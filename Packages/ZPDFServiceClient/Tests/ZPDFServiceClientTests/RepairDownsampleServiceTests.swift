import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport
@testable import ZPDFServiceClient

/// NL-PDF-08 across the process boundary: pictures are decoded, resampled and re-encoded with
/// ImageIO inside the repair worker, never in the test binary, and the input is unchanged.
struct RepairDownsampleServiceTests {

    /// A 1600 × 1200 noisy JPEG painted 144 × 108 pt (800 dpi) over two lines.
    static func scan(at url: URL) throws {
        let width = 1600, height = 1200
        var seed: UInt32 = 7
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for index in pixels.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; pixels[index] = UInt8(truncatingIfNeeded: seed >> 24) }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let jpeg = NSMutableData()
        let writer = CGImageDestinationCreateWithData(jpeg as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        _ = CGImageDestinationFinalize(writer)
        let content = "0 0 0 RG 10 10 m 400 10 l S 10 20 m 400 20 l S q 144 0 0 108 50 50 cm /Im1 Do Q"
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        func object(_ header: String, _ stream: Data? = nil) {
            offsets.append(pdf.count)
            pdf.append(Data("\(offsets.count) 0 obj\n\(header)\n".utf8))
            if let stream { pdf.append(Data("stream\n".utf8)); pdf.append(stream); pdf.append(Data("\nendstream\n".utf8)) }
            pdf.append(Data("endobj\n".utf8))
        }
        object("<< /Type /Catalog /Pages 2 0 R >>")
        object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 300] /Contents 4 0 R /Resources << /XObject << /Im1 5 0 R >> >> >>")
        object("<< /Length \(content.utf8.count) >>", Data(content.utf8))
        object("<< /Type /XObject /Subtype /Image /Width 1600 /Height 1200 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.length) >>", jpeg as Data)
        let xref = pdf.count
        var table = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        try pdf.write(to: url)
    }

    /// `/Width` of `/Im1` on page 1, or 0.
    static func pictureWidth(_ url: URL) -> Int {
        // The document must outlive every dictionary read from it.
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1)?.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects,
              CGPDFDictionaryGetStream(xobjects, "Im1", &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return 0 }
        var width: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(dictionary, "Width", &width)
        return withExtendedLifetime(document) { width }
    }

    @Test("Reduce File Size with a picture target runs in the worker: the picture shrinks, the file shrinks, the input is unchanged")
    func downsamplesOutOfProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-downsample-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { ServiceTestSupport.remove(directory) }
        let input = directory.appendingPathComponent("scan.pdf")
        try Self.scan(at: input)
        let before = SHA256.hash(data: try Data(contentsOf: input))
        let output = directory.appendingPathComponent("smaller.pdf")
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 0)
        defer { Task { await client.shutdown() } }

        let reply = try await client.transform(
            input: input, output: output,
            transform: RepairWireTransform(compresses: true, pictureTargetDPI: 150)
        )
        let summary = try #require(reply.transformSummary)
        #expect(summary.downsampledImageCount == 1 && summary.offeredImageCount == 1)
        // 1600 px over 2 in = 800 dpi → 150 dpi is 300 × 225 px: far under 40 % of the bytes.
        #expect(reply.outputByteCount * 10 <= summary.inputByteCount * 4, "\(summary.inputByteCount) → \(reply.outputByteCount)")
        #expect(SHA256.hash(data: try Data(contentsOf: input)) == before, "the input must not change")
        let width = Self.pictureWidth(output)
        #expect(width == 300)
    }
}
