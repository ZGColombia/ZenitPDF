import Foundation

/// The dimension of a quantity (spec 11.1, verbatim shape; ADR-0014 added the ratio tag).
///
/// Zenit's quantities are one-dimensional in length plus three orthogonal flags, which is exactly
/// what a takeoff needs and no more: a length power (`0` count, `1` length, `2` area, `3` volume,
/// and the negative powers that division produces), an angle flag, an optional ISO 4217
/// currency code, and — for the dimensionless case only — a ratio tag.
///
/// # Count versus ratio
///
/// Both are dimensionless, and until ADR-0014 they were the *same value*, so a slope ratio or a
/// waste factor summed straight into a count total (`4 doors + 1.15 = 5.15`, no refusal). The
/// `ratio` tag keeps them apart under the sum rule while letting the product rule do what a
/// takeoff expects: a factor scales whatever it multiplies (`area x ratio = area`,
/// `count x ratio = count`, `ratio x ratio = ratio`), and a like-for-like quotient is a ratio
/// (`length / length`, `count / count`, `SEK / SEK`).
///
/// # Where validation happens
///
/// The memberwise initialiser is deliberately **unchecked**. Dimensional algebra needs to build
/// intermediate dimensions that are momentarily out of range — `SQRT` halves a length power,
/// `POW` multiplies one, and a compiler pass may form `m^6` before rejecting it — so a trapping
/// or throwing initialiser would break the very code that enforces the range. The checks live
/// where a bad dimension can actually escape into the product:
///
/// - ``multiplied(by:)`` and ``divided(by:)`` reject a result outside
///   ``supportedLengthPowers``, so the algebra can never *produce* one;
/// - ``init(from:)`` rejects a malformed payload, so a hand-edited or corrupted project file
///   can never *decode* one;
/// - ``validate()`` is the explicit check for anything built by hand.
public struct QuantityDimension: Codable, Hashable, Sendable {
    /// 0 count, 1 length, 2 area, 3 volume. Negative powers arise from division
    /// (cost per square metre is currency with `lengthPower == -2`).
    public var lengthPower: Int
    /// True when the quantity is an angle. Angles are stored in radians.
    public var angle: Bool
    /// ISO 4217 code when the quantity carries money, otherwise `nil`.
    public var currencyCode: String?
    /// True when the dimensionless quantity is a factor — a slope ratio, a percentage, a waste
    /// factor — rather than a count of things (ADR-0014). Only meaningful, and only valid, when
    /// `lengthPower == 0`, `angle == false` and `currencyCode == nil`; ``validate()`` rejects
    /// the tag on anything else.
    public var ratio: Bool

    public init(
        lengthPower: Int = 0,
        angle: Bool = false,
        currencyCode: String? = nil,
        ratio: Bool = false
    ) {
        self.lengthPower = lengthPower
        self.angle = angle
        self.currencyCode = currencyCode
        self.ratio = ratio
    }

    /// The supported range of length powers. Outside it, the algebra throws rather than
    /// producing a dimension nothing in the product can render.
    public static let supportedLengthPowers = -3...3

    // MARK: - Named dimensions

    /// Dimensionless count: the number of things.
    public static let count = QuantityDimension(lengthPower: 0)
    /// Dimensionless factor: slope ratios, percentages, waste factors. Not additive with
    /// ``count`` (ADR-0014).
    public static let ratio = QuantityDimension(lengthPower: 0, ratio: true)
    public static let length = QuantityDimension(lengthPower: 1)
    public static let area = QuantityDimension(lengthPower: 2)
    public static let volume = QuantityDimension(lengthPower: 3)
    public static let angle = QuantityDimension(lengthPower: 0, angle: true)

    /// Money in the given ISO 4217 currency.
    public static func currency(_ code: String) -> QuantityDimension {
        QuantityDimension(lengthPower: 0, currencyCode: code)
    }

    /// A unit rate, for example currency per square metre (`lengthPower == -2`).
    public static func currencyRate(_ code: String, perLengthPower power: Int) -> QuantityDimension {
        QuantityDimension(lengthPower: -power, currencyCode: code)
    }

    // MARK: - Validation

    /// True for exactly three uppercase A-Z letters. ISO 4217 alphabetic codes are nothing else.
    public static func isValidCurrencyCode(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }

    public func validate() throws {
        guard Self.supportedLengthPowers.contains(lengthPower) else {
            throw DimensionError.unsupportedLengthPower(lengthPower)
        }
        if let code = currencyCode, !Self.isValidCurrencyCode(code) {
            throw DimensionError.invalidCurrencyCode(code)
        }
        if ratio, !isDimensionless {
            throw DimensionError.ratioOnDimensionedQuantity(self)
        }
    }

    /// True when the dimension carries no length, no angle and no currency. Both ``count`` and
    /// ``ratio`` are dimensionless; the tag distinguishes them under the sum rule only.
    public var isDimensionless: Bool { lengthPower == 0 && !angle && currencyCode == nil }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case lengthPower, angle, currencyCode, ratio
    }

    /// Encodes the `ratio` key only when it is set, so every dimension that existed before
    /// ADR-0014 keeps its byte-identical encoded form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lengthPower, forKey: .lengthPower)
        try container.encode(angle, forKey: .angle)
        try container.encodeIfPresent(currencyCode, forKey: .currencyCode)
        if ratio { try container.encode(true, forKey: .ratio) }
    }

    /// Decodes and **validates**.
    ///
    /// Without this, a hand-edited or corrupted project file could introduce a dimension the
    /// algebra never allows — `m^500`, or a currency code that is not ISO 4217 — and because
    /// ``requireAdditive(with:)`` only compares for equality, two such values would add happily
    /// and travel on into a total.
    ///
    /// A payload without a `ratio` key decodes as a count. Before ADR-0014 a stored ratio and a
    /// stored count were the same bytes, so nothing here can tell them apart; the consumer that
    /// knows what a stored dimensionless value *means* (a measurement field, a ledger column)
    /// re-tags it — see ``MeasurementResult/init(from:)``.
    ///
    /// - Throws: ``DimensionError/unsupportedLengthPower(_:)``,
    ///   ``DimensionError/invalidCurrencyCode(_:)`` or
    ///   ``DimensionError/ratioOnDimensionedQuantity(_:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lengthPower: try container.decodeIfPresent(Int.self, forKey: .lengthPower) ?? 0,
            angle: try container.decodeIfPresent(Bool.self, forKey: .angle) ?? false,
            currencyCode: try container.decodeIfPresent(String.self, forKey: .currencyCode),
            ratio: try container.decodeIfPresent(Bool.self, forKey: .ratio) ?? false
        )
        try validate()
    }

    // MARK: - Algebra

    /// Product rule.
    ///
    /// - length powers add;
    /// - angle x angle is rejected: a squared angle has no meaning in a takeoff;
    /// - money x money is rejected;
    /// - money x anything-else keeps the currency;
    /// - a ratio is absorbed by whatever it scales: `area x ratio = area`, `count x ratio =
    ///   count`; only `ratio x ratio` stays a ratio (ADR-0014).
    public func multiplied(by other: QuantityDimension) throws -> QuantityDimension {
        if angle && other.angle { throw DimensionError.angleProductUndefined }
        if let left = currencyCode, let right = other.currencyCode {
            throw DimensionError.currencyProductUndefined(left: left, right: right)
        }
        let power = lengthPower + other.lengthPower
        guard Self.supportedLengthPowers.contains(power) else {
            throw DimensionError.unsupportedLengthPower(power)
        }
        return QuantityDimension(
            lengthPower: power,
            angle: angle || other.angle,
            currencyCode: currencyCode ?? other.currencyCode,
            ratio: ratio && other.ratio
        )
    }

    /// Quotient rule.
    ///
    /// - length powers subtract;
    /// - dividing by an angle requires an angle numerator, and the result is dimensionless;
    /// - dividing money by the same currency cancels it; a different currency is rejected;
    /// - dividing a non-money quantity by money is rejected — a reciprocal currency is not a
    ///   value this product ever displays;
    /// - a dimensionless quotient of two like quantities is a **ratio** (`length / length`,
    ///   `count / count`, `SEK / SEK`, `ratio / ratio`), and a count divided by a ratio — or
    ///   the reverse — is a count, since the factor was only ever scaling it (ADR-0014).
    public func divided(by other: QuantityDimension) throws -> QuantityDimension {
        if other.angle && !angle { throw DimensionError.angleQuotientUndefined }
        let resultAngle = angle && !other.angle

        let resultCurrency: String?
        switch (currencyCode, other.currencyCode) {
        case (let left?, let right?):
            guard left == right else {
                throw DimensionError.currencyMismatch(left: left, right: right)
            }
            resultCurrency = nil
        case (let left?, nil):
            resultCurrency = left
        case (nil, let right?):
            throw DimensionError.currencyMismatch(left: nil, right: right)
        case (nil, nil):
            resultCurrency = nil
        }

        let power = lengthPower - other.lengthPower
        guard Self.supportedLengthPowers.contains(power) else {
            throw DimensionError.unsupportedLengthPower(power)
        }
        let dimensionless = power == 0 && !resultAngle && resultCurrency == nil
        return QuantityDimension(
            lengthPower: power,
            angle: resultAngle,
            currencyCode: resultCurrency,
            ratio: dimensionless && ratio == other.ratio
        )
    }

    /// Sum rule: identical or nothing. This is the invariant behind "incompatible dimensions are
    /// never added" (spec 11.4). A ratio and a count are not identical (ADR-0014).
    public func requireAdditive(with other: QuantityDimension) throws {
        guard self == other else {
            throw DimensionError.incompatibleDimensions(left: self, right: other)
        }
    }

    /// The SI base unit symbol for this dimension, used in contract documents and diagnostics.
    /// Count and ratio share the dimensionless symbol `1`; the distinction is a tag, not a unit.
    ///
    /// Money over a length power is a rate (`SEK/m^2`); money times a length power, which
    /// `multiplied(by:)` allows, is a product (`SEK*m`). Before BH-494 the positive case printed
    /// as a rate with a negative exponent (`SEK/m^-1`).
    public var baseUnitSymbol: String {
        if let code = currencyCode {
            switch lengthPower {
            case 0: return code
            case 1: return "\(code)*m"
            case ..<0: return "\(code)/m^\(-lengthPower)"
            default: return "\(code)*m^\(lengthPower)"
            }
        }
        if angle { return "rad" }
        switch lengthPower {
        case 0: return "1"
        case 1: return "m"
        default: return "m^\(lengthPower)"
        }
    }
}
