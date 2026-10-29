import Foundation
import ZPDFUIPresentation

/// Converts a numeric filter operand between the unit the user reads and the SI base unit the
/// engine compares against (BH-039).
///
/// `LedgerFilterOperand.number` is contractually "in the column's SI base unit", while the cell
/// the user reads was converted into the project's display unit. A field that took the typed
/// number verbatim compared 500 (typed while reading "500 mm") with 0.5 m and dropped every row.
/// The factor comes from the column's own `displayUnitSymbol` and the exact `Decimal` factors of
/// the presentation units, so a length conversion is exact.
public struct LedgerFilterUnitConversion: Hashable, Sendable {

    /// The unit symbol the field shows beside the value, empty when there is none.
    public let symbol: String
    private let siPerDisplayUnit: Decimal
    private let isAngle: Bool
    private let displayUnitsPerRadian: Decimal

    /// Digits the field shows. The stored operand keeps full precision; this is only the view.
    static let displayFractionDigits = 10

    /// The identity conversion, for counts, ratios, currencies and unknown symbols.
    public static let identity = LedgerFilterUnitConversion(symbol: "", siPerDisplayUnit: 1)

    private init(symbol: String, siPerDisplayUnit: Decimal, isAngle: Bool = false, unitsPerRadian: Decimal = 1) {
        self.symbol = symbol
        self.siPerDisplayUnit = siPerDisplayUnit
        self.isAngle = isAngle
        self.displayUnitsPerRadian = unitsPerRadian
    }

    /// The conversion for a column: its dimension and its display unit symbol.
    public static func forColumn(_ column: LedgerColumn?) -> LedgerFilterUnitConversion {
        guard let column, let dimension = column.dimension else { return .identity }
        let symbol = column.displayUnitSymbol
        if dimension.currencyCode != nil { return LedgerFilterUnitConversion(symbol: symbol, siPerDisplayUnit: 1) }
        if dimension.angle {
            guard let unit = AngleDisplayUnit(rawValue: symbol) else { return .identity }
            return LedgerFilterUnitConversion(
                symbol: symbol,
                siPerDisplayUnit: 1,
                isAngle: true,
                unitsPerRadian: unit.unitsPerRadian
            )
        }
        switch dimension.lengthPower {
        case 1:
            guard let unit = LengthUnit(rawValue: symbol) else { return .identity }
            return LedgerFilterUnitConversion(symbol: symbol, siPerDisplayUnit: unit.metresPerUnit)
        case 2:
            guard let unit = AreaUnit(rawValue: symbol) else { return .identity }
            return LedgerFilterUnitConversion(symbol: symbol, siPerDisplayUnit: unit.squareMetresPerUnit)
        case 3:
            guard let unit = VolumeUnit(rawValue: symbol) else { return .identity }
            return LedgerFilterUnitConversion(symbol: symbol, siPerDisplayUnit: unit.cubicMetresPerUnit)
        default:
            return LedgerFilterUnitConversion(symbol: symbol, siPerDisplayUnit: 1)
        }
    }

    /// The value the field shows for a stored SI operand, rounded for display only.
    public func displayValue(fromSI value: Decimal) -> Decimal {
        let converted: Decimal
        if isAngle {
            converted = value * displayUnitsPerRadian
        } else {
            converted = siPerDisplayUnit == 1 ? value : value / siPerDisplayUnit
        }
        return LedgerNumberFormatting.rounded(converted, fractionDigits: Self.displayFractionDigits)
    }

    /// The SI operand for a value the user typed in the display unit.
    public func siValue(fromDisplay value: Decimal) -> Decimal {
        if isAngle { return displayUnitsPerRadian == 0 ? value : value / displayUnitsPerRadian }
        return siPerDisplayUnit == 1 ? value : value * siPerDisplayUnit
    }
}

/// Day-granular date operands (BH-041, BH-228).
///
/// The date picker edits a calendar day, but a `Date` is an instant: a rule seeded with
/// `Date()` carried the time of day it was created, so "is at least 5 Sep" dropped rows from
/// that morning and "between" lost most of its last day. Every date operand the builder
/// writes is pinned to a day boundary chosen by the comparison: the start of the day for
/// "is", "is not", "is at least" and "is less than", the end of the day for "is greater than"
/// and "is at most", and start…end for "between".
public enum LedgerFilterDates {

    /// The first instant of the day containing `date`.
    public static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The last representable instant of the day containing `date` (one millisecond before
    /// the next day starts), so an inclusive `<=` bound covers the whole day.
    public static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return start }
        return next.addingTimeInterval(-0.001)
    }

    /// The boundary a single-date operand is pinned to for a comparison.
    public static func normalized(
        _ date: Date,
        for comparison: LedgerFilterComparison,
        calendar: Calendar = .current
    ) -> Date {
        switch comparison {
        case .greaterThan, .lessThanOrEqual:
            return endOfDay(date, calendar: calendar)
        default:
            return startOfDay(date, calendar: calendar)
        }
    }

    /// A date operand pinned to day boundaries for a comparison; other operands pass through.
    public static func normalized(
        _ operand: LedgerFilterOperand,
        for comparison: LedgerFilterComparison,
        calendar: Calendar = .current
    ) -> LedgerFilterOperand {
        switch operand {
        case let .date(value):
            return .date(normalized(value, for: comparison, calendar: calendar))
        case let .dateRange(start, end):
            let lower = min(start, end)
            let upper = max(start, end)
            return .dateRange(
                start: startOfDay(lower, calendar: calendar),
                end: endOfDay(upper, calendar: calendar)
            )
        default:
            return operand
        }
    }
}

/// Keeping a rule's operand in a shape the ledger engine can evaluate for its comparison.
///
/// Every rule this returns is one the core filter actually applies. A shape the engine cannot
/// equate — a choice set under "is", a range under "is", a pattern under "is" — used to be kept
/// and silently matched nothing (or, negated, everything) while the export banner still named
/// the filter (BH-042, BH-225, BH-712).
public enum LedgerFilterOperandRules {

    /// The comparison a fresh rule on a column starts with.
    public static func defaultComparison(for column: LedgerColumn) -> LedgerFilterComparison {
        switch column.kind {
        case .text: return .contains
        case .number, .currency, .formula: return .greaterThanOrEqual
        case .date: return .greaterThanOrEqual
        case .checkbox: return .isTrue
        case .choice: return .isAnyOf
        }
    }

    /// The operand a fresh rule on a column starts with.
    public static func defaultOperand(
        for column: LedgerColumn,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LedgerFilterOperand {
        switch column.kind {
        case .text: return .text("")
        case .number, .currency, .formula: return .number(0)
        case .date:
            return .date(LedgerFilterDates.normalized(now, for: defaultComparison(for: column), calendar: calendar))
        case .checkbox: return .none
        case .choice: return .choices([])
        }
    }

    /// The operand a rule carries after the user picks a new comparison.
    public static func operand(
        for comparison: LedgerFilterComparison,
        column: LedgerColumn?,
        previous: LedgerFilterOperand,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LedgerFilterOperand {
        if comparison.isUnary { return .none }
        let isChoice = column?.kind == .choice
        let isDate = column?.kind == .date
        let reshaped: LedgerFilterOperand
        switch comparison {
        case .between:
            switch previous {
            case .dateRange, .numberRange:
                reshaped = previous
            case let .date(value):
                reshaped = .dateRange(start: value, end: value)
            case let .number(value):
                reshaped = .numberRange(lower: value, upper: value)
            default:
                reshaped = isDate ? .dateRange(start: now, end: now) : .numberRange(lower: 0, upper: 0)
            }
        case .isAnyOf:
            switch previous {
            case .choices:
                reshaped = previous
            case let .text(value) where isChoice:
                reshaped = .choices(value.isEmpty ? [] : [value])
            default:
                reshaped = .choices([])
            }
        case .matchesRegex:
            if case .regex = previous { reshaped = previous } else { reshaped = .regex("") }
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            switch previous {
            case .number, .date:
                reshaped = previous
            case let .numberRange(lower, _):
                reshaped = .number(lower)
            case let .dateRange(start, _):
                reshaped = .date(start)
            default:
                reshaped = column.map { defaultOperand(for: $0, now: now, calendar: calendar) } ?? .number(0)
            }
        default:
            // "is", "is not", "contains", "begins with", "ends with".
            if isChoice {
                // A choice column is equated by the option's stored value (the core's CR-52
                // path); a choice *set* has no equality there.
                switch previous {
                case let .choices(values):
                    reshaped = .text(values.first ?? "")
                case .text:
                    reshaped = previous
                default:
                    reshaped = .text("")
                }
                break
            }
            switch previous {
            case let .numberRange(lower, _):
                reshaped = .number(lower)
            case let .dateRange(start, _):
                reshaped = .date(start)
            case .none, .regex, .choices, .boolean:
                reshaped = column.map { defaultOperand(for: $0, now: now, calendar: calendar) } ?? .text("")
            default:
                reshaped = previous
            }
        }
        return LedgerFilterDates.normalized(reshaped, for: comparison, calendar: calendar)
    }

    /// Whether a filter tree has anything in it the user could clear or save — disabled rules
    /// and empty groups included (BH-710). `LedgerFilterGroup.isEmpty` answers a different
    /// question: whether the tree constrains any row.
    public static func hasContent(_ group: LedgerFilterGroup) -> Bool {
        !group.rules.isEmpty || !group.groups.isEmpty
    }

    /// Whether a rule has nothing written in it yet: a comparison that takes a value, with no
    /// text, no option picked, or no pattern (U-058).
    ///
    /// The core applies such a rule literally, and literally it matches no row — "contains"
    /// with an empty needle is false for every text, an empty label reads as no value, and an
    /// empty option set holds nothing — so a blank rule left on empties the ledger, and the
    /// canvas under dim or hide. A blank rule is kept off until something is written in it.
    /// Text of spaces is written text ("contains ␠" is a real question); only empty is blank.
    public static func isBlank(_ rule: LedgerFilterRule) -> Bool {
        guard !rule.comparison.isUnary else { return false }
        switch rule.operand {
        case .none: return true
        case let .text(value): return value.isEmpty
        case let .choices(values): return values.isEmpty
        case let .regex(pattern): return pattern.isEmpty
        case .number, .numberRange, .date, .dateRange, .boolean: return false
        }
    }

    /// A rule as Add Rule inserts it: switched off while it is blank, so starting a filter
    /// never empties the ledger (U-058).
    public static func newRule(on column: LedgerColumn, id: UUID = UUID()) -> LedgerFilterRule {
        var rule = LedgerFilterRule(
            id: id,
            column: column.id,
            comparison: defaultComparison(for: column),
            operand: defaultOperand(for: column)
        )
        if isBlank(rule) { rule.isEnabled = false }
        return rule
    }

    /// The words under a rule that is off because nothing is written in it, `nil` otherwise.
    public static func blankHint(for rule: LedgerFilterRule) -> String? {
        guard isBlank(rule), !rule.isEnabled else { return nil }
        if case .choices = rule.operand {
            return NSLocalizedString(
                "Choose an option. This rule is off until it has one.",
                comment: "Ledger filter hint under a rule whose option set is empty"
            )
        }
        return NSLocalizedString(
            "Enter a value. This rule is off until it has one.",
            comment: "Ledger filter hint under a rule whose value is empty"
        )
    }
}

/// Keeps a blank rule off and switches it back on once something is written in it (U-058).
///
/// A rule row holds one of these. Every edit the row makes to its rule — a typed value, a
/// picked option, a new column or comparison — passes through ``rule(after:replacing:)``. A
/// rule whose operand becomes blank is switched off, remembering whether it was on; when the
/// operand is written again it comes back as it was — on for a rule that was on, or for a new
/// rule Add Rule inserted off because it was blank, and off for one the person had switched off.
struct LedgerFilterBlankOperand: Hashable, Sendable {

    /// Whether the rule was on when its operand went blank in this row; `nil` when it has not.
    private(set) var wasEnabledBeforeBlank: Bool?

    /// The rule to publish for an edit that turns `current` into `proposed`.
    mutating func rule(after proposed: LedgerFilterRule, replacing current: LedgerFilterRule) -> LedgerFilterRule {
        var next = proposed
        let isBlankNow = LedgerFilterOperandRules.isBlank(proposed)
        let wasBlank = LedgerFilterOperandRules.isBlank(current)
        if isBlankNow {
            if !wasBlank { wasEnabledBeforeBlank = proposed.isEnabled }
            next.isEnabled = false
        } else if wasBlank {
            next.isEnabled = wasEnabledBeforeBlank ?? true
            wasEnabledBeforeBlank = nil
        }
        return next
    }
}

/// The Type column as a filter offers it: a pick list of the measurement tools and markup
/// kinds, each stored by the token the Type cells hold and titled as the column shows it
/// (U-059).
///
/// A Type cell holds the tool's raw token ("length", "rectangleArea") or, for a markup without
/// a tool, its kind ("cloud"), and draws the tool's name ("Length", "Rectangle Area"). The
/// builder offered Type as free text and the core compares text exactly, so "Type is Length"
/// and "Type contains Rectangle Area" matched nothing, and no Swedish name ever matched. As a
/// pick list the rule stores the token and reads the name.
public enum LedgerFilterTypeColumn {

    /// Type values no row carries any more: every measurement's Type cell read "measurement"
    /// (its markup kind) until loop iteration 3 (T-046) made it the tool. A saved filter on it
    /// now matches nothing and says so (``LedgerFilterDiagnostic/retiredTypeValue(value:)``).
    public static let retiredValues: Set<String> = [MarkupKind.measurement.rawValue]

    /// One option per measurement tool that can reach the ledger, then per markup kind that is
    /// not a measurement, in declaration order.
    public static let options: [LedgerChoiceOption] = {
        let tools = MeasurementKind.allCases.filter { !$0.isTemporary }.map { ($0.rawValue, $0.displayName) }
        let toolTokens = Set(tools.map(\.0))
        let kinds = MarkupKind.allCases
            .filter { $0 != .measurement && !toolTokens.contains($0.rawValue) }
            .map { ($0.rawValue, $0.displayName) }
        return (tools + kinds).enumerated().map { index, entry in
            LedgerChoiceOption(
                id: UUID(uuid: (0x7A, 0x9E, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, UInt8(index >> 8), UInt8(index & 0xFF))),
                value: entry.0,
                title: entry.1,
                colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0),
                order: index
            )
        }
    }()

    /// `column` as a filter presents it: the Type column as a pick list of ``options``, every
    /// other column unchanged.
    public static func presented(_ column: LedgerColumn) -> LedgerColumn {
        guard column.id == .icon, column.kind == .text, column.choices.isEmpty else { return column }
        var presented = column
        presented.kind = .choice
        presented.choices = options
        return presented
    }
}
