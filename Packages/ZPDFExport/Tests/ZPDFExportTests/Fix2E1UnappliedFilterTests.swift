import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Filter rules the ledger could not apply travel in the report and are printed in the
/// exports that carry metadata (BH-101).
@Suite("Fix2 E1 unapplied filter rules", .sharedHeap)
struct Fix2E1UnappliedFilterTests {

    private static func report(unapplied: [String]) throws -> LedgerReport {
        let spec = LedgerViewSpec(visibleColumns: [])
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(try Fix2E1ProjectionTests.store().makeView(spec), title: "Rules", unappliedFilterRules: unapplied)
    }

    @Test("BH-101: unapplied filter rules reach the report, the projection and the PDF cover")
    func unappliedRulesArePrinted() throws {
        let note = "Pattern rules are not applied (Label matches ^C-)"
        let report = try Self.report(unapplied: [note])
        #expect(report.metadata.unappliedFilterRules == [note])
        let projection = try ExportProjector().project(report)
        #expect(projection.table.metadata.unappliedFilterRules == [note])
        let cover = Painter.coverEntries(projection.table.metadata)
        // Old: the cover said "Filter: …" only — the rows looked filtered by a rule that was dropped.
        #expect(cover.contains { $0.label == "Not applied" && $0.value == note })
    }

    @Test("BH-101: with nothing unapplied the cover is unchanged")
    func noNoteWithoutRules() throws {
        let projection = try ExportProjector().project(try Self.report(unapplied: []))
        #expect(!Painter.coverEntries(projection.table.metadata).contains { $0.label == "Not applied" })
    }

    private static func sheetXML(_ projection: ExportProjection, constantMemory: Bool) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fix2-im063-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url, options: XLSXExportOptions(constantMemory: constantMemory))
        return try XLSXInspector.entry("xl/worksheets/sheet1.xml", of: url)
    }

    @Test("IM-063: a grouped workbook carries outline levels in both memory modes; a flat one none")
    func outlineLevelsAreWritten() throws {
        let grouped = try ExportProjector().project(
            try Fix2E1ProjectionTests.report(grouping: [Fix2E1ProjectionTests.hiddenID])
        )
        for constantMemory in [false, true] {
            let xml = try Self.sheetXML(grouped, constantMemory: constantMemory)
            // Old: no row carried outlineLevel — the workbook could not collapse to subtotals.
            #expect(xml.contains("outlineLevel=\"1\""), "constantMemory: \(constantMemory)")
        }
        let flat = try ExportProjector().project(try Fix2E1ProjectionTests.report())
        #expect(!(try Self.sheetXML(flat, constantMemory: false)).contains("outlineLevel="))
    }
}
