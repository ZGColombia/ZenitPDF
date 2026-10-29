import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Regression tests for the `.zpdfjson` reconciliation findings: BH-133, BH-134, BH-513, BH-514.
@Suite("Fix2 E1 reconciliation", .sharedHeap)
struct Fix2E1ReconciliationTests {

    private func document(_ report: LedgerReport) throws -> ZenitInterchangeDocument {
        ZenitJSONExporter().document(from: try ExportFixture.projection(report))
    }

    private func reread(_ text: String) throws -> ZenitInterchangeDocument {
        try ZenitInterchangeImport.read(Data(text.utf8), fileName: "e1.zpdfjson").0
    }

    @Test("BH-133: the same takeoff shown in another display unit reconciles as identical")
    func displayUnitChangeIsNotADifference() throws {
        let ledger = try document(try ExportFixture.goldenReport())
        let text = String(decoding: ZenitJSONExporter().encode(ledger), as: UTF8.self)
        #expect(text.contains("\"unit\": \"ft²\""))
        // The footprint column exported in square metres instead of square feet: every raw is
        // the same SI value, only the display symbol changed.
        let metric = try reread(text.replacingOccurrences(of: "\"unit\": \"ft²\"", with: "\"unit\": \"m²\""))
        let result = ZenitLedgerReconciliation.compare(imported: metric, against: ledger)
        // Old: rowsDiffering == 6 and isExactMatch == false — `a.unit == b.unit` failed on
        // "m²" vs "ft²" for every footprint cell although every raw was identical.
        #expect(result.rowsDiffering == 0)
        #expect(result.isExactMatch)

        // A different *dimension* under the same raw is still a difference: 10 m is not 10 m².
        let length = try reread(text.replacingOccurrences(of: "\"unit\": \"ft²\"", with: "\"unit\": \"m\""))
        let differs = ZenitLedgerReconciliation.compare(imported: length, against: ledger)
        #expect(differs.rowsDiffering == 6)
        // And a different currency is a different value.
        #expect(!ZenitLedgerReconciliation.agree(
            .number(.init(raw: "100", display: "100.00", unit: "SEK")),
            .number(.init(raw: "100", display: "100.00", unit: "EUR"))
        ))
        #expect(ZenitLedgerReconciliation.agree(
            .number(.init(raw: "0.50", display: "500", unit: "mm")),
            .number(.init(raw: "0.5", display: "0.50", unit: "m"))
        ))
    }

    @Test("BH-134: a difference names the stored value in its stored unit, then what was shown")
    func differenceIsLabelledInTheRightUnit() throws {
        let cell = ZenitInterchangeDocument.Cell.number(.init(raw: "0.0125", display: "12.5", unit: "mm"))
        // Old: "0.0125 mm" — a metre value wearing the millimetre label, 1000x too small.
        #expect(ZenitLedgerReconciliation.describe(cell) == "0.0125 m (12.5 mm)")
        let count = ZenitInterchangeDocument.Cell.number(.init(raw: "0.4449", display: "0.44", unit: ""))
        #expect(ZenitLedgerReconciliation.describe(count) == "0.4449 (0.44)")

        let ledger = try document(try ExportFixture.goldenReport())
        let text = String(decoding: ZenitJSONExporter().encode(ledger), as: UTF8.self)
        // Footprint row 0 is 10 m², shown as 107.64 ft².
        let changed = try reread(text.replacingOccurrences(of: "\"raw\": \"10\",", with: "\"raw\": \"11\","))
        let result = ZenitLedgerReconciliation.compare(imported: changed, against: ledger)
        let difference = try #require(result.differences.first { $0.columnKey == "footprint" })
        // Old: "10 ft²".
        #expect(difference.inLedger == "10 m^2 (107.64 ft²)")
    }

    @Test("BH-513: differences are listed in the file's row order and the cut keeps the same ones")
    func differencesAreDeterministic() throws {
        let ledger = try document(try ExportFixture.syntheticReport(rowCount: 300, grouped: true))
        let text = String(decoding: ZenitJSONExporter().encode(ledger), as: UTF8.self)
        // Every cost cell of every row in another currency: 300 differing rows, one cell each.
        let imported = try reread(text.replacingOccurrences(of: "\"unit\": \"SEK\"", with: "\"unit\": \"EUR\""))
        let result = ZenitLedgerReconciliation.compare(imported: imported, against: ledger)
        #expect(result.rowsDiffering == 300)
        #expect(result.differences.count == ZenitLedgerReconciliation.maximumReportedDifferences)
        let fileOrder = ZenitLedgerReconciliation.orderedRows(imported).map(\.0)
        // Old: the rows came out of a Dictionary, in an order that changes with every process,
        // so a different 200 of the 300 were reported each run.
        #expect(result.differences.map(\.markupID) == Array(fileOrder.prefix(200)))
        let again = ZenitLedgerReconciliation.compare(imported: imported, against: ledger)
        #expect(again.differences == result.differences)
    }

    @Test("BH-514: a row with fewer cells than its counterpart is a difference, not a trap")
    func narrowRowIsReportedNotTrapped() throws {
        let ledger = try document(try ExportFixture.goldenReport())
        let narrow = ledger.rows.enumerated().map { offset, row in
            offset == 0
                ? ZenitInterchangeDocument.Row(
                    markupID: row.markupID, index: row.index, groupPath: row.groupPath,
                    cells: Array(row.cells.dropLast())
                )
                : row
        }
        let imported = ZenitInterchangeDocument(
            schemaVersion: ledger.schemaVersion,
            generatedAt: ledger.generatedAt,
            producer: ledger.producer,
            document: ledger.document,
            ledger: ledger.ledger,
            numberLocale: ledger.numberLocale,
            columns: ledger.columns,
            groups: ledger.groups,
            rows: narrow,
            grandTotals: ledger.grandTotals
        )
        // Old: Fatal error: Index out of range at `ledgerRow.cells[index]` when the file's row
        // is the wider one; here the ledger side is compared against the narrow file too.
        let result = ZenitLedgerReconciliation.compare(imported: imported, against: ledger)
        #expect(result.rowsDiffering == 1)
        let difference = try #require(result.differences.first)
        #expect(difference.columnKey == ledger.columns.last?.key)
        #expect(difference.inFile == ZenitLedgerReconciliation.missingCellText)
        let reversed = ZenitLedgerReconciliation.compare(imported: ledger, against: imported)
        #expect(reversed.rowsDiffering == 1)
        #expect(reversed.differences.first?.inLedger == ZenitLedgerReconciliation.missingCellText)
    }
}
