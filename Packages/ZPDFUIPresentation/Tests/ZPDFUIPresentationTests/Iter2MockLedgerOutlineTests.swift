import Foundation
import Testing
@testable import ZPDFUIPresentation

/// C-04 (R-129 remainder): the preview mock publishes its ledger outline the way the
/// application's presenter does, so the Quantity Ledger table has one aggregation path and the
/// table's own in-memory fold could be deleted.
///
/// Old output: `MockLedgerPresenter.suppliesDisplayOrderedOutline == false`; its rows were in
/// sort order across every group (display order was not group order), only the first grouping
/// level was honoured, a Type grouping bucketed on the raw `.icon` cell, and no node carried the
/// display `Value` column's merged total — so a table over the mock folded rows itself
/// (`LedgerTableController.planOrigin == .folded`).
@MainActor
@Suite("Iter2 C-04: the mock's display-ordered outline")
struct Iter2MockLedgerOutlineTests {

    private static let value = LedgerDefaultColumns.valueColumnID

    /// Walks an outline against the presenter's rows: every node covers the next
    /// `totals.rowCount` display positions, children partition their parent, and every row
    /// under a node carries the node's key on the node's level.
    private func expectDisplayOrdered(
        _ nodes: [LedgerGroupNode],
        ledger: MockLedgerPresenter,
        start: Int
    ) -> Int {
        var cursor = start
        for node in nodes {
            let range = cursor..<(cursor + node.totals.rowCount)
            if node.children.isEmpty {
                #expect(node.rows.map(\.markupID) == range.compactMap { ledger.row(at: $0)?.markupID }, "\(node.title)")
            } else {
                let end = expectDisplayOrdered(node.children, ledger: ledger, start: cursor)
                #expect(end == range.upperBound, "\(node.title): children cover \(end - cursor) of \(range.count)")
            }
            cursor = range.upperBound
        }
        return cursor
    }

    @Test("C-04: the mock supplies a display-ordered outline for flat, one-level and nested groupings")
    func mockSuppliesItsOutline() {
        let ledger = MockLedgerPresenter()
        #expect(ledger.suppliesDisplayOrderedOutline)
        let existential: any LedgerPresenting = ledger
        #expect(existential.suppliesDisplayOrderedOutline, "dispatched through the protocol")

        for grouping in [[LedgerColumnID.projectZone], [.icon], [.projectZone, .icon], [.status, .subject]] {
            ledger.setGrouping(grouping)
            #expect(!ledger.rootGroups.isEmpty, "\(grouping)")
            #expect(expectDisplayOrdered(ledger.rootGroups, ledger: ledger, start: 0) == ledger.rowCount, "\(grouping)")
            #expect(ledger.rootGroups.reduce(0) { $0 + $1.totals.rowCount } == ledger.rowCount)
            for node in ledger.allGroups {
                #expect(node.groupingColumn == grouping[node.depth], "\(node.title) at depth \(node.depth)")
                #expect(node.children.isEmpty == (node.depth == grouping.count - 1))
            }
        }

        ledger.setGrouping([])
        #expect(ledger.rootGroups.isEmpty)
        #expect(ledger.grandTotals.rowCount == ledger.rowCount)
    }

    @Test("C-04: Type groups partition by tool and carry the merged Value total")
    func typeGroupsCarryTheValueTotal() throws {
        let ledger = MockLedgerPresenter()
        ledger.setGrouping([.icon])
        let titles = ledger.rootGroups.map(\.title)
        #expect(titles.contains(MeasurementKind.area.displayName))
        #expect(titles.contains(MeasurementKind.length.displayName))
        #expect(!titles.contains(""))

        let area = try #require(ledger.rootGroups.first { $0.title == MeasurementKind.area.displayName })
        #expect(area.totals.total(Self.value)?.dimension == .area)
        #expect(!area.totals.displayValue(Self.value).isEmpty)
        let expected = area.rows.compactMap { LedgerDefaultColumns.primaryQuantity(for: $0)?.value }.reduce(0, +)
        #expect(area.totals.total(Self.value)?.value == expected)
        // The totals the table's bridge reads for a summed column are the mock's straight sums.
        #expect(area.totals.total(.planArea) == LedgerTotals.mockSumming(
            rows: area.rows, columns: ledger.columns, format: { _, quantity in SampleFormatting.string(quantity) }
        ).total(.planArea))
        // A zone that mixes tools refuses its merged Value rather than inventing one.
        ledger.setGrouping([.projectZone])
        let zone = try #require(ledger.rootGroups.first {
            Set($0.rows.compactMap { LedgerDefaultColumns.primaryQuantity(for: $0)?.dimension }).count > 1
        })
        #expect(zone.totals.incompatibleColumns.contains(Self.value))
        #expect(zone.totals.displayValue(Self.value) == LedgerTotals.incompatiblePlaceholder)
        // Grouping never changes a grand total.
        let grouped = ledger.grandTotals
        ledger.setGrouping([])
        #expect(ledger.grandTotals == grouped)
    }

    @Test("C-04: node identity follows the group path, so a regroup keeps it and totals(forGroup:) finds nested nodes")
    func identityAndNestedTotals() throws {
        let ledger = MockLedgerPresenter()
        ledger.setGrouping([.projectZone, .icon])
        let ids = ledger.allGroups.map(\.id)
        #expect(Set(ids).count == ids.count)
        ledger.setFilter(LedgerFilterGroup(id: UUID()))
        #expect(ledger.allGroups.map(\.id) == ids)
        let child = try #require(ledger.rootGroups.first?.children.first)
        #expect(ledger.totals(forGroup: child.id) == child.totals)
    }

    // MARK: Grouping rules the mock keeps from the retired fold

    private static func row(
        _ index: Int,
        _ values: [LedgerColumnID: LedgerCellValue],
        display: [LedgerColumnID: String] = [:],
        kind: MeasurementKind? = .length
    ) -> LedgerRow {
        LedgerRow(
            markupID: SampleFormatting.sampleID(9_000 + index), values: values, displayValues: display,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan, kind: .measurement, measurementKind: kind
        )
    }

    @Test("Choice groups follow the option order (BH-239)")
    func choiceOrder() {
        let options = ["open", "inProgress", "accepted"].enumerated().map {
            LedgerChoiceOption(id: SampleFormatting.sampleID(9_100 + $0.offset), value: $0.element, title: $0.element,
                               colorRGBA: ColorRGBA.Zenit.Dark.cyan, order: $0.offset)
        }
        let status = LedgerColumn(id: .status, title: "Status", kind: .choice, width: 80, choices: options)
        let rows = ["accepted", "open", "inProgress", "open"].enumerated().map { Self.row($0.offset, [.status: .choice($0.element)]) }
        let outline = MockLedgerOutline.build(rows: rows, groupingColumns: [.status], columns: [status])
        #expect(outline.rootGroups.map(\.groupingValue) == ["open", "inProgress", "accepted"])
        #expect(outline.order == [1, 3, 2, 0])
    }

    @Test("Check boxes read as states; numbers group canonically and sort numerically; dates group by day (BH-728, BH-730)")
    func canonicalKeys() {
        let flag = LedgerColumnID.custom("done")
        let checks = [Self.row(0, [flag: .checkbox(true)], display: [flag: "✓"]), Self.row(1, [flag: .checkbox(false)])]
        let byFlag = MockLedgerOutline.build(rows: checks, groupingColumns: [flag], columns: [])
        #expect(Set(byFlag.rootGroups.map(\.title)) == ["Checked", "Not checked"])

        let amount = LedgerColumnID.custom("amount")
        let numbers = [Decimal(string: "10.00")!, 10, -5, -10].enumerated().map { Self.row($0.offset, [amount: .number($0.element)]) }
        let byAmount = MockLedgerOutline.build(rows: numbers, groupingColumns: [amount], columns: [])
        #expect(byAmount.rootGroups.map(\.groupingValue) == ["-10", "-5", "10"])

        let created = LedgerColumnID.custom("createdOn")
        let morning = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)).addingTimeInterval(9 * 3600)
        let dated = [Self.row(0, [created: .date(morning)]), Self.row(1, [created: .date(morning.addingTimeInterval(5 * 3600))])]
        #expect(MockLedgerOutline.build(rows: dated, groupingColumns: [created], columns: []).rootGroups.count == 1)
    }

    @Test("Rows with no value come last at every level (CR-65), and nesting partitions its parent")
    func emptyLastAndNesting() throws {
        let zone = LedgerColumnID.projectZone
        let trade = LedgerColumnID.trade
        let rows = [
            Self.row(0, [zone: .text("Zone B"), trade: .text("Concrete")]),
            Self.row(1, [trade: .text("Concrete")]),
            Self.row(2, [zone: .text("Zone A"), trade: .text("Drywall")]),
            Self.row(3, [zone: .text("Zone A"), trade: .text("Concrete")])
        ]
        let outline = MockLedgerOutline.build(rows: rows, groupingColumns: [zone], columns: [])
        #expect(outline.rootGroups.map(\.title) == ["Zone A", "Zone B", MockLedgerOutline.emptyGroupTitle])
        #expect(outline.order == [2, 3, 0, 1])

        let nested = MockLedgerOutline.build(rows: rows, groupingColumns: [trade, zone], columns: [])
        let concrete = try #require(nested.rootGroups.first { $0.title == "Concrete" })
        #expect(concrete.children.map(\.title) == ["Zone A", "Zone B", MockLedgerOutline.emptyGroupTitle])
        #expect(concrete.children.reduce(0) { $0 + $1.totals.rowCount } == concrete.totals.rowCount)
        #expect(nested.order == [3, 0, 1, 2])
    }

    @Test("The merged Value never sums a slope ratio or an angle (BH-240), and refuses mixed units")
    func valueRefusals() {
        let slopes = [Decimal(string: "0.25")!, Decimal(string: "0.5")!].enumerated().map {
            Self.row($0.offset, [.slopeRatio: .quantity(DecimalQuantity(value: $0.element, dimension: .ratio))], kind: .slope)
        }
        let slopeTotals = MockLedgerOutline.totals(slopes, columns: [])
        #expect(slopeTotals.total(Self.value) == nil)
        #expect(!slopeTotals.incompatibleColumns.contains(Self.value))

        let mixed = [
            Self.row(0, [.planLength: .quantity(.metres(2))], kind: .length),
            Self.row(1, [.planArea: .quantity(.squareMetres(3))], kind: .area)
        ]
        let mixedTotals = MockLedgerOutline.totals(mixed, columns: [])
        #expect(mixedTotals.total(Self.value) == nil)
        #expect(mixedTotals.incompatibleColumns.contains(Self.value))

        let lengths = [Self.row(0, [.planLength: .quantity(.metres(2))]), Self.row(1, [.planLength: .quantity(.metres(5))])]
        #expect(MockLedgerOutline.totals(lengths, columns: []).total(Self.value) == .metres(7))
    }
}
