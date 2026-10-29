import Foundation
import ZPDFUIPresentation

/// The one reading of a typed number that every Zenit field uses.
///
/// Before this type there were four of them — the numeric field, the calibration entry, the two
/// tool-preset parameter fields and the schedule-cell reader — and they disagreed with each
/// other in ways nobody could see from the screen. Under `en_US` two of them read `12,5` as
/// twelve and a half and two refused it; `1,234` was one thousand two hundred and thirty-four to
/// one field and one point two three four to the field beside it in the same sheet, a factor of
/// a thousand between two boxes an estimator tabs between; and two of them accepted `nan`,
/// which then travelled into a slope parameter and a page index. Finding CR-184.
///
/// # The grammar
///
/// One rule, stated once, the same in every locale:
///
/// - **Grouping is stripped.** Plain spaces, no-break spaces and narrow no-break spaces are
///   removed before anything else, so `1 200` and `1 200` are both twelve hundred. No other
///   character is treated as grouping, because every candidate for the job is also somebody's
///   decimal mark.
/// - **Both decimal marks are accepted, never both at once.** A single `,` with no `.` is the
///   decimal mark, so `12,5` is twelve and a half whatever the keyboard. A text carrying both
///   marks, or more than one comma, is refused outright rather than disambiguated by luck:
///   `1,200.50` and `1,200,300` are `nil`, not a guess.
/// - **The locale is not consulted.** A `NumberFormatter` in the user's locale reads the same
///   characters differently on two machines, which is exactly how the same project file produced
///   two different depths. The grammar above is total and machine-independent.
/// - **The result must be finite.** `nan`, `inf`, `-infinity` and every spelling of them fail the
///   grammar, and the parsed value is checked again before it is returned. Nothing that is not a
///   real number leaves this type.
///
/// Exponents are off by default and asked for explicitly, because a schedule cell reading `1e5`
/// is far more likely to be a misread than a hundred thousand, while a numeric field is a place
/// a person may reasonably type one.
public enum ZPDFDecimalParser {

    /// Characters treated as digit grouping and removed before parsing.
    public static var groupingCharacters: Set<Character> { TypedDecimalGrammar.groupingCharacters }

    /// Invisible bidirectional marks a right-to-left locale wraps numbers in.
    static var ignoredMarks: Set<Character> { TypedDecimalGrammar.ignoredMarks }

    /// The typed text as a canonical POSIX decimal string, or `nil` when it is not a number.
    ///
    /// The grammar itself is ``TypedDecimalGrammar`` in `ZPDFUIPresentation`, the layer below
    /// both this package and the app core, so a ledger cell, a preset default and a column
    /// retype read the same text as the same number (W-032). ``double(_:allowingExponent:)``
    /// and ``decimal(_:allowingExponent:)`` are both this function plus a conversion, so the
    /// two can never come to different verdicts about the same text.
    public static func normalized(_ text: String, allowingExponent: Bool = false) -> String? {
        TypedDecimalGrammar.normalized(text, allowingExponent: allowingExponent)
    }

    /// The typed text as a `Double`, or `nil` when it is not a finite number.
    public static func double(_ text: String, allowingExponent: Bool = false) -> Double? {
        guard let normalized = normalized(text, allowingExponent: allowingExponent),
              let value = Double(normalized),
              value.isFinite
        else { return nil }
        return value
    }

    /// The typed text as a `Decimal`, or `nil` when it is not a finite number.
    ///
    /// `Decimal` rather than `Double` wherever the number is stored rather than drawn: a depth
    /// typed as `0.2` has to come back as exactly two tenths, and `Decimal(string:)` in the
    /// POSIX locale is the only conversion that guarantees it. A `Decimal` that comes back as
    /// `NaN` — which `Decimal(string:)` can produce from text this grammar would never pass — is
    /// refused as well, so no caller has to remember to check.
    public static func decimal(_ text: String, allowingExponent: Bool = false) -> Decimal? {
        TypedDecimalGrammar.decimal(text, allowingExponent: allowingExponent)
    }
}
