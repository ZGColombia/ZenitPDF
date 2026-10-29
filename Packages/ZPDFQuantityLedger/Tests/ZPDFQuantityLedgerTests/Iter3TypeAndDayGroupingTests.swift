import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// T-046: the Type cell is the measurement tool, so grouping, sorting and filtering on Type
/// work per tool. T-047: a date grouping level groups by calendar day, in the builder and in
/// the incremental editor alike.
@Suite("Iteration 3 — Type is the tool, dates group by day")
struct Iter3TypeAndDayGroupingTests {

    private static func record(
        _ index: Int,
        kind: MarkupKind = .measurement,
        tool: MeasurementTool?,
        createdAt: Date = SyntheticLedger.epoch,
        modifiedAt: Date = SyntheticLedger.epoch
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(index)),
            documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
            pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
            kind: kind,
            tool: tool,
            subject: "S\(index)",
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    // MARK: T-046

    /// Every measuring path writes kind `.measurement`, whatever the tool (the measuring
    /// presenter, Takeoff Assistant, geometry queries, room detection, wall takeoff).
    private static func typeStore() throws -> (LedgerStore, ColumnID) {
        let columns = try LedgerColumnSet.standard()
        let store = try LedgerStore(
            markups: [
                record(0, tool: .length),
                record(1, tool: .rectangleArea),
                record(2, tool: .count),
                record(3, tool: .area),
                record(4, tool: .length),
                record(5, kind: .cloud, tool: nil)
            ],
            columns: columns,
            names: LedgerNameCatalog()
        )
        return (store, try #require(columns.columnID(standard: .icon)))
    }

    @Test("T-046: the Type cell is the tool; a markup without one keeps its kind")
    func typeCellIsTheTool() throws {
        let (store, icon) = try Self.typeStore()
        // Old output: .text("measurement") for rows 0-4.
        #expect((0..<6).map { store.value(at: $0, column: icon) } == [
            .value(.text("length")), .value(.text("rectangleArea")), .value(.text("count")),
            .value(.text("area")), .value(.text("length")), .value(.text("cloud"))
        ])
    }

    @Test("T-046: grouping by Type makes one group per tool")
    func groupingByTypeSplitsTheTools() throws {
        let (store, icon) = try Self.typeStore()
        let view = store.makeView(LedgerViewSpec(grouping: [LedgerGroupingField(column: icon)]))
        // Old output: two groups — "cloud" [5] and "measurement" [0, 1, 2, 3, 4].
        #expect(view.tree.roots.map(\.key) == [
            .text("area"), .text("cloud"), .text("count"), .text("length"), .text("rectangleArea")
        ])
        #expect(view.tree.roots.map(\.rowIndices) == [[3], [5], [2], [0, 4], [1]])
    }

    @Test("T-046: a sort on Type orders by tool and a filter on Type matches by tool")
    func sortAndFilterOnType() throws {
        let (store, icon) = try Self.typeStore()
        // Old output: every measurement tied as "measurement", so the stable sort kept
        // 0, 1, 2, 3, 4 and put "cloud" first: [5, 0, 1, 2, 3, 4].
        let sorted = LedgerSorter(store: store, descriptors: [LedgerSortDescriptor(column: icon)])
            .sorted(Array(0..<6))
        #expect(sorted == [3, 5, 2, 0, 4, 1])
        // Old output: [] — "measurement" contains no "area".
        let evaluator = LedgerFilterEvaluator(store: store)
        let areas = evaluator.filter(
            Array(0..<6),
            with: .rule(LedgerFilterRule(column: icon, op: .contains, value: .text("area")))
        )
        #expect(areas == [1, 3])
        let counts = evaluator.filter(
            Array(0..<6),
            with: .rule(LedgerFilterRule(column: icon, op: .equals, value: .text("count")))
        )
        #expect(counts == [2])
    }

    // MARK: T-047

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-09-26 08:00 UTC, 2026-09-26 17:00 UTC, 2026-09-27 09:00 UTC.
    private static let instants: [Date] = [
        Date(timeIntervalSince1970: 1_790_380_800 + 8 * 3_600),
        Date(timeIntervalSince1970: 1_790_380_800 + 17 * 3_600),
        Date(timeIntervalSince1970: 1_790_380_800 + 33 * 3_600)
    ]

    private static func dateStore() throws -> (LedgerStore, ColumnID, ColumnID) {
        let columns = try LedgerColumnSet.standard()
        let store = try LedgerStore(
            markups: instants.enumerated().map { index, instant in
                record(index, tool: .count, createdAt: instant, modifiedAt: instant)
            },
            columns: columns,
            names: LedgerNameCatalog()
        )
        return (
            store,
            try #require(columns.columnID(standard: .created)),
            try #require(columns.columnID(standard: .modified))
        )
    }

    @Test("T-047: two rows created the same day at different times form one group")
    func sameDayIsOneGroup() throws {
        let (store, created, _) = try Self.dateStore()
        #expect(Self.utc.component(.day, from: Self.instants[0]) == 26)
        #expect(Self.utc.component(.day, from: Self.instants[1]) == 26)
        #expect(Self.utc.component(.day, from: Self.instants[2]) == 27)
        let view = store.makeView(LedgerViewSpec(
            grouping: [LedgerGroupingField(column: created)], dayCalendar: Self.utc
        ))
        // Old output: three single-row groups keyed on the instants.
        #expect(view.tree.roots.map(\.rowIndices) == [[0, 1], [2]])
        #expect(view.tree.roots.map(\.key) == [
            .date(Self.utc.startOfDay(for: Self.instants[0])),
            .date(Self.utc.startOfDay(for: Self.instants[2]))
        ])
    }

    @Test("T-047: the day is the one in the spec's time zone")
    func dayFollowsTheTimeZone() throws {
        let (store, created, _) = try Self.dateStore()
        var brisbane = Calendar(identifier: .gregorian)
        brisbane.timeZone = TimeZone(identifier: "Australia/Brisbane")!  // UTC+10, no DST
        // 08:00Z is 18:00 on the 26th; 17:00Z is 03:00 on the 27th; 09:00Z on the 27th is 19:00.
        let view = store.makeView(LedgerViewSpec(
            grouping: [LedgerGroupingField(column: created)], dayCalendar: brisbane
        ))
        #expect(view.tree.roots.map(\.rowIndices) == [[0], [1, 2]])

        // Changing only the calendar regroups through the coordinator too.
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(grouping: [LedgerGroupingField(column: created)], dayCalendar: Self.utc)
        )
        #expect(coordinator.view.tree.roots.map(\.rowIndices) == [[0, 1], [2]])
        var spec = coordinator.view.spec
        spec.dayCalendar = brisbane
        let update = coordinator.apply(.setSpec(spec))
        #expect(update.change.contains(.grouping))
        #expect(coordinator.view.tree.roots.map(\.rowIndices) == [[0], [1, 2]])
    }

    @Test("T-047: an edit inside the same day stays in its group, as a full build files it")
    func incrementalEditAgreesWithTheBuilder() throws {
        let (store, _, modified) = try Self.dateStore()
        let spec = LedgerViewSpec(grouping: [LedgerGroupingField(column: modified)], dayCalendar: Self.utc)
        var coordinator = LedgerCoordinator(store: store, spec: spec)
        #expect(coordinator.view.tree.roots.map(\.rowIndices) == [[0, 1], [2]])

        // Row 0 modified again at 23:30 the same UTC day.
        var record = store.record(at: 0)
        record.modifiedAt = Date(timeIntervalSince1970: 1_790_380_800 + 23 * 3_600 + 1_800)
        let edited = try store.updatingRows([
            LedgerStore.LedgerRowEdit(index: 0, record: record, measurement: store.measurement(at: 0))
        ])
        coordinator.apply(.editRows(store: edited, editedIndices: [0]))
        let rebuilt = edited.makeView(spec)
        #expect(coordinator.view.tree == rebuilt.tree)
        #expect(coordinator.view.tree.roots.map(\.rowIndices) == [[0, 1], [2]])
        #expect(coordinator.diagnostics.incrementalTreeEdits == 1, "the delta path, not a rebuild")
    }
}
