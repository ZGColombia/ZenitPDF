import AppKit
import Testing
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Design decision 2026-09-26 (r2-layers follow-up): ⌘[ and ⌘] are sheet history Back and
/// Forward, which the canvas takes before the menu (`PDFCanvasViewController.handleNavigationKey`),
/// and Arrange moved to ⌥⌘] / ⌥⌘[ and ⇧⌥⌘] / ⇧⌥⌘[.
///
/// Old: Edit ▸ Arrange held ⌘] and ⌘[ as well, so Bring Forward was unreachable from the keyboard
/// on the canvas and fired from everywhere else — one chord, two meanings. This suite holds every
/// chord of the menu bar (visible rows and their hidden twins) and the canvas's own key handlers
/// against each other.
@MainActor
@Suite(.appTierSerialised)
struct ShortcutChordUniquenessTests {

    /// A chord as the keyboard produces it: the unshifted key and the modifiers, so `"}"` with ⌘ and
    /// `"]"` with ⇧⌘ are the same chord, and an upper-case letter is its lower case with ⇧.
    struct Chord: Hashable, CustomStringConvertible {
        let key: String
        let modifiers: NSEvent.ModifierFlags.RawValue

        init(_ rawKey: String, _ rawModifiers: NSEvent.ModifierFlags) {
            var modifiers = rawModifiers.intersection([.command, .option, .control, .shift])
            var key = rawKey
            let shifted: [Character: Character] = [
                "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
                "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
                "\"": "'", "<": ",", ">": ".", "?": "/"
            ]
            if key.count == 1, let character = key.first {
                if let base = shifted[character] {
                    key = String(base)
                    modifiers.insert(.shift)
                } else if character.isLetter, character.isUppercase {
                    key = key.lowercased()
                    modifiers.insert(.shift)
                }
            }
            self.key = key
            self.modifiers = modifiers.rawValue
        }

        var description: String {
            let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + key
        }
    }

    /// Every chord of the built menu bar with the title that holds it.
    private func menuChords() -> [(chord: Chord, holder: String)] {
        var found: [(Chord, String)] = []
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    found.append((Chord(item.keyEquivalent, item.keyEquivalentModifierMask), "\(path) ▸ \(item.title)"))
                }
                if let submenu = item.submenu { walk(submenu, path: "\(path) ▸ \(submenu.title)") }
            }
        }
        walk(ZenitMenuBar.make(), path: "")
        return found
    }

    @Test("No two menu rows and no menu row and canvas key handler share a chord")
    func everyChordHasOneMeaning() {
        var holders: [Chord: [String]] = [:]
        for (chord, holder) in menuChords() { holders[chord, default: []].append(holder) }
        for equivalent in PDFCanvasViewController.navigationChords {
            holders[Chord(equivalent.key, equivalent.modifiers), default: []].append("Canvas ▸ sheet history")
        }
        // A hidden twin of a row repeats nothing: it is its own chord by construction. Anything
        // else held twice is two meanings for one chord.
        let clashes = holders.filter { $0.value.count > 1 }
            .map { "\($0.key): \($0.value.joined(separator: " | "))" }
            .sorted()
        #expect(clashes.isEmpty, "\(clashes)")
    }

    @Test("Arrange sits on ⌥⌘ chords; ⌘[ and ⌘] belong to the canvas's history")
    func arrangeChords() {
        func chord(_ command: ZenitAppCommand) -> Chord? {
            ZenitAppCommandTable.spec(for: command).keyEquivalent.map { Chord($0.key, $0.modifiers) }
        }
        #expect(chord(.bringForward) == Chord("]", [.command, .option]))
        #expect(chord(.sendBackward) == Chord("[", [.command, .option]))
        #expect(chord(.bringToFront) == Chord("]", [.command, .option, .shift]))
        #expect(chord(.sendToBack) == Chord("[", [.command, .option, .shift]))
        let history = Set(PDFCanvasViewController.navigationChords.map { Chord($0.key, $0.modifiers) })
        #expect(history == [Chord("[", [.command]), Chord("]", [.command])])
        // Show Next Tab's ⇧⌘] is not Bring to Front's ⇧⌥⌘].
        #expect(chord(.showNextTab) == Chord("]", [.command, .shift]))
    }
}
