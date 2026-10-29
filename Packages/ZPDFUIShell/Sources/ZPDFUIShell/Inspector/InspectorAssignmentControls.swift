import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Properties tab's Locked, Hidden and Project Zone rows as controls, and the Actions
/// row's Zoom to Selection.
///
/// nl-ux, 2026-09-23. All four used to look like controls and act like labels, or act on the
/// wrong thing:
/// - Locked and Hidden were plain text ("Locked" / "Visible"); the only way to change them was
///   the header's ⋯ menu.
/// - Project Zone was plain text, and a zone could be assigned only from the Zones page.
/// - Actions ▸ Zoom to Selection fitted the **first** selected markup
///   (`canvas.zoomTo(markupID: first.id)`), while the header ⋯ item of the same name fitted the
///   whole selection.
///
/// Every route here is one the product already had: the lock and hide commands behind the ⋯
/// menu, the document's `setMarkupZone` command, and the View menu's Zoom to Selection. Nothing
/// here writes the document itself.
extension InspectorPanel {

    // MARK: - Routes (value-level, so tests drive them without a view tree)

    /// Fits the whole selection, through the same command the View menu and the header ⋯ item
    /// run — which turns to the selection's sheet first (S-045).
    func zoomToSelection(_ summary: InspectorSelectionSummary) {
        guard !summary.isEmpty else { return }
        environment.perform(.zoomToSelection)
    }

    /// What both Zoom to Selection controls say about where they land (S-045): a selection on
    /// another sheet is turned to, and one over several sheets is fitted on one of them.
    static func zoomToSelectionHelp(
        _ summary: InspectorSelectionSummary,
        environment: ProjectShellEnvironment
    ) -> String {
        switch environment.selectionPlacement(of: summary.markups) {
        case .none, .currentSheet:
            return NSLocalizedString("Zoom to the selection.", comment: "Inspector Zoom to Selection help")
        case .otherSheet(let page):
            return String(
                format: NSLocalizedString(
                    "Turn to %@ and zoom to the selection.",
                    comment: "Inspector Zoom to Selection help: the selection is on another sheet; the sheet"
                ),
                sheetName(page, in: environment)
            )
        case .severalSheets(let count, let target):
            let format = target == environment.document.currentPageID
                ? NSLocalizedString(
                    "The selection spans %1$d sheets. Zooms to its part on this sheet.",
                    comment: "Inspector Zoom to Selection help: sheet count"
                )
                : NSLocalizedString(
                    "The selection spans %1$d sheets. Turns to %2$@ and zooms to its part there.",
                    comment: "Inspector Zoom to Selection help: sheet count, the sheet it turns to"
                )
            return String(format: format, count, sheetName(target, in: environment))
        }
    }

    /// A sheet as a person names it: its sheet number, else "Page <label>".
    private static func sheetName(_ pageID: PageDescriptor.ID, in environment: ProjectShellEnvironment) -> String {
        guard let page = environment.document.pages.first(where: { $0.id == pageID }) else {
            return NSLocalizedString("its sheet", comment: "Inspector Zoom to Selection help: an unnamed sheet")
        }
        if let number = page.sheetNumber, !number.isEmpty { return number }
        return String(format: NSLocalizedString("Page %@", comment: "A page by its label"), page.label)
    }

    /// Sets the selection's lock to `locked`, one undo step through the wired lock command.
    func setLocked(_ locked: Bool, for summary: InspectorSelectionSummary) {
        guard !summary.isEmpty, let setLocked = environment.inspectorEditing.onSetLocked else { return }
        setLocked(Set(summary.markups.map(\.id)), locked)
    }

    /// Sets the selection's visibility; nothing when the engine would refuse (a locked markup
    /// whose visibility would change).
    func setHidden(_ hidden: Bool, for summary: InspectorSelectionSummary) {
        guard !summary.isEmpty, let setHidden = environment.inspectorEditing.onSetHidden else { return }
        guard !summary.markups.contains(where: { $0.locked && $0.hidden != hidden }) else { return }
        setHidden(Set(summary.markups.map(\.id)), hidden)
    }

    /// Files the selection into a zone, or out of every zone with `nil`.
    func assignZone(_ zoneID: UUID?, for summary: InspectorSelectionSummary) {
        guard !summary.isEmpty, let assign = environment.inspectorEditing.onSetZone else { return }
        if let zoneID, !environment.projectZones.zones.contains(where: { $0.id == zoneID }) { return }
        assign(Set(summary.markups.map(\.id)), zoneID)
    }

    /// Whether the selection's zone can be changed from the Inspector: something is selected,
    /// the app wired the command, and nothing selected is locked.
    func canAssignZone(_ summary: InspectorSelectionSummary) -> Bool {
        !summary.isEmpty && environment.inspectorEditing.onSetZone != nil && !summary.includesLockedMarkup
    }

    // MARK: - The layer as the cause (K-08)

    /// Which layer flag a Hidden or Locked row explains.
    enum LayerFlag: Sendable {
        case hidden, locked
    }

    /// What a Hidden or Locked row says when the selection's markup layer is the cause —
    /// "Hidden by layer Walls", "Locked by layers Walls and Doors", or "Hidden by its layer" when
    /// a layer's name is not known — or `nil` when no selected markup takes the flag from its
    /// layer (ADR-0032 folds the layer's share into ``MarkupSummary/hidden`` and
    /// ``MarkupSummary/locked``; ``MarkupSummary/layerHidden`` and
    /// ``MarkupSummary/layerLocked`` say where it came from).
    ///
    /// K-08: the switches used to read "on" with nothing saying why, and the markup's own switch
    /// cannot lift a layer's flag, so turning it off changed nothing the person could see.
    static func layerCause(
        _ flag: LayerFlag,
        in summary: InspectorSelectionSummary,
        layerName: (UUID) -> String?
    ) -> String? {
        var layerIDs: [UUID] = []
        var hasUnknownLayer = false
        for markup in summary.markups {
            let fromLayer = flag == .hidden ? markup.layerHidden == true : markup.layerLocked == true
            guard fromLayer else { continue }
            if let id = markup.layerID {
                if !layerIDs.contains(id) { layerIDs.append(id) }
            } else {
                hasUnknownLayer = true
            }
        }
        guard !layerIDs.isEmpty || hasUnknownLayer else { return nil }
        let names = layerIDs.compactMap(layerName)
        guard !hasUnknownLayer, names.count == layerIDs.count else {
            return flag == .hidden
                ? NSLocalizedString("Hidden by its layer", comment: "Inspector Hidden row: the markup's layer, whose name is unknown, hides it")
                : NSLocalizedString("Locked by its layer", comment: "Inspector Locked row: the markup's layer, whose name is unknown, locks it")
        }
        if names.count == 1 {
            let format = flag == .hidden
                ? NSLocalizedString("Hidden by layer %@", comment: "Inspector Hidden row: the named markup layer hides the selection")
                : NSLocalizedString("Locked by layer %@", comment: "Inspector Locked row: the named markup layer locks the selection")
            return String(format: format, names[0])
        }
        let list = AppLanguageList.joined(names)
        let format = flag == .hidden
            ? NSLocalizedString("Hidden by layers %@", comment: "Inspector Hidden row: several named markup layers hide the selection")
            : NSLocalizedString("Locked by layers %@", comment: "Inspector Locked row: several named markup layers lock the selection")
        return String(format: format, list)
    }

    /// How a Hidden or Locked row stands for a selection: whether its switch can act, the note
    /// beside it, and the help when it cannot.
    struct FlagRowState: Equatable, Sendable {
        let isEnabled: Bool
        /// "Hidden by layer Walls", shown beside the switch; `nil` when the layer is not the cause.
        let note: String?
        let disabledReason: String?
    }

    /// The Locked row. A layer's lock is lifted in the Navigator, so the markup's own switch is
    /// off while a selected markup is locked by its layer.
    static func lockedRowState(
        _ summary: InspectorSelectionSummary,
        isWired: Bool,
        layerName: (UUID) -> String?
    ) -> FlagRowState {
        let cause = layerCause(.locked, in: summary, layerName: layerName)
        return FlagRowState(
            isEnabled: !summary.isEmpty && isWired && cause == nil,
            note: cause,
            disabledReason: cause == nil ? nil : lockedLayerReason
        )
    }

    /// The Hidden row. Off for a selected markup hidden by its layer, and — as before — for a
    /// locked markup whose visibility would change.
    static func hiddenRowState(
        _ summary: InspectorSelectionSummary,
        isWired: Bool,
        layerName: (UUID) -> String?
    ) -> FlagRowState {
        let cause = layerCause(.hidden, in: summary, layerName: layerName)
        let reason: String
        if cause != nil {
            reason = NSLocalizedString(
                "The selection is on a hidden layer. Show the layer in the Navigator first.",
                comment: "Inspector Hidden switch help when a selected markup's layer is hidden"
            )
        } else if summary.markups.contains(where: { $0.layerLocked == true }) {
            reason = lockedLayerReason
        } else {
            reason = lockedMarkupReason
        }
        return FlagRowState(
            isEnabled: InspectorMarkupFormatting.canChangeVisibility(summary) && isWired && cause == nil,
            note: cause,
            disabledReason: reason
        )
    }

    /// Why a control is off for a selection on a locked layer. The layer model's words for the
    /// same refusal, so the Inspector and the Navigator say one thing (W-052).
    static var lockedLayerReason: String {
        MarkupLayerPanelModel.reason(.markupOnLockedLayer)
    }

    /// Why a control is off for a selection that includes a locked markup
    /// (``InspectorSelectionSummary/includesLockedMarkup``): one wording for every control the
    /// lock rule turns off (W-039).
    static var lockedMarkupReason: String {
        NSLocalizedString(
            "The selection includes a locked markup. Unlock it first.",
            comment: "Inspector: why a control is off for a selection that includes a locked markup"
        )
    }

    /// The name the project gives a markup layer, when its layers are installed.
    func markupLayerName(_ id: UUID) -> String? {
        environment.markupLayers.row(id)?.name
    }

    // MARK: - Rows

    /// A labelled on/off control for a Boolean markup property.
    ///
    /// A mixed selection reads "Multiple values" beside an off switch, and the first click sets
    /// the whole selection on — the same rule the rest of the Inspector follows for mixed fields.
    /// `note` says why the switch reads as it does when something other than the markup decides
    /// it — its layer (K-08) — and is spoken with the value.
    @ViewBuilder
    func booleanControl(
        title: String,
        value: Bool?,
        isEnabled: Bool,
        disabledReason: String?,
        note: String? = nil,
        set: @escaping @MainActor (Bool) -> Void
    ) -> some View {
        HStack(spacing: ZPDFSpacing.m) {
            Toggle(isOn: Binding(
                get: { value ?? false },
                set: { set($0) }
            )) {
                Text(value == nil ? InspectorSelectionSummary.mixedPlaceholder : "")
                    .zpdfText(.caption, .textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!isEnabled)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(Self.booleanAccessibilityValue(value, note: note)))
            .help(isEnabled ? "" : (disabledReason ?? ""))
            if let note {
                Text(note)
                    .zpdfText(.caption, .textSecondary)
                    .lineLimit(2)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
    }

    /// What VoiceOver says for a Boolean row's value, with the row's note when it has one.
    static func booleanAccessibilityValue(_ value: Bool?, note: String?) -> String {
        let spoken = booleanAccessibilityValue(value)
        guard let note, !note.isEmpty else { return spoken }
        return String(
            format: NSLocalizedString("%1$@, %2$@", comment: "Inspector switch spoken value: state, then why (for example On, Hidden by layer Walls)"),
            spoken, note
        )
    }

    /// What VoiceOver says for a Boolean row's value.
    static func booleanAccessibilityValue(_ value: Bool?) -> String {
        switch value {
        case true?: return NSLocalizedString("On", comment: "Accessibility value of an Inspector switch that is on")
        case false?: return NSLocalizedString("Off", comment: "Accessibility value of an Inspector switch that is off")
        case nil: return InspectorSelectionSummary.mixedPlaceholder
        }
    }

    /// The Project Zone popup: None, then every zone in tree order, the current one checked.
    @ViewBuilder
    func zoneControl(_ summary: InspectorSelectionSummary) -> some View {
        // `nil` when the selection disagrees; `.some(nil)` when it shares "no zone".
        let current: String?? = summary.common(\.zone)
        let noneTitle = NSLocalizedString("None", comment: "Zone value when the markup has no zone")
        let title = current.map { $0 ?? noneTitle } ?? InspectorSelectionSummary.mixedPlaceholder
        let enabled = canAssignZone(summary)
        InspectorPopup(title: title, isEnabled: enabled) {
            Button {
                assignZone(nil, for: summary)
            } label: {
                if case .some(.none) = current {
                    Label(noneTitle, systemImage: "checkmark")
                } else {
                    Text(noneTitle)
                }
            }
            let zones = environment.projectZones.treeOrdered
            if !zones.isEmpty { Divider() }
            ForEach(zones) { zone in
                Button {
                    assignZone(zone.id, for: summary)
                } label: {
                    if case .some(.some(let name)) = current, name == zone.name {
                        Label(zone.name, systemImage: "checkmark")
                    } else {
                        Text(zone.name)
                    }
                }
            }
        }
        .help(enabled ? "" : Self.zoneDisabledReason(summary, wired: environment.inspectorEditing.onSetZone != nil))
        .accessibilityLabel(Text(NSLocalizedString("Project Zone", comment: "Inspector row label")))
        .accessibilityValue(Text(title))
    }

    /// Why the zone popup is off.
    static func zoneDisabledReason(_ summary: InspectorSelectionSummary, wired: Bool) -> String {
        if summary.includesLockedMarkup {
            return lockedMarkupReason
        }
        return wired ? "" : NSLocalizedString(
            "Zones can be assigned in a project.",
            comment: "Inspector zone popup help when zone assignment is unavailable"
        )
    }
}

extension InspectorPanel {

    /// The Layer row's value, drawn as a plain value (glyph and text, no field box).
    ///
    /// nl-ux: it was drawn in the popup's boxed face, which is the shape every other Inspector
    /// control has, so it read as a popup that did nothing when clicked. The product has no
    /// command that moves a markup to another markup layer yet (no markup-layer names are
    /// stored in a project; NL-UX-08 records that), so the honest form is a value, styled like
    /// Author beside it.
    @ViewBuilder
    func layerValue(_ summary: InspectorSelectionSummary) -> some View {
        // ADR-0032 (r2-layers): a project with markup layers gets the real popup
        // (`Layers/InspectorLayerControl.swift`); a surface without them keeps the value.
        if environment.markupLayers.isInstalled {
            layerControl(summary)
        } else {
            plainLayerValue(summary)
        }
    }

    @ViewBuilder
    func plainLayerValue(_ summary: InspectorSelectionSummary) -> some View {
        let text = Self.layerText(summary)
        HStack(spacing: ZPDFSpacing.m) {
            ZPDFGlyphView(.symbol(.layers), size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(ZPDFColor.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .zpdfText(.control, .textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NSLocalizedString("Layer", comment: "Inspector row label")))
        .accessibilityValue(Text(text))
    }

    /// What the Layer row reads for a selection.
    static func layerText(_ summary: InspectorSelectionSummary) -> String {
        summary.displayText(\.layer) {
            $0 ?? NSLocalizedString("None", comment: "Layer value when the markup has no layer")
        }
    }

}
