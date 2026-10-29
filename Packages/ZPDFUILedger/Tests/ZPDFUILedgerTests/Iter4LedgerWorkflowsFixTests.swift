import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Loop iteration 4, area ui-workflows-ledger. A comparison change drops the unreadable draft
/// with the rest of the rule's number bookkeeping (U-057), a new rule with nothing written in
/// it starts off (U-058), Type filters by the tool the column shows (U-059), Copy quotes a CRLF
/// (U-062), the export banner names only applied rules (U-063), Apply Assembly takes lengths
/// in the ledger's unit (U-064), the matrix and snapshots speak in sentences (U-065) and the
/// count phrases read "1 row" (U-066). Nothing is put in a window.
@MainActor
@Suite("Ledger, loop iteration 4", .ledgerTierSerialised)
struct Iter4LedgerWorkflowsFixTests {

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let identity = LedgerFilterUnitConversion.forColumn(nil)

    private static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: posix)!
    }

    // MARK: - U-056

    @Test("U-056: the Waste and Order preset leaves Pack size out of totals and writes Order as a count")
    func wasteAndOrderPresetTotals() async throws {
        for basis in LedgerColumnManagerModel.WasteBasis.allCases {
            let presenter = MockLedgerPresenter()
            let model = LedgerColumnManagerModel(presenter: presenter)
            #expect(await model.addWasteAndOrderColumns(basis: basis))
            let specs = presenter.mockColumnSpecs
            let pack = try #require(specs.first { $0.title == "Pack size" })
            let order = try #require(specs.first { $0.title == "Order" })
            // Old output: Pack size unflagged (summed), Order "ROUNDUP([Gross] / [Pack size], 0)"
            // (a ratio, never summed) — for every basis.
            #expect(pack.neverSums, "\(basis)")
            #expect(pack.dimension == basis.packDimension)
            #expect(order.formulaSource == "CONVERT(ROUNDUP([Gross] / [Pack size], 0), 1, count)")
            #expect(!order.neverSums)
            #expect(LedgerColumnManagerView.kindSummary(pack).contains("no total"))
            #expect(!LedgerColumnManagerView.kindSummary(order).contains("no total"))
        }
        // The flag means nothing on a column that cannot sum, and is not shown there.
        var text = LedgerColumnSpec.new(kind: .text, title: "Note")
        text.neverSums = true
        #expect(!LedgerColumnManagerView.kindSummary(text).contains("no total"))
    }

    // MARK: - U-057

    private static func areaRule() -> LedgerFilterRule {
        LedgerFilterRule(id: UUID(), column: .planArea, comparison: .greaterThanOrEqual, operand: .number(0))
    }

    /// Types `text` one character at a time into field 0 through the row's own path.
    private static func type(_ text: String, into rule: LedgerFilterRule, fields: inout LedgerFilterNumberFields) -> LedgerFilterRule {
        var current = rule
        var typed = ""
        for character in text {
            typed.append(character)
            if let next = fields.rule(typing: typed, inField: 0, conversion: identity, of: current, operand: { .number($0) }) {
                current = next
            }
        }
        return current
    }

    @Test("U-057: a comparison change drops the unreadable draft, so the field shows the value the rule applies")
    func comparisonChangeDropsTheDraft() {
        var fields = LedgerFilterNumberFields()
        let typed = Self.type("1,234.5", into: Self.areaRule(), fields: &fields)
        #expect(typed.isEnabled == false)
        #expect(typed.operand == .number(Self.decimal("1.234")), "the last prefix that parsed")
        #expect(fields.draftText(inField: 0) == "1,234.5")

        // "is at most": the operand keeps .number(1.234) and the rule comes back on.
        let isEnabled = fields.operandReplaced(wasEnabled: typed.isEnabled)
        let rebuilt = LedgerFilterRule(
            id: typed.id, column: typed.column, comparison: .lessThanOrEqual,
            operand: LedgerFilterOperandRules.operand(for: .lessThanOrEqual, column: nil, previous: typed.operand),
            isEnabled: isEnabled
        )
        #expect(rebuilt.isEnabled)
        #expect(fields.hint == nil)
        // Old output: the field's own @State kept "1,234.5" (same view, same identity, same
        // stored value), so the rule filtered at 1.234 under a field reading "1,234.5".
        #expect(fields.draftText(inField: 0) == nil)
        guard case let .number(applied) = rebuilt.operand else {
            Issue.record("expected a number operand, got \(rebuilt.operand)")
            return
        }
        let shown = LedgerFilterNumberFields.shownText(
            draft: fields.draftText(inField: 0), siValue: applied, conversion: Self.identity
        )
        #expect(shown == LedgerNumberParsing.editingString(Self.decimal("1.234")))
        #expect(shown != "1,234.5")
    }

    @Test("U-057: a draft that still means the stored value is kept; one replaced from outside goes")
    func draftBookkeeping() {
        var fields = LedgerFilterNumberFields()
        let typed = Self.type("12,", into: Self.areaRule(), fields: &fields)
        #expect(typed.operand == .number(12))
        #expect(fields.draftText(inField: 0) == "12,")
        fields.dropDraft(inField: 0)
        #expect(fields.draftText(inField: 0) == nil)
    }

    // MARK: - U-058

    private static let pageColumn = LedgerColumn(id: .pageLabel, title: "Page", kind: .text, width: 80)

    @Test("U-058: Add Rule on a text column inserts the rule switched off, so the ledger does not go empty")
    func blankRuleStartsOff() {
        let rule = LedgerFilterOperandRules.newRule(on: Self.pageColumn)
        #expect(rule.comparison == .contains)
        #expect(rule.operand == .text(""))
        // Old output: isEnabled true — "Page contains “”" matched no row and the panel read
        // "0 of N rows match" the moment the rule was added.
        #expect(rule.isEnabled == false)
        #expect(LedgerFilterOperandRules.blankHint(for: rule)?.hasPrefix("Enter a value.") == true)
        let group = LedgerFilterGroup(id: UUID(), rules: [rule])
        #expect(group.isEmpty, "a blank rule constrains no row")
        #expect(LedgerExportWriter.describe(filter: group, columns: [Self.pageColumn], locale: Self.posix) == "No filter applied")

        // A choice column's "is any of" with nothing picked starts off too; a number rule does not.
        let status = LedgerColumn(id: .status, title: "Status", kind: .choice, width: 80, choices: LedgerFixtures.statusChoices)
        #expect(LedgerFilterOperandRules.newRule(on: status).isEnabled == false)
        #expect(LedgerFilterOperandRules.blankHint(for: LedgerFilterOperandRules.newRule(on: status))?.hasPrefix("Choose an option.") == true)
        let area = LedgerColumn(id: .planArea, title: "Plan Area", kind: .number, dimension: .area, width: 80)
        #expect(LedgerFilterOperandRules.newRule(on: area).isEnabled)
    }

    @Test("U-058: the rule comes on with its first written value, and a person's own choice stands")
    func blankRuleComesOnWhenWritten() {
        var blank = LedgerFilterBlankOperand()
        var rule = LedgerFilterOperandRules.newRule(on: Self.pageColumn)
        func edit(_ operand: LedgerFilterOperand) {
            var proposed = rule
            proposed.operand = operand
            rule = blank.rule(after: proposed, replacing: rule)
        }
        edit(.text("A"))
        #expect(rule.isEnabled, "the first letter switches it on")
        edit(.text("A-1"))
        #expect(rule.isEnabled)
        edit(.text(""))
        #expect(rule.isEnabled == false, "emptied again: off, with the hint")
        #expect(LedgerFilterOperandRules.blankHint(for: rule) != nil)
        edit(.text("A-2"))
        #expect(rule.isEnabled, "back on, as it was")

        // Switched off by the person, emptied, written again: it stays off.
        rule.isEnabled = false
        edit(.text(""))
        edit(.text("B"))
        #expect(rule.isEnabled == false)
        #expect(LedgerFilterOperandRules.blankHint(for: rule) == nil, "off by choice, not for want of a value")

        // A column change onto a blank operand switches an enabled rule off, and writing brings it back.
        var number = LedgerFilterRule(id: UUID(), column: .planArea, comparison: .greaterThanOrEqual, operand: .number(5))
        var numberBlank = LedgerFilterBlankOperand()
        let moved = LedgerFilterRule(id: number.id, column: .subject, comparison: .contains, operand: .text(""), isEnabled: true)
        number = numberBlank.rule(after: moved, replacing: number)
        #expect(number.isEnabled == false)
        var written = number
        written.operand = .text("Wall")
        #expect(numberBlank.rule(after: written, replacing: number).isEnabled)

        // A unary comparison is never blank.
        #expect(!LedgerFilterOperandRules.isBlank(LedgerFilterRule(id: UUID(), column: .pageLabel, comparison: .isEmpty, operand: .none)))
    }

    // MARK: - U-059

    private static let typeColumn = LedgerColumn(id: .icon, title: "Type", kind: .text, width: 32)

    @Test("U-059: the builder offers Type as a pick list of tool names over the stored tokens")
    func typeIsAPickList() throws {
        let columns = LedgerFilterBuilder.filterableColumns([Self.typeColumn, Self.pageColumn])
        let type = try #require(columns.first { $0.id == .icon })
        // Old output: kind .text with no choices — free text compared exactly with "length".
        #expect(type.kind == .choice)
        let length = try #require(type.choices.first { $0.value == "length" })
        #expect(length.title == MeasurementKind.length.displayName)
        #expect(type.choices.first { $0.value == "rectangleArea" }?.title == MeasurementKind.rectangleArea.displayName)
        #expect(type.choices.first { $0.value == "cloud" }?.title == MarkupKind.cloud.displayName)
        #expect(!type.choices.contains { $0.value == "measurement" || $0.value == "temporaryMeasure" })
        #expect(Set(type.choices.map(\.value)).count == type.choices.count, "one option per token")
        #expect(LedgerFilterRuleRow.comparisons(for: type, current: .isAnyOf) == [.equals, .notEquals, .isAnyOf, .isEmpty, .isNotEmpty])
        // Every other column is untouched.
        let arranged = LedgerDefaultColumns.arranged([Self.typeColumn, Self.pageColumn])
        #expect(columns.first { $0.id == .pageLabel } == arranged.first { $0.id == .pageLabel })

        // "Type is Length" stores the token, and the banner reads the name.
        let rule = LedgerFilterRule(id: UUID(), column: .icon, comparison: .equals, operand: .text(length.value))
        let banner = LedgerExportWriter.describe(
            filter: LedgerFilterGroup(id: UUID(), rules: [rule]), columns: [Self.typeColumn], locale: Self.posix
        )
        // Old output: `Type is “length”`.
        #expect(banner == "Type \(LedgerFilterComparison.equals.displayName) \(MeasurementKind.length.displayName)")
    }

    @Test("U-059: a saved rule on the retired \"measurement\" token is flagged")
    func retiredTypeTokenIsFlagged() {
        let old = LedgerFilterRule(id: UUID(), column: .icon, comparison: .equals, operand: .text("measurement"))
        let diagnostics = LedgerFilterDiagnostic.unappliedRules(
            in: LedgerFilterGroup(id: UUID(), rules: [old]), columns: [Self.typeColumn]
        )
        // Old output: [] — the rule matched nothing and the panel said nothing.
        #expect(diagnostics == [.retiredTypeValue(value: "measurement")])
        #expect(diagnostics.first?.message.contains("“measurement”") == true)
        let current = LedgerFilterRule(id: UUID(), column: .icon, comparison: .isAnyOf, operand: .choices(["length", "area"]))
        #expect(LedgerFilterDiagnostic.unappliedRules(in: LedgerFilterGroup(id: UUID(), rules: [current]), columns: [Self.typeColumn]).isEmpty)
    }

    // MARK: - U-062

    final class RecordingPasteboard: LedgerPasteboardWriting {
        var payloads: [LedgerCopyPayload] = []
        func write(_ payload: LedgerCopyPayload) { payloads.append(payload) }
    }

    @Test("U-062: a comment holding CRLF is quoted, in the field and through Copy")
    func crlfIsQuoted() throws {
        let comment = "Line one\r\nLine two"
        #expect(comment.contains("\n") == false, "Swift reads \\r\\n as one Character")
        // Old output: "Line one\r\nLine two", unquoted — the pasted table split at the break.
        #expect(LedgerTabularText.field(comment) == "\"Line one\r\nLine two\"")
        #expect(LedgerTabularText.field("plain") == "plain")
        #expect(LedgerTabularText.field("say \"hi\"") == "\"say \"\"hi\"\"\"")

        var rows = LedgerFixtures.rows
        rows[0].displayValues[.subject] = comment
        let controller = LedgerTableController(rowSource: LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns))
        controller.loadViewIfNeeded()
        let pasteboard = RecordingPasteboard()
        controller.copyPasteboard = pasteboard
        controller.mainTableViewForTesting.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.copy(nil)
        let text = try #require(pasteboard.payloads.first?.tabSeparatedText)
        #expect(text.contains("\"Line one\r\nLine two\""))
        #expect(controller.view.window == nil)
    }

    // MARK: - U-063

    @Test("U-063: the banner names only the rules the ledger applies")
    func bannerSkipsUnappliedRules() {
        let applied = LedgerFilterRule(id: UUID(), column: .subject, comparison: .contains, operand: .text("Wall"))
        let pattern = LedgerFilterRule(id: UUID(), column: .label, comparison: .matchesRegex, operand: .regex("S-0[0-9]"))
        let missing = LedgerFilterRule(id: UUID(), column: .custom("gone"), comparison: .contains, operand: .text("x"))
        let display = LedgerFilterRule(id: UUID(), column: LedgerDefaultColumns.valueColumnID, comparison: .greaterThan, operand: .number(1))
        let columns = LedgerFixtures.columns + [
            LedgerColumn(id: LedgerDefaultColumns.valueColumnID, title: "Value", kind: .number, width: 80)
        ]
        let banner = LedgerExportWriter.describe(
            filter: LedgerFilterGroup(id: UUID(), rules: [applied, pattern, missing, display]),
            columns: columns, locale: Self.posix
        )
        // Old output: `Subject contains “Wall” and Label matches /S-0[0-9]/ and gone contains “x”
        // and Value is greater than 1` — three rules the seam drops.
        #expect(banner == "Subject \(LedgerFilterComparison.contains.displayName) “Wall”")

        // Nothing applied at all: no filter, and an inverted group of dropped rules is not named.
        let onlyDropped = LedgerFilterGroup(
            id: UUID(), rules: [pattern],
            groups: [LedgerFilterGroup(id: UUID(), rules: [missing], isNegated: true)]
        )
        #expect(LedgerExportWriter.describe(filter: onlyDropped, columns: columns, locale: Self.posix) == "No filter applied")
        #expect(LedgerFilterDiagnostic.isApplied(applied, columns: columns))
        #expect(!LedgerFilterDiagnostic.isApplied(pattern, columns: columns))
        #expect(!LedgerFilterDiagnostic.isApplied(missing, columns: columns))
        #expect(!LedgerFilterDiagnostic.isApplied(display, columns: columns))
    }

    @Test("U-063: a pattern operand under \"is\" / \"is not\" is dropped by the pane and the banner alike")
    func patternOperandUnderAnotherComparison() {
        // "Label is /^C-/" — a pattern rule whose comparison was changed (BH-712). ZPDFAppCore's
        // seam now drops it and reports it (Iter4LedgerPatternOperandSeamTests: every row stays,
        // isFiltered false); the banner and the panel must say the same.
        let columns = LedgerFixtures.columns
        let wall = LedgerFilterRule(id: UUID(), column: .subject, comparison: .contains, operand: .text("Wall"))
        for comparison in [LedgerFilterComparison.equals, .notEquals, .contains, .notContains] {
            let rule = LedgerFilterRule(id: UUID(), column: .label, comparison: comparison, operand: .regex("^C-"))
            let alone = LedgerFilterGroup(id: UUID(), rules: [rule])
            #expect(!LedgerFilterDiagnostic.isApplied(rule, columns: columns), "\(comparison)")
            #expect(LedgerFilterDiagnostic.unappliedRules(in: alone, columns: columns) == [.regexNotApplied], "\(comparison)")
            #expect(LedgerExportWriter.describe(filter: alone, columns: columns, locale: Self.posix) == "No filter applied")
            // Beside an applied rule the banner names that rule alone — the seam's rows are the
            // Wall rows (old seam: 0 rows, the pattern operand crossing as "Label is <nothing>").
            let mixed = LedgerFilterGroup(id: UUID(), rules: [rule, wall])
            #expect(
                LedgerExportWriter.describe(filter: mixed, columns: columns, locale: Self.posix)
                    == "Subject \(LedgerFilterComparison.contains.displayName) “Wall”"
            )
        }
        // A comparison that takes no value ignores the operand, here and at the seam.
        let unary = LedgerFilterRule(id: UUID(), column: .label, comparison: .isEmpty, operand: .regex("^C-"))
        #expect(LedgerFilterDiagnostic.isApplied(unary, columns: columns))
        #expect(LedgerFilterDiagnostic.unappliedRules(in: LedgerFilterGroup(id: UUID(), rules: [unary]), columns: columns).isEmpty)

        // unappliedRules judges by isApplied: a rule the seam drops is not also reported as an
        // applied Type rule that matches nothing. Old output: [.regexNotApplied, .retiredTypeValue].
        let typeColumns = columns + [LedgerColumn(id: .icon, title: "Type", kind: .text, width: 32)]
        let droppedTypeRule = LedgerFilterRule(id: UUID(), column: .icon, comparison: .matchesRegex, operand: .text("measurement"))
        #expect(
            LedgerFilterDiagnostic.unappliedRules(in: LedgerFilterGroup(id: UUID(), rules: [droppedTypeRule]), columns: typeColumns)
                == [.regexNotApplied]
        )
    }

    // MARK: - U-064

    @Test("U-064: in a millimetre ledger a length input is typed in mm, as in the Tool Library")
    func assemblyLengthsFollowTheLedgerUnit() async throws {
        let presenter = MockLedgerPresenter()
        let model = LedgerAssemblyPanelModel(
            presenter: presenter, markupIDs: [UUID()], locale: Self.posix, lengthUnit: .millimetre
        )
        let spacing = try #require(model.selected?.inputs.first { $0.name == "Spacing" })
        #expect(spacing.dimension == .length)
        #expect(model.unitLabel(spacing.dimension) == "mm")
        #expect(model.unitLabel(.area) == "m²")
        model.parameterTexts["Spacing"] = "600"
        model.parameterTexts["Height"] = "2400"
        #expect(await model.apply())
        let applied = try #require(presenter.appliedAssemblies.last)
        // Old output: 600 m and 2 400 m — the typed number taken as metres under a field the
        // Tool Library labels "mm", where the same text is 0.6 m.
        #expect(applied.parameters["Spacing"] == DecimalQuantity(value: Self.decimal("0.6"), dimension: .length))
        #expect(applied.parameters["Height"] == DecimalQuantity(value: Self.decimal("2.4"), dimension: .length))

        // A metre ledger is unchanged.
        let metres = LedgerAssemblyPanelModel(presenter: MockLedgerPresenter(), markupIDs: [UUID()], locale: Self.posix)
        #expect(metres.unitLabel(.length) == "m")
    }

    // MARK: - U-065

    @Test("U-065: a matrix that cannot be built says so in words, with the detail as help")
    func matrixFailureIsASentence() async {
        let presenter = FailingReportsPresenter()
        let model = LedgerMatrixModel(presenter: presenter, options: [], rows: .subject, columns: .pageLabel)
        await model.rebuild()
        // Old output: "ledger rebuild failed: no document" on screen.
        #expect(model.failure == "The summary matrix could not be built. Close it and try again.")
        #expect(model.failureDetail == String(describing: FailingReportsPresenter.Failure.noDocument))
        presenter.fails = false
        await model.rebuild()
        #expect(model.failure == nil)
        #expect(model.failureDetail == nil)
        #expect(model.matrix != nil)
    }

    @Test("U-065: a report failure is its own sentence and clears when a report builds")
    func snapshotReportFailureClears() async {
        let presenter = FailingReportsPresenter()
        let model = LedgerSnapshotsModel(presenter: presenter)
        model.newName = "Bid 1"
        #expect(await model.takeSnapshot())
        // The action's confirmation is not overwritten by the report's failure.
        #expect(model.message == "Snapshot “Bid 1” stored.")
        #expect(model.report == nil)
        #expect(model.reportFailure?.hasPrefix("The changes since this snapshot could not be worked out.") == true)
        #expect(model.reportFailureDetail == String(describing: FailingReportsPresenter.Failure.noDocument))

        presenter.fails = false
        await model.rebuildReport()
        // Old output: `message` still held "ledger rebuild failed: no document" beside the valid report.
        #expect(model.report?.snapshotName == "Bid 1")
        #expect(model.reportFailure == nil)
        #expect(model.reportFailureDetail == nil)

        let hosting = NSHostingView(rootView: LedgerSnapshotsPanel(model: model, onDone: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 460)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.window == nil)
    }

    // MARK: - U-066

    @Test("U-066: one row reads as one row")
    func countPhrasesAreSingular() {
        // Old output: "1 rows", "Price 1 Rows", "1 selected measurements", "Priced 1 rows. …".
        #expect(LedgerPlurals.rows(1) == "1 row")
        #expect(LedgerPlurals.rows(3) == "3 rows")
        #expect(LedgerPlurals.priceRows(1) == "Price 1 Row")
        #expect(LedgerPlurals.priceRows(2) == "Price 2 Rows")
        #expect(LedgerPlurals.pricedRows(1) == "Priced 1 row. Undo takes it back.")
        #expect(LedgerPlurals.updatedRates(1) == "Updated the rate on 1 row. Undo takes it back.")
        #expect(LedgerPlurals.staleRates(1) == "1 row is priced at an older rate")
        #expect(LedgerPlurals.selectedMeasurements(1) == "1 selected measurement")
        #expect(LedgerPlurals.measuredRowsUpdated(1) == "1 measured row now uses it; Undo takes it back.")
        #expect(LedgerPlurals.lockedRowsKept(1) == "1 locked row keeps the old recipe.")
        #expect(LedgerPlurals.options(1) == "1 option")
        let group = LedgerGroupSlice(
            path: "g", title: "Walls", column: .subject, value: "g", depth: 0, rowRange: 0..<1,
            children: [], subtotals: LedgerSubtotals(rowCount: 1, results: [:]),
            isExpanded: true
        )
        #expect(group.accessibilityLabel(totalColumn: nil) == "Walls, 1 row")

        // U-066 re-fix: the package's remaining count phrases. Old output, in order:
        // "1 markups selected", "Label: 1 markups", "Ledger, 1 rows", "Ledger, 1 rows, 1 groups",
        // "Match all group, 1 rules", "1 items imported, 1 lines not read.",
        // "Applies 1 changed field(s) to 1 markup(s).", "1 of 1 rows match".
        #expect(LedgerPlurals.markupsSelected(1) == "1 markup selected")
        #expect(LedgerPlurals.markupsSelected(4) == "4 markups selected")
        #expect(LedgerPlurals.markupsPerField("Label", count: 1) == "Label: 1 markup")
        #expect(LedgerPlurals.markupsPerField("Label", count: 2) == "Label: 2 markups")
        #expect(LedgerAccessibilitySummary.text(rowCount: 1, groupCount: 0, totalText: nil) == "Ledger, 1 row")
        #expect(LedgerAccessibilitySummary.text(rowCount: 1, groupCount: 1, totalText: nil) == "Ledger, 1 row, 1 group")
        #expect(
            LedgerAccessibilitySummary.text(rowCount: 5, groupCount: 3, totalText: "12 m²", selectionCount: 2)
                == "Ledger, 5 rows, 3 groups, total 12 m², 2 selected"
        )
        #expect(LedgerPlurals.filterGroupLabel("Match all", ruleCount: 1) == "Match all group, 1 rule")
        #expect(LedgerPlurals.filterGroupLabel("Match any", ruleCount: 2) == "Match any group, 2 rules")
        #expect(LedgerPlurals.importOutcome(imported: 1, rejected: 1) == "1 item imported, 1 line not read.")
        #expect(LedgerPlurals.importOutcome(imported: 3, rejected: 2) == "3 items imported, 2 lines not read.")
        #expect(LedgerBulkChangeSummary(markupCount: 1, fieldCount: 1, changesPerField: [:]).message
            == "Applies 1 changed field to 1 markup.")
        #expect(LedgerBulkChangeSummary(markupCount: 5, fieldCount: 2, changesPerField: [:]).message
            == "Applies 2 changed fields to 5 markups.")
        #expect(LedgerPlurals.rowsMatch(1, of: 1) == "1 of 1 row matches")
        #expect(LedgerPlurals.rowsMatch(0, of: 1) == "0 of 1 row matches")
        #expect(LedgerPlurals.rowsMatch(3, of: 12) == "3 of 12 rows match")
    }

    @Test("U-066: the Rate Library's import outcome reads \"1 item imported\"")
    func importOutcomeIsSingular() async {
        let model = LedgerRateLibraryModel(presenter: MockLedgerPresenter(), markupIDs: [])
        model.pastedList = "Name;Unit;Rate\nGypsum 13 mm;m²;89,50\n"
        await model.importPasted()
        // Old output: "1 items imported, 0 lines not read."
        #expect(model.message == "1 item imported, 0 lines not read.")
    }

    @Test("U-066: no ZPDFUILedger format pairs a bare %d with a counted noun")
    func noBareCountFormatsRemain() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUILedger")
        // A literal holding an integer conversion followed by a plural noun: "%1$d rows",
        // "%2$d markups", "%d rules". Ordinals and bare numbers — "sort level %2$d of %3$d",
        // "Option %d name", "%1$@, %2$d selected" — carry no noun to agree with.
        let pattern = try NSRegularExpression(
            pattern: #"%(\d+\$)?(l?l?d|i)[^"%]*?\b(rows|groups|rules|markups|items|lines|fields|options|measurements|entries)\b"#
        )
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "LedgerPlurals.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let string = String(line)
                if pattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil {
                    offenders.append("\(url.lastPathComponent):\(number + 1): \(string.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        // Old output: LedgerBulkEditPanel.swift:88 and :100, LedgerSelectionSync.swift:26 and :32,
        // LedgerFilterBuilder.swift:113 and :264, LedgerRateLibraryPanel.swift:55 and
        // LedgerBulkEditModel.swift:74.
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("U-066: the shipped catalogue pluralises the ledger phrases in English and Swedish")
    func catalogueCarriesTheLedgerPhrases() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for (language, oneRow, priceOne, priceMany) in [
            ("en", "1 row", "Price 1 Row", "Price 4 Rows"),
            ("sv", "1 rad", "Prissätt 1 rad", "Prissätt 4 rader")
        ] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LedgerPlurals-\(UUID().uuidString)", isDirectory: true)
            let lproj = root.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.copyItem(
                at: repository.appendingPathComponent("ZPDFUIPresentation/Localization/\(language).lproj/Plurals.stringsdict"),
                to: lproj.appendingPathComponent("Plurals.stringsdict")
            )
            let info: [String: Any] = ["CFBundleDevelopmentRegion": language, "CFBundleIdentifier": "ledger.plural.\(language)"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Info.plist"))
            let bundle = try #require(Bundle(url: root))
            #expect(LocalizedPlural.string("%lld rows", count: 1, one: "x", other: "y", bundle: bundle) == oneRow)
            #expect(LocalizedPlural.string("Price %lld Rows", count: 1, one: "x", other: "y", bundle: bundle) == priceOne)
            #expect(LocalizedPlural.string("Price %lld Rows", count: 4, one: "x", other: "y", bundle: bundle) == priceMany)
            // U-066 re-fix: the pieces the two-count sentences are built from.
            let pieces: [(key: String, count: Int, en: String, sv: String)] = [
                ("%lld markups selected", 1, "1 markup selected", "1 markering vald"),
                ("%lld markups", 1, "1 markup", "1 markering"),
                ("%lld groups", 1, "1 group", "1 grupp"),
                ("%lld groups", 3, "3 groups", "3 grupper"),
                ("%lld rules", 1, "1 rule", "1 regel"),
                ("%lld changed fields", 1, "1 changed field", "1 ändrat fält"),
                ("%lld items imported", 1, "1 item imported", "1 post importerad"),
                ("%lld lines not read", 2, "2 lines not read", "2 rader lästes inte"),
                ("of %lld rows match", 1, "of 1 row matches", "av 1 rad matchar")
            ]
            for piece in pieces {
                #expect(
                    LocalizedPlural.string(piece.key, count: piece.count, one: "x", other: "y", bundle: bundle)
                        == (language == "en" ? piece.en : piece.sv),
                    "\(language) \(piece.key)"
                )
            }
        }
    }
}

/// A presenter whose matrix and change report fail until told otherwise (U-065). Everything
/// else is the mock presenter's.
@Observable
@MainActor
final class FailingReportsPresenter: LedgerMatrixProviding, LedgerSnapshotting {

    enum Failure: Error, CustomStringConvertible {
        case noDocument
        var description: String { "ledger rebuild failed: no document" }
    }

    @ObservationIgnored let base = MockLedgerPresenter()
    @ObservationIgnored var fails = true

    var columns: [LedgerColumn] { base.columns }
    var rootGroups: [LedgerGroupNode] { base.rootGroups }
    var rowCount: Int { base.rowCount }
    var contentRevision: Int { base.contentRevision }
    var grandTotals: LedgerTotals { base.grandTotals }
    var groupingColumns: [LedgerColumnID] { base.groupingColumns }
    var filter: LedgerFilterGroup { base.filter }
    var canvasFilterBehavior: LedgerCanvasFilterBehavior { base.canvasFilterBehavior }
    var selectedRowIDs: Set<UUID> { base.selectedRowIDs }
    var sortDescriptors: [LedgerSortDescriptor] { base.sortDescriptors }
    var isLoading: Bool { base.isLoading }
    func setGrouping(_ columns: [LedgerColumnID]) { base.setGrouping(columns) }
    func setFilter(_ filter: LedgerFilterGroup) { base.setFilter(filter) }
    func setCanvasFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) { base.setCanvasFilterBehavior(behavior) }
    func setColumnVisible(_ visible: Bool, columnID: LedgerColumnID) { base.setColumnVisible(visible, columnID: columnID) }
    func setColumnWidth(_ width: Double, columnID: LedgerColumnID) { base.setColumnWidth(width, columnID: columnID) }
    func setColumnPinned(_ pinned: Bool, columnID: LedgerColumnID) { base.setColumnPinned(pinned, columnID: columnID) }
    func moveColumn(_ columnID: LedgerColumnID, to index: Int) { base.moveColumn(columnID, to: index) }
    func toggleGroup(id: LedgerGroupNode.ID) { base.toggleGroup(id: id) }
    func select(rowIDs: Set<UUID>, additive: Bool) { base.select(rowIDs: rowIDs, additive: additive) }
    func sort(by columnID: LedgerColumnID, ascending: Bool) { base.sort(by: columnID, ascending: ascending) }
    func totals(forGroup groupID: LedgerGroupNode.ID?) -> LedgerTotals { base.totals(forGroup: groupID) }
    func row(at index: Int) -> LedgerRow? { base.row(at: index) }
    func index(of markupID: UUID) -> Int? { base.index(of: markupID) }
    func prefetchRows(in range: Range<Int>) { base.prefetchRows(in: range) }

    func matrix(rows: LedgerColumnID, columns: LedgerColumnID) async throws -> LedgerMatrix {
        if fails { throw Failure.noDocument }
        return try await base.matrix(rows: rows, columns: columns)
    }

    func snapshots() async -> [LedgerSnapshotSummary] { await base.snapshots() }
    func takeSnapshot(named name: String) async -> LedgerBulkEditReceipt { await base.takeSnapshot(named: name) }
    func changeReport(since snapshotID: String) async throws -> LedgerChangeReport {
        if fails { throw Failure.noDocument }
        return try await base.changeReport(since: snapshotID)
    }
    func deleteSnapshot(_ snapshotID: String) async -> Bool { await base.deleteSnapshot(snapshotID) }
}
