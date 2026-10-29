import Foundation
import Observation
import ZPDFUILedger
import ZPDFUIPresentation

/// Owns the docked Quantity Ledger's table and its persisted view choices.
///
/// The pane view stays declarative: this object builds the ledger package's
/// `LedgerTableHost` (the grouped `NSOutlineView`) over the
/// presenter, restores the persisted grouping, collapsed state and subtotal visibility, and
/// routes selection, activation and sorting back through the presenter, without the pane
/// having to be an `NSViewController` itself.
@MainActor
@Observable
public final class LedgerPaneModel {

    /// The ledger package's table host: grouped outline or flat table.
    @ObservationIgnored public let host: LedgerTableHost

    /// The active grouping levels, outermost first. Empty is the flat list.
    public private(set) var groupingColumns: [LedgerColumnID]

    /// The user's named filters, restored from and written back to the preferences.
    public var savedFilters: LedgerSavedFilterStore {
        didSet {
            guard savedFilters != oldValue else { return }
            preferences.savedFilters = savedFilters
        }
    }

    /// The bulk-edit panel's model, kept in step with the table's selection.
    @ObservationIgnored public let bulkEdit: LedgerBulkEditModel

    /// The outcome of the last applied bulk edit, so the panel can state what happened
    /// rather than leaving the reviewer to check nineteen rows by eye.
    public private(set) var lastBulkEditReceipt: LedgerBulkEditReceipt?

    /// Non-`nil` while the ledger is asking what to call the layout being saved.
    ///
    /// "Save Layout…" in the column header menu called
    /// `LedgerTableHost.onSaveLayoutRequested` (`LedgerColumnMenuBuilder.swift:185`) and
    /// nothing installed it, so the menu item did nothing at all — and because saved layouts
    /// were the only source of the menu's "Apply Layout" list, that list could never fill.
    /// This is the state the naming prompt is bound to; ``saveLayout(named:)`` completes it
    /// and ``cancelLayoutNaming()`` abandons it.
    public var pendingLayoutName: String?

    /// The open Column Manager (NL-QTY-02), or `nil`. The pane's sheet is bound to this, so a
    /// test drives the manager through the model and nothing presents itself unasked.
    public var columnManager: LedgerColumnManagerModel?

    /// The open Apply Assembly panel (NL-QTY-07), or `nil`; the pane's sheet is bound to it.
    public var assemblyPanel: LedgerAssemblyPanelModel?

    @ObservationIgnored let presenter: any LedgerPresenting
    @ObservationIgnored private let preferences: LedgerPanePreferences

    /// The grouping in force before ``toggleSheetGrouping()`` last switched per-sheet on.
    ///
    /// Deliberately not persisted: this is the undo of one button press, not a view choice.
    /// A restore that outlived the session would drop a person into a grouping they last saw
    /// days ago, which the persisted ``LedgerPanePreferences/groupingColumns`` already covers.
    @ObservationIgnored private var groupingBeforeSheetToggle: [LedgerColumnID]?

    /// One grouping choice in the pane's menu.
    public struct GroupingOption: Identifiable, Hashable, Sendable {
        /// The column to group by.
        public let column: LedgerColumnID
        /// The menu title.
        public let title: String
        /// Stable identity.
        public var id: LedgerColumnID { column }
    }

    /// The grouping levels the pane offers, matching the ledger screen's grouping
    /// vocabulary. Type leads because it is the default.
    public static var groupingOptions: [GroupingOption] {
        [
            GroupingOption(column: .icon, title: NSLocalizedString(
                "Type", comment: "Ledger grouping menu: group by measurement type")),
            GroupingOption(column: .subject, title: NSLocalizedString(
                "Subject", comment: "Ledger grouping menu: group by subject")),
            GroupingOption(column: .label, title: NSLocalizedString(
                "Label", comment: "Ledger grouping menu: group by label")),
            GroupingOption(column: .pageLabel, title: NSLocalizedString(
                "Page", comment: "Ledger grouping menu: group by page")),
            GroupingOption(column: .projectZone, title: NSLocalizedString(
                "Project Zone", comment: "Ledger grouping menu: group by Project Zone")),
            GroupingOption(column: .status, title: NSLocalizedString(
                "Status", comment: "Ledger grouping menu: group by review status"))
        ]
    }

    /// Creates the model over a presenter, restoring the persisted view choices.
    public init(
        presenter: any LedgerPresenting,
        preferences: LedgerPanePreferences = LedgerPanePreferences(),
        subtotalRounding: LedgerRounding = .twoDigits
    ) {
        self.presenter = presenter
        self.preferences = preferences
        let source = LedgerPresenterRowSource(presenter: presenter)
        // BH-814: a stored grouping column this ledger does not have put every row in one
        // blank-headed group with no message; unknown columns are dropped.
        let grouping = Self.validatedGrouping(
            preferences.groupingColumns,
            known: Set(presenter.columns.map(\.id)).union(Self.groupingOptions.map(\.column))
        )
        self.groupingColumns = grouping
        self.savedFilters = preferences.savedFilters
        self.bulkEdit = LedgerBulkEditModel(rows: [], columns: presenter.columns)
        self.host = LedgerTableHost(
            rowSource: source,
            mode: grouping.isEmpty ? .flat : .grouped,
            groupingColumns: grouping
        )
        // The group's merged total is what a screen reader announces for a heading row.
        host.controller.headlineTotalColumn = LedgerDefaultColumns.valueColumnID
        // Header subtotals display with the precision in force when the pane is built —
        // display rounding only, the exact totals are untouched. BH-295: the pane passes the
        // session's precision here, so a pane that mounts after the first projection does
        // not keep two digits until some later edit.
        // C-05: through the host, so its observable `rounding` (the summary chips read it)
        // agrees with the table from the first frame.
        host.setRounding(subtotalRounding)
        // C-05: a person who hid the group subtotals keeps them hidden across relaunches.
        host.setShowsSubtotals(preferences.showsSubtotals)
        // BH-705: a layout applied from the header menu — or removed
        // there — persists like one saved through the prompt.
        host.controller.onLayoutStoreChange = { [preferences] store in preferences.columnLayouts = store }
        // The header menu's "Apply Layout" submenu reads this store. Restoring it here is
        // what makes a layout saved in one session reachable in the next, and the table
        // reopens in the active layout the menu ticks (S-082).
        host.controller.restoreLayoutStore(preferences.columnLayouts)
        // W-029: a job template is captured from and applied to the table's own arrangement,
        // which the presenter's columns do not carry.
        (presenter as? any LedgerTableArrangementHosting)?.tableArrangement = LedgerTableArrangement(
            read: { [weak host = self.host] in host?.controller.columns ?? [] },
            apply: { [weak host = self.host] in host?.controller.setColumns($0) }
        )
        wire()
    }

    private func wire() {
        let presenter = self.presenter
        host.onSelectionChange = { [weak self] ids in
            presenter.select(rowIDs: ids, additive: false)
            self?.adoptSelectionIntoBulkEdit(ids)
        }
        // Apply is one call into the presenter's bulk-edit seam, which the app tier backs
        // with `DocumentCommandBus.performBatch`: one undo entry, one audit group. The
        // pane never constructs a document command of its own.
        bulkEdit.onApply = { [weak self] values, color, markupIDs in
            self?.applyBulkEdit(values: values, color: color, markupIDs: markupIDs)
        }
        // Return or a double click jumps to the markup; the app tier routes the ledger
        // selection into the canvas, so activation is a selection with intent.
        host.onActivate = { id in
            presenter.select(rowIDs: [id], additive: false)
        }
        host.onSort = { [weak self] columnID, ascending in
            presenter.sort(by: columnID, ascending: ascending)
            self?.refresh()
        }
        // IM-099: the header's secondary sort levels reach the
        // presenter; the host prefers this hook over `onSort` when it is set.
        host.onSortDescriptors = { [weak self] levels in
            presenter.sort(by: levels)
            self?.refresh()
        }
        let preferences = self.preferences
        host.onCollapsedGroupPathsChange = { paths in
            preferences.collapsedGroupPaths = paths
        }
        host.setCollapsedGroupPaths(preferences.collapsedGroupPaths)
        // The fifth of the host's five hooks. The
        // other four are installed above; this one was left out, so Save Layout… was a menu
        // item a person could pick with no effect of any kind.
        host.onSaveLayoutRequested = { [weak self] in
            self?.beginLayoutNaming()
        }
        // NL-QTY-02: "Add Column…" and "Manage Columns…" in the header menu, only when the
        // presenter can actually change columns.
        if presenter is any LedgerColumnManaging {
            host.onManageColumnsRequested = { [weak self] adding in
                self?.openColumnManager(addingNew: adding)
            }
        }
        // NL-QTY-04: a number typed into a cell that cannot become a value is said in the
        // pane, instead of the system alert sound, and the cell keeps its value.
        host.controller.onInlineEditRejected = { [weak self] column in
            self?.paneNotice = column.kind == .currency && column.dimension?.currencyCode == nil
                ? String(format: NSLocalizedString(
                    "“%@” has no currency, so the amount was not stored.",
                    comment: "Quantity Ledger notice: a typed amount in a money column without a currency"
                ), column.title)
                : String(format: NSLocalizedString(
                    "“%@” takes a number. The cell was not changed.",
                    comment: "Quantity Ledger notice: text typed into a number cell"
                ), column.title)
        }
        // IM-013: an inline cell edit is a one-markup bulk edit through
        // the presenter's seam — one undo entry, one audit entry.
        host.onCommitInlineEdit = { [weak self] request in
            self?.applyBulkEdit(
                values: request.values, color: request.color, markupIDs: request.markupIDs, fromPanel: false
            )
        }
    }

    // MARK: - Column Manager (NL-QTY-02)

    /// Whether the ledger's columns can be added, renamed, retyped and deleted here.
    public var canManageColumns: Bool { presenter is any LedgerColumnManaging }

    /// Opens the Column Manager, optionally straight onto a new column.
    public func openColumnManager(addingNew: Bool = false) {
        guard let managing = presenter as? any LedgerColumnManaging else { return }
        let manager = LedgerColumnManagerModel(presenter: managing)
        if addingNew { manager.beginAdd(kind: .text) }
        columnManager = manager
    }

    /// Closes the Column Manager and redraws the table over the columns it left.
    public func closeColumnManager() {
        columnManager = nil
        refresh()
    }

    // MARK: - Whole-project summary (NL-QTY-15)

    /// The open whole-project summary, or `nil`; the pane's sheet is bound to it.
    public var projectSummaryPanel: LedgerProjectSummaryModel?

    /// The open "Explain" panel, or `nil`; the pane's sheet is bound to it.
    public var explainPanel: LedgerExplainModel?
    /// Reveals a markup on the canvas from the Explain panel; set when the pane knows its window.
    @ObservationIgnored var explainShow: (@MainActor (UUID) -> Void)?

    /// Whether other drawings are open to summarise with this one.
    public var canSummariseProject: Bool {
        (presenter as? any LedgerProjectSummarizing)?.hasProjectSources ?? false || batchSummary != nil
    }

    /// NL-QTY-15 phase 2: the batch-over-closed-projects hooks, from the window's environment.
    @ObservationIgnored var batchSummary: (@MainActor () async -> LedgerBatchSummary?)?
    @ObservationIgnored var exportBatchSummary: (@MainActor (LedgerBatchSummary) -> Void)?
    /// NL-QTY-07 round 2: the office recipe library's import and export, from the environment.
    @ObservationIgnored var importAssemblyRecipes: (@MainActor () async -> [LedgerAssemblySummary]?)?
    @ObservationIgnored var exportAssemblyRecipes: (@MainActor () -> Void)?

    /// Opens the whole-project summary.
    public func openProjectSummary() {
        let summarizing = presenter as? any LedgerProjectSummarizing
        guard summarizing != nil || batchSummary != nil else { return }
        let panel = LedgerProjectSummaryModel(presenter: summarizing)
        panel.runBatch = batchSummary
        panel.exportBatch = exportBatchSummary
        projectSummaryPanel = panel
    }

    /// Closes the whole-project summary.
    public func closeProjectSummary() { projectSummaryPanel = nil }

    // MARK: - Rate library (NL-QTY-05)

    /// The open rate library, or `nil`; the pane's sheet is bound to it.
    public var rateLibraryPanel: LedgerRateLibraryModel?

    /// Whether the ledger has a rate library.
    public var canUseRateLibrary: Bool { presenter is any LedgerRateLibraryManaging }

    /// Opens the rate library over the selected rows.
    public func openRateLibrary() {
        guard let library = presenter as? any LedgerRateLibraryManaging else { return }
        let panel = LedgerRateLibraryModel(presenter: library, markupIDs: host.selectedRowIDs)
        // V-062: a removal written as the sheet closes (Escape, the window) and refused is
        // said in the pane — the sheet's own warning is gone by then.
        panel.onRemovalFailedAfterClose = { [weak self] failure in self?.paneNotice = failure }
        rateLibraryPanel = panel
    }

    /// Closes the rate library and redraws the priced rows.
    public func closeRateLibrary() {
        rateLibraryPanel = nil
        refresh()
    }

    // MARK: - Snapshots (NL-QTY-16)

    /// The open snapshots panel, or `nil`; the pane's sheet is bound to it.
    public var snapshotsPanel: LedgerSnapshotsModel?

    /// Whether the ledger can take snapshots.
    public var canSnapshot: Bool { presenter is any LedgerSnapshotting }

    /// Opens the snapshots panel.
    public func openSnapshots() {
        guard let snapshotting = presenter as? any LedgerSnapshotting else { return }
        snapshotsPanel = LedgerSnapshotsModel(presenter: snapshotting)
    }

    /// Closes the snapshots panel.
    public func closeSnapshots() { snapshotsPanel = nil }

    // MARK: - Summary matrix (NL-QTY-09)

    /// The open summary matrix, or `nil`; the pane's sheet is bound to it.
    public var matrixPanel: LedgerMatrixModel?

    /// Whether the ledger can build a summary matrix.
    public var canShowMatrix: Bool { presenter is any LedgerMatrixProviding }

    /// Opens the matrix: the current outer grouping (or Subject) down, Page across.
    public func openMatrix() {
        guard let provider = presenter as? any LedgerMatrixProviding else { return }
        let options = groupableColumns.map { LedgerMatrixModel.Option(column: $0.column, title: $0.title) }
        let rows = groupingColumns.first ?? .subject
        let columns: LedgerColumnID = rows == .pageLabel ? .icon : .pageLabel
        matrixPanel = LedgerMatrixModel(presenter: provider, options: options, rows: rows, columns: columns)
    }

    /// Closes the matrix.
    public func closeMatrix() { matrixPanel = nil }

    // MARK: - Live summaries on the sheet (NL-QTY-10)

    /// A one-line outcome the pane shows above the table until dismissed — a summary placed, or
    /// why it was not.
    public var paneNotice: String?

    /// Whether the ledger can place live summaries on the sheet.
    public var canPlaceSummary: Bool { presenter is any LedgerSummaryPlacing }

    /// Places a live summary of `kind` on the current sheet — grouped and filtered as the
    /// ledger is now — and says what happened.
    public func placeSummary(_ kind: LedgerSummaryPlacementKind) async {
        guard let placing = presenter as? any LedgerSummaryPlacing else { return }
        let receipt = await placing.placeSummary(kind)
        paneNotice = receipt.failureDescription ?? (kind == .quantities
            ? NSLocalizedString(
                "A live quantity table is on the sheet. It updates as you measure, and says when the ledger is filtered.",
                comment: "Quantity Ledger notice after placing a live quantity table"
            )
            : NSLocalizedString(
                "A live count legend is on the sheet. It updates as you count.",
                comment: "Quantity Ledger notice after placing a live count legend"
            ))
    }

    // MARK: - Assemblies (NL-QTY-07)

    /// Whether assemblies can be applied here, and there is a selection to apply one to.
    public var canApplyAssembly: Bool {
        presenter is any LedgerAssemblyApplying && !host.selectedRowIDs.isEmpty
    }

    /// Opens the Apply Assembly panel over the selected rows.
    public func openAssemblyPanel() {
        guard let applying = presenter as? any LedgerAssemblyApplying, !host.selectedRowIDs.isEmpty else { return }
        // U-064: length inputs are typed in the unit the ledger shows, as in the Tool Library.
        let panel = LedgerAssemblyPanelModel(
            presenter: applying, markupIDs: host.selectedRowIDs, lengthUnit: host.unitPolicy.length
        )
        panel.importRecipes = importAssemblyRecipes
        panel.exportRecipes = exportAssemblyRecipes
        assemblyPanel = panel
    }

    /// Closes the panel and redraws the rows it derived.
    public func closeAssemblyPanel() {
        assemblyPanel = nil
        refresh()
    }

    // MARK: - Status quick filters (NL-QTY-17)

    /// One chip per status the ledger holds, counted over every row before any filter.
    public var statusCounts: [LedgerStatusCount] {
        (presenter as? any LedgerStatusCounting)?.statusCounts ?? []
    }

    /// Whether the filter narrows to `status` through a chip.
    public func isStatusChipActive(_ status: String) -> Bool {
        chipStatuses(in: presenter.filter).contains(status)
    }

    /// Turns a status chip on or off. A chip is an honest filter: it is a Status "is any of"
    /// rule at the top of the filter tree, so the Filter button counts it and the builder
    /// shows it, and every other rule the person set stays as it was.
    public func toggleStatusChip(_ status: String) {
        let group = presenter.filter
        var statuses = chipStatuses(in: group)
        if let index = statuses.firstIndex(of: status) {
            statuses.remove(at: index)
        } else {
            statuses.append(status)
        }
        let rule = statuses.isEmpty ? nil : LedgerFilterRule(
            id: UUID(), column: .status, comparison: .isAnyOf, operand: .choices(statuses)
        )
        setFilter(Self.placingChipRule(rule, in: group, replacing: Self.isChipRule))
    }

    /// The filter with one chip's rule placed where it narrows, and every earlier rule of that
    /// chip taken out (R-077).
    ///
    /// A chip rule lives at the top of the tree only when the top is a plain "Match all" group.
    /// Under a "Match any" or negated top the chip used to be OR-ed in — widening the filter its
    /// help says it narrows — and, since the chip read itself only from a plain top, it never
    /// showed as on and could not be turned off; it also removed a Status rule the person wrote
    /// in that "any" group. Now such a tree is wrapped, untouched, in a "Match all" group that
    /// carries the chip rules beside it; when the last chip goes, the wrapper goes too and the
    /// person's own filter is back exactly as it was.
    static func placingChipRule(
        _ rule: LedgerFilterRule?,
        in filter: LedgerFilterGroup,
        replacing isChip: (LedgerFilterRule) -> Bool
    ) -> LedgerFilterGroup {
        var root = filter
        if root.conjunction != .all || root.isNegated {
            root = LedgerFilterGroup(id: UUID(), conjunction: .all, groups: [filter])
        }
        root.rules.removeAll(where: isChip)
        if let rule { root.rules.append(rule) }
        // A plain "Match all" holding nothing but one group that is not itself plain is the
        // wrapper above with no chip left in it: it is that group, and the group comes back.
        if root.rules.isEmpty, root.groups.count == 1,
           let inner = root.groups.first, inner.conjunction != .all || inner.isNegated {
            return inner
        }
        return root
    }

    // MARK: - Kind chips (NL-UX-09)

    /// The quantity kind a summary chip is filtering to, or `nil`. A kind chip is an honest
    /// filter like a status chip: a "<quantity column> has a value" rule at the top of the
    /// filter tree — Plan Area for Areas, Plan Length for Lengths, Count for Counts — so the
    /// Filter button counts it ("Filter (n of m)") and the builder shows it.
    public var activeKindChip: LedgerSummary.Kind? {
        let group = presenter.filter
        guard group.conjunction == .all, !group.isNegated else { return nil }
        for rule in group.rules {
            if let kind = Self.kindChip(of: rule) { return kind }
        }
        return nil
    }

    /// Turns a kind chip on (replacing another kind chip) or off. The Markups chip — every row —
    /// clears the kind filter. Every other rule stays as it was.
    public func toggleKindChip(_ kind: LedgerSummary.Kind) {
        let wasActive = activeKindChip == kind
        let rule = wasActive ? nil : kind.totalColumn.map {
            LedgerFilterRule(id: UUID(), column: $0, comparison: .isNotEmpty, operand: .none)
        }
        // R-077: placed where it narrows, as a status chip is.
        setFilter(Self.placingChipRule(rule, in: presenter.filter) { Self.kindChip(of: $0) != nil })
    }

    /// The kind chip a rule is, or `nil`. A rule switched off in the filter builder is not in
    /// force, so it lights no chip (S-052) — the status chip's rule (`isChipRule`) already said so.
    static func kindChip(of rule: LedgerFilterRule) -> LedgerSummary.Kind? {
        guard rule.comparison == .isNotEmpty, rule.isEnabled else { return nil }
        return LedgerSummary.Kind.allCases.first { $0.totalColumn == rule.column }
    }

    private func chipStatuses(in group: LedgerFilterGroup) -> [String] {
        guard group.conjunction == .all, !group.isNegated else { return [] }
        for rule in group.rules where Self.isChipRule(rule) {
            if case let .choices(values) = rule.operand { return values }
        }
        return []
    }

    private static func isChipRule(_ rule: LedgerFilterRule) -> Bool {
        rule.column == .status && rule.comparison == .isAnyOf && rule.isEnabled
    }

    // MARK: - Grouping levels (NL-QTY-08)

    /// Every column the ledger can group by: Type, then each text, choice, date or checkbox
    /// column the presenter has — built-in or a person's own — in ledger order.
    public var groupableColumns: [GroupingOption] {
        var options = [Self.groupingOptions[0]]
        var seen: Set<LedgerColumnID> = [.icon]
        for column in presenter.columns where !seen.contains(column.id) {
            guard !LedgerDefaultColumns.isDisplayColumn(column.id), Self.groups(column) else { continue }
            seen.insert(column.id)
            options.append(GroupingOption(column: column.id, title: column.title))
        }
        return options
    }

    /// Whether a column's values make sensible group headings: words, options, days and
    /// yes/no — never a measured quantity, a colour swatch or free-form notes.
    public static func groups(_ column: LedgerColumn) -> Bool {
        guard column.id != .color, column.id != .comment else { return false }
        switch column.kind {
        case .text, .choice, .date, .checkbox: return true
        case .number, .currency, .formula: return false
        }
    }

    /// The title of a grouping level, for the menu and the pane's "Sheet › Subject" line.
    public func groupingTitle(_ column: LedgerColumnID) -> String {
        groupableColumns.first { $0.column == column }?.title
            ?? presenter.columns.first { $0.id == column }?.title
            ?? column.rawValue
    }

    /// Adds a nested level under the current grouping ("then by"). A column already grouped
    /// on is not added twice.
    public func addGroupingLevel(_ column: LedgerColumnID) {
        guard !groupingColumns.contains(column) else { return }
        setGrouping(groupingColumns + [column])
    }

    /// Removes the innermost grouping level.
    public func removeLastGroupingLevel() {
        guard !groupingColumns.isEmpty else { return }
        setGrouping(Array(groupingColumns.dropLast()))
    }

    // MARK: - Saved column layouts

    /// Opens the naming prompt with a suggested name.
    ///
    /// The suggestion is "Layout 1", "Layout 2", … rather than the active layout's name: a
    /// Save that silently overwrote the arrangement the person started from would be a worse
    /// outcome than one more entry in a list they can delete.
    public func beginLayoutNaming() {
        let existing = host.controller.layoutStore.layouts.count
        var candidate = existing + 1
        var suggestion = Self.layoutName(candidate)
        while host.controller.layoutStore.layout(named: suggestion) != nil, candidate < existing + 100 {
            candidate += 1
            suggestion = Self.layoutName(candidate)
        }
        pendingLayoutName = suggestion
    }

    /// Abandons the naming prompt without saving anything.
    public func cancelLayoutNaming() {
        pendingLayoutName = nil
    }

    /// Saves the table's current column arrangement under a name and persists it.
    ///
    /// An empty or whitespace-only name saves nothing and leaves the prompt open, because
    /// silently discarding the request is the defect this whole entry is about. Returns the
    /// layout that was written, or `nil` when the name was refused.
    @discardableResult
    public func saveLayout(named name: String, replacingExisting: Bool = false) -> LedgerColumnLayout? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // BH-815: an empty name used to vanish without a word — the prompt closes anyway,
        // so the outcome is said in the pane instead.
        guard !trimmed.isEmpty else {
            layoutSaveMessage = NSLocalizedString(
                "The layout was not saved: it needs a name.",
                comment: "Quantity Ledger message when Save Layout is confirmed with an empty name"
            )
            pendingLayoutName = nil
            return nil
        }
        var store = host.controller.layoutStore
        // BH-812: typing an existing name silently replaced that layout.
        if !replacingExisting, let existing = store.layout(named: trimmed) {
            layoutSaveMessage = String(
                format: NSLocalizedString(
                    "A layout called “%@” already exists. Save again under another name, or delete the old one first.",
                    comment: "Quantity Ledger message when Save Layout names an existing layout"
                ),
                existing.name
            )
            pendingLayoutName = nil
            return nil
        }
        guard let layout = store.save(host.columns, name: trimmed) else { return nil }
        host.controller.layoutStore = store
        preferences.columnLayouts = store
        layoutSaveMessage = String(
            format: NSLocalizedString(
                "Saved the column layout “%@”.",
                comment: "Quantity Ledger confirmation after a column layout is saved"
            ),
            layout.name
        )
        pendingLayoutName = nil
        return layout
    }

    /// The outcome of the last Save Layout, shown in the pane until dismissed (BH-815).
    public var layoutSaveMessage: String?

    /// Clears ``layoutSaveMessage``.
    public func clearLayoutSaveMessage() {
        layoutSaveMessage = nil
        paneNotice = nil
    }

    private static func layoutName(_ index: Int) -> String {
        String(
            format: NSLocalizedString(
                "Layout %d",
                comment: "Suggested name for a newly saved Quantity Ledger column layout"
            ),
            index
        )
    }

    /// Replaces the grouping, persists the choice, and regroups the table.
    ///
    /// An empty set is the flat list — a stored choice of its own, not a fallback.
    public func setGrouping(_ columns: [LedgerColumnID]) {
        // BH-813: a regroup from the menu (or from Project Zones) is the grouping the
        // per-sheet toggle must come back to, not whatever it remembered before.
        groupingBeforeSheetToggle = nil
        applyGrouping(columns)
    }

    private func applyGrouping(_ columns: [LedgerColumnID]) {
        groupingColumns = columns
        preferences.groupingColumns = columns
        host.setGrouping(columns)
        publishOnScreenColumns()
        // IM-027: the presenter learns the on-screen grouping, so "Export as on screen"
        // exports the grouping the person is looking at. For a presenter that supplies its
        // own outline, host.setGrouping has already handed it this grouping through the row
        // source (IM-011); asking again only cost a superseded rebuild, so ask only when the
        // presenter does not have it yet (a flat regroup, or a presenter without an outline).
        if presenter.groupingColumns != columns {
            presenter.setGrouping(columns)
        }
    }

    /// The table's visible columns in on-screen order — what an "as on screen" export should
    /// carry (IM-027; the export request itself is built in the app tier).
    public var onScreenColumnOrder: [LedgerColumnID] {
        host.columns.filter(\.visible).map(\.id)
    }

    /// Drops grouping columns the ledger does not know, falling back to the default grouping
    /// when nothing survives (BH-814).
    static func validatedGrouping(_ stored: [LedgerColumnID], known: Set<LedgerColumnID>) -> [LedgerColumnID] {
        guard !stored.isEmpty else { return stored }
        let valid = stored.filter { known.contains($0) }
        return valid.isEmpty ? LedgerDefaultColumns.defaultGroupingColumns : valid
    }

    /// Whether the ledger is split into one section per sheet.
    ///
    /// Exactly `[.pageLabel]`, never a merely page-outermost multi-level grouping: the header
    /// toggle owns only the state it can put back, and `[.pageLabel, .subject]` is not it.
    public var isGroupedBySheet: Bool { groupingColumns == [.pageLabel] }

    /// Switches between the per-sheet summary and the combined whole-document view.
    ///
    /// Switching off restores the grouping that was in force before, not the flat list: the
    /// per-sheet view is a detour taken while reading some other grouping, and a return that
    /// discarded where it came from would cost a menu walk back. With nothing remembered —
    /// the pane reopened on a persisted `[.pageLabel]` — the flat list is the combined view.
    public func toggleSheetGrouping() {
        if isGroupedBySheet {
            let restored = groupingBeforeSheetToggle ?? []
            groupingBeforeSheetToggle = nil
            applyGrouping(restored)
        } else {
            let before = groupingColumns
            applyGrouping([.pageLabel])
            groupingBeforeSheetToggle = before
        }
    }

    /// Re-reads the presenter's rows after they changed shape or content. The reload also
    /// re-reads the presenter's columns, so a column added, renamed, hidden or deleted in the
    /// Column Manager reaches the table (S-075).
    public func refresh() {
        refreshPending = false
        host.reload()
        planRebuildCount += 1
        publishOnScreenColumns()
    }

    /// IM-027: the presenter learns the on-screen column order for an "as on screen" export.
    private func publishOnScreenColumns() {
        let order = onScreenColumnOrder
        if presenter.onScreenColumnOrder != order { presenter.onScreenColumnOrder = order }
    }

    /// BH-732: group-header subtotals are printed in the document's
    /// display units, not in metres over rows shown in millimetres or feet.
    public func setSubtotalUnitPolicy(_ policy: LedgerUnitPolicy) {
        guard host.unitPolicy != policy else { return }
        host.setUnitPolicy(policy)
    }

    /// How many full plan rebuilds the pane has asked for — what the coalescing tests count.
    public private(set) var planRebuildCount = 0

    @ObservationIgnored private var refreshPending = false

    /// Asks for one refresh on the next main-actor turn, however many triggers fire in this
    /// one (IM-029). One projection swap moves the revision, the row count, the totals and the
    /// loading flag together; each used to cost a full rebuild.
    public func requestRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            guard let self, self.refreshPending else { return }
            self.refresh()
        }
    }

    /// Keeps the group-subtotal rounding aligned with the active display precision.
    ///
    /// The init default of two digits matched the core's default rendering; once the
    /// inspector's Precision popup can change that, a fixed subtotal rounding shows
    /// "5,50" over children reading "5,502" (found 2026-08-24 while verifying ledger hydration).
    /// Display rounding only — the exact totals are untouched.
    ///
    /// C-05: goes through `LedgerTableHost.setRounding`, which redraws the rows (IM-214: the
    /// plan is kept) and moves the host's observable `rounding` with the table. Writing the
    /// controller directly left that mirror on the old precision, so the summary chips kept
    /// printing "12.35 m" after the rows had moved to three decimals.
    public func setSubtotalRounding(_ rounding: LedgerRounding) {
        host.setRounding(rounding)
    }

    /// Whether group heading rows print their subtotals (BH-731), from the pane's Group by menu.
    public var showsSubtotals: Bool { host.showsSubtotals }

    /// Shows or hides the subtotals on group heading rows and remembers the choice (C-05).
    public func setShowsSubtotals(_ shows: Bool) {
        guard host.showsSubtotals != shows else { return }
        host.setShowsSubtotals(shows)
        preferences.showsSubtotals = shows
    }

    /// Expands every group of the grouped ledger (C-05). The table persists the collapsed set.
    public func expandAllGroups() {
        host.expandAll()
    }

    /// Collapses every group of the grouped ledger to its heading row (C-05).
    public func collapseAllGroups() {
        host.collapseAll()
    }

    /// The live match count's numerator: rows that pass the filter.
    public var matchCount: Int { presenter.rowCount }

    /// The live match count's denominator: rows before the filter narrowed them.
    public var totalCount: Int { presenter.unfilteredRowCount }

    /// The active filter tree.
    public var filter: LedgerFilterGroup { presenter.filter }

    /// The columns the filter panel lets a rule name: every column the presenter has, in the
    /// default arrangement, hidden ones included.
    ///
    /// S-078: the pane used to hand the builder the columns on screen
    /// (`arranged(visibleColumns).filter(\.visible)`), so the rules the Status and kind chips
    /// write — Status "is any of", Plan Area / Plan Length / Count "has a value" — were reported
    /// as naming no such column while they were in fact applied, and Status could not be picked
    /// for a rule. The choice lives here rather than in the pane's body so a test can hold the
    /// pane to it.
    public var filterColumns: [LedgerColumn] {
        LedgerFilterBuilder.filterableColumns(presenter.columns)
    }

    /// Replaces the filter tree and lets the presenter's rebuild land.
    ///
    /// The reload is not forced here: the app presenter debounces and supersedes its
    /// rebuilds (ADR-0003 §2.2) and bumps `contentRevision` when the new projection
    /// arrives, which is the cue the pane already reloads on. Reloading now as well would
    /// draw the *previous* projection one more time.
    public func setFilter(_ group: LedgerFilterGroup) {
        presenter.setFilter(group)
    }

    /// What the canvas does with rows the filter removed.
    public var canvasFilterBehavior: LedgerCanvasFilterBehavior { presenter.canvasFilterBehavior }

    /// Changes what the canvas does with rows the filter removed.
    public func setCanvasFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) {
        presenter.setCanvasFilterBehavior(behavior)
    }

    /// Whether the attached presenter can service a bulk edit at all.
    ///
    /// A pane over the mock presenter cannot, and says so, rather than offering an Apply
    /// button that silently does nothing.
    public var canBulkEdit: Bool { presenter is any LedgerBulkEditPresenting }

    /// Clears the outcome line after the reviewer has read it.
    public func clearBulkEditReceipt() { lastBulkEditReceipt = nil }

    /// Applies an edit through the presenter's bulk-edit seam.
    ///
    /// - Parameter fromPanel: `true` for the Bulk Edit panel's Apply, whose outcome line sits
    ///   under the panel; `false` for an inline cell edit, which says only a refusal, in the
    ///   pane's notice. L-85: an inline label edit's "Changed 1 markup(s)" waited under the
    ///   Bulk Edit panel and greeted it, as if something had been applied there.
    func applyBulkEdit(
        values: [LedgerColumnID: LedgerCellValue],
        color: ColorRGBA?,
        markupIDs: Set<UUID>,
        fromPanel: Bool = true
    ) {
        guard let editor = presenter as? any LedgerBulkEditPresenting else {
            let refusal = NSLocalizedString(
                "This ledger cannot be edited.",
                comment: "Bulk edit refusal when the pane has no editable ledger"
            )
            if fromPanel { lastBulkEditReceipt = .failure(refusal) } else { paneNotice = refusal }
            return
        }
        let request = LedgerBulkEditRequest(markupIDs: markupIDs, values: values, color: color)
        Task { @MainActor [weak self] in
            let receipt = await editor.applyBulkEdit(request)
            guard let self else { return }
            if fromPanel {
                self.lastBulkEditReceipt = receipt
            } else if let failure = receipt.failureDescription {
                self.paneNotice = failure
            }
            self.refresh()
            // The rows the panel shows are now stale by exactly the fields that changed,
            // so the mixed-value state is recomputed from the rebuilt table rather than
            // from what was on screen when Apply was pressed.
            self.adoptSelectionIntoBulkEdit(self.host.selectedRowIDs, keepingReceipt: true)
        }
    }

    private func adoptSelectionIntoBulkEdit(_ ids: Set<UUID>, keepingReceipt: Bool = false) {
        // The outcome line belongs to the markups it was applied to: another selection is a new
        // edit, and an old "Changed 2 markups" over it would claim work done on these (L-85).
        if !keepingReceipt, ids != bulkEdit.markupIDs { lastBulkEditReceipt = nil }
        bulkEdit.setColumns(presenter.columns)
        // Resolved through the table's identity index, so selecting three rows out of a
        // hundred thousand costs three lookups rather than a scan (ADR-0003 §2.3).
        bulkEdit.setSelection(rows: host.rows(withIDs: ids))
    }

    /// Mirrors a selection that came from the canvas into the table, without echo.
    public func applyExternalSelection(_ ids: Set<UUID>) {
        guard ids != host.selectedRowIDs else { return }
        host.applyExternalSelection(ids, scrollToFirst: false)
        adoptSelectionIntoBulkEdit(ids)
    }
}
