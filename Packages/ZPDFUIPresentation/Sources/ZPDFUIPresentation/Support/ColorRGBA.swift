import Foundation

/// A device-independent, storage-friendly colour used by every presentation value type.
///
/// Components are extended-sRGB in the closed range `0...1`. The presentation layer never
/// vends `NSColor`/`Color`; the design system package converts these values when it draws,
/// which keeps every summary type `Sendable` and `Codable` across actor boundaries.
public struct ColorRGBA: Codable, Hashable, Sendable {

    /// Red component, `0...1`.
    public var red: Double
    /// Green component, `0...1`.
    public var green: Double
    /// Blue component, `0...1`.
    public var blue: Double
    /// Opacity, `0...1`.
    public var alpha: Double

    private enum CodingKeys: String, CodingKey {
        case red, green, blue, alpha
    }

    /// Decodes a colour **through the clamp** (BH-793). The synthesized decoder stored
    /// whatever a project database or a job-template file carried, so a `"red": 2` or a
    /// `1e300` escaped the documented `0...1` range the rest of the type relies on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try container.decode(Double.self, forKey: .red),
            green: try container.decode(Double.self, forKey: .green),
            blue: try container.decode(Double.self, forKey: .blue),
            alpha: try container.decode(Double.self, forKey: .alpha)
        )
    }

    /// Creates a colour, clamping every component into `0...1`.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = ColorRGBA.clamp(red)
        self.green = ColorRGBA.clamp(green)
        self.blue = ColorRGBA.clamp(blue)
        self.alpha = ColorRGBA.clamp(alpha)
    }

    /// Creates a colour from a packed `0xRRGGBB` value.
    ///
    /// - Parameters:
    ///   - packed: 24-bit RGB value, for example `0x50D6DE`.
    ///   - alpha: Opacity, `0...1`.
    public init(hex packed: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((packed >> 16) & 0xFF) / 255.0,
            green: Double((packed >> 8) & 0xFF) / 255.0,
            blue: Double(packed & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    /// The colour as an uppercase `#RRGGBB` string, ignoring ``alpha``.
    public var hexString: String {
        // BH-793: a decoded colour has not been through the clamping initialiser; clamp here
        // too, so 1e300 cannot trap `Int(_:)` and 2 cannot print "#1FE…".
        let r = Int((ColorRGBA.clamp(red) * 255).rounded())
        let g = Int((ColorRGBA.clamp(green) * 255).rounded())
        let b = Int((ColorRGBA.clamp(blue) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Returns the same colour at a different opacity.
    public func withAlpha(_ newAlpha: Double) -> ColorRGBA {
        ColorRGBA(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    /// Relative luminance per WCAG 2.1, used for contrast assertions in UI tests.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG 2.1 contrast ratio between two opaque colours, `1...21`.
    public func contrastRatio(against other: ColorRGBA) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        let lighter = Swift.max(a, b)
        let darker = Swift.min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func clamp(_ value: Double) -> Double {
        Swift.min(1, Swift.max(0, value))
    }
}

extension ColorRGBA {

    /// The Zenit "Graphite Workshop" palette, dark appearance first.
    ///
    /// These are presentation-layer tokens so that mock data and accessibility tests can
    /// reference the exact approved hex values. The canonical asset catalogue and dynamic
    /// `NSColor` definitions live in the design system package.
    public enum Zenit {

        /// Tokens for the dark appearance (the default Zenit appearance).
        public enum Dark {
            /// `#101317` — window and canvas backdrop.
            public static let background = ColorRGBA(hex: 0x101317)
            /// `#171B21` — panel and sidebar surface.
            public static let surface = ColorRGBA(hex: 0x171B21)
            /// `#202630` — raised surface: popovers, inspector cards, hovered rows.
            public static let elevated = ColorRGBA(hex: 0x202630)
            /// `rgba(255, 255, 255, 0.10)` — hairline separators and control borders.
            public static let border = ColorRGBA(red: 1, green: 1, blue: 1, alpha: 0.10)
            /// `#F5F7F9` — primary text.
            public static let text = ColorRGBA(hex: 0xF5F7F9)
            /// `#9DA8B4` — secondary text and disabled glyphs.
            public static let secondary = ColorRGBA(hex: 0x9DA8B4)
            /// `#50D6DE` — Zenit cyan, the measurement accent.
            public static let cyan = ColorRGBA(hex: 0x50D6DE)
            /// `#6E9FFF` — Zenit blue, the interactive accent.
            public static let blue = ColorRGBA(hex: 0x6E9FFF)
            /// `#4FD095` — Zenit green, success and accepted states.
            public static let green = ColorRGBA(hex: 0x4FD095)
            /// `#EFB957` — warning state.
            public static let warning = ColorRGBA(hex: 0xEFB957)
            /// `#F0616E` — danger state.
            public static let danger = ColorRGBA(hex: 0xF0616E)
            /// `#2B6CB0` — selection fill.
            public static let selection = ColorRGBA(hex: 0x2B6CB0)
        }

        /// Tokens for the light appearance.
        ///
        /// Green, warning, danger and selection are shared with ``Dark`` because the
        /// approved palette defines a single value for those semantic roles.
        public enum Light {
            /// `#F3F5F7` — window and canvas backdrop.
            public static let background = ColorRGBA(hex: 0xF3F5F7)
            /// `#FFFFFF` — panel and sidebar surface.
            public static let surface = ColorRGBA(hex: 0xFFFFFF)
            /// `#E9EEF2` — raised surface.
            public static let elevated = ColorRGBA(hex: 0xE9EEF2)
            /// `#D3DCE3` — hairline separators and control borders.
            public static let border = ColorRGBA(hex: 0xD3DCE3)
            /// `#11171D` — primary text.
            public static let text = ColorRGBA(hex: 0x11171D)
            /// `#5E6B77` — secondary text.
            public static let secondary = ColorRGBA(hex: 0x5E6B77)
            /// `#087D84` — Zenit cyan, darkened for light backgrounds.
            public static let cyan = ColorRGBA(hex: 0x087D84)
            /// `#245FAF` — Zenit blue, darkened for light backgrounds.
            public static let blue = ColorRGBA(hex: 0x245FAF)
            /// `#4FD095` — Zenit green.
            public static let green = ColorRGBA(hex: 0x4FD095)
            /// `#EFB957` — warning state.
            public static let warning = ColorRGBA(hex: 0xEFB957)
            /// `#F0616E` — danger state.
            public static let danger = ColorRGBA(hex: 0xF0616E)
            /// `#2B6CB0` — selection fill.
            public static let selection = ColorRGBA(hex: 0x2B6CB0)
        }
    }
}
