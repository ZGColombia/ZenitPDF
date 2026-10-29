import Foundation

/// How a slope is written down (spec 11.3, 12.8).
///
/// All six forms describe the same underlying quantity: a dimensionless `rise / run`. The stored
/// value keeps the form the user typed so the ledger can show it back unchanged, while
/// ``ratio()`` gives the engine the single number it computes with.
///
/// `run == 0` is vertical and undefined, never an infinity (spec 12.8).
public enum SlopeExpression: Codable, Hashable, Sendable {
    /// `1:n` — one unit of rise for `n` of run. The roofing/drainage form.
    case ratioOneToN(Decimal)
    /// `n:1` — `n` units of rise for one of run. The pitch form.
    case ratioNToOne(Decimal)
    /// A bare decimal `rise / run`.
    case decimalRatio(Decimal)
    /// Percent: `100 * rise / run`.
    case percent(Decimal)
    /// Degrees from horizontal.
    case degrees(Decimal)
    /// An explicit rise and run pair in the same length unit.
    case riseOverRun(rise: Decimal, run: Decimal)

    /// A fully vertical slope, which every form must be able to report rather than divide by zero.
    public static let vertical = SlopeExpression.riseOverRun(rise: 1, run: 0)

    /// True when the expression describes a vertical (undefined-ratio) slope.
    public var isVertical: Bool {
        switch self {
        case .ratioOneToN(let n): n == 0
        case .ratioNToOne: false
        case .decimalRatio: false
        case .percent: false
        case .degrees(let d): d == 90 || d == -90
        case .riseOverRun(_, let run): run == 0
        }
    }

    /// The dimensionless `rise / run`.
    ///
    /// - Throws: ``SlopeError/verticalSlopeUndefined`` when the slope is vertical — `run == 0`
    ///   and its `1:0` spelling alike, the two forms ``isVertical`` reports — and
    ///   ``SlopeError/degreesOutOfRange(_:)`` for +/-90 degrees. ``SlopeError/zeroRatioTerm``
    ///   is raised only by ``expressed(as:)`` when a flat slope is asked for in the `1:n` form,
    ///   where `n` would have to be infinite.
    public func ratio() throws -> Decimal {
        switch self {
        case .ratioOneToN(let n):
            // `1:0` is vertical, and `isVertical` already says so. Throwing `zeroRatioTerm` here
            // contradicted that flag (code review CR-145).
            guard n != 0 else { throw SlopeError.verticalSlopeUndefined }
            return 1 / n
        case .ratioNToOne(let n):
            return n
        case .decimalRatio(let value):
            return value
        case .percent(let value):
            return value / 100
        case .degrees(let value):
            // The whole open interval, not just its two ends (BH-495): tan(270°) in Double is
            // a finite 5.4e15 and tan(90.5°) is -114, and neither is a slope.
            guard !value.isNaN, value > -90, value < 90 else { throw SlopeError.degreesOutOfRange(value) }
            let radians = NumericPolicy.double(from: value) * AngleUnit.degree.radiansPerUnit
            let tangent = Foundation.tan(radians)
            guard tangent.isFinite else { throw SlopeError.degreesOutOfRange(value) }
            return try NumericPolicy.decimal(from: tangent)
        case .riseOverRun(let rise, let run):
            guard run != 0 else { throw SlopeError.verticalSlopeUndefined }
            return rise / run
        }
    }

    /// The slope as a percentage.
    public func percentValue() throws -> Decimal { try ratio() * 100 }

    /// The slope angle in radians, measured from horizontal. Vertical yields +/- pi/2 rather
    /// than throwing, because the angle *is* defined even when the ratio is not.
    public func angleRadians() throws -> Double {
        if isVertical {
            switch self {
            case .riseOverRun(let rise, _): return rise < 0 ? -Double.pi / 2 : Double.pi / 2
            case .degrees(let d): return d < 0 ? -Double.pi / 2 : Double.pi / 2
            default: return Double.pi / 2
            }
        }
        return Foundation.atan(NumericPolicy.double(from: try ratio()))
    }

    /// The true-length multiplier `sqrt(1 + ratio^2)` (spec 12.8).
    ///
    /// Computed with `hypot`, not as `(1 + r*r).squareRoot()`. The naive form squares the ratio
    /// first, so it overflows to `+infinity` once `r` passes about 1.3e154 even though the answer
    /// itself is perfectly representable — and an infinite factor would then multiply a plan
    /// length into an infinite true length with nothing raised. `hypot` is exact-to-an-ulp over
    /// the whole range and never overflows before the result does.
    ///
    /// - Throws: ``SlopeError/verticalSlopeUndefined`` for a vertical slope, where a plan length
    ///   of zero cannot be stretched into a true length at all, and
    ///   ``SlopeError/nonFiniteSlopeRatio`` when the ratio is a `NaN` `Decimal` (which is what
    ///   `Decimal` overflow produces) or the factor is otherwise not finite.
    public func trueLengthFactor() throws -> Double {
        let ratio = try ratio()
        guard !ratio.isNaN else { throw SlopeError.nonFiniteSlopeRatio }
        let value = NumericPolicy.double(from: ratio)
        guard value.isFinite else { throw SlopeError.nonFiniteSlopeRatio }
        let factor = Foundation.hypot(1.0, value)
        guard factor.isFinite else { throw SlopeError.nonFiniteSlopeRatio }
        return factor
    }

    /// Re-expresses the same slope in another form, so the ledger can switch display without
    /// touching the stored measurement.
    public func expressed(as form: SlopeForm) throws -> SlopeExpression {
        let value = try ratio()
        switch form {
        case .ratioOneToN:
            guard value != 0 else { throw SlopeError.zeroRatioTerm }
            return .ratioOneToN(1 / value)
        case .ratioNToOne:
            return .ratioNToOne(value)
        case .decimalRatio:
            return .decimalRatio(value)
        case .percent:
            return .percent(value * 100)
        case .degrees:
            let degrees = try NumericPolicy.decimal(
                from: Foundation.atan(NumericPolicy.double(from: value)) / AngleUnit.degree.radiansPerUnit
            )
            return .degrees(degrees)
        case .riseOverRun:
            return .riseOverRun(rise: value, run: 1)
        }
    }
}

/// The tag half of ``SlopeExpression``, used where only the form is chosen.
public enum SlopeForm: String, Codable, Hashable, Sendable, CaseIterable {
    case ratioOneToN
    case ratioNToOne
    case decimalRatio
    case percent
    case degrees
    case riseOverRun
}

// MARK: - Pitch input (ADR-0004 §3)

extension SlopeExpression {

    /// The imperial run a bare pitch numerator is measured against: `6` means `6:12`.
    public static let imperialPitchRun: Decimal = 12

    /// A roof pitch as `rise : run`. `pitch(6)` is `6:12`; `pitch(1, run: 2)` is `1:2`.
    ///
    /// Stored as the exact rise/run pair, so `6:12`, `1:2`, `50 %` and `0.5` are the same
    /// `Decimal` by the time the engine sees them and produce bit-identical results.
    public static func pitch(_ rise: Decimal, run: Decimal = SlopeExpression.imperialPitchRun) -> SlopeExpression {
        .riseOverRun(rise: rise, run: run)
    }

    /// Reads the forms ADR-0004 §3 requires: `6:12`, `1:2`, `26.57°`, `50%`, `0.5`,
    /// `rise 1.5 m over run 3 m`.
    ///
    /// A bare number is a decimal ratio unless `pitchDefaultRun` is supplied, in which case it is
    /// a pitch numerator over that run — that is how an imperial roofing input behaves and it is
    /// opt-in rather than guessed, because `0.5` typed into a metric field means a 1:2 slope and
    /// `6` typed into a pitch field means 6:12.
    ///
    /// Display conversion is one way: this produces the form the user typed, and the stored value
    /// is that form. Nothing here reads a formatted string back into storage.
    ///
    /// Everything that is not a number must be a word the grammar knows (BH-496): `45º` with
    /// the ordinal indicator, `45 grader` or `50 percent` used to leave one token and become a
    /// bare ratio of 45 or 50 — a 4500 % slope stored without a word. A malformed literal
    /// (`1.2.5`, BH-497) and a sign cut off from its digits (`- 5%`, BH-498) are refused too;
    /// the Unicode minus sign U+2212 is a minus, not a separator.
    public static func parse(
        _ text: String,
        pitchDefaultRun: Decimal? = nil
    ) throws -> SlopeExpression {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "\u{2212}", with: "-")
        guard !trimmed.isEmpty else { throw SlopeError.unparsableSlopeText(text) }
        guard let numbers = decimalTokens(in: trimmed), unitWordsAreKnown(in: trimmed) else {
            throw SlopeError.unparsableSlopeText(text)
        }

        if trimmed.hasSuffix("%") {
            guard numbers.count == 1 else { throw SlopeError.unparsableSlopeText(text) }
            return .percent(numbers[0])
        }
        if trimmed.hasSuffix("\u{00B0}") || trimmed.hasSuffix("deg") || trimmed.hasSuffix("degs")
            || trimmed.hasSuffix("deg.") || trimmed.hasSuffix("degrees") {
            guard numbers.count == 1 else { throw SlopeError.unparsableSlopeText(text) }
            return .degrees(numbers[0])
        }
        let isPair = trimmed.contains(":") || trimmed.contains("/") || trimmed.contains("over")
        if isPair {
            guard numbers.count == 2 else { throw SlopeError.unparsableSlopeText(text) }
            return .riseOverRun(rise: numbers[0], run: numbers[1])
        }
        guard numbers.count == 1 else { throw SlopeError.unparsableSlopeText(text) }
        if let run = pitchDefaultRun {
            return .riseOverRun(rise: numbers[0], run: run)
        }
        return .decimalRatio(numbers[0])
    }

    /// Every decimal literal in the string, in order, or `nil` when one of them is malformed.
    /// Written as a scanner rather than a regex so the accepted grammar is visible and cannot
    /// pick up an exponent or a locale separator by accident.
    ///
    /// A literal is digits with at most one `.`; a sign belongs to the literal it precedes,
    /// glued to it or separated by whitespace alone (BH-498: `- 5` used to lose its sign). A
    /// literal `Decimal` cannot read in full — `1.2.5`, which it used to prefix-parse as
    /// `1.2` (BH-497) — is malformed, and so is a sign with no literal after it.
    static func decimalTokens(in text: String) -> [Decimal]? {
        var result: [Decimal] = []
        var digits = ""
        var sign: Character?
        var malformed = false
        func flush() {
            defer { digits = "" }
            guard !digits.isEmpty else { return }
            guard digits != ".", digits.filter({ $0 == "." }).count <= 1,
                  let magnitude = Decimal(string: digits, locale: nil), !magnitude.isNaN else {
                malformed = true
                return
            }
            result.append(sign == "-" ? -magnitude : magnitude)
            sign = nil
        }
        for character in text {
            if Self.isDigit(character) || character == "." {
                digits.append(character)
            } else if (character == "-" || character == "+") && digits.isEmpty && sign == nil {
                sign = character
            } else {
                flush()
                if sign != nil, !character.isWhitespace { malformed = true }
            }
        }
        flush()
        if sign != nil { malformed = true }
        return malformed ? nil : result
    }

    /// An ASCII digit. `Character.isNumber` is wider — it accepts `²`, `½` and other Unicode
    /// numerics that `Decimal(string:)` then reads as far as it can and drops the rest.
    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// The words the grammar reads: the unit suffixes, the pair separators and the words of
    /// the `rise 1.5 m over run 3 m` form. Anything else after the numbers are removed is a
    /// unit this parser does not know, and a number in an unknown unit is not a bare ratio.
    static let knownUnitWords: Set<String> = [
        "%", "\u{00B0}", "deg", "deg.", "degs", "degrees", ":", "/", "over", "rise", "run", "m"
    ]

    /// True when every non-numeric word of the (lowercased) text is in ``knownUnitWords``.
    static func unitWordsAreKnown(in text: String) -> Bool {
        let residual = String(text.map { character -> Character in
            isDigit(character) || character == "." || character == "-" || character == "+"
                ? " " : character
        })
        return residual.split(whereSeparator: \.isWhitespace)
            .allSatisfy { knownUnitWords.contains(String($0)) }
    }
}
