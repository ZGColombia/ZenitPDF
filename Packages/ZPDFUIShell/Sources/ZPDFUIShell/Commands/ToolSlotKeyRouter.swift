import Foundation
import ZPDFUIPresentation

/// Turns a bare number key into an armed preset.
///
/// The router is deliberately two halves. ``handleKey(characters:modifiers:focus:)`` is pure
/// decision-making over an explicit ``Focus``, so every rule below can be driven by a test
/// against the shipping presenter without an `NSEvent`, a window or a first responder. The
/// AppKit half — ``ProjectWindowLayoutController`` — does nothing but *observe* the focus and
/// hand it over, which is the part that cannot be tested headlessly and is therefore the part
/// that contains no rules.
@MainActor
public final class ToolSlotKeyRouter {

    /// Where the keyboard is pointing, reduced to the two facts the rule needs.
    public struct Focus: Hashable, Sendable {

        /// Whether the first responder is the canvas, or something inside it.
        public var isCanvasFirstResponder: Bool
        /// Whether text is being edited anywhere — a field editor, a text view, a Text markup.
        public var isEditingText: Bool

        /// Creates a focus reading.
        public init(isCanvasFirstResponder: Bool, isEditingText: Bool) {
            self.isCanvasFirstResponder = isCanvasFirstResponder
            self.isEditingText = isEditingText
        }

        /// The canvas has the keyboard and nothing is being typed into.
        public static let canvas = Focus(isCanvasFirstResponder: true, isEditingText: false)
        /// Nothing on the canvas has the keyboard.
        public static let elsewhere = Focus(isCanvasFirstResponder: false, isEditingText: false)
        /// A text field or a Text markup is being edited.
        public static let editingText = Focus(isCanvasFirstResponder: true, isEditingText: true)

        /// Whether a bare digit means a tool slot right now.
        ///
        /// Both halves are required, and the second is not implied by the first: the canvas's
        /// own Text markup editor is a text view *inside* the canvas, so "the canvas has focus"
        /// is true at the exact moment typing `3` must produce a `3`.
        public var acceptsToolSlotKeys: Bool { isCanvasFirstResponder && !isEditingText }
    }

    /// What the number keys reach into.
    private let presenter: any ToolLibraryPresenting

    /// Runs the command a single-letter canvas shortcut names (IM-116). Unset, the letters are
    /// passed on untouched — a key the window cannot service is never swallowed.
    public var performCommand: (@MainActor (ZPDFCommandID) -> Void)?

    /// The table the letter shortcuts are read from. `nil` — the window's router — reads
    /// ``ZPDFCommandTable/effective`` at key time, so a shortcut changed in Settings ▸ Shortcuts
    /// reaches an open window at once (R-074). A test injects a table.
    public var commandTable: ZPDFCommandTable?

    /// Asked before a key is taken as a tool slot or a tool shortcut: `true` leaves the key to
    /// the canvas.
    ///
    /// The window answers `true` for every tool key while the canvas owns the keyboard
    /// (ADR-0030 §5.7, §5.8; K-02): during a two-point pick, whose clicks go to the pick whatever
    /// the toolbar says; while a typed length is being entered; and while a shape a tool switch
    /// would throw away is in progress. Mid-shape A means "the next segment is an arc"
    /// (NL-MEASURE-05) and a digit starts a typed length (NL-MEASURE-18); any other tool key is
    /// refused by the canvas with a note.
    public var claimsDrawingKey: (@MainActor (_ characters: String, _ modifiers: ZPDFModifierFlags) -> Bool)?

    /// Asked after ``claimsDrawingKey`` and before a key is taken as a tool slot: `true` when the
    /// key went into the value the armed tool is asking for (L-103).
    ///
    /// While the tool options bar asks for a slope, a rise, a depth or a height that is still
    /// missing (the field is empty or unreadable), a number typed at the canvas is that number.
    /// It used to arm the Tool Library preset in its slot — "20" for a slope armed Interior Wall
    /// — and the next clicks recorded a wall area instead of the slope, with only the tool name
    /// in the status line changing. A tool whose field already holds a value (a preset's saved
    /// height, a slope typed earlier) is not asking, so the number arms its slot as before.
    public var takesParameterKey: (@MainActor (_ characters: String, _ modifiers: ZPDFModifierFlags) -> Bool)?

    /// Creates a router over one window's Tool Library.
    public init(presenter: any ToolLibraryPresenting) {
        self.presenter = presenter
    }

    /// The preset a one-based slot names, or `nil` when the active set is shorter than that.
    public func preset(inSlot slot: Int) -> ToolPresetSummary? {
        presenter.toolSlotPreset(slot)
    }

    /// Arms the preset in one slot.
    ///
    /// - Returns: `true` when a preset was armed. `false` for a slot the active set does not
    ///   fill — pressing `7` on a set of four tools arms nothing and, deliberately, does not
    ///   swallow the key either: an empty slot is not a command that silently succeeded.
    @discardableResult
    public func armSlot(_ slot: Int) -> Bool {
        guard let preset = preset(inSlot: slot) else { return false }
        presenter.activatePreset(id: preset.id)
        return true
    }

    /// Decides one key press.
    ///
    /// - Returns: `true` when the press was consumed as a tool slot, so the caller must not
    ///   pass it on.
    @discardableResult
    public func handleKey(
        characters: String?,
        modifiers: ZPDFModifierFlags,
        focus: Focus
    ) -> Bool {
        guard focus.acceptsToolSlotKeys else { return false }
        if let characters, let claimsDrawingKey, claimsDrawingKey(characters.lowercased(), modifiers) {
            return false
        }
        if let characters, let takesParameterKey, takesParameterKey(characters, modifiers) {
            return true
        }
        if let slot = ToolSlotShortcut.slot(
            forCharactersIgnoringModifiers: characters,
            modifiers: modifiers
        ) {
            return armSlot(slot)
        }
        guard let performCommand,
              let command = CanvasToolShortcut.command(
                forCharactersIgnoringModifiers: characters,
                modifiers: modifiers,
                in: commandTable ?? .effective
              )
        else { return false }
        performCommand(command)
        return true
    }
}
