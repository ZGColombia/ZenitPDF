import Foundation
import Observation

/// Presents the Tool Library: panels, saved presets and the reuse-tool switch.
@MainActor
public protocol ToolLibraryPresenting: ZenitPresenting {

    /// Panels in sidebar order.
    var panels: [ToolLibraryPanel] { get }
    /// The panel currently shown.
    var activePanel: ToolLibraryPanel { get }
    /// Every preset across all panels.
    var presets: [ToolPresetSummary] { get }
    /// The preset that is armed, or `nil` when a plain tool is active.
    var activePresetID: ToolPresetSummary.ID? { get }
    /// Whether the active tool stays selected after a markup is committed.
    var reuseToolEnabled: Bool { get }
    /// Free-text filter applied to the preset list.
    var searchText: String { get }
    /// The mode each set is in, keyed by panel.
    ///
    /// A set is in exactly one mode at a time and the mode is remembered *with the set*, so
    /// leaving Apply on `Project Tools` and going back to `My Tools` does not silently make
    /// the next click a brush. Absent means ``ToolSetMode/default``.
    var setModes: [ToolLibraryPanel: ToolSetMode] { get }
    /// The presets armed most recently, newest first: what the Recent set lists (R-054).
    var recentPresetIDs: [ToolPresetSummary.ID] { get }

    /// Shows a different panel.
    func selectPanel(_ panel: ToolLibraryPanel)
    /// Arms a preset so the next canvas gesture uses its tool and defaults.
    func activatePreset(id: ToolPresetSummary.ID)
    /// Disarms whatever preset is active.
    func clearActivePreset()
    /// Stars or unstars a preset.
    func toggleFavorite(id: ToolPresetSummary.ID)
    /// Turns reuse-tool on or off.
    func setReuseToolEnabled(_ enabled: Bool)
    /// Filters the preset list.
    func setSearchText(_ text: String)
    /// Moves a preset within its category.
    func movePreset(id: ToolPresetSummary.ID, to index: Int)
    /// Puts one set into one mode.
    func setMode(_ mode: ToolSetMode, for panel: ToolLibraryPanel)

    /// Tells the library that a markup or a measurement has just been committed, and
    /// answers whether the tool stays armed.
    ///
    /// This is the **single place** the Reuse Tool decision is made. Before it had a
    /// caller, the markup family disarmed itself inline and the measurement family did
    /// not, so Length and Area reused themselves whether the switch said On or Off
    /// (confirmed 2026-08-24). Both families now ask this and obey
    /// the answer, so the switch cannot be honoured by one tool and ignored by another.
    ///
    /// - Returns: `true` when the tool stays armed, `false` when the caller must return
    ///   to Select.
    @discardableResult
    func markupCommitted() -> Bool
}

extension ToolLibraryPresenting {

    /// Presets in one panel, ordered by category then sort index, honouring ``searchText``.
    public func presets(in panel: ToolLibraryPanel) -> [ToolPresetSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return presets
            .filter { $0.panel == panel }
            .filter {
                query.isEmpty
                    || $0.name.lowercased().contains(query)
                    || $0.category.lowercased().contains(query)
            }
            // BH-787: categories are free text; order them as a person reads them — locale
            // aware, case-insensitive — and keep "Doors" and "doors" in one run.
            .sorted {
                let order = $0.category.localizedStandardCompare($1.category)
                return order == .orderedSame ? $0.sortIndex < $1.sortIndex : order == .orderedAscending
            }
    }

    /// The armed preset, resolved from ``activePresetID``.
    public var activePreset: ToolPresetSummary? {
        guard let activePresetID else { return nil }
        return presets.first { $0.id == activePresetID }
    }

    /// The mode one set is in.
    public func mode(of panel: ToolLibraryPanel) -> ToolSetMode {
        setModes[panel] ?? .default
    }

    /// What the next canvas click means, right now.
    ///
    /// Read off the set the **armed preset** belongs to, not off the panel that happens to be
    /// on screen: arming a stamp out of `Project Tools` and then browsing `My Tools` must not
    /// turn the armed stamp back into a drawing tool. With nothing armed there is nothing to
    /// apply or place, so the answer is Draw and the canvas behaves exactly as it did before
    /// tool sets existed.
    public var armedSetMode: ToolSetMode {
        guard let panel = activePreset?.panel else { return .draw }
        return mode(of: panel)
    }
}

extension ToolLibraryPresenting {
    /// A presenter that keeps no history lists nothing under Recent.
    public var recentPresetIDs: [ToolPresetSummary.ID] { [] }
}
