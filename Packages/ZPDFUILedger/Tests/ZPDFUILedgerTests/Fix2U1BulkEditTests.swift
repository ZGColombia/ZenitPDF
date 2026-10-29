import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Bug hunt 2, bulk-edit panel and model: BH-036, BH-037, BH-222, BH-223, BH-224, BH-702,
/// BH-703. Nothing here opens a window; the one view test hosts the panel in an
/// `NSHostingView` that is never put in a window.
@MainActor
@Suite("Fix2 U1 bulk edit", .ledgerTierSerialised)
struct Fix2U1BulkEditTests {

    private static let sv = Locale(identifier: "sv_SE")
    private static let en = Locale(identifier: "en_US")

    /// `Repeat ×`-shaped column: a dimensionless number column declared a ratio.
    private static let repeatColumn = LedgerColumn(
        id: .custom("repeat"), title: "Repeat ×", kind: .number, dimension: .ratio,
        width: 60, alignment: .trailing, isEditable: true
    )

    private static func repeatRow(_ index: Int, _ value: Decimal) -> LedgerRow {
        var row = LedgerFixtures.rows[index]
        // What LedgerBridge.quantityCell stores for a dimensionless, non-count column.
        row.values[repeatColumn.id] = .number(value)
        row.displayValues[repeatColumn.id] = "\(value)"
        return row
    }

    private func model(_ rows: [LedgerRow], extra: [LedgerColumn] = []) -> LedgerBulkEditModel {
        LedgerBulkEditModel(rows: rows, columns: LedgerFixtures.columns + extra)
    }

    // MARK: BH-036

    @Test("BH-036: a mixed field keeps its editor, showing Mixed as a placeholder")
    func mixedFieldKeepsEditor() {
        // Old output: `ZPDFInspectorRow(isMixed: state.isMixed && edit == nil)` swapped the
        // TextField for the inert indicator, so no text field existed for a disagreeing
        // subject and the edit that would un-mix it could never be typed.
        let model = model([LedgerFixtures.rows[0], LedgerFixtures.rows[2]])
        #expect(model.displayState(.subject) == .mixed)
        #expect(model.showsMixedPlaceholder(.subject))

        let hosting = NSHostingView(rootView: LedgerBulkEditPanel(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 900)
        hosting.layoutSubtreeIfNeeded()
        let fields = Self.textFields(in: hosting)
        // Subject, Label and Waste Factor all disagree across rows 0 and 2; each must still
        // offer its text field, with "Mixed" as the placeholder. Old output: zero editable
        // text fields in the panel. (Mixed Metric disagrees too, but it is not editable, and
        // since NL-QTY-01 the panel offers only columns whose rows hold a typed value — it
        // used to offer every `custom.` column, editable or not.)
        #expect(fields.count == 3, "every mixed text/number field keeps its editor")
        #expect(fields.allSatisfy { $0.placeholderString == "Mixed" })

        model.setEdit(.text("Slab"), for: .subject)
        #expect(model.showsMixedPlaceholder(.subject) == false)
        #expect(model.summary.changesPerField[.subject] == 2)
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { result.append(field) }
            result.append(contentsOf: textFields(in: subview))
        }
        return result
    }

    // MARK: BH-037

    @Test("BH-037: a dimensioned number column shows the staged quantity, not the old text")
    func stagedQuantityIsEchoed() {
        // Old output: the getter recognised only .number/.currency, so after staging
        // `.quantity(3.5 m)` the field read back "12 m" (the shared text) and the typed
        // digits vanished while an invisible edit stayed staged.
        let model = model([LedgerFixtures.rows[0]])
        let length = LedgerFixtures.columns.first { $0.id == .planLength }!
        model.setEdit(.quantity(.metres(Decimal(string: "3.5")!)), for: .planLength)
        #expect(model.numberText(for: length, locale: Self.en) == "3.5")

        model.setNumberText("4.25", for: length, locale: Self.en)
        #expect(model.numberText(for: length, locale: Self.en) == "4.25")
        #expect(model.edit(for: .planLength) == .quantity(.metres(Decimal(string: "4.25")!)))
    }

    // MARK: BH-222

    @Test("BH-222: selecting different markups drops staged edits")
    func selectionChangeDropsEdits() {
        // Old output: edits survived `setSelection(rows: [C])` and Apply wrote "Slab" onto C.
        let model = model([LedgerFixtures.rows[0], LedgerFixtures.rows[1]])
        model.setEdit(.text("Slab"), for: .subject)
        model.setSelection(rows: [LedgerFixtures.rows[2]])
        #expect(model.edits.isEmpty)
        #expect(model.summary.isEmpty)
    }

    @Test("BH-222: re-adopting the same markups keeps staged edits")
    func sameSelectionKeepsEdits() {
        let model = model([LedgerFixtures.rows[0], LedgerFixtures.rows[1]])
        model.setEdit(.text("Slab"), for: .subject)
        model.setSelection(rows: [LedgerFixtures.rows[1], LedgerFixtures.rows[0]])
        #expect(model.edit(for: .subject) == .text("Slab"))
    }

    // MARK: BH-223

    @Test("BH-223: typing the value every row already has changes nothing")
    func sameRatioIsNoChange() {
        // Old output: the panel staged `.quantity(2, ratio)` against stored `.number(2)`,
        // so the summary read "Applies 1 changed field(s) to 5 markup(s)".
        let rows = (0..<5).map { Self.repeatRow($0, 2) }
        let model = model(rows, extra: [Self.repeatColumn])
        // The field shows "2" already, so writing "2" straight away is the focus echo and
        // stages nothing (R-121 re-fix). Typing through another value reaches the staged shape.
        model.setNumberText("2", for: Self.repeatColumn, locale: Self.en)
        #expect(model.edit(for: Self.repeatColumn.id) == nil)
        model.setNumberText("3", for: Self.repeatColumn, locale: Self.en)
        model.setNumberText("2", for: Self.repeatColumn, locale: Self.en)
        #expect(model.edit(for: Self.repeatColumn.id) == .number(2))
        #expect(model.summary.isEmpty)

        // Even a hand-staged quantity of the same value compares equal.
        model.setEdit(.quantity(DecimalQuantity(value: 2, dimension: .ratio)), for: Self.repeatColumn.id)
        #expect(model.summary.isEmpty)
        model.setEdit(.quantity(DecimalQuantity(value: 3, dimension: .ratio)), for: Self.repeatColumn.id)
        #expect(model.summary.markupCount == 5)
    }

    // MARK: BH-224

    @Test("BH-224: a decimal comma survives the next keystroke in a comma locale")
    func decimalCommaLocale() {
        // Old output: "2,5" staged 2.5, the field echoed "2.5", and the next keystroke
        // "2.50" parsed in sv as 2 — the fraction was lost.
        let model = model([Self.repeatRow(0, 1)], extra: [Self.repeatColumn])
        model.setNumberText("2,", for: Self.repeatColumn, locale: Self.sv)
        #expect(model.numberText(for: Self.repeatColumn, locale: Self.sv) == "2,")
        model.setNumberText("2,5", for: Self.repeatColumn, locale: Self.sv)
        #expect(model.numberText(for: Self.repeatColumn, locale: Self.sv) == "2,5")
        #expect(model.edit(for: Self.repeatColumn.id) == .number(Decimal(string: "2.5")!))
        model.setNumberText("2,50", for: Self.repeatColumn, locale: Self.sv)
        #expect(model.edit(for: Self.repeatColumn.id) == .number(Decimal(string: "2.5")!))
    }

    @Test("BH-224: trailing garbage stages nothing and marks the field invalid")
    func garbageStagesNothing() {
        // Old output: "12abc" staged 12.
        let model = model([Self.repeatRow(0, 1)], extra: [Self.repeatColumn])
        model.setNumberText("12abc", for: Self.repeatColumn, locale: Self.en)
        #expect(model.edit(for: Self.repeatColumn.id) == nil)
        #expect(model.invalidNumberColumns.contains(Self.repeatColumn.id))
        #expect(model.numberText(for: Self.repeatColumn, locale: Self.en) == "12abc")

        model.setNumberText("", for: Self.repeatColumn, locale: Self.en)
        #expect(model.invalidNumberColumns.isEmpty)
        // R-121: an emptied field is a cleared value and stays empty. It used to unstage and
        // echo the shared "1" back into the field, which is what made a number impossible to
        // blank and made the field rewrite itself mid-typing.
        #expect(model.numberText(for: Self.repeatColumn, locale: Self.en) == "")
        #expect(model.edit(for: Self.repeatColumn.id) == .empty)
        model.leaveUnchanged(Self.repeatColumn.id)
        #expect(model.numberText(for: Self.repeatColumn, locale: Self.en) == "1", "Leave Unchanged shows the shared value again")
        #expect(model.edit(for: Self.repeatColumn.id) == nil)
    }

    @Test("BH-224: the parser is exact and strict")
    func parser() {
        #expect(LedgerBulkEditModel.parseDecimal("1.15") == Decimal(string: "1.15"))
        #expect(LedgerBulkEditModel.parseDecimal("1,15") == Decimal(string: "1.15"))
        #expect(LedgerBulkEditModel.parseDecimal("1.15") == Decimal(string: "1.15"))
        #expect(LedgerBulkEditModel.parseDecimal("2.") == 2)
        #expect(LedgerBulkEditModel.parseDecimal("abc") == nil)
        #expect(LedgerBulkEditModel.parseDecimal("12abc") == nil)
        #expect(LedgerBulkEditModel.parseDecimal("") == nil)
    }

    // MARK: BH-702

    @Test("BH-702: a value beside a blank cell is mixed, not uniform")
    func blankIsAValue() {
        // Old output: `.uniform("Slab")` — the blank row was skipped by the fold.
        var blank = LedgerFixtures.rows[1]
        blank.values[.subject] = .empty
        blank.displayValues[.subject] = ""
        let model = model([LedgerFixtures.rows[0], blank])
        #expect(model.displayState(.subject) == .mixed)
        #expect(model.valueState(.subject) == .mixed)

        var alsoBlank = LedgerFixtures.rows[2]
        alsoBlank.values[.subject] = .empty
        alsoBlank.displayValues[.subject] = ""
        let empty = self.model([blank, alsoBlank])
        #expect(empty.displayState(.subject) == .empty)
        #expect(empty.valueState(.subject) == .empty)
    }

    // MARK: BH-703

    @Test("BH-703: a currency column without a declared currency uses the rows' code or refuses")
    func currencyWithoutDimension() {
        // Old output: `.number(value)` was staged, which LedgerBridge.domainCellValue drops
        // for a currency column, so Apply reported a change and the receipt said none.
        let column = LedgerColumn(
            id: .custom("price"), title: "Price", kind: .currency, width: 80,
            alignment: .trailing, isEditable: true
        )
        var priced = LedgerFixtures.rows[0]
        priced.values[column.id] = .currency(amount: 10, code: "EUR")
        let withCode = model([priced], extra: [column])
        withCode.setNumberText("12", for: column, locale: Self.en)
        #expect(withCode.edit(for: column.id) == .currency(amount: 12, code: "EUR"))

        let noCode = model([LedgerFixtures.rows[0]], extra: [column])
        noCode.setNumberText("12", for: column, locale: Self.en)
        #expect(noCode.edit(for: column.id) == nil)
        #expect(noCode.invalidNumberColumns.contains(column.id))
        #expect(noCode.summary.isEmpty)
    }
}

/// The bulk-edit number field types in the column's display unit.
@MainActor
@Suite("Fix2 U1 bulk edit display units", .ledgerTierSerialised)
struct Fix2U1BulkEditUnitTests {

    @Test("A number typed into a millimetre column is staged as metres and shown back in mm")
    func displayUnitRoundTrip() {
        let column = LedgerColumn(
            id: .custom("offset"), title: "Offset", kind: .number, dimension: .length,
            width: 80, alignment: .trailing, isEditable: true, displayUnitSymbol: "mm"
        )
        let model = LedgerBulkEditModel(rows: [LedgerFixtures.rows[0]], columns: LedgerFixtures.columns + [column])
        model.setNumberText("500", for: column, locale: Locale(identifier: "en_US"))
        #expect(model.edit(for: column.id) == .quantity(.metres(Decimal(string: "0.5")!)))
        model.setEdit(.quantity(.metres(Decimal(string: "1.25")!)), for: column.id)
        #expect(model.numberText(for: column, locale: Locale(identifier: "en_US")) == "1250")
    }
}
