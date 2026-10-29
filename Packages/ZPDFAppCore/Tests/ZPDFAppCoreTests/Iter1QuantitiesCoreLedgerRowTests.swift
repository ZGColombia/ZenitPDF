import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// NL-MEASURE-10's ledger half (ADR-0035). A
/// markup whose parameters carry a `displayOverride` shows its row in those units, through the one
/// formatter type; every other row stays in the project's units.
@Suite("Iteration 1 — quantities core, ledger rows")
struct Iter1QuantitiesCoreLedgerRowTests {

    static let documentID = DocumentID(UUID(uuidString: "00000000-0000-4000-8000-00000000D001")!)
    static let pageID = PageID(UUID(uuidString: "00000000-0000-4000-8000-00000000D002")!)

    /// A 3.81 m length: exactly 12.5 ft (3.81 / 0.3048), so the imperial text is 12'-6".
    static func length(_ byte: UInt8, displayOverride: DisplayUnitPolicy?) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000000%02X", byte))!),
            documentID: documentID, pageID: pageID, kind: .measurement, tool: .length,
            subject: "Rebar", author: "t",
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 3.81, y: 0)]),
            parameters: MeasurementParameters(displayOverride: displayOverride),
            measurement: MeasurementResult(values: [.planLength: .length(Decimal(string: "3.81")!)]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    /// Old output: both rows read 12'-6" in an imperial project — the override had no bytes of
    /// its own (`display` defaults to metric) and LedgerBridge never looked. Now the Rebar row
    /// set to metres with two decimals reads 3.81 m, the other still 12'-6", and the stored SI
    /// value is the same 3.81 in both.
    @Test("NL-MEASURE-10: a row with its own display units is formatted in them; the rest keep the project's")
    func overrideRowUsesItsOwnUnits() throws {
        let metresTwoPlaces = DisplayUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre, precision: .decimalPlaces(2))
        let store = try LedgerStore(
            markups: [Self.length(1, displayOverride: nil), Self.length(2, displayOverride: metresTwoPlaces)],
            columns: LedgerColumnSet.standard()
        )
        let view = store.makeView(LedgerViewSpec())
        let project = QuantityFormatter(units: .imperial)
        let planLength = LedgerColumnID(try #require(store.columns.column(standard: .planLength)).key)

        let rows = (0..<view.rowCount).map { LedgerBridge.row(view: view, displayIndex: $0, formatter: project) }
        let plain = try #require(rows.first { $0.markupID == Self.length(1, displayOverride: nil).id.rawValue })
        let rebar = try #require(rows.first { $0.markupID == Self.length(2, displayOverride: nil).id.rawValue })

        #expect(plain.displayValues[planLength] == "12'-6\"")
        #expect(rebar.displayValues[planLength] == "3.81")
        #expect(rebar.displayValues[LedgerDefaultColumns.unitColumnID] == "m")
        // The value behind both cells is the same SI quantity.
        #expect(plain.values[planLength] == rebar.values[planLength])
    }
}
