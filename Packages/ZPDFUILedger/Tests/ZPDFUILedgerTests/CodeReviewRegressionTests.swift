import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Regression tests for the code-review findings on the ledger UX package (CR-56). Every test names, in its own comment,
/// what the code under review answered before the fix. CR-54 (exact-or-refuse subtotals) and
/// CR-65 (the empty group last) were rules of the table's in-memory fold, deleted in C-04
/// (R-129): the table now draws the aggregation core's outline, whose own suites hold those
/// rules, and the preview mock's outline keeps CR-65 (`Iter2MockLedgerOutlineTests` in
/// ZPDFUIPresentation). The pinned-band echo
/// (CR-63) lives in `PinnedBandSelectionTests`. CR-64 (the export dialog's "All rows" scope)
/// and CR-67 (the regex budget) went with the export dialog and the package's own filter
/// evaluator, removed as dead duplicates in loop iteration 1 (R-124, R-126); the ADR-0014
/// COUNT() case went with the package's formula engine (R-123) and is asserted against the
/// live engine in `LiveFormulaEngineTests`.
@Suite("Code-review regressions: ledger UX", .ledgerTierSerialised)
struct LedgerCodeReviewRegressionTests {

    private var columns: [LedgerColumn] { LedgerFixtures.columns }

    // MARK: - CR-56

    @Test("The panel names the rules the ledger engine does not apply")
    func unappliedRulesAreDiagnosed() {
        // Old output: `[]` — no diagnostic existed for either kind of rule; the builder's
        // "N of M rows match" and the export banner reported the filter as applied.
        let value = LedgerDefaultColumns.valueColumn()
        let all = columns + [value, LedgerDefaultColumns.unitColumn()]
        let filter = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.label, .matchesRegex, .regex("S-0[12]"), index: 0),
            LedgerFixtures.rule(value.id, .greaterThan, .number(10), index: 1),
            LedgerFixtures.rule(.subject, .contains, .text("Slab"), index: 2)
        ], groups: [
            LedgerFixtures.group(.any, rules: [
                LedgerFixtures.rule(.trade, .matchesRegex, .regex("Con.*"), index: 3)
            ], index: 1)
        ])
        let diagnostics = LedgerFilterDiagnostic.unappliedRules(in: filter, columns: all)
        #expect(diagnostics == [
            .regexNotApplied,
            .displayColumnNotApplied(columnTitle: value.title)
        ])
        #expect(diagnostics.allSatisfy { !$0.message.isEmpty })

        // A disabled rule is not applied by anybody and raises nothing.
        var disabled = filter
        disabled.rules[0].isEnabled = false
        disabled.rules[1].isEnabled = false
        disabled.groups[0].rules[0].isEnabled = false
        #expect(LedgerFilterDiagnostic.unappliedRules(in: disabled, columns: all).isEmpty)
        // A filter the engine applies in full raises nothing.
        let plain = LedgerFixtures.group(.all, rules: [LedgerFixtures.rule(.subject, .contains, .text("Slab"))])
        #expect(LedgerFilterDiagnostic.unappliedRules(in: plain, columns: all).isEmpty)
    }

    @Test("The rule editor offers neither a pattern comparison nor a display column to a new rule")
    func builderOffersOnlyWhatTheEngineApplies() {
        // Old output: the text comparisons ended in `.matchesRegex`, and the column picker
        // listed the Value and Unit display columns.
        let text = columns.first { $0.id == .subject }
        let offered = LedgerFilterRuleRow.comparisons(for: text, current: .contains)
        #expect(!offered.contains(.matchesRegex))
        #expect(offered.contains(.contains) && offered.contains(.notContains) && offered.contains(.isEmpty))
        #expect(!LedgerFilterRuleRow.comparisons(for: nil, current: .equals).contains(.matchesRegex))
        // A rule that already carries the comparison keeps it, so the row still reads correctly.
        #expect(LedgerFilterRuleRow.comparisons(for: text, current: .matchesRegex).last == .matchesRegex)

        let value = LedgerDefaultColumns.valueColumn()
        let unit = LedgerDefaultColumns.unitColumn()
        let all = [value, unit] + columns
        let selectable = LedgerFilterRuleRow.selectableColumns(all, current: .subject).map(\.id)
        #expect(!selectable.contains(value.id))
        #expect(!selectable.contains(unit.id))
        #expect(selectable.contains(.subject))
        // A rule already on a display column keeps it in its own picker.
        #expect(LedgerFilterRuleRow.selectableColumns(all, current: value.id).map(\.id).contains(value.id))
        // A fresh rule never starts on a display column, even when one leads the layout.
        #expect(LedgerFilterRuleRow.defaultColumn(in: all)?.id == .subject)
    }
}
