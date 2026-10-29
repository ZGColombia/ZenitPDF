import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// ADR-0018 in the aggregation core: a cutout is part of its parent, never a quantity of its own.
///
/// The fixture is a 10 x 10 m slab with two overlapping 4 x 4 m cutouts and an unrelated
/// 5 x 5 m pad. Every number below is derived on paper, from the geometry, before the code ran:
///
/// ```text
/// slab outline         10 * 10                     = 100 m²,  perimeter 4 * 10 = 40 m
/// cutout A             [1,5] x [1,5]   4 * 4       =  16 m²,  perimeter 16 m
/// cutout B             [3,7] x [3,7]   4 * 4       =  16 m²,  perimeter 16 m
/// overlap A ∩ B        [3,5] x [3,5]   2 * 2       =   4 m²
/// union A ∪ B          16 + 16 - 4                 =  28 m²
/// slab net             100 - 28                    =  72 m²   (subtract / report separately)
///                      100                                    (ignore: netArea = planArea)
/// pad                  5 * 5                       =  25 m²,  perimeter 20 m
/// ```
///
/// The measurement results are the ones the engine writes (golden cases K04/K05 pin those):
/// the parent carries planArea / netArea / cutoutArea / perimeter, a cutout carries planArea,
/// cutoutArea and its own perimeter, and under `ignore` the parent has no cutoutArea.
@Suite("Fix 3 — cutout rows in the ledger (ADR-0018)")
struct Fix3CutoutLedgerTests {

    // MARK: Fixture

    static let slabID = MarkupID(SyntheticLedger.deterministicUUID(9_001))
    static let cutoutAID = MarkupID(SyntheticLedger.deterministicUUID(9_002))
    static let cutoutBID = MarkupID(SyntheticLedger.deterministicUUID(9_003))
    static let padID = MarkupID(SyntheticLedger.deterministicUUID(9_004))
    static let twicePerimeter = ColumnID(SyntheticLedger.deterministicUUID(9_100))

    static func column(_ standard: StandardLedgerColumn) -> ColumnID {
        LedgerIdentifiers.columnID(for: standard)
    }

    static func record(
        _ id: MarkupID,
        subject: String,
        tool: MeasurementTool,
        parameters: MeasurementParameters? = nil,
        measurement: MeasurementResult,
        parent: MarkupID? = nil,
        cutouts: [MarkupID] = []
    ) -> MarkupRecord {
        MarkupRecord(
            id: id,
            documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
            pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
            kind: .measurement,
            tool: tool,
            subject: subject,
            parameters: parameters,
            measurement: measurement,
            parentMarkupID: parent,
            cutoutMarkupIDs: cutouts,
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )
    }

    static func slab(_ policy: CutoutPolicy) -> MarkupRecord {
        let values: [MeasurementField: DecimalQuantity] = policy == .ignore
            ? [.planArea: .area(100), .netArea: .area(100), .perimeter: .length(40)]
            : [.planArea: .area(100), .netArea: .area(72), .cutoutArea: .area(28), .perimeter: .length(40)]
        return record(
            slabID, subject: "Slab", tool: .area,
            parameters: MeasurementParameters(cutoutPolicy: policy),
            measurement: MeasurementResult(values: values),
            cutouts: [cutoutAID, cutoutBID]
        )
    }

    static func cutout(_ id: MarkupID, tool: MeasurementTool = .polygonCutout) -> MarkupRecord {
        record(
            id, subject: "Slab", tool: tool,
            measurement: MeasurementResult(values: [
                .planArea: .area(16), .cutoutArea: .area(16), .perimeter: .length(16)
            ]),
            parent: slabID
        )
    }

    static let pad = record(
        padID, subject: "Pad", tool: .area,
        measurement: MeasurementResult(values: [
            .planArea: .area(25), .netArea: .area(25), .perimeter: .length(20)
        ])
    )

    static func columns() throws -> LedgerColumnSet {
        var definitions = try LedgerColumnSet.standard().columns
        definitions.append(LedgerColumnDefinition(
            id: twicePerimeter, key: "twicePerimeter", title: "Twice Perimeter", kind: .formula,
            dimension: .length, formula: FormulaExpression(source: "Perimeter * 2"),
            isEditable: false, order: definitions.count
        ))
        return try LedgerColumnSet(columns: definitions)
    }

    static func store(_ policy: CutoutPolicy) throws -> LedgerStore {
        try LedgerStore(
            markups: [slab(policy), cutout(cutoutAID), cutout(cutoutBID, tool: .ellipseCutout), pad],
            columns: columns()
        )
    }

    static func value(_ store: LedgerStore, _ row: Int, _ standard: StandardLedgerColumn) -> Decimal? {
        store.value(at: row, column: column(standard)).quantity?.value
    }

    static func sum(_ aggregates: LedgerAggregates, _ column: ColumnID) -> Decimal? {
        aggregates.value(AggregateKey(column: column, function: .sum))?.decimal
    }

    // MARK: Cells

    @Test("A cutout row's quantity cells are empty under every policy; the parent reads net")
    func cutoutRowCellsAreEmpty() throws {
        // Old output (before this fix): a cutout row showed its own Perimeter 16 m and — for a
        // circular ellipse cutout — its radius and diameter, and every one of them was summed.
        for policy in CutoutPolicy.allCases {
            let store = try Self.store(policy)
            for row in [1, 2] {
                for standard in StandardLedgerColumn.allCases
                where standard.measurementField != nil && standard != .cutoutArea {
                    #expect(
                        store.value(at: row, column: Self.column(standard)) == .value(.empty),
                        "\(policy): cutout row \(row), \(standard)"
                    )
                }
                // A cutout row's formula cell is empty: not 2 * 16, and not a "blank in
                // arithmetic" error that would turn the column total into a refusal.
                #expect(store.value(at: row, column: Self.twicePerimeter) == .value(.empty), "\(policy)")
                // Non-quantity columns are untouched.
                #expect(store.value(at: row, column: Self.column(.subject)) == .value(.text("Slab")))
            }
            // The parent: Plan Area is the net 72 (100 under ignore), Gross Area the outline 100.
            #expect(Self.value(store, 0, .planArea) == (policy == .ignore ? 100 : 72), "\(policy)")
            #expect(Self.value(store, 0, .grossArea) == 100, "\(policy)")
            #expect(Self.value(store, 0, .perimeter) == 40, "\(policy)")
            #expect(store.value(at: 0, column: Self.twicePerimeter).quantity?.value == 80, "\(policy)")
        }
    }

    @Test("Cutout Area: the parent's union, and each cutout's own area only under report-separately")
    func cutoutAreaColumn() throws {
        for policy in CutoutPolicy.allCases {
            let store = try Self.store(policy)
            // Parent: 28 = 16 + 16 - 4 wherever the engine subtracted; nothing under ignore.
            #expect(Self.value(store, 0, .cutoutArea) == (policy == .ignore ? nil : 28), "\(policy)")
            let reported: Decimal? = policy == .subtractAndReportSeparately ? 16 : nil
            #expect(Self.value(store, 1, .cutoutArea) == reported, "\(policy): cutout A")
            #expect(Self.value(store, 2, .cutoutArea) == reported, "\(policy): cutout B")
            // A plain area has no cutouts and no Cutout Area.
            #expect(Self.value(store, 3, .cutoutArea) == nil)
        }
        // An orphaned cutout (its parent is not in the ledger) reports nothing.
        let orphan = try LedgerStore(markups: [Self.cutout(Self.cutoutAID)], columns: Self.columns())
        #expect(Self.value(orphan, 0, .cutoutArea) == nil)
        #expect(Self.value(orphan, 0, .perimeter) == nil)
    }

    // MARK: Totals

    @Test("Subtotals and grand totals: a cutout row adds and subtracts nothing, under every policy")
    func totalsIgnoreCutoutRows() throws {
        let subject = LedgerGroupingField(column: Self.column(.subject))
        for policy in CutoutPolicy.allCases {
            let store = try Self.store(policy)
            let plan = LedgerAggregationPlan.standard(for: store.columns)
            let view = store.makeView(LedgerViewSpec(grouping: [subject], aggregation: plan))
            let slabNet: Decimal = policy == .ignore ? 100 : 72

            // Grand totals: Plan Area = slab net + pad 25; Perimeter = 40 + 20 = 60, never
            // 40 + 16 + 16 + 20 = 92 (old output); Gross Area = 100 + 25 = 125.
            #expect(Self.sum(view.grandTotal, Self.column(.planArea)) == slabNet + 25, "\(policy)")
            #expect(Self.sum(view.grandTotal, Self.column(.perimeter)) == 60, "\(policy)")
            #expect(Self.sum(view.grandTotal, Self.column(.grossArea)) == 125, "\(policy)")
            // Twice Perimeter: 80 + 40 = 120, not 120 + 32 + 32.
            #expect(Self.sum(view.grandTotal, Self.twicePerimeter) == 120, "\(policy)")
            // Radius and diameter: nothing, even with a circular ellipse cutout in the ledger.
            #expect(Self.sum(view.grandTotal, Self.column(.radius)) == nil, "\(policy)")
            // Cutout Area is never summed: the parent's 28 and the rows' 16 + 16 are one area.
            #expect(view.grandTotal.value(AggregateKey(column: Self.column(.cutoutArea), function: .sum)) == nil)

            // The Slab subtotal (parent + both cutout rows) is the parent alone.
            let slabGroup = try #require(view.tree.roots.first { $0.key == .text("Slab") })
            #expect(slabGroup.rowIndices.count == 3, "the cutout rows are still listed")
            #expect(Self.sum(slabGroup.aggregates, Self.column(.planArea)) == slabNet, "\(policy)")
            #expect(Self.sum(slabGroup.aggregates, Self.column(.perimeter)) == 40, "\(policy)")
            #expect(Self.sum(slabGroup.aggregates, Self.column(.grossArea)) == 100, "\(policy)")
            let padGroup = try #require(view.tree.roots.first { $0.key == .text("Pad") })
            #expect(Self.sum(padGroup.aggregates, Self.column(.planArea)) == 25)
        }
        #expect(!LedgerAggregationPlan.sums(try #require(Self.columns().column(standard: .cutoutArea))))
        #expect(LedgerAggregationPlan.sums(try #require(Self.columns().column(standard: .grossArea))))
    }

    // MARK: Incremental path

    @Test("Changing the parent's policy re-evaluates its cutout rows on the incremental path")
    func parentPolicyEditReachesCutoutRows() throws {
        let store = try Self.store(.subtractFromArea)
        let reported = LedgerFilterNode.rule(LedgerFilterRule(
            column: Self.column(.cutoutArea), op: .isNotEmpty, value: .none
        ))
        let plan = LedgerAggregationPlan.standard(for: store.columns)
            .adding(AggregateKey(column: Self.column(.cutoutArea), function: .count))
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(filter: reported, aggregation: plan)
        )
        // Under subtractFromArea only the parent reports a Cutout Area.
        #expect(coordinator.view.matchingRowIndices == [0])

        // Only the parent row is edited — exactly what the session sends.
        let edited = try store.updatingRows([
            LedgerStore.LedgerRowEdit(index: 0, record: Self.slab(.subtractAndReportSeparately))
        ])
        coordinator.apply(.editRows(store: edited, editedIndices: [0]))
        // The cutout rows now report 16 m² each, and the incremental view equals a rebuild.
        #expect(coordinator.view.matchingRowIndices == [0, 1, 2])
        let rebuilt = edited.makeView(coordinator.view.spec)
        #expect(coordinator.view.matchingRowIndices == rebuilt.matchingRowIndices)
        #expect(coordinator.view.tree == rebuilt.tree)
    }
}
