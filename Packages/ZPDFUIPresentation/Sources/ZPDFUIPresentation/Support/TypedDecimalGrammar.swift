import Foundation

/// Zenit's one grammar for a typed number, below every package that reads one.
///
/// It lives here, in the dependency-free presentation layer, so the UI's fields
/// (`ZPDFDecimalParser` in the design system, a facade over this type) and the app core's
/// preset defaults and column retypes (`LedgerColumnValueConversion`) read the same text as
/// the same number. Before W-032 the core had a second grammar: it turned every
/// comma into a point and parsed what was left with the importers' strict rule, so `1 250` and
/// `−12,50` were numbers in a ledger cell but were skipped as preset defaults, while `1e3` was
/// refused by the cell and became 1000 as a default.
///
/// The rule, stated once and the same in every locale (finding CR-184 has the history):
///
/// - **Grouping is stripped.** Spaces, no-break spaces, narrow no-break spaces and U+066C are
///   removed before anything else. No other character groups digits, because every other
///   candidate is somebody's decimal mark.
/// - **Both decimal marks are accepted, never both at once.** A single `,` with no `.` is the
///   decimal mark; a text carrying both marks, or two commas, is refused rather than guessed.
/// - **The locale is not consulted.**
/// - **Spellings fold**: U+2212 and the other minus signs become `-`, bidirectional marks are
///   dropped, native decimal digits become ASCII.
/// - **Exponents are off unless asked for.**
public enum TypedDecimalGrammar {

    /// Characters treated as digit grouping and removed before parsing.
    public static let groupingCharacters: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\u{066C}"]

    /// Minus-sign spellings folded to ASCII `-`: U+2212 MINUS SIGN (what `NumberFormatter`
    /// emits for sv, fi, nb and et), the small and full-width hyphen-minus.
    public static let minusSigns: Set<Character> = ["\u{2212}", "\u{FE63}", "\u{FF0D}"]

    /// Invisible bidirectional marks a right-to-left locale wraps numbers in.
    public static let ignoredMarks: Set<Character> = [
        "\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}",
        "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"
    ]

    /// A native decimal digit (Arabic-Indic, Persian, Devanagari, full-width, …) as ASCII.
    public static func asciiDigit(_ character: Character) -> Character? {
        guard !character.isASCII,
              character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.properties.numericType == .decimal,
              let digit = character.wholeNumberValue, (0...9).contains(digit)
        else { return nil }
        return Character(String(digit))
    }

    /// The typed text as a canonical POSIX decimal string, or `nil` when it is not a number.
    ///
    /// The single place the grammar lives; ``decimal(_:allowingExponent:)`` and every caller's
    /// `Double` reading are this function plus a conversion.
    public static func normalized(_ text: String, allowingExponent: Bool = false) -> String? {
        var working = ""
        working.reserveCapacity(text.count)
        for character in text where !groupingCharacters.contains(character) {
            // BH-019: the app's own formatter — and any locale-aware display — can hand back
            // a U+2212 minus (sv, fi, nb, et), bidi marks (ar, fa) or native digits. Those are
            // spellings of the same number, not a different grammar.
            if ignoredMarks.contains(character) { continue }
            if minusSigns.contains(character) { working.append("-"); continue }
            if character == "\u{066B}" { working.append("."); continue }
            if let ascii = asciiDigit(character) { working.append(ascii); continue }
            working.append(character)
        }
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return nil }

        let commaCount = working.count(where: { $0 == "," })
        if commaCount > 0 {
            // Both marks in one text is ambiguous by construction, and so is a second comma.
            // Refusing is the only reading that cannot be silently wrong by a factor of 1000.
            guard commaCount == 1, !working.contains(".") else { return nil }
            working = working.replacingOccurrences(of: ",", with: ".")
        }

        let mantissa = "[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)"
        let pattern = allowingExponent
            ? "^" + mantissa + "([eE][+-]?[0-9]+)?$"
            : "^" + mantissa + "$"
        guard working.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return working
    }

    /// The typed text as a finite `Decimal`, or `nil`. Converted in the POSIX locale, the only
    /// conversion that keeps `0.2` exactly two tenths; a `NaN` result is refused as well.
    public static func decimal(_ text: String, allowingExponent: Bool = false) -> Decimal? {
        guard let normalized = normalized(text, allowingExponent: allowingExponent),
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN
        else { return nil }
        return value
    }
}
