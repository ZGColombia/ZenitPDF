import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// NL-QTY-07-UI: a recipe line's unit cost becomes its derived row's Unit Cost, and the store
/// prices it like any rate (ADR-0020): Total Cost = the row's quantity × the rate, exact.
@Suite("NL-QTY-07-UI — derived rows carry the line's unit cost")
struct NLQty07UIDerivedCostTests {

    static let recipe = AssemblyDefinition(
        id: UUID(uuidString: "7C1B2F3E-3333-4A2B-9C3D-000000000007")!,
        name: "Priced stud wall",
        inputs: [
            AssemblyInput(name: "Length", dimension: .length),
            AssemblyInput(name: "Height", dimension: .length),
            AssemblyInput(name: "Spacing", dimension: .length)
        ],
        lines: [
            AssemblyLine(name: "Studs", source: "FLOOR(Length / Spacing) + 1", outputDimension: .count,
                         unitCost: .money(Decimal(string: "45.50")!, currencyCode: "SEK")),
            AssemblyLine(name: "Plasterboard", source: "Length * Height * 2", outputDimension: .area,
                         unitCost: .money(Decimal(string: "89.95")!, currencyCode: "SEK")),
            AssemblyLine(name: "Plates", source: "Length * 2", outputDimension: .length),
            AssemblyLine(name: "Broken", source: "Length * Nothing", outputDimension: .length,
                         unitCost: .money(10, currencyCode: "SEK"))
        ]
    )

    @Test("Unit Cost per derived row, Total Cost = quantity × rate, and the repeat multiplier applies to the money too")
    func derivedRowsArePriced() throws {
        let assignmentColumn = ColumnID(UUID())
        let repeatColumn = ColumnID(UUID())
        var definitions = try LedgerColumnSet.standard().columns
        definitions.append(LedgerColumnDefinition(
            id: repeatColumn, key: "custom.repeat", title: "Repeat", kind: .number, dimension: .ratio, order: definitions.count
        ))
        let columns = try LedgerColumnSet(columns: definitions)
        let unitCost = try #require(columns.column(standard: .unitCost))
        let totalCost = try #require(columns.column(standard: .totalCost))

        let assignment = LedgerAssemblyAssignment(
            assemblyID: Self.recipe.id,
            parameters: ["Height": .length(Decimal(string: "2.4")!), "Spacing": .length(Decimal(string: "0.6")!)],
            definition: Self.recipe
        )
        let wall = NLQuantitiesMoneyTests.record(0, tool: .length, values: [.planLength: .length(10)],
                                                 custom: [assignmentColumn: assignment.cellValue])
        let derived = LedgerAssemblyExpansion.derivedRecords(for: wall, assignmentColumn: assignmentColumn, repeatColumn: repeatColumn)
        #expect(derived.map(\.subject) == ["Studs", "Plasterboard", "Plates", "Broken"])
        #expect(derived[0].customValues[unitCost.id] == NLQuantitiesMoneyTests.sek(Decimal(string: "45.50")!))
        #expect(derived[1].customValues[unitCost.id] == NLQuantitiesMoneyTests.sek(Decimal(string: "89.95")!))
        #expect(derived[2].customValues[unitCost.id] == nil, "a line without a rate prices nothing")

        let store = try LedgerStore(markups: [wall] + derived, columns: columns, quantityMultiplierColumn: repeatColumn)
        // Studs: FLOOR(10 / 0.6) + 1 = 17 pcs × 45.50 = 773.50 SEK.
        #expect(store.value(at: 1, definition: totalCost) == .value(NLQuantitiesMoneyTests.sek(Decimal(string: "773.50")!)))
        // Plasterboard: 10 × 2.4 × 2 = 48 m² × 89.95 = 4 317.60 SEK.
        #expect(store.value(at: 2, definition: totalCost) == .value(NLQuantitiesMoneyTests.sek(Decimal(string: "4317.60")!)))
        #expect(store.value(at: 3, definition: totalCost) == .empty)
        // A line that could not be evaluated has no quantity, so its rate prices nothing.
        #expect(store.value(at: 4, definition: totalCost) == .empty)
        #expect(store.value(at: 0, definition: totalCost) == .empty, "the wall itself carries no rate")
        // 773.50 + 4 317.60 = 5 091.10 SEK; the rate never sums.
        let view = store.makeView(LedgerViewSpec(aggregation: .standard(for: columns)))
        #expect(view.grandTotal[totalCost.id] == .currency(amount: Decimal(string: "5091.10")!, code: "SEK"))
        #expect(view.grandTotal[unitCost.id] == nil)

        // Repeated three times: 51 studs × 45.50 = 2 320.50; 144 m² × 89.95 = 12 952.80.
        var repeated = wall
        repeated.customValues[repeatColumn] = .number(DecimalQuantity(value: 3, dimension: .ratio))
        let tripled = LedgerAssemblyExpansion.derivedRecords(for: repeated, assignmentColumn: assignmentColumn, repeatColumn: repeatColumn)
        let tripledStore = try LedgerStore(markups: [repeated] + tripled, columns: columns, quantityMultiplierColumn: repeatColumn)
        #expect(tripledStore.value(at: 1, definition: totalCost) == .value(NLQuantitiesMoneyTests.sek(Decimal(string: "2320.50")!)))
        #expect(tripledStore.value(at: 2, definition: totalCost) == .value(NLQuantitiesMoneyTests.sek(Decimal(string: "12952.80")!)))
    }
}
