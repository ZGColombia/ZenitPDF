import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ZPDFQPDF
import ZPDFTestingSupport

/// NL-PDF-08, the picture half of Reduce File Size: pictures painted above the target resolution
/// are resampled, everything else — linework, boxes, rotation, pictures painted large somewhere —
/// stays exactly as it was. Expected sizes are derived by hand from the placements below.
@Suite("Reduce file size — picture downsampling (NL-PDF-08)")
struct QPDFDownsampleTests {

    /// Deterministic noise, so the JPEG is the size a scanned photograph is, not a flat colour.
    static func noisyRGB(width: Int, height: Int) -> [UInt8] {
        var seed: UInt32 = 0x2545_F491
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<bytes.count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: (seed >> 24) / 2 + UInt32((index / 3) % width) * 127 / UInt32(width))
        }
        return bytes
    }

    static func jpeg(width: Int, height: Int) -> Data {
        let pixels = noisyRGB(width: width, height: height)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let writer = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
        return out as Data
    }

    /// One A4-ish page: linework, a 2400 × 1600 JPEG painted 288 × 192 pt (600 dpi), a
    /// 1200 × 1200 Flate RGB picture painted 200 × 200 pt (432 dpi), and an 800 × 800 JPEG painted
    /// twice — 96 × 96 pt (600 dpi) and 576 × 576 pt (100 dpi), so its largest placement is 100
    /// dpi and it must not be touched.
    static func scannedDrawing() -> Data {
        let photo = jpeg(width: 2400, height: 1600)
        let twice = jpeg(width: 800, height: 800)
        let flateRaw = Data(noisyRGB(width: 1200, height: 1200).map { $0 & 0xF0 })
        let flate = try! (flateRaw as NSData).compressed(using: .zlib) as Data
        // NSData's zlib is raw deflate; PDF /FlateDecode wants a zlib header and trailer.
        var zlib = Data([0x78, 0x9C])
        zlib.append(flate)
        var adler: (UInt32, UInt32) = (1, 0)
        for byte in flateRaw { adler.0 = (adler.0 + UInt32(byte)) % 65521; adler.1 = (adler.1 + adler.0) % 65521 }
        let checksum = (adler.1 << 16) | adler.0
        zlib.append(contentsOf: [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF), UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])

        var content = "0 0 0 RG 0.5 w\n"
        for index in 0..<60 { content += "30 \(40 + index * 12) m 565 \(40 + index * 12) l S\n" }
        content += "q 288 0 0 192 50 500 cm /Im1 Do Q\n"
        content += "q 200 0 0 200 350 500 cm /Im2 Do Q\n"
        content += "q 96 0 0 96 50 380 cm /Im3 Do Q\n"
        content += "q 576 0 0 576 10 10 cm /Im3 Do Q\n"
        content += "20 20 555 802 re S\n"

        var pdf = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        func object(_ number: Int, _ header: String, stream: Data? = nil) {
            offsets.append(pdf.count)
            pdf.append(Data("\(number) 0 obj\n\(header)\n".utf8))
            if let stream {
                pdf.append(Data("stream\n".utf8))
                pdf.append(stream)
                pdf.append(Data("\nendstream\n".utf8))
            }
            pdf.append(Data("endobj\n".utf8))
        }
        object(1, "<< /Type /Catalog /Pages 2 0 R >>")
        object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Rotate 90 /Contents 4 0 R"
               + " /Resources << /XObject << /Im1 5 0 R /Im2 6 0 R /Im3 7 0 R >> >> >>")
        object(4, "<< /Length \(content.utf8.count) >>", stream: Data(content.utf8))
        object(5, "<< /Type /XObject /Subtype /Image /Width 2400 /Height 1600 /ColorSpace /DeviceRGB /BitsPerComponent 8"
               + " /Filter /DCTDecode /Length \(photo.count) >>", stream: photo)
        object(6, "<< /Type /XObject /Subtype /Image /Width 1200 /Height 1200 /ColorSpace /DeviceRGB /BitsPerComponent 8"
               + " /Filter /FlateDecode /Length \(zlib.count) >>", stream: zlib)
        object(7, "<< /Type /XObject /Subtype /Image /Width 800 /Height 800 /ColorSpace /DeviceRGB /BitsPerComponent 8"
               + " /Filter /DCTDecode /Length \(twice.count) >>", stream: twice)
        let xref = pdf.count
        var table = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    /// `/Width` and `/Height` of each named picture on page 1.
    static func sizes(ofFileAt url: URL) -> [String: (Int, Int)] {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1), let dictionary = page.dictionary else { return [:] }
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return [:] }
        var result: [String: (Int, Int)] = [:]
        for name in ["Im1", "Im2", "Im3"] {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) else { continue }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            _ = CGPDFDictionaryGetInteger(d, "Width", &w)
            _ = CGPDFDictionaryGetInteger(d, "Height", &h)
            result[name] = (w, h)
        }
        return result
    }

    @Test("Pictures above 150 dpi are resampled to it; the one painted large stays; linework, boxes and rotation are identical")
    func downsamplesPicturesOnly() throws {
        let box = try Sandbox("downsample")
        let input = box.file("scan.pdf")
        try Self.scannedDrawing().write(to: input)
        let inputHash = try Hashing.sha256(of: input)
        let output = box.file("smaller.pdf")

        let report = try QPDF.transform(
            input: input, output: output,
            transform: QPDFTransform(compresses: true, downsampling: QPDFImageDownsampling(targetDPI: 150))
        )
        // Old behaviour: "Image data is untouched" — the copy kept every picture at full size.
        #expect(report.offeredImageCount == 2)
        #expect(report.downsampledImageCount == 2)
        let sizes = Self.sizes(ofFileAt: output)
        // 2400 px over 4 in → 600 dpi; at 150 dpi: 2400 × 150 / 600 = 600, 1600 × 150 / 600 = 400.
        #expect(sizes["Im1"]?.0 == 600 && sizes["Im1"]?.1 == 400)
        // 1200 px over 200/72 in → 432 dpi; 1200 × 150 / 432 = 416.67 → 417.
        #expect(sizes["Im2"]?.0 == 417 && sizes["Im2"]?.1 == 417)
        // Painted at 100 dpi on the largest placement: never offered, never touched.
        #expect(sizes["Im3"]?.0 == 800 && sizes["Im3"]?.1 == 800)

        #expect(report.outputByteCount <= report.inputByteCount * 6 / 10, "\(report.inputByteCount) → \(report.outputByteCount)")
        let before = try #require(QPDFVectorDigest.pages(ofFileAt: input))
        let after = try #require(QPDFVectorDigest.pages(ofFileAt: output))
        #expect(before == after)
        #expect(before.first?.hasSuffix("/1") == false, "the digest saw the linework, not an empty page")
        #expect(try Hashing.sha256(of: input) == inputHash, "the input is never modified")
        let reopened = try #require(CGPDFDocument(output as CFURL)?.page(at: 1))
        #expect(reopened.rotationAngle == 90)
        #expect(reopened.getBoxRect(.mediaBox) == CGRect(x: 0, y: 0, width: 595, height: 842))
    }

    @Test("The resampler keeps grey pictures grey, refuses to enlarge, and a digest sees a moved line")
    func resamplerAndGate() throws {
        let gray = [UInt8](repeating: 128, count: 400 * 300)
        let result = gray.withUnsafeBytes {
            QPDFImageResampler.resample(width: 400, height: 300, components: 1, isJPEG: false, effectiveDPI: 600,
                                        bytes: $0, settings: QPDFImageDownsampling(targetDPI: 150))
        }
        let output = try #require(result)
        #expect(output.width == 100 && output.height == 75 && !output.isJPEG)
        #expect(output.data.count == 100 * 75)
        #expect(output.data.allSatisfy { abs(Int($0) - 128) <= 1 })
        let none = gray.withUnsafeBytes {
            QPDFImageResampler.resample(width: 400, height: 300, components: 1, isJPEG: false, effectiveDPI: 140,
                                        bytes: $0, settings: QPDFImageDownsampling(targetDPI: 150))
        }
        #expect(none == nil)

        let box = try Sandbox("digest")
        let a = box.file("a.pdf"), b = box.file("b.pdf")
        try Self.scannedDrawing().write(to: a)
        var moved = Self.scannedDrawing()
        let needle = Data("565 40 l".utf8), replacement = Data("565 41 l".utf8)
        let range = try #require(moved.range(of: needle))
        moved.replaceSubrange(range, with: replacement)
        try moved.write(to: b)
        #expect(QPDFVectorDigest.pages(ofFileAt: a) != QPDFVectorDigest.pages(ofFileAt: b))
    }
}
