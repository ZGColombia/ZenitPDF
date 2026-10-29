import Foundation
import Observation
import ZPDFUIPresentation

/// The state of one field across a multi-row selection.
public enum LedgerMixedValue<Value: Hashable & Sendable>: Hashable, Sendable {

    /// No row carries a value.
    case empty
    /// Every row agrees.
    case uniform(Value)
    /// The rows disagree, so the field must show a mixed indicator rather than one value.
    case mixed

    /// The shared value, when the rows agree.
    public var uniformValue: Value? {
        if case let .uniform(value) = self { return value }
        return nil
    }

    /// Whether the rows disagree.
    public var isMixed: Bool { self == .mixed }

    /// Folds a sequence of per-row values into a mixed state.
    public static func folding<S: Sequence>(_ values: S) -> LedgerMixedValue<Value> where S.Element == Value? {
        var result: LedgerMixedValue<Value> = .empty
        for value in values {
            guard let value else { continue }
            switch result {
            case .empty:
                result = .uniform(value)
            case let .uniform(existing):
                if existing != value { return .mixed }
            case .mixed:
                return .mixed
            }
        }
        return result
    }
}

/// What a bulk edit will actually do, stated before it happens.
public struct LedgerBulkChangeSummary: Hashable, Sendable {

    /// Number of markups that change at least one field.
    public let markupCount: Int
    /// Number of fields being written.
    public let fieldCount: Int
    /// How many markups each field changes.
    public let changesPerField: [LedgerColumnID: Int]

    /// Creates a summary.
    public init(markupCount: Int, fieldCount: Int, changesPerField: [LedgerColumnID: Int]) {
        self.markupCount = markupCount
        self.fieldCount = fieldCount
        self.changesPerField = changesPerField
    }

    /// An empty summary.
    public static let empty = LedgerBulkChangeSummary(markupCount: 0, fieldCount: 0, changesPerField: [:])

    /// Whether the edit would do nothing.
    public var isEmpty: Bool { markupCount == 0 || fieldCount == 0 }

    /// The confirmation sentence shown above the Apply button.
    public var message: String {
        guard !isEmpty else {
            return NSLocalizedString(
                "Nothing to change yet. Edit a field above.",
                comment: "Bulk edit confirmation when no field has been changed"
            )
        }
        return LedgerPlurals.bulkEditApplies(fields: fieldCount, markups: markupCount)
    }
}

/// Drives the bulk-edit panel over a multi-row selection.
///
/// A field the selection disagrees about starts out mixed and stays mixed until the user
/// deliberately writes it, so a bulk edit can never flatten values the user never looked
/// at. Before anything is written the panel states exactly how many markups change.
@MainActor
@Observable
public final class LedgerBulkEditModel {

    /// The selected rows.
    public private(set) var rows: [LedgerRow]
    /// Column definitions.
    public private(set) var columns: [LedgerColumn]
    /// Pending cell edits, keyed by column.
    public private(set) var edits: [LedgerColumnID: LedgerCellValue] = [:]
    /// A pending colour change, kept apart because colour is a markup property, not a cell.
    public var colorEdit: ColorRGBA?

    /// Called when the user confirms the edit.
    public var onApply: (@MainActor (_ edits: [LedgerColumnID: LedgerCellValue], _ color: ColorRGBA?, _ markupIDs: Set<UUID>) -> Void)?

    /// Creates the model.
    public init(rows: [LedgerRow], columns: [LedgerColumn]) {
        self.rows = rows
        self.columns = columns
    }

    /// Raw text typed into each number field, so the field shows exactly what was typed —
    /// a trailing decimal separator, a comma in a decimal-comma locale — rather than an echo
    /// re-formatted from the staged value after every keystroke (BH-037, BH-224).
    public private(set) var numberDrafts: [LedgerColumnID: String] = [:]

    /// Number fields whose typed text could not become a value: text that is not a number,
    /// or an amount for a currency column whose currency is unknown (BH-224, BH-703). Such
    /// a field stages nothing, and the panel says why.
    public private(set) var invalidNumberColumns: Set<LedgerColumnID> = []

    /// Raw text typed into each text field, so an emptied field stays empty while the person
    /// types instead of snapping back to the selection's shared value (R-121).
    public private(set) var textDrafts: [LedgerColumnID: String] = [:]

    /// Fields the person emptied that cannot be blank — Subject and Status, whose apply path
    /// has no "cleared" form. Such a field stages nothing, and the panel says so (R-121).
    public private(set) var refusedBlankColumns: Set<LedgerColumnID> = []

    /// Columns a bulk edit cannot clear. The application writes Subject only from `.text` and
    /// Status only from a choice (`AppLedgerBulkEdit`), so a staged `.empty` for either would be
    /// counted in the summary and then silently ignored on Apply.
    public static let unclearableColumns: Set<LedgerColumnID> = [.subject, .status]

    /// Whether a bulk edit may blank this column across the selection (R-121).
    public func canClear(_ column: LedgerColumn) -> Bool {
        !Self.unclearableColumns.contains(column.id)
    }

    /// Replaces the selection, dropping any pending edits that no longer apply.
    ///
    /// Staged edits belong to the rows they were typed for. A selection of *different*
    /// markups drops them, so a value staged for A and B can never be applied to C that was
    /// clicked afterwards (BH-222). Re-adopting the same markups — the refresh after Apply,
    /// or a row whose content changed — keeps them.
    public func setSelection(rows newRows: [LedgerRow]) {
        let changedMarkups = Set(newRows.map(\.markupID)) != markupIDs
        rows = newRows
        if newRows.isEmpty || changedMarkups { clearEdits() }
    }

    /// Replaces the column definitions.
    public func setColumns(_ newColumns: [LedgerColumn]) {
        columns = newColumns
    }

    /// Markup identifiers in the selection.
    public var markupIDs: Set<UUID> { Set(rows.map(\.markupID)) }

    /// The fields the panel offers, in panel order.
    public var editableColumns: [LedgerColumn] {
        let standard: [LedgerColumnID] = [.subject, .label, .status]
        var result = standard.compactMap { id in columns.first { $0.id == id } }
        // NL-QTY-01: every column whose rows hold a typed value — an imported column, Cost
        // Code, Unit Cost — not only the ones whose identifier starts with `custom.`. A
        // built-in estimating column joins the panel once it is shown in the ledger, so a
        // project that never prices anything is not handed six empty fields.
        result.append(contentsOf: columns.filter {
            $0.holdsUserValues && $0.kind.isDirectlyEditable && ($0.isUserDefined || $0.visible)
        })
        return result
    }

    /// The current shared value of a column, as display text.
    ///
    /// A blank cell is a value of its own: "Slab" beside an empty subject is a selection
    /// that disagrees, not one that agrees on "Slab" (BH-702). Only a selection that is blank
    /// on every row is ``LedgerMixedValue/empty``.
    public func displayState(_ columnID: LedgerColumnID) -> LedgerMixedValue<String> {
        let folded = LedgerMixedValue.folding(rows.map { row -> String? in row.displayValue(columnID) })
        return folded == .uniform("") ? .empty : folded
    }

    /// The current shared raw value of a column, with a blank cell counted as a value exactly
    /// as ``displayState(_:)`` counts it.
    public func valueState(_ columnID: LedgerColumnID) -> LedgerMixedValue<LedgerCellValue> {
        let folded = LedgerMixedValue.folding(rows.map { row -> LedgerCellValue? in row.value(columnID) })
        return folded == .uniform(.empty) ? .empty : folded
    }

    /// Whether a field should read "Mixed": the rows disagree and nothing is staged yet.
    ///
    /// The field's editor stays on screen either way — it is the only way to stage the edit
    /// that un-mixes the selection (BH-036). "Mixed" is its placeholder, not its replacement.
    public func showsMixedPlaceholder(_ columnID: LedgerColumnID) -> Bool {
        displayState(columnID).isMixed && edit(for: columnID) == nil
    }

    /// The current shared colour of the selection.
    public var colorState: LedgerMixedValue<ColorRGBA> {
        LedgerMixedValue.folding(rows.map { Optional($0.colorRGBA) })
    }

    /// Stages an edit, or clears it when `value` is `nil`.
    ///
    /// Any typed number draft for the column is dropped: the edit now comes from somewhere
    /// else (a menu, a reset), and the field should show it.
    public func setEdit(_ value: LedgerCellValue?, for columnID: LedgerColumnID) {
        numberDrafts.removeValue(forKey: columnID)
        textDrafts.removeValue(forKey: columnID)
        invalidNumberColumns.remove(columnID)
        refusedBlankColumns.remove(columnID)
        stage(value, for: columnID)
    }

    /// Blanks a field across the selection: stages `.empty`, which the application writes as a
    /// cleared value. Does nothing for a column that cannot be cleared (R-121).
    ///
    /// This is the only way to blank a field the selection disagrees about. Such a field shows
    /// nothing while it is untouched, so an empty field cannot also mean "blank it".
    public func clearField(_ column: LedgerColumn) {
        guard canClear(column) else { return }
        setEdit(.empty, for: column.id)
    }

    /// Whether the panel offers Clear beside this field: the column can be blanked, some row
    /// holds a value, and the field is not already staged to be blanked.
    public func offersClear(_ column: LedgerColumn) -> Bool {
        canClear(column) && edit(for: column.id) != .empty && displayState(column.id) != .empty
    }

    /// Whether the untouched field shows a value: every row agrees on a non-blank value.
    ///
    /// Only then does emptying the field mean "blank it". Over a mixed or all-blank selection
    /// the untouched field is already empty, so an empty field there is the untouched field.
    private func showsSharedValue(_ columnID: LedgerColumnID) -> Bool {
        displayState(columnID).uniformValue != nil
    }

    /// Takes back whatever the field had staged, so Apply leaves it as it is (R-121).
    public func leaveUnchanged(_ columnID: LedgerColumnID) {
        setEdit(nil, for: columnID)
    }

    // MARK: Text fields

    /// The text a text field shows: what the user typed (an emptied field stays empty), else
    /// the staged value, else the selection's shared value.
    ///
    /// "Not edited" and "edited to empty" used to be the same state: emptying the field
    /// unstaged it, and the getter then put the shared value back — backspacing "Slab" away
    /// brought "Slab" back, and there was no way to blank a field (R-121).
    public func text(for column: LedgerColumn) -> String {
        if let draft = textDrafts[column.id] { return draft }
        switch edit(for: column.id) {
        case .empty?:
            return ""
        case let staged?:
            return staged.asText ?? ""
        case nil:
            return displayState(column.id).uniformValue ?? ""
        }
    }

    /// Takes what the user typed into a text field.
    ///
    /// - A write of exactly what the field already shows is not an edit and changes nothing.
    ///   On macOS a SwiftUI `TextField` calls its binding's setter with its unchanged text
    ///   whenever it gains or loses focus; in a Mixed field that text is "", and treating it as
    ///   typed blanked every selected markup just because the person clicked into the field or
    ///   tabbed through it (R-121 re-fix).
    /// - Emptying a field that showed the selection's shared value stages a cleared field, or,
    ///   for a column that cannot be blank, stages nothing and is reported (R-121).
    /// - Emptying a field whose untouched state is already empty (mixed, or blank on every row)
    ///   goes back to "leave unchanged". Blanking such a field is ``clearField(_:)``.
    public func setText(_ text: String, for column: LedgerColumn) {
        guard text != self.text(for: column) else { return }
        refusedBlankColumns.remove(column.id)
        guard text.isEmpty else {
            textDrafts[column.id] = text
            stage(.text(text), for: column.id)
            return
        }
        guard showsSharedValue(column.id) else {
            textDrafts.removeValue(forKey: column.id)
            stage(nil, for: column.id)
            return
        }
        textDrafts[column.id] = text
        stageEmptied(column)
    }

    /// Stages an emptied field that showed a shared value: `.empty`, or nothing plus the
    /// refusal hint for a column that cannot be blank.
    private func stageEmptied(_ column: LedgerColumn) {
        if canClear(column) {
            stage(.empty, for: column.id)
        } else {
            refusedBlankColumns.insert(column.id)
            stage(nil, for: column.id)
        }
    }

    private func stage(_ value: LedgerCellValue?, for columnID: LedgerColumnID) {
        if let value {
            edits[columnID] = value
        } else {
            edits.removeValue(forKey: columnID)
        }
    }

    // MARK: Number fields

    /// The text a number field shows: what the user typed, else the staged value in the
    /// user's locale, else the selection's shared value as a bare editable number. A cleared
    /// field shows empty.
    ///
    /// The shared value used to be the rows' display text — "45,50 kr" or "$45.50" for a money
    /// column — which the field's own parser refuses, so changing one digit of a shared Unit
    /// Cost marked the field "Not a number" (S-084). It is now the number the inline cell
    /// editor opens with (``editableNumberText(_:column:locale:)``).
    public func numberText(for column: LedgerColumn, locale: Locale = .autoupdatingCurrent) -> String {
        if let draft = numberDrafts[column.id] { return draft }
        switch edit(for: column.id) {
        case .empty?:
            return ""
        case let staged?:
            // A staged `.quantity` comes from a dimensioned column; the getter used to ignore
            // it and echo the old shared text over every keystroke (BH-037). Shown in the
            // column's display unit, the unit the user typed it in.
            return Self.editableNumberText(staged, column: column, locale: locale)
                ?? displayState(column.id).uniformValue ?? ""
        case nil:
            if let shared = valueState(column.id).uniformValue,
               let text = Self.editableNumberText(shared, column: column, locale: locale) {
                return text
            }
            return displayState(column.id).uniformValue ?? ""
        }
    }

    /// A number or money cell as the bare text a person edits: the locale's decimal separator,
    /// no grouping, no currency or unit symbol, a dimensioned value in the unit the column
    /// displays — "5400" rather than "5 400,00 kr", so what is typed back parses. `nil` for a
    /// cell that holds no number.
    ///
    /// The one conversion for Bulk Edit's number fields and the inline cell editor (NL-QTY-04).
    public static func editableNumberText(
        _ cell: LedgerCellValue,
        column: LedgerColumn,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        switch cell {
        case let .number(value):
            return editableString(value, locale: locale)
        case let .currency(amount, _):
            return editableString(amount, locale: locale)
        case let .quantity(quantity):
            let display = LedgerFilterUnitConversion.forColumn(column).displayValue(fromSI: quantity.value)
            return editableString(display, locale: locale)
        default:
            return nil
        }
    }

    /// Takes what the user typed into a number field and stages the value it stands for.
    ///
    /// Parsing is strict and the same in every locale: "2,5" and "2.5" are 2.5, a trailing
    /// separator is a fraction still being typed, and "12abc" stages nothing instead of 12
    /// (BH-224). The value is staged in the cell shape the app stores for the column, so the
    /// pre-apply count compares like with like (BH-223).
    ///
    /// Empty text follows the rules of ``setText(_:for:)``: a write of what the field already
    /// shows is the focus echo and changes nothing, emptying a shared value clears it, and
    /// emptying a mixed field goes back to "leave unchanged" (R-121 re-fix).
    public func setNumberText(_ text: String, for column: LedgerColumn, locale: Locale = .autoupdatingCurrent) {
        guard text != numberText(for: column, locale: locale) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        invalidNumberColumns.remove(column.id)
        refusedBlankColumns.remove(column.id)
        guard !trimmed.isEmpty else {
            // An emptied field that showed the shared value is a cleared value, and it stays
            // empty on screen. It used to unstage the edit and fall back to the shared value, so
            // a number could not be blanked and the field rewrote itself mid-typing (R-121).
            guard showsSharedValue(column.id) else {
                if text.isEmpty {
                    numberDrafts.removeValue(forKey: column.id)
                } else {
                    numberDrafts[column.id] = text
                }
                stage(nil, for: column.id)
                return
            }
            numberDrafts[column.id] = text
            stageEmptied(column)
            return
        }
        numberDrafts[column.id] = text
        guard let value = Self.parseDecimal(trimmed),
              let cell = stagedNumberValue(value, for: column) else {
            invalidNumberColumns.insert(column.id)
            stage(nil, for: column.id)
            return
        }
        stage(cell, for: column.id)
    }

    /// The cell a typed number becomes in a column, or `nil` when it cannot become one.
    ///
    /// - A currency column needs a currency code. Without one declared on the column, the
    ///   code the selected rows already carry is used; with neither there is no honest cell
    ///   to write, and a `.number` would be dropped by the app without a word (BH-703).
    /// - A dimensionless number column stores `.number` — that is what the app's own rows
    ///   carry for `Repeat ×` and every custom factor — so the staged cell matches them.
    /// - A dimensioned column stores a `.quantity` of its dimension. The typed number is in
    ///   the unit the column displays ("500" in a millimetre column is 0.5 m), converted to
    ///   SI with the same conversion the filter builder uses.
    public func stagedNumberValue(_ value: Decimal, for column: LedgerColumn) -> LedgerCellValue? {
        Self.numberCell(value, for: column, fallbackCurrencyCode: selectionCurrencyCode(column.id))
    }

    /// The cell a typed number becomes in a column — the rule ``stagedNumberValue(_:for:)``
    /// applies, shared with the inline cell editor so a number typed into a cell and the same
    /// number typed into this panel store the same value (NL-QTY-04).
    ///
    /// - Parameter fallbackCurrencyCode: the code to use when the column declares none.
    public static func numberCell(
        _ value: Decimal,
        for column: LedgerColumn,
        fallbackCurrencyCode: String?
    ) -> LedgerCellValue? {
        if column.kind == .currency {
            guard let code = column.dimension?.currencyCode ?? fallbackCurrencyCode else { return nil }
            return .currency(amount: value, code: code)
        }
        guard let dimension = column.dimension else { return .number(value) }
        let dimensionless = dimension.lengthPower == 0 && !dimension.angle && dimension.currencyCode == nil
        if dimensionless { return .number(value) }
        let siValue = LedgerFilterUnitConversion.forColumn(column).siValue(fromDisplay: value)
        return .quantity(DecimalQuantity(value: siValue, dimension: dimension))
    }

    private func selectionCurrencyCode(_ columnID: LedgerColumnID) -> String? {
        for row in rows {
            if case let .currency(_, code) = row.value(columnID), !code.isEmpty { return code }
        }
        return nil
    }

    /// Parses a typed decimal strictly: a single comma or period as the decimal mark, spaces
    /// between digit groups, nothing else. A single trailing mark is a fraction still being
    /// typed. Returns `nil` for anything that is not entirely a number.
    ///
    /// Delegates to ``LedgerNumberParsing/decimal(from:allowingExponent:)``, the parser every
    /// numeric field in the ledger shares with the rest of Zenit (S-076).
    public static func parseDecimal(_ text: String) -> Decimal? {
        LedgerNumberParsing.decimal(from: text)
    }

    /// A decimal as editable text: the locale's decimal separator, no grouping, every digit.
    public static func editableString(_ value: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        LedgerNumberParsing.editingString(value, locale: locale)
    }

    /// Whether writing `new` over `current` leaves the cell as it is.
    ///
    /// Numbers compare by value and dimension as the column declares it, so a staged
    /// `.quantity(2, ratio)` over a stored `.number(2)` in a ratio column is no change
    /// (BH-223); everything else compares exactly.
    public static func isSameCell(_ current: LedgerCellValue, _ new: LedgerCellValue, dimension: QuantityDimension?) -> Bool {
        if current == new { return true }
        // A blank text cell and a cleared cell are the same nothing: clearing a label that is
        // already "" changes no markup (R-121).
        if Self.isBlank(current) && Self.isBlank(new) { return true }
        guard let lhs = current.asQuantity(inColumn: dimension),
              let rhs = new.asQuantity(inColumn: dimension) else { return false }
        return lhs.value == rhs.value && lhs.dimension == rhs.dimension
    }

    private static func isBlank(_ value: LedgerCellValue) -> Bool {
        switch value {
        case .empty: return true
        case let .text(text): return text.isEmpty
        default: return false
        }
    }

    /// The staged edit for a column, when there is one.
    public func edit(for columnID: LedgerColumnID) -> LedgerCellValue? { edits[columnID] }

    /// Drops every staged edit.
    public func clearEdits() {
        edits.removeAll()
        numberDrafts.removeAll()
        textDrafts.removeAll()
        invalidNumberColumns.removeAll()
        refusedBlankColumns.removeAll()
        colorEdit = nil
    }

    /// What applying the staged edits would do.
    public var summary: LedgerBulkChangeSummary {
        var perField: [LedgerColumnID: Int] = [:]
        var touched: Set<UUID> = []

        for (columnID, value) in edits {
            var count = 0
            let dimension = columns.first { $0.id == columnID }?.dimension
            for row in rows where !Self.isSameCell(row.value(columnID), value, dimension: dimension) {
                count += 1
                touched.insert(row.markupID)
            }
            if count > 0 { perField[columnID] = count }
        }
        if let colorEdit {
            var count = 0
            for row in rows where row.colorRGBA != colorEdit {
                count += 1
                touched.insert(row.markupID)
            }
            if count > 0 { perField[.color] = count }
        }
        return LedgerBulkChangeSummary(
            markupCount: touched.count,
            fieldCount: perField.count,
            changesPerField: perField
        )
    }

    /// Applies the staged edits and clears them.
    public func apply() {
        guard !summary.isEmpty else { return }
        onApply?(edits, colorEdit, markupIDs)
        clearEdits()
    }
}
