import Foundation
import Observation
import ZPDFUIPresentation

/// Each markup tool's own style: the one the person set as its default, and the last one they
/// used (nl-markup, NL-MARKUP-04).
///
/// Before this there was one tool style for every markup tool, so recolouring a cloud red
/// also made the next arrow red, and nothing could say "my clouds are red, my notes are blue".
/// The table is per `MarkupKind`:
///
/// - **Set as Default for ⟨kind⟩** writes the kind's default, which survives a restart.
/// - With **Tools remember the last style I used** on (the default), the style a person last
///   gave a kind — by drawing with a restyled tool or restyling one of its markups — is what
///   that tool draws next. Off, only Set as Default changes what a tool draws.
///
/// Stored in the process defaults the app hands in (the standard defaults in the shipping app,
/// memory in a test process), one blob, so nothing here can write the user's preferences
/// from a test.
@MainActor
@Observable
public final class MarkupStyleDefaults {

    /// The persisted shape. Codable, decoded leniently.
    struct Stored: Codable, Equatable {
        var defaults: [String: ToolStyleSelection] = [:]
        var lastUsed: [String: ToolStyleSelection] = [:]
        var remembersLastUsed: Bool = true
    }

    static let defaultsKey = "Zenit.MarkupStyleDefaults"

    private let store: (any ZPDFDefaultsStoring)?
    private var stored: Stored

    /// Whether a tool draws the style last used for its kind (on), or only its default (off).
    public var remembersLastUsed: Bool {
        get { stored.remembersLastUsed }
        set {
            guard newValue != stored.remembersLastUsed else { return }
            stored.remembersLastUsed = newValue
            persist()
        }
    }

    /// Creates a table over `store`, or in memory when `store` is `nil`.
    public init(store: (any ZPDFDefaultsStoring)? = nil) {
        self.store = store
        self.stored = store?.decode(Stored.self, forKey: Self.defaultsKey) ?? Stored()
    }

    /// The style a tool for `kind` draws with.
    ///
    /// - Parameter fallback: the style used when the table says nothing for the kind — the
    ///   window's current tool style while remembering is on, which keeps "the next shape looks
    ///   like the last one I styled" true across kinds that have no memory yet.
    public func style(for kind: MarkupKind, fallback: ToolStyleSelection) -> ToolStyleSelection {
        if stored.remembersLastUsed {
            return stored.lastUsed[kind.rawValue] ?? stored.defaults[kind.rawValue] ?? fallback
        }
        return stored.defaults[kind.rawValue] ?? .zenitInk
    }

    /// Sets `kind`'s default. The kind's last-used memory takes the same style, so a fresh
    /// default is what the tool draws next either way.
    public func setDefault(_ style: ToolStyleSelection, for kind: MarkupKind) {
        stored.defaults[kind.rawValue] = style
        stored.lastUsed[kind.rawValue] = style
        persist()
    }

    /// Records the style last used for `kind`. Does nothing while remembering is off.
    public func remember(_ style: ToolStyleSelection, for kind: MarkupKind) {
        guard stored.remembersLastUsed, stored.lastUsed[kind.rawValue] != style else { return }
        stored.lastUsed[kind.rawValue] = style
        persist()
    }

    /// A tool variant's style (r2-markup): its last-used memory, else `fallback`. Kept under its
    /// own key so the highlighter and the pen remember different looks.
    public func style(forVariant variant: MarkupToolVariant, fallback: ToolStyleSelection) -> ToolStyleSelection {
        stored.remembersLastUsed ? (stored.lastUsed["variant." + variant.rawValue] ?? fallback) : fallback
    }

    /// Records the style last used for a tool variant.
    public func remember(_ style: ToolStyleSelection, forVariant variant: MarkupToolVariant) {
        let key = "variant." + variant.rawValue
        guard stored.remembersLastUsed, stored.lastUsed[key] != style else { return }
        stored.lastUsed[key] = style
        persist()
    }

    /// Forgets every default and memory and turns remembering back on: the table a fresh
    /// install starts with. For tests that share the process-wide table.
    public func forgetAll() {
        stored = Stored()
        persist()
    }

    private func persist() {
        _ = store?.encode(stored, forKey: Self.defaultsKey)
    }
}
