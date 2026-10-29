import Foundation

/// A device-independent sRGB colour with straight (non-premultiplied) alpha.
///
/// The contracts package owns its own colour type on purpose: nothing here may import AppKit,
/// SwiftUI or a `ZPDFUI*` package. The design system is the one place allowed to turn this value
/// into something drawable.
public struct RGBAColor: Codable, Hashable, Sendable {
    /// Red component, 0...1.
    public var red: Double
    /// Green component, 0...1.
    public var green: Double
    /// Blue component, 0...1.
    public var blue: Double
    /// Alpha component, 0...1. 0 is fully transparent.
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Returns the colour with every component clamped to 0...1.
    public func clampedToUnitRange() -> RGBAColor {
        func clamp(_ value: Double) -> Double {
            guard value.isFinite else { return 0.0 }
            return Swift.min(1.0, Swift.max(0.0, value))
        }
        return RGBAColor(red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: clamp(alpha))
    }

    public static let opaqueBlack = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let transparent = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}
