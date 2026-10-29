import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Fix round 2: changes other packages asked of ZPDFUIPresentation.
@Suite("Fix2 presentation cross-package requests")
@MainActor
struct Fix2CrossPackageRequestTests {

    /// IM-099: a presenter without a multi-level sorter applies the outermost level.
    @Test("Multi-level sort falls back to the first level")
    func multiLevelSortDefault() {
        let ledger = MockLedgerPresenter()
        ledger.sort(by: [LedgerSortDescriptor(column: .pageLabel, ascending: false),
                         LedgerSortDescriptor(column: .subject, ascending: true)])
        #expect(ledger.sortDescriptors == [LedgerSortDescriptor(column: .pageLabel, ascending: false)])
        #expect(ledger.lastRebuildError == nil)
        #expect(ledger.unappliedSortMessage == nil)
        ledger.onScreenColumnOrder = [.subject]
        #expect(ledger.onScreenColumnOrder.isEmpty, "the mock does not export")
    }

    /// BH-107: page-box alignment has an honest state of its own.
    @Test("Page-box alignment is its own state")
    func pageBoxAlignment() {
        let state = RevisionAlignmentState.pageBox(residualPixels: 0.5)
        #expect(state.isAligned)
        #expect(state.displayName.contains("page size"))
    }

    /// IM-098: the producer's number text wins over splitting the formatted display.
    @Test("Value text prefers the stored display value")
    func valueTextPrefersTheStoredCell() {
        let row = LedgerRow(markupID: UUID(), values: [:],
                            displayValues: [LedgerDefaultColumns.valueColumnID: "1 234,5", .planLength: "999 m"],
                            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0), kind: .measurement, measurementKind: .length)
        #expect(LedgerDefaultColumns.valueText(for: row) == "1 234,5")
    }

    /// IM-208: one named palette.
    @Test("The named palette has five named colours")
    func namedPalette() {
        #expect(ZenitNamedPalette.entries.map(\.id) == ["cyan", "blue", "green", "amber", "coral"])
        #expect(ZenitNamedPalette.entry(for: "blue").color == ColorRGBA.Zenit.Dark.blue)
        #expect(ZenitNamedPalette.name(for: ColorRGBA.Zenit.Dark.blue) == ZenitNamedPalette.entry(for: "blue").name)
        #expect(ZenitNamedPalette.color(for: "unknown") == ColorRGBA.Zenit.Dark.cyan)
    }

    /// IM-148: the shared page-list reading.
    @Test("Page ranges parse, accept reversed ranges and name rejected fragments")
    func pageRanges() {
        #expect(PageRangeParser.indices(in: "1, 3-4; 8", pageCount: 10) == IndexSet([0, 2, 3, 7]))
        #expect(PageRangeParser.indices(in: "5-3", pageCount: 10) == IndexSet([2, 3, 4]))
        #expect(PageRangeParser.rejectedFragments(in: "2, x7, 40, 3-", pageCount: 10) == ["x7", "40", "3-"])
        #expect(PageRangeParser.isValid("1-10", pageCount: 10))
        #expect(!PageRangeParser.isValid("", pageCount: 10))
    }

    /// BH-314: a row can say it was read, and old rows still decode.
    @Test("Row provenance is optional and round-trips")
    func rowProvenance() throws {
        var row = LedgerRow(markupID: UUID(), values: [:], displayValues: [:],
                            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0), kind: .count)
        #expect(!row.isRead)
        row.provenance = .read
        let decoded = try JSONDecoder().decode(LedgerRow.self, from: JSONEncoder().encode(row))
        #expect(decoded.isRead)
        #expect(LedgerRowProvenance.read.leaderGlyph != nil)
        #expect(LedgerRowProvenance.measured.accessibilityLabel == nil)
    }
}
