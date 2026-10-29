import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-QTY-15 (phase 1): the whole-project summary over open drawings, held to QUALITY_BAR A36.
/// Hand-derived: drawing A has Slab 0 = 12 m² and Slab 1 = 12 m²; drawing B has Slab 0 = 2 m².
/// Combined: Slab 0 = 14 m², Slab 1 = 12 m²; the combined total 26 m² is the exact sum of A's
/// 24 and B's 2.
@Suite("Quantities — whole-project summary")
@MainActor
struct NLQuantitiesProjectSummaryTests {

    let bugs = NLQuantitiesBugTests()

    @Test("Two open drawings combine subject by subject, exactly")
    func combinesExactly() async throws {
        let a = try await bugs.makeFixture(sizes: [(40, 30), (40, 30)])
        let b = try await bugs.makeFixture(sizes: [(20, 10)])
        let aID = UUID(), bID = UUID()
        a.environment.installProjectLedgerSources(
            [b.environment.projectLedgerSource(documentID: bID, title: "B")], ownDocumentID: aID, ownTitle: "A"
        )
        let summarizing = try #require(a.environment.ledger as? any LedgerProjectSummarizing)
        #expect(summarizing.hasProjectSources)
        let summary = await summarizing.projectSummary()
        #expect(summary.drawings.map(\.title) == ["A", "B"])
        let combined = Dictionary(uniqueKeysWithValues: summary.combined.map { ($0.subject, $0.quantity.value) })
        #expect(combined == ["Slab 0": 14, "Slab 1": 12])
        let perDrawing = summary.drawings.flatMap(\.totals).map(\.quantity.value).reduce(Decimal(0), +)
        let all = summary.combined.map(\.quantity.value).reduce(Decimal(0), +)
        #expect(perDrawing == 26 && all == 26)
        #expect(summary.combined.allSatisfy { !$0.text.isEmpty })
    }

    @Test("The same subject in two units stays two lines, never converted")
    func unitsNeverMix() {
        let area = LedgerSubjectTotal(subject: "Wall", quantity: DecimalQuantity(value: 10, dimension: .area), rowCount: 1)
        let length = LedgerSubjectTotal(subject: "Wall", quantity: DecimalQuantity(value: 4, dimension: .length), rowCount: 1)
        let combined = ProjectLedgerCombiner.combine([
            .init(documentID: UUID(), title: "A", totals: [area]),
            .init(documentID: UUID(), title: "B", totals: [length, area])
        ], formatter: QuantityFormatter())
        #expect(combined.count == 2)
        #expect(combined.first { $0.quantity.dimension == .area }?.quantity.value == 20)
        #expect(combined.first { $0.quantity.dimension == .length }?.quantity.value == 4)
    }

    @Test("Explain: each selected row's value and provenance, and the exact sum per unit")
    func explainSelection() async throws {
        // 12 + 2 = 14 m².
        let f = try await bugs.makeFixture(sizes: [(40, 30), (40, 30), (20, 10)])
        let explaining = try #require(f.environment.ledger as? any LedgerExplaining)
        let e = await explaining.explain([f.ids[0].rawValue, f.ids[2].rawValue])
        #expect(e.rows.count == 2)
        #expect(e.rows.compactMap { $0.value?.value }.reduce(Decimal(0), +) == 14)
        #expect(e.rows.allSatisfy { $0.provenance.contains("A-101") })
        #expect(e.totals.count == 1)
        // 12 m² + 2 m², exact, shown with its unit (round 2 — it used to read "14.00").
        #expect(e.totals == ["14.00 m²"])
    }
}
