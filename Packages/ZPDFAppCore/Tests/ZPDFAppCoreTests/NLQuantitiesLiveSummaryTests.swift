import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// NL-QTY-10 (ADR-0025): a live quantity table and legend on the sheet.
///
/// Hand-derived: rectangles of 40 × 30 pt at 0.1 m/pt are 12 m² each. Subjects "Slab 0",
/// "Slab 1", "Slab 2" from the shared fixture, one row each.
@Suite("Quantities — live summaries on the sheet")
@MainActor
struct NLQuantitiesLiveSummaryTests {

    let bugs = NLQuantitiesBugTests()

    func summaryRecord(_ fixture: NLQuantitiesBugTests.Fixture) async -> MarkupRecord? {
        await fixture.session.orderedMarkups.first { $0.customValues[LiveSummaryColumn.columnID] != nil }
    }

    @Test("A placed table shows the ledger's group totals, follows a new measurement in the same undo step, and is never a row")
    func liveTable() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30), (40, 30)])
        let placing = try #require(fixture.environment.ledger as? any LedgerSummaryPlacing)
        let rowsBefore = fixture.environment.ledger.rowCount
        let receipt = await placing.placeSummary(.quantities)
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        let placed = try #require(await summaryRecord(fixture))
        #expect(placed.kind == .text)
        #expect(!placed.kind.producesQuantity)
        let text = try #require(placed.caption)
        #expect(text.contains("Slab 0"))
        #expect(text.contains("Slab 1"))
        #expect(text.contains("All rows"))
        #expect(text.contains("As of"))
        await fixture.environment.ledger.refresh()
        #expect(fixture.environment.ledger.rowCount == rowsBefore, "a summary is never a ledger row")

        // Measure one more area: the summary's words change in the same step.
        let page = await fixture.session.pageDescriptors[0]
        let stamp = Date(timeIntervalSince1970: 1_700_000_100)
        try await fixture.environment.commands.perform(.addMarkup(MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Roof", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 20, y: 0), PDFPoint(x: 20, y: 10), PDFPoint(x: 0, y: 10)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )))
        let updated = try #require(await summaryRecord(fixture)?.caption)
        #expect(updated.contains("Roof"), "old output: no live table existed at all")
        // One ⌘Z takes back the measurement and the summary's words together.
        await fixture.environment.commands.undo()
        let restored = try #require(await summaryRecord(fixture)?.caption)
        #expect(!restored.contains("Roof"))
    }

    @Test("A filtered table says it is filtered, with the filter in words and the row counts")
    func filteredTableSaysSo() async throws {
        let fixture = try await bugs.makeFixture()
        fixture.environment.ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text("Slab 1"))
        ]))
        await fixture.environment.ledger.refresh()
        let placing = try #require(fixture.environment.ledger as? any LedgerSummaryPlacing)
        _ = await placing.placeSummary(.quantities)
        let text = try #require(await summaryRecord(fixture)?.caption)
        #expect(text.contains("Filtered"))
        #expect(text.contains("Subject"))
        #expect(text.contains("1 of 3"))
        #expect(!text.contains("Slab 0"))
    }

    @Test("The spec round-trips through its stored cell")
    func specCodec() {
        let spec = LiveSummarySpec(kind: .quantities, title: "Level 2", grouping: ["pageLabel", "subject"], pageOnly: true)
        #expect(LiveSummarySpec(cell: spec.cellValue) == spec)
        #expect(LiveSummarySpec(cell: .text("not json")) == nil)
    }

    // MARK: NL-QTY-09 — summary matrix

    @Test("Subject × Status: every row and column total equals the ledger's grouped totals, exactly")
    func summaryMatrixReconciles() async throws {
        // 12, 12 and 2 m²; rows 0 and 2 accepted, row 1 left at its default status.
        let fixture = try await bugs.makeFixture(sizes: [(40, 30), (40, 30), (20, 10)])
        _ = try await bugs.editor(fixture).applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [fixture.ids[0].rawValue, fixture.ids[2].rawValue], values: [.status: .choice("accepted")]
        ))
        await fixture.environment.ledger.refresh()
        let provider = try #require(fixture.environment.ledger as? any LedgerMatrixProviding)
        let matrix = try await provider.matrix(rows: .subject, columns: .status)
        #expect(matrix.rowTitles == ["Slab 0", "Slab 1", "Slab 2"])
        let accepted = try #require(matrix.columnTitles.firstIndex(of: "Accepted"))
        // Column totals: accepted 12 + 2 = 14 m²; the other status 12 m²; grand 26 m².
        #expect(matrix.columnTotals[accepted].quantity?.value == 14)
        #expect(matrix.grandTotal.quantity?.value == 26)
        #expect(matrix.rowTotals.map { $0.quantity?.value } == [12, 12, 2])
        #expect(matrix.cells[2][accepted].quantity?.value == 2)
        // Σ column totals == grand total == Σ row totals, in Decimal (A5, A7).
        let columnSum = matrix.columnTotals.compactMap { $0.quantity?.value }.reduce(Decimal(0), +)
        let rowSum = matrix.rowTotals.compactMap { $0.quantity?.value }.reduce(Decimal(0), +)
        #expect(columnSum == 26 && rowSum == 26)
        // And the ledger grouped by Status alone carries the same Accepted subtotal.
        fixture.environment.ledger.setGrouping([.status])
        await fixture.environment.ledger.refresh()
        let group = try #require(fixture.environment.ledger.rootGroups.first { $0.title == "Accepted" })
        #expect(group.totals.quantities[LedgerDefaultColumns.valueColumnID]?.value == 14)
    }
}
