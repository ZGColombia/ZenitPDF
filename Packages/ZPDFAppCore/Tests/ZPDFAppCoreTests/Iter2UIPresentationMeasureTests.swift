import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// The presentation ↔ domain seam.
///
/// S-089 — the dimension bridge dropped the ADR-0014 `ratio` tag, so a "Ratio / factor" column
/// became a count column whose factors summed into totals.
/// S-090 — a row read from a schedule table carried no read marker in the Quantity Ledger.
@Suite("Iteration 2 — measurement presentation, bridge")
@MainActor
struct Iter2UIPresentationMeasureTests {

    let bugs = NLQuantitiesBugTests()

    // MARK: S-089

    /// Old output: `Domain.Dimension(shown: .ratio) == .count` and
    /// `Shown.Dimension(domain: .ratio) == .count` — only lengthPower, angle and currency crossed.
    @Test("S-089: the dimension seam carries the ratio tag both ways and still copies every other field")
    func ratioCrossesTheSeam() {
        #expect(Domain.Dimension(shown: Shown.Dimension.ratio) == Domain.Dimension.ratio)
        #expect(Shown.Dimension(domain: Domain.Dimension.ratio) == Shown.Dimension.ratio)
        #expect(Domain.Dimension(shown: Shown.Dimension.count) == Domain.Dimension.count)
        #expect(Shown.Dimension(domain: Domain.Dimension.count) == Shown.Dimension.count)
        for dimension in [
            Domain.Dimension.length, .area, .volume, .angle,
            .currency("SEK"), .currencyRate("SEK", perLengthPower: 2)
        ] {
            #expect(Domain.Dimension(shown: Shown.Dimension(domain: dimension)) == dimension, "\(dimension)")
        }
        // A slope ratio of 0.25 stays a ratio on the way to the screen and back.
        let slope = Domain.Quantity(value: Decimal(string: "0.25")!, dimension: .ratio)
        #expect(Shown.Quantity(domain: slope).dimension.ratio)
        #expect(Domain.Quantity(shown: Shown.Quantity(domain: slope)) == slope)
    }

    /// Old output: the Waste column crossed into the domain as `.count`, so the Column Manager
    /// reopened it as "Count (pcs)", the standard plan carried a `.sum` key for it and the
    /// presented column showed a Sum aggregate — waste factors added into group and grand totals.
    @Test("S-089: a Ratio / factor column stays a ratio: the manager reopens it as one and it never sums")
    func ratioColumnStaysARatio() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30)])
        let manager = try #require(fixture.environment.ledger as? any LedgerColumnManaging)
        let waste = LedgerColumnID.custom(UUID().uuidString)
        let receipt = await manager.applyColumnSpecs([
            LedgerColumnSpec(id: waste, title: "Waste", kind: .number, dimension: .ratio, decimalPlaces: 2)
        ], actionName: "Add Column")
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")

        #expect(manager.userColumnSpecs.first?.dimension == .ratio)
        let set = await fixture.session.ledgerColumns
        let definition = try #require(set.column(key: waste.rawValue))
        #expect(definition.dimension == ZPDFContracts.QuantityDimension.ratio)
        #expect(!LedgerAggregationPlan.sums(definition))
        #expect(!LedgerAggregationPlan.standard(for: set).keys.contains(AggregateKey(column: definition.id, function: .sum)))
        let presented = try #require(fixture.environment.ledger.columns.first { $0.id == waste })
        #expect(presented.dimension == .ratio)
        #expect(presented.aggregate == nil)
    }

    // MARK: S-090

    /// A read row exactly as `TableImportAcceptance` lands one: a note, no tool, provenance
    /// `.read`, with the table row's text as its derivation.
    static func readRecord(documentID: DocumentID, pageID: PageID) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .note,
            subject: "D1 Door 900",
            provenance: .read,
            derivation: QuantityDerivation(
                sourceMarkupID: nil,
                formulaText: "D1 Door 900 4",
                inputs: ["Mark": "D1", "Qty": "4"],
                originIdentifier: "page test rect 0,0 10x10 row 1"
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// Old output: the Type cell read the markup kind's raw token `note`, `row.provenance` was
    /// nil (nothing ever set it), and Explain gave the row a measured-on-sheet line or nothing —
    /// although the import's own status note promised rows "marked ⌐".
    @Test("S-090: a row read from a table leads its Type cell with ⌐, carries its provenance, and Explain names the source")
    func readRowIsMarked() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30)])
        let measured = try #require(await fixture.session.markup(fixture.ids[0]))
        let read = Self.readRecord(documentID: measured.documentID, pageID: measured.pageID)
        _ = try await fixture.session.applyBatch([.addMarkup(read)])
        await fixture.environment.ledger.refresh()

        let ledger = fixture.environment.ledger
        let readRow = try #require(ledger.index(of: read.id.rawValue).flatMap { ledger.row(at: $0) })
        #expect(readRow.displayValue(.icon) == "\u{2310} Read from table")
        #expect(readRow.provenance == .read)
        #expect(readRow.isRead)

        // A measured row is untouched: its tool's name, no marker, no provenance.
        let measuredRow = try #require(ledger.index(of: measured.id.rawValue).flatMap { ledger.row(at: $0) })
        #expect(measuredRow.displayValue(.icon) == "Area")
        #expect(measuredRow.provenance == nil)

        let explaining = try #require(ledger as? any LedgerExplaining)
        let explanation = await explaining.explain([read.id.rawValue])
        #expect(explanation.rows.map(\.provenance) == ["Read from a table on the drawing, not measured"])
    }
}
