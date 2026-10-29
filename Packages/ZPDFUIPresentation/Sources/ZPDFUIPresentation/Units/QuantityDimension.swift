import Foundation

/// The physical dimension of a quantity, mirroring the frozen core contract.
///
/// `lengthPower` is `0` for a count, `1` for a length, `2` for an area and `3` for a
/// volume. `angle` marks a dimensionless angular value so that it is never summed with a
/// count. `currencyCode` is an ISO 4217 code and is only set on monetary quantities.
/// `ratio` marks the *other* dimensionless value — a factor rather than a number of things.
///
/// # Count versus ratio (ADR-0014)
///
/// Both are dimensionless, and in this mirror they were the **same value** until ADR-0014:
/// `.ratio` was spelled differently and compared equal, so ``isCompatible(with:)`` — which is
/// equality — let a slope ratio or a waste factor sum straight into a count total
/// (`4 doors + 1.15 = 5.15`, no refusal). That is the one place the product's headline
/// guarantee, *incompatible dimensions are never added*, was true only in spelling. The tag is
/// the contracts' fix, mirrored here so the presentation seam refuses the same sums the core
/// refuses, rather than agreeing with the core by accident.
public struct QuantityDimension: Codable, Hashable, Sendable {

    /// Exponent of the length base unit: `0` count, `1` length, `2` area, `3` volume.
    public var lengthPower: Int
    /// Whether the quantity is an angle. Angles are stored in radians.
    public var angle: Bool
    /// ISO 4217 currency code for monetary quantities, otherwise `nil`.
    public var currencyCode: String?
    /// Whether a dimensionless quantity is a **factor** — a slope ratio, a percentage, a waste
    /// factor — rather than a count of things (ADR-0014 §2.1). Only meaningful when the value
    /// is otherwise dimensionless; ``isValid`` says so.
    public var ratio: Bool

    /// Creates a dimension.
    public init(
        lengthPower: Int,
        angle: Bool = false,
        currencyCode: String? = nil,
        ratio: Bool = false
    ) {
        self.lengthPower = lengthPower
        self.angle = angle
        self.currencyCode = currencyCode
        self.ratio = ratio
    }

    /// A dimensionless count, for example a Count markup total.
    public static let count = QuantityDimension(lengthPower: 0)
    /// A length, stored in metres.
    public static let length = QuantityDimension(lengthPower: 1)
    /// An area, stored in square metres.
    public static let area = QuantityDimension(lengthPower: 2)
    /// A volume, stored in cubic metres.
    public static let volume = QuantityDimension(lengthPower: 3)
    /// An angle, stored in radians.
    public static let angle = QuantityDimension(lengthPower: 0, angle: true)
    /// A dimensionless ratio such as a slope ratio or a waste factor. **Not** additive with
    /// ``count`` (ADR-0014).
    public static let ratio = QuantityDimension(lengthPower: 0, ratio: true)

    /// A monetary dimension for the given ISO 4217 code.
    public static func currency(_ code: String) -> QuantityDimension {
        QuantityDimension(lengthPower: 0, currencyCode: code)
    }

    /// True when the dimension carries no length, no angle and no currency. Both ``count`` and
    /// ``ratio`` are dimensionless; the tag distinguishes them under the sum rule only.
    public var isDimensionless: Bool { lengthPower == 0 && !angle && currencyCode == nil }

    /// Whether the tag is where it is allowed to be. The contracts' `validate()` throws on a
    /// ratio-tagged length, angle or currency; this mirror has no throwing entry point, so the
    /// same rule is offered as a question a decoder and a test can ask.
    public var isValid: Bool { !ratio || isDimensionless }

    /// Whether two quantities of these dimensions may be added or aggregated.
    ///
    /// Incompatible dimensions are never summed into the same ledger cell — and since
    /// ADR-0014 that includes a ratio meeting a count.
    public func isCompatible(with other: QuantityDimension) -> Bool { self == other }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case lengthPower, angle, currencyCode, ratio
    }

    /// Encodes `ratio` **only when it is set**, so every dimension that existed before
    /// ADR-0014 keeps its byte-identical encoded form and a stored count stays a stored count.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lengthPower, forKey: .lengthPower)
        try container.encode(angle, forKey: .angle)
        try container.encodeIfPresent(currencyCode, forKey: .currencyCode)
        if ratio { try container.encode(true, forKey: .ratio) }
    }

    /// A payload without a `ratio` key decodes as a count, exactly as the contracts' decoder
    /// does: before ADR-0014 a stored ratio and a stored count were the same bytes, so nothing
    /// here can tell them apart. The consumer that knows what a stored dimensionless value
    /// *means* — a ledger column's declared dimension — re-tags it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lengthPower: try container.decodeIfPresent(Int.self, forKey: .lengthPower) ?? 0,
            angle: try container.decodeIfPresent(Bool.self, forKey: .angle) ?? false,
            currencyCode: try container.decodeIfPresent(String.self, forKey: .currencyCode),
            ratio: try container.decodeIfPresent(Bool.self, forKey: .ratio) ?? false
        )
    }

    /// A localized description used in error messages and VoiceOver output.
    public var displayName: String {
        if currencyCode != nil {
            return NSLocalizedString("Currency", comment: "Quantity dimension name")
        }
        if angle {
            return NSLocalizedString("Angle", comment: "Quantity dimension name")
        }
        if ratio {
            return NSLocalizedString("Ratio", comment: "Quantity dimension name")
        }
        switch lengthPower {
        case 0: return NSLocalizedString("Count", comment: "Quantity dimension name")
        case 1: return NSLocalizedString("Length", comment: "Quantity dimension name")
        case 2: return NSLocalizedString("Area", comment: "Quantity dimension name")
        case 3: return NSLocalizedString("Volume", comment: "Quantity dimension name")
        default: return NSLocalizedString("Unsupported Dimension", comment: "Quantity dimension name")
        }
    }
}

/// Errors raised by dimension-safe arithmetic in the presentation layer.
public enum QuantityError: Error, Hashable, Sendable {

    /// Two quantities with different dimensions were combined.
    case incompatibleDimensions(QuantityDimension, QuantityDimension)
    /// A display unit was requested that does not match the quantity's dimension.
    case unitDimensionMismatch(expected: QuantityDimension, actual: QuantityDimension)

    /// A localized, user-facing explanation. Never shown as a raw error dump.
    public var localizedDescription: String {
        switch self {
        case let .incompatibleDimensions(lhs, rhs):
            let format = NSLocalizedString(
                "%1$@ and %2$@ cannot be combined.",
                comment: "Error shown when two quantities of different dimensions are added"
            )
            return String(format: format, lhs.displayName, rhs.displayName)
        case let .unitDimensionMismatch(expected, actual):
            let format = NSLocalizedString(
                "This unit measures %1$@, but the value is a %2$@.",
                comment: "Error shown when a display unit does not match the quantity dimension"
            )
            return String(format: format, expected.displayName, actual.displayName)
        }
    }
}
