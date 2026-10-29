import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Loop iteration 3, area ui-workflows-ledger. Group headings print counts and money as their
/// cells do (T-048), an unreadable number switches its filter rule off and says so (T-049), an
/// inline edit that cannot take is refused instead of vanishing (T-050), choice filters name
/// their options (T-051) and the Rate Library rounds money like the cells (T-052). Every
/// controller is loaded off screen and never put in a window.
@MainActor
@Suite("Ledger, loop iteration 3", .ledgerTierSerialised)
struct Iter3LedgerWorkflowsFixTests {

    private static let swedish = Locale(identifier: "sv_SE")
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: posix)!
    }

    private static func column(_ id: LedgerColumnID) throws -> LedgerColumn {
        try #require(LedgerFixtures.columns.first { $0.id == id })
    }

    // MARK: - T-048

    private static func slice(_ results: [LedgerColumnID: DecimalQuantity]) -> LedgerGroupSlice {
        LedgerGroupSlice(
            path: "g", title: "Group", column: .subject, value: "g", depth: 0, rowRange: 0..<2,
            children: [],
            subtotals: LedgerSubtotals(
                rowCount: 2,
                results: results.reduce(into: [:]) { index, entry in
                    index[entry.key] = LedgerAggregateResult(
                        column: entry.key, aggregate: .sum, value: .quantity(entry.value)
                    )
                }
            ),
            isExpanded: true
        )
    }

    @Test("T-048: a Count heading keeps its whole number at three-digit precision in sv_SE")
    func countHeadingIsWhole() throws {
        let controller = LedgerTableController(
            rowSource: LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        )
        controller.loadViewIfNeeded()
        controller.rounding = .threeDigits
        controller.locale = Self.swedish
        let count = DecimalQuantity(value: 151, dimension: .count)
        let group = Self.slice([.count: count, LedgerDefaultColumns.valueColumnID: count])
        // Old output: "151,000" — a hundred and fifty-one thousand to a Swedish reader — while
        // the Count cells under it read whole numbers.
        #expect(controller.groupCellText(group, column: try Self.column(.count)) == "151")
        let value = LedgerColumn(id: LedgerDefaultColumns.valueColumnID, title: "Value", kind: .number, width: 80)
        #expect(controller.groupCellText(group, column: value) == "151")

        // A count that carries a fraction (a plain number column) keeps its digits, as its
        // cells do, whatever the precision: 3.75 is not rounded to "4" or padded to "3,750".
        let fraction = DecimalQuantity(value: Self.decimal("3.75"), dimension: .count)
        for rounding in [LedgerRounding.integer, .twoDigits, .fourDigits, .exact] {
            #expect(LedgerNumberFormatting.displayParts(fraction, rounding: rounding, locale: Self.swedish).numberText == "3,75")
        }
        // A measured quantity still follows the precision.
        let area = DecimalQuantity(value: Self.decimal("12.125"), dimension: .area)
        #expect(LedgerNumberFormatting.displayParts(area, rounding: .threeDigits, locale: Self.posix).numberText == "12.125")
        #expect(LedgerNumberFormatting.displayParts(area, rounding: .integer, locale: Self.posix).numberText == "12")
    }

    @Test("T-048: a money heading prints the currency's minor digits at every precision")
    func moneyHeadingFollowsTheCurrency() throws {
        // 17 × 45.125 = 767.125 SEK: the cell reads "767,13 kr" (LedgerMoneyFormatting).
        let total = DecimalQuantity.money(Decimal(17) * Self.decimal("45.125"), code: "SEK")
        // Old output: "767,125" at .exact and .threeDigits, "767,1250" at .fourDigits, "767" at
        // .integer.
        for rounding in LedgerRounding.allCases {
            let parts = LedgerNumberFormatting.displayParts(total, rounding: rounding, locale: Self.swedish)
            #expect(parts.numberText == "767,13", "\(rounding)")
            #expect(parts.unitSymbol == "SEK")
        }
        #expect(LedgerMoneyFormatting.text(total.value, currencyCode: "SEK", locale: Self.swedish).hasPrefix("767,13"))
        // A currency without minor units prints none; one with three prints three.
        let yen = DecimalQuantity.money(Self.decimal("767.5"), code: "JPY")
        #expect(LedgerNumberFormatting.displayParts(yen, rounding: .twoDigits, locale: Self.posix).numberText == "768")
        let dinar = DecimalQuantity.money(Self.decimal("1.2345"), code: "KWD")
        #expect(LedgerNumberFormatting.displayParts(dinar, rounding: .twoDigits, locale: Self.posix).numberText == "1.235")

        let controller = LedgerTableController(
            rowSource: LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        )
        controller.loadViewIfNeeded()
        controller.rounding = .threeDigits
        controller.locale = Self.swedish
        let heading = controller.groupCellText(Self.slice([.totalCost: total]), column: try Self.column(.totalCost))
        #expect(heading.hasPrefix("767,13"), "\(heading)")
    }

    // MARK: - T-049

    private static let identity = LedgerFilterUnitConversion.forColumn(nil)

    private static func areaRule(enabled: Bool = true) -> LedgerFilterRule {
        LedgerFilterRule(
            id: UUID(), column: .planArea, comparison: .greaterThanOrEqual,
            operand: .number(0), isEnabled: enabled
        )
    }

    /// Types `text` one character at a time into field 0, publishing each rule the row would.
    private static func type(
        _ text: String,
        into rule: LedgerFilterRule,
        fields: inout LedgerFilterNumberFields
    ) -> LedgerFilterRule {
        var current = rule
        var typed = ""
        for character in text {
            typed.append(character)
            let draft = LedgerFilterNumberDraft(text: typed, conversion: identity)
            if let next = fields.rule(after: draft, inField: 0, of: current, operand: { .number($0) }) {
                current = next
            }
        }
        return current
    }

    @Test("T-049: a draft is a number, empty, or not a number — never the last value that parsed")
    func draftsAreRead() {
        #expect(LedgerFilterNumberDraft(text: "1,234.5", conversion: Self.identity) == .notANumber)
        #expect(LedgerFilterNumberDraft(text: "12abc", conversion: Self.identity) == .notANumber)
        #expect(LedgerFilterNumberDraft(text: "", conversion: Self.identity) == .empty)
        #expect(LedgerFilterNumberDraft(text: "  ", conversion: Self.identity) == .empty)
        #expect(LedgerFilterNumberDraft(text: "1,5", conversion: Self.identity) == .number(Self.decimal("1.5")))
        #expect(LedgerFilterNumberDraft(text: "1234.5", conversion: Self.identity) == .number(Self.decimal("1234.5")))
    }

    @Test("T-049: typing \"1,234.5\" switches the rule off with a hint instead of filtering at 1.234")
    func unreadableNumberSwitchesTheRuleOff() {
        var fields = LedgerFilterNumberFields()
        let typed = Self.type("1,234.5", into: Self.areaRule(), fields: &fields)
        // Old output: the rule kept `.number(1.234)` and stayed enabled, with no word on screen,
        // while the field read "1,234.5".
        #expect(typed.isEnabled == false)
        #expect(fields.isHoldingUnreadableDraft)
        #expect(fields.hint?.hasPrefix("Not a number.") == true)
        // The export banner lists enabled rules only, so it no longer claims 1.234.
        let banner = LedgerExportWriter.describe(
            filter: LedgerFilterGroup(id: UUID(), rules: [typed]),
            columns: LedgerFixtures.columns,
            locale: Self.posix
        )
        #expect(banner == "No filter applied", "\(banner)")

        // Correcting the text brings the rule back, with the typed value.
        let corrected = fields.rule(
            after: LedgerFilterNumberDraft(text: "1234.5", conversion: Self.identity),
            inField: 0, of: typed, operand: { .number($0) }
        )
        #expect(corrected?.isEnabled == true)
        #expect(corrected?.operand == .number(Self.decimal("1234.5")))
        #expect(fields.hint == nil)
    }

    @Test("T-049: an emptied field is no value, not the old one; a rule the person switched off stays off")
    func emptyFieldAndThePersonsChoice() {
        var fields = LedgerFilterNumberFields()
        let rule = LedgerFilterRule(
            id: UUID(), column: .planArea, comparison: .greaterThanOrEqual, operand: .number(25), isEnabled: true
        )
        // Old output: emptying the field kept filtering at 25.
        let emptied = fields.rule(
            after: LedgerFilterNumberDraft(text: "", conversion: Self.identity),
            inField: 0, of: rule, operand: { .number($0) }
        )
        #expect(emptied?.isEnabled == false)
        #expect(fields.hint?.hasPrefix("Enter a number.") == true)

        // The person's own switch wins over a later draft.
        var own = LedgerFilterNumberFields()
        let off = Self.areaRule(enabled: false)
        own.personToggledRule()
        #expect(own.rule(after: .notANumber, inField: 0, of: off, operand: { .number($0) }) == nil)
        let valid = own.rule(after: .number(7), inField: 0, of: off, operand: { .number($0) })
        #expect(valid?.isEnabled == false, "a draft never switches on a rule the person switched off")
        #expect(valid?.operand == .number(7))
    }

    @Test("T-049: a range stays off until both of its fields read as numbers")
    func rangeWaitsForBothFields() {
        var fields = LedgerFilterNumberFields()
        let rule = LedgerFilterRule(
            id: UUID(), column: .planArea, comparison: .between, operand: .numberRange(lower: 1, upper: 9)
        )
        let lowerBad = fields.rule(after: .notANumber, inField: 0, of: rule) { .numberRange(lower: $0, upper: 9) }
        #expect(lowerBad?.isEnabled == false)
        let upperGood = fields.rule(after: .number(12), inField: 1, of: lowerBad ?? rule) { .numberRange(lower: 1, upper: $0) }
        #expect(upperGood?.isEnabled == false, "the lower bound still does not read")
        #expect(upperGood?.operand == .numberRange(lower: 1, upper: 12))
        let lowerGood = fields.rule(after: .number(2), inField: 0, of: upperGood ?? rule) { .numberRange(lower: $0, upper: 12) }
        #expect(lowerGood?.isEnabled == true)
        #expect(lowerGood?.operand == .numberRange(lower: 2, upper: 12))

        // A new comparison rebuilds the operand: the drafts go and a draft's suspension ends.
        var suspended = LedgerFilterNumberFields()
        _ = suspended.rule(after: .empty, inField: 0, of: rule) { .numberRange(lower: $0, upper: 9) }
        #expect(suspended.operandReplaced(wasEnabled: false) == true)
        #expect(suspended.hint == nil)
    }

    // MARK: - T-050

    @Test("T-050: an emptied Subject is refused with the rejection cue and sends nothing")
    func blankSubjectIsRefused() throws {
        var requests: [LedgerBulkEditRequest] = []
        let controller = LedgerTableController(
            rowSource: LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        )
        controller.onCommitInlineEdit = { requests.append($0) }
        var rejected: [LedgerColumnID] = []
        controller.onInlineEditRejected = { rejected.append($0.id) }
        controller.loadViewIfNeeded()
        #expect(controller.beginInlineEdit(displayPosition: 0, columnID: .subject))
        let field = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        field.stringValue = ""
        controller.commitInlineEdit()
        // Old output: a request `[.subject: .empty]`, which the application turned into an empty
        // batch and a success receipt, and no rejection.
        #expect(requests.isEmpty)
        #expect(rejected == [.subject])

        // A clearable text column still clears.
        #expect(controller.beginInlineEdit(displayPosition: 0, columnID: .label))
        let label = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        label.stringValue = ""
        controller.commitInlineEdit()
        #expect(requests == [LedgerBulkEditRequest(markupIDs: [LedgerFixtures.rows[0].markupID], values: [.label: .empty])])
    }

    @Test("T-050: Status offers no \"No value\" entry; a clearable choice column and an empty cell still do")
    func statusPopUpHasNoEmptyEntry() throws {
        let status = try Self.column(.status)
        let address = LedgerCellAddress(displayPosition: 0, columnID: .status)
        // Old output: ["No value", "Draft", "Approved"]; choosing "No value" closed the editor
        // and changed nothing.
        #expect(LedgerInlinePopUpButton(address: address, column: status, current: "approved").itemTitles
            == ["Draft", "Approved"])
        #expect(LedgerInlinePopUpButton(address: address, column: status, current: nil).itemTitles
            == ["No value", "Draft", "Approved"], "an empty cell never commits an option nobody picked")

        let phase = LedgerColumn(
            id: .custom("phase"), title: "Phase", kind: .choice, width: 96,
            alignment: .leading, isEditable: true, choices: LedgerFixtures.statusChoices
        )
        #expect(LedgerInlinePopUpButton(
            address: LedgerCellAddress(displayPosition: 0, columnID: phase.id), column: phase, current: "draft"
        ).itemTitles == ["No value", "Draft", "Approved"])
    }

    // MARK: - T-051

    private static let statusColumn = LedgerColumn(
        id: .status, title: "Status", kind: .choice, width: 96, alignment: .leading, isEditable: true,
        choices: [
            LedgerChoiceOption(id: UUID(), value: "open", title: "Open", colorRGBA: ColorRGBA.Zenit.Dark.warning, order: 0),
            LedgerChoiceOption(id: UUID(), value: "inProgress", title: "In progress", colorRGBA: ColorRGBA.Zenit.Dark.green, order: 1)
        ]
    )

    @Test("T-051: the \"is any of\" menu names the picked options in option order")
    func choiceMenuShowsTitles() {
        // Old output: "inProgress, open" — the stored keys, sorted as text.
        #expect(LedgerFilterRuleRow.choiceMenuTitle(selected: ["open", "inProgress"], column: Self.statusColumn)
            == "Open, In progress")
        #expect(LedgerFilterRuleRow.choiceMenuTitle(selected: ["inProgress", "retired"], column: Self.statusColumn)
            == "In progress, retired", "a key the column no longer offers is shown as stored")
        #expect(LedgerFilterRuleRow.choiceMenuTitle(selected: [], column: Self.statusColumn) == "Choose…")
    }

    @Test("T-051: the export banner names a single-choice Status rule by its title")
    func bannerNamesTheOption() {
        let filter = LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .status, comparison: .equals, operand: .text("inProgress"))
        ])
        // Old output: "Status is “inProgress”".
        #expect(LedgerExportWriter.describe(filter: filter, columns: [Self.statusColumn], locale: Self.posix)
            == "Status is In progress")
        // A text column keeps its quotes.
        let text = LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text("Slab"))
        ])
        #expect(LedgerExportWriter.describe(filter: text, columns: LedgerFixtures.columns, locale: Self.posix)
            == "Subject is “Slab”")
    }

    // MARK: - T-052

    @Test("T-052: the Rate Library prints a .xx5 rate half away from zero, as the Unit Cost cell does")
    func rateLibraryRoundsLikeTheCell() {
        let rate = Self.decimal("45.125")
        let panel = LedgerRateLibraryPanel.money(rate, "SEK", locale: Self.swedish)
        // Old output: "45,12 kr" (ICU half-even, process locale); the cell reads "45,13 kr".
        #expect(panel.hasPrefix("45,13"), "\(panel)")
        #expect(panel == LedgerMoneyFormatting.text(rate, currencyCode: "SEK", locale: Self.swedish))
        #expect(LedgerRateLibraryPanel.money(Self.decimal("-30.625"), "SEK", locale: Self.swedish).contains("30,63"))
        let entry = LedgerRateEntrySummary(
            id: UUID(), name: "Screed", basis: .area, rate: rate, currencyCode: "SEK",
            waste: nil, packSize: nil, costCode: "", trade: ""
        )
        #expect(LedgerRateLibraryPanel.summary(entry, locale: Self.swedish).hasPrefix(panel))
    }
}
