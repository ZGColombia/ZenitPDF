import Foundation
import Observation
import ZPDFContracts
import ZPDFUIPresentation

/// `ToolLibraryPresenting` over the project's saved tool presets.
///
/// The Tool Library has no engine behind it — a preset is stored configuration, not a
/// computation — so this presenter owns its state directly and reports arming decisions
/// outward. It is in this package because arming a preset has to reach the measurement
/// presenter (which tool, which defaults) and the status bar (reuse-tool), and wiring
/// those three together is exactly what this layer is for.
@MainActor
@Observable
public final class AppToolLibraryPresenter: ToolLibraryPresenting {

    public private(set) var panels: [ToolLibraryPanel] = ToolLibraryPanel.allCases
    public private(set) var activePanel: ToolLibraryPanel = .myTools
    public private(set) var presets: [ToolPresetSummary] = []
    public private(set) var activePresetID: ToolPresetSummary.ID?
    /// Whether a tool stays armed after it commits. **On by default.**
    ///
    /// Measuring one length or area and then another should not need the tool clicked again
    /// (reported 2026-08-26). Taking off two hundred wall runs is
    /// two hundred measurements, not two hundred tool choices, and returning to Select after each
    /// one puts a click between the estimator and every single number.
    ///
    /// The mechanism was already here and already correct — ``markupCommitted()`` keeps the tool
    /// when this is set, and `MeasurementInputConfiguration.reusesToolAfterCommit` has defaulted
    /// to `true` since it was written. Only this line disagreed, and because the toolbar acts on
    /// *this* one it was the one that decided. Two defaults for one idea, and the wrong one won.
    ///
    /// The status-bar switch still turns it off for anyone who wants one tool per measurement.
    public private(set) var reuseToolEnabled: Bool = true
    public private(set) var searchText: String = ""
    public private(set) var setModes: [ToolLibraryPanel: ToolSetMode] = [:]

    /// Called when a preset is armed or disarmed, so the measurement palette follows.
    ///
    /// The mode travels with the preset because arming means something different in each of
    /// them: Draw configures the drawing tools, while Apply and Place deliberately leave the
    /// drawing tools *disarmed* — a brush that also armed the Area tool would draw a new area
    /// on the first click that missed a markup.
    public var onArm: (@MainActor (ToolPresetSummary?, ToolSetMode) -> Void)?

    /// Called when a set's mode changes, so the status bar can say what the next click means.
    public var onSetModeChange: (@MainActor (ToolLibraryPanel, ToolSetMode) -> Void)?

    /// Persists the per-set modes — the sets whose mode just changed, for the store to merge.
    /// Supplied by the app; a preview leaves it `nil`.
    public var onSetModesChanged: (@MainActor ([ToolLibraryPanel: ToolSetMode]) -> Void)?
    /// Called when reuse-tool is switched, so the status bar follows.
    public var onReuseToolChange: (@MainActor (Bool) -> Void)?

    /// Persists a preset change. Supplied by the app; a preview leaves it `nil`.
    public var onPresetsChanged: (@MainActor ([ToolPresetSummary]) -> Void)?

    /// Creates a presenter.
    public init(
        presets: [ToolPresetSummary] = [],
        setModes: [ToolLibraryPanel: ToolSetMode] = [:]
    ) {
        self.presets = presets
        self.setModes = setModes
    }

    /// Adopts the modes read back from storage, without re-persisting them.
    public func adoptSetModes(_ modes: [ToolLibraryPanel: ToolSetMode]) {
        setModes = modes
        if let preset = activePreset { onArm?(preset, armedSetMode) }
    }

    /// Replaces the preset library, keeping the armed preset if it survived.
    public func setPresets(_ presets: [ToolPresetSummary]) {
        self.presets = presets
        if let activePresetID, !presets.contains(where: { $0.id == activePresetID }) {
            self.activePresetID = nil
            onArm?(nil, .draw)
        }
    }

    // MARK: ToolLibraryPresenting

    public func selectPanel(_ panel: ToolLibraryPanel) { activePanel = panel }

    public func activatePreset(id: ToolPresetSummary.ID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        activePresetID = id
        recentPresetIDs.removeAll { $0 == id }
        recentPresetIDs.insert(id, at: 0)
        if recentPresetIDs.count > 12 { recentPresetIDs.removeLast(recentPresetIDs.count - 12) }
        onArm?(preset, mode(of: preset.panel))
    }

    /// Recently armed presets, newest first — what the Recent set lists, through the Tool
    /// Library model (R-054).
    public private(set) var recentPresetIDs: [ToolPresetSummary.ID] = []

    public func clearActivePreset() {
        guard activePresetID != nil else { return }
        activePresetID = nil
        onArm?(nil, .draw)
    }

    public func toggleFavorite(id: ToolPresetSummary.ID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        guard !presets[index].isReadOnly else { return }
        presets[index].isFavorite.toggle()
        onPresetsChanged?(presets)
    }

    public func setReuseToolEnabled(_ enabled: Bool) {
        reuseToolEnabled = enabled
        onReuseToolChange?(enabled)
    }

    public func setSearchText(_ text: String) { searchText = text }

    /// Puts one set into one mode, and re-arms so the canvas hears about it.
    ///
    /// Re-arming matters: switching `My Tools` from Draw to Apply while an exterior-wall preset
    /// is armed has to disarm the drawing tool immediately, or the next click would still draw.
    /// A mode change that only repainted a segmented control would be a switch that lies.
    public func setMode(_ mode: ToolSetMode, for panel: ToolLibraryPanel) {
        guard (setModes[panel] ?? .default) != mode else { return }
        setModes[panel] = mode
        onSetModeChange?(panel, mode)
        // Only the set that changed: the store merges, so a presenter whose snapshot is older
        // than another window's decision cannot write that decision away (BH-099).
        onSetModesChanged?([panel: mode])
        if let preset = activePreset, preset.panel == panel {
            onArm?(preset, mode)
        }
    }

    public func movePreset(id: ToolPresetSummary.ID, to index: Int) {
        guard let current = presets.firstIndex(where: { $0.id == id }) else { return }
        let moved = presets[current]
        guard !moved.isReadOnly else { return }
        // Reordering is within a category, so the sort index is rewritten for that
        // category's members rather than for the whole library — moving a preset in
        // "Concrete" must not renumber "Steel".
        var siblings = presets.enumerated()
            .filter { $0.element.panel == moved.panel && $0.element.category == moved.category }
            .map(\.offset)
        guard let from = siblings.firstIndex(of: current) else { return }
        let clamped = max(0, min(siblings.count - 1, index))
        siblings.remove(at: from)
        siblings.insert(current, at: clamped)
        for (order, position) in siblings.enumerated() {
            presets[position].sortIndex = order
        }
        onPresetsChanged?(presets)
    }

    /// Called after a markup or a measurement is committed: the tool stays armed when
    /// reuse-tool is on, and is disarmed otherwise. This is the single place that decision
    /// is made, so the switch cannot be honoured by one tool and ignored by another.
    ///
    /// It had no caller until 2026-08-24. The markup family disarmed
    /// itself inline in `PDFCanvasViewController.commitMarkup()` and the measurement family
    /// did nothing at all, so Length and Area reused themselves with the switch showing
    /// **Off**. Both families call this now and obey what it returns; disarming the *chip*
    /// belongs to the caller, because only the toolbar can do it and this presenter has no
    /// business knowing there is a toolbar.
    ///
    /// - Returns: `true` when the tool stays armed, `false` when the caller must return to
    ///   Select.
    @discardableResult
    public func markupCommitted() -> Bool {
        guard !reuseToolEnabled else { return true }
        clearActivePreset()
        return false
    }
}
