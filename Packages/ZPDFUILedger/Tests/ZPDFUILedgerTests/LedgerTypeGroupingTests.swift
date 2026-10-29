import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// The ledger groups by measurement type by default, group
/// headers carry the count and the summed compatible values in the same columns as their
/// children (Length shows total metres; Area shows summed area *and* summed perimeter),
/// collapsed state persists, and no total is ever changed by grouping.
@MainActor
@Suite("Ledger type grouping", .ledgerTierSerialised)
struct LedgerTypeGroupingTests {

    // MARK: Fixtures — four lengths and two areas, the acceptance drawing

    private static let perimeterColumn = LedgerColumn(
        id: .perimeter, title: "Perimeter", kind: .number, dimension: .length,
        width: 96, alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m"
    )

    /// The engine-shaped columns plus Perimeter, arranged the way the table arranges them —
    /// which is what puts the display Value/Unit columns (and their `.sum`) into play.
    private var columns: [LedgerColumn] {
        LedgerDefaultColumns.arranged(LedgerFixtures.columns + [Self.perimeterColumn])
    }

    private func lengthRow(_ index: Int, metres: Decimal) -> LedgerRow {
        var row = LedgerFixtures.row(
            index, subject: "Length", label: "L-\(index)", zone: "Zone A", trade: "Concrete",
            status: "draft", count: 0, length: metres, area: 0, cost: 0, waste: 0,
            mixedDimension: .length, mixedValue: 0
        )
        row.measurementKind = .length
        row.values[.planArea] = .empty
        row.displayValues[.planArea] = ""
        row.values[.count] = .empty
        row.displayValues[.count] = ""
        return row
    }

    private func areaRow(_ index: Int, squareMetres: Decimal, perimeter: Decimal) -> LedgerRow {
        var row = LedgerFixtures.row(
            index, subject: "Area", label: "A-\(index)", zone: "Zone A", trade: "Concrete",
            status: "draft", count: 0, length: 0, area: squareMetres, cost: 0, waste: 0,
            mixedDimension: .area, mixedValue: 0
        )
        row.measurementKind = .area
        row.values[.planLength] = .empty
        row.displayValues[.planLength] = ""
        row.values[.count] = .empty
        row.displayValues[.count] = ""
        row.values[.perimeter] = .quantity(.metres(perimeter))
        row.displayValues[.perimeter] = "\(perimeter) m"
        return row
    }

    /// The acceptance drawing: four lengths (2 + 5 + 8 + 15 = 30 m) and two areas
    /// (40 + 52 = 92 m², perimeters 26 + 30 = 56 m).
    private var rows: [LedgerRow] {
        [
            lengthRow(0, metres: 2), lengthRow(1, metres: 5),
            lengthRow(2, metres: 8), lengthRow(3, metres: 15),
            areaRow(4, squareMetres: 40, perimeter: 26),
            areaRow(5, squareMetres: 52, perimeter: 30)
        ]
    }

    /// The plan a table over these rows draws: the source's outline, which for the in-memory
    /// test source is the preview mock's (`MockLedgerOutline`), bridged as a presenter's is.
    /// The table has no fold of its own since C-04 (R-129).
    private func suppliedPlan(_ grouping: [LedgerColumnID]) throws -> LedgerGroupPlan {
        try #require(LedgerArrayRowSource.plan(rows: rows, groupingColumns: grouping, columns: columns))
    }

    // MARK: Grouping by type

    @Test("Grouping on the Type column partitions by tool, exactly as the Type cell reads")
    func typeGroupingPartitionsByTool() throws {
        let plan = try suppliedPlan(LedgerDefaultColumns.defaultGroupingColumns)
        #expect(LedgerDefaultColumns.defaultGroupingColumns == [.icon])
        #expect(plan.groups.count == 2)
        let byTitle = Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.title, $0) })
        #expect(byTitle[MeasurementKind.length.displayName]?.rowCount == 4)
        #expect(byTitle[MeasurementKind.area.displayName]?.rowCount == 2)
    }

    @Test("The Length header shows one merged total in the Value column: total metres")
    func lengthHeaderSumsMetres() throws {
        let plan = try suppliedPlan([.icon])
        let length = try #require(plan.groups.first { $0.title == MeasurementKind.length.displayName })
        let value = try #require(length.subtotals.result(LedgerDefaultColumns.valueColumnID))
        #expect(value.quantity?.value == Decimal(30))
        #expect(value.quantity?.dimension == .length)
        // The Value cell shows the number; the Unit cell shows the symbol — same split
        // as every child row.
        let text = value.displayText()
        #expect(LedgerDefaultColumns.splitUnit(text).unit == "m")
    }

    @Test("The Area header shows summed area AND summed perimeter, in their own columns")
    func areaHeaderSumsAreaAndPerimeter() throws {
        let plan = try suppliedPlan([.icon])
        let area = try #require(plan.groups.first { $0.title == MeasurementKind.area.displayName })
        let value = try #require(area.subtotals.result(LedgerDefaultColumns.valueColumnID))
        #expect(value.quantity?.value == Decimal(92))
        #expect(value.quantity?.dimension == .area)
        let perimeter = try #require(area.subtotals.result(.perimeter))
        #expect(perimeter.quantity?.value == Decimal(56))
        #expect(perimeter.quantity?.dimension == .length)
        // Length rows carry no perimeter, so the Length group's perimeter cell is empty —
        // never a zero pretending to be a measurement.
        let length = try #require(plan.groups.first { $0.title == MeasurementKind.length.displayName })
        #expect(length.subtotals.result(.perimeter)?.quantity == nil)
    }

    @Test("A group that mixes types refuses the merged Value rather than inventing one")
    func mixedTypeGroupRefusesTheValueSum() throws {
        // Group by zone: every row is Zone A, so lengths and areas share one group.
        let plan = try suppliedPlan([.projectZone])
        let zone = try #require(plan.groups.first)
        #expect(zone.subtotals.result(LedgerDefaultColumns.valueColumnID)?.isMixedUnits == true)
    }

    @Test("No total is ever changed by grouping: grand totals agree across every grouping")
    func groupingNeverChangesTotals() throws {
        let flat = try suppliedPlan([])
        let byType = try suppliedPlan([.icon])
        let byZone = try suppliedPlan([.projectZone])
        for column in [LedgerColumnID.planLength, .planArea, .perimeter, LedgerDefaultColumns.valueColumnID] {
            let reference = flat.grandSubtotals.result(column)
            #expect(byType.grandSubtotals.result(column) == reference, "\(column) changed under type grouping")
            #expect(byZone.grandSubtotals.result(column) == reference, "\(column) changed under zone grouping")
        }
    }

    // MARK: Collapsed state persists

    @Test("Collapsing a group is reported, survives a rebuild, and restores into a fresh table")
    func collapsedStatePersists() throws {
        let source = LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns + [Self.perimeterColumn])
        let controller = LedgerTableController(
            rowSource: source, mode: .grouped, groupingColumns: [.icon]
        )
        controller.loadViewIfNeeded()
        controller.rebuildPlan()

        var reported: Set<String>?
        controller.onCollapsedGroupPathsChange = { reported = $0 }

        let lengthPath = try #require(
            controller.plan.groups.first { $0.title == MeasurementKind.length.displayName }?.path
        )
        controller.collapseAllGroups()
        #expect(reported == controller.plan.allPaths)

        controller.expandAllGroups()
        #expect(reported?.isEmpty == true)

        // A fresh controller restoring a persisted set comes back collapsed.
        let restored = LedgerTableController(
            rowSource: source, mode: .grouped, groupingColumns: [.icon]
        )
        restored.loadViewIfNeeded()
        restored.setCollapsedGroupPaths([lengthPath])
        #expect(restored.collapsedGroupPaths == [lengthPath])
        // The plan itself never loses the collapsed group's rows or totals.
        #expect(restored.plan.order.count == rows.count)

        // Collapsing Length to one line is exactly the merged view type grouping exists for:
        // the heading stays visible with its subtotals, the four child rows do not.
        var visibleGroupPaths: [String] = []
        var visibleRowPositions: [Int] = []
        var visual = 0
        while true {
            switch restored.content(atVisualRow: visual) {
            case let .group(path): visibleGroupPaths.append(path)
            case let .row(position): visibleRowPositions.append(position)
            case .none: visual = -1
            }
            if visual == -1 { break }
            visual += 1
        }
        #expect(visibleGroupPaths.contains(lengthPath), "the collapsed group's heading row is gone")
        #expect(visibleGroupPaths.count == 2)
        #expect(visibleRowPositions.count == 2, "the Length group's child rows should be hidden")
    }

    @Test("Unknown persisted paths are kept, so a filtered-out group comes back collapsed")
    func unknownCollapsedPathsSurvive() {
        let source = LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns + [Self.perimeterColumn])
        let controller = LedgerTableController(
            rowSource: source, mode: .grouped, groupingColumns: [.icon]
        )
        controller.loadViewIfNeeded()
        controller.setCollapsedGroupPaths(["Volume"])
        #expect(controller.collapsedGroupPaths.contains("Volume"))
    }

    // MARK: The Perimeter column in the arranged set

    @Test("The arranged column set shows Perimeter after Value/Unit with its unit and sum")
    func arrangedSetCarriesPerimeter() throws {
        let visible = columns.filter(\.visible).map(\.id)
        let unitIndex = try #require(visible.firstIndex(of: LedgerDefaultColumns.unitColumnID))
        #expect(visible.indices.contains(unitIndex + 1) && visible[unitIndex + 1] == .perimeter)
        let perimeter = try #require(columns.first { $0.id == .perimeter })
        #expect(perimeter.aggregate == .sum)
        #expect(perimeter.alignment == .trailing)
        #expect(perimeter.displayUnitSymbol == "m")
    }

    @Test("The heading text lands in a column wide enough to hold it")
    func headingLandsInAWideColumn() throws {
        let source = LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns + [Self.perimeterColumn])
        let controller = LedgerTableController(
            rowSource: source, mode: .grouped, groupingColumns: [.icon]
        )
        controller.loadViewIfNeeded()
        let headingID = try #require(controller.groupHeadingColumnID)
        let heading = try #require(controller.columns.first { $0.id == headingID })
        #expect(heading.visible)
        #expect(heading.width >= 90, "\(headingID) is too narrow for 'Length (6)'")
    }

    @Test("The grand-total bar stays as it is: display columns never grow a pill")
    func grandTotalBarUnchanged() throws {
        let plan = try suppliedPlan([.icon])
        // The bar's filter is what keeps the display Value sum out of the grand strip.
        let barColumns = columns.filter {
            $0.visible
                && !LedgerDefaultColumns.isDisplayColumn($0.id)
                && plan.grandSubtotals.result($0.id) != nil
        }
        #expect(!barColumns.contains { LedgerDefaultColumns.isDisplayColumn($0.id) })
        // The value sum still exists for the group headers.
        #expect(plan.grandSubtotals.result(LedgerDefaultColumns.valueColumnID) != nil)
    }
}
