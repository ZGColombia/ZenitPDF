import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Scale Regions panel: which part of a page measures at which scale.
///
/// Regions are listed in resolution order, highest priority first, because that order is what
/// actually decides a measurement. Priority is moved with buttons rather than drag alone, so
/// the order is reachable from the keyboard. Overlaps are reported, never resolved silently.
public struct ScaleRegionsPanel: View {

    private let regions: [ScaleRegionSummary]
    private let pageDefaultScale: ScaleSummary?
    private let overlaps: [ScaleRegionOverlap]
    private let crossing: ScaleRegionCrossing?
    @Binding private var selection: UUID?
    private let onAddRegion: () -> Void
    private let onToggleLock: (UUID) -> Void
    private let onToggleVisibility: (UUID) -> Void
    private let onMovePriority: (UUID, Int) -> Void
    private let onEditScale: (UUID) -> Void
    private let availableScales: [ScaleSummary]
    private let onAssignScale: (UUID, ScaleSummary) -> Void
    private let renamingRegionID: UUID?
    private let renameDraft: Binding<String>
    private let onBeginRename: (UUID) -> Void
    private let onCommitRename: () -> Void
    private let onCancelRename: () -> Void
    private let onDeleteRegion: (UUID) -> Void
    private let onResolveOverlap: (ScaleRegionOverlap) -> Void
    private let onResolveCrossing: (ScaleRegionCrossingResolution) -> Void

    private let externalChoice: Binding<ScaleRegionCrossingResolution?>?
    /// Used only when the host does not bind the choice to its model. Keyed by crossing, so a
    /// choice made for one crossing can never appear as the answer to the next (BH-048).
    @State private var localChoice = ScaleRegionCrossingChoice()

    /// - Parameters:
    ///   - regions: every region on the page, in any order; the panel sorts by priority.
    ///   - pageDefaultScale: the scale used outside every region.
    ///   - overlaps: overlaps detected by the core. Empty is the normal case.
    ///   - crossing: set while a markup is waiting for a crossing decision.
    ///   - selection: the highlighted region.
    ///   - onAddRegion: start drawing a new region.
    ///   - onToggleLock: lock or unlock a region.
    ///   - onToggleVisibility: show or hide a region outline.
    ///   - onMovePriority: move a region by `delta` places in the priority order.
    ///   - onEditScale: open calibration for a region.
    ///   - availableScales: the project's scales, offered in a row's scale menu so a region can
    ///     take one that is already calibrated (S-091).
    ///   - onAssignScale: give a region one of `availableScales`.
    ///   - renamingRegionID: the region whose name is open for editing in its row.
    ///   - renameDraft: the text of that row's rename field.
    ///   - onBeginRename: open a region's name for editing.
    ///   - onCommitRename: commit the rename field (Return).
    ///   - onCancelRename: close the rename field without an edit (Escape).
    ///   - onDeleteRegion: remove a region. Refused while it is locked or still measures
    ///     something — see ``ScaleRegionsPanelModel/delete(regionID:)``.
    ///   - onResolveOverlap: jump to the overlap so the user can fix it.
    ///   - onResolveCrossing: apply one of the three legal crossing outcomes.
    ///   - chosenCrossingResolution: the host's own record of the outcome being chosen —
    ///     normally `ScaleRegionsPanelModel.chosenCrossingResolution`, which the model resets
    ///     for every new crossing. When `nil` the panel keeps a per-crossing choice itself.
    ///
    /// Every action defaults to an explicit no-op so previews and tests can render the panel
    /// without a document behind it.
    public init(
        regions: [ScaleRegionSummary],
        pageDefaultScale: ScaleSummary?,
        overlaps: [ScaleRegionOverlap] = [],
        crossing: ScaleRegionCrossing? = nil,
        selection: Binding<UUID?>,
        onAddRegion: @escaping () -> Void = {},
        onToggleLock: @escaping (UUID) -> Void = { _ in },
        onToggleVisibility: @escaping (UUID) -> Void = { _ in },
        onMovePriority: @escaping (UUID, Int) -> Void = { _, _ in },
        onEditScale: @escaping (UUID) -> Void = { _ in },
        availableScales: [ScaleSummary] = [],
        onAssignScale: @escaping (UUID, ScaleSummary) -> Void = { _, _ in },
        renamingRegionID: UUID? = nil,
        renameDraft: Binding<String> = .constant(""),
        onBeginRename: @escaping (UUID) -> Void = { _ in },
        onCommitRename: @escaping () -> Void = {},
        onCancelRename: @escaping () -> Void = {},
        onDeleteRegion: @escaping (UUID) -> Void = { _ in },
        onResolveOverlap: @escaping (ScaleRegionOverlap) -> Void = { _ in },
        onResolveCrossing: @escaping (ScaleRegionCrossingResolution) -> Void = { _ in },
        chosenCrossingResolution: Binding<ScaleRegionCrossingResolution?>? = nil
    ) {
        self.externalChoice = chosenCrossingResolution
        self.regions = regions
        self.pageDefaultScale = pageDefaultScale
        self.overlaps = overlaps
        self.crossing = crossing
        self._selection = selection
        self.onAddRegion = onAddRegion
        self.onToggleLock = onToggleLock
        self.onToggleVisibility = onToggleVisibility
        self.onMovePriority = onMovePriority
        self.onEditScale = onEditScale
        self.availableScales = availableScales
        self.onAssignScale = onAssignScale
        self.renamingRegionID = renamingRegionID
        self.renameDraft = renameDraft
        self.onBeginRename = onBeginRename
        self.onCommitRename = onCommitRename
        self.onCancelRename = onCancelRename
        self.onDeleteRegion = onDeleteRegion
        self.onResolveOverlap = onResolveOverlap
        self.onResolveCrossing = onResolveCrossing
    }

    /// What a region's scale menu offers: every project scale, with the one the region already
    /// uses marked so it is shown but not offered as a change.
    static func scaleChoices(
        _ available: [ScaleSummary],
        for region: ScaleRegionSummary
    ) -> [(scale: ScaleSummary, isCurrent: Bool)] {
        available.map { ($0, $0.id == region.scale.id) }
    }

    /// Every region named in at least one overlap.
    static func overlappingIDs(_ overlaps: [ScaleRegionOverlap]) -> Set<UUID> {
        Set(overlaps.flatMap { [$0.first, $0.second] })
    }

    /// The outcome binding the resolver shows for `crossing`.
    private func choiceBinding(for crossing: ScaleRegionCrossing) -> Binding<ScaleRegionCrossingResolution?> {
        if let externalChoice { return externalChoice }
        return Binding(
            get: { localChoice.resolution(for: crossing) },
            set: { localChoice.choose($0, for: crossing) }
        )
    }

    /// The regions in the order the panel lists them — resolution order
    /// (``ScaleRegionSummary/inResolutionOrder(_:)``), the order Raise and Lower move through
    /// (``ScaleRegionsPanelModel/ordered``).
    var rows: [ScaleRegionSummary] { ScaleRegionSummary.inResolutionOrder(regions) }

    public var body: some View {
        // Sorted once and the overlap set built once per render, not on every access and in
        // every row (IM-206).
        let ordered = rows
        let overlapping = Self.overlappingIDs(overlaps)
        return VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Scale Regions", comment: "Panel title"),
                subtitle: pageDefaultScale.map {
                    String(
                        format: NSLocalizedString("Page default %@", comment: "Panel subtitle: default scale ratio"),
                        $0.displayString
                    )
                },
                count: regions.count
            ) {
                ZPDFToolbarButton(
                    glyph: .symbol(.add),
                    title: NSLocalizedString("Add Scale Region", comment: "Button"),
                    prominence: .accent,
                    action: onAddRegion
                )
            }
            .padding(.horizontal, ZPDFSpacing.l)
            .padding(.vertical, ZPDFSpacing.s)

            ZPDFHairlineDivider()

            if let crossing {
                ScaleRegionCrossingResolver(
                    crossing: crossing,
                    chosen: choiceBinding(for: crossing),
                    onResolve: onResolveCrossing
                )
                // A new crossing is a new decision: fresh view identity, nothing carried over.
                .id(crossing.id)
                .padding(ZPDFSpacing.l)
                ZPDFHairlineDivider()
            }

            if !overlaps.isEmpty {
                VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
                    ForEach(overlaps) { overlap in
                        ZPDFInlineWarning(
                            severity: .warning,
                            message: overlap.message,
                            actionTitle: NSLocalizedString("Show Overlap", comment: "Button: reveal the overlapping area"),
                            action: { onResolveOverlap(overlap) }
                        )
                    }
                }
                .padding(ZPDFSpacing.l)
                ZPDFHairlineDivider()
            }

            if ordered.isEmpty {
                ZPDFEmptyState(
                    glyph: .symbol(.scaleRegions),
                    title: NSLocalizedString("No Scale Regions", comment: "Empty state title"),
                    message: NSLocalizedString(
                        "The whole page measures at its default scale. Add a region when one part of the drawing is drawn at a different scale.",
                        comment: "Empty state message"
                    ),
                    actionTitle: NSLocalizedString("Add Scale Region", comment: "Empty state action"),
                    action: onAddRegion
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(ordered, overlapping: overlapping)
            }
        }
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Scale Regions", comment: "Accessibility label")))
    }

    private func list(_ ordered: [ScaleRegionSummary], overlapping: Set<UUID>) -> some View {
        let total = ordered.count
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, region in
                    ScaleRegionRow(
                        region: region,
                        order: index + 1,
                        total: total,
                        isSelected: selection == region.id,
                        isOverlapping: overlapping.contains(region.id),
                        onSelect: { selection = region.id },
                        onToggleLock: { onToggleLock(region.id) },
                        onToggleVisibility: { onToggleVisibility(region.id) },
                        onMoveUp: { onMovePriority(region.id, -1) },
                        onMoveDown: { onMovePriority(region.id, 1) },
                        onEditScale: { onEditScale(region.id) },
                        scaleChoices: Self.scaleChoices(availableScales, for: region),
                        onAssignScale: { scale in onAssignScale(region.id, scale) },
                        isRenaming: renamingRegionID == region.id,
                        renameDraft: renameDraft,
                        onBeginRename: { onBeginRename(region.id) },
                        onCommitRename: onCommitRename,
                        onCancelRename: onCancelRename,
                        onDelete: { onDeleteRegion(region.id) }
                    )
                    ZPDFHairlineDivider(leadingInset: ZPDFSpacing.l)
                }
            }
        }
    }
}

/// One row in ``ScaleRegionsPanel``.
struct ScaleRegionRow: View {

    let region: ScaleRegionSummary
    let order: Int
    let total: Int
    let isSelected: Bool
    let isOverlapping: Bool
    let onSelect: () -> Void
    let onToggleLock: () -> Void
    let onToggleVisibility: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEditScale: () -> Void
    let scaleChoices: [(scale: ScaleSummary, isCurrent: Bool)]
    let onAssignScale: (ScaleSummary) -> Void
    let isRenaming: Bool
    let renameDraft: Binding<String>
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @FocusState private var isFocused: Bool
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        // L-95 (live test 8): one row held the name, the scale and seven controls, so in the
        // panel's own width the name was cut to "Scale Re…" and the scale to "1:50 · pri…". The
        // row keeps one line while the whole name and scale fit beside the controls, and moves
        // the controls to a line of their own when they do not.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ZPDFSpacing.m) {
                colorChip
                label
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: ZPDFSpacing.s)
                controls
            }
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                HStack(spacing: ZPDFSpacing.m) {
                    colorChip
                    label
                    Spacer(minLength: 0)
                }
                HStack(spacing: ZPDFSpacing.m) {
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .padding(.horizontal, ZPDFSpacing.l)
        .padding(.vertical, ZPDFSpacing.s)
        .frame(minHeight: ZPDFSpacing.Control.listRow)
        .background(isSelected ? ZPDFColor.selection.opacity(0.28) : Color.clear)
        .overlay(alignment: .leading) {
            // Selection is a bar plus a tint, so it survives greyscale and Increase Contrast.
            Rectangle()
                .fill(ZPDFColor.accentCyan)
                .frame(width: ZPDFStroke.emphasis)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .focusable()
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.hairline)
        .contextMenu {
            Button(NSLocalizedString("Rename…", comment: "Scale Region row menu")) { onBeginRename() }
                .disabled(region.locked)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(region.name))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The region's name — or its rename field — over its scale and order.
    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ZPDFSpacing.xs) {
                if isRenaming {
                    // S-091: a misnamed region is fixed in place — Return commits, Escape
                    // cancels, and a refused name keeps the field open with the reason shown.
                    TextField(
                        NSLocalizedString("Region name", comment: "Rename field in a Scale Region row"),
                        text: renameDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .zpdfFont(.control)
                    .focused($isRenameFocused)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .onAppear { isRenameFocused = true }
                    .accessibilityLabel(Text(String(
                        format: NSLocalizedString(
                            "New name for %@",
                            comment: "Accessibility label of a Scale Region's rename field"
                        ),
                        region.name
                    )))
                } else {
                    Text(region.name)
                        .zpdfText(.control, .textPrimary)
                        .lineLimit(1)
                }
                if isOverlapping {
                    ZPDFGlyphView(.symbol(.warning), size: ZPDFSpacing.Control.iconSmall)
                        .foregroundStyle(ZPDFColor.warning)
                }
            }
            Text(subtitle)
                .zpdfText(.caption, .textSecondary)
                .lineLimit(1)
        }
    }

    /// Raise and Lower, the scale, Rename, Show/Hide, Lock and Delete.
    private var controls: some View {
        HStack(spacing: ZPDFSpacing.m) {
            priorityControls

            scaleMenu
                .disabled(region.locked)

            ZPDFToolbarButton(
                glyph: .symbol(.text),
                title: NSLocalizedString("Rename region", comment: "Row action"),
                isSelected: isRenaming,
                action: onBeginRename
            )
            .disabled(region.locked || isRenaming)

            ZPDFToolbarButton(
                glyph: .symbol(region.isVisible ? .visible : .hidden),
                title: region.isVisible
                    ? NSLocalizedString("Hide region outline", comment: "Row action")
                    : NSLocalizedString("Show region outline", comment: "Row action"),
                isSelected: !region.isVisible,
                action: onToggleVisibility
            )

            ZPDFToolbarButton(
                glyph: .symbol(region.locked ? .lock : .unlock),
                title: region.locked
                    ? NSLocalizedString("Unlock region", comment: "Row action")
                    : NSLocalizedString("Lock region", comment: "Row action"),
                isSelected: region.locked,
                action: onToggleLock
            )

            // A region that can be created and not removed is its own dead end. Locking is
            // the guard against an accidental one, so a locked region's Delete is disabled
            // rather than hidden — the way out is visible, and it is the padlock.
            ZPDFToolbarButton(
                glyph: .symbol(.delete),
                title: NSLocalizedString("Delete region", comment: "Row action"),
                action: onDelete
            )
            .disabled(region.locked)
        }
    }

    /// The region's scale: assign one the project already has, or measure a new one. The same
    /// two routes the draft editor's scale menu offers, so a region is never stuck with the
    /// scale it was created with (S-091).
    private var scaleMenu: some View {
        Menu {
            ForEach(scaleChoices, id: \.scale.id) { choice in
                Button {
                    onAssignScale(choice.scale)
                } label: {
                    Text(choice.isCurrent
                        ? String(
                            format: NSLocalizedString(
                                "%@ (current)",
                                comment: "Scale Region scale menu: the scale the region already uses"
                            ),
                            "\(choice.scale.name) · \(choice.scale.displayString)"
                        )
                        : "\(choice.scale.name) · \(choice.scale.displayString)")
                }
                .disabled(choice.isCurrent)
            }
            if !scaleChoices.isEmpty { Divider() }
            Button(NSLocalizedString("Calibrate on the drawing…", comment: "Scale Region scale menu")) {
                onEditScale()
            }
        } label: {
            // Drawn like the row's other toolbar buttons, so the menu does not read as a
            // different kind of control.
            ZPDFGlyphView(.measurement(.calibrate), size: ZPDFSpacing.Control.icon)
                .frame(
                    minWidth: ZPDFSpacing.Control.minimumHitTarget,
                    minHeight: ZPDFSpacing.Control.toolbarButton
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(NSLocalizedString("Edit scale", comment: "Row action"))
        .accessibilityLabel(Text(NSLocalizedString("Edit scale", comment: "Row action")))
        .accessibilityValue(Text(region.scale.accessibilityValue))
    }

    private var colorChip: some View {
        RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
            .fill(
                Color(
                    .sRGB,
                    red: region.colorRGBA.red,
                    green: region.colorRGBA.green,
                    blue: region.colorRGBA.blue,
                    opacity: region.colorRGBA.alpha
                )
            )
            .frame(width: ZPDFSpacing.l, height: ZPDFSpacing.l)
            .overlay {
                RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
                    .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.hairline)
            }
            // The chip is decoration; the row's accessibility value names the colour in words
            // so the region is never identified by colour alone.
            .accessibilityHidden(true)
    }

    private var priorityControls: some View {
        HStack(spacing: 1) {
            ZPDFToolbarButton(
                glyph: .symbol(.disclosureOpen),
                title: NSLocalizedString("Raise priority", comment: "Row action"),
                helpText: NSLocalizedString(
                    "A higher priority region wins where two regions meet.",
                    comment: "Help tag for the priority controls"
                ),
                action: onMoveUp
            )
            .disabled(order == 1)
            .rotationEffect(.degrees(180))

            ZPDFToolbarButton(
                glyph: .symbol(.disclosureOpen),
                title: NSLocalizedString("Lower priority", comment: "Row action"),
                action: onMoveDown
            )
            .disabled(order == total)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(NSLocalizedString("Priority order", comment: "Accessibility label for the priority buttons"))
        )
    }

    private var subtitle: String {
        String(
            format: NSLocalizedString(
                "%1$@ · priority %2$d of %3$d · %4$@",
                comment: "Region row subtitle: ratio, priority, total, colour name"
            ),
            region.scale.displayString,
            order,
            total,
            colorName
        )
    }

    /// The region colour in words. The subtitle promised a colour name and printed
    /// `#1FB6D9`, and the accessibility value never mentioned colour at all (BH-751, IM-207).
    private var colorName: String { ZenitRegionPalette.name(for: region.colorRGBA) }

    private var accessibilityValue: String {
        var parts = [
            region.scale.accessibilityValue,
            String(
                format: NSLocalizedString("colour %@", comment: "Accessibility: the region outline colour name"),
                colorName
            ),
            String(
                format: NSLocalizedString("priority %1$d of %2$d", comment: "Accessibility: priority order"),
                order,
                total
            )
        ]
        if region.locked {
            parts.append(NSLocalizedString("locked", comment: "Accessibility: region is locked"))
        }
        if !region.isVisible {
            parts.append(NSLocalizedString("outline hidden", comment: "Accessibility: region outline is hidden"))
        }
        if isOverlapping {
            parts.append(NSLocalizedString("overlaps another region", comment: "Accessibility: region overlaps"))
        }
        return parts.joined(separator: ", ")
    }
}

/// The crossing outcome a person has chosen, remembered for the crossing it was chosen for.
///
/// The panel used to keep a bare `@State` outcome that nothing reset, so the next crossing
/// opened with the previous answer selected and Continue live — one click applied an outcome
/// nobody chose for it (BH-048).
struct ScaleRegionCrossingChoice: Equatable {
    private(set) var crossingID: UUID?
    private(set) var resolution: ScaleRegionCrossingResolution?

    /// The chosen outcome for `crossing`, or `nil` when none was chosen for this one.
    func resolution(for crossing: ScaleRegionCrossing) -> ScaleRegionCrossingResolution? {
        guard crossingID == crossing.id, let resolution,
              crossing.offeredResolutions.contains(resolution)
        else { return nil }
        return resolution
    }

    mutating func choose(_ resolution: ScaleRegionCrossingResolution?, for crossing: ScaleRegionCrossing) {
        crossingID = crossing.id
        self.resolution = resolution
    }
}

/// The three legal outcomes for a markup that crosses two Scale Regions.
///
/// Nothing is preselected. The estimator has to say which one they want, because the app
/// choosing for them is exactly the silent wrong scale the spec forbids.
public struct ScaleRegionCrossingResolver: View {

    private let crossing: ScaleRegionCrossing
    @Binding private var chosen: ScaleRegionCrossingResolution?
    private let onResolve: (ScaleRegionCrossingResolution) -> Void

    @FocusState private var isConfirmFocused: Bool

    public init(
        crossing: ScaleRegionCrossing,
        chosen: Binding<ScaleRegionCrossingResolution?>,
        onResolve: @escaping (ScaleRegionCrossingResolution) -> Void = { _ in }
    ) {
        self.crossing = crossing
        self._chosen = chosen
        self.onResolve = onResolve
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            ZPDFInlineWarning(severity: .warning, message: crossing.headline)

            VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
                ForEach(crossing.offeredResolutions) { resolution in
                    optionRow(resolution)
                }
            }

            HStack(spacing: ZPDFSpacing.m) {
                Spacer(minLength: 0)
                Button {
                    guard let chosen else { return }
                    onResolve(chosen)
                } label: {
                    Text(NSLocalizedString("Continue", comment: "Button: apply the chosen crossing outcome"))
                        .zpdfFont(.control.withWeight(.semibold))
                        .padding(.horizontal, ZPDFSpacing.l)
                        .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(chosen == nil ? ZPDFColor.textSecondary : ZPDFColor.textPrimary)
                .zpdfControlBackground(fill: chosen == nil ? .elevated : .selection, cornerRadius: ZPDFRadius.small)
                .focused($isConfirmFocused)
                .zpdfFocusRing(isConfirmFocused, cornerRadius: ZPDFRadius.small)
                .disabled(chosen == nil)
                .accessibilityLabel(NSLocalizedString("Continue", comment: "Accessibility label"))
                .accessibilityValue(
                    Text(
                        chosen.map { crossing.title(for: $0) }
                            ?? NSLocalizedString(
                                "Choose an outcome first",
                                comment: "Accessibility value when no crossing outcome is chosen"
                            )
                    )
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                NSLocalizedString(
                    "Scale Region crossing",
                    comment: "Accessibility label for the crossing resolver"
                )
            )
        )
    }

    private func optionRow(_ resolution: ScaleRegionCrossingResolution) -> some View {
        let isChosen = chosen == resolution
        return Button {
            chosen = resolution
        } label: {
            HStack(alignment: .top, spacing: ZPDFSpacing.m) {
                ZPDFGlyphView(
                    .symbol(isChosen ? .success : .disclosureClosed),
                    size: ZPDFSpacing.Control.iconSmall
                )
                .foregroundStyle(isChosen ? ZPDFColor.accentCyan : ZPDFColor.textSecondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(crossing.title(for: resolution))
                        .zpdfFont(isChosen ? .control.withWeight(.semibold) : .control)
                        .foregroundStyle(
                            resolution == .block ? ZPDFColor.danger : ZPDFColor.textPrimary
                        )
                        .multilineTextAlignment(.leading)
                    Text(crossing.explanation(for: resolution))
                        .zpdfText(.caption, .textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(ZPDFSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zpdfControlBackground(
                fill: isChosen ? .elevated : .surface,
                stroke: isChosen ? .accentCyan : .border,
                cornerRadius: ZPDFRadius.small
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(crossing.title(for: resolution)))
        .accessibilityHint(Text(crossing.explanation(for: resolution)))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}
