import Foundation
import Observation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFFormulaEngine
import ZPDFUIPresentation

/// `LedgerPresenting` over the real aggregation core.
///
/// The presenter holds a ``LedgerProjection``, not rows. `rowCount` is the projection's
/// count, `row(at:)` builds one row on demand, and `index(of:)` is a dictionary lookup.
/// Nothing here is O(rows) except the rebuild itself, which happens on the session actor.
///
/// Rebuilds are debounced and superseding: a keystroke in the filter field cancels the
/// query the previous keystroke started (ADR-0003 §2.2), so a fast typist gets one query
/// rather than eight, and never sees the results of the seventh arrive after the eighth.
@MainActor
@Observable
public final class AppLedgerPresenter: LedgerPresenting, LedgerTableArrangementHosting {

    // MARK: Published state

    public private(set) var columns: [ZPDFUIPresentation.LedgerColumn] = []
    public private(set) var rootGroups: [ZPDFUIPresentation.LedgerGroupNode] = []
    public private(set) var grandTotals: LedgerTotals = .empty
    public private(set) var groupingColumns: [LedgerColumnID] = []
    public private(set) var filter: LedgerFilterGroup
    public private(set) var canvasFilterBehavior: LedgerCanvasFilterBehavior = .dimNonMatching
    public private(set) var selectedRowIDs: Set<UUID> = []
    public private(set) var sortDescriptors: [ZPDFUIPresentation.LedgerSortDescriptor] = []
    /// NL-MEASURE-03: how many ledger rows hold a value kept under an older scale, over every
    /// row whether filtered out or not, and whether the ledger shows only those.
    public private(set) var olderScaleRowCount: Int = 0
    public private(set) var showsOnlyOlderScaleValues = false
    public private(set) var isLoading: Bool = false
    /// Bumped on every projection swap — the pane's always-moving reload cue.
    public private(set) var contentRevision = 0
    /// Rows in the store before ``filter`` narrowed the view — the denominator of the
    /// filter builder's live count and of every export's "12 of 40 rows" label.
    public private(set) var unfilteredRowCount: Int = 0
    /// Whether the projection on screen was narrowed by a filter.
    public private(set) var isFiltered: Bool = false
    /// Rows that pass the filter, per measurement kind, for the ledger bar's summary chips
    /// Counted once per projection swap from the projection's own
    /// records — the same `tool` → kind mapping each row's `measurementKind` uses — so no row
    /// is formatted and no second path into the rows exists. Rows without a measurement kind
    /// (text, callouts) are not counted; kinds with no rows are absent.
    public private(set) var rowCountsByMeasurementKind: [ZPDFUIPresentation.MeasurementKind: Int] = [:]
    /// Rows per review status over the whole ledger, before any filter — what the status
    /// quick-filter chips read (NL-QTY-17). One pass over the records, no cell built.
    public private(set) var rowCountsByStatus: [ZPDFContracts.MarkupStatus: Int] = [:]
    /// Markups in the document that carry no quantity, ledger row or not — the ledger bar's
    /// Markups chip (L-50, ``LedgerMarkupCounting``). Counted by the session with each projection.
    public private(set) var nonMeasurementMarkupCount: Int = 0
    /// The rules of ``filter`` the engine could not apply — a pattern rule, a rule on a
    /// display-only column — so the builder can say so instead of reporting them applied
    /// and the export banner can stop claiming them (CR-56).
    public private(set) var unappliedFilterRules: [LedgerFilterDiagnostic] = []
    /// Why the last rebuild failed, while the previous result is still on screen — or `nil`.
    ///
    /// A refused rebuild keeps the last projection, because an empty ledger would read as "you
    /// have no quantities"; but it used to keep it *silently*, so after a failed filter, sort or
    /// edit rebuild the table showed stale rows and totals that looked current (IM-056). The
    /// pane shows this as a dismissible banner; the next successful rebuild clears it.
    public private(set) var lastRebuildError: String?
    /// A sort the engine could not apply, and why, or `nil`.
    ///
    /// The Value and Unit columns are synthesised for display and have no engine column; a
    /// header click on either used to set a sort descriptor the spec builder then dropped, so
    /// the rows stayed in insertion order under a header showing a sort indicator (BH-102). The
    /// sort is refused and said instead; the previous order stays.
    public private(set) var unappliedSortColumn: LedgerColumnID?

    /// Called when the selection changed inside the ledger, so the canvas can follow.
    public var onSelectionChange: (@MainActor (Set<UUID>) -> Void)?

    /// Called whenever the filter, or what the canvas should do about it, changed.
    ///
    /// The filter builder's canvas control used to write ``canvasFilterBehavior`` and stop
    /// there: `AppCanvasPresenter` has had `setFilterMatches(_:)` and `setFilterBehavior(_:)`
    /// since it was written and nothing in the application called either, so filtering the
    /// ledger to one subject left every markup on the drawing and the three-way control
    /// above the rules did nothing at all. Installed by ``AppCoreEnvironment``, which is the
    /// only object that holds both presenters.
    ///
    /// The set is the markups that passed the filter, or `nil` when the ledger is not
    /// filtered — `nil` means "no narrowing", which is not the same as "nothing matched".
    public var onCanvasFilterChange: (@MainActor (Set<UUID>?, LedgerCanvasFilterBehavior) -> Void)?

    /// The markups the active filter kept, or `nil` when no filter is on.
    ///
    /// Read off the projection's identity index, so it costs the matched rows rather than
    /// a scan of the takeoff (ADR-0003 §2.3).
    public var filterMatchedMarkupIDs: Set<UUID>? {
        guard isFiltered else { return nil }
        return Set(projection.positionByMarkupID.keys)
    }

    /// Services ``LedgerBulkEditPresenting``. Installed by ``AppCoreEnvironment``, which
    /// is the only place that knows how to turn a bulk edit into document commands. Left
    /// unset — in a preview, or a presenter built without an environment — Apply reports
    /// an honest refusal instead of appearing to work.
    public var onBulkEdit: (@MainActor (LedgerBulkEditRequest) async -> LedgerBulkEditReceipt)?

    /// The Column Manager's seam (NL-QTY-02), installed by the environment next to
    /// ``onBulkEdit`` so a column change goes through the command bus like every edit.
    public var onApplyColumnSpecs: (@MainActor ([LedgerColumnSpec], String) async -> LedgerBulkEditReceipt)?

    /// The assemblies seam (NL-QTY-07), installed by the environment beside ``onBulkEdit``.
    /// The summary matrix's seam (NL-QTY-09): built by the session from the core's projections.
    public var buildMatrix: (@MainActor (LedgerColumnID, LedgerColumnID, LedgerFilterGroup) async throws -> LedgerMatrix)?

    public var onPlaceSummary: (@MainActor (LiveSummarySpec) async -> LedgerBulkEditReceipt)?

    public var onApplyAssembly: (@MainActor (UUID?, [String: Domain.Quantity], Set<UUID>) async -> LedgerBulkEditReceipt)?
    /// NL-QTY-07 round 2: the office's recipes, offered beside the built-in ones.
    public var officeAssemblies: [AssemblyDefinition] = []
    /// NL-QTY-07-UI: the recipes saved in this project, offered beside the office's.
    public var projectAssemblies: [AssemblyDefinition] = []
    /// NL-QTY-07-UI: the office library the recipe editor saves into; `nil` offers no office
    /// library (a test process, unless a test injects one in a temporary directory).
    public var officeRecipeLibrary: AssemblyRecipeLibrary?
    /// NL-QTY-07-UI: the recipe editor's seam, installed by the environment.
    public var assemblyRecipeSeam: AssemblyRecipeSeam?
    /// NL-QTY-07-UI: called after the project's own recipes changed, so the document is saved
    /// with them. Installed by the application.
    public var onProjectAssembliesChanged: (@MainActor () -> Void)?

    /// The full column set the current projection was built against — every column, hidden
    /// ones included — for the Column Manager and the formula check.
    var projectedColumnSet: LedgerColumnSet { projection.view.store.columns }

    /// The store behind the current projection.
    var projectedStore: LedgerStore { projection.view.store }

    /// The formatter the current projection renders with.
    var projectionFormatter: QuantityFormatter { projection.formatter }

    /// The takeoff snapshots' seam (NL-QTY-16), installed by the environment.
    public var snapshotSeam: LedgerSnapshotSeam?

    /// The rate library's seam (NL-QTY-05), installed by the environment.
    public var rateLibrarySeam: LedgerRateLibrarySeam?

    /// "Explain any number"'s seam, installed by the environment.
    public var explainSeam: (@MainActor (Set<UUID>) async -> LedgerExplanation)?

    /// The other open drawings, for the whole-project summary (NL-QTY-15). Installed by the
    /// window that holds them; empty for a single drawing.
    public var projectSources: [ProjectLedgerSource] = []

    /// This drawing's own part of the whole-project summary, installed with the sources.
    public var ownProjectPart: (@MainActor () async -> LedgerProjectSummary.Drawing)?

    /// The audit-trail feed behind ``LedgerAuditPresenting``, installed by
    /// ``AppCoreEnvironment``. The shell reaches the History tab through a conditional
    /// cast on the ledger presenter, so the feed is surfaced here by delegation rather
    /// than by a second presenter the shell cannot see.
    public var history: AppHistoryPresenter?

    /// The table's own column arrangement, installed by the pane that builds the table over
    /// this presenter (W-029). A job template is captured from and applied to it: the table
    /// keeps order and visibility itself, so ``columns`` is the definitions, not what is shown.
    @ObservationIgnored
    public var tableArrangement: LedgerTableArrangement?

    /// The derivation sections of every measured value, from the last adopted snapshot.
    private var derivations: [UUID: [LedgerDerivationSection]] = [:]

    // MARK: Private state

    private let session: TakeoffSession
    private(set) var projection: LedgerProjection
    /// Rows already built for the current projection. Cleared whenever the projection is
    /// replaced, so a stale row can never be drawn against fresh totals.
    private var rowCache: [Int: ZPDFUIPresentation.LedgerRow] = [:]
    private var collapsedGroupIDs: Set<UUID> = []
    private var rebuildTask: Task<Void, Never>?

    /// How long a filter or sort change waits before it becomes a query.
    ///
    /// 300 ms, a settled-announcement debounce (`ACCESSIBILITY_PLAN.md`, "Required behavior"), so
    /// the query and the VoiceOver announcement land together rather than the announcement
    /// describing a result the user is about to replace.
    public var debounce: Duration = .milliseconds(300)

    /// Creates a presenter over a session.
    public init(session: TakeoffSession, projection: LedgerProjection) {
        self.session = session
        self.projection = projection
        self.filter = LedgerFilterGroup(id: UUID())
        adopt(projection)
    }

    // MARK: Index-addressed rows (ADR-0003 §3.4)

    public var rowCount: Int { projection.rowCount }

    public func row(at index: Int) -> ZPDFUIPresentation.LedgerRow? {
        guard index >= 0, index < projection.rowCount else { return nil }
        if let cached = rowCache[index] { return cached }
        guard var built = projection.row(at: index) else { return nil }
        built.matchesFilter = true
        rowCache[index] = built
        return built
    }

    public func index(of markupID: UUID) -> Int? { projection.positionByMarkupID[markupID] }

    /// The rows for these markups from the store, filtered out or not, in store order (W-042).
    /// A row the filter hides says so in ``LedgerRow/matchesFilter``.
    public func unfilteredRows(withIDs markupIDs: Set<UUID>) -> [ZPDFUIPresentation.LedgerRow] {
        let view = projection.view
        return markupIDs
            .compactMap { view.store.index(of: MarkupID($0)) }
            .sorted()
            .map { storeIndex in
                var row = LedgerBridge.row(view: view, storeIndex: storeIndex, formatter: projection.formatter)
                row.matchesFilter = projection.positionByMarkupID[row.markupID] != nil
                return row
            }
    }

    public func prefetchRows(in range: Range<Int>) {
        guard projection.rowCount > 0 else { return }
        let clamped = range.clamped(to: 0..<projection.rowCount)
        for position in clamped where rowCache[position] == nil {
            rowCache[position] = projection.row(at: position)
        }
        evictOutside(clamped)
    }

    /// Drops rows far outside the band the table is drawing.
    ///
    /// Without this the cache is an array of view models with extra steps, which is the
    /// exact thing ADR-0003 removed. The window kept is the visible band plus four times
    /// its own size, so ordinary scrolling never re-builds and a jump to the far end of a
    /// 100 000-row ledger does not carry the near end with it.
    private func evictOutside(_ band: Range<Int>) {
        let slack = max(256, band.count * 4)
        let keep = max(0, band.lowerBound - slack)..<min(projection.rowCount, band.upperBound + slack)
        guard rowCache.count > keep.count else { return }
        rowCache = rowCache.filter { keep.contains($0.key) }
    }

    // MARK: Mutations

    public func setGrouping(_ columns: [LedgerColumnID]) {
        groupingColumns = columns
        // A discrete choice, not typing: nothing to coalesce, so no debounce (IM-055).
        rebuildNow()
    }

    public func setFilter(_ filter: LedgerFilterGroup) {
        self.filter = filter
        scheduleRebuild()
    }

    public func setCanvasFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) {
        canvasFilterBehavior = behavior
        publishCanvasFilter()
    }

    /// Tells the canvas what the filter is and what to do about it.
    ///
    /// Called on every projection swap as well as on the control, because the matched set
    /// changes whenever the rules do — and a canvas still narrowed to yesterday's match is
    /// worse than one that was never narrowed at all.
    private func publishCanvasFilter() {
        onCanvasFilterChange?(
            canvasFilterBehavior == .leaveUnchanged ? nil : filterMatchedMarkupIDs,
            canvasFilterBehavior
        )
    }

    public func setColumnVisible(_ visible: Bool, columnID: LedgerColumnID) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        columns[index].visible = visible
        rowCache.removeAll(keepingCapacity: true)
    }

    public func setColumnWidth(_ width: Double, columnID: LedgerColumnID) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        columns[index].width = max(24, width)
    }

    public func setColumnPinned(_ pinned: Bool, columnID: LedgerColumnID) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        columns[index].pinned = pinned
    }

    public func moveColumn(_ columnID: LedgerColumnID, to index: Int) {
        guard let current = columns.firstIndex(where: { $0.id == columnID }),
              columns.indices.contains(index) else { return }
        let column = columns.remove(at: current)
        columns.insert(column, at: index)
    }

    public func toggleGroup(id: ZPDFUIPresentation.LedgerGroupNode.ID) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
        rootGroups = Self.applyingExpansion(rootGroups, collapsed: collapsedGroupIDs)
    }

    public func select(rowIDs: Set<UUID>, additive: Bool) {
        selectedRowIDs = additive ? selectedRowIDs.union(rowIDs) : rowIDs
        onSelectionChange?(selectedRowIDs)
    }

    /// Applies a selection that came from the canvas, without echoing it back and starting
    /// a loop between the two panes.
    public func applyExternalSelection(_ markupIDs: Set<UUID>) {
        selectedRowIDs = markupIDs
    }

    public func sort(by columnID: LedgerColumnID, ascending: Bool) {
        if columnID == LedgerDefaultColumns.valueColumnID || columnID == LedgerDefaultColumns.unitColumnID {
            unappliedSortColumn = columnID
            return
        }
        unappliedSortColumn = nil
        sortDescriptors = [ZPDFUIPresentation.LedgerSortDescriptor(column: columnID, ascending: ascending)]
        // A header click is one discrete action. It used to wait out the 300 ms typing debounce
        // before any work started — the whole of QUALITY_BAR 4.7's sort budget spent idle
        // (IM-055). The debounce stays where it belongs, on the filter field.
        rebuildNow()
    }

    /// Sorts by several levels at once, outermost first (IM-099). The aggregation
    /// core's sorter already takes levels, and the export's sort description lists every one.
    /// A level on a display-only column is refused like a single-column sort on it, and the
    /// remaining levels still apply.
    public func sort(by descriptors: [ZPDFUIPresentation.LedgerSortDescriptor]) {
        let refused = descriptors.first { LedgerDefaultColumns.isDisplayColumn($0.column) }
        unappliedSortColumn = refused?.column
        let applied = descriptors.filter { !LedgerDefaultColumns.isDisplayColumn($0.column) }
        guard !applied.isEmpty || descriptors.isEmpty else { return }
        sortDescriptors = applied
        rebuildNow()
    }

    /// The on-screen column order reported by the pane (IM-027).
    public var onScreenColumnOrder: [LedgerColumnID] = []

    /// The words for ``unappliedSortColumn``.
    public var unappliedSortMessage: String? {
        guard let unappliedSortColumn else { return nil }
        return String(
            format: NSLocalizedString(
                "The ledger cannot be sorted by “%@”: that column is for display only. The previous order is kept.",
                comment: "Ledger sort refusal; the placeholder is the column key"
            ),
            unappliedSortColumn.rawValue
        )
    }

    /// Clears ``lastRebuildError`` when the person dismisses the banner.
    public func dismissRebuildError() {
        lastRebuildError = nil
    }

    public func totals(forGroup groupID: ZPDFUIPresentation.LedgerGroupNode.ID?) -> LedgerTotals {
        guard let groupID else { return grandTotals }
        return Self.find(groupID, in: rootGroups)?.totals ?? .empty
    }

    /// The outline is the aggregation core's group tree, addressed by position (IM-011).
    ///
    /// All three promises hold by construction: the projection's display order is the core
    /// tree's `orderedRowIndices` — the leaves' rows concatenated in outline order — each node
    /// carries `totals.rowCount = descendantRowCount`, and every node's totals and
    /// ``grandTotals`` carry every summed column plus the display `Value` total
    /// (`LedgerBridge.group`/`project`). `rootGroups`, `grandTotals` and `rowCount` are
    /// replaced together in ``adopt(_:)``, so the table never pairs one projection's outline
    /// with another's rows. The table therefore draws its group headings and subtotals from
    /// here and never folds the rows itself: one aggregation engine, the core's.
    public var suppliesDisplayOrderedOutline: Bool { true }

    // MARK: Rebuilding

    /// The request the session is asked for, derived from the published state.
    public var request: LedgerRequest {
        var request = LedgerRequest(
            grouping: groupingColumns,
            sort: sortDescriptors,
            filter: filter,
            visibleColumns: []
        )
        request.onlyOlderScaleValues = showsOnlyOlderScaleValues
        return request
    }

    /// Shows only the rows whose value was kept under an older scale, or every row again.
    public func setShowsOnlyOlderScaleValues(_ on: Bool) {
        guard showsOnlyOlderScaleValues != on else { return }
        showsOnlyOlderScaleValues = on
        rebuildNow()
    }

    /// Schedules a debounced, superseding rebuild.
    public func scheduleRebuild() {
        rebuildTask?.cancel()
        isLoading = true
        let request = self.request
        let debounce = self.debounce
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.rebuild(request)
        }
    }

    /// Starts a superseding rebuild with no debounce — for a sort or a grouping change, which is
    /// one discrete action with nothing to coalesce.
    private func rebuildNow() {
        rebuildTask?.cancel()
        isLoading = true
        let request = self.request
        rebuildTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await self.rebuild(request)
        }
    }

    /// Rebuilds now, without the debounce. Used after a document mutation, where there is
    /// nothing to coalesce and a visible delay would look like a dropped edit.
    public func refresh() async {
        rebuildTask?.cancel()
        rebuildTask = nil
        await rebuild(request)
    }

    private func rebuild(_ request: LedgerRequest) async {
        isLoading = true
        do {
            let projection = try await session.ledgerProjection(request)
            guard !Task.isCancelled else { return }
            adopt(projection)
            lastRebuildError = nil
        } catch {
            // A refused rebuild leaves the previous projection on screen. Showing an empty
            // ledger because a query failed would read as "you have no quantities" — but the
            // staleness is said (IM-056).
            lastRebuildError = String(
                format: NSLocalizedString(
                    "The ledger could not be updated: %@. Showing the last result.",
                    comment: "Ledger banner after a failed rebuild; the placeholder is the reason"
                ),
                String(describing: error)
            )
        }
        isLoading = false
    }

    /// Installs a new projection and drops every cached row with it.
    public func adopt(_ projection: LedgerProjection) {
        self.projection = projection
        rowCache.removeAll(keepingCapacity: true)
        // The reload cue the pane can always trust: row count and totals stay identical
        // across a subject rename, so they cannot be the only observable signals
        // (found 2026-08-24).
        contentRevision += 1
        columns = projection.columns
        unfilteredRowCount = projection.unfilteredRowCount
        isFiltered = projection.isFiltered
        rowCountsByMeasurementKind = Self.kindCounts(projection)
        rowCountsByStatus = Self.statusCounts(projection)
        if let markups = projection.nonMeasurementMarkupCount { nonMeasurementMarkupCount = markups }
        olderScaleRowCount = Self.olderScaleCount(projection)
        unappliedFilterRules = projection.unappliedFilterRules
        grandTotals = projection.grandTotals
        rootGroups = Self.applyingExpansion(projection.rootGroups, collapsed: collapsedGroupIDs)
        selectedRowIDs = selectedRowIDs.filter { projection.positionByMarkupID[$0] != nil }
        publishCanvasFilter()
    }

    /// Rows holding a value kept under an older scale, over the whole store (NL-MEASURE-03).
    static func olderScaleCount(_ projection: LedgerProjection) -> Int {
        let store = projection.view.store
        var count = 0
        for index in 0..<store.rowCount where LedgerOlderScale.isKept(store.row(at: index).record) { count += 1 }
        return count
    }

    /// Rows per status over the store the projection was built from — every row, filtered
    /// out or not, so a chip's count does not fall to zero the moment another chip is on.
    static func statusCounts(_ projection: LedgerProjection) -> [ZPDFContracts.MarkupStatus: Int] {
        var counts: [ZPDFContracts.MarkupStatus: Int] = [:]
        let store = projection.view.store
        for index in 0..<store.rowCount {
            counts[store.row(at: index).record.status, default: 0] += 1
        }
        return counts
    }

    /// One pass over the projection's records: no cell is read and no row is built.
    static func kindCounts(_ projection: LedgerProjection) -> [ZPDFUIPresentation.MeasurementKind: Int] {
        var counts: [ZPDFUIPresentation.MeasurementKind: Int] = [:]
        let view = projection.view
        for display in 0..<view.rowCount {
            guard let tool = view.row(displayRow: display).record.tool else { continue }
            counts[Shown.Kind(domain: tool), default: 0] += 1
        }
        return counts
    }

    // MARK: Group helpers

    private static func applyingExpansion(
        _ nodes: [ZPDFUIPresentation.LedgerGroupNode],
        collapsed: Set<UUID>
    ) -> [ZPDFUIPresentation.LedgerGroupNode] {
        nodes.map { node in
            var copy = node
            copy.isExpanded = !collapsed.contains(node.id)
            copy.children = applyingExpansion(node.children, collapsed: collapsed)
            return copy
        }
    }

    private static func find(
        _ id: UUID,
        in nodes: [ZPDFUIPresentation.LedgerGroupNode]
    ) -> ZPDFUIPresentation.LedgerGroupNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = find(id, in: node.children) { return found }
        }
        return nil
    }
}

// MARK: - LedgerMarkupCounting (L-50)

extension AppLedgerPresenter: LedgerMarkupCounting {}

// MARK: - LedgerAuditPresenting (ADR-0007 §3)

/// The History tab's trust surface, backed by ``AppHistoryPresenter``'s trail. With no
/// feed attached every answer is honestly empty, and the pane states that rather than
/// rendering a blank body.
extension AppLedgerPresenter: LedgerAuditPresenting {

    public func derivation(for markupID: UUID) -> LedgerDerivationModel? {
        let sections = derivations[markupID] ?? []
        let events = history?.auditEvents(matching: LedgerAuditFilter(markupID: markupID)) ?? []
        // Nothing at all about this markup: the panel's own "unknown markup" branch, not an
        // empty disclosure that looks like an answer.
        guard !sections.isEmpty || !events.isEmpty else { return nil }
        return LedgerDerivationModel(
            markupID: markupID,
            // `false` says, in the panel's own words, that this value predates derivation
            // capture. It is not a synonym for "no sections": a value measured by this build
            // always has them, and one measured by an older build never will.
            hasProvenance: !sections.isEmpty,
            sections: sections,
            history: events
        )
    }

    /// Installs the derivations from a snapshot. Called on the same pass as the projection, so
    /// the disclosure and the row it was opened from describe one instant of the document.
    public func adopt(derivations sections: [UUID: [LedgerDerivationSection]]) {
        derivations = sections
    }

    public func auditEvents(matching filter: LedgerAuditFilter) -> [LedgerAuditEvent] {
        history?.auditEvents(matching: filter) ?? []
    }

    public var auditPageLabels: [String] {
        history?.auditPageLabels ?? []
    }

    public var auditActions: [String] {
        history?.auditActions ?? []
    }

    /// The trail's own generation (V-042): it moves when the history store publishes, which
    /// need not coincide with a ledger rebuild.
    public var auditRevision: Int {
        history?.eventsGeneration ?? 0
    }
}

// MARK: - LedgerBulkEditPresenting

/// Multi-selection editing, routed through the command bus by ``AppCoreEnvironment`` so a
/// bulk edit is one undo step and one audit group like every other mutation. The presenter
/// itself never touches the session: a second write path into the document is exactly the
/// thing `DocumentCommandBus` exists to make impossible.
extension AppLedgerPresenter: LedgerBulkEditPresenting {

    public func applyBulkEdit(_ request: LedgerBulkEditRequest) async -> LedgerBulkEditReceipt {
        guard let onBulkEdit else {
            return .failure(NSLocalizedString(
                "This ledger cannot be edited.",
                comment: "Bulk edit refusal when no document is attached to the ledger"
            ))
        }
        return await onBulkEdit(request)
    }
}
