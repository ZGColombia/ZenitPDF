import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Tool Library: the sets on the left, their presets on the right.
///
/// The view binds to a ``ToolLibraryPresenting`` for the parts the core owns — which set is open,
/// which preset is armed, reuse-tool — and to a ``ToolLibraryEditingModel`` for the parts that
/// are edits to the library itself. Every action that changes the library has a keyboard path,
/// and the one destructive action leaves an Undo bar rather than a confirmation dialog.
public struct ToolLibraryPanelView<Presenter: ToolLibraryPresenting>: View {

    private let presenter: Presenter
    private let model: ToolLibraryEditingModel
    private let selectedMarkup: MarkupSummary?
    private let onClose: () -> Void

    @State private var searchText: String = ""
    @State private var isImportingFile = false
    @State private var isExportingFile = false
    @State private var exportDocument: ToolSetFileDocument?
    /// What an export left behind, said after the file is written (BH-319).
    @State private var exportNotice: String?
    @FocusState private var isSearchFocused: Bool

    /// - Parameters:
    ///   - presenter: the Tool Library presenter.
    ///   - model: the editing state that sits on top of it.
    ///   - selectedMarkup: the markup currently selected on the canvas, which enables
    ///     "Save Selection as Tool". Pass `nil` when nothing is selected.
    ///   - onClose: closes the panel. Required — every panel has a visible close control and
    ///     an `Escape` route.
    public init(
        presenter: Presenter,
        model: ToolLibraryEditingModel,
        selectedMarkup: MarkupSummary? = nil,
        onClose: @escaping () -> Void
    ) {
        self.presenter = presenter
        self.model = model
        self.selectedMarkup = selectedMarkup
        self.onClose = onClose
    }

    public var body: some View {
        // L-61, L-89 (live test 8): the sets sat beside the tools at any width. The floating
        // panel opens 380 pt wide and the Inspector's Tools tab is about 300 pt, while the
        // side-by-side layout needs ~450 pt — so the panel grew past the screen's right edge,
        // the set names were cut to "s", "ymbols", the header wrapped "MY / TOO / LS" and the
        // second tool column was cut off. Narrower than
        // ``ToolLibraryPanelLayout/stackedLayoutWidth`` the sets become a pop-up above the tools.
        GeometryReader { proxy in
            Group {
                if ToolLibraryPanelLayout.usesStackedLayout(width: proxy.size.width) {
                    VStack(spacing: 0) {
                        setPicker
                        presetArea(compact: true)
                    }
                } else {
                    HStack(spacing: 0) {
                        setSidebar
                        ZPDFHairlineDivider(axis: .vertical)
                        presetArea(compact: false)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(ZPDFColor.background)
        .sheet(item: draftBinding) { draft in
            ToolPresetEditorSheet(
                draft: draft,
                onSave: { updated in
                    model.draft = updated
                    model.commitDraft()
                },
                onCancel: { model.cancelDraft() },
                // Artwork import's missing half. The model carries the hook; the host
                // installs it, because the compiler is below the UI seam and the artwork store
                // belongs to the open project.
                importArtwork: model.onImportArtwork,
                // NL-QTY-07 (ADR-0035 §4): the Assembly row, when the presenter offers recipes.
                assemblies: (presenter as? any ToolPresetAssemblyProviding)?.presetAssemblyCatalog
            )
        }
        .sheet(item: importReviewBinding) { review in
            ToolSetImportReviewSheet(
                review: review,
                onImport: { model.confirmImport() },
                onCancel: { model.cancelImport() },
                canKeepPictures: model.canKeepImportedPictures,
                onImportWithStrategy: { model.confirmImport(strategy: $0) }
            )
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [ToolSetDocument.contentType],
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .fileExporter(
            isPresented: $isExportingFile,
            document: exportDocument,
            contentType: ToolSetDocument.contentType,
            defaultFilename: presenter.activePanel.displayName
        ) { result in
            exportDocument = nil
            guard case .success = result else { return }
            let leftBehind = model.presetsLeavingArtworkBehind(panel: presenter.activePanel)
            exportNotice = leftBehind.isEmpty ? nil : String(
                format: NSLocalizedString(
                    "Exported. The pictures of these tools are not in the file and will not travel with it: %@.",
                    comment: "Tool Library notice after an export whose stamp pictures could not be included. %@ is a list of tool names"
                ),
                AppLanguageList.joined(leftBehind)
            )
        }
    }

    // MARK: - Layout

    /// The stacked layout's set chooser: one full-width pop-up naming the set, its tool count
    /// and, when it is not Draw, its mode — the same three things a sidebar row shows.
    private var setPicker: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Tool Set", comment: "Tool Library: label of the set chooser in the narrow layout"))
                .zpdfText(.caption, .textSecondary)
                .lineLimit(1)
                .fixedSize()
            Picker(
                NSLocalizedString("Tool Set", comment: "Tool Library: label of the set chooser in the narrow layout"),
                selection: Binding(
                    get: { presenter.activePanel },
                    set: { presenter.selectPanel($0) }
                )
            ) {
                ForEach(presenter.panels) { panel in
                    Text(setPickerTitle(panel)).tag(panel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .padding(.vertical, ZPDFSpacing.s)
        .background(ZPDFColor.surface)
        .overlay(alignment: .bottom) { ZPDFHairlineDivider(axis: .horizontal) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Tool sets", comment: "Accessibility label for the Tool Library set list")))
    }

    /// "My Tools — 14", or "Project Tools — 6 · Apply" for a set in another mode.
    private func setPickerTitle(_ panel: ToolLibraryPanel) -> String {
        let count = model.presets(in: panel, recent: presenter.recentPresetIDs).count
        let base = String(
            format: NSLocalizedString(
                "%1$@ — %2$@",
                comment: "Tool Library narrow set chooser row: set name, tool count"
            ),
            panel.displayName,
            count.formatted()
        )
        let mode = presenter.mode(of: panel)
        guard mode != .default else { return base }
        return String(
            format: NSLocalizedString(
                "%1$@ · %2$@",
                comment: "Tool Library narrow set chooser row: the row, then the set's mode when it is not Draw"
            ),
            base,
            mode.displayName
        )
    }

    // MARK: - Sets sidebar

    private var setSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(title: NSLocalizedString("Tool Sets", comment: "Tool Library sidebar heading"))
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(presenter.panels) { panel in
                        setRow(panel)
                    }
                }
                .padding(.horizontal, ZPDFSpacing.xs)
            }
        }
        .frame(width: 168)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Tool sets", comment: "Accessibility label for the Tool Library set list")))
    }

    private func setRow(_ panel: ToolLibraryPanel) -> some View {
        let isActive = panel == presenter.activePanel
        let count = model.presets(in: panel, recent: presenter.recentPresetIDs).count
        return Button {
            presenter.selectPanel(panel)
        } label: {
            HStack(spacing: ZPDFSpacing.s) {
                ZPDFGlyphView(WorkflowGlyphs.glyph(for: panel), size: ZPDFSpacing.Control.icon)
                    .foregroundStyle(isActive ? ZPDFColor.accentCyan : ZPDFColor.textSecondary)
                Text(panel.displayName)
                    .zpdfText(isActive ? .body.withWeight(.semibold) : .body, .textPrimary)
                    .lineLimit(1)
                Spacer(minLength: ZPDFSpacing.xs)
                // The mode is shown on the set, not only on the open one: an estimator who left
                // `Project Tools` in Apply has to be able to see that from the sidebar, because
                // the next thing they click in it writes over whatever is selected.
                if presenter.mode(of: panel) != .default {
                    Text(presenter.mode(of: panel).displayName)
                        .zpdfText(.caption, .accentCyan)
                }
                Text(count.formatted())
                    .zpdfText(.monoNumeric, .textSecondary)
            }
            .padding(.horizontal, ZPDFSpacing.s)
            .frame(height: ZPDFSpacing.Control.listRow, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                    .fill(isActive ? ZPDFColor.elevated : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(panel.displayName))
        .accessibilityValue(Text(String(
            format: NSLocalizedString(
                "%1$@, %2$@ mode",
                comment: "Accessibility value for a set row: the tool count as '5 tools' and the set's mode"
            ),
            WorkflowPlurals.tools(count),
            presenter.mode(of: panel).displayName
        )))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Presets

    private func presetArea(compact: Bool) -> some View {
        // One filter-and-group pass per body, shared by the header count, the sections, the
        // number-key badges and the move commands (IM-156). The header used to run a second
        // filter-and-sort of its own (R-133) and each tile a whole-library sort for its badge
        // (R-120).
        let content = model.panelContent(in: presenter.activePanel, matching: searchText, recent: presenter.recentPresetIDs)
        return VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            presetHeader(count: content.visibleCount, compact: compact)
            modeSwitch
            armedBanner
            searchField
            if model.isReviewingImport {
                HStack(spacing: ZPDFSpacing.s) {
                    ProgressView().controlSize(.small)
                    Text(NSLocalizedString(
                        "Reading the tool set…",
                        comment: "Tool Library: shown while an imported tool set is being checked"
                    ))
                    .zpdfText(.caption, .textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            if content.groups.isEmpty {
                emptyState
            } else {
                presetScroll(content)
            }
            if let exportNotice {
                ZPDFInlineWarning(severity: .warning, message: exportNotice)
                    .padding(.horizontal, ZPDFSpacing.m)
                    .onTapGesture { self.exportNotice = nil }
            }
            if let deletion = model.pendingDeletion {
                ToolPresetUndoBar(
                    deletion: deletion,
                    onUndo: { model.undoDelete() },
                    onDismiss: { model.clearPendingDeletion() }
                )
                .padding(.horizontal, ZPDFSpacing.m)
            }
            reuseToolFooter
        }
        .padding(.vertical, ZPDFSpacing.s)
        .frame(minWidth: compact ? 0 : 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The tool area's header. Compact, the Grid/List switch moves into the ⋯ menu, so the
    /// set's name keeps the room it needs.
    private func presetHeader(count: Int, compact: Bool) -> some View {
        ZPDFPanelHeader(
            title: presenter.activePanel.displayName,
            subtitle: presenter.activePanel.isEditable
                ? nil
                : NSLocalizedString("Read-only set", comment: "Subtitle for a Tool Library set that cannot be edited"),
            count: count
        ) {
            HStack(spacing: ZPDFSpacing.xs) {
                if !compact {
                    layoutToggle
                }
                ZPDFToolbarButton(
                    glyph: .symbol(.add),
                    title: NSLocalizedString("New Tool", comment: "Create a new tool preset"),
                    action: { model.beginCreating(in: presenter.activePanel) }
                )
                .disabled(!presenter.activePanel.isEditable)
                libraryMenu(includesLayout: compact)
                WorkflowPanelCloseButton(
                    panelName: NSLocalizedString("Tool Library", comment: "Panel name"),
                    action: onClose
                )
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
    }

    /// The set's mode — Draw, Apply or Place.
    ///
    /// On the set, not on the preset, and directly under the set's own title, because the mode
    /// belongs to the set and applies to every tool in it. The line beneath is the mode's
    /// ``ToolSetMode/shortHelp``: three one-word segments cannot say what a click will do, and a
    /// mode switch whose meaning has to be discovered by clicking is a trap in a mode that
    /// writes over forty markups.
    private var modeSwitch: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ZPDFSegmentedControl(
                selection: Binding(
                    get: { presenter.mode(of: presenter.activePanel) },
                    set: { presenter.setMode($0, for: presenter.activePanel) }
                ),
                segments: ToolSetMode.allCases.map { mode in
                    .init(value: mode, title: mode.displayName, glyph: WorkflowGlyphs.glyph(for: mode), helpText: mode.shortHelp)
                },
                accessibilityTitle: NSLocalizedString(
                    "Tool set mode",
                    comment: "Accessibility title for the Draw / Apply / Place switch"
                )
            )
            Text(presenter.mode(of: presenter.activePanel).shortHelp)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .accessibilityElement(children: .contain)
    }

    /// What is armed right now, when that is not what the mode switch above is showing.
    ///
    /// The mode belongs to the set the armed preset came from, not to the panel on screen
    /// (``ToolLibraryPresenting/armedSetMode``). So an estimator can arm a stamp out of
    /// `Project Tools`, click over to `My Tools`, and read a switch that says *Draw* while the
    /// next click drops a stamp — the panel was telling the truth about the wrong set. The
    /// banner names the armed preset, the set it came from and what a click does, and it
    /// appears only while a mode is armed, so it is never furniture.
    @ViewBuilder
    private var armedBanner: some View {
        if let armed = presenter.armedModeState {
            HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.xs) {
                ZPDFGlyphView(WorkflowGlyphs.glyph(for: armed.mode), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.accentCyan)
                    .accessibilityHidden(true)
                Text(armed.bannerText)
                    .zpdfText(.caption, .textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(NSLocalizedString("Disarm", comment: "Clears the armed Tool Library preset")) {
                    presenter.clearActivePreset()
                }
                .buttonStyle(.link)
                .zpdfFont(.caption)
            }
            .padding(ZPDFSpacing.s)
            .zpdfControlBackground(fill: .elevated, cornerRadius: ZPDFRadius.small)
            .padding(.horizontal, ZPDFSpacing.m)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(armed.accessibilityDescription))
        }
    }

    private var layoutToggle: some View {
        ZPDFSegmentedControl(
            selection: Binding(
                get: { model.presentationStyle },
                set: { model.presentationStyle = $0 }
            ),
            segments: ToolPresetPresentationStyle.allCases.map { style in
                .init(
                    value: style,
                    title: style.displayName,
                    glyph: .symbol(style == .grid ? .toolLibrary : .pages)
                )
            },
            accessibilityTitle: NSLocalizedString("Tool layout", comment: "Accessibility title for the Tool Library layout switch")
        )
        .fixedSize()
    }

    private func libraryMenu(includesLayout: Bool) -> some View {
        Menu {
            if includesLayout {
                // The narrow layout's Grid/List switch: the same choice as the header's segments.
                Picker(
                    NSLocalizedString("Show Tools As", comment: "Tool Library menu: the Grid / List choice in the narrow layout"),
                    selection: Binding(
                        get: { model.presentationStyle },
                        set: { model.presentationStyle = $0 }
                    )
                ) {
                    ForEach(ToolPresetPresentationStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.inline)
                Divider()
            }
            Button(NSLocalizedString("Save Selection as Tool", comment: "Create a tool preset from the selected markup")) {
                if let selectedMarkup {
                    model.beginCreating(from: selectedMarkup, in: .myTools)
                }
            }
            .disabled(selectedMarkup == nil)

            Divider()

            Button(NSLocalizedString("Import Tool Set…", comment: "Import a .zpdftools file")) {
                isImportingFile = true
            }
            .disabled(model.isReviewingImport)
            Button(NSLocalizedString("Export This Set…", comment: "Export the active set as a .zpdftools file")) {
                exportDocument = ToolSetFileDocument(document: model.exportDocument(
                    panel: presenter.activePanel,
                    name: presenter.activePanel.displayName
                ))
                isExportingFile = true
            }
            // The export writes the whole set whatever the search field says, so the search must
            // not decide whether there is anything to export. Finding BH-849.
            .disabled(!model.canExport(panel: presenter.activePanel))

            // X-031: an imported set — by hand or from a pack — can be taken out again, whole,
            // with the Undo bar behind it. A subscribed set is not listed: its refresh owns it.
            if presenter.activePanel == .importedLibraries {
                let removable = model.removableImportedSets()
                Divider()
                Menu(NSLocalizedString("Remove Imported Set", comment: "Tool Library menu: remove one imported tool set")) {
                    ForEach(removable) { set in
                        Button(set.menuTitle) {
                            model.removeImportedSet(category: set.category)
                        }
                    }
                }
                .disabled(removable.isEmpty)
            }
        } label: {
            ZPDFGlyphView(.symbol(.more), size: ZPDFSpacing.Control.icon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(NSLocalizedString(
            "Tool Library actions",
            comment: "Accessibility label for the Tool Library overflow menu"
        )))
    }

    private var searchField: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ZPDFGlyphView(.symbol(.search), size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(ZPDFColor.textSecondary)
            TextField(
                NSLocalizedString("Filter tools", comment: "Placeholder for the Tool Library filter field"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .zpdfFont(.control)
            .focused($isSearchFocused)
            .onChange(of: searchText) { _, newValue in
                presenter.setSearchText(newValue)
            }
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .frame(height: ZPDFSpacing.Control.toolbarControl)
        .zpdfControlBackground(fill: .surface)
        .zpdfFocusRing(isSearchFocused)
        .padding(.horizontal, ZPDFSpacing.m)
        .accessibilityLabel(Text(NSLocalizedString("Filter tools", comment: "Accessibility label for the Tool Library filter field")))
    }

    private var emptyState: some View {
        ZPDFEmptyState(
            glyph: .symbol(.toolLibrary),
            title: searchText.isEmpty
                ? NSLocalizedString("This set has no tools yet", comment: "Tool Library empty state title")
                : NSLocalizedString("No tool matches that filter", comment: "Tool Library filtered empty state title"),
            message: searchText.isEmpty
                ? NSLocalizedString(
                    "Draw a measurement on the page, then save it here so the next one takes a single click.",
                    comment: "Tool Library empty state message"
                )
                : NSLocalizedString(
                    "Clear the filter to see the whole set again.",
                    comment: "Tool Library filtered empty state message"
                ),
            actionTitle: searchText.isEmpty
                ? NSLocalizedString("New Tool", comment: "Tool Library empty state action")
                : NSLocalizedString("Clear Filter", comment: "Tool Library filtered empty state action"),
            action: {
                if searchText.isEmpty {
                    model.beginCreating(in: presenter.activePanel)
                } else {
                    searchText = ""
                    presenter.setSearchText("")
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presetScroll(_ content: ToolPresetPanelContent) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ZPDFSpacing.s, pinnedViews: [.sectionHeaders]) {
                ForEach(content.groups) { group in
                    Section {
                        if !model.collapsedCategories.contains(group.category) {
                            categoryBody(group.presets, slotNumbers: content.slotNumbers)
                        }
                    } header: {
                        categoryHeader(group.category, count: group.presets.count)
                    }
                }
            }
            .padding(.horizontal, ZPDFSpacing.m)
            .padding(.bottom, ZPDFSpacing.m)
        }
    }

    private func categoryHeader(_ category: String, count: Int) -> some View {
        ZPDFPanelHeader(
            title: category,
            count: count,
            isExpanded: Binding(
                get: { !model.collapsedCategories.contains(category) },
                set: { expanded in
                    if expanded {
                        model.collapsedCategories.remove(category)
                    } else {
                        model.collapsedCategories.insert(category)
                    }
                }
            )
        )
        .background(ZPDFColor.background)
    }

    @ViewBuilder
    private func categoryBody(
        _ items: [ToolPresetSummary],
        slotNumbers: [ToolPresetSummary.ID: Int]
    ) -> some View {
        if model.presentationStyle == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: ZPDFSpacing.s)], spacing: ZPDFSpacing.s) {
                ForEach(items) { preset in
                    ToolPresetTile(
                        preset: preset,
                        isArmed: preset.id == presenter.activePresetID,
                        slotNumber: slotNumbers[preset.id],
                        onActivate: { presenter.activatePreset(id: preset.id) },
                        onEdit: { model.beginEditing(id: preset.id) }
                    )
                    .modifier(PresetInteractions(
                        preset: preset,
                        model: model,
                        siblings: items,
                        viewedPanel: presenter.activePanel,
                        onEdit: { model.beginEditing(id: preset.id) }
                    ))
                }
            }
        } else {
            VStack(spacing: 1) {
                ForEach(items) { preset in
                    ToolPresetRow(
                        preset: preset,
                        isArmed: preset.id == presenter.activePresetID,
                        slotNumber: slotNumbers[preset.id],
                        onActivate: { presenter.activatePreset(id: preset.id) }
                    )
                    .modifier(PresetInteractions(
                        preset: preset,
                        model: model,
                        siblings: items,
                        viewedPanel: presenter.activePanel,
                        onEdit: { model.beginEditing(id: preset.id) }
                    ))
                }
            }
        }
    }

    private var reuseToolFooter: some View {
        Toggle(isOn: Binding(
            get: { presenter.reuseToolEnabled },
            set: { presenter.setReuseToolEnabled($0) }
        )) {
            Text(NSLocalizedString(
                "Keep the tool armed after each markup",
                comment: "Tool Library reuse-tool switch"
            ))
            .zpdfText(.caption, .textSecondary)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, ZPDFSpacing.m)
    }

    // MARK: - Helpers

    private var draftBinding: Binding<ToolPresetDraft?> {
        Binding(
            get: { model.draft },
            set: { if $0 == nil { model.cancelDraft() } }
        )
    }

    private var importReviewBinding: Binding<ToolSetImportReview?> {
        Binding(
            get: { model.importReview },
            set: { if $0 == nil { model.cancelImport() } }
        )
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        // The size check, the read and the review all run off the main actor, with the
        // importer's security scope held until the read is done (IM-155, R-134).
        Task { @MainActor in
            await model.reviewImport(fileAt: url)
        }
    }
}

/// Which layout the Tool Library takes at a width (L-61, L-89).
public enum ToolLibraryPanelLayout {

    /// The narrowest width that still holds the sets beside the tools: the 168 pt sidebar and
    /// its divider, and a tool area wide enough for its header on one line — the set's name and
    /// count beside the Grid/List switch, New Tool, ⋯ and close (about 340 pt).
    public static let stackedLayoutWidth: CGFloat = 540

    /// Whether the sets stack above the tools at `width`: a pop-up instead of a sidebar.
    public static func usesStackedLayout(width: CGFloat) -> Bool {
        width < stackedLayoutWidth
    }
}

/// The context menu, drag source and keyboard reordering shared by the tile and the row.
///
/// Reordering is on the keyboard as well as the mouse: Option-Up and Option-Down move a preset
/// inside its category, so the whole panel is usable without a pointer.
private struct PresetInteractions: ViewModifier {

    let preset: ToolPresetSummary
    let model: ToolLibraryEditingModel
    let siblings: [ToolPresetSummary]
    /// The panel on screen, which is not the preset's own set in Recent and Favorites.
    let viewedPanel: ToolLibraryPanel
    let onEdit: () -> Void

    func body(content: Content) -> some View {
        content
            .draggable(ToolPresetDragPayload(preset: preset))
            .contextMenu { menuItems }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let delta = press.key == .upArrow ? -1 : 1
                guard press.modifiers.contains(.option), canMove(by: delta) else {
                    return .ignored
                }
                move(by: delta)
                return .handled
            }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(NSLocalizedString("Edit Tool…", comment: "Context menu: edit a tool preset"), action: onEdit)
            .disabled(preset.isReadOnly)
        Button(NSLocalizedString("Duplicate", comment: "Context menu: duplicate a tool preset")) {
            model.duplicate(id: preset.id)
        }
        Button(preset.isFavorite
            ? NSLocalizedString("Remove from Favorites", comment: "Context menu: unstar a tool preset")
            : NSLocalizedString("Add to Favorites", comment: "Context menu: star a tool preset")) {
            model.toggleFavorite(id: preset.id)
        }
        Divider()
        Button(NSLocalizedString("Move Up", comment: "Context menu: move a tool preset up")) { move(by: -1) }
            .disabled(!canMove(by: -1))
        Button(NSLocalizedString("Move Down", comment: "Context menu: move a tool preset down")) { move(by: 1) }
            .disabled(!canMove(by: 1))
        Divider()
        Button(NSLocalizedString("Remove", comment: "Context menu: delete a tool preset")) {
            model.delete(id: preset.id)
        }
        // X-031: the model's one rule — a hand-imported tool is read-only and still removable;
        // a subscribed one is not.
        .disabled(!model.canRemove(preset))
    }

    /// Whether a move is offered: only when it visibly reorders the list on screen (S-083).
    private func canMove(by delta: Int) -> Bool {
        model.canMove(id: preset.id, by: delta, among: siblings.map(\.id), viewing: viewedPanel)
    }

    /// Moves past the next **visible** sibling. The preset's index in the filtered list used
    /// to be handed to `move(id:to:)`, which reorders the unfiltered category
    /// — so under a search Move Down swapped the preset with a hidden neighbour, looked like a
    /// no-op, and shifted the number-key slots. Finding BH-316.
    private func move(by delta: Int) {
        model.move(id: preset.id, by: delta, among: siblings.map(\.id))
    }
}
