import Foundation
import Observation

/// Settings ▸ Keyboard Shortcuts, apart from its view (NL-UX-11).
///
/// Lists every command of the standard table with the shortcut in force. Choosing a row and
/// pressing a chord rebinds it — through ``ZPDFCommandTable/rebinding(_:to:in:standard:reservedChords:)``,
/// so a clash is refused with the other command's name and nothing changes. A rebinding that
/// lands is stored and handed to ``onApply`` (the app rebuilds the menu bar and the shortcut
/// reference from ``ZPDFCommandTable/effective``).
@MainActor
@Observable
public final class ShortcutSettingsModel {

    /// One row: a command and the shortcut it has now.
    public struct Row: Identifiable, Hashable {
        public let id: ZPDFCommandID
        public let title: String
        public let group: String
        public let context: String
        public let shortcut: String?
        public let isCustomised: Bool
    }

    /// The overrides in force.
    public private(set) var overrides: ZPDFShortcutOverrides
    /// The command waiting for a chord, or `nil`.
    public private(set) var recording: ZPDFCommandID?
    /// The last refusal, shown under the list until the next attempt.
    public private(set) var refusal: String?
    /// What the search field filters by.
    public var filter: String = ""

    @ObservationIgnored private let standard: ZPDFCommandTable
    @ObservationIgnored private let store: ZPDFShortcutOverrideStore
    @ObservationIgnored private let reservedChords: [String: String]
    /// Raised after every change that landed, with the new effective table.
    @ObservationIgnored public var onApply: (@MainActor (ZPDFCommandTable) -> Void)?

    public init(
        store: ZPDFShortcutOverrideStore,
        standard: ZPDFCommandTable = .standard,
        reservedChords: [String: String] = [:]
    ) {
        self.store = store
        self.standard = standard
        self.reservedChords = reservedChords
        self.overrides = store.overrides
    }

    /// The table in force under these settings.
    public var effectiveTable: ZPDFCommandTable { standard.applying(overrides) }

    /// The rows, filtered, in menu order.
    public var rows: [Row] {
        let table = effectiveTable
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return table.menus.flatMap { entry in
            entry.commands.map { command in
                Row(
                    id: command.id,
                    title: command.title,
                    group: entry.group.displayName,
                    context: command.context.displayName,
                    shortcut: command.binding?.displayString,
                    isCustomised: overrides.override(for: command.id) != nil
                )
            }
        }
        .filter { row in
            needle.isEmpty
                || row.title.localizedCaseInsensitiveContains(needle)
                || row.group.localizedCaseInsensitiveContains(needle)
                || (row.shortcut?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    /// Starts waiting for a chord for one command.
    public func beginRecording(_ id: ZPDFCommandID) {
        recording = id
        refusal = nil
    }

    /// Stops waiting without changing anything.
    public func cancelRecording() {
        recording = nil
    }

    /// The chord the person pressed while recording. Returns whether it was accepted.
    @discardableResult
    public func record(_ binding: ZPDFKeyBinding) -> Bool {
        guard let id = recording else { return false }
        return assign(binding, to: id)
    }

    /// Gives `id` the shortcut `binding`, or refuses and says why.
    @discardableResult
    public func assign(_ binding: ZPDFKeyBinding?, to id: ZPDFCommandID) -> Bool {
        let base = effectiveTable
        switch base.rebinding(id, to: binding, in: overrides, standard: standard, reservedChords: reservedChords) {
        case .success(let next):
            commit(next)
            recording = nil
            return true
        case .failure(let reason):
            refusal = reason.message
            return false
        }
    }

    /// Removes a command's shortcut.
    public func clear(_ id: ZPDFCommandID) {
        assign(nil, to: id)
    }

    /// Puts one command back on its standard shortcut. Refused when the standard chord has
    /// since been given to another command.
    @discardableResult
    public func restore(_ id: ZPDFCommandID) -> Bool {
        guard overrides.override(for: id) != nil else { return true }
        if let binding = standard.command(id)?.binding {
            var without = overrides
            without.bindings.removeValue(forKey: id.rawValue)
            let table = standard.applying(without)
            if let clash = table.commands.first(where: { $0.id != id && $0.binding?.chord == binding.chord }),
               overrides.override(for: clash.id) != nil {
                refusal = ZPDFShortcutRefusal.takenBy(commandTitle: clash.title).message
                return false
            }
            commit(without)
        } else {
            var without = overrides
            without.bindings.removeValue(forKey: id.rawValue)
            commit(without)
        }
        return true
    }

    /// Every shortcut back to the standard table.
    public func restoreAll() {
        commit(.none)
    }

    private func commit(_ next: ZPDFShortcutOverrides) {
        overrides = next
        store.overrides = next
        refusal = nil
        onApply?(effectiveTable)
    }
}
