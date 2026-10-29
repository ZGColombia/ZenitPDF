import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Scale Regions panel as the application actually shows it: a ``ScaleRegionsPanelModel``
/// on top, the list underneath, and the draft editor in between while a region is being made.
///
/// ``ScaleRegionsPanel`` stays a pure function of its inputs — that is what makes it previewable
/// and snapshot-testable. This host is the part that has a controller, so every action the panel
/// offers ends somewhere real instead of in a defaulted no-op closure.
public struct ScaleRegionsPanelHost: View {

    @Bindable private var model: ScaleRegionsPanelModel
    private let onClose: (() -> Void)?

    /// - Parameters:
    ///   - model: the controller. Every button routes through it.
    ///   - onClose: leaves the panel. Present whenever the panel is shown as a mode rather than
    ///     as a permanent pane, so there is always a visible way out next to the Escape route.
    public init(model: ScaleRegionsPanelModel, onClose: (() -> Void)? = nil) {
        self._model = Bindable(model)
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onClose {
                HStack(spacing: ZPDFSpacing.s) {
                    Spacer(minLength: 0)
                    ZPDFToolbarButton(
                        glyph: .symbol(.close),
                        title: NSLocalizedString("Close Scale Regions", comment: "Button: leave the panel"),
                        action: onClose
                    )
                }
                .padding(.horizontal, ZPDFSpacing.l)
                .padding(.top, ZPDFSpacing.s)
            }

            if let refusal = model.refusal {
                Group {
                    if model.canRevealRefusedMarkups {
                        // A refusal that names N measurements offers the way to them (IM-209).
                        ZPDFInlineWarning(
                            severity: .warning,
                            message: refusal.message,
                            actionTitle: NSLocalizedString(
                                "Show Measurements",
                                comment: "Button: select the measurements a Scale Region is the scale for"
                            ),
                            action: { model.revealRefusedMarkups() }
                        )
                    } else {
                        ZPDFInlineWarning(severity: .warning, message: refusal.message)
                    }
                }
                .padding(.horizontal, ZPDFSpacing.l)
                .padding(.top, ZPDFSpacing.s)
            }

            if model.isAwaitingPolygon {
                ZPDFInlineWarning(
                    severity: .info,
                    message: NSLocalizedString(
                        "Draw the region boundary on the page. Close the polygon to name it.",
                        comment: "Prompt shown while the canvas is waiting for a Scale Region boundary"
                    ),
                    actionTitle: NSLocalizedString("Cancel", comment: "Button: stop drawing a Scale Region"),
                    action: { model.cancelRegionCreation() }
                )
                .padding(.horizontal, ZPDFSpacing.l)
                .padding(.top, ZPDFSpacing.s)
            }

            if model.draft != nil {
                ScaleRegionDraftEditor(model: model)
                    .padding(ZPDFSpacing.l)
                ZPDFHairlineDivider()
            }

            ScaleRegionsPanel(
                regions: model.regions,
                pageDefaultScale: model.pageDefaultScale,
                overlaps: model.overlaps,
                crossing: model.crossing,
                selection: $model.selection,
                onAddRegion: { model.beginRegion() },
                onToggleLock: { id in
                    guard let region = model.region(id) else { return }
                    model.setLocked(!region.locked, regionID: id)
                },
                onToggleVisibility: { id in
                    guard let region = model.region(id) else { return }
                    model.setVisible(!region.isVisible, regionID: id)
                },
                onMovePriority: { id, delta in model.movePriority(regionID: id, by: delta) },
                onEditScale: { id in model.editScale(regionID: id) },
                availableScales: model.availableScales,
                onAssignScale: { id, scale in model.assignScale(scale, to: id) },
                renamingRegionID: model.renamingRegionID,
                renameDraft: $model.renameDraft,
                onBeginRename: { id in model.beginRename(regionID: id) },
                onCommitRename: { model.commitRename() },
                onCancelRename: { model.cancelRename() },
                onDeleteRegion: { id in model.delete(regionID: id) },
                onResolveOverlap: { overlap in model.revealOverlap(overlap) },
                onResolveCrossing: { resolution in
                    guard model.chooseCrossingResolution(resolution) else { return }
                    model.confirmCrossing()
                },
                // The model owns the choice and resets it for every crossing, with its own
                // offered-outcome check — one source of truth (IM-110).
                chosenCrossingResolution: Binding(
                    get: { model.chosenCrossingResolution },
                    set: { resolution in
                        if let resolution { _ = model.chooseCrossingResolution(resolution) }
                    }
                )
            )
        }
        .background(ZPDFColor.surface)
        .onExitCommand {
            if model.isAwaitingCrossingDecision {
                model.cancelCrossing()
            } else if model.renamingRegionID != nil {
                model.cancelRename()
            } else if model.draft != nil || model.isAwaitingPolygon {
                model.cancelRegionCreation()
            } else {
                onClose?()
            }
        }
    }
}

/// Naming, colouring and — the part that matters — assigning a scale to a region before it
/// exists.
///
/// The Create button is disabled until a scale has been assigned, and the sentence next to it
/// says why. A region created without a scale would measure at something nobody stated, which
/// is the silent-wrongness this whole panel is built against.
struct ScaleRegionDraftEditor: View {

    @Bindable var model: ScaleRegionsPanelModel

    @FocusState private var isNameFocused: Bool

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                Text(
                    String(
                        format: NSLocalizedString(
                            "New Scale Region on page %@",
                            comment: "Draft editor heading: page label"
                        ),
                        draft.pageLabel
                    )
                )
                .zpdfText(.control, .textPrimary)

                TextField(
                    NSLocalizedString("Region name", comment: "Draft editor field label"),
                    text: Binding(get: { draft.name }, set: { model.setDraftName($0) })
                )
                .textFieldStyle(.roundedBorder)
                .zpdfFont(.control)
                .focused($isNameFocused)
                // Draw, type the name, Return (IM-111).
                .onSubmit { model.commitDraft() }
                .onAppear { isNameFocused = true }
                .accessibilityLabel(Text(NSLocalizedString("Region name", comment: "Accessibility label")))

                colorPicker(draft: draft)
                scalePicker(draft: draft)

                Toggle(isOn: Binding(get: { draft.locked }, set: { model.setDraftLocked($0) })) {
                    Text(NSLocalizedString("Lock this region", comment: "Draft editor toggle"))
                        .zpdfText(.control, .textPrimary)
                }
                .toggleStyle(.checkbox)

                // L-95 (live test 8): the sentence sat beside the buttons and was broken into
                // short lines between them. It has the editor's full width now, above the
                // buttons, with a glyph when it is the reason Create is off — never colour alone.
                HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.xs) {
                    if !model.canCommitDraft {
                        ZPDFGlyphView(.symbol(.warning), size: ZPDFSpacing.Control.iconSmall)
                            .foregroundStyle(ZPDFColor.warning)
                            .accessibilityHidden(true)
                    }
                    Text(scaleStateSentence(draft: draft))
                        .zpdfText(.caption, model.canCommitDraft ? .textSecondary : .warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: ZPDFSpacing.m) {
                    Spacer(minLength: 0)
                    Button {
                        model.cancelRegionCreation()
                    } label: {
                        Text(NSLocalizedString("Cancel", comment: "Draft editor button"))
                            .zpdfFont(.control)
                            .padding(.horizontal, ZPDFSpacing.m)
                            .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ZPDFColor.textSecondary)

                    Button {
                        model.commitDraft()
                    } label: {
                        Text(NSLocalizedString("Create Region", comment: "Draft editor button"))
                            .zpdfFont(.control.withWeight(.semibold))
                            .padding(.horizontal, ZPDFSpacing.l)
                            .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.canCommitDraft ? ZPDFColor.textPrimary : ZPDFColor.textSecondary)
                    .zpdfControlBackground(
                        fill: model.canCommitDraft ? .selection : .elevated,
                        cornerRadius: ZPDFRadius.small
                    )
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCommitDraft)
                    .accessibilityHint(Text(scaleStateSentence(draft: draft)))
                }
            }
            .zpdfControlBackground(fill: .elevated, stroke: .border, cornerRadius: ZPDFRadius.small)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(NSLocalizedString("New Scale Region", comment: "Accessibility label")))
        }
    }

    private func colorPicker(draft: ScaleRegionDraft) -> some View {
        HStack(spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Colour", comment: "Draft editor field label"))
                .zpdfText(.caption, .textSecondary)
            ForEach(ZenitRegionPalette.entries) { entry in
                Button {
                    model.setDraftColor(paletteID: entry.id)
                } label: {
                    RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
                        .fill(
                            Color(
                                .sRGB,
                                red: entry.color.red,
                                green: entry.color.green,
                                blue: entry.color.blue,
                                opacity: entry.color.alpha
                            )
                        )
                        .frame(width: ZPDFSpacing.l, height: ZPDFSpacing.l)
                        .overlay {
                            RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
                                .strokeBorder(
                                    draft.colorPaletteID == entry.id ? ZPDFColor.accentCyan : ZPDFColor.border,
                                    lineWidth: draft.colorPaletteID == entry.id
                                        ? ZPDFStroke.emphasis
                                        : ZPDFStroke.hairline
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(entry.name))
                .accessibilityAddTraits(draft.colorPaletteID == entry.id ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }

    private func scalePicker(draft: ScaleRegionDraft) -> some View {
        HStack(spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Scale", comment: "Draft editor field label"))
                .zpdfText(.caption, .textSecondary)
            Menu {
                ForEach(model.availableScales) { scale in
                    Button {
                        model.assignDraftScale(scale)
                    } label: {
                        Text("\(scale.name) · \(scale.displayString)")
                    }
                }
                if !model.availableScales.isEmpty { Divider() }
                Button {
                    model.calibrateDraft()
                } label: {
                    Text(NSLocalizedString("Calibrate on the drawing…", comment: "Draft editor scale menu"))
                }
            } label: {
                Text(
                    draft.scale.map { "\($0.displayString)" }
                        ?? NSLocalizedString("Not assigned", comment: "Draft editor: no scale chosen yet")
                )
                .zpdfFont(.control)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityLabel(Text(NSLocalizedString("Region scale", comment: "Accessibility label")))
            .accessibilityValue(
                Text(
                    draft.scale?.accessibilityValue
                        ?? NSLocalizedString("Not assigned", comment: "Accessibility value: no scale chosen")
                )
            )
            Spacer(minLength: 0)
        }
    }

    private func scaleStateSentence(draft: ScaleRegionDraft) -> String {
        // The same verdict the Create button is disabled by (IM-112).
        if let problem = model.draftProblem { return problem.message }
        return String(
            format: NSLocalizedString(
                "Everything inside this boundary will measure at %@.",
                comment: "Draft editor confirmation: the chosen ratio"
            ),
            draft.scale?.displayString ?? ""
        )
    }
}
