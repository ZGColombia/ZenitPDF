import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ZPDFImageIntake

/// NL-PLAT-04 acceptance. Expected values are derived by hand from the fixture's own numbers
/// (pixels, dpi), never read back from the code under test.
@Suite("Image intake — NL-PLAT-04")
struct ImageIntakeTests {

    // MARK: Fixtures

    final class Scratch {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-intake-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// A 1-bit image with a black horizontal bar `barPixels` long starting at x = 100, y = 100
    /// (from the top), `barHeight` pixels tall.
    static func bilevelImage(width: Int, height: Int, barPixels: Int, barHeight: Int = 4) -> CGImage {
        let bytesPerRow = (width + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: bytesPerRow * height) // 1 = white in DeviceGray
        for row in 100..<(100 + barHeight) {
            for x in 100..<(100 + barPixels) {
                bits[row * bytesPerRow + x / 8] &= ~(0x80 >> UInt8(x % 8))
            }
        }
        let provider = CGDataProvider(data: Data(bits) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    static func writeImages(_ images: [CGImage], to url: URL, type: UTType, properties: [CFString: Any]) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
    }

    static var g4TIFF: [CFString: Any] { [
        kCGImagePropertyDPIWidth: 300,
        kCGImagePropertyDPIHeight: 300,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 4] as CFDictionary, // CCITT Group 4
    ] }

    // MARK: The acceptance tests

    @Test("A 3-page 300-dpi G4 TIFF opens as 3 pages whose media box is pixels ÷ 300 × 72")
    func multiPageG4TIFF() throws {
        let scratch = try Scratch()
        let tiff = scratch.url("plan-room.tif")
        // 2480 × 3508 px at 300 dpi is A4 (8.2667 × 11.6933 in): 595.2 × 841.92 pt.
        let pages = (0..<3).map { _ in Self.bilevelImage(width: 2480, height: 3508, barPixels: 600) }
        try Self.writeImages(pages, to: tiff, type: .tiff, properties: Self.g4TIFF)

        // The fixture really is G4 and 1-bit, or the test says nothing about scans.
        let source = try #require(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        let first = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiffDictionary = try #require(first[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect((tiffDictionary[kCGImagePropertyTIFFCompression] as? NSNumber)?.intValue == 4)

        let pdf = scratch.url("plan-room.pdf")
        let result = try ImageIntake.makePDF(from: tiff, to: pdf)
        #expect(result.pages.count == 3)
        #expect(result.allPagesHaveTrustedResolution)
        let expectedWidth = 2480.0 / 300.0 * 72.0   // 595.2
        let expectedHeight = 3508.0 / 300.0 * 72.0  // 841.92
        for page in result.pages {
            #expect(abs(page.mediaBox.width - expectedWidth) < 1e-9)
            #expect(abs(page.mediaBox.height - expectedHeight) < 1e-9)
            #expect(page.frame.bitsPerPixel == 1)
        }

        // The written PDF agrees, page by page.
        let document = try #require(CGPDFDocument(pdf as CFURL))
        #expect(document.numberOfPages == 3)
        for index in 1...3 {
            let box = try #require(document.page(at: index)).getBoxRect(.mediaBox)
            #expect(abs(box.width - expectedWidth) < 0.01)
            #expect(abs(box.height - expectedHeight) < 0.01)
        }
    }

    @Test("A length measured on page 2 at 1:100 equals the drawn length: 600 px at 300 dpi is 5.08 m")
    func calibratedLengthMatchesPaper() throws {
        let scratch = try Scratch()
        let tiff = scratch.url("scale.tif")
        let images = (0..<3).map { _ in Self.bilevelImage(width: 2480, height: 3508, barPixels: 600) }
        try Self.writeImages(images, to: tiff, type: .tiff, properties: Self.g4TIFF)
        let result = try ImageIntake.makePDF(from: tiff, to: scratch.url("scale.pdf"))
        let page = result.pages[1]
        // Points per pixel on this page, from the media box.
        let pointsPerPixel = page.mediaBox.width / Double(page.frame.pixelWidth)
        let barPoints = 600 * pointsPerPixel
        // Hand-derived: 600 px ÷ 300 dpi = 2 in = 50.8 mm on paper; at 1:100 that is 5080 mm.
        let paperMillimetres = barPoints / 72 * 25.4
        #expect(abs(paperMillimetres - 50.8) < 1e-9)
        let realMetres = paperMillimetres * 100 / 1000
        #expect(abs(realMetres - 5.08) < 1e-9)
    }

    @Test("A 20 000 × 20 000 image is refused with the limit stated, before any pixel is decoded")
    func oversizedImageRefusedFromHeader() throws {
        let scratch = try Scratch()
        let png = scratch.url("huge.png")
        // A real 20 000 × 20 000 PNG (400 million pixels, 1.6 GB once decoded to RGBA). The
        // refusal comes from `inspect`, which reads header properties only.
        try Self.blackPNG(width: 20_000, height: 20_000).write(to: png)
        let frames = try? ImageIntake.inspect(png, limits: ImageIntakeLimits(maximumPixelsPerFrame: .max))
        #expect(frames?.first?.pixelWidth == 20_000, "the fixture must be a readable 20 000-pixel image")
        #expect(throws: ImageIntakeError.frameTooLarge(
            fileName: "huge.png", frame: 0, pixelWidth: 20_000, pixelHeight: 20_000, limit: 250_000_000
        )) {
            try ImageIntake.makePDF(from: png, to: scratch.url("huge.pdf"))
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.url("huge.pdf").path))
        let sentence = ImageIntakeError.frameTooLarge(
            fileName: "huge.png", frame: 0, pixelWidth: 20_000, pixelHeight: 20_000, limit: 250_000_000
        ).description
        #expect(sentence.contains("20000 × 20000") && sentence.contains("250000000"))
    }

    @Test("No resolution, or the 72-dpi screen default on a 10 000-pixel scan, is never a physical size")
    func untrustedResolutionNeverGuessed() throws {
        #expect(ImageIntake.resolution(dpiX: nil, dpiY: nil, pixelWidth: 4000, pixelHeight: 3000) == .untrusted(.missing))
        // 10 000 px at 72 dpi would be a 3.5 m sheet.
        #expect(ImageIntake.resolution(dpiX: 72, dpiY: 72, pixelWidth: 10_000, pixelHeight: 7000)
                == .untrusted(.implausible(dpiX: 72, dpiY: 72)))
        // A small 72-dpi image (a screenshot of a detail) is plausible at its size.
        #expect(ImageIntake.resolution(dpiX: 72, dpiY: 72, pixelWidth: 1200, pixelHeight: 800).isTrusted)
        #expect(ImageIntake.resolution(dpiX: 10, dpiY: 10, pixelWidth: 100, pixelHeight: 100)
                == .untrusted(.implausible(dpiX: 10, dpiY: 10)))
        #expect(ImageIntake.resolution(dpiX: 300, dpiY: 300, pixelWidth: 9933, pixelHeight: 14043).isTrusted) // A0 at 300

        // End to end: a 10 000 × 7 000 G4 scan whose file says 72 dpi becomes a page marked
        // untrusted, one point per pixel, never a 3.5 m "sheet".
        let scratch = try Scratch()
        let tiff = scratch.url("junk-dpi.tif")
        var properties = Self.g4TIFF
        properties[kCGImagePropertyDPIWidth] = 72
        properties[kCGImagePropertyDPIHeight] = 72
        try Self.writeImages([Self.bilevelImage(width: 10_000, height: 7000, barPixels: 100)], to: tiff, type: .tiff, properties: properties)
        let result = try ImageIntake.makePDF(from: tiff, to: scratch.url("junk-dpi.pdf"))
        #expect(result.pages.count == 1)
        #expect(!result.allPagesHaveTrustedResolution)
        #expect(result.pages[0].frame.resolution == .untrusted(.implausible(dpiX: 72, dpiY: 72)))
        #expect(result.pages[0].mediaBox.size == CGSize(width: 10_000, height: 7000))
    }

    @Test("A phone photo stored sideways (EXIF orientation 6) becomes an upright sheet")
    func orientationIsApplied() throws {
        let frame = ImageFrameInfo(index: 0, pixelWidth: 4000, pixelHeight: 3000,
                                   resolution: .trusted(dpiX: 200, dpiY: 100), orientation: 6, bitsPerPixel: 8)
        let box = ImageIntake.mediaBox(for: frame)
        // Upright: 3000 px wide at the stored *vertical* resolution (100), 4000 px tall at 200.
        #expect(abs(Double(box.width) - 2160) < 1e-9)   // 3000 px ÷ 100 dpi × 72
        #expect(abs(Double(box.height) - 1440) < 1e-9)  // 4000 px ÷ 200 dpi × 72
        // The transform maps the stored image's corners onto the box.
        let t = ImageIntake.orientationTransform(6, box: box)
        let storedTopLeft = CGPoint(x: 0, y: box.width).applying(t)   // stored drawn size is (box.height, box.width)
        #expect(abs(storedTopLeft.x - box.width) < 1e-9 && abs(storedTopLeft.y - box.height) < 1e-9,
                "orientation 6: the stored top-left corner is the upright top-right")
    }

    @Test("Other files are refused as not an image, and unsupported extensions are not offered")
    func nonImagesRefused() throws {
        let scratch = try Scratch()
        let fake = scratch.url("notes.tif")
        try Data("not an image".utf8).write(to: fake)
        #expect(throws: ImageIntakeError.self) { try ImageIntake.makePDF(from: fake, to: scratch.url("x.pdf")) }
        #expect(ImageIntake.canOpen(URL(fileURLWithPath: "/a/Scan.TIFF")))
        #expect(ImageIntake.canOpen(URL(fileURLWithPath: "/a/photo.heic")))
        #expect(!ImageIntake.canOpen(URL(fileURLWithPath: "/a/plan.dwg")))
        #expect(!ImageIntake.canOpen(URL(fileURLWithPath: "/a/plan.pdf")))
    }

    // MARK: Helpers

    /// A complete, valid 1-bit greyscale PNG of `width` × `height` pixels, all black, built by
    /// hand so no 400-megapixel bitmap is ever allocated: the IDAT is a zlib stream of zeros
    /// (DEFLATE via Foundation, wrapped with the zlib header and Adler-32 computed in closed form,
    /// because the Adler-32 of n zero bytes is `(n mod 65521) << 16 | 1`).
    static func blackPNG(width: UInt32, height: UInt32) throws -> Data {
        func chunk(_ type: String, _ body: Data) -> Data {
            var out = Data()
            out.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
            var typed = Data(type.utf8)
            typed.append(body)
            out.append(typed)
            out.append(contentsOf: withUnsafeBytes(of: crc32(typed).bigEndian, Array.init))
            return out
        }
        var ihdr = Data()
        ihdr.append(contentsOf: withUnsafeBytes(of: width.bigEndian, Array.init))
        ihdr.append(contentsOf: withUnsafeBytes(of: height.bigEndian, Array.init))
        ihdr.append(contentsOf: [1, 0, 0, 0, 0]) // 1-bit, greyscale, deflate, adaptive, no interlace
        let rowBytes = 1 + (Int(width) + 7) / 8   // filter byte + packed pixels
        let raw = Data(count: rowBytes * Int(height))
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        var zlib = Data([0x78, 0x01])
        zlib.append(deflated)
        let adler = (UInt32(raw.count % 65521) << 16) | 1
        zlib.append(contentsOf: withUnsafeBytes(of: adler.bigEndian, Array.init))
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlib))
        png.append(chunk("IEND", Data()))
        return png
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
