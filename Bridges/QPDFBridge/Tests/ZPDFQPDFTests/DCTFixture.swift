import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A one-page PDF whose only image is `/DCTDecode`-encoded.
///
/// The fixture corpus in `ZPDFTestingSupport` has no JPEG-bearing document —
/// its raster fixtures use Flate — and this bridge is built without libjpeg, so
/// the DCT path needs its own fixture. The JPEG itself comes from ImageIO, so
/// it is a real JPEG produced by a real encoder rather than a byte blob that
/// merely looks like one.
enum DCTFixture {

    struct Built {
        let url: URL
        /// The exact JPEG bytes embedded in the PDF, from SOI to EOI.
        let jpegBytes: Data
        let width: Int
        let height: Int
    }

    /// Writes the fixture into `directory`.
    ///
    /// - Parameter breakCrossReferences: when true, every offset in the xref
    ///   table is shifted so the file needs reconstruction — the case where a
    ///   DCT-bearing document must survive a repair.
    static func make(
        in directory: URL,
        named name: String,
        breakCrossReferences: Bool = false
    ) throws -> Built {
        let width = 64
        let height = 48
        let jpeg = try makeJPEG(width: width, height: height)

        var objects: [Data] = []
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        objects.append(
            Data(
                """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>
                """.utf8))

        let content = Data("q 256 0 0 192 100 500 cm /Im0 Do Q\n".utf8)
        var contentObject = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        contentObject.append(content)
        contentObject.append(Data("\nendstream".utf8))
        objects.append(contentObject)

        var imageObject = Data(
            """
            << /Type /XObject /Subtype /Image /Width \(width) /Height \(height) \
            /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode \
            /Length \(jpeg.count) >>
            stream

            """.utf8)
        imageObject.append(jpeg)
        imageObject.append(Data("\nendstream".utf8))
        objects.append(imageObject)

        var file = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(file.count)
            file.append(Data("\(index + 1) 0 obj\n".utf8))
            file.append(body)
            file.append(Data("\nendobj\n".utf8))
        }

        let xrefOffset = file.count
        let shift = breakCrossReferences ? 37 : 0
        var xref = Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets {
            xref.append(Data(String(format: "%010d 00000 n \n", offset + shift).utf8))
        }
        file.append(xref)
        file.append(
            Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n".utf8))
        file.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))

        let url = directory.appendingPathComponent(name)
        try file.write(to: url, options: .atomic)
        return Built(url: url, jpegBytes: jpeg, width: width, height: height)
    }

    private static func makeJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            throw FixtureFailure.contextUnavailable
        }
        // A gradient with a hard edge: cheap to encode, and not a flat colour,
        // so a re-encode at any quality would change the bytes noticeably.
        for y in 0..<height {
            for x in 0..<width {
                let red = CGFloat(x) / CGFloat(width)
                let green = CGFloat(y) / CGFloat(height)
                let blue: CGFloat = (x / 8 + y / 8) % 2 == 0 ? 0.9 : 0.1
                context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let image = context.makeImage() else { throw FixtureFailure.imageUnavailable }

        let buffer = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                buffer, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw FixtureFailure.encoderUnavailable
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureFailure.encodeFailed
        }
        return buffer as Data
    }

    enum FixtureFailure: Error {
        case contextUnavailable
        case imageUnavailable
        case encoderUnavailable
        case encodeFailed
    }
}
