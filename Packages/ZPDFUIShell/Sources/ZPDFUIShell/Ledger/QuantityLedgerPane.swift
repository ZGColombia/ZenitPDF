import SwiftUI
import ZPDFDesignSystem
import ZPDFUILedger
import ZPDFUIPresentation

/// The docked (or detached) Quantity Ledger pane.
///
/// The shell owns the pane, not the table: the rows are drawn by the ledger package's
/// virtualised table — the grouped `NSOutlineView` with collapsible per-type subtotal
/// headers by default, hosted through ``LedgerPaneModel``. What
/// lives here is the chrome that makes the pane a first-class window citizen — its header,
/// its grouping menu, its detach control, its screen-reader summary and the grand-total
/// strip, which stays exactly as it was.
public struct QuantityLedgerPane: View {

    /// The two tabs of the bottom pane: the Quantity Ledger, and the project's audit trail
    /// docked behind it (ADR-0007 §3 — "a History pane beside the Quantity Ledger").
    ///
    /// The selection lives on ``ShellPanelState`` rather than in this view, because both tabs
    /// are closable surfaces with a menu item and an ear of their own, and
    /// *Show History* has to be able to open the pane on the right tab from outside it.
    typealias PaneTab = ZPDFBottomPaneTab

    /// The ledger bar's own band: the design system's 56 pt bar less
    /// the two points of hairline budget, which still leaves the 44 pt summary chips a gutter
    /// above and below.
    public static let headerHeight: CGFloat = ZPDFSpacing.Chrome.ledgerBarHeight - 2

    /// The bar's ground: the design system's ledger-bar colour, sampled from the mockup's bar
    /// (one step lighter than the panels). The table under it stays on the panel surface.
    static let barGroundToken: ZPDFColorToken = .ledgerBar

    /// The pane's height when it is collapsed to just its header bar: the header band plus
    /// its hairline budget — exactly the design system's ledger bar height. The layout
    /// controller pins the docked pane to this.
    public static let collapsedBarHeight: CGFloat = headerHeight + 2

    /// The pane's title bar text, transcribed from the main-window mockup and binding for
    /// terminology.
    ///
    /// A named constant so the convergence test can read the string the pane actually draws.
    /// It used to compare a literal to the same literal — `NSLocalizedString("Panel (Quantity
    /// Ledger)", …) == "Panel (Quantity Ledger)"` — which is true whatever the pane renders,
    /// so renaming the header would not have failed it (CR-120).
    public static let paneTitle = NSLocalizedString(
        "Panel (Quantity Ledger)",
        comment: "Ledger pane title"
    )

    /// The per-sheet toggle's label, constant whatever its state (the mockup's "Per Sheet").
    static let perSheetTitle = NSLocalizedString(
        "Per Sheet",
        comment: "Ledger header toggle: separate the summary by sheet"
    )

    /// The pane's own side panel: the filter builder, the bulk-edit panel, or neither.
    ///
    /// A side panel rather than a sheet because both are used *while* reading the table —
    /// a filter whose match count you cannot see against the rows it is narrowing is a
    /// guess, and a bulk edit you cannot check against the selection is a leap.
    enum SidePanel: String, CaseIterable, Identifiable {
        case none
        case filter
        case bulkEdit

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none:
                return NSLocalizedString("No Panel", comment: "Ledger side panel name")
            case .filter:
                return NSLocalizedString("Filter", comment: "Ledger side panel name")
            case .bulkEdit:
                return NSLocalizedString("Bulk Edit", comment: "Ledger side panel name")
            }
        }
    }

    /// Width of the pane's side panel. Wide enough for a rule row's three controls plus
    /// its value field without the operand editor collapsing to an ellipsis.
    static let sidePanelWidth: CGFloat = 340

    private let environment: ProjectShellEnvironment
    private let panelState: ShellPanelState

    @State private var sidePanel: SidePanel = .none
    @State private var model: LedgerPaneModel
    @State private var isHoveringTitle = false

    /// Creates the pane.
    ///
    /// - Parameters:
    ///   - panelState: read for the live docked/detached/collapsed state, so every
    ///     header control is labelled for what it will actually do rather than for how the
    ///     pane was built.
    ///   - preferences: the persisted grouping and collapsed-group choices; injectable so
    ///     tests never touch the user's real defaults.
    public init(
        environment: ProjectShellEnvironment,
        panelState: ShellPanelState,
        preferences: LedgerPanePreferences = LedgerPanePreferences()
    ) {
        self.init(environment: environment, panelState: panelState, preferences: preferences, sidePanel: .none)
    }

    /// The pane opened on one of its side panels, for tests that host the real pane off screen
    /// and drive the panel a person would have opened from the header (L-85) — over a model the
    /// test already drove, when it passes one (an Apply whose outcome line is showing).
    init(
        environment: ProjectShellEnvironment,
        panelState: ShellPanelState,
        preferences: LedgerPanePreferences,
        sidePanel: SidePanel,
        model: LedgerPaneModel? = nil
    ) {
        self.environment = environment
        self.panelState = panelState
        _sidePanel = State(initialValue: sidePanel)
        _model = State(initialValue: model ?? LedgerPaneModel(
            presenter: environment.ledger,
            preferences: preferences,
            subtotalRounding: Self.subtotalRounding(for: environment)
        ))
    }

    private var ledger: any LedgerPresenting { environment.ledger }

    /// Which tab is showing, read from and written to the shared panel state.
    private var activeTab: PaneTab {
        get { panelState.bottomPaneTab }
        nonmutating set { panelState.bottomPaneTab = newValue }
    }

    /// The columns the docked pane draws: the mockup default
    /// `Page · Type · Label · Subject · Comment · Value · Unit`,
    /// derived from whatever the presenter published so a custom column still appears.
    private var displayColumns: [LedgerColumn] {
        LedgerDefaultColumns.arranged(ledger.visibleColumns).filter(\.visible)
    }

    /// Whether the table is on screen. The detached window never collapses to a bar.
    private var showsContent: Bool {
        panelState.isLedgerDetached || !panelState.isLedgerCollapsedToBar
    }

    /// The subtotal rounding the session's decimal places imply, in a metric and an imperial
    /// session alike; see ``subtotalRounding(for:)``.
    private var subtotalRounding: LedgerRounding { Self.subtotalRounding(for: environment) }

    /// The rounding an imperial session's group subtotals and summary chips fall back to when
    /// the shell knows no decimal precision for the session (`activePrecision` holds a fraction,
    /// which only an app that bypasses `InspectorMeasurementModel.selectPrecision` can leave
    /// there). Two places is the app's default `DisplayUnitSelection.metricDecimalPlaces`.
    static let imperialSubtotalRounding: LedgerRounding = .twoDigits

    /// The subtotal rounding for an environment's session.
    ///
    /// **Metric session:** the Inspector's decimals, read through `InspectorPrecision.effective`,
    /// the same answer the Precision popup gives (BH-286).
    ///
    /// **Imperial session:** the session's *decimal places* too, not its fraction. The ledger
    /// table has no feet-and-inches formatter, so an imperial subtotal prints as a decimal in
    /// the session's unit (`ft`, `ft²`, `yd³`) — and the app's quantity formatter prints every
    /// decimal quantity of an imperial session (square feet, cubic yards, decimal feet and
    /// inches, the totals row) at `DisplayUnitSelection.metricDecimalPlaces`. The app seeds
    /// `inspectorEditing.activePrecision` from that value and a fraction pick never overwrites
    /// it (BH-286), so reading it here is what makes a group heading and a chip agree with the
    /// rows and the totals row at 0, 2 or 3 places alike. Clamped to the ledger's 0…4 like the
    /// metric arm; ``imperialSubtotalRounding`` only when no decimal value is known.
    ///
    /// History (T-031): this arm returned `.exact` (10 m read `32.8083989501 ft`), then a fixed
    /// `.twoDigits`, which was only right while the session kept the default two places — with
    /// three places a 1 m² row and the totals row read `10.764 ft²` and the chip `10.76 ft²`.
    static func subtotalRounding(for environment: ProjectShellEnvironment) -> LedgerRounding {
        let active = environment.inspectorEditing.activePrecision
        let precision = InspectorPrecision.effective(
            active: active,
            lengthUnit: environment.measurement.lengthUnit,
            imperialPrecision: environment.measurement.imperialPrecision
        )
        switch precision {
        case let .decimalPlaces(places):
            return rounding(forDecimalPlaces: places)
        case .imperialFraction:
            guard case let .decimalPlaces(places) = active else { return imperialSubtotalRounding }
            return rounding(forDecimalPlaces: places)
        }
    }

    /// A number of decimal places as a ledger rounding, clamped to the ledger's 0…4.
    private static func rounding(forDecimalPlaces places: Int) -> LedgerRounding {
        LedgerRounding(rawValue: max(0, min(4, places))) ?? .twoDigits
    }

    /// The units group subtotals print in: the session's display units (BH-732).
    static func unitPolicy(for environment: ProjectShellEnvironment) -> LedgerUnitPolicy {
        LedgerUnitPolicy(
            length: environment.measurement.lengthUnit,
            area: environment.measurement.areaUnit,
            volume: environment.measurement.volumeUnit
        )
    }

    /// What the Quantities tab shows (BH-294, IM-028, IM-121).
    enum ContentState: Equatable {
        /// Rows to show.
        case rows
        /// The projection is still arriving.
        case loading
        /// Nothing has been measured.
        case empty
        /// Measurements exist, but the filter matches none of them.
        case noMatch(total: Int)
    }

    /// The content state for a ledger's counts. A filter that matches nothing used to show
    /// "Measure something on the page…" over a takeoff of hundreds of rows, and so did a
    /// ledger that was still loading.
    static func contentState(rowCount: Int, unfilteredRowCount: Int, isFiltered: Bool, isLoading: Bool) -> ContentState {
        if rowCount > 0 { return .rows }
        if isLoading { return .loading }
        if isFiltered { return .noMatch(total: unfilteredRowCount) }
        return .empty
    }

    private var contentState: ContentState {
        Self.contentState(
            rowCount: ledger.rowCount,
            unfilteredRowCount: ledger.unfilteredRowCount,
            isFiltered: ledger.isFiltered,
            isLoading: ledger.isLoading
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // The bar's top edge is a hairline (the mockup's rule at y 866), so the collapsed
            // bar reads as its own band under the canvas column.
            ZPDFHairlineDivider(axis: .horizontal)
            header
            if showsContent {
                ZPDFHairlineDivider(axis: .horizontal)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        switch activeTab {
                        case .history:
                            HistoryPaneContent(environment: environment)
                        case .quantities:
                            statusChips
                            layoutSaveNotice
                            // IM-056 / BH-102: a failed rebuild and a
                            // refused sort are said above the table, which keeps the last result.
                            LedgerPresenterStatusBanner(
                                rebuildError: ledger.lastRebuildError,
                                unappliedSortMessage: ledger.unappliedSortMessage,
                                onDismissRebuildError: { ledger.dismissRebuildError() }
                            )
                            switch contentState {
                            case .rows:
                                table
                                ZPDFHairlineDivider(axis: .horizontal)
                                totalsRow
                                symbolLegend
                            case .loading:
                                ledgerStateLine(NSLocalizedString(
                                    "Loading quantities…",
                                    comment: "Ledger state while the projection is still arriving"
                                ))
                            case .empty:
                                emptyLedgerState
                            case let .noMatch(total):
                                noMatchState(total: total)
                                ZPDFHairlineDivider(axis: .horizontal)
                                totalsRow
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if activeTab == .quantities, sidePanel != .none {
                        ZPDFHairlineDivider(axis: .vertical)
                        sidePanelContent
                            .frame(width: Self.sidePanelWidth)
                    }
                }
            }
        }
        .background(ZPDFColor.surface)
        // The naming prompt "Save Layout…" always claimed to open, and now does. The
        // alert is bound to the model's `pendingLayoutName`, so a test drives the whole
        // control — menu item, prompt, save, persistence — without putting anything on the
        // user's screen; nothing here presents itself unasked.
        .alert(
            NSLocalizedString(
                "Save Column Layout",
                comment: "Title of the Quantity Ledger save-layout prompt"
            ),
            isPresented: Binding(
                get: { model.pendingLayoutName != nil },
                set: { if !$0 { model.cancelLayoutNaming() } }
            )
        ) {
            TextField(
                NSLocalizedString("Name", comment: "Field label in the save-layout prompt"),
                text: Binding(
                    get: { model.pendingLayoutName ?? "" },
                    set: { model.pendingLayoutName = $0 }
                )
            )
            Button(NSLocalizedString("Save", comment: "Confirm the save-layout prompt")) {
                model.saveLayout(named: model.pendingLayoutName ?? "")
            }
            Button(
                NSLocalizedString("Cancel", comment: "Dismiss the save-layout prompt"),
                role: .cancel
            ) {
                model.cancelLayoutNaming()
            }
        } message: {
            Text(NSLocalizedString(
                "The columns shown, their order, their widths and which are pinned are saved under this name. Apply it again from the column header menu.",
                comment: "Explanation in the Quantity Ledger save-layout prompt"
            ))
        }
        // NL-QTY-02: the Column Manager, bound to the model like the layout prompt above — a
        // test opens and drives it through `model.columnManager` without any window.
        .sheet(isPresented: Binding(
            get: { model.columnManager != nil },
            set: { if !$0 { model.closeColumnManager() } }
        )) {
            if let manager = model.columnManager {
                LedgerColumnManagerView(model: manager) { model.closeColumnManager() }
            }
        }
        // NL-QTY-15: the whole-project summary, bound to the model the same way.
        .sheet(isPresented: Binding(
            get: { model.projectSummaryPanel != nil },
            set: { if !$0 { model.closeProjectSummary() } }
        )) {
            if let panel = model.projectSummaryPanel {
                LedgerProjectSummaryView(model: panel) { model.closeProjectSummary() }
            }
        }
        // NL-QTY-05: the rate library, bound to the model the same way.
        .sheet(isPresented: Binding(
            get: { model.rateLibraryPanel != nil },
            set: { if !$0 { model.closeRateLibrary() } }
        )) {
            if let panel = model.rateLibraryPanel {
                LedgerRateLibraryPanel(model: panel) { model.closeRateLibrary() }
            }
        }
        // NL-QTY-16: snapshots and the change report, bound to the model the same way.
        .sheet(isPresented: Binding(
            get: { model.snapshotsPanel != nil },
            set: { if !$0 { model.closeSnapshots() } }
        )) {
            if let panel = model.snapshotsPanel {
                LedgerSnapshotsPanel(model: panel) { model.closeSnapshots() }
            }
        }
        // The Explain panel, bound to the model the same way.
        .sheet(isPresented: Binding(
            get: { model.explainPanel != nil },
            set: { if !$0 { model.closeExplain() } }
        )) {
            if let panel = model.explainPanel {
                LedgerExplainView(model: panel) { model.closeExplain() }
            }
        }
        // NL-QTY-09: the summary matrix, bound to the model the same way.
        .sheet(isPresented: Binding(
            get: { model.matrixPanel != nil },
            set: { if !$0 { model.closeMatrix() } }
        )) {
            if let matrix = model.matrixPanel {
                LedgerMatrixView(model: matrix) { model.closeMatrix() }
            }
        }
        // NL-QTY-07: the Apply Assembly panel, bound to the model the same way.
        .sheet(isPresented: Binding(
            get: { model.assemblyPanel != nil },
            set: { if !$0 { model.closeAssemblyPanel() } }
        )) {
            if let panel = model.assemblyPanel {
                LedgerAssemblyPanel(model: panel) { model.closeAssemblyPanel() }
            }
        }
        // The pane never paints outside its split item: without the clip, a taller-than-
        // pane SwiftUI pass (switching to History while collapsed) drew the header over
        // the Navigator's layer outline until the next relayout.
        .clipped()
        // The AppKit table reloads on explicit cues rather than on SwiftUI body passes.
        // `contentRevision` is the cue that always moves on a projection swap; row count
        // and totals are kept as belt-and-braces, but they are NOT sufficient on their
        // own — a subject rename changes neither, and the row read stale until the next
        // unrelated reload (found 2026-08-24 while verifying ledger hydration).
        //
        // IM-029: one projection swap moves the revision, the row count, the totals and the
        // loading flag together, and each trigger used to cost a full rebuild. They now all
        // ask for ONE refresh on the next turn.
        .onChange(of: ledger.contentRevision) { model.requestRefresh() }
        .onChange(of: ledger.rowCount) { model.requestRefresh() }
        .onChange(of: ledger.grandTotals) { model.requestRefresh() }
        .onChange(of: environment.inspectorEditing.activePrecision) {
            model.setSubtotalRounding(subtotalRounding)
        }
        .onChange(of: environment.measurement.lengthUnit) {
            model.setSubtotalRounding(subtotalRounding)
            model.setSubtotalUnitPolicy(Self.unitPolicy(for: environment))
        }
        .onChange(of: environment.measurement.areaUnit) {
            model.setSubtotalUnitPolicy(Self.unitPolicy(for: environment))
        }
        .onChange(of: environment.measurement.volumeUnit) {
            model.setSubtotalUnitPolicy(Self.unitPolicy(for: environment))
        }
        // BH-295: a pane that mounts after the first projection syncs on appear, not only on
        // the next change. BH-732: so does the unit policy.
        .onAppear {
            // NL-UX-09: the row context menu, over the window's own doors.
            model.installRowMenu(environment: environment)
            model.setSubtotalRounding(subtotalRounding)
            model.setSubtotalUnitPolicy(Self.unitPolicy(for: environment))
        }
        // A regrouping asked for by another panel — Project Zones' "Group Quantity Ledger by
        // Zone". The token, not the value: asking twice for the same grouping has to arrive
        // twice, or the second ask reads as a control that did nothing.
        .onChange(of: environment.ledgerGrouping.token) {
            guard let columns = environment.ledgerGrouping.take() else { return }
            activeTab = .quantities
            model.setGrouping(columns)
        }
        .onChange(of: ledger.isLoading) { _, isLoading in
            if !isLoading { model.requestRefresh() }
        }
        .onChange(of: ledger.selectedRowIDs) { _, ids in
            model.applyExternalSelection(ids)
        }
        // The standard escape path: Escape on the pane hides it, same as its close control.
        .onExitCommand { environment.perform(activeTab.surface.command) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Quantity Ledger",
            comment: "Accessibility label for the Quantity Ledger pane"
        )))
        .accessibilityValue(Text(screenReaderSummary))
    }

    /// One quiet line under the column headers — the loading state (static text, so nothing
    /// animates under Reduce Motion or otherwise).
    private func ledgerStateLine(_ text: String) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) { headerRow(displayColumns) }
                .scrollIndicators(.hidden)
            Text(text)
                .zpdfText(.caption, .textSecondary)
                .padding(.horizontal, ZPDFSpacing.m)
                .padding(.vertical, ZPDFSpacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// IM-028: a filter that matches nothing says so, names the scale of what it hides, and
    /// offers the way back — the filter control itself stays in the header.
    private func noMatchState(total: Int) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) { headerRow(displayColumns) }
                .scrollIndicators(.hidden)
            HStack(spacing: ZPDFSpacing.s) {
                ZPDFGlyphView(.symbol(.search), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .accessibilityHidden(true)
                Text(Self.noMatchText(total: total))
                    .zpdfText(.caption, .textSecondary)
                Button(NSLocalizedString("Clear Filter", comment: "Ledger action: remove the filter that hides every row")) {
                    model.setFilter(LedgerFilterGroup(id: UUID()))
                }
                .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZPDFSpacing.m)
            .padding(.vertical, ZPDFSpacing.s)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    static func noMatchText(total: Int) -> String {
        String(
            format: NSLocalizedString(
                "No rows match the filter (0 of %d).",
                comment: "Ledger state when the filter hides every row; the unfiltered row count"
            ),
            total
        )
    }

    /// BH-815: what the last Save Layout did, in the pane — the prompt closes either way.
    @ViewBuilder
    private var layoutSaveNotice: some View {
        if let message = model.layoutSaveMessage ?? model.paneNotice {
            HStack(spacing: ZPDFSpacing.s) {
                Text(message)
                    .zpdfText(.caption, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(NSLocalizedString("Dismiss", comment: "Clears the save-layout message")) {
                    model.clearLayoutSaveMessage()
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal, ZPDFSpacing.m)
            .padding(.vertical, ZPDFSpacing.xs)
            .accessibilityElement(children: .combine)
        }
    }

    /// The empty ledger per the mockup: the column header row stays where it always is,
    /// the body is simply empty, and one quiet line says why. The table's structure is the
    /// promise of what measuring will produce; a message card in its place was a different
    /// screen to learn.
    private var emptyLedgerState: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                headerRow(displayColumns)
            }
            .scrollIndicators(.hidden)
            Text(NSLocalizedString(
                "Measure something on the page and it appears here with its totals.",
                comment: "Ledger empty state hint under the column headers"
            ))
            .zpdfText(.caption, .textSecondary)
            .padding(.horizontal, ZPDFSpacing.m)
            .padding(.vertical, ZPDFSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The summary the bar's chips show, read from the presenter's grand totals and — when
    /// the presenter can say — its per-kind row counts.
    var summary: LedgerSummary {
        let host = model.host
        let locale = host.controller.locale
        return LedgerSummary(
            totals: ledger.grandTotals,
            rowCount: ledger.rowCount,
            kindCounts: (ledger as? LedgerKindRowCounting)?.rowCountsByMeasurementKind,
            markupCount: (ledger as? LedgerMarkupCounting)?.nonMeasurementMarkupCount,
            // The table's own totals formatter — the function its group subtotals and totals
            // print through — with the pane's display units, rounding and number locale, so a
            // chip and the table under it agree digit for digit and unit for unit. A count
            // keeps its own digits there, so no chip-only rule is needed (T-048).
            format: { quantity in
                LedgerNumberFormatting.display(
                    quantity, policy: host.unitPolicy, rounding: host.rounding, locale: locale
                )
            },
            speak: { quantity in
                Self.spokenTotal(
                    quantity, policy: host.unitPolicy, rounding: host.rounding, locale: locale
                )
            }
        )
    }

    /// A total as VoiceOver says it: the same number the chip
    /// prints, from the same formatter, followed by the display unit's full name —
    /// "2,480 square feet", not "2,480 SF".
    static func spokenTotal(
        _ quantity: DecimalQuantity,
        policy: LedgerUnitPolicy,
        rounding: LedgerRounding,
        locale: Locale
    ) -> String {
        let parts = LedgerNumberFormatting.displayParts(quantity, policy: policy, rounding: rounding, locale: locale)
        let unitName: String
        switch quantity.dimension.lengthPower {
        case 1 where quantity.dimension.currencyCode == nil && !quantity.dimension.angle:
            unitName = policy.length.displayName
        case 2 where quantity.dimension.currencyCode == nil:
            unitName = policy.area.displayName
        case 3 where quantity.dimension.currencyCode == nil:
            unitName = policy.volume.displayName
        default:
            unitName = parts.unitSymbol
        }
        let name = unitName.lowercased(with: locale)
        return name.isEmpty ? parts.numberText : "\(parts.numberText) \(name)"
    }

    /// The header bar, per the 2026-09-23 mockup, left to right: the disclosure chevron and
    /// pane title (one button — one-click show/hide), the Quantities | History
    /// tabs, the summary chips, then Per Sheet, Filter, Bulk Edit, Detach, the options menu
    /// and close.
    ///
    /// The chips give way first when the window narrows: full chips, then one-line chips,
    /// then none — the action buttons never do, because they are the bar's controls and the
    /// chips only repeat what the table's totals row already says.
    private var header: some View {
        HStack(spacing: ZPDFSpacing.s) {
            collapseControl
            ZPDFHairlineDivider(axis: .vertical)
                .frame(height: ZPDFSpacing.Control.toolbarButton)
            tabControl
            if activeTab == .quantities {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        LedgerSummaryStrip(
                            summary: summary,
                            onChip: { model.toggleKindChip($0) },
                            activeKind: model.activeKindChip
                        )
                        Spacer(minLength: ZPDFSpacing.s)
                    }
                    HStack(spacing: 0) {
                        // V-048: the narrow strip filters and shows the filter, as the full one does.
                        LedgerSummaryStrip(
                            summary: summary,
                            onChip: { model.toggleKindChip($0) },
                            activeKind: model.activeKindChip,
                            isCompact: true
                        )
                        Spacer(minLength: ZPDFSpacing.s)
                    }
                    Spacer(minLength: ZPDFSpacing.s)
                }
                .padding(.leading, ZPDFSpacing.s)
            } else {
                Spacer(minLength: ZPDFSpacing.s)
            }
            if activeTab == .quantities {
                perSheetToggle
                olderScaleButton   // NL-MEASURE-03 (r2-layers follow-up): LedgerOlderScaleControl.swift
                filterButton
                bulkEditButton
            }
            if !panelState.isLedgerDetached {
                ZPDFToolbarButton(
                    glyph: .symbol(.detach),
                    title: NSLocalizedString("Detach", comment: "Move the ledger to its own window"),
                    showsTitle: true,
                    keyboardHint: environment.commands
                        .command(.detachQuantityLedger)?.binding?.displayString
                ) {
                    environment.perform(.detachQuantityLedger)
                }
            } else {
                ZPDFToolbarButton(
                    glyph: .symbol(.detach),
                    title: NSLocalizedString("Dock", comment: "Re-dock the detached ledger"),
                    showsTitle: true,
                    keyboardHint: environment.commands
                        .command(.detachQuantityLedger)?.binding?.displayString
                ) {
                    environment.perform(.detachQuantityLedger)
                }
            }
            optionsMenu
            ZPDFToolbarButton(
                glyph: .symbol(.close),
                title: String(
                    format: NSLocalizedString("Close %@", comment: "Ledger header close control"),
                    activeTab.surface.displayName
                ),
                helpText: Self.closeHelp(
                    shortcut: environment.commands.command(activeTab.surface.command)?.binding?.displayString
                ),
                keyboardHint: environment.commands
                    .command(activeTab.surface.command)?.binding?.displayString
            ) {
                environment.perform(activeTab.surface.command)
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(height: Self.headerHeight)
        .background(ZPDFColor.color(Self.barGroundToken))
    }

    /// Quantities | History — the audit trail is a tab of the same bottom pane, so it docks,
    /// collapses and detaches with the ledger instead of fighting it for screen space
    /// (ADR-0007 §3). Selecting a tab while the pane is collapsed also expands it: choosing
    /// what to look at *is* asking to look at it.
    private var tabControl: some View {
        LedgerPaneTabBar(
            selection: Binding(
                get: { activeTab },
                set: { tab in
                    activeTab = tab
                    if !panelState.isLedgerDetached, panelState.isLedgerCollapsedToBar {
                        environment.perform(.collapseQuantityLedger)
                    }
                }
            ),
            tabs: PaneTab.allCases.map { tab in
                LedgerPaneTabBar.Tab(value: tab, title: tab.title)
            },
            accessibilityTitle: NSLocalizedString(
                "Bottom pane tab",
                comment: "Accessibility title of the Quantities/History tab control"
            )
        )
        .fixedSize()
    }

    /// The chevron plus the title chip, one button: click anywhere on it to collapse the
    /// pane to this bar or restore it to its previous height.
    private var collapseControl: some View {
        let isCollapsed = !panelState.isLedgerDetached && panelState.isLedgerCollapsedToBar
        return Button {
            environment.perform(.collapseQuantityLedger)
        } label: {
            HStack(spacing: ZPDFSpacing.s) {
                ZPDFGlyphView(
                    .symbol(isCollapsed ? .disclosureClosed : .disclosureOpen),
                    size: ZPDFSpacing.Control.iconSmall
                )
                .foregroundStyle(ZPDFColor.textSecondary)
                // The mockup's pane title, verbatim. The row
                // count that used to sit beside it is the Markups chip now.
                Text(Self.paneTitle)
                    .zpdfText(.body.withWeight(.semibold), .textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, ZPDFSpacing.s)
            .frame(minHeight: ZPDFSpacing.Control.toolbarButton)
            .background {
                RoundedRectangle(cornerRadius: ZPDFRadius.medium, style: .continuous)
                    .fill(ZPDFColor.elevated)
                    .opacity(isHoveringTitle && !panelState.isLedgerDetached ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringTitle = $0 }
        .zpdfAnimation(.micro, value: isHoveringTitle)
        .disabled(panelState.isLedgerDetached)
        .help(isCollapsed
            ? NSLocalizedString("Expand the Quantity Ledger", comment: "Ledger collapse chip help")
            : NSLocalizedString("Collapse the Quantity Ledger to its header", comment: "Ledger collapse chip help"))
        .accessibilityLabel(Text(NSLocalizedString(
            "Quantity Ledger",
            comment: "Accessibility label for the ledger header chip"
        )))
        .accessibilityValue(isCollapsed
            ? Text(NSLocalizedString("Collapsed", comment: "Accessibility value: pane collapsed to its header"))
            : Text(NSLocalizedString("Expanded", comment: "Accessibility value: pane showing its content")))
    }

    /// NL-QTY-17: one chip per review status — "Open (12)" — that filters the ledger to it.
    /// Glyph and words carry the status; the tint only repeats them.
    @ViewBuilder
    private var statusChips: some View {
        let counts = model.statusCounts
        if counts.count > 1 || counts.contains(where: { $0.value != "none" }) {
            ScrollView(.horizontal) {
                HStack(spacing: ZPDFSpacing.s) {
                    ForEach(counts) { status in
                        ZPDFSummaryChip(
                            glyph: .symbol(Self.statusGlyph(status.value)),
                            tint: Self.statusTint(status.value),
                            title: status.title,
                            count: "\(status.count)",
                            isSelected: model.isStatusChipActive(status.value)
                        ) {
                            model.toggleStatusChip(status.value)
                        }
                        .help(String(
                            format: NSLocalizedString(
                                "Show only rows with the status %@. Click again to show all.",
                                comment: "Help on a status quick-filter chip; the status"
                            ),
                            status.title
                        ))
                    }
                }
                .padding(.horizontal, ZPDFSpacing.m)
                .padding(.vertical, ZPDFSpacing.xs)
            }
            .scrollIndicators(.never)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(NSLocalizedString("Status filters", comment: "Accessibility label of the status quick-filter strip"))
        }
    }

    static func statusGlyph(_ value: String) -> ZPDFSymbol {
        switch value {
        case "open": .info
        case "inProgress": .history
        case "resolved", "accepted", "completed": .success
        case "rejected": .error
        case "cancelled": .close
        default: .clear
        }
    }

    static func statusTint(_ value: String) -> ZPDFColorToken {
        switch value {
        case "open": .accentBlue
        case "inProgress": .warning
        case "resolved", "accepted", "completed": .success
        case "rejected": .danger
        default: .textSecondary
        }
    }

    /// The hamburger options menu on the right of the header, per the mockup.
    private var optionsMenu: some View {
        Menu {
            groupingMenu
            if model.canManageColumns {
                Button {
                    model.openColumnManager()
                } label: {
                    Text(NSLocalizedString("Manage Columns…", comment: "Ledger options menu item: open the Column Manager"))
                }
            }
            Button {
                model.openProjectSummary()
            } label: {
                Text(NSLocalizedString("Whole Project Summary…", comment: "Ledger options menu item: every open drawing's totals together"))
            }
            .disabled(!model.canSummariseProject)
            if model.canUseRateLibrary {
                Button {
                    model.openRateLibrary()
                } label: {
                    Text(NSLocalizedString("Rate Library…", comment: "Ledger options menu item: the office rate library"))
                }
            }
            if model.canSnapshot {
                Button {
                    model.openSnapshots()
                } label: {
                    Text(NSLocalizedString("Snapshots and Changes…", comment: "Ledger options menu item: take snapshots and see what changed since"))
                }
            }
            if model.canExplain {
                Button {
                    model.explainSelection()
                } label: {
                    Text(NSLocalizedString("Explain Selection…", comment: "Ledger options menu item: show the rows, formula and scale behind the selected rows"))
                }
                .disabled(model.host.selectedRowIDs.isEmpty)
            }
            if model.canShowMatrix {
                Button {
                    model.openMatrix()
                } label: {
                    Text(NSLocalizedString("Summary Matrix…", comment: "Ledger options menu item: open the two-way summary matrix"))
                }
            }
            if model.canPlaceSummary {
                Button {
                    Task { await model.placeSummary(.quantities) }
                } label: {
                    Text(NSLocalizedString("Place Quantity Table on Sheet", comment: "Ledger options menu item: place a live quantity table on the current sheet"))
                }
                Button {
                    Task { await model.placeSummary(.countLegend) }
                } label: {
                    Text(NSLocalizedString("Place Count Legend on Sheet", comment: "Ledger options menu item: place a live count legend on the current sheet"))
                }
            }
            Button {
                model.openAssemblyPanel()
            } label: {
                Text(NSLocalizedString("Apply Assembly…", comment: "Ledger options menu item: apply an assembly to the selected rows"))
            }
            .disabled(!model.canApplyAssembly)
            Divider()
            Button {
                environment.perform(.collapseQuantityLedger)
            } label: {
                Text(panelState.isLedgerCollapsedToBar
                    ? NSLocalizedString("Expand", comment: "Ledger options menu item")
                    : NSLocalizedString("Collapse to Header", comment: "Ledger options menu item"))
            }
            .disabled(panelState.isLedgerDetached)
            Button {
                environment.perform(.detachQuantityLedger)
            } label: {
                Text(panelState.isLedgerDetached
                    ? NSLocalizedString("Dock in Window", comment: "Ledger options menu item")
                    : NSLocalizedString("Detach to Its Own Window", comment: "Ledger options menu item"))
            }
            Divider()
            // S-050: the item hides the surface on show, as the header's close control does. On
            // History it ran Toggle Quantity Ledger, which *revealed* the ledger — the pane stayed
            // open and only changed tab.
            Button {
                environment.perform(Self.hideMenuCommand(for: activeTab))
            } label: {
                Text(Self.hideMenuTitle(for: activeTab))
            }
        } label: {
            ZPDFGlyphView(.symbol(.options), size: ZPDFSpacing.Control.iconSmall)
                .frame(
                    width: ZPDFSpacing.Control.minimumHitTarget,
                    height: ZPDFSpacing.Control.minimumHitTarget
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(NSLocalizedString("Quantity Ledger options", comment: "Ledger hamburger help"))
        .accessibilityLabel(Text(NSLocalizedString(
            "Quantity Ledger options",
            comment: "Accessibility label for the ledger options menu"
        )))
    }

    /// The ledger package's virtualised table: the grouped `NSOutlineView` with
    /// collapsible per-type subtotal header rows by default, the flat `NSTableView` when
    /// the user chose "No Grouping".
    private var table: some View {
        LedgerTableRepresentable(host: model.host)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(model.host.accessibilitySummary)
    }

    /// The per-sheet switch, in the header rather than only under *Group by ▸ Page*.
    ///
    /// The two views are read against each other — a sheet's own quantities, then the
    /// document's — and a comparison that costs a menu walk in each direction is one nobody
    /// makes. The mockup's toggle: a constant "Per Sheet" label, on the selected fill with an
    /// accent edge while the summary is separated by sheet. The fill, the heavier label and
    /// the `isSelected` trait carry the state without relying on colour, and the help text
    /// names what pressing it will do. (It used to rename itself "All Sheets" as well, which
    /// said the state twice and made the button's name change under the pointer.)
    private var perSheetToggle: some View {
        let perSheet = model.isGroupedBySheet
        return ZPDFToolbarButton(
            glyph: .symbol(.perSheet),
            title: Self.perSheetTitle,
            showsTitle: true,
            isSelected: perSheet,
            helpText: perSheet
                ? NSLocalizedString(
                    "Combine every sheet into one summary for the whole document",
                    comment: "Help on the ledger per-sheet toggle while it is grouped by sheet")
                : NSLocalizedString(
                    "Separate the summary into one section per sheet",
                    comment: "Help on the ledger per-sheet toggle while the summary is combined")
        ) {
            model.toggleSheetGrouping()
        }
    }

    /// The Filter control. Its title carries the live match count when a filter is on, so
    /// a narrowed ledger states that it is narrowed even with the panel closed — the
    /// on-screen half of the same promise the exports make (QUALITY_BAR A35).
    /// Values kept under an older scale: shown whenever there are any, so a total that includes
    /// one never reads as current; a click narrows the ledger to them.
    @ViewBuilder
    private var olderScaleButton: some View {
        if let older = model.presenter as? any LedgerOlderScaleFiltering,
           older.olderScaleRowCount > 0 || older.showsOnlyOlderScaleValues {
            LedgerOlderScaleControl(filtering: older)
        }
    }

    private var filterButton: some View {
        ZPDFToolbarButton(
            glyph: .symbol(.filter),
            title: filterButtonTitle,
            showsTitle: true,
            isSelected: sidePanel == .filter,
            helpText: NSLocalizedString(
                "Build a rule tree that narrows the ledger, and save it by name",
                comment: "Help text for the ledger filter control"
            )
        ) {
            sidePanel = sidePanel == .filter ? .none : .filter
        }
    }

    private var filterButtonTitle: String {
        guard ledger.isFiltered else {
            return NSLocalizedString("Filter", comment: "Ledger header control: open the filter builder")
        }
        return String(
            format: NSLocalizedString(
                "Filter (%1$d of %2$d)",
                comment: "Ledger header control when a filter is active: matching rows, total rows"
            ),
            model.matchCount,
            model.totalCount
        )
    }

    /// The Bulk Edit control. Disabled, with the reason in its help text, when the pane is
    /// over a ledger that cannot be written to.
    private var bulkEditButton: some View {
        ZPDFToolbarButton(
            glyph: .symbol(.bulkEdit),
            title: bulkEditButtonTitle,
            showsTitle: true,
            isSelected: sidePanel == .bulkEdit,
            helpText: model.canBulkEdit
                ? NSLocalizedString(
                    "Change subject, label, status, colour and custom values across the whole selection, in one undoable step",
                    comment: "Help text for the ledger bulk edit control"
                )
                : NSLocalizedString(
                    "This ledger cannot be edited.",
                    comment: "Help text for the bulk edit control over a read-only ledger"
                )
        ) {
            sidePanel = sidePanel == .bulkEdit ? .none : .bulkEdit
        }
        .disabled(!model.canBulkEdit)
    }

    private var bulkEditButtonTitle: String {
        let count = ledger.selectedRowIDs.count
        guard count > 0 else {
            return NSLocalizedString("Bulk Edit", comment: "Ledger header control: open the bulk edit panel")
        }
        return String(
            format: NSLocalizedString(
                "Bulk Edit (%d)",
                comment: "Ledger header control with a selection: number of selected rows"
            ),
            count
        )
    }

    @ViewBuilder
    private var sidePanelContent: some View {
        switch sidePanel {
        case .filter:
            Self.filterBuilder(for: model)
        case .bulkEdit:
            // L-85: the outcome line is the panel's own, inside its scroll, above the Apply that
            // produced it. Drawn under the panel, it took its height from the fields' scroll after
            // every Apply, and a short docked pane squeezed the fields back out of reach.
            LedgerBulkEditPanel(
                model: model.bulkEdit,
                outcome: model.lastBulkEditReceipt.map { AnyView(bulkEditOutcome($0)) }
            )
        case .none:
            EmptyView()
        }
    }

    /// The filter side panel exactly as the pane shows it, wired to the pane's model.
    ///
    /// S-078: its columns are the model's ``LedgerPaneModel/filterColumns`` — every column the
    /// presenter has — never the columns on screen. Built here rather than inline in the body so
    /// a test can inspect the builder the pane really draws.
    static func filterBuilder(for model: LedgerPaneModel) -> LedgerFilterBuilder {
        LedgerFilterBuilder(
            columns: model.filterColumns,
            filter: Binding(
                get: { model.filter },
                set: { model.setFilter($0) }
            ),
            savedFilters: Binding(
                get: { model.savedFilters },
                set: { model.savedFilters = $0 }
            ),
            canvasBehavior: Binding(
                get: { model.canvasFilterBehavior },
                set: { model.setCanvasFilterBehavior($0) }
            ),
            matchCount: model.matchCount,
            totalCount: model.totalCount
        )
    }

    /// What the last bulk edit actually did, in one line, next to the panel that asked
    /// for it. A refusal is a warning; a success names the number of markups and the fact
    /// that one Cmd-Z takes all of it back, because that is the thing a reviewer needs to
    /// believe before they will use the feature on nineteen rows at a time.
    @ViewBuilder
    private func bulkEditOutcome(_ receipt: LedgerBulkEditReceipt) -> some View {
        HStack(alignment: .top, spacing: ZPDFSpacing.s) {
            if let failure = receipt.failureDescription {
                ZPDFInlineWarning(severity: .warning, message: failure)
            } else {
                Text(bulkEditSuccessText(receipt))
                    .zpdfText(.caption, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(NSLocalizedString("Dismiss", comment: "Clears the bulk edit outcome line")) {
                model.clearBulkEditReceipt()
            }
            .buttonStyle(.link)
        }
        .accessibilityElement(children: .combine)
    }

    private func bulkEditSuccessText(_ receipt: LedgerBulkEditReceipt) -> String {
        Self.bulkEditSuccessText(receipt)
    }

    /// The Bulk Edit outcome line: how many markups changed, in words that agree with the count.
    static func bulkEditSuccessText(_ receipt: LedgerBulkEditReceipt) -> String {
        guard !receipt.changedMarkupIDs.isEmpty else {
            return NSLocalizedString(
                "Nothing changed: every selected markup already held those values.",
                comment: "Bulk edit outcome when the edit was a no-op"
            )
        }
        let markups = LocalizedPlural.string(
            "%lld markups",
            count: receipt.changedMarkupIDs.count,
            one: NSLocalizedString("%lld markup", comment: "Count of markups, singular"),
            other: NSLocalizedString("%lld markups", comment: "Count of markups, plural")
        )
        return String(
            format: NSLocalizedString(
                "Changed %@. One Undo takes the whole change back.",
                comment: "Bulk edit outcome; the placeholder is a count of markups, e.g. 1 markup"
            ),
            markups
        )
    }

    /// Grouping choices: type is the default, every existing level
    /// stays available, and "No Grouping" remains the flat list. The choice persists.
    private var groupingMenu: some View {
        Menu {
            // NL-QTY-08: every groupable column, a person's own included, not six fixed ones.
            ForEach(model.groupableColumns) { option in
                Button {
                    model.setGrouping([option.column])
                } label: {
                    if model.groupingColumns == [option.column] {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
            if !model.groupingColumns.isEmpty {
                Divider()
                Menu {
                    ForEach(model.groupableColumns.filter { !model.groupingColumns.contains($0.column) }) { option in
                        Button(option.title) { model.addGroupingLevel(option.column) }
                    }
                } label: {
                    Text(NSLocalizedString("Then by", comment: "Ledger grouping menu: add a nested grouping level"))
                }
                if model.groupingColumns.count > 1 {
                    Button(String(
                        format: NSLocalizedString(
                            "Remove Level “%@”",
                            comment: "Ledger grouping menu: remove the innermost level; the level's title"
                        ),
                        model.groupingTitle(model.groupingColumns[model.groupingColumns.count - 1])
                    )) {
                        model.removeLastGroupingLevel()
                    }
                }
                // C-05: the grouped outline's own view choices, next to the grouping they act on.
                Divider()
                Button(NSLocalizedString("Expand All Groups", comment: "Ledger grouping menu: open every group")) {
                    model.expandAllGroups()
                }
                Button(NSLocalizedString("Collapse All Groups", comment: "Ledger grouping menu: fold every group to its heading row")) {
                    model.collapseAllGroups()
                }
                Toggle(
                    NSLocalizedString("Show Group Subtotals", comment: "Ledger grouping menu: subtotals on group heading rows"),
                    isOn: Binding(get: { model.showsSubtotals }, set: { model.setShowsSubtotals($0) })
                )
            }
            Divider()
            Button {
                model.setGrouping([])
            } label: {
                if model.groupingColumns.isEmpty {
                    Label(
                        NSLocalizedString("No Grouping", comment: "Ledger grouping menu: flat list"),
                        systemImage: "checkmark"
                    )
                } else {
                    Text(NSLocalizedString("No Grouping", comment: "Ledger grouping menu: flat list"))
                }
            }
        } label: {
            Text(groupingMenuTitle)
        }
    }

    /// "Group by", or "Group by: Page › Subject" when more than one level is on, so the menu
    /// says what the outline is nested by.
    private var groupingMenuTitle: String {
        let base = NSLocalizedString("Group by", comment: "Ledger options menu: grouping submenu")
        guard model.groupingColumns.count > 1 else { return base }
        return base + ": " + model.groupingColumns.map(model.groupingTitle).joined(separator: " › ")
    }

    private func headerRow(_ columns: [LedgerColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Text(column.title)
                    .zpdfText(.sectionHeader, .textSecondary)
                    .lineLimit(1)
                    .frame(
                        width: CGFloat(column.width),
                        alignment: alignment(column.alignment)
                    )
                    .padding(.horizontal, ZPDFSpacing.s)
            }
        }
        .frame(minHeight: ZPDFSpacing.Control.panelHeader)
        // The same ground as the AppKit table's header band (LedgerTableHeaderView), so the
        // empty and loading states show the header the rows will arrive under.
        .background(ZPDFColor.surface)
        .overlay(alignment: .bottom) { ZPDFHairlineDivider(axis: .horizontal) }
    }

    /// Feature 19 — the count-symbol legend: which symbol counts which subject, and how
    /// many marks stand. Text, never tint, and derived from placed marks — a preset edited
    /// after placement changes nothing here. Absent when nothing carries a symbol.
    @ViewBuilder
    private var symbolLegend: some View {
        if let rows = environment.countSymbolLegend?(), !rows.isEmpty {
            ZPDFHairlineDivider(axis: .horizontal)
            HStack(spacing: ZPDFSpacing.l) {
                Text(NSLocalizedString("Legend:", comment: "Ledger count-symbol legend label"))
                    .zpdfText(.caption.withWeight(.semibold), .textSecondary)
                ForEach(rows) { row in
                    Text(String(
                        format: NSLocalizedString(
                            "%@ — %@ ×%d",
                            comment: "One legend entry: subject, symbol name, mark count"
                        ),
                        row.subject, row.symbolName, row.markCount
                    ))
                    .zpdfText(.caption, .textPrimary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZPDFSpacing.m)
            .padding(.vertical, ZPDFSpacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(NSLocalizedString(
                "Count symbol legend",
                comment: "Accessibility label for the ledger's symbol legend"
            )))
        }
    }

    /// IM-215: the close control's help names the shortcut only when there is one; with no
    /// binding it read "Closes the pane.  brings it back".
    /// The options menu's last item hides the tab on show: the History tab's own command on
    /// History, the ledger's on Quantities (S-050).
    static func hideMenuCommand(for tab: PaneTab) -> ZPDFCommandID { tab.surface.command }

    /// "Hide Quantity Ledger" or "Hide History", after the tab on show (S-050).
    static func hideMenuTitle(for tab: PaneTab) -> String {
        String(
            format: NSLocalizedString("Hide %@", comment: "Ledger options menu item: hide the bottom pane surface on show; the surface"),
            tab.surface.displayName
        )
    }

    static func closeHelp(shortcut: String?) -> String {
        guard let shortcut, !shortcut.isEmpty else {
            return NSLocalizedString(
                "Closes the pane. The ear at the bottom edge brings it back.",
                comment: "Help on the bottom pane's close control when its command has no shortcut"
            )
        }
        return String(
            format: NSLocalizedString(
                "Closes the pane. %@ brings it back, and so does the ear at the bottom edge.",
                comment: "Help on the bottom pane's close control, naming the way back"
            ),
            shortcut
        )
    }

    /// IM-122 / IM-123: the totals label says when it totals a filtered subset.
    static func totalsLabel(isFiltered: Bool, matchCount: Int, totalCount: Int) -> String {
        guard isFiltered else {
            return NSLocalizedString("Totals", comment: "Ledger totals row label")
        }
        return String(
            format: NSLocalizedString(
                "Totals (filtered: %1$d of %2$d rows)",
                comment: "Ledger totals row label while a filter is active: matching rows, all rows"
            ),
            matchCount, totalCount
        )
    }

    private var totalsRow: some View {
        let totals = ledger.grandTotals
        let label = Self.totalsLabel(
            isFiltered: ledger.isFiltered, matchCount: model.matchCount, totalCount: model.totalCount
        )
        // IM-123: many aggregate columns scroll sideways instead of clipping at a narrow width.
        return ScrollView(.horizontal) {
            HStack(spacing: ZPDFSpacing.l) {
                HStack(spacing: ZPDFSpacing.xs) {
                    if ledger.isFiltered {
                        ZPDFGlyphView(.symbol(.search), size: ZPDFSpacing.Control.iconSmall)
                            .foregroundStyle(ZPDFColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(label).zpdfText(.sectionHeader, .textSecondary)
                }
                ForEach(ledger.visibleColumns.filter { $0.aggregate != nil }) { column in
                    HStack(spacing: ZPDFSpacing.xs) {
                        Text(column.title).zpdfText(.caption, .textSecondary)
                        Text(totals.displayValue(column.id)).zpdfText(.monoNumericStrong, .textPrimary)
                    }
                }
            }
            .padding(.horizontal, ZPDFSpacing.m)
        }
        .scrollIndicators(.automatic)
        .frame(minHeight: ZPDFSpacing.Control.listRow)
        .background(ZPDFColor.elevated)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
    }

    private func alignment(_ value: LedgerColumnAlignment) -> Alignment {
        switch value {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// One sentence a screen-reader user hears on entering the pane, instead of having to
    /// walk every row to find out how big the takeoff is.
    private var screenReaderSummary: String {
        let format = NSLocalizedString(
            "%1$d rows, %2$d columns shown",
            comment: "Screen-reader summary of the Quantity Ledger"
        )
        return String(format: format, ledger.rowCount, ledger.visibleColumns.count)
    }
}

#if DEBUG
struct QuantityLedger_Previews: PreviewProvider {
    static var previews: some View {
        QuantityLedgerPane(environment: .mock(), panelState: ShellPanelState())
            .frame(width: 900, height: 260)
    }
}
#endif
