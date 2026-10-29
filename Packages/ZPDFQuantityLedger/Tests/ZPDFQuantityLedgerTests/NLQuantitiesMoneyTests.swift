import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// Money in the aggregation core (ADR-0020).
///
/// Unit Cost is a rate — money per square metre, per metre, per piece — and a sum of rates is
/// a number that means nothing. Total Cost is the priced quantity times the rate, and it is
/// the money that sums. Expected values are derived by hand beside each assertion.
@Suite("Quantities — money in the core")
struct NLQuantitiesMoneyTests {

    static let documentID = DocumentID(UUID(uuidString: "00000000-0000-0000-0000-00000000D0C0")!)
    static let pageID = PageID(UUID(uuidString: "00000000-0000-0000-0000-00000000FA6E")!)

    static func record(
        _ index: Int,
        tool: MeasurementTool?,
        values: [MeasurementField: DecimalQuantity],
        custom: [ColumnID: LedgerCellValue]
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(9_000 + index)),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: tool,
            subject: "S",
            measurement: MeasurementResult(values: values),
            customValues: custom,
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )
    }

    static func sek(_ amount: Decimal) -> LedgerCellValue { .currency(amount: amount, code: "SEK") }

    // MARK: Bug 4 — Unit Cost summed

    @Test("The standard plan never sums Unit Cost, and sums Total Cost")
    func unitCostIsARate() throws {
        let columns = try LedgerColumnSet.standard()
        let unitCost = try #require(columns.column(standard: .unitCost))
        let totalCost = try #require(columns.column(standard: .totalCost))
        // Old code: `.currency` always summed, so a grouped export printed "Sum: Unit Cost".
        #expect(!LedgerAggregationPlan.sums(unitCost))
        #expect(LedgerAggregationPlan.sums(totalCost))
        let plan = LedgerAggregationPlan.standard(for: columns)
        #expect(!plan.keys.contains(AggregateKey(column: unitCost.id, function: .sum)))
        #expect(plan.keys.contains(AggregateKey(column: totalCost.id, function: .sum)))
    }

    @Test("A money column declared per square metre is a rate and does not sum; plain money does")
    func declaredRatesDoNotSum() {
        let rate = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "rate", title: "Rate", kind: .currency,
            dimension: .currencyRate("SEK", perLengthPower: 2)
        )
        let rateNumber = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "rateNumber", title: "Rate", kind: .number,
            dimension: .currencyRate("SEK", perLengthPower: 1)
        )
        let money = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "fee", title: "Fee", kind: .currency,
            dimension: .currency("SEK")
        )
        let undeclared = LedgerColumnDefinition(id: ColumnID(UUID()), key: "fee2", title: "Fee", kind: .currency)
        #expect(!LedgerAggregationPlan.sums(rate))
        #expect(!LedgerAggregationPlan.sums(rateNumber))
        #expect(LedgerAggregationPlan.sums(money))
        #expect(LedgerAggregationPlan.sums(undeclared))
    }

    // MARK: Bug 7 — Total Cost always empty

    @Test("Total Cost = priced quantity × Unit Cost, per tool, exact; the grand total sums it")
    func totalCostIsDerived() throws {
        let columns = try LedgerColumnSet.standard()
        let unitCost = try #require(columns.columnID(standard: .unitCost))
        let totalCostColumn = try #require(columns.column(standard: .totalCost))
        let markups = [
            // 12 m² at 450 SEK/m² = 5 400 SEK.
            Self.record(0, tool: .area, values: [.planArea: .area(12), .netArea: .area(12)],
                        custom: [unitCost: Self.sek(450)]),
            // 7.25 m at 99.90 SEK/m = 724.275 SEK — kept exact, never rounded in the cell.
            Self.record(1, tool: .length, values: [.planLength: .length(Decimal(string: "7.25")!)],
                        custom: [unitCost: Self.sek(Decimal(string: "99.90")!)]),
            // 5 pieces at 120 SEK each = 600 SEK.
            Self.record(2, tool: .count, values: [.count: .count(5)], custom: [unitCost: Self.sek(120)]),
            // No Unit Cost: nothing is priced.
            Self.record(3, tool: .area, values: [.planArea: .area(3), .netArea: .area(3)], custom: [:])
        ]
        let store = try LedgerStore(markups: markups, columns: columns)
        #expect(store.value(at: 0, definition: totalCostColumn) == .value(Self.sek(5_400)))
        #expect(store.value(at: 1, definition: totalCostColumn) == .value(Self.sek(Decimal(string: "724.275")!)))
        #expect(store.value(at: 2, definition: totalCostColumn) == .value(Self.sek(600)))
        #expect(store.value(at: 3, definition: totalCostColumn) == .empty)

        // 5 400 + 724.275 + 600 = 6 724.275, exact.
        let view = store.makeView(LedgerViewSpec(aggregation: .standard(for: columns)))
        #expect(view.grandTotal[totalCostColumn.id] == .currency(amount: Decimal(string: "6724.275")!, code: "SEK"))
        #expect(view.grandTotal[unitCost] == nil)
    }

    @Test("Total Cost follows the net area and the repeat multiplier, exactly as the area cell does")
    func totalCostUsesTheCellPath() throws {
        let multiplier = ColumnID(UUID())
        var definitions = try LedgerColumnSet.standard().columns
        definitions.append(LedgerColumnDefinition(
            id: multiplier, key: "custom.repeat", title: "Repeat", kind: .number, dimension: .ratio,
            order: definitions.count
        ))
        let columns = try LedgerColumnSet(columns: definitions)
        let unitCost = try #require(columns.columnID(standard: .unitCost))
        let totalCost = try #require(columns.column(standard: .totalCost))
        // Gross 100 m², net 72 m² (cutouts removed), repeated 3 times: 72 × 3 = 216 m² priced
        // at 10 SEK/m² = 2 160 SEK. Pricing the gross area would read 3 000.
        let slab = Self.record(0, tool: .area,
                               values: [.planArea: .area(100), .netArea: .area(72)],
                               custom: [unitCost: Self.sek(10), multiplier: .number(DecimalQuantity(value: 3, dimension: .ratio))])
        let store = try LedgerStore(markups: [slab], columns: columns, quantityMultiplierColumn: multiplier)
        #expect(store.value(at: 0, definition: totalCost) == .value(Self.sek(2_160)))
    }

    @Test("A Unit Cost on a row with nothing to price is an error cell, and refuses the total")
    func unitCostOnAnUnpricedRowIsAnError() throws {
        let columns = try LedgerColumnSet.standard()
        let unitCost = try #require(columns.columnID(standard: .unitCost))
        let totalCost = try #require(columns.column(standard: .totalCost))
        let markups = [
            Self.record(0, tool: .slope, values: [.slopeRatio: DecimalQuantity(value: Decimal(string: "0.5")!, dimension: .ratio)],
                        custom: [unitCost: Self.sek(100)]),
            Self.record(1, tool: .area, values: [.planArea: .area(2), .netArea: .area(2)], custom: [unitCost: Self.sek(100)])
        ]
        let store = try LedgerStore(markups: markups, columns: columns)
        guard case .error = store.value(at: 0, definition: totalCost) else {
            Issue.record("a rate that multiplies nothing must not read as empty or zero")
            return
        }
        // The one priced row is 2 × 100 = 200, but the grand total must not quietly print 200
        // when another row's total failed (QUALITY_BAR A11, CR-62).
        let total = try #require(store.makeView(LedgerViewSpec(aggregation: .standard(for: columns))).grandTotal[totalCost.id])
        #expect(total.isRefusal)
    }

    // MARK: NL-QTY-14 — the selection filter node

    @Test("A markups node narrows to exactly those rows and the totals are their exact sum")
    func markupsNode() throws {
        let columns = try LedgerColumnSet.standard()
        let areas: [Decimal] = [12, Decimal(string: "2.5")!, 7]
        let markups = areas.enumerated().map { index, area in
            Self.record(index, tool: .area, values: [.planArea: .area(area), .netArea: .area(area)], custom: [:])
        }
        let store = try LedgerStore(markups: markups, columns: columns)
        let chosen: Set<MarkupID> = [markups[0].id, markups[2].id]
        let view = store.makeView(LedgerViewSpec(filter: .markups(chosen), aggregation: .standard(for: columns)))
        #expect(Set((0..<view.rowCount).map { view.row(displayRow: $0).markupID }) == chosen)
        // 12 + 7 = 19 m², never the unfiltered 21.5.
        let planArea = try #require(columns.columnID(standard: .planArea))
        #expect(view.grandTotal[planArea] == .quantity(.area(19)))
    }

    // MARK: NL-QTY-07 — assembly expansion

    @Test("The timber wall on a 10 m line at 2.4 m / 0.6 m derives 24 m², 17 studs, 20 m and 48 m²")
    func assemblyExpansion() throws {
        let assignmentColumn = ColumnID(UUID())
        let assignment = LedgerAssemblyAssignment(
            assemblyID: LedgerAssemblyLibrary.standard[0].id,
            parameters: ["Height": .length(Decimal(string: "2.4")!), "Spacing": .length(Decimal(string: "0.6")!)]
        )
        let wall = Self.record(0, tool: .length, values: [.planLength: .length(10)], custom: [assignmentColumn: assignment.cellValue])
        let derived = LedgerAssemblyExpansion.derivedRecords(for: wall, assignmentColumn: assignmentColumn, repeatColumn: nil)
        #expect(derived.map(\.subject) == ["Wall area", "Studs", "Plates", "Plasterboard both sides"])
        #expect(derived.allSatisfy { $0.provenance == .derived && $0.derivation?.sourceMarkupID == wall.id })
        #expect(derived[0].measurement?.values[.netArea] == .area(24))
        #expect(derived[1].measurement?.values[.count] == .count(17))
        #expect(derived[2].measurement?.values[.planLength] == .length(20))
        #expect(derived[3].measurement?.values[.planArea] == .area(48))
        // Stable identity: rebuilt rows are the same rows.
        #expect(derived.map(\.id) == LedgerAssemblyExpansion.derivedRecords(
            for: wall, assignmentColumn: assignmentColumn, repeatColumn: nil
        ).map(\.id))
        // A derived row never derives again, and a row without an assignment derives nothing.
        #expect(LedgerAssemblyExpansion.derivedRecords(for: derived[0], assignmentColumn: assignmentColumn, repeatColumn: nil).isEmpty)
        #expect(LedgerAssemblyExpansion.derivedRecords(
            for: Self.record(1, tool: .length, values: [.planLength: .length(3)], custom: [:]),
            assignmentColumn: assignmentColumn, repeatColumn: nil
        ).isEmpty)
    }
}
