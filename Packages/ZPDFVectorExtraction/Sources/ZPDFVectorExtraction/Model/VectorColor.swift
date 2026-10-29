import Foundation

/// The paint colour a primitive was filled or stroked with, as sRGB-ish components.
///
/// **Not colour-managed.** The components are the PDF's device values mapped by the naive
/// textbook formulas below and are meant for coarse decisions — "is this an opaque white
/// knockout fill or ink?", "which of these two regions is red?" — never for proofing:
///
/// | Space | Formula |
/// |---|---|
/// | `DeviceGray` `g` | `r = g = b = gray` |
/// | `DeviceRGB` `r g b` | taken as sRGB unchanged |
/// | `DeviceCMYK` `c m y k` | `r = (1 − c)(1 − k)`, `g = (1 − m)(1 − k)`, `b = (1 − y)(1 − k)` |
///
/// `ICCBased` spaces with `/N` 1, 3 or 4 and the `CalGray`/`CalRGB` spaces are read as
/// the device space with the same component count; their profiles are ignored. A colour
/// the extractor cannot state without guessing — `Pattern` (tiling or shading), `Indexed`,
/// `Separation`, `DeviceN`, `Lab`, an unknown resource, unreadable operands — is not a
/// `VectorColor` at all: the primitive's colour is `nil`.
///
/// ``alpha`` is the constant alpha from the `/ExtGState` in force (`ca` for fill, `CA`
/// for stroke), `1` when none was set. Soft masks and blend modes are not composited.
///
/// Every component is clamped to `0…1` (PDF 32000-1 8.6.4: out-of-range components are
/// "adjusted to the nearest valid value").
public struct VectorColor: Sendable, Hashable {
    /// The four components as 8-bit channels, packed `R << 24 | G << 16 | B << 8 | A`.
    ///
    /// Eight bits per channel is the precision of the sRGB values a renderer or an importer
    /// uses, and it keeps two optional colours on a ``VectorPrimitive`` to 9 bytes instead of
    /// 66: storing four `Double`s grew every primitive from 232 to 312 bytes (+34 %), which is
    /// paid on every extracted page (BH-167 follow-up). A component `c` is
    /// stored as `round(c * 255)`, so `0` and `1` are exact and every other value is within
    /// 1/510 of what the file said.
    public let rgba: UInt32

    /// Red, `0…1`, in steps of 1/255.
    public var red: Double { Self.unit(rgba >> 24) }
    /// Green, `0…1`, in steps of 1/255.
    public var green: Double { Self.unit(rgba >> 16) }
    /// Blue, `0…1`, in steps of 1/255.
    public var blue: Double { Self.unit(rgba >> 8) }
    /// Alpha, `0…1`, in steps of 1/255.
    public var alpha: Double { Self.unit(rgba) }

    /// Components are clamped to `0…1` (a non-finite component becomes `0`) and rounded to the
    /// nearest 1/255.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        rgba = Self.channel(red) << 24 | Self.channel(green) << 16 | Self.channel(blue) << 8 | Self.channel(alpha)
    }

    /// A colour from its packed channels (see ``rgba``).
    public init(rgba: UInt32) {
        self.rgba = rgba
    }

    /// `DeviceGray`: `r = g = b = gray`.
    public init(deviceGray gray: Double, alpha: Double = 1) {
        self.init(red: gray, green: gray, blue: gray, alpha: alpha)
    }

    /// `DeviceCMYK`, naive and not colour-managed:
    /// `r = (1 − c)(1 − k)`, `g = (1 − m)(1 − k)`, `b = (1 − y)(1 − k)`.
    public init(deviceCyan cyan: Double, magenta: Double, yellow: Double, black: Double, alpha: Double = 1) {
        let c = Self.clamp(cyan), m = Self.clamp(magenta), y = Self.clamp(yellow), k = Self.clamp(black)
        self.init(red: (1 - c) * (1 - k), green: (1 - m) * (1 - k), blue: (1 - y) * (1 - k), alpha: alpha)
    }

    /// `true` for exactly `(1, 1, 1, 1)`: paper-white paint that covers what is under it.
    /// A white background or knockout fill, not ink.
    public var isOpaqueWhite: Bool { rgba == 0xFFFF_FFFF }

    /// The same colour with another alpha.
    public func withAlpha(_ alpha: Double) -> VectorColor {
        VectorColor(rgba: (rgba & 0xFFFF_FF00) | Self.channel(alpha))
    }

    public static let black = VectorColor(red: 0, green: 0, blue: 0)
    public static let white = VectorColor(red: 1, green: 1, blue: 1)

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(1, Swift.max(0, value))
    }

    private static func channel(_ value: Double) -> UInt32 {
        UInt32((clamp(value) * 255).rounded())
    }

    private static func unit(_ bits: UInt32) -> Double {
        Double(bits & 0xFF) / 255
    }
}

/// Coded as four named components, the shape the type had before its channels were packed,
/// so a stored value decodes either way.
extension VectorColor: Codable {
    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try container.decode(Double.self, forKey: .red),
            green: try container.decode(Double.self, forKey: .green),
            blue: try container.decode(Double.self, forKey: .blue),
            alpha: try container.decode(Double.self, forKey: .alpha)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(red, forKey: .red)
        try container.encode(green, forKey: .green)
        try container.encode(blue, forKey: .blue)
        try container.encode(alpha, forKey: .alpha)
    }
}
