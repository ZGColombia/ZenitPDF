import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// NL-QTY-07-UI: a line's unit cost in the recipe, and the static line check a recipe editor and
/// a recipe import share.
@Suite("NL-QTY-07-UI — recipe unit cost and static line check")
struct NLQty07UIRecipeTests {

    static let id = UUID(uuid: (0x41, 0x53, 0x4D, 0x42, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x07, 0x01))

    static func recipe(_ lines: [AssemblyLine]) -> AssemblyDefinition {
        AssemblyDefinition(
            id: id,
            name: "Wall",
            inputs: [
                AssemblyInput(name: "Length", dimension: .length),
                AssemblyInput(name: "Height", dimension: .length),
                AssemblyInput(name: "Spacing", dimension: .length)
            ],
            lines: lines
        )
    }

    static func sek(_ text: String) -> DecimalQuantity {
        .money(Decimal(string: text)!, currencyCode: "SEK")
    }

    @Test("A recipe without unit costs encodes exactly as before; one with them round-trips the rate exactly")
    func unitCostCoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = try encoder.encode(AssemblyDefinition.timberStudWall)
        #expect(String(decoding: plain, as: UTF8.self).contains("unitCost") == false)
        // Re-decoding the old bytes gives no rate, and re-encoding gives the same bytes.
        let decoded = try JSONDecoder().decode(AssemblyDefinition.self, from: plain)
        #expect(decoded.lines.allSatisfy { $0.unitCost == nil })
        #expect(try encoder.encode(decoded) == plain)

        let priced = Self.recipe([
            AssemblyLine(name: "Board", source: "Length * Height * 2", outputDimension: .area, unitCost: Self.sek("89.95")),
            AssemblyLine(name: "Studs", source: "FLOOR(Length / Spacing) + 1", outputDimension: .count, unitCost: Self.sek("0.1"))
        ])
        let again = try JSONDecoder().decode(AssemblyDefinition.self, from: try encoder.encode(priced))
        #expect(again == priced)
        #expect(again.lines[0].unitCost?.value == Decimal(string: "89.95")!)
        #expect(again.lines[1].unitCost?.value == Decimal(string: "0.1")!, "0.1 exactly, not its binary neighbour")
        #expect(again.lines[1].unitCost?.dimension.currencyCode == "SEK")
    }

    @Test("A unit cost that is not money in one currency is refused by validate()")
    func unitCostMustBeMoney() throws {
        let perMetre = Self.recipe([AssemblyLine(
            name: "Plates", source: "Length * 2", outputDimension: .length,
            unitCost: DecimalQuantity(value: 12, dimension: .currencyRate("SEK", perLengthPower: 1))
        )])
        #expect(throws: AssemblyDefinitionError.unitCostNotMoney(line: "Plates")) { try perMetre.validate() }
        let length = Self.recipe([AssemblyLine(name: "Plates", source: "Length * 2", outputDimension: .length, unitCost: .length(3))])
        #expect(throws: AssemblyDefinitionError.unitCostNotMoney(line: "Plates")) { try length.validate() }
        let good = Self.recipe([AssemblyLine(name: "Plates", source: "Length * 2", outputDimension: .length, unitCost: Self.sek("12"))])
        try good.validate()
    }

    @Test("The static check refuses what evaluation always would, and nothing else")
    func staticRefusals() throws {
        let lines = [
            AssemblyLine(name: "ok area", source: "Length * Height", outputDimension: .area),
            AssemblyLine(name: "ok count", source: "FLOOR(Length / Spacing) + 1", outputDimension: .count),
            AssemblyLine(name: "wrong unit", source: "Length * 2", outputDimension: .area),
            AssemblyLine(name: "incomplete", source: "Length *", outputDimension: .length),
            AssemblyLine(name: "typo", source: "Lenght * 2", outputDimension: .length),
            AssemblyLine(name: "undeclared field", source: "Area * 2", outputDimension: .area),
            AssemblyLine(name: "aggregate", source: "SUM(Length)", outputDimension: .length),
            AssemblyLine(name: "boolean", source: "Length > 2", outputDimension: .count),
            AssemblyLine(name: "ok ratio as count", source: "Length / Spacing", outputDimension: .count)
        ]
        let evaluator = AssemblyEvaluator(Self.recipe(lines))
        #expect(evaluator.staticRefusal(forLine: 0) == nil)
        #expect(evaluator.staticRefusal(forLine: 1) == nil)
        #expect(evaluator.staticRefusal(forLine: 2) == .unexpectedDimension(expected: .area, actual: .length))
        guard case .formulaRefused? = evaluator.staticRefusal(forLine: 3) else {
            Issue.record("an incomplete formula is the parser's refusal"); return
        }
        #expect(evaluator.staticRefusal(forLine: 4) == .missingInput("Lenght"))
        #expect(evaluator.staticRefusal(forLine: 5) == .missingInput("Area"))
        #expect(evaluator.staticRefusal(forLine: 6) != nil)
        guard case .notANumber? = evaluator.staticRefusal(forLine: 7) else {
            Issue.record("a comparison is not a quantity"); return
        }
        #expect(evaluator.staticRefusal(forLine: 8) == nil, "count and ratio are one tag apart")
        #expect(evaluator.staticRefusal(forLine: 99) == nil)

        // Agreement with evaluation, on a 10 m wall at 2.4 m and 0.6 m: the lines that pass the
        // check produce 24 m² and FLOOR(16.67) + 1 = 17; every refused one is refused here too.
        let results = evaluator.evaluate(inputs: [
            "Length": .length(10), "Height": .length(Decimal(string: "2.4")!), "Spacing": .length(Decimal(string: "0.6")!)
        ])
        #expect(results[0].quantity?.value == .area(24))
        #expect(results[1].quantity?.value == .count(17))
        for index in 2...7 { #expect(results[index].isFailure, "line \(index)") }
    }
}
