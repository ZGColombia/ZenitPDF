import CoreGraphics
import Foundation
import Testing
import ZPDFQPDF

/// Iteration 4, U-052: an image's /Width × /Height is multiplied with overflow
/// reported, in the qpdf shim and in the Swift resampler. No `@testable`: the release gate builds
/// this package's tests, and the resampler is `package`.
@Suite("Iteration 4 — QPDF image size bounds (U-052)")
struct Iter4QPDFImageBoundsTests {

    /// 2^63 − 2^31 − 1 and 2^62 + 2^31 − 1: their product modulo 2^64 is exactly 1.
    static let wrappingWidth = "9223372034707292159"
    static let wrappingHeight = "4611686020574871551"

    /// One page painting one unfiltered DeviceRGB picture 1 pt square, whose declared size is
    /// `width` × `height` and whose stream holds `samples` (three bytes by default).
    static func drawing(width: String, height: String, samples: Data = Data([0x10, 0x20, 0x30])) -> Data {
        let content = "q 1 0 0 1 100 100 cm /Im1 Do Q\n0 0 0 RG 10 10 m 200 10 l S\n"
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
        object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Contents 4 0 R"
               + " /Resources << /XObject << /Im1 5 0 R >> >> >>")
        object(4, "<< /Length \(content.utf8.count) >>", stream: Data(content.utf8))
        object(5, "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB"
               + " /BitsPerComponent 8 /Length \(samples.count) >>", stream: samples)
        let xref = pdf.count
        var table = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010ld 00000 n \n", offset) }
        table += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    @Test("U-052: Reduce File Size leaves a picture whose /Width × /Height wraps to 1 as it is, without offering it")
    func wrappingImageSizeIsNotOffered() throws {
        // Old: `width * height` in the shim overflowed (undefined behaviour) to exactly 1, so the
        // 3-byte stream passed both size checks, was offered to the resampler as 2147483647 ×
        // 2147483647, and `width * height * components` trapped the test process.
        let box = try Sandbox("u052-wrap")
        let input = box.file("hostile.pdf")
        try Self.drawing(width: Self.wrappingWidth, height: Self.wrappingHeight).write(to: input)
        // Uncompressed, so the picture's dictionary can be read back from the bytes; the
        // downsampling pass is the same with or without compression.
        let output = box.file("smaller.pdf")
        let report = try QPDF.transform(
            input: input, output: output,
            transform: QPDFTransform(downsampling: QPDFImageDownsampling(targetDPI: 150))
        )
        #expect(report.offeredImageCount == 0)
        #expect(report.downsampledImageCount == 0)
        let written = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        #expect(written.contains("/Width \(Self.wrappingWidth)"), "the picture is left as it was")
        #expect(written.contains("/Height \(Self.wrappingHeight)"))
        // Compressed as Reduce File Size writes it: still not offered, still no trap.
        let compressed = try QPDF.transform(
            input: input, output: box.file("compressed.pdf"),
            transform: QPDFTransform(compresses: true, downsampling: QPDFImageDownsampling(targetDPI: 150))
        )
        #expect(compressed.offeredImageCount == 0)
    }

    @Test("U-052: an honest picture painted at a high resolution is still offered and resampled")
    func honestPictureIsStillResampled() throws {
        // 30 × 20 px painted over 1 pt: 2160 × 1440 dpi, far above 150 × 1.25; 1800 sample bytes.
        let box = try Sandbox("u052-honest")
        let input = box.file("honest.pdf")
        try Self.drawing(width: "30", height: "20", samples: Data((0..<1800).map { UInt8($0 % 251) })).write(to: input)
        let output = box.file("smaller.pdf")
        let report = try QPDF.transform(
            input: input, output: output,
            transform: QPDFTransform(compresses: true, downsampling: QPDFImageDownsampling(targetDPI: 150))
        )
        #expect(report.offeredImageCount == 1, "the bound refuses only sizes that do not fit")
        #expect(report.downsampledImageCount == 1)
    }

    @Test("U-052: the resampler refuses a sample count that overflows Int instead of trapping")
    func resamplerRefusesOverflowingSize() {
        // Old: `bytes.count == width * height * components` evaluated 2147483647² × 3 ≈ 1.38e19,
        // which overflows Int: a runtime trap in the repair worker.
        let three: [UInt8] = [0x10, 0x20, 0x30]
        let huge = Int(Int32.max)
        let result = three.withUnsafeBytes {
            QPDFImageResampler.resample(width: huge, height: huge, components: 3, isJPEG: false, effectiveDPI: 1e300,
                                        bytes: $0, settings: QPDFImageDownsampling(targetDPI: 150))
        }
        #expect(result == nil)
        let row = three.withUnsafeBytes {
            QPDFImageResampler.resample(width: Int.max / 2, height: 2, components: 3, isJPEG: false, effectiveDPI: 1e300,
                                        bytes: $0, settings: QPDFImageDownsampling(targetDPI: 150))
        }
        #expect(row == nil, "width × components alone overflows")
        // An honest picture still resamples: 4 × 4 grey at 600 dpi → 1 × 1 at 150.
        let grey = [UInt8](repeating: 200, count: 16)
        let honest = grey.withUnsafeBytes {
            QPDFImageResampler.resample(width: 4, height: 4, components: 1, isJPEG: false, effectiveDPI: 600,
                                        bytes: $0, settings: QPDFImageDownsampling(targetDPI: 150))
        }
        #expect(honest?.width == 1 && honest?.height == 1)
    }
}
