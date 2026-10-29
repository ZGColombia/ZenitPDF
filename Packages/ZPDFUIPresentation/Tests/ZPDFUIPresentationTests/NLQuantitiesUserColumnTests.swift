import Foundation
import Testing
@testable import ZPDFUIPresentation

/// NL-QTY-01: one rule for "user column", carried on the column rather than read off a prefix.
@Suite("Quantities — user column rule")
struct NLQuantitiesUserColumnTests {

    @Test("A column built without saying falls back to the custom. prefix, as before")
    func defaultsFollowThePrefix() {
        let custom = LedgerColumn(id: .custom("fee"), title: "Fee", kind: .number, width: 80, isEditable: true)
        #expect(custom.isUserDefined)
        #expect(custom.holdsUserValues)
        let readOnly = LedgerColumn(id: .custom("sum"), title: "Sum", kind: .number, width: 80)
        #expect(readOnly.isUserDefined)
        #expect(!readOnly.holdsUserValues, "a column nobody may edit holds no typed values")
        let builtIn = LedgerColumn(id: .costCode, title: "Cost Code", kind: .text, width: 80, isEditable: true)
        #expect(!builtIn.isUserDefined)
    }

    @Test("An imported column is a user column when its producer says so, whatever its key")
    func producerDecides() {
        let imported = LedgerColumn(
            id: LedgerColumnID("zenit.import.1234"), title: "Door type", kind: .text, width: 80,
            isEditable: true, isUserDefined: true, holdsUserValues: true
        )
        // Old rule: `id.isCustom` was false here, so the column was hidden and uneditable.
        #expect(!imported.id.isCustom)
        #expect(imported.isUserDefined)
        #expect(LedgerDefaultColumns.arranged([imported]).first { $0.id == imported.id }?.visible == true)
    }

    @Test("A column encoded before the flags existed decodes with the defaults")
    func decodesOldPayloads() throws {
        let json = """
        {"id":"zenit.import.9","title":"Door","kind":"text","width":80,"pinned":false,"visible":true,
         "alignment":"leading","isEditable":true,"choices":[],"displayUnitSymbol":""}
        """
        let column = try JSONDecoder().decode(LedgerColumn.self, from: Data(json.utf8))
        #expect(!column.isUserDefined)
        let roundTrip = try JSONDecoder().decode(LedgerColumn.self, from: JSONEncoder().encode(
            LedgerColumn(id: "x", title: "X", kind: .text, width: 1, isUserDefined: true, holdsUserValues: false)
        ))
        #expect(roundTrip.isUserDefined)
        #expect(!roundTrip.holdsUserValues)
    }
}
