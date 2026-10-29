import Foundation
import ZPDFUIPresentation

/// The ledger filter, described in words for an export's banner.
///
/// The application's CSV export (`LedgerCSVExport` in the app) heads a filtered file with this
/// description, so the person the file is sent to can see which rows it holds.
///
/// This enum used to be a complete CSV, audit-trail CSV and Zenit JSON writer with its own
/// rounding warning, driven by the package's own export dialog. Neither ever shipped: the
/// application writes its exports from the on-screen table and from `ZPDFExport`'s projection.
/// The writer, the dialog, its options and its request were removed as dead duplicates in loop
/// iteration 1 (R-124), so there is one exporter; the filter description is what remained in use.
public enum LedgerExportWriter {

    /// A date operand, medium style, in the locale the banner is written for (W-068). The
    /// shared `DateFormatter.localizedString` ignored the `locale` parameter.
    private static func dateString(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// A short, human-readable description of a filter tree, for an export's filter banner.
    ///
    /// Numbers are written in the locale's notation, like the dates beside them, and choice
    /// operands by the option titles the interface shows, not their stored keys (BH-709) — Type
    /// included, which the filter offers as a pick list of tools (U-059).
    ///
    /// Only the rules the ledger applies are named (U-063): a pattern rule, a rule on the Value
    /// or Unit display column and a rule on a column the ledger lacks are dropped by the seam,
    /// and the banner used to print them anyway ("Comment matches /…/"), claiming a narrower
    /// filter than the rows it headed. ``LedgerFilterDiagnostic/isApplied(_:columns:)`` is the
    /// one predicate the panel and the banner share.
    public static func describe(
        filter: LedgerFilterGroup,
        columns presenterColumns: [LedgerColumn],
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let noFilter = NSLocalizedString("No filter applied", comment: "Ledger export filter description")
        guard !filter.isEmpty else { return noFilter }
        let columns = presenterColumns.map(LedgerFilterTypeColumn.presented)
        let titles: [LedgerColumnID: String] = columns.reduce(into: [:]) { $0[$1.id] = $1.title }
        let choiceTitles: [LedgerColumnID: [String: String]] = columns.reduce(into: [:]) { index, column in
            guard !column.choices.isEmpty else { return }
            index[column.id] = column.choices.reduce(into: [:]) { $0[$1.value] = $1.title }
        }

        let columnsByID: [LedgerColumnID: LedgerColumn] = columns.reduce(into: [:]) { $0[$1.id] = $1 }

        func describe(_ group: LedgerFilterGroup) -> String {
            var parts: [String] = []
            for rule in group.rules where LedgerFilterDiagnostic.isApplied(rule, columns: columns) {
                let title = titles[rule.column] ?? rule.column.rawValue
                let operand = describe(
                    rule.operand,
                    choices: choiceTitles[rule.column] ?? [:],
                    conversion: LedgerFilterUnitConversion.forColumn(columnsByID[rule.column])
                )
                parts.append(operand.isEmpty
                    ? "\(title) \(rule.comparison.displayName)"
                    : "\(title) \(rule.comparison.displayName) \(operand)")
            }
            for child in group.groups where !child.isEmpty {
                // A group whose every rule is dropped constrains nothing (the seam reads it as
                // match-all), so it is not named either.
                let described = describe(child)
                if !described.isEmpty { parts.append("(\(described))") }
            }
            guard !parts.isEmpty else { return "" }
            let joiner = group.conjunction == .all
                ? NSLocalizedString(" and ", comment: "Joiner between ledger filter rules that must all match")
                : NSLocalizedString(" or ", comment: "Joiner between ledger filter rules where any may match")
            let joined = parts.joined(separator: joiner)
            guard group.isNegated else { return joined }
            let format = NSLocalizedString("not (%1$@)", comment: "Ledger filter description for an inverted group")
            return String(format: format, joined)
        }

        /// A numeric operand in the unit the person typed it in, with that unit's symbol.
        ///
        /// The operand is stored in the column's SI base unit (the filter builder commits
        /// `siValue(fromDisplay:)`), and it used to be printed as stored: a rule typed as
        /// "Plan Length ≥ 500" in a millimetre column read "Plan Length is at least 0.5" in the
        /// CSV banner — a different number, with no unit (R-122).
        ///
        /// Every digit the operand has, as the person typed it, never rounded to a dimension's
        /// display default (BH-038, BH-709) — through the ledger's one number renderer
        /// (W-068), so the banner and the cells under it write the same separators. It used to
        /// run its own ICU `NumberFormatter`, whose fr_FR grouping (U+202F) differed from the
        /// ledger's U+00A0.
        func number(_ si: Decimal, _ conversion: LedgerFilterUnitConversion) -> String {
            LedgerNumberFormatting.exactString(
                conversion.displayValue(fromSI: si), minimumFractionDigits: 0, locale: locale, grouping: true
            )
        }

        func withUnit(_ text: String, _ conversion: LedgerFilterUnitConversion) -> String {
            conversion.symbol.isEmpty ? text : "\(text) \(conversion.symbol)"
        }

        func describe(
            _ operand: LedgerFilterOperand,
            choices: [String: String],
            conversion: LedgerFilterUnitConversion
        ) -> String {
            switch operand {
            case .none: return ""
            // T-051: "is" / "is not" on a choice column stores the option's key as text; the
            // banner names the option the person picked ("Status is In progress"), not the
            // key ("Status is “inProgress”").
            case let .text(value) where choices[value] != nil: return choices[value] ?? value
            case let .text(value): return "“\(value)”"
            case let .number(value): return withUnit(number(value, conversion), conversion)
            case let .numberRange(lower, upper):
                return withUnit("\(number(lower, conversion))–\(number(upper, conversion))", conversion)
            case let .date(value): return dateString(value, locale: locale)
            case let .dateRange(start, end):
                return "\(dateString(start, locale: locale))–\(dateString(end, locale: locale))"
            case let .boolean(value):
                return value
                    ? NSLocalizedString("checked", comment: "Ledger filter operand")
                    : NSLocalizedString("not checked", comment: "Ledger filter operand")
            case let .choices(values): return values.map { choices[$0] ?? $0 }.joined(separator: ", ")
            case let .regex(pattern): return "/\(pattern)/"
            }
        }

        let described = describe(filter)
        return described.isEmpty ? noFilter : described
    }
}
