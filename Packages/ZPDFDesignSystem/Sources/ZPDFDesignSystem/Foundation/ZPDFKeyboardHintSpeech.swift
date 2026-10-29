import Foundation

/// The spoken form of a printed keyboard shortcut such as `"⌥⌘I"`.
///
/// IM-059: every design-system control that shows a shortcut passed the printed string to
/// `accessibilityHint`, so VoiceOver read glyphs it cannot name. The shell's `ZPDFKeyBinding`
/// has a spoken form, but the controls only receive the display string — and fifteen call
/// sites across four packages pass it. Speaking the display string here fixes all of them at
/// once; a caller that has the binding's own spoken form may still pass it explicitly.
public enum ZPDFKeyboardHintSpeech {

    /// `"⌥⌘I"` → `"Option Command I"`, `"⇧⌘S"` → `"Shift Command S"`, `"⎋"` → `"Escape"`.
    public static func spoken(_ display: String) -> String {
        var parts: [String] = []
        var pending = ""
        func flush() {
            if !pending.isEmpty { parts.append(pending); pending = "" }
        }
        for character in display {
            if let name = name(of: character) {
                flush()
                parts.append(name)
            } else if character.isWhitespace {
                flush()
            } else {
                pending.append(character)
            }
        }
        flush()
        return parts.joined(separator: " ")
    }

    private static func name(of character: Character) -> String? {
        switch character {
        case "\u{2318}": return NSLocalizedString("Command", comment: "Modifier key name")
        case "\u{2325}": return NSLocalizedString("Option", comment: "Modifier key name")
        case "\u{21E7}": return NSLocalizedString("Shift", comment: "Modifier key name")
        case "\u{2303}": return NSLocalizedString("Control", comment: "Modifier key name")
        case "\u{238B}": return NSLocalizedString("Escape", comment: "Key name")
        case "\u{21A9}", "\u{23CE}": return NSLocalizedString("Return", comment: "Key name")
        case "\u{232B}": return NSLocalizedString("Delete", comment: "Key name")
        case "\u{2326}": return NSLocalizedString("Forward Delete", comment: "Key name")
        case "\u{21E5}": return NSLocalizedString("Tab", comment: "Key name")
        case "\u{2190}": return NSLocalizedString("Left Arrow", comment: "Key name")
        case "\u{2192}": return NSLocalizedString("Right Arrow", comment: "Key name")
        case "\u{2191}": return NSLocalizedString("Up Arrow", comment: "Key name")
        case "\u{2193}": return NSLocalizedString("Down Arrow", comment: "Key name")
        case "\u{2423}": return NSLocalizedString("Space", comment: "Key name")
        case "\u{21DE}": return NSLocalizedString("Page Up", comment: "Key name")
        case "\u{21DF}": return NSLocalizedString("Page Down", comment: "Key name")
        case "\u{2196}": return NSLocalizedString("Home", comment: "Key name")
        case "\u{2198}": return NSLocalizedString("End", comment: "Key name")
        default: return nil
        }
    }
}
