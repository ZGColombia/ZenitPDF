import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// U-060: two texts Swift calls equal compare as the same text, so the incremental group
/// editor files a row into the group a full build puts it in. U-061: a grouped view with no
/// matching row reports the same grand total as the flat view.
@Suite("Iteration 4 — canonical text keys, empty grouped totals")
struct Iter4LedgerCoreFixTests {

    private static func record(_ index: Int, subject: String, tool: MeasurementTool = .count) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(index)),
            documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
            pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
            kind: .measurement,
            tool: tool,
            subject: subject,
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )
    }

    // MARK: U-060

    /// "Café" with the precomposed é (U+00E9) and with e + combining acute accent (U+0301).
    private static let composed = "Caf\u{00E9}"
    private static let decomposed = "Cafe\u{0301}"

    @Test("U-060: NFC and NFD spellings of one text compare as the same text")
    func canonicalTextsCompareSame() {
        #expect(Self.composed == Self.decomposed)
        #expect(Array(Self.composed.unicodeScalars) != Array(Self.decomposed.unicodeScalars))
        // Old output: .orderedDescending — the scalar tiebreak ordered U+00E9 after "e".
        #expect(LedgerOrdering.compareText(Self.composed, Self.decomposed) == .orderedSame)
        #expect(LedgerGroupKey.compare(.text(Self.composed), .text(Self.decomposed), choiceOrder: [:]) == .orderedSame)
        // Distinct texts keep their deterministic order.
        #expect(LedgerOrdering.compareText("I", "i") != .orderedSame)
        #expect(LedgerOrdering.compareText("A-99", "A-101") == .orderedAscending)
    }

    @Test("U-060: an edit into the other normalisation form joins the existing group, as a full build does")
    func incrementalEditIntoTheOtherFormAgreesWithTheBuilder() throws {
        let columns = try LedgerColumnSet.standard()
        let subject = try #require(columns.columnID(standard: .subject))
        let store = try LedgerStore(
            markups: [
                Self.record(0, subject: Self.composed),
                Self.record(1, subject: "Floor"),
                Self.record(2, subject: "Roof")
            ],
            columns: columns,
            names: LedgerNameCatalog()
        )
        let spec = LedgerViewSpec(
            grouping: [LedgerGroupingField(column: subject)],
            aggregation: .standard(for: columns)
        )
        var coordinator = LedgerCoordinator(store: store, spec: spec)
        #expect(coordinator.view.tree.roots.count == 3)

        var record = store.record(at: 1)
        record.subject = Self.decomposed
        let edited = try store.updatingRows([
            LedgerStore.LedgerRowEdit(index: 1, record: record, measurement: store.measurement(at: 1))
        ])
        coordinator.apply(.editRows(store: edited, editedIndices: [1]))
        let rebuilt = edited.makeView(spec)

        // Old output: three roots on the delta path — "Café" (NFD) [1], "Café" (NFC) [0] and
        // "Roof" [2]; the two Café keys and paths are == to each other; the full build has two.
        #expect(rebuilt.tree.roots.count == 2)
        #expect(coordinator.view.tree == rebuilt.tree)
        // "Café" [0, 1], then "Roof" [2].
        #expect(coordinator.view.tree.roots.map(\.rowIndices) == [[0, 1], [2]])
        #expect(coordinator.diagnostics.incrementalTreeEdits == 1, "the delta path, not a rebuild")
    }

    // MARK: U-061

    /// Three counts (2, 3, 5 pieces) and a plan that also names a column the ledger lacks.
    private static func countStore() throws -> (LedgerStore, LedgerColumnSet, ColumnID, AggregateKey) {
        let columns = try LedgerColumnSet.standard()
        let store = try LedgerStore(
            markups: [
                Self.record(0, subject: "A"),
                Self.record(1, subject: "B"),
                Self.record(2, subject: "C")
            ],
            columns: columns,
            names: LedgerNameCatalog()
        )
        let icon = try #require(columns.columnID(standard: .icon))
        let missing = AggregateKey(column: ColumnID(SyntheticLedger.deterministicUUID(-900)), function: .sum)
        return (store, columns, icon, missing)
    }

    @Test("U-061: a filter that matches nothing gives the same grand total grouped and flat")
    func emptyGroupedGrandTotalMatchesFlat() throws {
        let (store, columns, icon, missing) = try Self.countStore()
        let plan = LedgerAggregationPlan.standard(for: columns).adding(missing)
        let countColumn = try #require(columns.columnID(standard: .count))
        let countKey = AggregateKey(column: countColumn, function: .count)

        let flat = store.makeView(LedgerViewSpec(filter: .nothing, aggregation: plan))
        let grouped = store.makeView(LedgerViewSpec(
            filter: .nothing, grouping: [LedgerGroupingField(column: icon)], aggregation: plan
        ))
        #expect(flat.tree.rowCount == 0)
        #expect(grouped.tree.roots.isEmpty)
        // The flat view seeds every planned key: Count 0 and the refusal of the missing column.
        #expect(flat.tree.grandTotal.value(countKey) != nil)
        #expect(flat.tree.grandTotal.value(missing) != nil)
        // Old output: `LedgerAggregates(accumulators: [:])` for the grouped view — no Count and
        // no error, so a grouped export under that filter lost its totals rows and its #ERROR.
        #expect(grouped.tree.grandTotal == flat.tree.grandTotal)
    }

    @Test("U-061: an edit that empties every group keeps the planned grand-total keys")
    func incrementalEditToNoMatchKeepsTheKeys() throws {
        let columns = try LedgerColumnSet.standard()
        let subject = try #require(columns.columnID(standard: .subject))
        let store = try LedgerStore(
            markups: [Self.record(0, subject: "Wall")],
            columns: columns,
            names: LedgerNameCatalog()
        )
        let spec = LedgerViewSpec(
            filter: .rule(LedgerFilterRule(column: subject, op: .equals, value: .text("Wall"))),
            grouping: [LedgerGroupingField(column: subject)],
            aggregation: .standard(for: columns)
        )
        var coordinator = LedgerCoordinator(store: store, spec: spec)
        #expect(coordinator.view.tree.roots.count == 1)

        var record = store.record(at: 0)
        record.subject = "Floor"
        let edited = try store.updatingRows([
            LedgerStore.LedgerRowEdit(index: 0, record: record, measurement: store.measurement(at: 0))
        ])
        coordinator.apply(.editRows(store: edited, editedIndices: [0]))
        let flat = edited.makeView(LedgerViewSpec(filter: spec.filter, aggregation: spec.aggregation))
        #expect(coordinator.view.tree.roots.isEmpty)
        // Old output: an empty grand total after the delta path emptied the last group.
        #expect(coordinator.view.tree.grandTotal == flat.tree.grandTotal)
        #expect(coordinator.view.tree == edited.makeView(spec).tree)
    }
}
