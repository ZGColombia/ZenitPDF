import AppKit
import SwiftUI

/// The four appearance permutations the Graphite Workshop design system resolves against:
/// light / dark, each with a normal and an Increase Contrast variant.
public enum ZPDFAppearanceVariant: String, CaseIterable, Sendable, Hashable {
    case light
    case dark
    case lightHighContrast
    case darkHighContrast

    /// The AppKit appearance name that selects this variant.
    public var appearanceName: NSAppearance.Name {
        switch self {
        case .light: return .aqua
        case .dark: return .darkAqua
        case .lightHighContrast: return .accessibilityHighContrastAqua
        case .darkHighContrast: return .accessibilityHighContrastDarkAqua
        }
    }

    /// `true` when the variant is one of the dark appearances.
    public var isDark: Bool {
        self == .dark || self == .darkHighContrast
    }

    /// The SwiftUI colour scheme matching this variant.
    public var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    /// An `NSAppearance` instance for this variant, or `nil` if the system cannot vend one.
    public var appearance: NSAppearance? {
        NSAppearance(named: appearanceName)
    }

    /// Whether the user has turned on Increase Contrast in System Settings.
    ///
    /// This has to be consulted separately from the appearance. macOS only vends the
    /// `NSAppearanceNameAccessibility*` appearances while the setting is actually on —
    /// `NSAppearance(named: .accessibilityHighContrastAqua)` hands back plain Aqua otherwise —
    /// so an appearance name alone cannot tell the whole story.
    public static var systemIncreaseContrastEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Maps an arbitrary `NSAppearance` onto the closest Zenit variant.
    ///
    /// An explicit accessibility appearance name wins. Otherwise the appearance decides
    /// light vs dark and the system setting decides normal vs Increase Contrast.
    public static func matching(_ appearance: NSAppearance) -> ZPDFAppearanceVariant {
        switch appearance.name {
        case .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
            return .darkHighContrast
        case .accessibilityHighContrastAqua, .accessibilityHighContrastVibrantLight:
            return .lightHighContrast
        default:
            break
        }

        let isDark: Bool
        switch appearance.name {
        case .darkAqua, .vibrantDark:
            isDark = true
        case .aqua, .vibrantLight:
            isDark = false
        default:
            // Order matters: `bestMatch(from:)` returns the first compatible name in the list.
            isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        switch (isDark, systemIncreaseContrastEnabled) {
        case (true, true): return .darkHighContrast
        case (true, false): return .dark
        case (false, true): return .lightHighContrast
        case (false, false): return .light
        }
    }

    /// Maps a SwiftUI environment pair onto a variant, for views that resolve colours by hand.
    public static func matching(scheme: ColorScheme, contrast: ColorSchemeContrast) -> ZPDFAppearanceVariant {
        switch (scheme, contrast) {
        case (.dark, .increased): return .darkHighContrast
        case (.dark, _): return .dark
        case (_, .increased): return .lightHighContrast
        default: return .light
        }
    }
}
