import Foundation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Formats and parses imperial lengths as feet, inches and a vulgar fraction.
///
/// The fraction precision runs from whole inches to 1/64, and rounding for display
/// must never change the stored SI value. Everything here takes and returns metres; the caller
/// keeps the exact quantity and only asks for a string when it draws.
public enum ImperialLengthFormatter {

    /// Metres in one inch.
    public static let metresPerInch: Double = 0.0254

    /// Formats a length in metres as `12' 6 1/2"`.
    ///
    /// - Parameters:
    ///   - metres: the exact stored length.
    ///   - precision: how far the inch fraction is rounded.
    ///   - showsFeet: `false` renders inches only, for short dimensions.
    public static func string(
        metres: Double,
        precision: ImperialPrecision,
        showsFeet: Bool = true
    ) -> String {
        let sign = metres < 0 ? "-" : ""
        let totalInches = abs(metres) / metresPerInch
        let denominator = max(1, precision.denominator)
        let ticks = (totalInches * Double(denominator)).rounded()
        // `Int(_:)` traps on NaN, on infinity and on anything past Int.max. A NaN quantity
        // (Decimal division by zero reaches here through NSDecimalNumber.doubleValue) used to
        // crash the process at the view boundary while the metric branch printed "NaN"
        // harmlessly. Finding BH-752. Render the value the way the metric branch would.
        guard ticks.isFinite, ticks < Double(Int.max / 2) else {
            return metres.isNaN ? "NaN" : (metres < 0 ? "-∞" : "∞")
        }
        var wholeInches = Int(ticks) / denominator
        var numerator = Int(ticks) % denominator

        // Reduce the fraction so 8/16 reads as 1/2, which is how a tape measure reads.
        var reducedDenominator = denominator
        if numerator > 0 {
            let divisor = greatestCommonDivisor(numerator, reducedDenominator)
            numerator /= divisor
            reducedDenominator /= divisor
        }

        guard showsFeet else {
            return sign + inchString(whole: wholeInches, numerator: numerator, denominator: reducedDenominator)
        }

        let feet = wholeInches / 12
        wholeInches %= 12
        let inches = inchString(whole: wholeInches, numerator: numerator, denominator: reducedDenominator)
        guard feet != 0 else { return sign + inches }
        if wholeInches == 0 && numerator == 0 { return "\(sign)\(feet)'" }
        return "\(sign)\(feet)' \(inches)"
    }

    /// Parses `12' 6 1/2"`, `6.5"`, `12 ft 6 in`, `6 1/2` and plain `18` into inches.
    ///
    /// A bare number is read as inches, which is what the field's unit suffix already says.
    /// Returns `nil` when the text is not a length at all, so the caller can block rather than
    /// guess.
    public static func parseInches(_ text: String) -> Double? {
        var working = normalizingSpaces(text).trimmingCharacters(in: .whitespaces).lowercased()
        guard !working.isEmpty else { return nil }

        // A leading minus is taken off before the feet-inch hyphen in `12'-6"` is turned into a
        // space, so a genuinely negative entry stays negative and the validator can block it.
        var isNegative = false
        if working.hasPrefix("-") {
            isNegative = true
            working.removeFirst()
        }

        var normalized = working
        for (typographic, mark) in typographicMarks {
            normalized = normalized.replacingOccurrences(of: typographic, with: mark)
        }
        for (word, mark) in [("feet", "'"), ("foot", "'"), ("ft", "'"),
                             ("inches", "\""), ("inch", "\""), ("in", "\"")] {
            normalized = normalized.replacingOccurrences(of: word, with: mark)
        }
        normalized = normalized
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }

        var feetPart = ""
        var inchPart = normalized
        if let apostrophe = normalized.firstIndex(of: "'") {
            feetPart = String(normalized[normalized.startIndex..<apostrophe])
            inchPart = String(normalized[normalized.index(after: apostrophe)...])
        }
        inchPart = inchPart.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)

        var total = 0.0
        if !feetPart.isEmpty {
            guard let feet = decimal(feetPart) else { return nil }
            total += feet * 12
        }
        if !inchPart.isEmpty {
            guard let inches = inchesFromMixedNumber(inchPart) else { return nil }
            total += inches
        }
        if feetPart.isEmpty && inchPart.isEmpty { return nil }
        return isNegative ? -total : total
    }

    /// The typographic spellings of the foot and inch marks, each with the ASCII mark it means.
    ///
    /// A dimension copied from a drawing's text layer is typeset: prime and double prime
    /// (`12′ 6″`), or curly quotes from a word processor (`12’ 6”`). ``isUnitless(_:)`` already
    /// treated the primes as unit marks, but ``parseInches(_:)`` folded only the right curly
    /// quotes, so `12′ 6″` under feet was refused as unusable (S-094). One table serves both.
    static let typographicMarks: [(String, String)] = [
        ("\u{2032}", "'"),  // prime
        ("\u{2019}", "'"),  // right single quotation mark
        ("\u{2018}", "'"),  // left single quotation mark
        ("\u{2033}", "\""), // double prime
        ("\u{201D}", "\""), // right double quotation mark
        ("\u{201C}", "\"")  // left double quotation mark
    ]

    /// Whether the text is a plain number carrying no unit of its own.
    ///
    /// `12`, `12.5` and `12,5` are bare. `12' 6"`, `6 1/2`, `12 ft` and `1 200` are not: each
    /// says something about its own units — a mark, a fraction, or two parts — and must be read
    /// by ``parseInches(_:)`` rather than taken at face value.
    ///
    /// The distinction exists because a bare number under a **feet** popup means feet. Reading
    /// it as inches turned a 12-foot dimension into one foot and calibrated the sheet twelve
    /// times too small, with nothing on screen to say so. Finding CR-165.
    public static func isBareNumber(_ text: String) -> Bool {
        let trimmed = normalizingSpaces(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let numeric = trimmed.allSatisfy { character in
            character.isASCII && (character.isNumber || ".,+-".contains(character))
        }
        return numeric && ZPDFDecimalParser.double(trimmed) != nil
    }

    /// Whether the text carries no unit of its own: no foot or inch mark and no unit word.
    ///
    /// `6 1/2`, `1/2` and `12.5` are unitless; `6 1/2"`, `12'` and `12 ft 6 in` are not. A
    /// unitless entry is a number in whatever unit the popup names — the same rule CR-165
    /// applies to a bare number, extended to the mixed number that says the same thing.
    public static func isUnitless(_ text: String) -> Bool {
        let working = normalizingSpaces(text).lowercased()
        let marks = Set("'\"" + typographicMarks.map(\.0).joined())
        return !working.contains(where: { character in
            character.isLetter || marks.contains(character)
        })
    }

    /// Reads a unitless entry — `12`, `12,5`, `6 1/2`, `1/2`, `-3` — as a plain number.
    ///
    /// Returns `nil` for anything carrying a unit mark, and for two numbers that join neither
    /// as a whole plus a fraction (`12 6`, `1 200`), exactly as ``parseInches(_:)`` refuses them.
    ///
    /// Finding BH-247: under a feet popup `6.5` was 6.5 ft but `6 1/2` was 6.5 **inches**, two
    /// spellings of one number calibrating the sheet a factor of twelve apart.
    public static func parseUnitlessNumber(_ text: String) -> Double? {
        guard isUnitless(text) else { return nil }
        var working = normalizingSpaces(text).trimmingCharacters(in: .whitespaces)
        guard !working.isEmpty else { return nil }
        var isNegative = false
        if working.hasPrefix("-") {
            isNegative = true
            working.removeFirst()
            working = working.trimmingCharacters(in: .whitespaces)
        }
        guard let value = inchesFromMixedNumber(working), value.isFinite else { return nil }
        return isNegative ? -value : value
    }

    /// The text with every space-like character folded into one ASCII space.
    ///
    /// U+00A0 and U+202F are what Numbers, Excel and a Swedish locale put between digit groups,
    /// and Option-Space types U+00A0 directly. The shared decimal grammar strips them as
    /// grouping, so a mixed number split only on U+0020 read `6\u{00A0}1/2` as `61/2` = 30.5
    /// inches (BH-050), and `1\u{00A0}200` under feet slipped past the bare-number check to be
    /// read as 1 200 inches (BH-049). Folding first makes both behave exactly like their
    /// plain-space spellings: the mixed number parses, and the grouped number is refused.
    static func normalizingSpaces(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = false
        for character in text {
            let isSpace = character.isWhitespace && !character.isNewline
            if isSpace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }

    // MARK: - Private

    private static func inchString(whole: Int, numerator: Int, denominator: Int) -> String {
        if numerator == 0 { return "\(whole)\"" }
        if whole == 0 { return "\(numerator)/\(denominator)\"" }
        return "\(whole) \(numerator)/\(denominator)\""
    }

    /// Reads `6 1/2`, `1/2` or `6.5`.
    private static func inchesFromMixedNumber(_ text: String) -> Double? {
        let parts = text.split(separator: " ").map(String.init)
        switch parts.count {
        case 1:
            if parts[0].contains("/") { return fraction(parts[0]) }
            return decimal(parts[0])
        case 2:
            guard let whole = decimal(parts[0]), let fractional = fraction(parts[1]) else { return nil }
            return whole + fractional
        default:
            return nil
        }
    }

    private static func fraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count == 2,
              let numerator = decimal(parts[0]),
              let denominator = decimal(parts[1]),
              denominator != 0
        else { return nil }
        return numerator / denominator
    }

    /// Decimal parse through the one grammar every Zenit field shares (CR-184).
    ///
    /// Both `12,5` and `12.5` are accepted, because a Swedish keyboard and an American drawing
    /// meet in the same field every day — and `nan`, which the old `Double(trimmed)` first line
    /// let straight through into a foot count, is not.
    private static func decimal(_ text: String) -> Double? {
        ZPDFDecimalParser.double(text)
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(1, x)
    }
}
