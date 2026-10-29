import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// The Navigator's Project Zones page: the zones that exist, and the controls that make one.
///
/// Until this shipped the page listed zones and toggled their boundaries — over a list nothing
/// in the product could add to. The two controls that changed that are the header's Add Zone
/// and the footer's "Group Quantity Ledger by Zone", which is the whole point of filing
/// quantities into zones in the first place.
public struct ProjectZonesPanel: View {

    @Bindable private var model: ProjectZonesPanelModel
    private let onClose: (() -> Void)?
    /// What Escape does when there is nothing on the page to cancel and no ``onClose``.
    let onExitWhenIdle: (() -> Void)?

    /// - Parameters:
    ///   - model: the controller. Every action routes through it.
    ///   - onClose: collapses the Navigator, when the page is shown as a panel with a way out.
    ///     Also draws the header's close button.
    ///   - onExitWhenIdle: where an idle Escape goes on a page without a close button — the
    ///     Navigator hosting the page backs out one level (R-095). The page's own Escape
    ///     handler consumes the key, so without this an idle Escape did nothing at all.
    public init(
        model: ProjectZonesPanelModel,
        onClose: (() -> Void)? = nil,
        onExitWhenIdle: (() -> Void)? = nil
    ) {
        self._model = Bindable(model)
        self.onClose = onClose
        self.onExitWhenIdle = onExitWhenIdle
    }

    /// Escape, one level at a time: stop drawing a boundary, cancel a rename, drop a draft —
    /// and with nothing left, close the page or hand the key to its host.
    func handleExitCommand() {
        if model.isAwaitingBoundary {
            model.stopBoundaryDrawing()
        } else if model.renamingZoneID != nil {
            model.cancelRename()
        } else if model.draft != nil {
            model.cancelZoneCreation()
        } else {
            (onClose ?? onExitWhenIdle)?()
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ZPDFHairlineDivider(axis: .horizontal)

            if let refusal = model.refusal {
                ZPDFInlineWarning(severity: .warning, message: refusal.message)
                    .padding(.horizontal, ZPDFSpacing.s)
                    .padding(.top, ZPDFSpacing.s)
            }

            if model.isAwaitingBoundary {
                ZPDFInlineWarning(
                    severity: .info,
                    message: NSLocalizedString(
                        "Draw the zone boundary on the page. Close the polygon to finish.",
                        comment: "Prompt shown while the canvas is waiting for a zone boundary"
                    ),
                    // BH-304: stopping the drawing keeps the named draft.
                    actionTitle: NSLocalizedString("Stop Drawing", comment: "Button: stop drawing a zone boundary, keeping the draft"),
                    action: { model.stopBoundaryDrawing() }
                )
                .padding(.horizontal, ZPDFSpacing.s)
                .padding(.top, ZPDFSpacing.s)
            }

            if model.draft != nil {
                ProjectZoneDraftEditor(model: model)
                    .padding(ZPDFSpacing.s)
                ZPDFHairlineDivider(axis: .horizontal)
            }

            if model.zones.isEmpty && model.draft == nil {
                ZPDFEmptyState(
                    glyph: .symbol(.projectZones),
                    title: NSLocalizedString("No Project Zones", comment: "Zones empty state title"),
                    message: NSLocalizedString(
                        "Draw a zone to group quantities by area, floor or phase. The Quantity Ledger can then total each zone on its own.",
                        comment: "Zones empty state message"
                    ),
                    actionTitle: NSLocalizedString("Add Zone", comment: "Zones empty state action"),
                    action: { model.beginZone() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                ZPDFHairlineDivider(axis: .horizontal)
                footer
            }
        }
        .background(ZPDFColor.color(NavigatorStyle.panelFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Project Zones", comment: "Accessibility label")))
        .onExitCommand { handleExitCommand() }
    }

    private var header: some View {
        ZPDFPanelHeader(
            title: NSLocalizedString("Project Zones", comment: "Panel title"),
            count: model.zones.count
        ) {
            HStack(spacing: ZPDFSpacing.xs) {
                ZPDFToolbarButton(
                    glyph: .symbol(.add),
                    title: NSLocalizedString("Add Zone", comment: "Button"),
                    prominence: .accent,
                    action: { model.beginZone() }
                )
                if let onClose {
                    ZPDFToolbarButton(
                        glyph: .symbol(.close),
                        title: NSLocalizedString("Close Project Zones", comment: "Button"),
                        action: onClose
                    )
                }
            }
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .padding(.vertical, ZPDFSpacing.xs)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // BH-825: tree order, so an indented child sits under its own parent.
                ForEach(model.treeOrdered) { zone in
                    ProjectZoneRow(
                        zone: zone,
                        depth: depth(of: zone),
                        isSelected: model.selection == zone.id,
                        model: model
                    )
                    ZPDFHairlineDivider(leadingInset: ZPDFSpacing.s)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Button {
                model.groupLedgerByZone()
            } label: {
                HStack(spacing: ZPDFSpacing.s) {
                    ZPDFGlyphView(.symbol(.quantityLedger), size: ZPDFSpacing.Control.iconSmall)
                    Text(NSLocalizedString(
                        "Group Quantity Ledger by Zone",
                        comment: "Button: regroup the ledger by Project Zone"
                    ))
                    .zpdfFont(.control)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ZPDFColor.textPrimary)

            Text(
                model.ledgerGroupingWouldBeEmpty
                    ? NSLocalizedString(
                        "No markups are filed into a zone yet, so every row would land in one group.",
                        comment: "Footnote when no markup carries a zone"
                    )
                    : String(
                        format: NSLocalizedString(
                            "%d markups are filed into zones.",
                            comment: "Footnote: how many markups carry a zone"
                        ),
                        model.filedMarkupCount
                    )
            )
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZPDFSpacing.s)
    }

    private func depth(of zone: ProjectZoneSummary) -> Int {
        var depth = 0
        var current = zone.parentID
        var remaining = model.zones.count
        while let id = current, remaining > 0 {
            depth += 1
            current = model.zone(id)?.parentID
            remaining -= 1
        }
        return depth
    }
}

/// One zone row: colour, name, type, count, visibility, and the actions on it.
struct ProjectZoneRow: View {

    let zone: ProjectZoneSummary
    let depth: Int
    let isSelected: Bool
    let model: ProjectZonesPanelModel

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: ZPDFSpacing.s) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * ZPDFSpacing.m)
            }

            RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
                .fill(
                    Color(
                        .sRGB,
                        red: zone.colorRGBA.red,
                        green: zone.colorRGBA.green,
                        blue: zone.colorRGBA.blue,
                        opacity: zone.colorRGBA.alpha
                    )
                )
                .frame(width: ZPDFSpacing.m, height: ZPDFSpacing.m)
                .overlay {
                    RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
                        .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.hairline)
                }
                // Decoration: the row's accessibility value carries the type and count in words.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                if model.renamingZoneID == zone.id {
                    TextField(
                        NSLocalizedString("Zone name", comment: "Rename field in a zone row"),
                        text: Binding(get: { model.renameDraft }, set: { model.renameDraft = $0 })
                    )
                    .textFieldStyle(.roundedBorder)
                    .zpdfFont(.control)
                    .onSubmit { model.commitRename() }
                    .onExitCommand { model.cancelRename() }
                    .accessibilityLabel(Text(String(
                        format: NSLocalizedString("New name for %@", comment: "Accessibility label of a zone's rename field"),
                        zone.name
                    )))
                } else {
                    Text(zone.name).zpdfText(.control, .textPrimary).lineLimit(1)
                }
                Text(subtitle).zpdfText(.caption, .textSecondary).lineLimit(1)
            }

            Spacer(minLength: ZPDFSpacing.xs)

            Text(zone.markupCount.formatted())
                .zpdfText(.monoNumeric.withSize(11), .textSecondary)

            ZPDFToolbarButton(
                glyph: .symbol(zone.isVisible ? .visible : .hidden),
                title: zone.isVisible
                    ? NSLocalizedString("Hide zone boundary", comment: "Row action")
                    : NSLocalizedString("Show zone boundary", comment: "Row action"),
                isSelected: !zone.isVisible,
                action: { model.setVisible(!zone.isVisible, zoneID: zone.id) }
            )

            Menu {
                Button(NSLocalizedString("File Selection into Zone", comment: "Zone row menu")) {
                    model.assignSelection(to: zone.id)
                }
                .disabled(model.selectedMarkupCount == 0)

                // BH-301 / IM-142: a misnamed or misplaced zone can be fixed in place.
                Button(NSLocalizedString("Rename…", comment: "Zone row menu")) {
                    model.beginRename(zoneID: zone.id)
                }

                Menu(NSLocalizedString("Move Into", comment: "Zone row submenu: choose the parent zone")) {
                    Button(NSLocalizedString("Top Level", comment: "Zone parent choice: no parent")) {
                        model.setParent(nil, zoneID: zone.id)
                    }
                    .disabled(zone.parentID == nil)
                    ForEach(model.parentChoices(for: zone.id)) { candidate in
                        Button(candidate.name) { model.setParent(candidate.id, zoneID: zone.id) }
                            .disabled(zone.parentID == candidate.id)
                    }
                }

                Menu(NSLocalizedString("Zone Type", comment: "Zone row submenu")) {
                    ForEach(ProjectZoneKind.allCases) { kind in
                        Button(kind.displayName) { model.setKind(kind, zoneID: zone.id) }
                    }
                }

                Menu(NSLocalizedString("Colour", comment: "Zone row submenu")) {
                    ForEach(ZenitMarkupPalette.entries) { entry in
                        Button(entry.name) { model.setColor(paletteID: entry.id, zoneID: zone.id) }
                    }
                }

                Divider()

                // IM-142: the unavailable Delete says why.
                Button(ProjectZonesPanelModel.deleteTitle(markupCount: zone.markupCount), role: .destructive) {
                    model.delete(zoneID: zone.id)
                }
                .disabled(zone.markupCount > 0)
            } label: {
                ZPDFGlyphView(.symbol(.more), size: ZPDFSpacing.Control.iconSmall)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: ZPDFSpacing.Control.minimumHitTarget)
            .accessibilityLabel(Text(
                String(
                    format: NSLocalizedString("Actions for %@", comment: "Accessibility label for a zone's action menu"),
                    zone.name
                )
            ))
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .padding(.vertical, ZPDFSpacing.xs)
        .frame(minHeight: ZPDFSpacing.Control.listRow)
        // The Navigator's selected-card language (2026-09-23 mockup): an accent wash and an
        // accent bar — shape as well as tint, so the state survives greyscale.
        .background(ZPDFColor.color(NavigatorStyle.accent).opacity(isSelected ? NavigatorStyle.selectionTint : 0))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(ZPDFColor.color(NavigatorStyle.stateLine))
                .frame(width: NavigatorStyle.tabUnderline)
                .padding(.vertical, ZPDFSpacing.xs)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = zone.id }
        .focusable()
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.hairline)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(zone.name))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var subtitle: String {
        var parts = [zone.kind.displayName]
        if let pageLabel = zone.pageLabel { parts.append(pageLabel) }
        if zone.boundary.isEmpty {
            parts.append(NSLocalizedString("no boundary", comment: "Zone subtitle: zone has no drawn area"))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        var parts = [zone.accessibilityLabel]
        parts.append(
            zone.isVisible
                ? NSLocalizedString("boundary shown", comment: "Accessibility: zone boundary is drawn")
                : NSLocalizedString("boundary hidden", comment: "Accessibility: zone boundary is not drawn")
        )
        return parts.joined(separator: ", ")
    }
}

/// Naming, typing, colouring and nesting a zone before it exists.
struct ProjectZoneDraftEditor: View {

    @Bindable var model: ProjectZonesPanelModel

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
                TextField(
                    NSLocalizedString("Zone name", comment: "Draft editor field label"),
                    text: Binding(get: { draft.name }, set: { model.setDraftName($0) })
                )
                .textFieldStyle(.roundedBorder)
                .zpdfFont(.control)
                .accessibilityLabel(Text(NSLocalizedString("Zone name", comment: "Accessibility label")))

                Picker(
                    NSLocalizedString("Zone type", comment: "Draft editor field label"),
                    selection: Binding(get: { draft.kind }, set: { model.setDraftKind($0) })
                ) {
                    ForEach(ProjectZoneKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .zpdfFont(.control)

                // BH-301: nesting is reachable when the zone is created.
                if !model.zones.isEmpty {
                    Picker(
                        NSLocalizedString("Inside", comment: "Draft editor field label: the parent zone"),
                        selection: Binding(get: { draft.parentID }, set: { model.setDraftParent($0) })
                    ) {
                        Text(NSLocalizedString("Top Level", comment: "Zone parent choice: no parent")).tag(UUID?.none)
                        ForEach(model.parentChoices(for: nil)) { candidate in
                            Text(candidate.name).tag(UUID?.some(candidate.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .zpdfFont(.control)
                }

                HStack(spacing: ZPDFSpacing.xs) {
                    Text(NSLocalizedString("Colour", comment: "Draft editor field label"))
                        .zpdfText(.caption, .textSecondary)
                    ForEach(ZenitMarkupPalette.entries) { entry in
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
                                .frame(width: ZPDFSpacing.m, height: ZPDFSpacing.m)
                                .overlay {
                                    RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
                                        .strokeBorder(
                                            draft.colorPaletteID == entry.id
                                                ? ZPDFColor.color(NavigatorStyle.stateLine)
                                                : ZPDFColor.color(NavigatorStyle.hairline),
                                            lineWidth: draft.colorPaletteID == entry.id
                                                ? ZPDFStroke.emphasis
                                                : ZPDFStroke.hairline
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(entry.name))
                        .accessibilityAddTraits(
                            draft.colorPaletteID == entry.id ? [.isButton, .isSelected] : .isButton
                        )
                    }
                    Spacer(minLength: 0)
                }

                Button {
                    model.beginBoundary()
                } label: {
                    Text(
                        draft.hasBoundary
                            ? NSLocalizedString("Redraw boundary", comment: "Draft editor button")
                            : NSLocalizedString("Draw boundary on the page", comment: "Draft editor button")
                    )
                    .zpdfFont(.control)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ZPDFColor.accentBlue)

                Text(
                    draft.hasBoundary
                        ? String(
                            format: NSLocalizedString(
                                "Boundary drawn on page %@.",
                                comment: "Draft editor state: boundary is drawn on a named page"
                            ),
                            draft.pageLabel ?? ""
                        )
                        : NSLocalizedString(
                            "A zone with no boundary still groups quantities; it just is not drawn on the sheet.",
                            comment: "Draft editor state: no boundary drawn"
                        )
                )
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: ZPDFSpacing.s) {
                    Spacer(minLength: 0)
                    Button {
                        model.cancelZoneCreation()
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
                        Text(NSLocalizedString("Create Zone", comment: "Draft editor button"))
                            .zpdfFont(.control.withWeight(.semibold))
                            .padding(.horizontal, ZPDFSpacing.m)
                            .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.canCommitDraft ? ZPDFColor.textPrimary : ZPDFColor.textSecondary)
                    .zpdfControlBackground(
                        fill: model.canCommitDraft ? .selection : .elevated,
                        cornerRadius: ZPDFRadius.small
                    )
                    .disabled(!model.canCommitDraft)
                }
            }
            .zpdfControlBackground(fill: .elevated, stroke: .border, cornerRadius: ZPDFRadius.small)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(NSLocalizedString("New Project Zone", comment: "Accessibility label")))
        }
    }
}
