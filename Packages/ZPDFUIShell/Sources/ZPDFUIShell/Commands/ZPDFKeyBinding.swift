import AppKit
import Foundation

/// The modifier keys a Zenit command can require.
///
/// This mirrors `NSEvent.ModifierFlags` but is a `Sendable`, `Codable` value type so the
/// command table can be declared, compared and tested without touching AppKit state.
public struct ZPDFModifierFlags: OptionSet, Codable, Hashable, Sendable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The Command key.
    public static let command = ZPDFModifierFlags(rawValue: 1 << 0)
    /// The Shift key.
    public static let shift = ZPDFModifierFlags(rawValue: 1 << 1)
    /// The Option key.
    public static let option = ZPDFModifierFlags(rawValue: 1 << 2)
    /// The Control key.
    public static let control = ZPDFModifierFlags(rawValue: 1 << 3)

    /// The four modifiers Zenit models, read out of a live `NSEvent`.
    ///
    /// Only the device-independent bits are consulted, and only the four this type names, so
    /// Caps Lock, Fn, the numeric-pad bit and the left/right variants can never make a plain
    /// key press look modified. A shortcut that stops working because the number row happens
    /// to set the numeric-pad flag is the kind of bug nobody finds twice.
    public init(_ flags: NSEvent.ModifierFlags) {
        var value: ZPDFModifierFlags = []
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        if masked.contains(.command) { value.insert(.command) }
        if masked.contains(.shift) { value.insert(.shift) }
        if masked.contains(.option) { value.insert(.option) }
        if masked.contains(.control) { value.insert(.control) }
        self = value
    }

    /// The AppKit flags an `NSMenuItem` needs.
    public var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }

    /// The glyphs macOS prints in a menu, in Apple's canonical order.
    public var displayString: String {
        var text = ""
        if contains(.control) { text += "\u{2303}" }
        if contains(.option) { text += "\u{2325}" }
        if contains(.shift) { text += "\u{21E7}" }
        if contains(.command) { text += "\u{2318}" }
        return text
    }

    /// The spoken form, so VoiceOver never has to read a glyph it cannot name.
    public var spokenString: String {
        var parts: [String] = []
        if contains(.control) { parts.append(NSLocalizedString("Control", comment: "Modifier key name")) }
        if contains(.option) { parts.append(NSLocalizedString("Option", comment: "Modifier key name")) }
        if contains(.shift) { parts.append(NSLocalizedString("Shift", comment: "Modifier key name")) }
        if contains(.command) { parts.append(NSLocalizedString("Command", comment: "Modifier key name")) }
        return parts.joined(separator: " ")
    }
}

/// One keyboard shortcut, stored exactly as `NSMenuItem` wants it.
///
/// `key` is the literal `keyEquivalent` string: a lowercase character for letters and digits,
/// or a control character such as escape or return. `displayKey` is what a human sees, which
/// for control characters is a glyph rather than an invisible byte.
public struct ZPDFKeyBinding: Codable, Hashable, Sendable {

    /// The `NSMenuItem.keyEquivalent` value.
    public let key: String
    /// The modifiers required alongside ``key``.
    public let modifiers: ZPDFModifierFlags
    /// What the menu prints for ``key`` on its own, for example `"⎋"` or `"S"`.
    public let displayKey: String
    /// What VoiceOver says for ``key`` on its own, for example `"Escape"`.
    public let spokenKey: String

    /// Creates a binding from an explicit key equivalent.
    public init(key: String, modifiers: ZPDFModifierFlags, displayKey: String, spokenKey: String) {
        self.key = key
        self.modifiers = modifiers
        self.displayKey = displayKey
        self.spokenKey = spokenKey
    }

    /// The full printed shortcut, for example `"⇧⌘S"`.
    public var displayString: String { modifiers.displayString + displayKey }

    /// The full spoken shortcut, for example `"Shift Command S"`.
    public var spokenString: String {
        let modifierText = modifiers.spokenString
        return modifierText.isEmpty ? spokenKey : "\(modifierText) \(spokenKey)"
    }

    /// The identity a conflict check compares: the same physical chord.
    public var chord: String { "\(modifiers.rawValue):\(key.lowercased())" }
}

public extension ZPDFKeyBinding {

    /// A letter or digit shortcut, for example `.character("s", [.command])`.
    static func character(_ character: Character, _ modifiers: ZPDFModifierFlags) -> ZPDFKeyBinding {
        let lower = String(character).lowercased()
        return ZPDFKeyBinding(
            key: lower,
            modifiers: modifiers,
            displayKey: lower.uppercased(),
            spokenKey: lower.uppercased()
        )
    }

    /// The Escape key, with no modifiers by default.
    static func escape(_ modifiers: ZPDFModifierFlags = []) -> ZPDFKeyBinding {
        ZPDFKeyBinding(
            key: "\u{1B}",
            modifiers: modifiers,
            displayKey: "\u{238B}",
            spokenKey: NSLocalizedString("Escape", comment: "Key name spoken by VoiceOver")
        )
    }

    /// The Return key.
    static func `return`(_ modifiers: ZPDFModifierFlags = []) -> ZPDFKeyBinding {
        ZPDFKeyBinding(
            key: "\r",
            modifiers: modifiers,
            displayKey: "\u{21A9}",
            spokenKey: NSLocalizedString("Return", comment: "Key name spoken by VoiceOver")
        )
    }

    /// The Delete (backspace) key.
    static func delete(_ modifiers: ZPDFModifierFlags = []) -> ZPDFKeyBinding {
        ZPDFKeyBinding(
            key: "\u{8}",
            modifiers: modifiers,
            displayKey: "\u{232B}",
            spokenKey: NSLocalizedString("Delete", comment: "Key name spoken by VoiceOver")
        )
    }

    /// The Tab key.
    static func tab(_ modifiers: ZPDFModifierFlags = []) -> ZPDFKeyBinding {
        ZPDFKeyBinding(
            key: "\t",
            modifiers: modifiers,
            displayKey: "\u{21E5}",
            spokenKey: NSLocalizedString("Tab", comment: "Key name spoken by VoiceOver")
        )
    }

    /// The Up Arrow key.
    ///
    /// `NSUpArrowFunctionKey` (`U+F700`) is the value `NSMenuItem.keyEquivalent` expects for an
    /// arrow; the printed glyph is the ordinary arrow character, which is what macOS draws.
    static func arrowUp(_ modifiers: ZPDFModifierFlags = []) -> ZPDFKeyBinding {
        ZPDFKeyBinding(
            key: "\u{F700}",
            modifiers: modifiers,
            displayKey: "\u{2191}",
            spokenKey: NSLocalizedString("Up Arrow", comment: "Key name spoken by VoiceOver")
        )
    }

    /// The Down Arrow key.
    static func arrowDown(_ modifiers: ZPDFModifierFlags = []) -> ZPDFKeyBinding {
        ZPDFKeyBinding(
            key: "\u{F701}",
            modifiers: modifiers,
            displayKey: "\u{2193}",
            spokenKey: NSLocalizedString("Down Arrow", comment: "Key name spoken by VoiceOver")
        )
    }
}
