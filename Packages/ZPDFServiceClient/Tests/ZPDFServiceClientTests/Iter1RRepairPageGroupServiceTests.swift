import CoreGraphics
import CryptoKit
import Foundation
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport
@testable import ZPDFServiceClient

/// Iteration 1 re-fix, NL-DOCS-08 across the process boundary: Split into Sheets
/// asks the repair worker for every sheet of a drawing in one request, which parses the drawing
/// once. Old behaviour: one extractPages request per sheet, each a full parse of the drawing.
struct Iter1RRepairPageGroupServiceTests {

    /// `/PageLabels` of a single-range copy: the prefix and start of its one range.
    static func label(_ url: URL) throws -> String? {
        let document = try #require(CGPDFDocument(url as CFURL))
        let catalog = try #require(document.catalog)
        var labels: CGPDFDictionaryRef?
        var nums: CGPDFArrayRef?
        var range: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "PageLabels", &labels), let labels,
              CGPDFDictionaryGetArray(labels, "Nums", &nums), let nums,
              CGPDFArrayGetDictionary(nums, 1, &range), let range else { return nil }
        var start: CGPDFInteger = 1
        _ = CGPDFDictionaryGetInteger(range, "St", &start)
        var prefix: CGPDFStringRef?
        let text = CGPDFDictionaryGetString(range, "P", &prefix) ? (prefix.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "") : ""
        return text + String(start)
    }

    @Test("extractPageGroups runs in the worker: one file per group, in order, labels and layers kept, input unchanged")
    func groupsRunOutOfProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-it1r-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { ServiceTestSupport.remove(directory) }
        let input = directory.appendingPathComponent("set.pdf")
        try Iter1RepairExtractServiceTests.labelledLayeredSet().write(to: input)
        let before = SHA256.hash(data: try Data(contentsOf: input))
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 0)
        defer { Task { await client.shutdown() } }

        let outputs = ["A-103.pdf", "A-101.pdf", "A-102.pdf"].map { directory.appendingPathComponent($0) }
        let reply = try await client.extractPageGroups(input: input, outputs: outputs, pageGroups: [[2], [0], [1]])
        #expect(reply.partByteCounts?.count == 3)
        #expect(reply.partByteCounts?.reduce(0, +) == reply.outputByteCount)
        #expect(SHA256.hash(data: try Data(contentsOf: input)) == before, "the input must not change")
        #expect(try outputs.map { try Self.label($0) } == ["A-103", "A-101", "A-102"])
        for output in outputs {
            let document = try #require(CGPDFDocument(output as CFURL))
            #expect(document.numberOfPages == 1)
            let catalog = try #require(document.catalog)
            var properties: CGPDFDictionaryRef?
            #expect(CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties), "the layer definitions travel")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".zpdf-") }
        #expect(leftovers.isEmpty, "no joined or staging file is left: \(leftovers)")

        // A page the drawing does not have, a count that does not match, or the input as an
        // output: refused, and nothing is written.
        let never = [directory.appendingPathComponent("n1.pdf"), directory.appendingPathComponent("n2.pdf")]
        await #expect(throws: (any Error).self) { _ = try await client.extractPageGroups(input: input, outputs: never, pageGroups: [[0], [7]]) }
        await #expect(throws: (any Error).self) { _ = try await client.extractPageGroups(input: input, outputs: never, pageGroups: [[0]]) }
        await #expect(throws: (any Error).self) { _ = try await client.extractPageGroups(input: input, outputs: [input], pageGroups: [[0]]) }
        #expect(never.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(SHA256.hash(data: try Data(contentsOf: input)) == before)
    }
}
