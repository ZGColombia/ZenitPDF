import Foundation
import CoreText
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Regression tests for the printed-report layout findings: BH-138, BH-527, BH-528, BH-529,
/// BH-530.
@Suite("Fix2 E1 PDF report layout", .sharedHeap)
struct Fix2E1PDFReportTests {

    private static let auditTitles = ["#", "Time", "Action", "Author", "Subject", "Page", "Values", "Note"]

    private static func auditRows(_ count: Int) -> [[String]] {
        (0..<count).map { index in
            [
                "\(index + 1)",
                "2026-09-01T22:30:\(String(format: "%02d", index % 60))Z",
                "Changed the quantity of a markup",
                "Site engineer (site office, north)",
                "Concrete slab, level 2, bay \(index)",
                "A-101",
                "Plan Area 12.500 m² → 12.750 m²; Depth 0.200 m → 0.250 m; Unit cost 1 250 → 1 300",
                "Recalibrated after the revision C drawing arrived from the architect's office"
            ]
        }
    }

    @Test("BH-138: a long document name is ellipsised on the cover, not run off the page")
    func coverHeadingStaysInsideTheMargin() throws {
        let report = try ExportFixture.goldenReport(
            title: "A-101_Floor_plan_level_2_rev_C_with_a_very_long_suffix.pdf — Quantity Ledger"
        )
        let projection = try ExportFixture.projection(report)
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(
            projection, to: url, options: PDFReportOptions(pageSize: .a4)
        )
        // Old: the 22 pt heading was drawn with no width limit — about 250 pt past A4's right
        // margin, so the "Quantity Ledger" tail was clipped by the media box.
        #expect(result.rightMarginOverrun == 0)
    }

    @Test("BH-527: a long footer note ends before the page number starts")
    func footerNoteDoesNotReachThePageNumber() {
        let contentWidth = 595.276 - 36 - 36
        for number in ["Page 1", "Page 12", "Page 1234"] {
            let font = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
            let numberWidth = TextMeasure.width(number, font: font)
            let layout = Painter.footerLayout(
                contentLeft: 36, contentWidth: contentWidth, pageNumberWidth: numberWidth
            )
            // Old: the note ran to 36 + 0.98·contentWidth ≈ 548.9 pt while "Page 12" starts at
            // ≈ 532 pt — seventeen points of overlap on every page.
            #expect(layout.noteX + layout.noteMaxWidth < layout.pageNumberX)
            #expect(layout.noteMaxWidth > 0)
        }
    }

    @Test("BH-528: provenance marks are recorded apart from the one-entry-per-cell trace")
    func marksDoNotBreakTheCellTrace() throws {
        // Three rows: measured, derived, read.
        let store = try ProvenanceExportTests.mixedStore()
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(LedgerViewSpec()), title: "Mixed")
        let projection = try ExportFixture.projection(report)
        #expect(projection.table.carriesProvenanceLabels)
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(
            projection, to: url,
            options: PDFReportOptions(
                pageSize: .a4.landscape, includeCoverPage: false, includeGrandTotals: false,
                recordsDrawnText: true
            )
        )
        // Old: the legend and two glyphs sat between the rows of drawnText — 3 rows x width + 3
        // entries — so every cell after the first derived row was compared with its neighbour.
        #expect(result.drawnText.count == 3 * result.printedColumnCount)
        #expect(result.drawnMarks == [Painter.provenanceLegend, "\u{0192}", "\u{2310}"])
        let width = result.printedColumnCount
        let rows = stride(from: 0, to: result.drawnText.count, by: width).map {
            Array(result.drawnText[$0..<($0 + width)])
        }
        #expect(rows.map(\.first) == ["Concrete", "Steel", "Glazing"])
    }

    @Test("BH-529/530: the audit appendix's columns fit the page after the minimum-width clamp")
    func auditColumnsFitThePage() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(
            projection, to: url,
            options: PDFReportOptions(pageSize: .a4, includeCoverPage: false),
            auditAppendix: PDFReportAuditAppendix(
                title: "Audit trail", columnTitles: Self.auditTitles, rows: Self.auditRows(12)
            )
        )
        // Old: scaled to the content width, then "#" and "Page" raised back to 28 pt with no
        // compensating shrink — the Note column ran about 20 pt past the right margin.
        #expect(result.rightMarginOverrun == 0)

        let content = 595.276 - 36 - 36
        let natural = [30.0, 110, 150, 160, 160, 60, 160, 160]
        let fitted = Painter.fitAuditWidths(natural, into: content, minimum: 28)
        #expect(fitted.allSatisfy { $0 >= 28 - 1e-9 })
        #expect(abs(fitted.reduce(0, +) - content) < 1e-6)
        // Twelve columns on a page too narrow for twelve minimums share the page equally.
        let tight = Painter.fitAuditWidths(Array(repeating: 100, count: 12), into: 300, minimum: 28)
        #expect(abs(tight.reduce(0, +) - 300) < 1e-6)
        // A table that already fits is left alone.
        #expect(Painter.fitAuditWidths([40, 50], into: 500, minimum: 28) == [40, 50])
    }
}
