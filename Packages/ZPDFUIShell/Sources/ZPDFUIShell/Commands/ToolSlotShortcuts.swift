import AppKit
import Foundation
import ZPDFUIPresentation

/// The number-key shortcuts for the first nine slots of the active tool set.
///
/// # Why these are not nine entries in ``ZPDFCommandTable/standard``
///
/// Everything in that table becomes a menu item: the app target walks it and installs one row
/// per command. Nine rows reading *Tool 1 … Tool 9* would be nine controls whose meaning
/// changes with the open set and whose titles cannot say so — and, until something serviced
/// them, nine controls that do nothing — a control that promises an action and performs none.
///
/// So the slots are declared **here**, as their own part of the keyboard map, and the table is
/// still the authority on conflicts: ``conflicts(with:)`` asks it whether any command reachable
/// on the canvas already claims a bare digit. A shortcut that is not in the map's conflict
/// audit is a shortcut that will one day be claimed twice.
///
/// # The context rule
///
/// Bare digits, no modifier. That is only safe under the same rule the canvas-scoped commands
/// already follow — ``ZPDFCommandContext/canvas``: the canvas is first responder and no text is
/// being edited. Typing `3` into a Text markup, into the Tool Library filter or into the zoom
/// field must type a `3`, and ``ToolSlotKeyRouter`` is where that is enforced.
public enum ToolSlotShortcut {

    /// The context these shortcuts live in. Not configurable: a bare digit is only ever
    /// available where a bare digit cannot be text.
    public static let context: ZPDFCommandContext = .canvas

    /// The keyboard binding for a one-based slot, or `nil` outside `1...9`.
    public static func binding(slot: Int) -> ZPDFKeyBinding? {
        guard let key = ToolSlotOrder.displayString(slot: slot) else { return nil }
        return ZPDFKeyBinding(
            key: key,
            modifiers: [],
            displayKey: key,
            spokenKey: key
        )
    }

    /// Every slot binding, slot `1` first.
    public static var bindings: [ZPDFKeyBinding] {
        (1...ToolSlotOrder.slotCount).compactMap { binding(slot: $0) }
    }

    /// The chords the slots claim, for a conflict audit.
    public static var chords: Set<String> { Set(bindings.map(\.chord)) }

    /// Every chord a slot can arrive as: the bare digit, and the same digit with Shift, which is
    /// how a layout that needs Shift for its digit row delivers it (BH-283). A command claiming
    /// either would fight a slot key, so the audit checks both.
    public static var auditChords: Set<String> {
        chords.union(bindings.map { ZPDFKeyBinding(
            key: $0.key,
            modifiers: [.shift],
            displayKey: $0.displayKey,
            spokenKey: $0.spokenKey
        ).chord })
    }

    /// The slot a key press names, or `nil` when the press is not a bare digit `1...9`.
    ///
    /// - Parameters:
    ///   - characters: `NSEvent.charactersIgnoringModifiers`. That property ignores every
    ///     modifier **except Shift**, so on a layout whose digit row needs Shift (French AZERTY:
    ///     the unshifted key reports `&`) only the shifted press reports a digit at all.
    ///   - modifiers: the live modifier state, already reduced to the four Zenit models.
    ///
    /// Shift alone is therefore accepted **when the press still reports a digit** (BH-283).
    /// That cannot steal a US-layout shortcut: there, Shift-3 reports `#`, never `3`, so a
    /// shifted press that reports a digit only happens on a layout where Shift is how a digit is
    /// typed. Command, Option and Control still make the press something else.
    public static func slot(
        forCharactersIgnoringModifiers characters: String?,
        modifiers: ZPDFModifierFlags
    ) -> Int? {
        guard modifiers.isEmpty || modifiers == [.shift] else { return nil }
        guard let characters, characters.count == 1 else { return nil }
        guard let digit = Int(characters), (1...ToolSlotOrder.slotCount).contains(digit) else {
            return nil
        }
        return digit
    }

    /// The same lookup straight off an `NSEvent`.
    public static func slot(for event: NSEvent) -> Int? {
        slot(
            forCharactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: ZPDFModifierFlags(event.modifierFlags)
        )
    }

    /// Commands in the map that would fight a slot key.
    ///
    /// A command conflicts when it claims a bare digit in any context that is live while the
    /// canvas has focus: the canvas itself, the narrower drawing context inside it, and the
    /// application context both inherit from. A `.textEditing` command claiming a digit is not
    /// a conflict — the slots are refused while text is being edited, which is the same
    /// partition drawn from the other side.
    public static func conflicts(with table: ZPDFCommandTable) -> [ZPDFCommandID] {
        let live: Set<ZPDFCommandContext> = [.canvas, .canvasDrawing, .application]
        return table.boundCommands
            .filter { live.contains($0.context) }
            .filter { auditChords.contains($0.binding?.chord ?? "") }
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
    }
}

/// Single-key tool shortcuts on the canvas (IM-116).
///
/// Select, Pan, Zoom, Text, Callout, Shapes, Measure, Cutout and Calibrate had no shortcut at
/// all, so switching tools took the mouse and no tooltip could name a key. They are declared in
/// ``ZPDFCommandTable/standard`` as ``ZPDFCommandContext/canvas`` letters — so the conflict,
/// shadow and reserved-chord audits see them like any other binding — and served here, because
/// a binding without `⌘` never becomes a menu key equivalent (it would swallow the letter from
/// every text field in the application).
///
/// The same context rule as the number-key slots: the canvas has the keyboard and no text is
/// being edited. Typing `t` into a Text markup types a `t`.
public enum CanvasToolShortcut {

    /// Whether a binding is one of the canvas's single-letter tool keys: canvas-scoped, a
    /// letter, and no modifier other than Shift.
    public static func isCanvasLetter(_ command: ZPDFCommand) -> Bool {
        guard command.context == .canvas, let binding = command.binding else { return false }
        guard binding.modifiers.isSubset(of: [.shift]) else { return false }
        guard binding.key.count == 1, let scalar = binding.key.unicodeScalars.first else { return false }
        return CharacterSet.lowercaseLetters.contains(scalar)
    }

    /// Every single-letter canvas command in a table.
    public static func commands(in table: ZPDFCommandTable) -> [ZPDFCommand] {
        table.boundCommands.filter(isCanvasLetter)
    }

    /// The command a key press names, or `nil` when it names none.
    ///
    /// - Parameters:
    ///   - characters: `NSEvent.charactersIgnoringModifiers` — Shift is reflected in it, so
    ///     it is lower-cased before it is compared with the stored lower-case key.
    ///   - modifiers: the live modifier state; it must equal the binding's exactly.
    public static func command(
        forCharactersIgnoringModifiers characters: String?,
        modifiers: ZPDFModifierFlags,
        in table: ZPDFCommandTable = .standard
    ) -> ZPDFCommandID? {
        guard let characters, characters.count == 1 else { return nil }
        let key = characters.lowercased()
        return commands(in: table).first { command in
            command.binding?.key == key && command.binding?.modifiers == modifiers
        }?.id
    }
}
