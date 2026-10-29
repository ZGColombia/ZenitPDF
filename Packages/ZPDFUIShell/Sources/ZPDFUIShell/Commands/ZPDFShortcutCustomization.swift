import Foundation

/// The person's own shortcuts, layered over ``ZPDFCommandTable/standard`` (NL-UX-11).
///
/// Stored per command identity: a binding replaces the standard one, an explicit `nil` removes
/// it, a command absent from the map keeps its standard shortcut. The standard table itself is
/// never edited, so "Restore Defaults" is simply an empty map.
public struct ZPDFShortcutOverrides: Codable, Hashable, Sendable {

    /// Command raw value → the binding it uses instead (`nil`: no shortcut).
    public var bindings: [String: ZPDFKeyBinding?]

    public init(bindings: [String: ZPDFKeyBinding?] = [:]) {
        self.bindings = bindings
    }

    public static let none = ZPDFShortcutOverrides()

    public var isEmpty: Bool { bindings.isEmpty }

    /// The override for one command, or `.none` (outer) when it keeps its standard shortcut.
    public func override(for id: ZPDFCommandID) -> ZPDFKeyBinding?? {
        bindings[id.rawValue]
    }
}

/// Why a shortcut was refused. Every case names what the person needs to know to pick another.
public enum ZPDFShortcutRefusal: Error, Hashable, Sendable {
    /// Another command already answers this chord where this one would.
    case takenBy(commandTitle: String)
    /// macOS owns this chord for the whole application (Quit, Copy, Settings…).
    case reservedBySystem
    /// The number keys arm the Tool Library's slots.
    case reservedForToolSlots
    /// A shortcut without ⌘ could never reach the menu bar and would swallow typing; only the
    /// canvas's single-letter tool keys may go without it.
    case needsCommandKey

    /// The sentence the Settings pane shows.
    public var message: String {
        switch self {
        case .takenBy(let title):
            return String(
                format: NSLocalizedString(
                    "That shortcut is already used by “%@”.",
                    comment: "Shortcut refused: the placeholder is the other command's name"
                ),
                title
            )
        case .reservedBySystem:
            return NSLocalizedString(
                "macOS uses that shortcut for every application.",
                comment: "Shortcut refused: the chord is reserved by the system"
            )
        case .reservedForToolSlots:
            return NSLocalizedString(
                "The number keys arm the tools in the active tool set.",
                comment: "Shortcut refused: the digits belong to the tool slots"
            )
        case .needsCommandKey:
            return NSLocalizedString(
                "Use ⌘ with this shortcut. Only the canvas tools take a single letter.",
                comment: "Shortcut refused: a non-canvas command needs the Command key"
            )
        }
    }
}

public extension ZPDFCommand {

    /// The same command with another shortcut.
    func rebound(to binding: ZPDFKeyBinding?) -> ZPDFCommand {
        ZPDFCommand(
            id: id,
            title: title,
            group: group,
            binding: binding,
            context: context,
            // A person's own chord is never a declared shadow: the rebinding refuses clashes.
            shadowsBroaderBinding: binding == self.binding ? shadowsBroaderBinding : false,
            glyph: glyph,
            accessibilityHint: accessibilityHint,
            isDestructive: isDestructive
        )
    }
}

public extension ZPDFCommandTable {

    /// The table with a set of overrides applied. An override for a command the table does not
    /// hold is ignored.
    func applying(_ overrides: ZPDFShortcutOverrides) -> ZPDFCommandTable {
        guard !overrides.isEmpty else { return self }
        return ZPDFCommandTable(commands: commands.map { command in
            guard let override = overrides.override(for: command.id) else { return command }
            return command.rebound(to: override)
        })
    }

    /// Whether `binding` can be given to `id`, checked against this table's other commands and
    /// against `reservedChords` — chords the application claims outside the table (its own
    /// commands), keyed by ``ZPDFKeyBinding/chord`` with the claiming command's title.
    ///
    /// The rules are the table's own audits, applied before the change rather than after it:
    /// no two commands on one chord (a declared standard shadow pair excepted), no takeover of a
    /// chord macOS reserves, no digit (the tool slots), and ⌘ on everything that is not a
    /// canvas tool letter.
    func validate(
        _ binding: ZPDFKeyBinding,
        for id: ZPDFCommandID,
        reservedChords: [String: String] = [:]
    ) -> ZPDFShortcutRefusal? {
        guard let command = command(id) else { return nil }
        if ToolSlotShortcut.auditChords.contains(binding.chord) {
            return .reservedForToolSlots
        }
        let isCanvasLetter = CanvasToolShortcut.isCanvasLetter(command.rebound(to: binding))
        if !binding.modifiers.contains(.command), !isCanvasLetter {
            return .needsCommandKey
        }
        if Self.systemReservedAuditChords.contains(Self.takeoverAuditChord(binding)) {
            return .reservedBySystem
        }
        if let other = commands.first(where: { $0.id != id && $0.binding?.chord == binding.chord }) {
            return .takenBy(commandTitle: other.title)
        }
        if let title = reservedChords[binding.chord] {
            return .takenBy(commandTitle: title)
        }
        return nil
    }

    /// The overrides after giving `id` the shortcut `binding` (or none), or the refusal.
    func rebinding(
        _ id: ZPDFCommandID,
        to binding: ZPDFKeyBinding?,
        in overrides: ZPDFShortcutOverrides,
        standard: ZPDFCommandTable = .standard,
        reservedChords: [String: String] = [:]
    ) -> Result<ZPDFShortcutOverrides, ZPDFShortcutRefusal> {
        if let binding, let refusal = validate(binding, for: id, reservedChords: reservedChords) {
            return .failure(refusal)
        }
        var next = overrides
        if standard.command(id)?.binding == binding {
            next.bindings.removeValue(forKey: id.rawValue)
        } else {
            next.bindings[id.rawValue] = .some(binding)
        }
        return .success(next)
    }
}

/// Where the overrides live. `UserDefaults`, JSON-encoded, injectable for tests; `nil`
/// defaults keeps them in memory only (any process that is not the shipping app).
@MainActor
public final class ZPDFShortcutOverrideStore {
    private let defaults: UserDefaults?
    private var memory: ZPDFShortcutOverrides = .none
    public static let key = "ZenitShortcutOverrides"

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    public var overrides: ZPDFShortcutOverrides {
        get {
            guard let defaults else { return memory }
            guard let data = defaults.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(ZPDFShortcutOverrides.self, from: data)
            else { return .none }
            return decoded
        }
        set {
            guard let defaults else { memory = newValue; return }
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.key)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }
}

public extension ZPDFCommandTable {

    /// The table in force: the standard table with the person's overrides. Set by the
    /// application at launch and after every change in Settings ▸ Shortcuts; everything that
    /// builds a menu, a key router or a shortcut reference reads it.
    @MainActor static var effective: ZPDFCommandTable {
        get { ZPDFEffectiveTable.current }
        set { ZPDFEffectiveTable.current = newValue }
    }
}

@MainActor
private enum ZPDFEffectiveTable {
    static var current: ZPDFCommandTable = .standard
}
