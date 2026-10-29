import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// The repeat multiplier on the one evaluation path: a markup drawn once but standing for N
/// identical instances counts N times in every extensive quantity — in the cell, the subtotal,
/// the grand total and the formula inputs, all from the same multiplication. Intensive values
/// and per-instance inputs never scale.
@Suite("Repeat multiplier on the value path")
struct QuantityRepetitionTests {

    static let multiplierColumn = HandBuiltLedger.columnID("repeat")

    static func multiplierDefinition(order: Int) -> LedgerColumnDefinition {
        LedgerColumnDefinition(
            id: multiplierColumn,
            key: "zenit.repeat.test",
            title: "Repeat ×",
            kind: .number,
            dimension: .ratio,
            precision: .decimalPlaces(0),
            order: order
        )
    }

    static func makeStore(
        repeats: LedgerCellValue?,
        extraColumns: [LedgerColumnDefinition] = [],
        multiplier: ColumnID? = multiplierColumn,
        measurement: MeasurementResult = MeasurementResult(values: [
            .planArea: .area(Decimal(string: "12.5")!), .netArea: .area(Decimal(string: "12.5")!),
            .planLength: .length(Decimal(string: "3.7")!),
            .slopeRatio: DecimalQuantity(value: Decimal(string: "0.25")!, dimension: .count),
            .depth: .length(Decimal(string: "0.3")!)
        ])
    ) throws -> LedgerStore {
        var definitions = try LedgerColumnSet.standard().columns
        definitions.append(Self.multiplierDefinition(order: definitions.count))
        for (offset, extra) in extraColumns.enumerated() {
            var shifted = extra
            shifted.order = definitions.count + offset
            definitions.append(shifted)
        }
        let columns = try LedgerColumnSet(columns: definitions)
        let record = MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(0)),
            documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
            pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
            kind: .measurement,
            tool: .area,
            subject: "Balcony",
            measurement: measurement,
            customValues: repeats.map { [Self.multiplierColumn: $0] } ?? [:],
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )
        return try LedgerStore(
            markups: [record],
            columns: columns,
            quantityMultiplierColumn: multiplier
        )
    }

    static func number(_ result: LedgerCellResult) throws -> DecimalQuantity {
        switch result {
        case .value(.number(let quantity)): return quantity
        case .value(.formulaResult(let quantity, _)): return quantity
        default: throw LedgerError.duplicateColumnKey("expected a number cell, got \(result)")
        }
    }

    static func cell(_ store: LedgerStore, _ standard: StandardLedgerColumn) throws -> DecimalQuantity {
        try number(store.value(at: 0, column: LedgerIdentifiers.columnID(for: standard)))
    }

    @Test("Repeat 6 multiplies the extensive cells exactly, and only those")
    func extensiveCellsMultiply() throws {
        let store = try Self.makeStore(repeats: .number(DecimalQuantity(value: 6, dimension: .ratio)))
        let area = try Self.cell(store, .planArea)
        #expect(area.value == Decimal(string: "75")!)
        #expect(area.dimension == .area)
        // Six repetitions equal the sum of six copies, to the last digit.
        var sixCopies = Decimal.zero
        for _ in 0..<6 { sixCopies += Decimal(string: "12.5")! }
        #expect(area.value == sixCopies)
        #expect(try Self.cell(store, .planLength).value == Decimal(string: "22.2")!)
        // Intensive: six identical roofs share one slope, six slabs share one depth.
        #expect(try Self.cell(store, .slopeRatio).value == Decimal(string: "0.25")!)
        #expect(try Self.cell(store, .depth).value == Decimal(string: "0.3")!)
    }

    @Test("The grand total carries the multiplication — same path, same number")
    func grandTotalMultiplies() throws {
        let store = try Self.makeStore(repeats: .number(DecimalQuantity(value: 6, dimension: .ratio)))
        let areaColumn = LedgerIdentifiers.columnID(for: .planArea)
        let plan = LedgerAggregationPlan(keys: [AggregateKey(column: areaColumn, function: .sum)])
        let view = store.makeView(LedgerViewSpec(aggregation: plan))
        let total = try #require(view.grandTotal[areaColumn])
        guard case .quantity(let quantity) = total else {
            Issue.record("expected a quantity total, got \(total)")
            return
        }
        #expect(quantity.value == Decimal(string: "75")!)
    }

    @Test("A formula reads the same multiplied field the cell shows")
    func formulaSeesMultipliedFields() throws {
        let doubledArea = HandBuiltLedger.columnID("doubledArea")
        let scaledDepth = HandBuiltLedger.columnID("scaledDepth")
        let store = try Self.makeStore(
            repeats: .number(DecimalQuantity(value: 6, dimension: .ratio)),
            extraColumns: [
                LedgerColumnDefinition(
                    id: doubledArea, key: "doubledArea", title: "Doubled",
                    kind: .formula, dimension: .area,
                    formula: FormulaExpression(source: "[planArea] * 2"),
                    isEditable: false, order: 0
                ),
                LedgerColumnDefinition(
                    id: scaledDepth, key: "scaledDepth", title: "Depth again",
                    kind: .formula, dimension: .length,
                    formula: FormulaExpression(source: "[depth] * 1"),
                    isEditable: false, order: 0
                )
            ]
        )
        // netArea 12.5 × repeat 6 × formula 2 = 150; depth stays per-instance.
        #expect(try Self.number(store.value(at: 0, column: doubledArea)).value == Decimal(string: "150")!)
        #expect(try Self.number(store.value(at: 0, column: scaledDepth)).value == Decimal(string: "0.3")!)
    }

    @Test("A stored 0 is corrupt and reads as once — it never zeroes a measured quantity")
    func corruptZeroReadsAsOnce() throws {
        let store = try Self.makeStore(repeats: .number(DecimalQuantity(value: 0, dimension: .ratio)))
        #expect(try Self.cell(store, .planArea).value == Decimal(string: "12.5")!)
    }

    @Test("With no designated multiplier column nothing multiplies, even with the cell present")
    func withoutDesignationNothingMultiplies() throws {
        let store = try Self.makeStore(
            repeats: .number(DecimalQuantity(value: 6, dimension: .ratio)),
            multiplier: nil
        )
        #expect(try Self.cell(store, .planArea).value == Decimal(string: "12.5")!)
    }

    @Test("An in-place row edit that sets the repeat count multiplies from that edit on")
    func rowEditPicksUpTheCount() throws {
        let store = try Self.makeStore(repeats: nil)
        #expect(try Self.cell(store, .planArea).value == Decimal(string: "12.5")!)
        var record = store.record(at: 0)
        record.customValues[Self.multiplierColumn] =
            .number(DecimalQuantity(value: 6, dimension: .ratio))
        let edited = try store.updatingRows([
            LedgerStore.LedgerRowEdit(index: 0, record: record, measurement: store.measurement(at: 0))
        ])
        #expect(try Self.cell(edited, .planArea).value == Decimal(string: "75")!)
        // The raw measurement stays the single-instance truth.
        #expect(edited.measurement(at: 0)[.planArea]?.value == Decimal(string: "12.5")!)
    }
}
