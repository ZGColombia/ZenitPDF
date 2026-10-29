import Foundation
import ZPDFUIPresentation

/// Why a filter could not be applied exactly as written.
///
/// The ledger engine (ZPDFQuantityLedger) evaluates every filter; the application's seam
/// translates the builder's tree for it and drops what the engine has no operator for. These
/// diagnostics are how the filter panel says so. This package once had a filter evaluator of
/// its own, with a guarded regex engine and four diagnostics for it; nothing shipping ever
/// constructed it, and it was removed as a dead duplicate in loop iteration 1 (R-126).
public enum LedgerFilterDiagnostic: Hashable, Sendable {

    /// A pattern rule is shown but not applied: the ledger engine has no regex operator, by
    /// design (QUALITY_BAR A23), and the seam drops the rule (CR-56).
    case regexNotApplied
    /// A rule on a synthesised display column — Value or Unit — names a column the ledger
    /// engine does not have, so the seam drops it; the rule is shown but not applied (CR-56).
    case displayColumnNotApplied(columnTitle: String)
    /// A rule names a column the ledger does not have — typically a saved filter restored in a
    /// project without that custom column. The seam drops it; the panel says so (BH-226).
    case unknownColumnNotApplied(columnName: String)
    /// A rule on Type names a value no row carries any more — "measurement", every
    /// measurement's Type before it became the tool (T-046). The rule is applied and matches
    /// nothing, so a saved filter would empty the ledger without a word (U-059).
    case retiredTypeValue(value: String)

    /// A localized, user-facing explanation for the filter bar.
    public var message: String {
        switch self {
        case .regexNotApplied:
            return NSLocalizedString(
                "Pattern rules are not applied. The ledger matches text with contains, begins with and ends with.",
                comment: "Ledger filter diagnostic: a regular-expression rule is shown but not applied by the ledger engine"
            )
        case let .displayColumnNotApplied(columnTitle):
            let format = NSLocalizedString(
                "Rules on the %1$@ column are not applied. Filter the measured column it shows instead.",
                comment: "Ledger filter diagnostic: a rule on the synthesised Value or Unit display column is not applied"
            )
            return String(format: format, columnTitle)
        case let .unknownColumnNotApplied(columnName):
            let format = NSLocalizedString(
                "A rule on the column “%1$@” is not applied: this ledger has no such column.",
                comment: "Ledger filter diagnostic: a rule names a column that does not exist in this project"
            )
            return String(format: format, columnName)
        case let .retiredTypeValue(value):
            let format = NSLocalizedString(
                "A rule on Type looks for “%1$@”, which no row has any more: measurements are listed by their tool, such as Length, Area or Count. Pick the type again.",
                comment: "Ledger filter diagnostic: a saved rule on the Type column names the old markup kind token"
            )
            return String(format: format, value)
        }
    }

    /// Whether the ledger engine applies `rule` as written: the application's seam
    /// (`LedgerSpecBuilder.filter` in ZPDFAppCore) drops a pattern rule, a pattern operand under
    /// any other comparison that takes a value, a rule on the synthesised Value or Unit display
    /// column, and a rule on a column the ledger does not have (CR-56, BH-226, BH-712, U-063),
    /// and reports each one. A disabled rule is not applied either.
    ///
    /// The one predicate behind the panel's diagnostics (``unappliedRules(in:columns:)``) and
    /// the export banner (U-063), so the banner never names a rule the rows were not filtered
    /// by, and never leaves out one they were.
    public static func isApplied(_ rule: LedgerFilterRule, columns: [LedgerColumn]) -> Bool {
        rule.isEnabled && reasonsNotApplied(rule, columns: columns).isEmpty
    }

    /// Why the seam drops an enabled `rule`, one diagnostic per reason; empty when it applies
    /// the rule. The checks ``isApplied(_:columns:)`` is made of.
    static func reasonsNotApplied(_ rule: LedgerFilterRule, columns: [LedgerColumn]) -> [LedgerFilterDiagnostic] {
        var reasons: [LedgerFilterDiagnostic] = []
        // A pattern rule, and (BH-712) a pattern operand kept under another comparison — "Label
        // is /^C-/" — which has no engine value: the seam drops both.
        let patternOperand: Bool
        if case .regex = rule.operand { patternOperand = !rule.comparison.isUnary } else { patternOperand = false }
        if rule.comparison == .matchesRegex || patternOperand { reasons.append(.regexNotApplied) }
        guard let column = columns.first(where: { $0.id == rule.column }) else {
            reasons.append(.unknownColumnNotApplied(columnName: rule.column.rawValue))
            return reasons
        }
        if LedgerDefaultColumns.isDisplayColumn(rule.column) {
            reasons.append(.displayColumnNotApplied(columnTitle: column.title))
        }
        return reasons
    }

    /// The rules of a filter tree the ledger engine cannot apply, as diagnostics the filter
    /// panel shows beside the tree (CR-56).
    ///
    /// The application's seam drops a `matchesRegex` rule and any rule on the synthesised
    /// Value or Unit display column, while the builder went on reporting "N of M rows match"
    /// and the export banner went on claiming the filter. One diagnostic per kind, so the
    /// panel says what is not being applied instead of nothing. A rule is judged by
    /// ``isApplied(_:columns:)`` — the banner's predicate — so the panel and the banner
    /// cannot disagree about which rules count (U-063).
    public static func unappliedRules(
        in group: LedgerFilterGroup,
        columns: [LedgerColumn]
    ) -> [LedgerFilterDiagnostic] {
        var diagnostics: [LedgerFilterDiagnostic] = []
        func note(_ diagnostic: LedgerFilterDiagnostic) {
            guard !diagnostics.contains(diagnostic) else { return }
            diagnostics.append(diagnostic)
        }
        func visit(_ group: LedgerFilterGroup) {
            for rule in group.rules where rule.isEnabled {
                guard isApplied(rule, columns: columns) else {
                    reasonsNotApplied(rule, columns: columns).forEach(note)
                    continue
                }
                // An applied rule on Type that looks for the retired token matches nothing.
                if rule.column == .icon, !rule.comparison.isUnary {
                    let values: [String]
                    switch rule.operand {
                    case let .text(value): values = [value]
                    case let .choices(list): values = list
                    default: values = []
                    }
                    for value in values where LedgerFilterTypeColumn.retiredValues.contains(value.lowercased()) {
                        note(.retiredTypeValue(value: value))
                    }
                }
            }
            for child in group.groups { visit(child) }
        }
        visit(group)
        return diagnostics
    }
}
