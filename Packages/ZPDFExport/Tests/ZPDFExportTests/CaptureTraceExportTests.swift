import Foundation
import Testing
@testable import ZPDFExport

/// ADR-0031 (NL-AUTO-18) in the exports: the trace carries how each measurement was captured —
/// a traced area with one confirmed closing line reads "traced, 1 closing line 25.4 pt" in the
/// CSV's "Trace: Captured" column and in the JSON's `capture` key, and a file without it stays
/// byte for byte what it was.
@Suite("Capture method in traced exports", .sharedHeap)
struct CaptureTraceExportTests {

    static func projection(capture: String?) throws -> ExportProjection {
        let report = try ExportFixture.goldenReport()
        var traces: [String: ExportRowTrace] = [:]
        for index in 0..<ExportFixture.goldenValues.count {
            traces[ExportFixture.uuid(index).uuidString] = ExportRowTrace(
                sheetLabel: "A-1", scaleAtMeasureTime: "1:50", author: "Ada",
                capture: index == 0 ? capture : nil)
        }
        return try ExportProjector().project(report, options: ExportProjectionOptions(rowTraces: traces))
    }

    @Test("CSV and JSON carry the capture words; the JSON round-trips them")
    func captureWritten() throws {
        let projection = try Self.projection(capture: "traced, 1 closing line 25.4 pt")
        let csv = String(decoding: try CSVExporter().export(projection), as: UTF8.self)
        #expect(csv.contains("Trace: Captured"))
        #expect(csv.contains("traced, 1 closing line 25.4 pt"))
        let json = ZenitJSONExporter().export(projection)
        #expect(String(decoding: json, as: UTF8.self).contains(#""capture""#))
        let read = try ZenitJSONImporter().document(from: json)
        #expect(read.rows.first?.trace?.capture == "traced, 1 closing line 25.4 pt")
        #expect(read.rows.dropFirst().allSatisfy { $0.trace?.capture == nil })
    }

    @Test("A trace without a capture writes no capture key, so older files are unchanged")
    func absentIsOmitted() throws {
        let json = String(decoding: ZenitJSONExporter().export(try Self.projection(capture: nil)), as: UTF8.self)
        #expect(!json.contains(#""capture""#))
    }
}
