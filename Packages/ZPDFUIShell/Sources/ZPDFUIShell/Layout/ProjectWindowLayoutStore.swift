import Foundation
import ZPDFUIPresentation

/// Loads and saves ``ProjectWindowLayoutState``.
///
/// Reads are defensive by design: a missing key, a corrupt blob or a state written by a future
/// schema all resolve to the shipped default rather than to a thrown error, because a window
/// that refuses to open is worse than a window that opens with default proportions.
@MainActor
public final class ProjectWindowLayoutStore {

    /// The defaults key the state is written under.
    public static let defaultsKey = "Zenit.ProjectWindow.LayoutState"

    private let defaults: any ZPDFDefaultsStoring
    private let key: String
    /// What ``load()`` answers when nothing usable is stored.
    public let fallback: ProjectWindowLayoutState
    /// Sorted keys, so the same layout encodes to the same bytes and an unchanged save is
    /// recognised as one.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    /// Creates a store over a defaults backing.
    ///
    /// - Parameters:
    ///   - defaults: where the state lives. Defaults to `UserDefaults.standard`.
    ///   - key: the defaults key, overridable so several windows can hold separate layouts.
    ///   - fallback: the layout a missing or unreadable entry resolves to. The application
    ///     passes ``ProjectWindowLayoutState/firstLaunch``.
    public init(
        defaults: any ZPDFDefaultsStoring = UserDefaults.standard,
        key: String = ProjectWindowLayoutStore.defaultsKey,
        fallback: ProjectWindowLayoutState = .default
    ) {
        self.defaults = defaults
        self.key = key
        self.fallback = fallback.normalized()
    }

    /// The same store with a different ``fallback``. The application writes
    /// `ProjectWindowLayoutStore(defaults: …).withFallback(.firstLaunch)`, which keeps the
    /// explicit-store call the defaults-isolation scan looks for intact.
    public func withFallback(_ fallback: ProjectWindowLayoutState) -> ProjectWindowLayoutStore {
        ProjectWindowLayoutStore(defaults: defaults, key: key, fallback: fallback)
    }

    /// The same store under another defaults key, so a second window on a document keeps a
    /// layout of its own instead of writing over the first window's (NL-UX-20).
    public func keyed(_ key: String) -> ProjectWindowLayoutStore {
        ProjectWindowLayoutStore(defaults: defaults, key: key, fallback: fallback)
    }

    /// Reads the stored layout, normalized, falling back to ``fallback``.
    public func load() -> ProjectWindowLayoutState {
        guard let data = defaults.persistedData(forKey: key) else { return fallback }
        guard let decoded = try? decoder.decode(ProjectWindowLayoutState.self, from: data) else {
            return fallback
        }
        guard decoded.schemaVersion <= ProjectWindowLayoutState.currentSchemaVersion else {
            // Written by a newer build. Start clean rather than half-reading a shape we
            // do not understand.
            return fallback
        }
        return decoded.normalized()
    }

    /// Writes the layout, normalizing first so nothing out of range is ever stored.
    ///
    /// Encoding a struct of numbers and enums cannot realistically fail; if it somehow does,
    /// the previous stored layout is left untouched rather than being replaced with junk.
    ///
    /// A layout identical to the stored one is not written again (S-059): each write posts
    /// `UserDefaults.didChangeNotification`, which every window's author badge observes.
    @discardableResult
    public func save(_ state: ProjectWindowLayoutState) -> Bool {
        guard let data = try? encoder.encode(state.normalized()) else { return false }
        if defaults.persistedData(forKey: key) == data { return true }
        defaults.setPersistedData(data, forKey: key)
        return true
    }

    /// Forgets the stored layout, so the next load returns the shipped default.
    public func reset() {
        defaults.setPersistedData(nil, forKey: key)
    }
}
