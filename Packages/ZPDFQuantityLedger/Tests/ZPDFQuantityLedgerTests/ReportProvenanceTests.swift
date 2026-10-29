import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// ADR-0012 rule 4 through the report chain: a row's provenance claim — measured, derived,
/// or read — rides ``LedgerReportRow`` so every exporter can print it from the one place.
///
/// Two claims, deliberately separate:
///
/// 1. The builder copies the store's provenance onto each report row, so a measured row and
///    a read row leave the builder distinguishable.
/// 2. The field is additive: a `LedgerReportRow` built the way every pre-ADR construction
///    was built still compiles and still claims `.measured`.
@Suite("Report row provenance (ADR-0012 rule 4)")
struct ReportProvenanceTests {

    /// One measured row and one `.read` row (the shape a table import lands as), through
    /// `LedgerReportBuilder`. Both claims must survive, on the right rows.
    @Test("A report over one measured and one read row carries both provenances")
    func measuredAndReadRowsKeepTheirClaims() throws {
        let columns = try HandBuiltLedger.makeColumnSet()
        let documentID = DocumentID(SyntheticLedger.deterministicUUID(-1))
        let pageID = PageID(SyntheticLedger.deterministicUUID(-2))

        let measured = MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(1)),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            subject: "Wall A",
            customValues: [
                HandBuiltLedger.valueColumn: .number(
                    DecimalQuantity(value: 3, dimension: .count)
                )
            ],
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )
        // The exact shape TableImportAcceptance produces: no tool, no geometry, no
        // measurement — a `.read` claim with the OCR text in its derivation.
        let read = MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(2)),
            documentID: documentID,
            pageID: pageID,
            kind: .note,
            subject: "D1",
            customValues: [HandBuiltLedger.textColumn: .text("910x2100")],
            provenance: .read,
            derivation: QuantityDerivation(
                formulaText: "D1 910x2100 IMPORTED-SCHEDULE",
                inputs: ["Column 1": "D1"],
                originIdentifier: "page test rect 0,0 100x100 row 1"
            ),
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )

        let store = try LedgerStore(markups: [measured, read], columns: columns)
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([HandBuiltLedger.valueColumn]))
        )
        let report = LedgerReportBuilder(
            timestamps: FixedTimestampProvider(SyntheticLedger.epoch)
        ).makeReport(view)

        let rows = report.allRows()
        #expect(rows.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.markupID, $0.provenance) })
        #expect(byID[measured.id] == .measured)
        #expect(byID[read.id] == .read)
        // Both claims present — an exporter reading this report can never flatten the
        // distinction by accident, only by ignoring the field.
        #expect(Set(rows.map(\.provenance)) == Set([.measured, .read]))
    }

    /// The additive-init proof: the argument list every construction used before ADR-0012
    /// still compiles, and what it builds still claims `.measured`.
    @Test("A row built without naming provenance compiles and claims .measured")
    func preexistingConstructionShapeStillCompiles() {
        let row = LedgerReportRow(
            markupID: MarkupID(SyntheticLedger.deterministicUUID(3)),
            storeIndex: 0,
            groupPath: [],
            cells: []
        )
        #expect(row.provenance == .measured)
    }
}
