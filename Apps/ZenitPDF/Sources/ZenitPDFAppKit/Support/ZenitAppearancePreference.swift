import AppKit
import Foundation
import ZPDFUIPresentation

/// Settings ▸ General ▸ Appearance: Dark (the default), Light, or Match System.
///
/// The 2026-09-23 main-window design is dark chrome, and the window follows it whatever the
/// system appearance is — that is the default. Light is a first-class choice, not a fallback:
/// every design-system token carries a light value, so the whole interface re-resolves when the
/// appearance changes. Match System hands the decision back to macOS.
public enum ZenitAppearancePreference: String, CaseIterable, Sendable {
    case dark
    case light
    case system

    /// The default for a person who has never chosen.
    public static let defaultValue: ZenitAppearancePreference = .dark

    /// The defaults key the choice is stored under.
    public static let defaultsKey = "Zenit.Appearance"

    /// The title in the Settings popup.
    public var title: String {
        switch self {
        case .dark: return NSLocalizedString("Dark", comment: "Settings ▸ Appearance choice")
        case .light: return NSLocalizedString("Light", comment: "Settings ▸ Appearance choice")
        case .system: return NSLocalizedString("Match System", comment: "Settings ▸ Appearance choice")
        }
    }

    /// The appearance to install, or `nil` to follow the system.
    @MainActor
    public var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }

    /// The stored choice, or ``defaultValue`` when there is none or it is unreadable.
    public static func load(from defaults: any ZPDFDefaultsStoring) -> ZenitAppearancePreference {
        guard let data = defaults.persistedData(forKey: defaultsKey),
              let raw = String(data: data, encoding: .utf8),
              let value = ZenitAppearancePreference(rawValue: raw)
        else { return defaultValue }
        return value
    }

    /// Stores the choice.
    public func save(to defaults: any ZPDFDefaultsStoring) {
        defaults.setPersistedData(Data(rawValue.utf8), forKey: Self.defaultsKey)
    }

    /// Installs the choice on an appearance target: the application in the product, a window
    /// that is never shown in a test (a test must not repaint the user's whole application).
    @MainActor
    public func apply(to target: any NSAppearanceCustomization) {
        target.appearance = nsAppearance
    }

    /// The process's appearance store: the real preferences in the assembled bundle, a scratch
    /// store anywhere else (``ZenitProcessDefaults``). Never `UserDefaults.standard` from a test.
    @MainActor
    public static var processDefaults: any ZPDFDefaultsStoring { ZenitProcessDefaults.layout }

    /// Reads the stored choice and installs it on the application. Called once at launch.
    @MainActor
    public static func applyStored(to application: NSApplication) {
        load(from: processDefaults).apply(to: application)
    }
}
