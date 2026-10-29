import AppKit
import Foundation
import Observation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// IM-011: one aggregation engine.
///
/// A table over a presenter that supplies its outline (`suppliesDisplayOrderedOutline`, the
/// application's core-backed presenter) takes every heading and every subtotal from that
/// outline. It never folds rows: the plan origin is always `.supplied`, the plan's subtotals
/// are exactly the presenter's totals, and the rebuild reads no row to compute them.
///
/// The presenter below stands in for the aggregation core. Its totals are computed by its own
/// code, from its own rows, and are deliberately **not** a straight sum of the Value column
/// (the stand-in adds a fixed 0.5 m² to every node's Value total), so a heading that shows the
/// stand-in's number can only have come from the outline.
///
/// Since C-04 (R-129) that is the table's only path: the in-memory fold is deleted, the preview
/// mock supplies its outline too, and a source that supplies none is listed flat.
@MainActor
@Suite("Fix3 one aggregation engine", .ledgerTierSerialised)
struct Fix3OneAggregationEngineTests {

    private static let value = LedgerDefaultColumns.valueColumnID

    private func makeTable(
        _ presenter: CoreStandInPresenter,
        grouping: [LedgerColumnID]
    ) -> LedgerTableController {
        let source = LedgerPresenterRowSource(presenter: presenter)
        let controller = LedgerTableController(
            rowSource: source,
            mode: grouping.isEmpty ? .flat : .grouped,
            groupingColumns: grouping
        )
        controller.loadViewIfNeeded()
        return controller
    }

    /// Every slice's subtotals are the bridged totals of the presenter node at the same path.
    private func expectSubtotalsMatchCore(
        _ slices: [LedgerGroupSlice],
        _ nodes: [LedgerGroupNode],
        columns: [LedgerColumn]
    ) {
        #expect(slices.count == nodes.count)
        for (slice, node) in zip(slices, nodes) {
            #expect(slice.title == node.title)
            #expect(slice.rowCount == node.totals.rowCount)
            #expect(slice.subtotals == LedgerSubtotals.bridging(node.totals, columns: columns), "\(slice.title)")
            expectSubtotalsMatchCore(slice.children, node.children, columns: columns)
        }
    }

    @Test("IM-011 grouped: the table asks the core to partition, then draws the core's groups and numbers")
    func groupedFollowsCore() throws {
        let presenter = CoreStandInPresenter(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let table = makeTable(presenter, grouping: [.projectZone])

        // The table asked; it did not group. Until the core answers, the rows are listed at
        // the outline's root under the core's grand totals.
        #expect(presenter.requestedGroupings == [[.projectZone]])
        #expect(table.planOrigin == .supplied)
        #expect(table.plan.groups.isEmpty)
        #expect(table.plan.order == Array(0..<6))
        #expect(table.outlineView(table.outlineViewForTesting, numberOfChildrenOfItem: nil) == 6)
        #expect(table.plan.grandSubtotals == LedgerSubtotals.bridging(presenter.grandTotals, columns: table.columns))

        presenter.settle()
        let readsBefore = presenter.rowReads
        table.rebuildPlan()
        #expect(presenter.rowReads == readsBefore, "no row is read to aggregate (\(presenter.rowReads - readsBefore))")
        #expect(table.planOrigin == .supplied)
        #expect(presenter.requestedGroupings == [[.projectZone]], "an answered grouping is not requested again")
        expectSubtotalsMatchCore(table.plan.groups, presenter.rootGroups, columns: table.columns)

        // Hand-derived from the fixtures: Zone A = rows 0–2, Zone B = rows 3–5.
        // Plan Area 40 + 25 + 60 = 125 m², 15 + 90 + 10 = 115 m². The stand-in's Value total is
        // Plan Area + 0.5 m², which no fold over these rows produces.
        let zoneA = try #require(table.plan.groups.first)
        let zoneB = try #require(table.plan.groups.last)
        #expect(zoneA.title == "Zone A")
        #expect(zoneA.rowRange == 0..<3)
        #expect(zoneB.rowRange == 3..<6)
        #expect(zoneA.subtotals.result(.planArea)?.quantity == .squareMetres(125))
        #expect(zoneB.subtotals.result(.planArea)?.quantity == .squareMetres(115))
        #expect(zoneA.subtotals.result(Self.value)?.quantity == .squareMetres(Decimal(string: "125.5")!))
        #expect(table.plan.grandSubtotals.result(.planArea)?.quantity == .squareMetres(240))
        #expect(table.plan.grandSubtotals.result(Self.value)?.quantity == .squareMetres(Decimal(string: "240.5")!))
    }

    @Test("IM-011: a pending plan resolves itself when the core answers, with no host reload")
    func pendingPlanResolvesItself() async throws {
        let presenter = CoreStandInPresenter(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let table = makeTable(presenter, grouping: [.projectZone])
        #expect(table.plan.groups.isEmpty)
        let builds = table.planBuildCount

        presenter.settle()
        for _ in 0..<200 where table.plan.groups.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(table.plan.groups.map(\.title) == ["Zone A", "Zone B"])
        #expect(table.planBuildCount == builds + 1, "one rebuild, after the whole projection landed")
        #expect(table.planOrigin == .supplied)
        expectSubtotalsMatchCore(table.plan.groups, presenter.rootGroups, columns: table.columns)

        // Once resolved, the table stops watching: a later projection is the host's to reload.
        presenter.settle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(table.planBuildCount == builds + 1)
    }

    @Test("IM-011 nested: two levels, every node's subtotals are the core's")
    func nestedFollowsCore() throws {
        let presenter = CoreStandInPresenter(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        presenter.setGrouping([.projectZone, .trade])
        presenter.settle()
        let table = makeTable(presenter, grouping: [.projectZone, .trade])
        #expect(table.planOrigin == .supplied)
        #expect(presenter.requestedGroupings == [[.projectZone, .trade]])
        expectSubtotalsMatchCore(table.plan.groups, presenter.rootGroups, columns: table.columns)

        // Zone A: Concrete (rows 0, 1) and Drywall (row 2); Zone B: Drywall (3), Glazing (4, 5).
        let zoneA = try #require(table.plan.groups.first)
        #expect(zoneA.children.map(\.title) == ["Concrete", "Drywall"])
        #expect(zoneA.children.map(\.rowRange) == [0..<2, 2..<3])
        #expect(zoneA.children.first?.subtotals.result(.planArea)?.quantity == .squareMetres(65))
        let zoneB = try #require(table.plan.groups.last)
        #expect(zoneB.children.map(\.rowRange) == [3..<4, 4..<6])
        #expect(zoneB.children.last?.subtotals.result(.planLength)?.quantity == .metres(33))
    }

    @Test("IM-011 filtered: the core's filtered outline and grand total, nothing re-added")
    func filteredFollowsCore() throws {
        let presenter = CoreStandInPresenter(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        presenter.keep = { $0.displayValue(.projectZone) == "Zone B" }
        presenter.setGrouping([.trade])
        presenter.settle()
        let table = makeTable(presenter, grouping: [.trade])
        #expect(table.planOrigin == .supplied)
        #expect(table.plan.order.count == 3)
        expectSubtotalsMatchCore(table.plan.groups, presenter.rootGroups, columns: table.columns)
        // Zone B only: 15 + 90 + 10 = 115 m².
        #expect(table.plan.grandSubtotals.rowCount == 3)
        #expect(table.plan.grandSubtotals.result(.planArea)?.quantity == .squareMetres(115))
        #expect(table.plan.groups.map(\.title) == ["Drywall", "Glazing"])
    }

    @Test("IM-011 empty: an empty ledger has no groups and an empty grand total, grouped or flat")
    func emptyFollowsCore() {
        for grouping in [[], [LedgerColumnID.projectZone]] {
            let presenter = CoreStandInPresenter(rows: [], columns: LedgerFixtures.columns)
            let table = makeTable(presenter, grouping: grouping)
            presenter.settle()
            table.rebuildPlan()
            #expect(table.planOrigin == .supplied)
            #expect(table.plan.order.isEmpty)
            #expect(table.plan.groups.isEmpty)
            #expect(table.plan.grandSubtotals.rowCount == 0)
            #expect(table.plan.grandSubtotals.results.isEmpty)
            #expect(table.outlineView(table.outlineViewForTesting, numberOfChildrenOfItem: nil) == 0)
        }
    }

    @Test("IM-011 flat: the grand totals are the core's, and a regroup is requested, never folded")
    func flatAndRegroup() {
        let presenter = CoreStandInPresenter(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        presenter.settle()
        let table = makeTable(presenter, grouping: [])
        #expect(table.planOrigin == .supplied)
        #expect(table.plan.grandSubtotals == LedgerSubtotals.bridging(presenter.grandTotals, columns: table.columns))
        #expect(presenter.requestedGroupings.isEmpty, "the presenter was already flat")

        let reads = presenter.rowReads
        table.setGrouping([.trade])
        #expect(presenter.requestedGroupings == [[.trade]])
        #expect(table.planOrigin == .supplied)
        #expect(table.plan.groups.isEmpty, "pending until the core answers")
        presenter.settle()
        table.rebuildPlan()
        #expect(table.plan.groups.map(\.title) == ["Concrete", "Drywall", "Glazing"])
        #expect(presenter.rowReads == reads, "regrouping read no row (\(presenter.rowReads - reads))")
    }

    @Test("IM-011: a level the core cannot group by is dropped, as the core drops it")
    func displayOnlyLevelIsDropped() {
        let presenter = CoreStandInPresenter(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let unit = LedgerDefaultColumns.unitColumnID
        presenter.setGrouping([.projectZone, unit])
        presenter.settle()
        let table = makeTable(presenter, grouping: [.projectZone, unit])
        #expect(table.planOrigin == .supplied)
        #expect(table.plan.groupingColumns == [.projectZone, unit])
        #expect(table.plan.groups.map(\.title) == ["Zone A", "Zone B"])
        #expect(table.plan.groups.allSatisfy { $0.isLeaf })
    }

    @Test("IM-011: a core refusal keeps its meaning — mixed units stay mixed, a failed total says error")
    func refusalsKeepTheirMeaning() {
        let totals = LedgerTotals(
            rowCount: 2,
            quantities: [.planArea: .squareMetres(5)],
            displayValues: [
                .planArea: "5 m²",
                LedgerFixtures.mixed: LedgerTotals.incompatiblePlaceholder,
                .totalCost: "Cannot total"
            ],
            incompatibleColumns: [LedgerFixtures.mixed, .totalCost, .planLength]
        )
        let bridged = LedgerSubtotals.bridging(totals, columns: LedgerFixtures.columns)
        #expect(bridged.result(.planArea)?.quantity == .squareMetres(5))
        // W-069: the result is the one representation of a refusal; the parallel
        // `isMixedUnits(_:)` / `isFailed(_:)` sets that restated it are gone.
        #expect(bridged.result(LedgerFixtures.mixed)?.isMixedUnits == true)
        #expect(bridged.result(LedgerFixtures.mixed)?.isFailed == false)
        #expect(bridged.result(.totalCost)?.isFailed == true)
        #expect(bridged.result(.totalCost)?.isMixedUnits == false)
        // A refusal with no words at all reads as the unit conflict, as it always did.
        #expect(bridged.result(.planLength)?.isMixedUnits == true)
        #expect(bridged.result(.planLength)?.isFailed == false)
    }

    @Test("C-04: one path for every source — the preview mock supplies its outline, like the core-backed presenter")
    func onePathPerSource() throws {
        // Old output: `mock.suppliesDisplayOrderedOutline == false`, `usesPresenterGroupOutline
        // == false`, and the table over the mock reported `planOrigin == .folded`.
        let mock = MockLedgerPresenter()
        #expect(mock.suppliesDisplayOrderedOutline)
        let mockSource = LedgerPresenterRowSource(presenter: mock)
        #expect(mockSource.usesPresenterGroupOutline)
        let mockTable = LedgerTableController(rowSource: mockSource, mode: .grouped, groupingColumns: [.projectZone, .icon])
        mockTable.loadViewIfNeeded()
        #expect(mockTable.planOrigin == .supplied)
        #expect(mock.groupingColumns == [.projectZone, .icon], "the table asked the mock to group")
        #expect(mockTable.plan.order == Array(0..<mock.rowCount), "display order is group order")
        expectSubtotalsMatchCore(mockTable.plan.groups, mock.rootGroups, columns: mockTable.columns)
        #expect(mockTable.plan.grandSubtotals == LedgerSubtotals.bridging(mock.grandTotals, columns: mockTable.columns))
        let zone = try #require(mockTable.plan.groups.first)
        let tool = try #require(zone.children.first)
        #expect(tool.subtotals.result(Self.value)?.quantity != nil, "a type group carries the merged Value total")

        let core = CoreStandInPresenter(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let coreSource = LedgerPresenterRowSource(presenter: core)
        #expect(coreSource.usesPresenterGroupOutline)
        // Whatever the table asks for, the core-backed source answers: grouped, nested, flat.
        for grouping in [[LedgerColumnID.projectZone], [.projectZone, .trade], [], [.status]] {
            let plan = coreSource.ledgerGroupPlan(groupingColumns: grouping, columns: LedgerFixtures.columns)
            #expect(plan != nil, "\(grouping)")
            #expect(plan?.groupingColumns == grouping)
            #expect(plan?.order.count == core.rowCount)
        }

        // A host can still switch the outline off; the table then lists the rows flat.
        coreSource.usesPresenterGroupOutline = false
        #expect(coreSource.ledgerGroupPlan(groupingColumns: [.projectZone], columns: LedgerFixtures.columns) == nil)
    }

    @Test("C-04: a source that supplies no outline is listed flat — no headings, no subtotals, no row read")
    func unsuppliedSourceIsFlat() {
        // Old output: `planOrigin == .folded`; the table read every row and built two Zone
        // groups with subtotals of its own (Plan Area 125 m² and 115 m²).
        let source = PlainRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let table = LedgerTableController(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        table.loadViewIfNeeded()
        let reads = source.rowReads
        table.rebuildPlan()
        #expect(table.planOrigin == .unsupplied)
        #expect(table.plan.groups.isEmpty)
        #expect(table.plan.order == Array(0..<LedgerFixtures.rows.count))
        #expect(table.plan.groupingColumns == [.projectZone])
        #expect(table.plan.grandSubtotals.rowCount == LedgerFixtures.rows.count)
        #expect(table.plan.grandSubtotals.results.isEmpty)
        #expect(source.rowReads == reads, "building the plan read \(source.rowReads - reads) rows")
        #expect(table.outlineView(table.outlineViewForTesting, numberOfChildrenOfItem: nil) == LedgerFixtures.rows.count)

        // The same for a presenter that keeps the protocol default.
        let presenter = CoreStandInPresenter(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let presenterSource = LedgerPresenterRowSource(presenter: presenter)
        presenterSource.usesPresenterGroupOutline = false
        let presenterTable = LedgerTableController(rowSource: presenterSource, mode: .grouped, groupingColumns: [.projectZone])
        presenterTable.loadViewIfNeeded()
        #expect(presenterTable.planOrigin == .unsupplied)
        #expect(presenterTable.plan.groups.isEmpty)
        #expect(presenter.requestedGroupings.isEmpty, "an outline that is off is never requested")
    }
}

/// A source with no outline to offer: rows only, counting every read.
@MainActor
private final class PlainRowSource: LedgerRowProviding {
    let rows: [LedgerRow]
    let ledgerColumns: [LedgerColumn]
    private(set) var rowReads = 0

    init(rows: [LedgerRow], columns: [LedgerColumn]) {
        self.rows = rows
        self.ledgerColumns = columns
    }

    var ledgerRowCount: Int { rows.count }
    func ledgerRow(at index: Int) -> LedgerRow? {
        rowReads += 1
        return rows.indices.contains(index) ? rows[index] : nil
    }
}

/// A stand-in for the application's core-backed presenter: display order is group order,
/// every node carries its descendants' row count and full totals, and regrouping is
/// asynchronous — ``setGrouping(_:)`` records the request and ``settle()`` answers it.
@Observable
@MainActor
final class CoreStandInPresenter: LedgerPresenting {
    let allRows: [LedgerRow]
    var columns: [LedgerColumn]
    var rootGroups: [LedgerGroupNode] = []
    var contentRevision = 0
    var grandTotals = LedgerTotals.empty
    var groupingColumns: [LedgerColumnID] = []
    var filter = LedgerFilterGroup(id: LedgerFixtures.id(990))
    var canvasFilterBehavior: LedgerCanvasFilterBehavior = .dimNonMatching
    var selectedRowIDs: Set<UUID> = []
    var sortDescriptors: [LedgerSortDescriptor] = []
    var isLoading = false
    /// The filter, as a predicate; applied on ``settle()``.
    @ObservationIgnored var keep: (LedgerRow) -> Bool = { _ in true }
    @ObservationIgnored private(set) var rowReads = 0
    @ObservationIgnored private(set) var requestedGroupings: [[LedgerColumnID]] = []
    @ObservationIgnored private var ordered: [LedgerRow] = []
    @ObservationIgnored private var nextNodeID = 0

    var suppliesDisplayOrderedOutline: Bool { true }

    init(rows: [LedgerRow], columns: [LedgerColumn]) {
        self.allRows = rows
        self.columns = columns
        self.ordered = rows
        self.grandTotals = Self.totals(rows, extra: true)
    }

    var rowCount: Int { ordered.count }
    func row(at index: Int) -> LedgerRow? {
        rowReads += 1
        return ordered.indices.contains(index) ? ordered[index] : nil
    }
    func index(of markupID: UUID) -> Int? { ordered.firstIndex { $0.markupID == markupID } }
    func prefetchRows(in range: Range<Int>) {}

    func setGrouping(_ columns: [LedgerColumnID]) {
        requestedGroupings.append(columns)
        groupingColumns = columns
        isLoading = true
    }

    /// Answers the pending request: partitions, orders and totals, the way the core does.
    func settle() {
        let visible = allRows.filter(keep)
        let known = Set(columns.map(\.id))
        let levels = groupingColumns.filter { known.contains($0) }
        rootGroups = levels.isEmpty ? [] : partition(visible, levels: levels, depth: 0)
        ordered = levels.isEmpty ? visible : rootGroups.flatMap(leafRows)
        grandTotals = Self.totals(visible, extra: true)
        isLoading = false
        contentRevision += 1
    }

    @ObservationIgnored private var membership: [UUID: [LedgerRow]] = [:]

    private func leafRows(_ node: LedgerGroupNode) -> [LedgerRow] {
        node.children.isEmpty ? (membership[node.id] ?? []) : node.children.flatMap(leafRows)
    }

    private func partition(_ rows: [LedgerRow], levels: [LedgerColumnID], depth: Int) -> [LedgerGroupNode] {
        let column = levels[depth]
        let keys = Array(Set(rows.map { $0.displayValue(column) })).sorted()
        return keys.map { key in
            let members = rows.filter { $0.displayValue(column) == key }
            nextNodeID += 1
            let id = LedgerFixtures.id(2_000 + nextNodeID)
            let children = depth + 1 < levels.count ? partition(members, levels: levels, depth: depth + 1) : []
            if children.isEmpty { membership[id] = members }
            return LedgerGroupNode(
                id: id, title: key, groupingColumn: column, groupingValue: "k:" + key,
                depth: depth, children: children, rows: [], totals: Self.totals(members, extra: true)
            )
        }
    }

    /// The stand-in's own totals: a straight sum per summed column, the Value total = Plan
    /// Area + 0.5 m² (a number no fold over the rows can produce), mixed units refused.
    static func totals(_ rows: [LedgerRow], extra: Bool) -> LedgerTotals {
        var totals = LedgerTotals(rowCount: rows.count)
        for column in [LedgerColumnID.count, .planLength, .planArea, LedgerFixtures.mixed] {
            var running: DecimalQuantity?
            var mixed = false
            for row in rows {
                guard let quantity = row.quantity(column) else { continue }
                if let current = running {
                    guard let sum = try? current.adding(quantity) else { mixed = true; break }
                    running = sum
                } else {
                    running = quantity
                }
            }
            if mixed {
                totals.incompatibleColumns.insert(column)
                totals.displayValues[column] = LedgerTotals.incompatiblePlaceholder
            } else if let running {
                totals.quantities[column] = running
            }
        }
        if extra, let area = totals.quantities[.planArea] {
            totals.quantities[LedgerDefaultColumns.valueColumnID] = DecimalQuantity(
                value: area.value + Decimal(string: "0.5")!, dimension: .area
            )
        }
        return totals
    }

    func setFilter(_ filter: LedgerFilterGroup) { self.filter = filter }
    func setCanvasFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) { canvasFilterBehavior = behavior }
    func setColumnVisible(_ visible: Bool, columnID: LedgerColumnID) {}
    func setColumnWidth(_ width: Double, columnID: LedgerColumnID) {}
    func setColumnPinned(_ pinned: Bool, columnID: LedgerColumnID) {}
    func moveColumn(_ columnID: LedgerColumnID, to index: Int) {}
    func toggleGroup(id: LedgerGroupNode.ID) {}
    func select(rowIDs: Set<UUID>, additive: Bool) { selectedRowIDs = rowIDs }
    func sort(by columnID: LedgerColumnID, ascending: Bool) {}
    func totals(forGroup groupID: LedgerGroupNode.ID?) -> LedgerTotals { grandTotals }
}
