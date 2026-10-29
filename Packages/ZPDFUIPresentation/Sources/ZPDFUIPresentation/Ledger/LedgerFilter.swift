import Foundation

/// How a filter rule compares a cell to its operand.
public enum LedgerFilterComparison: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Text contains the operand.
    case contains
    /// Text does not contain the operand.
    case notContains
    /// Values are equal.
    case equals
    /// Values are not equal.
    case notEquals
    /// Text starts with the operand.
    case beginsWith
    /// Text ends with the operand.
    case endsWith
    /// Number or date is smaller.
    case lessThan
    /// Number or date is smaller or equal.
    case lessThanOrEqual
    /// Number or date is larger.
    case greaterThan
    /// Number or date is larger or equal.
    case greaterThanOrEqual
    /// Value falls inside an inclusive range.
    case between
    /// Cell has no value.
    case isEmpty
    /// Cell has a value.
    case isNotEmpty
    /// Check box is ticked.
    case isTrue
    /// Check box is clear.
    case isFalse
    /// Value is one of a set of choices.
    case isAnyOf
    /// Text matches a regular expression, evaluated under a complexity and time guard.
    case matchesRegex

    /// Stable identity.
    public var id: String { rawValue }

    /// Whether the comparison needs no operand.
    public var isUnary: Bool {
        switch self {
        case .isEmpty, .isNotEmpty, .isTrue, .isFalse: return true
        default: return false
        }
    }

    /// A localized name for the rule editor.
    public var displayName: String {
        switch self {
        case .contains: return NSLocalizedString("contains", comment: "Ledger filter comparison")
        case .notContains: return NSLocalizedString("does not contain", comment: "Ledger filter comparison")
        case .equals: return NSLocalizedString("is", comment: "Ledger filter comparison")
        case .notEquals: return NSLocalizedString("is not", comment: "Ledger filter comparison")
        case .beginsWith: return NSLocalizedString("begins with", comment: "Ledger filter comparison")
        case .endsWith: return NSLocalizedString("ends with", comment: "Ledger filter comparison")
        case .lessThan: return NSLocalizedString("is less than", comment: "Ledger filter comparison")
        case .lessThanOrEqual: return NSLocalizedString("is at most", comment: "Ledger filter comparison")
        case .greaterThan: return NSLocalizedString("is greater than", comment: "Ledger filter comparison")
        case .greaterThanOrEqual: return NSLocalizedString("is at least", comment: "Ledger filter comparison")
        case .between: return NSLocalizedString("is between", comment: "Ledger filter comparison")
        case .isEmpty: return NSLocalizedString("is empty", comment: "Ledger filter comparison")
        case .isNotEmpty: return NSLocalizedString("is not empty", comment: "Ledger filter comparison")
        case .isTrue: return NSLocalizedString("is checked", comment: "Ledger filter comparison")
        case .isFalse: return NSLocalizedString("is not checked", comment: "Ledger filter comparison")
        case .isAnyOf: return NSLocalizedString("is any of", comment: "Ledger filter comparison")
        case .matchesRegex: return NSLocalizedString("matches pattern", comment: "Ledger filter comparison")
        }
    }
}

/// The right-hand side of a filter rule.
public enum LedgerFilterOperand: Codable, Hashable, Sendable {

    /// No operand, for unary comparisons.
    case none
    /// A text operand.
    case text(String)
    /// A numeric operand in the column's SI base unit.
    case number(Decimal)
    /// An inclusive numeric range in the column's SI base unit.
    case numberRange(lower: Decimal, upper: Decimal)
    /// A date operand.
    case date(Date)
    /// An inclusive date range.
    case dateRange(start: Date, end: Date)
    /// A boolean operand.
    case boolean(Bool)
    /// A set of stored choice values.
    case choices([String])
    /// A regular expression pattern.
    case regex(String)
}

/// How rules inside a filter group combine.
public enum LedgerFilterConjunction: String, Codable, Hashable, Sendable, CaseIterable {

    /// Every rule must match.
    case all
    /// At least one rule must match.
    case any

    /// A localized name for the group header.
    public var displayName: String {
        switch self {
        case .all: return NSLocalizedString("Match all", comment: "Ledger filter group conjunction")
        case .any: return NSLocalizedString("Match any", comment: "Ledger filter group conjunction")
        }
    }
}

/// What the canvas does with markups that fail the ledger filter.
public enum LedgerCanvasFilterBehavior: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Draw non-matching markups at reduced contrast.
    case dimNonMatching
    /// Do not draw non-matching markups.
    case hideNonMatching
    /// Ignore the filter on the canvas.
    case leaveUnchanged

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the canvas filter control.
    public var displayName: String {
        switch self {
        case .dimNonMatching: return NSLocalizedString("Dim Non-Matching", comment: "Canvas behaviour for filtered-out markups")
        case .hideNonMatching: return NSLocalizedString("Hide Non-Matching", comment: "Canvas behaviour for filtered-out markups")
        case .leaveUnchanged: return NSLocalizedString("Leave Unchanged", comment: "Canvas behaviour for filtered-out markups")
        }
    }
}

/// A single filter condition on one column.
public struct LedgerFilterRule: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the rule.
    public let id: UUID
    /// The column the rule inspects.
    public var column: LedgerColumnID
    /// How the cell is compared.
    public var comparison: LedgerFilterComparison
    /// The value compared against.
    public var operand: LedgerFilterOperand
    /// Whether the rule participates in filtering.
    public var isEnabled: Bool

    /// Creates a filter rule.
    public init(
        id: UUID,
        column: LedgerColumnID,
        comparison: LedgerFilterComparison,
        operand: LedgerFilterOperand = .none,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.column = column
        self.comparison = comparison
        self.operand = operand
        self.isEnabled = isEnabled
    }
}

/// A tree of filter rules.
///
/// The root group of an unfiltered ledger has no rules and no child groups, which the
/// presenter reports through ``isEmpty``.
public struct LedgerFilterGroup: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the group.
    public let id: UUID
    /// How ``rules`` and ``groups`` combine.
    public var conjunction: LedgerFilterConjunction
    /// Rules at this level.
    public var rules: [LedgerFilterRule]
    /// Nested groups.
    public var groups: [LedgerFilterGroup]
    /// Whether the group's result is inverted.
    public var isNegated: Bool

    /// Creates a filter group.
    public init(
        id: UUID,
        conjunction: LedgerFilterConjunction = .all,
        rules: [LedgerFilterRule] = [],
        groups: [LedgerFilterGroup] = [],
        isNegated: Bool = false
    ) {
        self.id = id
        self.conjunction = conjunction
        self.rules = rules
        self.groups = groups
        self.isNegated = isNegated
    }

    /// Whether the group constrains anything.
    public var isEmpty: Bool {
        rules.allSatisfy { !$0.isEnabled } && groups.allSatisfy(\.isEmpty)
    }

    /// Number of enabled rules in this group and all descendants.
    public var enabledRuleCount: Int {
        rules.filter(\.isEnabled).count + groups.reduce(0) { $0 + $1.enabledRuleCount }
    }
}
