import CryptoKit
import Foundation
import PDFKit
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport
@testable import ZPDFServiceClient

/// NL-DOCS-08 across the process boundary (iteration 1): Extract Pages and Split
/// into Sheets can run through qpdf in the repair worker, which keeps the sheets' page labels and
/// the drawing's layer definitions. Old behaviour: the repair service had no page operation at
/// all; extraction ran through PDFKit in the app process only.
struct Iter1RepairExtractServiceTests {

    /// Three sheets labelled A-101…A-103 whose line sits in layer "Walls".
    static func labelledLayeredSet() -> Data {
        let content = "/OC /L1 BDC 0 0 0 RG 10 10 m 190 190 l S EMC\n"
        var objects: [(String, String?)] = [
            ("<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D /P (A-) /St 101 >>] >>"
                + " /OCProperties << /OCGs [7 0 R] /D << /Order [7 0 R] /ON [7 0 R] /OFF [] >> >> >>", nil),
            ("<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>", nil),
        ]
        for _ in 0..<3 {
            objects.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R /Resources << /Properties << /L1 7 0 R >> >> >>", nil))
        }
        objects.append(("<< /Length \(content.utf8.count) >>", content))
        objects.append(("<< /Type /OCG /Name (Walls) >>", nil))
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            var body = "\(index + 1) 0 obj\n\(object.0)\n"
            if let stream = object.1 { body += "stream\n\(stream)\nendstream\n" }
            pdf.append(Data((body + "endobj\n").utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    @Test("extractPages runs in the worker: pages 3 and 1 in that order, labels A-103 and A-101, layers kept, input unchanged")
    func extractRunsOutOfProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-iter1-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { ServiceTestSupport.remove(directory) }
        let input = directory.appendingPathComponent("set.pdf"), output = directory.appendingPathComponent("extract.pdf")
        try Self.labelledLayeredSet().write(to: input)
        let before = SHA256.hash(data: try Data(contentsOf: input))
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 0)
        defer { Task { await client.shutdown() } }

        let reply = try await client.extractPages(input: input, output: output, pageIndices: [2, 0])
        #expect(reply.outputByteCount > 0)
        #expect(SHA256.hash(data: try Data(contentsOf: input)) == before, "the input must not change")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.label == "A-103" && document.page(at: 1)?.label == "A-101")
        let catalog = try #require(document.documentRef?.catalog)
        var properties: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties), "the layer definitions travel")

        // No pages named, or a page the drawing does not have: refused, nothing written.
        let never = directory.appendingPathComponent("never.pdf")
        await #expect(throws: (any Error).self) { _ = try await client.extractPages(input: input, output: never, pageIndices: []) }
        await #expect(throws: (any Error).self) { _ = try await client.extractPages(input: input, output: never, pageIndices: [7]) }
        #expect(!FileManager.default.fileExists(atPath: never.path))
    }
}
