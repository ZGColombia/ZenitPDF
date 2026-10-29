import AppKit
import Observation
import SwiftUI
import ZPDFUIPresentation

/// Owns the AppKit ledger table and republishes what it does as observable state.
///
/// SwiftUI cannot own an `NSViewController` across body evaluations, so the host does. It
/// is also the table's delegate, which keeps every callback in one place instead of
/// scattered across representable coordinators.
@MainActor
@Observable
public final class LedgerTableHost {

    /// The table controller.
    @ObservationIgnored public let controller: LedgerTableController

    /// The current selection, mirrored for SwiftUI.
    public private(set) var selectedRowIDs: Set<UUID> = []

    /// The current columns, mirrored for SwiftUI.
    public private(set) var columns: [LedgerColumn]

    /// Number of rows in the plan.
    public private(set) var rowCount: Int = 0

    /// Units the group headers and the totals bar print in. The table and the totals bar
    /// read this one value, so they cannot disagree (BH-732).
    public private(set) var unitPolicy: LedgerUnitPolicy = .metric

    /// Rounding the group headers and the totals bar print with.
    public private(set) var rounding: LedgerRounding = .exact

    /// Whether group rows show subtotals (BH-731).
    public private(set) var showsSubtotals = true

    /// Called when a row is activated, so the canvas can reveal the markup.
    public var onActivate: (@MainActor (UUID) -> Void)?

    /// Called when the selection changed inside the ledger.
    public var onSelectionChange: (@MainActor (Set<UUID>) -> Void)?

    /// Called when the user asked to sort by a column.
    ///
    /// Receives the outermost level only. A host that can sort by several columns sets
    /// ``onSortDescriptors`` instead, which then takes precedence.
    public var onSort: (@MainActor (LedgerColumnID, Bool) -> Void)?

    /// Called with every sort level the header carries, outermost first (IM-099). When set,
    /// it replaces ``onSort``.
    public var onSortDescriptors: (@MainActor ([LedgerSortDescriptor]) -> Void)?

    /// Called with a committed inline cell edit, a one-markup bulk-edit request (IM-013).
    /// Inline editing is offered only while this is set.
    public var onCommitInlineEdit: (@MainActor (LedgerBulkEditRequest) -> Void)? {
        get { controller.onCommitInlineEdit }
        set { controller.onCommitInlineEdit = newValue }
    }

    /// Called when the user picked "Save Layout…" in the header menu.
    public var onSaveLayoutRequested: (@MainActor () -> Void)?

    /// Called when the user picked "Add Column…" (`true`) or "Manage Columns…" (`false`) in
    /// the header menu (NL-QTY-02). Leaving it unset keeps both items out of the menu.
    public var onManageColumnsRequested: (@MainActor (_ addingNew: Bool) -> Void)? {
        didSet {
            controller.onManageColumnsRequested = onManageColumnsRequested == nil
                ? nil
                : { [weak self] adding in self?.onManageColumnsRequested?(adding) }
        }
    }

    /// Called whenever the collapsed-group set changes, so the owner can persist it —
    /// collapsed state survives a relaunch.
    public var onCollapsedGroupPathsChange: (@MainActor (Set<String>) -> Void)? {
        get { controller.onCollapsedGroupPathsChange }
        set { controller.onCollapsedGroupPathsChange = newValue }
    }

    /// Creates the host over a row source.
    public init(
        rowSource: any LedgerRowProviding,
        mode: LedgerTableMode = .flat,
        groupingColumns: [LedgerColumnID] = []
    ) {
        let controller = LedgerTableController(
            rowSource: rowSource,
            mode: mode,
            groupingColumns: groupingColumns
        )
        self.controller = controller
        self.columns = controller.columns
        self.unitPolicy = controller.unitPolicy
        self.rounding = controller.rounding
        controller.delegate = self
        controller.onSaveLayoutRequested = { [weak self] in self?.onSaveLayoutRequested?() }
    }

    /// Changes the units group subtotals print in, for the table and the totals bar at once.
    public func setUnitPolicy(_ policy: LedgerUnitPolicy) {
        guard policy != unitPolicy else { return }
        unitPolicy = policy
        controller.unitPolicy = policy
        controller.reloadRows()
    }

    /// Changes the rounding group subtotals print with, for the table and the totals bar.
    public func setRounding(_ newRounding: LedgerRounding) {
        guard newRounding != rounding else { return }
        rounding = newRounding
        controller.rounding = newRounding
        controller.reloadRows()
    }

    /// Shows or hides the subtotals on group rows.
    public func setShowsSubtotals(_ shows: Bool) {
        showsSubtotals = shows
        controller.showsSubtotals = shows
    }

    /// Re-reads the plan after the presenter changed.
    public func reload() {
        controller.rebuildPlan()
        syncFromController()
    }

    /// Applies a selection that came from the canvas.
    public func applyExternalSelection(_ rowIDs: Set<UUID>, scrollToFirst: Bool = true) {
        controller.applyExternalSelection(rowIDs, scrollToFirst: scrollToFirst)
        selectedRowIDs = rowIDs
    }

    /// Expands every group.
    public func expandAll() {
        controller.expandAllGroups()
        syncFromController()
    }

    /// Collapses every group.
    public func collapseAll() {
        controller.collapseAllGroups()
        syncFromController()
    }

    /// Replaces the grouping levels.
    public func setGrouping(_ columnIDs: [LedgerColumnID]) {
        controller.setGrouping(columnIDs)
        syncFromController()
    }

    /// Restores a persisted collapsed-group set.
    public func setCollapsedGroupPaths(_ paths: Set<String>) {
        controller.setCollapsedGroupPaths(paths)
        syncFromController()
    }

    /// The rows behind a set of markup identifiers, in display order.
    ///
    /// Costs one index hit per identifier rather than a scan over the whole ledger.
    public func rows(withIDs rowIDs: Set<UUID>) -> [LedgerRow] {
        controller.rows(withIDs: rowIDs)
    }

    /// The spoken summary of the whole ledger.
    public var accessibilitySummary: String { controller.accessibilitySummary }

    private func syncFromController() {
        columns = controller.columns
        unitPolicy = controller.unitPolicy
        rounding = controller.rounding
        showsSubtotals = controller.showsSubtotals
        selectedRowIDs = controller.selectedRowIDs
        rowCount = controller.plan.order.count
    }
}

extension LedgerTableHost: LedgerTableControllerDelegate {

    public func ledgerTable(_ controller: LedgerTableController, didChangeSelection rowIDs: Set<UUID>) {
        selectedRowIDs = rowIDs
        onSelectionChange?(rowIDs)
    }

    public func ledgerTable(_ controller: LedgerTableController, didActivate rowID: UUID) {
        onActivate?(rowID)
    }

    public func ledgerTable(_ controller: LedgerTableController, didChangeColumns columns: [LedgerColumn]) {
        self.columns = columns
    }

    public func ledgerTable(_ controller: LedgerTableController, didRequestSort columnID: LedgerColumnID, ascending: Bool) {
        onSort?(columnID, ascending)
    }

    public func ledgerTable(_ controller: LedgerTableController, didRequestSort descriptors: [LedgerSortDescriptor]) {
        if let onSortDescriptors {
            onSortDescriptors(descriptors)
        } else if let first = descriptors.first {
            onSort?(first.column, first.ascending)
        }
    }
}

/// Hosts ``LedgerTableController`` inside SwiftUI.
public struct LedgerTableRepresentable: NSViewControllerRepresentable {

    private let host: LedgerTableHost

    /// Wraps a host.
    public init(host: LedgerTableHost) {
        self.host = host
    }

    public func makeNSViewController(context: Context) -> LedgerTableController {
        host.controller
    }

    public func updateNSViewController(_ nsViewController: LedgerTableController, context: Context) {
        // The host mutates the controller directly; there is deliberately nothing to
        // push down here, so SwiftUI re-evaluations never trigger a table reload.
    }
}
