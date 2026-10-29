import Foundation
import ZPDFUIPresentation

/// Remembers which mode each tool set is in, between launches.
///
/// The mode is shown on the set and remembered with it. Remembering is half
/// the sentence and the half a reader would assume rather than check, so it has a type.
///
/// # Why `UserDefaults` and not the preset library
///
/// A mode is not a property of any preset — it is how the estimator is working with a set right
/// now. Putting it in `tool-presets.json` would make every mode flick rewrite the whole library
/// file, and putting it in the `.zpdfproj` would send it to whoever the project is e-mailed to.
/// It is a small preference, so it goes through the seam small preferences already use
/// (``ZPDFDefaultsStoring``), which is also what lets a test assert persistence without touching
/// the person's real machine.
///
/// # What an unreadable value does
///
/// Nothing. A missing or corrupt blob reads as an empty map, which resolves to
/// ``ToolSetMode/default`` for every set — Draw, the mode that behaves as the product did before
/// modes existed. A preference that cannot be read must never be a reason a set stops working,
/// and Draw is the only safe guess: Apply and Place both spend clicks on markups.
///
/// `@MainActor` rather than `Sendable`: ``ZPDFDefaultsStoring`` is a class protocol with no
/// `Sendable` conformance — `UserDefaults` is thread-safe but Foundation does not say so in the
/// type system — and the honest way to hold one under Swift 6 is to pin the store to the actor
/// its callers already run on. Every caller is a presenter or a window controller.
@MainActor
public struct ToolSetModeStore {

    /// The `UserDefaults` key the map lives under.
    public static let defaultsKey = "com.zenitgroup.zenitpdf.toolLibrary.setModes"

    private let defaults: any ZPDFDefaultsStoring

    /// Creates a store over a defaults seam. Tests pass ``ZPDFInMemoryDefaults``.
    public init(defaults: any ZPDFDefaultsStoring) {
        self.defaults = defaults
    }

    /// The remembered modes, keyed by panel. Empty when nothing has been stored.
    ///
    /// Decoded from `[String: String]` rather than from `[ToolLibraryPanel: ToolSetMode]`,
    /// because `JSONEncoder` writes a dictionary with a non-`String` key as a flat array and a
    /// stored preference should be readable by a person opening the plist. An unknown panel or
    /// an unknown mode is dropped, so a value written by a later build degrades to that set
    /// being in Draw rather than to the whole map being discarded.
    public func read() -> [ToolLibraryPanel: ToolSetMode] {
        guard let raw = defaults.decode([String: String].self, forKey: Self.defaultsKey) else {
            return [:]
        }
        var modes: [ToolLibraryPanel: ToolSetMode] = [:]
        for (key, value) in raw {
            guard let panel = ToolLibraryPanel(rawValue: key), let mode = ToolSetMode(rawValue: value) else {
                continue
            }
            modes[panel] = mode
        }
        return modes
    }

    /// Stores the modes of the sets named, dropping the sets that are in the default mode.
    ///
    /// Dropping keeps the written blob to the sets the person actually changed, so the stored
    /// preference is a record of decisions rather than a snapshot of the enumeration — and a
    /// set added in a later build starts in Draw rather than in whatever this build happened to
    /// write for it.
    ///
    /// **Merged, not replaced.** Every open project has its own Tool Library presenter over
    /// this one shared key. Writing a presenter's whole map let project B — whose snapshot was
    /// taken before project A changed anything — erase A's remembered modes the moment B changed
    /// one of its own, and a flip back to Draw emptied the key for every window (BH-099). A set
    /// the call does not name keeps what is stored for it; an entry for an unknown set written
    /// by a later build is kept too.
    public func write(_ modes: [ToolLibraryPanel: ToolSetMode]) {
        var raw = defaults.decode([String: String].self, forKey: Self.defaultsKey) ?? [:]
        for (panel, mode) in modes {
            raw[panel.rawValue] = mode == .default ? nil : mode.rawValue
        }
        if raw.isEmpty {
            defaults.setPersistedData(nil, forKey: Self.defaultsKey)
        } else {
            defaults.encode(raw, forKey: Self.defaultsKey)
        }
    }
}
