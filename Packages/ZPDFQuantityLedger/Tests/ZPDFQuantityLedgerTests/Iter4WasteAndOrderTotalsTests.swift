import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// U-056 / ADR-0039: the Waste and Order preset's
/// totals. Pack size never sums; Order is a count and sums.
///
/// Hand-derived values. Row A: 97.3 m², waste 0.10, pack 2.88 m². Row B: 50 m², no waste, pack
/// 2.88 m².
/// - Gross: 97.3 × 1.10 = 107.03 m² and 50 × 1 = 50 m²; total 157.03 m².
/// - Order: 107.03 / 2.88 = 37.163… → 38 and 50 / 2.88 = 17.361… → 18; total 56 boards (not
///   ⌈157.03 / 2.88⌉ = 55 — each row orders whole packs).
/// - Pack size: no total. Before ADR-0039 it printed 2.88 + 2.88 = 5.76 m².
@Suite("Iteration 4 — Waste and Order totals (ADR-0039)")
struct Iter4WasteAndOrderTotalsTests {

    private static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private static let wasteID = ColumnID(SyntheticLedger.deterministicUUID(-501))
    private static let packID = ColumnID(SyntheticLedger.deterministicUUID(-502))
    private static let grossID = ColumnID(SyntheticLedger.deterministicUUID(-503))
    private static let orderID = ColumnID(SyntheticLedger.deterministicUUID(-504))

    static let grossFormula = "Area * (1 + COALESCE([Waste], 0))"
    static let orderFormula = "CONVERT(ROUNDUP([Gross] / [Pack size], 0), 1, count)"
    static let oldOrderFormula = "ROUNDUP([Gross] / [Pack size], 0)"

    /// The four user columns as the application declares them: two passes, the formula columns
    /// taking the dimension their compiled result has (`LedgerBridge.definition`,
    /// `columnChangeBatch`).
    static func columnSet(order orderSource: String = orderFormula, packNeverSums: Bool = true) throws -> LedgerColumnSet {
        let standard = try LedgerColumnSet.standard().columns
        func user(_ dimensions: [ColumnID: QuantityDimension]) -> [LedgerColumnDefinition] {
            let base = standard.count
            return [
                LedgerColumnDefinition(id: wasteID, key: "custom.waste", title: "Waste", kind: .number, dimension: .ratio, order: base),
                LedgerColumnDefinition(
                    id: packID, key: "custom.pack", title: "Pack size", kind: .number, dimension: .area,
                    order: base + 1, neverSums: packNeverSums
                ),
                LedgerColumnDefinition(
                    id: grossID, key: "custom.gross", title: "Gross", kind: .formula, dimension: dimensions[grossID],
                    formula: FormulaExpression(source: grossFormula), isEditable: false, order: base + 2
                ),
                LedgerColumnDefinition(
                    id: orderID, key: "custom.order", title: "Order", kind: .formula, dimension: dimensions[orderID],
                    precision: .decimalPlaces(0), formula: FormulaExpression(source: orderSource), isEditable: false, order: base + 3
                )
            ]
        }
        let trial = try LedgerColumnSet(columns: standard + user([:]))
        var dimensions: [ColumnID: QuantityDimension] = [:]
        for id in [grossID, orderID] { dimensions[id] = trial.formulaResultDimension(id) }
        return try LedgerColumnSet(columns: standard + user(dimensions))
    }

    static func store(_ columns: LedgerColumnSet) throws -> LedgerStore {
        func record(_ index: Int, subject: String, area: String, waste: String?) -> MarkupRecord {
            var custom: [ColumnID: LedgerCellValue] = [
                packID: .number(DecimalQuantity(value: decimal("2.88"), dimension: .area))
            ]
            if let waste { custom[wasteID] = .number(DecimalQuantity(value: decimal(waste), dimension: .ratio)) }
            return MarkupRecord(
                id: MarkupID(SyntheticLedger.deterministicUUID(600 + index)),
                documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
                pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
                kind: .measurement,
                tool: .rectangleArea,
                subject: subject,
                measurement: MeasurementResult(values: [
                    .planArea: .area(decimal(area)), .netArea: .area(decimal(area))
                ]),
                customValues: custom,
                createdAt: SyntheticLedger.epoch,
                modifiedAt: SyntheticLedger.epoch
            )
        }
        return try LedgerStore(
            markups: [record(0, subject: "A", area: "97.3", waste: "0.10"), record(1, subject: "B", area: "50", waste: nil)],
            columns: columns
        )
    }

    @Test("Order is declared a count and Pack size never sums")
    func declarations() throws {
        let columns = try Self.columnSet()
        #expect(columns.column(id: Self.grossID)?.dimension == .area)
        // Old output: Order declared `.ratio` (area / area), and `sums` refused it.
        #expect(columns.column(id: Self.orderID)?.dimension == .count)
        #expect(LedgerAggregationPlan.sums(try #require(columns.column(id: Self.orderID))))
        // Old output: true — an area column summed, whatever it held.
        #expect(!LedgerAggregationPlan.sums(try #require(columns.column(id: Self.packID))))
        let plan = LedgerAggregationPlan.standard(for: columns)
        #expect(!plan.keys.contains(AggregateKey(column: Self.packID, function: .sum)))
        #expect(plan.keys.contains(AggregateKey(column: Self.packID, function: .count)), "the Count stays")
        #expect(plan.keys.contains(AggregateKey(column: Self.orderID, function: .sum)))

        // The preset's old formula is a ratio — the reason Order had no total.
        let old = try Self.columnSet(order: Self.oldOrderFormula, packNeverSums: false)
        #expect(old.column(id: Self.orderID)?.dimension == .ratio)
        #expect(!LedgerAggregationPlan.sums(try #require(old.column(id: Self.orderID))))
        #expect(LedgerAggregationPlan.sums(try #require(old.column(id: Self.packID))))
    }

    @Test("The grand total and each group show the boards to order and no Pack size total")
    func totals() throws {
        let columns = try Self.columnSet()
        let store = try Self.store(columns)
        let subject = try #require(columns.columnID(standard: .subject))
        let plan = LedgerAggregationPlan.standard(for: columns)

        // Per row, as before: 107.03 m² gross, 38 boards; 50 m², 18 boards.
        #expect(store.value(at: 0, column: Self.orderID).quantity == DecimalQuantity(value: 38, dimension: .count))
        #expect(store.value(at: 1, column: Self.orderID).quantity == DecimalQuantity(value: 18, dimension: .count))

        let flat = store.makeView(LedgerViewSpec(aggregation: plan))
        let order = AggregateKey(column: Self.orderID, function: .sum)
        let gross = AggregateKey(column: Self.grossID, function: .sum)
        let packSum = AggregateKey(column: Self.packID, function: .sum)
        // Old output: no Order sum at all, and a Pack size sum of 5.76 m².
        #expect(flat.tree.grandTotal.value(order) == .quantity(DecimalQuantity(value: 56, dimension: .count)))
        #expect(flat.tree.grandTotal.value(gross) == .quantity(DecimalQuantity(value: Self.decimal("157.03"), dimension: .area)))
        #expect(flat.tree.grandTotal.value(packSum) == nil)
        #expect(flat.tree.grandTotal.value(AggregateKey(column: Self.packID, function: .count)) == .integer(2))

        let grouped = store.makeView(LedgerViewSpec(grouping: [LedgerGroupingField(column: subject)], aggregation: plan))
        #expect(grouped.tree.roots.map { $0.aggregates.value(order) } == [
            .quantity(DecimalQuantity(value: 38, dimension: .count)),
            .quantity(DecimalQuantity(value: 18, dimension: .count))
        ])
        #expect(grouped.tree.roots.allSatisfy { $0.aggregates.value(packSum) == nil })
        #expect(grouped.tree.grandTotal.value(order) == flat.tree.grandTotal.value(order))
    }

    @Test("neverSums is additive: old definitions decode as nil and keep their bytes")
    func contractFieldIsAdditive() throws {
        let plain = LedgerColumnDefinition(id: Self.packID, key: "custom.pack", title: "Pack size", kind: .number, dimension: .area)
        #expect(plain.neverSums == nil)
        #expect(LedgerColumnDefinition(id: Self.packID, key: "k", title: "t", kind: .number, neverSums: false).neverSums == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("neverSums"), "an unflagged definition encodes as before ADR-0039")

        // A definition_json as a project written before ADR-0039 stores it: no key.
        let stored = try JSONDecoder().decode(LedgerColumnDefinition.self, from: Data(plainJSON.utf8))
        #expect(stored == plain)
        #expect(LedgerAggregationPlan.sums(stored), "an old area column still sums")

        var flagged = plain
        flagged.neverSums = true
        let flaggedJSON = try encoder.encode(flagged)
        #expect(String(decoding: flaggedJSON, as: UTF8.self).contains("\"neverSums\":true"))
        let decoded = try JSONDecoder().decode(LedgerColumnDefinition.self, from: flaggedJSON)
        #expect(decoded.neverSums == true)
        #expect(!LedgerAggregationPlan.sums(decoded))
    }
}
