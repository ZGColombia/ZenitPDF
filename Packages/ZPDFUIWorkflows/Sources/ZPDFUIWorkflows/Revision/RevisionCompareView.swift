import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Which sheet a canvas in Revision Compare is drawing.
public enum RevisionCanvasRole: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// The revision everything is measured against.
    case baseline
    /// The revision being checked.
    case comparison
    /// The computed picture of what is not the same.
    case difference

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the pane header.
    public var displayName: String {
        switch self {
        case .baseline: return NSLocalizedString("Baseline", comment: "Revision Compare pane role")
        case .comparison: return NSLocalizedString("Compared", comment: "Revision Compare pane role")
        case .difference: return NSLocalizedString("Differences", comment: "Revision Compare pane role")
        }
    }
}

/// Revision Compare: two sheets, what changed between them, and a review the person controls.
///
/// The view never asserts that a difference is a change to the works. It reports candidates,
/// counts them, and lets a person accept the ones that are real. That distinction is the whole
/// reason the feature can be trusted at all, so it is stated on screen rather than assumed.
public struct RevisionCompareView<Presenter: ComparePresenting, Canvas: View>: View {

    private let presenter: Presenter
    private let model: RevisionCompareModel
    private let onClose: () -> Void
    private let projectArea: (Double) -> String?
    private let canvas: (RevisionCanvasRole) -> Canvas

    /// - Parameters:
    ///   - presenter: the compare presenter.
    ///   - model: display mode, tolerance and review position.
    ///   - onClose: leaves Revision Compare. Required — this view must never be on screen
    ///     without a way out.
    ///   - projectArea: converts a difference area in square PDF points into a formatted
    ///     project-unit area (m², ft²) when the page is calibrated, or returns `nil` when it is
    ///     not. Square points stay as the fallback and the secondary reading (IM-230).
    ///   - canvas: draws one role's canvas.
    public init(
        presenter: Presenter,
        model: RevisionCompareModel,
        onClose: @escaping () -> Void,
        projectArea: @escaping (Double) -> String? = { _ in nil },
        @ViewBuilder canvas: @escaping (RevisionCanvasRole) -> Canvas
    ) {
        self.presenter = presenter
        self.model = model
        self.onClose = onClose
        self.projectArea = projectArea
        self.canvas = canvas
    }

    public var body: some View {
        // Filtered and sorted once per body, then handed down: the header, the legend, the
        // position readout and the list used to each re-filter and re-sort the whole
        // candidate list on their own (IM-229).
        let visible = model.visibleDiffs(from: presenter.diffs)
        VStack(spacing: 0) {
            header
            revisionBar
            ZPDFHairlineDivider()
            if hasBothRevisions {
                // The tolerance is an input, not a verdict, so it lives above the run-gated
                // branches. Inside `if let run` it was unmounted the moment a drag withdrew
                // the run, taking the slider out from under the cursor. Finding BH-055.
                settingsBar
                ZPDFHairlineDivider()
            }
            if let run = activeRun {
                reviewBar(run: run, visible: visible)
                ZPDFHairlineDivider()
                canvasArea
                ZPDFHairlineDivider()
                differenceList(run: run, visible: visible)
            } else if hasBothRevisions {
                awaitingRunCanvases
                ZPDFHairlineDivider()
                awaitingRunNote
            } else {
                selectionPrompt
            }
        }
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Revision Compare", comment: "Accessibility label for Revision Compare")))
    }

    // MARK: - State

    /// Whether a baseline and a comparison are both chosen. Until they are, the view asks for
    /// them and asserts nothing.
    private var hasBothRevisions: Bool {
        presenter.baselineRevisionID != nil && presenter.comparisonRevisionID != nil
    }

    /// The run whose result may honestly be shown, or `nil`. Every verdict-bearing section of
    /// this view takes the unwrapped run as a parameter, so none of them can exist without it.
    private var activeRun: RevisionCompareRun? {
        model.currentRun(
            baseline: presenter.baselineRevisionID,
            comparison: presenter.comparisonRevisionID
        )
    }

    // MARK: - Header

    private var header: some View {
        ZPDFPanelHeader(title: NSLocalizedString("Revision Compare", comment: "Revision Compare header title")) {
            WorkflowPanelCloseButton(
                panelName: NSLocalizedString("Revision Compare", comment: "Panel name"),
                action: onClose
            )
        }
    }

    // MARK: - Revision bar

    private var revisionBar: some View {
        HStack(spacing: ZPDFSpacing.s) {
            revisionPicker(
                title: RevisionCanvasRole.baseline.displayName,
                selection: Binding(
                    get: { presenter.baselineRevisionID },
                    set: {
                        if let id = $0 {
                            model.invalidateRun()
                            presenter.setBaseline(id: id)
                        }
                    }
                )
            )
            ZPDFToolbarButton(
                glyph: .symbol(.redo),
                title: NSLocalizedString("Swap Revisions", comment: "Swap baseline and comparison"),
                action: {
                    model.invalidateRun()
                    presenter.swapRevisions()
                }
            )
            revisionPicker(
                title: RevisionCanvasRole.comparison.displayName,
                selection: Binding(
                    get: { presenter.comparisonRevisionID },
                    set: {
                        if let id = $0 {
                            model.invalidateRun()
                            presenter.setComparison(id: id)
                        }
                    }
                )
            )
            Spacer(minLength: ZPDFSpacing.m)
            if activeRun != nil {
                alignmentPill
            }
            // L-57: a revision can be added from the sheet itself, whatever is chosen.
            if let addRevision = model.onAddRevision {
                Button(NSLocalizedString("Add Revision…", comment: "Revision Compare: choose a revised PDF to add as a revision")) {
                    addRevision()
                }
                .controlSize(.small)
                .help(NSLocalizedString(
                    "Choose the revised PDF of this drawing and add it as a revision.",
                    comment: "Revision Compare Add Revision button help"
                ))
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(height: ZPDFSpacing.Control.toolbarHeight)
    }

    private func revisionPicker(title: String, selection: Binding<RevisionSummary.ID?>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .zpdfText(.caption, .textSecondary)
                .textCase(.uppercase)
            Picker(selection: selection) {
                Text(NSLocalizedString("Choose…", comment: "Empty revision picker entry")).tag(RevisionSummary.ID?.none)
                ForEach(presenter.revisions) { revision in
                    Text("\(revision.name) · \(revision.revisionLabel)")
                        .tag(RevisionSummary.ID?.some(revision.id))
                }
            } label: {
                Text(title)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .zpdfFont(.control)
            .frame(maxWidth: 220)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private var alignmentPill: some View {
        ZPDFStatusPill(
            severity: presenter.alignmentState.isAligned ? .success : .warning,
            title: NSLocalizedString("Alignment", comment: "Revision Compare alignment status"),
            value: presenter.alignmentState.displayName,
            usesMonospacedValue: false
        )
        .help(RevisionAlignmentDisclosure.approximate)
        .accessibilityHint(Text(RevisionAlignmentDisclosure.approximate))
    }

    // MARK: - Empty and waiting states

    /// Shown while fewer than two revisions are chosen. No counts, no tolerance verdict, no
    /// claim of any kind — the view has examined nothing and says so. With fewer than two
    /// revisions it offers Add Revision… (L-93).
    private var selectionPrompt: some View {
        let state = RevisionCompareModel.emptyState(
            revisionCount: presenter.revisions.count,
            canAddRevision: model.onAddRevision != nil
        )
        let addRevision = model.onAddRevision
        return ZPDFEmptyState(
            glyph: .symbol(.revisionCompare),
            title: state.title,
            message: state.message,
            actionTitle: state.actionTitle,
            action: addRevision.map { hook in { hook() } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Both revisions are chosen but no comparison result exists yet. The sheets are shown as
    /// drawn; nothing is said about differences.
    private var awaitingRunCanvases: some View {
        HStack(spacing: 1) {
            rolePane(.baseline)
            rolePane(.comparison)
        }
        .background(ZPDFColor.border)
    }

    private var awaitingRunNote: some View {
        Text(NSLocalizedString(
            "No comparison result yet.",
            comment: "Revision Compare note while a result is pending"
        ))
        .zpdfText(.caption, .textSecondary)
        .padding(.horizontal, ZPDFSpacing.m)
        .padding(.vertical, ZPDFSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Review bar

    private func reviewBar(run: RevisionCompareRun, visible: [CompareDiffSummary]) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack(spacing: ZPDFSpacing.m) {
                ZPDFSegmentedControl(
                    selection: Binding(
                        get: { model.displayMode },
                        set: { model.displayMode = $0 }
                    ),
                    segments: RevisionCompareDisplayMode.allCases.map {
                        .init(
                            value: $0,
                            title: $0.displayName,
                            glyph: .symbol($0 == .sideBySide ? .splitCanvas : .revisionCompare),
                            helpText: $0.explanation
                        )
                    },
                    accessibilityTitle: NSLocalizedString("Compare view", comment: "Accessibility title for the compare display mode switch")
                )
                .fixedSize()

                CompareLegend(
                    counts: model.counts(from: presenter.diffs),
                    visibleKinds: Binding(
                        get: { model.visibleChangeKinds },
                        set: { requested in
                            for kind in CompareChangeKind.allCases {
                                model.setChangeKind(kind, visible: requested.contains(kind))
                            }
                        }
                    ),
                    canHide: { model.canHideChangeKind($0) }
                )
                Spacer(minLength: ZPDFSpacing.s)
                jumpControls(visible: visible)
            }

            Text(model.countSummary(for: run, diffs: presenter.diffs)).zpdfText(.caption, .textSecondary)
            // S-102: a sheet compared below the requested resolution says so beside its result.
            if let note = presenter.resultNote {
                HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.xs) {
                    ZPDFGlyphView(.symbol(.warning), size: ZPDFSpacing.Control.iconSmall)
                        .accessibilityHidden(true)
                    Text(note)
                        .zpdfText(.caption, .textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Text(RevisionAlignmentDisclosure.differencesAreCandidates)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .padding(.vertical, ZPDFSpacing.s)
    }

    /// The tolerance row. Shown whenever two revisions are chosen, with or without a run.
    private var settingsBar: some View {
        toleranceSlider
            .padding(.horizontal, ZPDFSpacing.m)
            .padding(.vertical, ZPDFSpacing.s)
    }

    private var toleranceSlider: some View {
        let shown = model.displayedTolerance
        let percent = "\(Int((shown * 100).rounded()))%"
        var explanation = model.settings
        explanation.tolerance = shown
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ZPDFSpacing.s) {
                Text(NSLocalizedString("Tolerance", comment: "Revision Compare tolerance slider label"))
                    .zpdfText(.caption, .textSecondary)
                // The slider parks intermediate values in the model's draft while the drag is
                // in progress and commits once on release; the core re-detects once per
                // adjustment instead of once per tick (IM-032).
                Slider(
                    value: Binding(
                        get: { model.displayedTolerance },
                        set: { model.previewTolerance($0) }
                    ),
                    in: 0...1,
                    onEditingChanged: { model.setAdjustingTolerance($0) }
                )
                .frame(width: 180)
                .accessibilityLabel(Text(NSLocalizedString(
                    "Difference tolerance",
                    comment: "Accessibility label for the compare tolerance slider"
                )))
                .accessibilityValue(Text(percent))
                Text(percent)
                    .zpdfText(.monoNumeric, .textSecondary)
            }
            Text(explanation.toleranceExplanation)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func jumpControls(visible: [CompareDiffSummary]) -> some View {
        let focused = model.focusedDiff(in: presenter.diffs)
        return HStack(spacing: ZPDFSpacing.xs) {
            if let position = model.focusedPosition(in: presenter.diffs) {
                Text(String(
                    format: NSLocalizedString(
                        "%1$d of %2$d",
                        comment: "Revision Compare review position: current, total"
                    ),
                    position,
                    visible.count
                ))
                .zpdfText(.monoNumeric, .textSecondary)
            }
            ZPDFToolbarButton(
                glyph: .symbol(.disclosureClosed),
                title: NSLocalizedString("Previous Difference", comment: "Go to the previous difference"),
                keyboardHint: "⌥←",
                action: { model.focusPreviousDifference(in: presenter.diffs) }
            )
            // The hint used to advertise ⇧⌥→ with nothing bound to it. Finding BH-839.
            .keyboardShortcut(.leftArrow, modifiers: [.option])
            ZPDFToolbarButton(
                glyph: .symbol(.disclosureOpen),
                title: NSLocalizedString("Next Difference", comment: "Go to the next difference"),
                keyboardHint: "⌥→",
                action: { model.focusNextDifference(in: presenter.diffs) }
            )
            .keyboardShortcut(.rightArrow, modifiers: [.option])
            // One key per difference: decide the focused one and move on (IM-033).
            Button(NSLocalizedString("Accept", comment: "Accept the focused difference")) {
                model.reviewFocusedDifference(in: presenter.diffs) { presenter.acceptDiff(id: $0) }
            }
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(focused == nil || focused?.isAccepted == true)
            .help(NSLocalizedString(
                "Accept the focused difference and move to the next one (⌘↩)",
                comment: "Help tag for the accept-focused-difference button"
            ))
            .accessibilityLabel(Text(NSLocalizedString(
                "Accept Focused Difference",
                comment: "Accessibility label for the accept-focused-difference button"
            )))
            .accessibilityHint(Text(NSLocalizedString(
                "Command Return", comment: "Spoken shortcut for accepting the focused difference"
            )))
            Button(NSLocalizedString("Dismiss", comment: "Dismiss the focused difference")) {
                model.reviewFocusedDifference(in: presenter.diffs) { presenter.rejectDiff(id: $0) }
            }
            .controlSize(.small)
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(focused == nil || focused?.isAccepted == true)
            .help(NSLocalizedString(
                "Dismiss the focused difference and move to the next one (⌘⌫)",
                comment: "Help tag for the dismiss-focused-difference button"
            ))
            .accessibilityLabel(Text(NSLocalizedString(
                "Dismiss Focused Difference",
                comment: "Accessibility label for the dismiss-focused-difference button"
            )))
            .accessibilityHint(Text(NSLocalizedString(
                "Command Delete", comment: "Spoken shortcut for dismissing the focused difference"
            )))
        }
    }

    // MARK: - Canvases

    @ViewBuilder
    private var canvasArea: some View {
        switch model.displayMode {
        case .sideBySide:
            HStack(spacing: 1) {
                rolePane(.baseline)
                rolePane(.comparison)
            }
            .background(ZPDFColor.border)
        case .difference:
            rolePane(.difference)
        }
    }

    private func rolePane(_ role: RevisionCanvasRole) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: ZPDFSpacing.xs) {
                Text(role.displayName).zpdfText(.caption, .textSecondary).textCase(.uppercase)
                if let name = revisionName(for: role) {
                    Text(name).zpdfText(.caption, .textPrimary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZPDFSpacing.s)
            .frame(height: ZPDFSpacing.Control.statusBar)
            .background(ZPDFColor.surface)
            canvas(role)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ZPDFColor.canvasBackdrop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(paneAccessibilityLabel(role)))
    }

    private func revisionName(for role: RevisionCanvasRole) -> String? {
        switch role {
        case .baseline: return presenter.baselineRevision.map { "\($0.name) · \($0.revisionLabel)" }
        case .comparison: return presenter.comparisonRevision.map { "\($0.name) · \($0.revisionLabel)" }
        case .difference: return nil
        }
    }

    private func paneAccessibilityLabel(_ role: RevisionCanvasRole) -> String {
        guard let name = revisionName(for: role) else { return role.displayName }
        return "\(role.displayName), \(name)"
    }

    // MARK: - Difference list

    /// The review list. Requires the run: the "Nothing came back different" verdict below is
    /// only constructible when a comparison actually produced it.
    private func differenceList(run: RevisionCompareRun, visible: [CompareDiffSummary]) -> some View {
        let pendingVisible = model.pendingVisibleDiffIDs(in: presenter.diffs)
        let isFiltered = visible.count != presenter.diffs.count
        return VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Differences", comment: "Difference review list heading"),
                count: visible.count
            ) {
                // Accepts what the list shows. Under a change filter it used to accept the
                // hidden differences too, and each became a markup. Finding BH-309.
                Button(isFiltered
                    ? NSLocalizedString("Accept All Shown", comment: "Accept every difference the filter shows")
                    : NSLocalizedString("Accept All", comment: "Accept every detected difference")
                ) {
                    for id in pendingVisible {
                        presenter.acceptDiff(id: id)
                    }
                }
                .disabled(pendingVisible.isEmpty)
                .help(isFiltered
                    ? NSLocalizedString(
                        "Accepts only the differences shown by the change filter.",
                        comment: "Help tag for Accept All Shown"
                    )
                    : NSLocalizedString(
                        "Accepts every difference that is still pending.",
                        comment: "Help tag for Accept All"
                    ))
            }
            .padding(.horizontal, ZPDFSpacing.m)

            if presenter.diffs.isEmpty {
                ZPDFEmptyState(
                    glyph: .symbol(.revisionCompare),
                    title: NSLocalizedString("Nothing came back different", comment: "Difference list empty state"),
                    message: NSLocalizedString(
                        "Either the sheets really are the same, or the tolerance is set higher than the change. Try lowering it.",
                        comment: "Difference list empty state message"
                    )
                )
                .frame(height: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visible) { diff in
                            differenceRow(diff)
                        }
                    }
                    .padding(.horizontal, ZPDFSpacing.m)
                }
                .frame(height: 160)
            }
        }
    }

    /// The difference area: in project units when the host can convert (a calibrated page),
    /// with square points as the secondary reading; square points alone otherwise (IM-230).
    @ViewBuilder
    private func areaText(for diff: CompareDiffSummary) -> some View {
        let points = String(
            format: NSLocalizedString("%.0f pt²", comment: "Difference area in square PDF points"),
            diff.areaInSquarePoints
        )
        if let converted = projectArea(diff.areaInSquarePoints) {
            Text(converted)
                .zpdfText(.monoNumeric, .textSecondary)
                .help(points)
                .accessibilityLabel(Text(converted))
        } else {
            Text(points).zpdfText(.monoNumeric, .textSecondary)
        }
    }

    private func differenceRow(_ diff: CompareDiffSummary) -> some View {
        let isFocused = diff.id == model.focusedDiffID
        return HStack(spacing: ZPDFSpacing.s) {
            CompareChangeShape(diff.changeKind)
                .fill(diff.changeKind.indicatorColor.swiftUIColor.opacity(0.3))
                .overlay {
                    CompareChangeShape(diff.changeKind)
                        .stroke(diff.changeKind.indicatorColor.swiftUIColor, lineWidth: ZPDFStroke.measurement)
                }
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(diff.changeKind.displayName).zpdfText(.control, .textPrimary).frame(width: 84, alignment: .leading)
            Text(diff.pageLabel).zpdfText(.monoNumeric, .textSecondary).frame(width: 64, alignment: .leading)
            areaText(for: diff)
            Spacer(minLength: ZPDFSpacing.s)
            if diff.isAccepted {
                ZPDFStatusPill(
                    severity: .success,
                    title: NSLocalizedString("Accepted", comment: "Difference has been accepted"),
                    usesMonospacedValue: false
                )
            } else {
                Button(NSLocalizedString("Accept", comment: "Accept one difference")) {
                    presenter.acceptDiff(id: diff.id)
                }
                .controlSize(.small)
                Button(NSLocalizedString("Dismiss", comment: "Reject one difference")) {
                    presenter.rejectDiff(id: diff.id)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .frame(height: ZPDFSpacing.Control.listRow)
        .background {
            RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                .fill(isFocused ? ZPDFColor.selection : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.focusDifference(id: diff.id, in: presenter.diffs) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(diff.accessibilityLabel))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}
