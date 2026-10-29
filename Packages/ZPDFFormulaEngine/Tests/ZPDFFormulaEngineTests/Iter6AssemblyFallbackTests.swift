import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// W-071: an assembly line was refused for every input it *named* but did not get, before the
/// program ran, so a recipe's own `COALESCE` or `IF` fallback never ran. The refusal now comes
/// from evaluation: a line that reads the absent value is still refused by name, and a line that
/// only names it is evaluated.
@Suite("Assemblies — optional inputs with a stated fallback (W-071)")
struct Iter6AssemblyFallbackTests {

    private static let id = UUID(uuid: (0x41, 0x53, 0x4D, 0x42, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x06, 0x71))

    private func definition(_ lines: [AssemblyLine]) -> AssemblyDefinition {
        AssemblyDefinition(
            id: Self.id,
            name: "Optional height",
            inputs: [
                AssemblyInput(name: "Length", dimension: .length),
                AssemblyInput(name: "Height", dimension: .length),
                AssemblyInput(name: "Spacing", dimension: .length)
            ],
            lines: lines
        )
    }

    /// Old output: `.missingInput("Height")`, although the formula gives its own fallback.
    @Test("COALESCE's fallback is used when the named input is absent")
    func coalesceFallbackRuns() throws {
        let recipe = definition([
            AssemblyLine(name: "Face", source: "Length * COALESCE(Height, 2.4)", outputDimension: .area)
        ])
        let evaluator = AssemblyEvaluator(recipe)
        // The editor and the import already accepted this line; evaluation now agrees.
        #expect(evaluator.staticRefusal(forLine: 0) == nil)

        let results = evaluator.evaluate(inputs: ["Length": .length(try dec("10"))])
        let face = try #require(results.result(for: "Face")?.quantity, "\(results)")
        // Hand-derived: Height is absent, so COALESCE gives 2.4 m; 10 m × 2.4 m = 24 m².
        #expect(face.value == .area(try dec("24")))
        // Provenance lists only what the line had: Height was never supplied.
        #expect(face.inputsUsed == ["Length": .length(try dec("10"))])

        // With Height supplied the fallback is not used: 10 m × 3 m = 30 m².
        let supplied = evaluator.evaluate(inputs: ["Length": .length(try dec("10")), "Height": .length(try dec("3"))])
        #expect(supplied.result(for: "Face")?.quantity?.value == .area(try dec("30")))
    }

    /// Old output: `.missingInput("Height")` on both measurements.
    @Test("An IF whose untaken branch reads an absent input still evaluates; the taken branch is refused by name")
    func untakenBranchIsNotRead() throws {
        let recipe = definition([
            AssemblyLine(name: "Run", source: "IF(Length > 5, Length, Height)", outputDimension: .length)
        ])
        let evaluator = AssemblyEvaluator(recipe)

        // Hand-derived: 9.6 > 5, so the line is Length = 9.6 m; Height is never read.
        let long = evaluator.evaluate(inputs: ["Length": .length(try dec("9.6"))])
        #expect(long.result(for: "Run")?.quantity?.value == .length(try dec("9.6")))

        // 3 > 5 is false, so the line reads Height, which is absent: refused by its declared name.
        let short = evaluator.evaluate(inputs: ["Length": .length(try dec("3"))])
        #expect(short.result(for: "Run")?.failure?.reason == .missingInput("Height"))
    }

    @Test("A line that really needs an absent input is still refused by that input's name")
    func neededInputIsStillRefused() throws {
        let recipe = definition([
            AssemblyLine(name: "Bare", source: "Length / Spacing", outputDimension: .count),
            AssemblyLine(name: "Bracketed", source: "FLOOR(Length / [spacing]) + 1", outputDimension: .count),
            // Two absent names: Height has a fallback and Spacing has none. The refusal names the
            // one evaluation actually needed. Old output: `.missingInput("Height")`, the first name
            // in reading order, which the line did not need.
            AssemblyLine(name: "Both", source: "COALESCE(Height, 2.4) / Spacing", outputDimension: .count)
        ])
        let results = AssemblyEvaluator.evaluate(recipe, inputs: ["Length": .length(try dec("9.6"))])
        #expect(results.result(for: "Bare")?.failure?.reason == .missingInput("Spacing"))
        // The declared spelling, not the one the formula wrote.
        #expect(results.result(for: "Bracketed")?.failure?.reason == .missingInput("Spacing"))
        #expect(results.result(for: "Both")?.failure?.reason == .missingInput("Spacing"))
    }

    @Test("A supplied value in the wrong dimension is still refused before evaluation, even behind a fallback")
    func mismatchIsStillCheckedFirst() throws {
        let recipe = definition([
            AssemblyLine(name: "Face", source: "Length * COALESCE(Height, 2.4)", outputDimension: .area)
        ])
        let results = AssemblyEvaluator.evaluate(
            recipe,
            inputs: ["Length": .length(try dec("10")), "Height": .area(try dec("3"))]
        )
        #expect(results.result(for: "Face")?.failure?.reason
            == .inputDimensionMismatch(name: "Height", expected: .length, actual: .area))
    }
}
