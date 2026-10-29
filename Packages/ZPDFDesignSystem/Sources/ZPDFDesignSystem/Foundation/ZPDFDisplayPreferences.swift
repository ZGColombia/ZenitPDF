import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The system display settings the components honour beyond Reduce Motion (NL-PLAT-20):
/// **Reduce Transparency** — translucent tints become solid surfaces — and **Differentiate
/// Without Color** — every state that has a colour also has a shape that differs in greyscale.
public struct ZPDFDisplayPreferences: Sendable, Equatable {
    public var reduceTransparency: Bool
    public var differentiateWithoutColor: Bool

    public init(reduceTransparency: Bool = false, differentiateWithoutColor: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.differentiateWithoutColor = differentiateWithoutColor
    }

    /// What the person chose in System Settings ▸ Accessibility ▸ Display.
    @MainActor public static var system: ZPDFDisplayPreferences {
        #if canImport(AppKit)
        let workspace = NSWorkspace.shared
        return ZPDFDisplayPreferences(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                                      differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor)
        #else
        return ZPDFDisplayPreferences()
        #endif
    }
}

private struct ZPDFDisplayPreferencesKey: EnvironmentKey {
    static let defaultValue: ZPDFDisplayPreferences? = nil
}

extension EnvironmentValues {
    /// An override of the system display settings, for previews and snapshot tests; `nil` reads
    /// the system's.
    public var zpdfDisplayPreferences: ZPDFDisplayPreferences? {
        get { self[ZPDFDisplayPreferencesKey.self] }
        set { self[ZPDFDisplayPreferencesKey.self] = newValue }
    }
}

/// How a status pill is painted under the display settings. Pure, so the rule is testable.
public struct ZPDFStatusPillPaint: Sendable, Equatable {
    /// Opacity of the severity tint behind the text; `1` means a solid surface instead.
    public var fillOpacity: Double
    /// Whether the fill is the opaque panel surface rather than a translucent tint.
    public var solidSurface: Bool
    public var strokeOpacity: Double
    public var strokeWidth: CGFloat
    /// The border's dash pattern; empty for a solid border.
    public var dash: [CGFloat]

    public static func paint(severity: ZPDFSeverity, preferences: ZPDFDisplayPreferences) -> ZPDFStatusPillPaint {
        var paint = ZPDFStatusPillPaint(fillOpacity: 0.14, solidSurface: false, strokeOpacity: 0.55,
                                        strokeWidth: ZPDFStroke.regular, dash: [])
        if preferences.reduceTransparency {
            paint.fillOpacity = 1
            paint.solidSurface = true
            paint.strokeOpacity = 1
        }
        if preferences.differentiateWithoutColor {
            // A border that tells the severities apart in greyscale, beside the glyph and the text.
            switch severity {
            case .warning: paint.dash = [3, 2]
            case .danger: paint.strokeWidth = ZPDFStroke.regular * 2
            case .success: paint.dash = [1, 2]
            default: break
            }
            paint.strokeOpacity = 1
        }
        return paint
    }
}
