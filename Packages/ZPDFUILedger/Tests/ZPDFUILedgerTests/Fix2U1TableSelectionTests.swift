import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Bug hunt 2, the table controller's selection, expansion and column bookkeeping:
/// BH-045, BH-242, BH-243, BH-244, BH-245, BH-246, BH-738, BH-739, BH-740, BH-741, and the
/// counting halves of IM-100 and IM-201. Every controller is built with
/// `loadViewIfNeeded()` and never put in a window.
@MainActor
@Suite("Fix2 U1 table selection and columns", .ledgerTierSerialised)
struct Fix2U1TableSelectionTests {

    final class Spy: LedgerTableControllerDelegate {
        var selections: [Set<UUID>] = []
        var columnChanges: [[LedgerColumn]] = []
        var activations: [UUID] = []
        var sorts: [[LedgerSortDescriptor]] = []
        var singleSorts: [(LedgerColumnID, Bool)] = []
        func ledgerTable(_ controller: LedgerTableController, didChangeSelection rowIDs: Set<UUID>) {
            selections.append(rowIDs)
        }
        func ledgerTable(_ controller: LedgerTableController, didActivate rowID: UUID) { activations.append(rowID) }
        func ledgerTable(_ controller: LedgerTableController, didChangeColumns columns: [LedgerColumn]) {
            columnChanges.append(columns)
        }
        func ledgerTable(_ controller: LedgerTableController, didRequestSort columnID: LedgerColumnID, ascending: Bool) {
            singleSorts.append((columnID, ascending))
        }
        func ledgerTable(_ controller: LedgerTableController, didSetExpanded expanded: Bool, groupPath: String) {}
        func ledgerTable(_ controller: LedgerTableController, didRequestSort descriptors: [LedgerSortDescriptor]) {
            sorts.append(descriptors)
        }
    }

    static func id(_ index: Int) -> UUID { LedgerFixtures.rows[index].markupID }

    static func flat() -> (LedgerArrayRowSource, LedgerTableController) {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        return (source, controller)
    }

    /// Grouped by Project Zone: "Zone A" holds rows 0, 1, 2 and "Zone B" rows 3, 4, 5.
    static func grouped() -> (LedgerArrayRowSource, LedgerTableController) {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        controller.loadViewIfNeeded()
        return (source, controller)
    }

    // MARK: BH-045

    @Test("BH-045: a reload over a shrunken plan keeps the selection by identity and reports nothing")
    func reloadKeepsSelectionByIdentity() {
        // Old output: selectedRowIDs == {row 2} and the delegate was told {row 2} — AppKit
        // trimmed index 5 during reloadData, the unguarded selectionDidChange recomputed the
        // ids from surviving index 0 against the new plan, and an unrelated markup replaced
        // the user's two.
        let (source, controller) = Self.flat()
        let spy = Spy()
        controller.delegate = spy
        controller.applyExternalSelection([Self.id(0), Self.id(5)], scrollToFirst: false)

        source.replace(rows: [LedgerFixtures.rows[2], LedgerFixtures.rows[3], LedgerFixtures.rows[0]])
        controller.rebuildPlan()

        #expect(controller.selectedRowIDs == [Self.id(0), Self.id(5)])
        #expect(spy.selections.isEmpty, "a reload is not a user selection")
        #expect(controller.mainTableViewForTesting.selectedRowIndexes == IndexSet(integer: 2),
                "row 0's markup now sits at index 2 and is the one highlighted")
        #expect(controller.pinnedTableViewForTesting.selectedRowIndexes == IndexSet(integer: 2))
    }

    // MARK: BH-242

    @Test("BH-242: a rebuild that re-collapses a group keeps the rows hidden inside it selected")
    func rebuildKeepsCollapsedRowsSelected() {
        // Old output: selectedRowIDs == {row 0} and the delegate told the canvas to drop
        // rows 3 and 4 — restoreSelectionInViews ran before applyExpansionState collapsed
        // "Zone B", and the collapse's selection notification was not echo-guarded.
        let (_, controller) = Self.grouped()
        let spy = Spy()
        controller.delegate = spy
        let selection: Set<UUID> = [Self.id(0), Self.id(3), Self.id(4)]
        controller.applyExternalSelection(selection, scrollToFirst: false)

        controller.setCollapsedGroupPaths(["Zone B"])
        controller.rebuildPlan()

        #expect(controller.selectedRowIDs == selection)
        #expect(spy.selections.isEmpty)
    }

    // MARK: BH-243

    @Test("BH-243: a canvas selection inside a collapsed group expands it and highlights the row")
    func externalSelectionExpandsBeforeSelecting() throws {
        // Old output: outline.selectedRowIndexes was empty — the row had no visual row when
        // it was selected, and with scrollToFirst: false the group never opened at all.
        let (_, controller) = Self.grouped()
        controller.setCollapsedGroupPaths(["Zone B"])
        var persisted: [Set<String>] = []
        controller.onCollapsedGroupPathsChange = { persisted.append($0) }

        controller.applyExternalSelection([Self.id(4)], scrollToFirst: false)

        let outline = controller.outlineViewForTesting
        #expect(controller.collapsedGroupPaths.isEmpty)
        #expect(persisted == [[]], "the reveal persists the collapsed set once")
        #expect(outline.selectedRowIndexes.count == 1)
        let position = try #require(controller.displayPosition(of: Self.id(4)))
        #expect(controller.content(atVisualRow: outline.selectedRow) == .row(displayPosition: position))
        #expect(controller.pinnedTableViewForTesting.selectedRowIndexes == outline.selectedRowIndexes)
    }

    // MARK: BH-244

    @Test("BH-244: resizing and moving a column in grouped mode updates the columns")
    func groupedColumnResizeAndMove() throws {
        // Old output: columns[label].width stayed 100 and no didChangeColumns arrived — the
        // outline calls outlineViewColumnDidResize/Move, which the controller never implemented.
        let (_, controller) = Self.grouped()
        let spy = Spy()
        controller.delegate = spy
        let outline = controller.outlineViewForTesting
        let label = try #require(outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label")))

        label.width = 300
        #expect(controller.columns.first { $0.id == .label }?.width == 300)
        #expect(spy.columnChanges.isEmpty == false)

        let before = controller.columns.filter(\.visible).map(\.id)
        outline.moveColumn(0, toColumn: 2)
        let after = controller.columns.filter(\.visible).map(\.id)
        #expect(after != before, "a reorder in the outline reaches the column model")
        #expect(after == outline.tableColumns.map { LedgerColumnID($0.identifier.rawValue) })
    }

    // MARK: BH-245

    @Test("BH-245: resizing a pinned column in the band resizes it in the main table too")
    func pinnedResizeReachesMainTable() throws {
        // Old output: the main table's Label column stayed 100 pt while the band grew to
        // 260 pt, sliding the first unpinned column under the overlay.
        let (_, controller) = Self.flat()
        controller.setColumn(.label, pinned: true)
        let pinned = controller.pinnedTableViewForTesting
        let pinnedLabel = try #require(pinned.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label")))

        pinnedLabel.width = 260

        let main = controller.mainTableViewForTesting
        #expect(main.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label"))?.width == 260)
        #expect(controller.outlineViewForTesting.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label"))?.width == 260)
        #expect(controller.columns.first { $0.id == .label }?.width == 260)
    }

    // MARK: BH-246

    @Test("BH-246: expanding or collapsing a group keeps the pinned band on the selected row")
    func pinnedBandFollowsExpansion() throws {
        // Old output: after collapsing Zone A the outline selected visual row 2 while the
        // pinned band still highlighted row 5 — reloadData kept its stale index.
        let (_, controller) = Self.grouped()
        controller.setColumn(.label, pinned: true)
        let outline = controller.outlineViewForTesting
        let pinned = controller.pinnedTableViewForTesting
        // Rows: 0 "Zone A", 1-3 its rows, 4 "Zone B", 5 row 3.
        outline.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        #expect(pinned.selectedRowIndexes == IndexSet(integer: 5))

        let zoneA = try #require(outline.item(atRow: 0))
        outline.collapseItem(zoneA)
        #expect(outline.selectedRowIndexes == IndexSet(integer: 2))
        #expect(pinned.selectedRowIndexes == outline.selectedRowIndexes)

        outline.expandItem(zoneA)
        #expect(outline.selectedRowIndexes == IndexSet(integer: 5))
        #expect(pinned.selectedRowIndexes == outline.selectedRowIndexes)
    }

    // MARK: IM-100

    @Test("IM-100: Collapse All on 200 groups reloads the pinned band once and persists once")
    func collapseAllIsBatched() {
        // Old output: one pinned reloadData and one onCollapsedGroupPathsChange per group
        // (200 each), plus a full plan rebuild.
        let rows = (0..<400).map { index -> LedgerRow in
            var row = LedgerFixtures.rows[index % 6]
            row = LedgerRow(
                markupID: UUID(), values: row.values.merging([.label: .text("L\(index / 2)")]) { $1 },
                displayValues: row.displayValues.merging([.label: "L\(index / 2)"]) { $1 },
                colorRGBA: row.colorRGBA, kind: row.kind, measurementKind: row.measurementKind
            )
            return row
        }
        let source = LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source, mode: .grouped, groupingColumns: [.label])
        controller.loadViewIfNeeded()
        #expect(controller.plan.groups.count == 200)
        var persisted = 0
        controller.onCollapsedGroupPathsChange = { _ in persisted += 1 }
        let reloadsBefore = controller.pinnedReloadCountForTesting
        let buildsBefore = controller.planBuildCount

        controller.collapseAllGroups()
        #expect(controller.pinnedReloadCountForTesting - reloadsBefore == 1)
        #expect(persisted == 1)
        #expect(controller.planBuildCount == buildsBefore, "collapsing does not rebuild the plan")
        #expect(controller.pinnedTableViewForTesting.numberOfRows == controller.outlineViewForTesting.numberOfRows)
        #expect(controller.outlineViewForTesting.numberOfRows == 200)

        controller.expandAllGroups()
        #expect(controller.pinnedReloadCountForTesting - reloadsBefore == 2)
        #expect(persisted == 2)
        #expect(controller.outlineViewForTesting.numberOfRows == 600)
        #expect(controller.pinnedTableViewForTesting.numberOfRows == 600)
    }

    // MARK: IM-201

    @Test("IM-201: switching from flat to grouped builds the plan exactly once")
    func setGroupingBuildsOnce() {
        // Old output: two builds — setMode rebuilt, then setGrouping rebuilt again.
        let (_, controller) = Self.flat()
        let before = controller.planBuildCount
        controller.setGrouping([.pageLabel])
        #expect(controller.planBuildCount - before == 1)
        #expect(controller.mode == .grouped)
        controller.setGrouping([])
        #expect(controller.planBuildCount - before == 2)
        #expect(controller.mode == .flat)
    }

    // MARK: BH-738

    @Test("BH-738: replacing the row source adopts its columns and keeps the user's arrangement")
    func rowSourceSwapAdoptsColumns() {
        // Old output: controller.columns still held the first source's set, so `extra` never
        // showed and the dropped `trade` column kept drawing blank cells.
        let (_, controller) = Self.flat()
        controller.setColumns(controller.columns.map { column in
            var column = column
            if column.id == .label { column.width = 222 }
            return column
        })
        let extra = LedgerColumn(id: .custom("extra"), title: "Extra", kind: .text, width: 80)
        var newColumns = LedgerFixtures.columns.filter { $0.id != .trade }
        newColumns.append(extra)
        controller.rowSource = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: newColumns)

        let ids = controller.columns.map(\.id)
        #expect(ids.contains(.custom("extra")))
        #expect(ids.contains(.trade) == false)
        #expect(controller.columns.first { $0.id == .label }?.width == 222)
        #expect(controller.mainTableViewForTesting.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("custom.extra")) != nil)
    }

    // MARK: BH-739

    @Test("BH-739: grouped mode with no grouping levels is flat, not an empty outline")
    func groupedWithoutLevelsIsFlat() {
        // Old output: mode == .grouped and the outline had zero rows over a six-row plan.
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source, mode: .grouped)
        controller.loadViewIfNeeded()
        #expect(controller.mode == .flat)
        #expect(controller.mainTableViewForTesting.numberOfRows == 6)
        controller.setMode(.grouped)
        #expect(controller.mode == .flat)
    }

    // MARK: BH-740

    @Test("BH-740: grouped visual rows translate to display positions")
    func groupedVisibleRangeIsInDisplaySpace() {
        // Old output: 0..<5 — the outline's visual rows, headings included.
        let (_, controller) = Self.grouped()
        // Visual rows 0-4: "Zone A", positions 0, 1, 2, "Zone B".
        #expect(controller.displayRange(coveringVisualRows: 0..<5) == 0..<3)
        controller.setCollapsedGroupPaths(["Zone A"])
        // Visual rows: 0 "Zone A" (collapsed), 1 "Zone B", 2-4 positions 3, 4, 5.
        #expect(controller.displayRange(coveringVisualRows: 0..<5) == 3..<6)
    }

    // MARK: BH-741

    @Test("BH-741: a heading whose path the plan lost draws a blank cell")
    func unknownGroupPathDrawsBlank() throws {
        let (_, controller) = Self.grouped()
        let outline = controller.outlineViewForTesting
        let column = try #require(outline.tableColumns.last)
        let stale = LedgerGroupSlice(
            path: "gone", title: "Gone", column: .projectZone, value: "gone", depth: 0,
            rowRange: 0..<1, children: [], subtotals: .empty, isExpanded: true
        )
        let view = controller.outlineView(outline, viewFor: column, item: LedgerOutlineItem(slice: stale))
        let cell = try #require(view as? LedgerCellView)
        #expect(cell.textField?.stringValue == "")
        #expect(cell.textField?.accessibilityLabel() ?? "" == "")
    }
}
