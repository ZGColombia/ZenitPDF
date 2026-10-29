import AppKit
import SwiftUI

/// A plain sRGB colour value. `Sendable`, so palette tables can live in `let` constants and
/// cross actor boundaries without touching AppKit.
public struct ZPDFRGBA: Hashable, Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Builds a colour from a 24-bit `0xRRGGBB` literal.
    public init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    /// `#RRGGBB` uppercase, ignoring alpha. Useful for design-token export and diagnostics.
    public var hexString: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// A non-dynamic `NSColor` in the sRGB space.
    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// A non-dynamic SwiftUI `Color` in the sRGB space.
    public var color: Color {
        Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }

    /// WCAG relative luminance, used by the contrast diagnostics.
    public var relativeLuminance: CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// This colour drawn over `ground`, as the opaque colour a person actually sees.
    ///
    /// Contrast is a property of what reaches the eye, and a translucent hairline over a dark
    /// panel is nowhere near as light as its own declared white. Measuring the declared colour
    /// is how a border at 28 % white was recorded as passing when it renders at 2.4:1.
    public func composited(over ground: ZPDFRGBA) -> ZPDFRGBA {
        guard alpha < 1 else { return self }
        let a = max(0, min(1, alpha))
        return ZPDFRGBA(
            red: a * red + (1 - a) * ground.red,
            green: a * green + (1 - a) * ground.green,
            blue: a * blue + (1 - a) * ground.blue,
            alpha: 1
        )
    }

    /// WCAG contrast ratio against another opaque colour (1.0 ... 21.0).
    public func contrastRatio(against other: ZPDFRGBA) -> CGFloat {
        let a = relativeLuminance
        let b = other.relativeLuminance
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
