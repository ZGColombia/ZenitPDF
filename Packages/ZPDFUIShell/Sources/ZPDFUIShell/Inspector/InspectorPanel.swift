import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// One Inspector line in the 2026-09-23 mockup's grammar: the label in the quiet left column,
/// the control beside it. Used by the Properties tab's sections; the mixed-value rule is
/// `ZPDFInspectorRow`'s, so both tabs agree about when a control gives way to "Mixed".
struct InspectorMockupRow<Content: View>: View {

    let label: String
    var isMixed: Bool = false
    /// The control renders the mixed state itself and must stay editable (BH-053, BH-288).
    var controlHandlesMixed: Bool = false
    @ViewBuilder let content: () -> Content

    init(
        label: String,
        isMixed: Bool = false,
        controlHandlesMixed: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.isMixed = isMixed
        self.controlHandlesMixed = controlHandlesMixed
        self.content = content
    }

    var body: some View {
        InspectorInlineRow(label: label, labelWidth: InspectorMetrics.propertiesLabelColumn) {
            if ZPDFInspectorRow<EmptyView>.showsMixedPlaceholder(
                isMixed: isMixed, showsContentWhenMixed: controlHandlesMixed
            ) {
                ZPDFMixedValueIndicator()
            } else {
                content()
            }
        }
        .accessibilityValue(
            isMixed
                ? Text(NSLocalizedString("Mixed value", comment: "Accessibility label for a mixed multi-selection value"))
                : Text(verbatim: "")
        )
    }
}

/// The Inspector: every property of the current selection, laid out as the 2026-09-23
/// main-window mockup draws it — a title band, the Markup / Properties / Comments tabs, a header
/// card naming the selection, and the form beneath.
///
/// With several markups selected each row shows either the value they all share or an explicit
/// mixed marker. Nothing is silently normalised to the first object's value.
public struct InspectorPanel: View {

    let environment: ProjectShellEnvironment
    @Bindable private var panelState: ShellPanelState
    /// The page on screen, held by the panel state (L-90).
    private var tab: InspectorTab {
        get { panelState.inspectorTab }
        nonmutating set { panelState.inspectorTab = newValue }
    }
    /// Raised by the Comments tab's "Write a Note"; the Notes field takes focus and lowers it.
    @State private var wantsNotesFocus = false
    var notesFocusRequest: Binding<Bool> { $wantsNotesFocus }

    /// Creates the Inspector.
    public init(environment: ProjectShellEnvironment, panelState: ShellPanelState) {
        self.init(environment: environment, panelState: panelState, initialTab: .initial)
    }

    /// Creates the Inspector open on a given tab — for previews and off-screen renders, which
    /// hand it a panel state of their own.
    init(environment: ProjectShellEnvironment, panelState: ShellPanelState, initialTab: InspectorTab) {
        self.environment = environment
        self._panelState = Bindable(panelState)
        if initialTab != .initial { panelState.inspectorTab = initialTab }
    }

    /// The whole selection, resolved from every markup — not only the ones visible on the
    /// current page. A selection made from the ledger on another sheet, or on a layer hidden
    /// since, used to read "Nothing selected" while Delete still removed it (BH-279, IM-024).
    private var selection: InspectorSelectionSummary {
        InspectorSelectionSummary(markups: environment.canvas.resolvedSelectedMarkups)
    }

    public var body: some View {
        let summary = selection
        return VStack(spacing: 0) {
            InspectorTitleBand(
                closeKeyboardHint: environment.commands.command(.toggleInspector)?.binding?.displayString
            ) {
                environment.perform(.toggleInspector)
            }
            InspectorTabStrip(selection: $panelState.inspectorTab)
                .padding(.horizontal, InspectorMetrics.gutter)
            if tab == .tools {
                // NL-UX-06: the Tool Library docked on its own tab, whatever is selected.
                toolsDock
            } else if summary.isEmpty, let kind = Self.styleableTool(environment.toolbar.activeSelection) {
                // Nothing selected and a markup tool armed: the Inspector edits the style the
                // tool will draw with (the "chosen" half of the tool-style fix).
                ScrollView {
                    toolStyleCard(kind: kind)
                        .padding(.horizontal, InspectorMetrics.gutter)
                        .padding(.bottom, InspectorMetrics.gutter)
                }
            } else if summary.isEmpty {
                let empty = Self.emptyState(for: tab)
                ZPDFEmptyState(glyph: .symbol(empty.symbol), title: empty.title, message: empty.message)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: InspectorMetrics.gutter) {
                        if let header = InspectorHeaderModel(summary: summary) {
                            InspectorHeaderCard(model: header) { headerMenu(summary) }
                        }
                        tabContent(summary)
                    }
                    .padding(.horizontal, InspectorMetrics.gutter)
                    .padding(.bottom, InspectorMetrics.gutter)
                }
                // A soft fade at the bottom edge says the form continues below the fold
                // (d9: "Modified" sat on the edge with nothing signalling more).
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [
                            ZPDFColor.color(InspectorChrome.panel, opacity: 0),
                            ZPDFColor.color(InspectorChrome.panel)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: InspectorMetrics.gutter * 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .background(ZPDFColor.color(InspectorChrome.panel))
        // The standard escape path: Escape on the panel hides it, same as its close control.
        .onExitCommand { environment.perform(.toggleInspector) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Inspector",
            comment: "Accessibility label for the inspector panel"
        )))
        .accessibilityValue(Text(summary.headerLine ?? NSLocalizedString(
            "Nothing selected", comment: "Inspector empty state title"
        )))
    }

    /// What a tab says with nothing selected — each tab its own words, so the tab a click
    /// opened is the tab on screen (L-90: "with nothing selected Properties and Comments look the
    /// same"; all three read "Nothing selected" over the same message).
    static func emptyState(for tab: InspectorTab) -> (symbol: ZPDFSymbol, title: String, message: String) {
        switch tab {
        case .markup, .tools:
            return (
                .inspector,
                NSLocalizedString("Nothing selected", comment: "Inspector empty state title"),
                NSLocalizedString(
                    "Select a markup on the page to edit its properties.",
                    comment: "Inspector empty state message"
                )
            )
        case .properties:
            return (
                .sliders,
                NSLocalizedString("No properties to show", comment: "Inspector Properties tab empty state title"),
                NSLocalizedString(
                    "Select a markup to see its scale, calculation, lock state, Project Zone and custom data.",
                    comment: "Inspector Properties tab empty state message"
                )
            )
        case .comments:
            return (
                .callout,
                NSLocalizedString("No comments to show", comment: "Inspector Comments tab empty state title"),
                NSLocalizedString(
                    "Select a markup to read the notes written on it, or to write one.",
                    comment: "Inspector Comments tab empty state message"
                )
            )
        }
    }

    @ViewBuilder
    private func tabContent(_ summary: InspectorSelectionSummary) -> some View {
        switch tab {
        case .markup:
            markupTab(summary)
        case .properties:
            VStack(spacing: 0) {
                // L-99: no "How This Number Was Calculated" for a selection with no number.
                ForEach(InspectorTab.propertiesSections(for: summary)) { section in
                    sectionView(section, summary: summary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous)
                    .strokeBorder(ZPDFColor.color(InspectorChrome.hairline), lineWidth: ZPDFStroke.regular)
            }
        case .comments:
            commentsTab(summary) {
                wantsNotesFocus = true
                tab = .markup
            }
        case .tools:
            EmptyView()
        }
    }

    /// The header card's ⋯ menu: the commands that act on the selection as a whole.
    @ViewBuilder
    private func headerMenu(_ summary: InspectorSelectionSummary) -> some View {
        // The View menu's own command, so a multi-selection is fitted as a whole.
        Button(NSLocalizedString("Zoom to Selection", comment: "Inspector action")) {
            environment.perform(.zoomToSelection)
        }
        .disabled(summary.isEmpty)
        .help(Self.zoomToSelectionHelp(summary, environment: environment))
        if let photos = environment.onAttachPhoto, let markup = summary.single {
            Button(NSLocalizedString("Attach Photograph…", comment: "Inspector action")) {
                photos(markup.id)
            }
        }
        if environment.inspectorEditing.onSetLocked != nil {
            Button(InspectorMarkupFormatting.lockTitle(summary)) { toggleLock(summary) }
                .disabled(summary.isEmpty)
        }
        if environment.inspectorEditing.onSetHidden != nil {
            Button(InspectorMarkupFormatting.hideTitle(summary)) { toggleVisibility(summary) }
                .disabled(!InspectorMarkupFormatting.canChangeVisibility(summary))
                .help(InspectorMarkupFormatting.canChangeVisibility(summary) ? "" : Self.lockedMarkupReason)
        }
        Divider()
        Button(role: .destructive) {
            environment.perform(.deleteSelection)
        } label: {
            Text(NSLocalizedString("Delete", comment: "Inspector action"))
        }
        .disabled(summary.isEmpty)
    }

    /// The ⋯ menu's Lock / Unlock over the whole selection.
    func toggleLock(_ summary: InspectorSelectionSummary) {
        guard !summary.isEmpty, let setLocked = environment.inspectorEditing.onSetLocked else { return }
        setLocked(Set(summary.markups.map(\.id)), InspectorMarkupFormatting.lockTarget(summary))
    }

    /// The ⋯ menu's Hide / Show over the whole selection; nothing when the engine would refuse.
    func toggleVisibility(_ summary: InspectorSelectionSummary) {
        guard InspectorMarkupFormatting.canChangeVisibility(summary),
              let setHidden = environment.inspectorEditing.onSetHidden else { return }
        setHidden(Set(summary.markups.map(\.id)), InspectorMarkupFormatting.hideTarget(summary))
    }

    @ViewBuilder
    private func sectionView(_ section: InspectorSection, summary: InspectorSelectionSummary) -> some View {
        let expanded = Binding(
            get: { panelState.isExpanded(section) },
            set: { panelState.setExpanded($0, section: section) }
        )
        VStack(spacing: 0) {
            ZPDFPanelHeader(title: section.displayName, isExpanded: expanded)
            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                    rows(for: section, summary: summary)
                }
                .padding(.vertical, ZPDFSpacing.s)
                .padding(.horizontal, ZPDFSpacing.m)
            }
        }
    }

    @ViewBuilder
    private func rows(for section: InspectorSection, summary: InspectorSelectionSummary) -> some View {
        switch section {
        // Appearance and Caption are the Markup tab's form (`markupTab`), not sections.
        case .appearance, .caption: EmptyView()
        case .measurement: measurementRows(summary)
        case .derivation: InspectorDerivationSection(
            summary: summary,
            audit: environment.ledger as? LedgerAuditPresenting
        )
        case .scale: scaleRows(summary)
        case .identity: identityRows(summary)
        case .status: statusRows(summary)
        case .layerZone: layerZoneRows(summary)
        case .customData: customDataRows(summary)
        case .actions: actionRows(summary)
        }
    }

    // MARK: - Sections

    /// Whether the selection can be restyled at all.
    ///
    /// A locked markup rejects style edits in the engine, so offering the control would be a
    /// promise the command bus breaks. With a mixed selection the rule is the strict one: if any
    /// of them is locked, the edit would only partly land, and a control that silently applies to
    /// nine of twelve is worse than one that is off.
    func canEditAppearance(_ summary: InspectorSelectionSummary) -> Bool {
        !summary.isEmpty
            && !summary.includesLockedMarkup
            && environment.ledger is any LedgerBulkEditPresenting
    }

    /// Whether a style edit to this selection becomes the markup tools' style: when it holds
    /// a markup Text, Callout or the Shapes draw. Recolouring a measured area is a statement
    /// about that area, not about the next callout.
    static func remembersToolStyle(for summary: InspectorSelectionSummary) -> Bool {
        summary.markups.contains { ZenitToolMode.isDrawable($0.kind) }
    }

    /// The markup kinds that draw text, and therefore have a text size worth showing.
    static func carriesText(_ kind: MarkupKind) -> Bool {
        kind == .text || kind == .callout || kind == .stamp
    }

    /// Applies one appearance change to the whole selection, as one undoable step.
    ///
    /// The change is also remembered as the markup tools' style when the selection holds a
    /// markup those tools draw, so the next text box, callout or shape looks like the one just
    /// styled rather than the default blue (the "last used" half of the tool-style fix).
    func applyStyle(_ edit: MarkupStyleEdit, to summary: InspectorSelectionSummary) {
        InspectorStyleEditing.apply(edit, to: summary, in: environment)
    }

    /// The measurement controls: Scale Region (popup), Subject (editable combo), Repeat and
    /// Precision (popup, display only). The measured values themselves are on the Markup tab,
    /// in both unit systems; the derivation section beneath this one says how each was reached.
    @ViewBuilder
    private func measurementRows(_ summary: InspectorSelectionSummary) -> some View {
        let model = InspectorMeasurementModel(environment: environment, selection: summary)
        if !model.hasAnyQuantities {
            Text(NSLocalizedString(
                "This selection produces no quantities.",
                comment: "Inspector measurement section with nothing to show"
            ))
            .zpdfText(.caption, .textSecondary)
        } else {
            InspectorMockupRow(label: NSLocalizedString("Scale Region", comment: "Inspector row label")) {
                ZPDFUnitPicker(
                    selection: Binding(
                        get: { model.currentScaleRegionChoiceID },
                        set: { model.selectScaleRegion(choiceID: $0) }
                    ),
                    options: model.scaleRegionChoices.map {
                        ZPDFUnitOption(id: $0.id, name: $0.name, abbreviation: $0.name)
                    },
                    accessibilityTitle: NSLocalizedString(
                        "Scale Region",
                        comment: "Accessibility title of the inspector's Scale Region popup"
                    )
                )
                // W-039: the Inspector's one lock rule, as every other editor here follows it.
                .disabled(!model.canEdit)
                .help(model.disabledReason ?? model.scaleRegionNote ?? "")
            }
            InspectorMockupRow(
                label: NSLocalizedString("Subject", comment: "Inspector row label"),
                isMixed: summary.isMixed(\.subject),
                controlHandlesMixed: true
            ) {
                InspectorSubjectCombo(model: model)
                    // Fresh field state per selection, so a draft never leaks across markups.
                    .id(Set(summary.markups.map(\.id)))
                    .disabled(!model.canEdit)
                    .help(model.disabledReason ?? "")
            }
            repetitionRow(summary, model: model)
            InspectorMockupRow(label: NSLocalizedString("Precision", comment: "Inspector row label")) {
                ZPDFUnitPicker(
                    selection: Binding(
                        get: { model.currentPrecisionID },
                        set: { model.selectPrecision(choiceID: $0) }
                    ),
                    options: model.offeredPrecisions.map {
                        ZPDFUnitOption(id: $0.id, name: $0.displayName, abbreviation: $0.abbreviation)
                    },
                    accessibilityTitle: NSLocalizedString(
                        "Precision",
                        comment: "Accessibility title of the inspector's display precision popup"
                    )
                )
            }
        }
    }

    /// The repetition multiplier, when the selection carries one (feature 11).
    ///
    /// Invariant: a multiplier is never invisible. A measurement applied
    /// to six sheets contributes six times, and a total inflated six-fold with nothing on screen
    /// saying why is the failure. The Quantity Ledger's reserved `Repeat ×` column is where the
    /// number is edited and exported; this row is where a person who has one markup selected
    /// sees it without going to the ledger.
    ///
    /// Absent for a markup that repeats once, so an unrepeated selection reads exactly as it did
    /// before the feature existed. A mixed selection says so rather than showing the first
    /// markup's count as if it were everyone's.
    @ViewBuilder
    private func repetitionRow(_ summary: InspectorSelectionSummary, model: InspectorMeasurementModel) -> some View {
        // A single selection gets the EDITOR — a stepper on the row. The engine and the
        // `editCustomValue` command existed with no way to reach them: the ledger cell
        // ignored double-clicks and this row was read-only and only appeared once a count
        // was already above one, which no UI could ever make true (LT-7, 2026-08-29).
        if summary.markups.count == 1, let markup = summary.markups.first,
           let setRepeat = environment.onSetRepeatCount {
            InspectorMockupRow(
                label: NSLocalizedString("Repeat", comment: "Inspector row label: repetition multiplier"),
                isMixed: false
            ) {
                InspectorRepeatStepper(
                    count: InspectorSelectionSummary.repetitions(markup),
                    onSet: { await setRepeat(markup.id, $0) }
                )
                // A different markup starts from its own count, never another's pending one.
                .id(markup.id)
                // W-039: a locked markup's count cannot change; the engine refuses it.
                .disabled(!model.canEdit)
                .help(model.disabledReason ?? "")
            }
        } else if summary.markups.contains(where: { ($0.repeatCount ?? 1) > 1 }) {
            InspectorMockupRow(
                label: NSLocalizedString("Repeat", comment: "Inspector row label: repetition multiplier"),
                isMixed: summary.isMixed(\.repeatCount)
            ) {
                Text(summary.displayText(\.repeatCount) { count in
                    guard let count, count > 1 else {
                        return NSLocalizedString("Once", comment: "Repetition value: the measurement is not repeated")
                    }
                    let format = NSLocalizedString(
                        "×%d",
                        comment: "Repetition value: the multiplication sign and how many times a measurement repeats"
                    )
                    return String(format: format, count)
                })
                .zpdfText(.monoNumeric, .textPrimary)
                .accessibilityLabel(Text(NSLocalizedString(
                    "How many sheets this measurement repeats on",
                    comment: "Accessibility label of the inspector's repetition row"
                )))
                // IM-025: the label no longer replaces the "×3" it describes.
                .accessibilityValue(Text(summary.displayText(\.repeatCount) { count in
                    guard let count, count > 1 else {
                        return NSLocalizedString("Once", comment: "Repetition value: the measurement is not repeated")
                    }
                    return String(format: NSLocalizedString(
                        "×%d",
                        comment: "Repetition value: the multiplication sign and how many times a measurement repeats"
                    ), count)
                }))
                .accessibilityHint(Text(InspectorPanel.readOnlyValueHint))
            }
        }
    }

    /// The hint every read-only Inspector value carries.
    static let readOnlyValueHint = NSLocalizedString(
        "Read-only; calculated from the drawn geometry.",
        comment: "Accessibility hint: the measured value cannot be typed over"
    )

    /// IM-212: the Scale Region is edited in the Measurement section just above; repeating it
    /// here read-only was a second answer to the same question. This section keeps what only
    /// it shows, the scale in force — the selection's, Scale Regions included (U-043).
    @ViewBuilder
    private func scaleRows(_ summary: InspectorSelectionSummary) -> some View {
        let scale = InspectorMeasurementModel(environment: environment, selection: summary).scaleInForce
        InspectorMockupRow(label: NSLocalizedString("Active scale", comment: "Inspector row label"), isMixed: scale.isMixed) {
            Text(scale.text)
                .zpdfText(.monoNumeric, .textPrimary)
        }
    }

    /// Whether Label, Notes and Status can be written: a bulk-edit presenter is attached and
    /// nothing in the selection is locked (IM-118).
    func canEditText(_ summary: InspectorSelectionSummary) -> Bool {
        !summary.isEmpty
            && environment.ledger is any LedgerBulkEditPresenting
            && !summary.includesLockedMarkup
    }

    /// Sets the review status of the whole selection, as one undoable step.
    func applyStatus(_ status: MarkupStatus, to summary: InspectorSelectionSummary) {
        guard !summary.isEmpty, summary.common(\.status) != status,
              let editor = environment.ledger as? any LedgerBulkEditPresenting
        else { return }
        let request = LedgerBulkEditRequest(
            markupIDs: Set(summary.markups.map(\.id)),
            values: [.status: .choice(InspectorMarkupFormatting.storedStatusValue(status))]
        )
        let editing = environment.inspectorEditing
        Task { @MainActor in
            await InspectorStyleEditing.apply(request, with: editor, reportingTo: editing)
        }
    }

    /// Writes a label or note over the selection as one bulk edit (IM-118). A mixed selection
    /// opens empty with a "Multiple values" prompt, and committing it untouched writes nothing.
    func applyText(_ text: String, column: LedgerColumnID, to summary: InspectorSelectionSummary) {
        guard let editor = environment.ledger as? any LedgerBulkEditPresenting,
              let request = InspectorTextEditField.request(
                  text: text, current: summary.common(column == .label ? \.label : \.comment),
                  column: column, markupIDs: Set(summary.markups.map(\.id))
              )
        else { return }
        let editing = environment.inspectorEditing
        Task { @MainActor in
            await InspectorStyleEditing.apply(request, with: editor, reportingTo: editing)
        }
    }

    /// IM-212: each fact has one home. Subject is edited in the Measurement section; author and
    /// the timestamps are on the Markup tab; Identity keeps what only it shows.
    @ViewBuilder
    private func identityRows(_ summary: InspectorSelectionSummary) -> some View {
        InspectorMockupRow(
            label: NSLocalizedString("Page", comment: "Inspector row label"),
            isMixed: summary.isMixed(\.pageLabel)
        ) {
            Text(summary.displayText(\.pageLabel) { $0 }).zpdfText(.monoNumeric, .textPrimary)
        }
    }

    /// Lock and visibility, as switches (nl-ux: they were plain text that looked like values
    /// you could change). The review status is edited on the Markup tab.
    /// K-08: when the markup's layer is what hides or locks it, the row says so — "Hidden by
    /// layer Walls" — and the markup's own switch, which cannot lift a layer's flag, is off.
    @ViewBuilder
    private func statusRows(_ summary: InspectorSelectionSummary) -> some View {
        let locked = Self.lockedRowState(
            summary, isWired: environment.inspectorEditing.onSetLocked != nil, layerName: markupLayerName
        )
        let hidden = Self.hiddenRowState(
            summary, isWired: environment.inspectorEditing.onSetHidden != nil, layerName: markupLayerName
        )
        InspectorMockupRow(
            label: NSLocalizedString("Locked", comment: "Inspector row label"),
            isMixed: false
        ) {
            booleanControl(
                title: NSLocalizedString("Locked", comment: "Inspector row label"),
                value: summary.common(\.locked),
                isEnabled: locked.isEnabled,
                disabledReason: locked.disabledReason,
                note: locked.note
            ) { setLocked($0, for: summary) }
        }
        InspectorMockupRow(
            label: NSLocalizedString("Hidden", comment: "Inspector row label"),
            isMixed: false
        ) {
            booleanControl(
                title: NSLocalizedString("Hidden", comment: "Inspector row label"),
                value: summary.common(\.hidden),
                isEnabled: hidden.isEnabled,
                disabledReason: hidden.disabledReason,
                note: hidden.note
            ) { setHidden($0, for: summary) }
        }
    }

    /// Project Zone membership, as a popup (nl-ux). The layer is shown on the Markup tab.
    @ViewBuilder
    private func layerZoneRows(_ summary: InspectorSelectionSummary) -> some View {
        InspectorMockupRow(
            label: NSLocalizedString("Project Zone", comment: "Inspector row label"),
            isMixed: false
        ) {
            zoneControl(summary)
        }
    }

    @ViewBuilder
    private func customDataRows(_ summary: InspectorSelectionSummary) -> some View {
        let entries = Self.customDataEntries(ledger: environment.ledger, markupIDs: Set(summary.markups.map(\.id)))
        if entries.isEmpty {
            Text(NSLocalizedString(
                "No custom columns are defined for this project.",
                comment: "Inspector custom data section with no custom columns"
            ))
            .zpdfText(.caption, .textSecondary)
        } else {
            ForEach(entries) { entry in
                InspectorMockupRow(label: entry.column.title, isMixed: entry.isMixed) {
                    Text(entry.text)
                        .zpdfText(.control, .textPrimary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// One Custom Data row: the user column, whether the selection disagrees on it, and the text.
    struct CustomDataEntry: Identifiable {
        let column: LedgerColumn
        let isMixed: Bool
        let text: String
        var id: LedgerColumnID { column.id }
    }

    /// What the Custom Data section shows for a selection: one entry per user column, each read
    /// from the markups' stored values.
    ///
    /// NL-QTY-01: the one user-column rule — imported columns and shown estimating columns (Cost
    /// Code, Unit Cost …) too, not only `custom.` identifiers.
    ///
    /// W-042: the values are read whatever the ledger's filter, through
    /// ``LedgerPresenting/unfilteredRows(withIDs:)``. They were read through `rows(withIDs:)`,
    /// which answers only rows the filter passes, so a selected markup the filter dims on the
    /// canvas — still clickable — showed a dash for every value it has, and a selection where
    /// only some were filtered out read "Multiple values" over equal values.
    static func customDataEntries(ledger: any LedgerPresenting, markupIDs: Set<UUID>) -> [CustomDataEntry] {
        let columns = ledger.columns.filter { $0.holdsUserValues && ($0.isUserDefined || $0.visible) }
        guard !columns.isEmpty else { return [] }
        let rows = ledger.unfilteredRows(withIDs: markupIDs)
        return columns.map { column in
            let values = Set(rows.map { $0.displayValue(column.id) })
            // BH-806: a markup the ledger has no row for has no value, which disagrees with a
            // sibling that does.
            let mixed = customDataIsMixed(values: values, rowCount: rows.count, selectedCount: markupIDs.count)
            return CustomDataEntry(
                column: column,
                isMixed: mixed,
                text: mixed ? InspectorSelectionSummary.mixedPlaceholder : customDataText(values)
            )
        }
    }

    /// What one Custom Data row shows for the set of values its ledger rows carry.
    ///
    /// Three answers, not two. The old expression was
    /// `values.count == 1 ? values.first! : mixedPlaceholder`, so **no** rows — a selection the
    /// ledger has nothing for at all, which is every selection before a measurement is filed —
    /// produced an empty set, fell into the `else`, and the column read "Multiple values" for a
    /// selection that had no values whatsoever (CR-116). Nothing to show is an em dash, the
    /// same em dash the rest of the Inspector uses for "there is no value here".
    ///
    /// Static and value-only so the rule is testable without a view tree.
    static func customDataIsMixed(values: Set<String>, rowCount: Int, selectedCount: Int) -> Bool {
        if values.count > 1 { return true }
        // Some markups have a row and some do not: the ones without have no value at all.
        return rowCount > 0 && rowCount < selectedCount
    }

    static func customDataText(_ values: Set<String>) -> String {
        switch values.count {
        case 0: return InspectorAppearanceText.none
        case 1: return values.first ?? InspectorAppearanceText.none
        default: return InspectorSelectionSummary.mixedPlaceholder
        }
    }

    @ViewBuilder
    private func actionRows(_ summary: InspectorSelectionSummary) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            HStack(spacing: ZPDFSpacing.s) {
                ZPDFToolbarButton(
                    glyph: .symbol(.select),
                    title: NSLocalizedString("Zoom to Selection", comment: "Inspector action"),
                    showsTitle: true
                ) {
                    zoomToSelection(summary)
                }
                .disabled(summary.isEmpty)
                .help(Self.zoomToSelectionHelp(summary, environment: environment))

                ZPDFToolbarButton(
                    glyph: .symbol(.delete),
                    title: NSLocalizedString("Delete", comment: "Inspector action"),
                    showsTitle: true,
                    prominence: .destructive,
                    keyboardHint: environment.commands.command(.deleteSelection)?.binding?.displayString
                ) {
                    environment.perform(.deleteSelection)
                }
                .disabled(summary.isEmpty)
            }
            photoRows(summary)
        }
    }

    /// Feature 15 — site photographs, on the single selection. The rows appear only when
    /// the application wired a photo store (Project Mode); Quick PDF Mode has no package
    /// to keep photographs crash-safe in, so the affordance is honestly absent there.
    @ViewBuilder
    private func photoRows(_ summary: InspectorSelectionSummary) -> some View {
        // Registers the observation: a bump after attach/remove re-renders these rows.
        let _ = environment.photoTick.revision
        if let photos = environment.photoAttachments,
           summary.markups.count == 1, let markup = summary.markups.first {
            let rows = photos(markup.id)
            ForEach(rows) { row in
                HStack(spacing: ZPDFSpacing.s) {
                    ZPDFGlyphView(.symbol(.add), size: ZPDFSpacing.Control.iconSmall)
                        .foregroundStyle(ZPDFColor.textSecondary)
                    Text(row.label).zpdfText(.body, .textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        environment.onRemovePhoto?(markup.id, row.id)
                    } label: {
                        Text(NSLocalizedString("Remove", comment: "Inspector photo row action"))
                            .zpdfText(.caption, .textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String(
                        format: NSLocalizedString(
                            "Remove photograph %@",
                            comment: "Accessibility: remove one attached photograph"
                        ),
                        row.label
                    )))
                }
            }
            ZPDFToolbarButton(
                glyph: .symbol(.add),
                title: NSLocalizedString("Attach Photograph…", comment: "Inspector action"),
                showsTitle: true
            ) {
                environment.onAttachPhoto?(markup.id)
            }
            .disabled(environment.onAttachPhoto == nil)
        }
    }

}

/// The Subject row's editable combo: a text field that commits on Return or on
/// focus loss, plus a menu of the subjects already in use on the page. An edit lands on every
/// selected markup through `InspectorEditing.onEditSubject`, which is what updates the ledger
/// row live — the row renders from the same presenter data the edit mutates.
struct InspectorSubjectCombo: View {

    let model: InspectorMeasurementModel

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(model: InspectorMeasurementModel) {
        self.model = model
        self._draft = State(initialValue: model.subjectText)
    }

    var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            TextField(
                model.selection.isMixed(\.subject)
                    ? InspectorSelectionSummary.mixedPlaceholder
                    : NSLocalizedString("Subject", comment: "Placeholder of the inspector's subject field"),
                text: $draft
            )
            .textFieldStyle(.plain)
            .zpdfText(.control, .textPrimary)
            .focused($isFocused)
            .onSubmit { model.commitSubject(draft) }
            .onChange(of: isFocused) { _, focused in
                if !focused { model.commitSubject(draft) }
            }
            // THE DRAFT FOLLOWS THE SUBJECT WHILE NOBODY IS TYPING.
            //
            // It was seeded once, in `init`, so it survived for as long as SwiftUI kept this
            // view's identity — which is per selection, not per edit. Undo an "Outer Wall"
            // rename with ⌘Z and the field still read "Outer Wall"; the next click anywhere
            // else lost focus, `commitSubject` fired with that stale draft, and the edit the
            // person had just undone was silently re-applied (CR-109). Re-seeding while
            // unfocused is safe by construction: a person who is typing holds focus, so their
            // half-typed text is never overwritten underneath them.
            .onChange(of: model.subjectText) { _, subject in
                if let reseeded = Self.reseededDraft(subject: subject, isFocused: isFocused) {
                    draft = reseeded
                }
            }
            .accessibilityLabel(Text(NSLocalizedString(
                "Subject",
                comment: "Accessibility label of the inspector's subject field"
            )))

            let suggestions = model.subjectSuggestions
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { subject in
                        Button(subject) {
                            draft = subject
                            model.commitSubject(subject)
                        }
                    }
                } label: {
                    ZPDFGlyphView(.symbol(.disclosureOpen), size: ZPDFSpacing.Control.iconSmall)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text(NSLocalizedString(
                    "Existing subjects",
                    comment: "Accessibility label of the subject suggestion menu"
                )))
            }
        }
        .inspectorFieldBox(isFocused: isFocused)
    }

    /// What the field should hold after the selection's subject changed underneath it, or
    /// `nil` to leave the draft alone.
    ///
    /// Static and value-only so the rule is testable without a view tree — which is what the
    /// defect needed, the old rule being "seed in `init` and never again".
    static func reseededDraft(subject: String, isFocused: Bool) -> String? {
        isFocused ? nil : subject
    }
}

#if DEBUG
struct Inspector_Previews: PreviewProvider {
    static var previews: some View {
        InspectorPanel(environment: .mock(), panelState: ShellPanelState())
            .frame(width: 320, height: 640)
    }
}
#endif

/// The Repeat row's value and stepper (V-043).
///
/// The count comes from the snapshot, and the application's repeat edit is asynchronous: until
/// the refresh lands, the snapshot still holds the old count. The stepper used a plain value
/// binding over that count, so two quick clicks — or a held click's auto-repeat — each asked for
/// `count + 1` again, and every ask was one more undo step and audit row for the same value.
/// It now steps from the last count it asked for that is still in flight
/// (``InspectorStepsInFlight``), as ``InspectorNumberControl`` does (BH-802).
struct InspectorRepeatStepper: View {

    /// The markup's count as the snapshot has it.
    let count: Int
    /// Asks the application for a count; answers whether the edit landed.
    let onSet: @MainActor (Int) async -> Bool

    /// The counts the stepper asked for that the snapshot has not shown yet.
    @State private var inFlight = InspectorStepsInFlight<Int>()

    /// Once up to the store's own ceiling. X-021: the range stopped at 999 while the store
    /// holds up to ``MarkupSummary/maximumRepeatCount``, so either click on a markup stored at
    /// ×1500 clamped to 999 and rewrote it — a third of its quantity gone from every total.
    static let range: ClosedRange<Int> = 1...MarkupSummary.maximumRepeatCount

    /// The count one stepper click asks for, or `nil` at a bound. The base is the count asked for
    /// while the edit is still in flight. A click only ever moves the count the way it points:
    /// a base outside the range is never clamped into it by a click the other way.
    static func stepped(count: Int, pending: Int?, delta: Int, range: ClosedRange<Int> = Self.range) -> Int? {
        let current = pending ?? count
        let next = min(range.upperBound, max(range.lowerBound, current + delta))
        guard delta > 0 ? next > current : next < current else { return nil }
        return next
    }

    /// One click: the count it asks for (recorded as in flight), or `nil` at a bound. The view's
    /// click and the tests run this same rule.
    static func click(delta: Int, count: Int, inFlight: inout InspectorStepsInFlight<Int>) -> Int? {
        guard let next = stepped(count: count, pending: inFlight.last, delta: delta) else { return nil }
        inFlight.asked(next)
        return next
    }

    /// The application's answer to one ask. A refused ask never lands, so no refresh will ever
    /// carry it: the asks in flight are dropped and the stepper shows the snapshot's count again
    /// (W-039). It used to keep showing the refused count, and the next click stepped from it —
    /// a locked markup at ×1 read ×2 and asked for 3, refused again, one warning per click.
    static func answered(_ landed: Bool, inFlight: inout InspectorStepsInFlight<Int>) {
        guard !landed else { return }
        inFlight.refused()
    }

    var body: some View {
        let shown = inFlight.last ?? count
        HStack(spacing: ZPDFSpacing.xs) {
            Text(shown > 1
                ? String(format: NSLocalizedString(
                    "×%d",
                    comment: "Repetition value: the multiplication sign and how many times a measurement repeats"
                  ), shown)
                : NSLocalizedString("Once", comment: "Repetition value: the measurement is not repeated"))
                .zpdfText(.monoNumeric, .textPrimary)
            Stepper {
                EmptyView()
            } onIncrement: {
                step(by: 1)
            } onDecrement: {
                step(by: -1)
            }
            .labelsHidden()
            .accessibilityLabel(Text(NSLocalizedString(
                "How many sheets this measurement repeats on",
                comment: "Accessibility label of the inspector's repetition row"
            )))
            .accessibilityValue(Text(String(shown)))
        }
        // A refresh landed: the asks up to it are done, the later ones still in flight. A count
        // nobody asked for (an undo, another edit) drops them all.
        .onChange(of: count) { _, landed in inFlight.snapshotMoved(to: landed) }
    }

    private func step(by delta: Int) {
        guard let next = Self.click(delta: delta, count: count, inFlight: &inFlight) else { return }
        let ask = onSet
        Task { @MainActor in
            let landed = await ask(next)
            Self.answered(landed, inFlight: &inFlight)
        }
    }
}
