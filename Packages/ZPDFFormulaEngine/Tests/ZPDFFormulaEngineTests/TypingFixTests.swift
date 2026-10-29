import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// Engine fixes: literal flexibility and the ADR-0014 count/ratio tag
/// (BH-153, BH-154, BH-155, BH-540, BH-541, BH-542, BH-543) and assembly inputs (BH-539).
@Suite("Literal flexibility and the ratio tag")
struct TypingFixTests {

    private let extra = makeColumnID(1)
    private let factor = makeColumnID(2)
    private let waste = makeColumnID(3)
    private let big = makeColumnID(4)

    /// `Extra` and `Factor` declare no dimension (dynamic); `Waste` is declared a ratio.
    private func catalog() throws -> FormulaColumnCatalog {
        try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: extra, name: "Extra", type: .dynamicNumber),
            FormulaColumnDescriptor(id: factor, name: "Factor", type: .dynamicNumber),
            FormulaColumnDescriptor(id: waste, name: "Waste", type: .number(.ratio)),
            FormulaColumnDescriptor(id: big, name: "Big", type: .number(.area))
        ])
    }

    private func run(_ source: String, _ row: FormulaRow) throws -> FormulaValue {
        try evaluate(source, row: row, catalog: catalog())
    }

    // MARK: BH-153

    /// BH-153. With a dynamic sibling, COALESCE and IF typed as `dynamicNumber` and returned the
    /// literal fallback as a raw count; the outer `+` was deferred, so exactly the rows where
    /// `Extra` is blank failed. Old output: `Cannot add length (m) and dimensionless (1)`.
    @Test("A literal fallback beside a dynamic column keeps its flexibility")
    func literalFallbackAdoptsAtRuntime() throws {
        let blank = try sampleRow(length: "4")
        var filled = blank
        filled.columns[extra] = .number(.length(try dec("0.5")))
        var wrongKind = blank
        wrongKind.columns[extra] = .number(.count(5))

        for source in [
            "Length + COALESCE([Extra], 0)",
            "COALESCE([Extra], 0) + Length",
            "IF(Area > 0, 0, [Extra]) + Length",
            "Length - -COALESCE([Extra], 0)",
            "MAX(Length, COALESCE([Extra], 0))",
            "Length + (COALESCE([Extra], 0) + 1)",
            // T-060: the rounding family, SQRT and ^ dropped the runtime marking. Old output on
            // the blank row: `Cannot add length (m) and dimensionless count (1)` for each.
            "Length + ROUND(COALESCE([Extra], 0), 2)",
            "Length + ROUNDUP(COALESCE([Extra], 0), 2)",
            "Length + ROUNDDOWN(COALESCE([Extra], 0))",
            "Length + CEILING(COALESCE([Extra], 0))",
            "Length + FLOOR(COALESCE([Extra], 0))",
            "Length + SQRT(COALESCE([Extra], 0))",
            "Length + COALESCE([Extra], 0) ^ 1"
        ] {
            let value = try run(source, blank)
            #expect(try value.dimension() == .length, "\(source)")
        }
        // T-060, by hand: 4 m + ROUND(0, 2) = 4 m; 4 m + ROUND(0.5 m, 0) = 4 m + 1 m (half away
        // from zero) = 5 m; 4 m + SQRT(0) = 4 m; 4 m + 0 ^ 1 = 4 m.
        #expect(try run("Length + ROUND(COALESCE([Extra], 0), 2)", blank) == .number(.length(4)))
        #expect(try run("Length + ROUND(COALESCE([Extra], 0), 0)", filled) == .number(.length(5)))
        #expect(try run("Length + SQRT(COALESCE([Extra], 0))", blank) == .number(.length(4)))
        #expect(try run("Length + COALESCE([Extra], 0) ^ 1", blank) == .number(.length(4)))
        // A power that changes the dimension: 12.5 m² + 0 ^ 2 = 12.5 m² on the blank row, and
        // 12.5 m² + (0.5 m)² = 12.75 m² on the filled one.
        #expect(try run("Area + COALESCE([Extra], 0) ^ 2", blank) == .number(.area(try dec("12.5"))))
        #expect(try run("Area + COALESCE([Extra], 0) ^ 2", filled) == .number(.area(try dec("12.75"))))
        // A rounded column value that is a count still never adopts: 4 m + ROUND(5 count).
        let roundedCount = try captureFormulaError { try run("Length + ROUND(COALESCE([Extra], 0))", wrongKind) }
        #expect(roundedCount.code == .dimensionMismatch(operation: "add", left: .length, right: .count))
        // 4 m + 0 = 4 m; 4 m + 0.5 m = 4.5 m; blank Extra + 1 literal = 1 adopts: 4 + 1 = 5 m.
        #expect(try run("Length + COALESCE([Extra], 0)", blank) == .number(.length(4)))
        #expect(try run("Length + COALESCE([Extra], 0)", filled) == .number(.length(try dec("4.5"))))
        #expect(try run("Length + (COALESCE([Extra], 0) + 1)", blank) == .number(.length(5)))
        #expect(try run("COALESCE([Extra], 0) < Length", blank) == .boolean(true))

        // A dimensionless value that came from the column still never adopts: 4 m + 5 count.
        let error = try captureFormulaError { try run("Length + COALESCE([Extra], 0)", wrongKind) }
        #expect(error.code == .dimensionMismatch(operation: "add", left: .length, right: .count))
    }

    // MARK: BH-154

    /// BH-154. `1 / 2` typed as a flexible *ratio*, so `1 + 1/2` became a non-flexible ratio and
    /// `Length + (1 + 1/2)` was refused. Old output: dimensionMismatch(length, ratio).
    @Test("A literal-only quotient stays a flexible literal")
    func literalQuotientIsFlexible() throws {
        #expect(try FormulaEngine.compile("1 / 2").resultType == .literalNumber)
        #expect(try FormulaEngine.compile("1 + 1 / 2").resultType == .literalNumber)
        let row = try sampleRow(length: "4")
        // 4 m + (1 + 1/2) = 5.5 m
        #expect(try run("Length + (1 + 1 / 2)", row) == .number(.length(try dec("5.5"))))
        // MAX(4 m, 1.5) = 4 m; IF picks 1.5, which adopts metres.
        #expect(try run("MAX(Length, 1 + 1 / 2)", row) == .number(.length(4)))
        #expect(try run("IF(Area < 0, Length, 1 + 1 / 2)", row) == .number(.length(try dec("1.5"))))
        // Count + 1.5 = 1 + 1.5 = 2.5 doors (sampleRow has Count = 1).
        #expect(try run("Count + (1 + 1 / 2)", row) == .number(.count(try dec("2.5"))))
        // The runtime value of 1/2 is a count, not a ratio: 0.5.
        #expect(try number("1 / 2") == (try dec("0.5")))
        #expect(try evaluate("1 / 2").dimension() == .count)
    }

    // MARK: BH-155

    /// BH-155. `formulaDescription` never read `ratio`, so an ADR-0014 refusal said "Cannot add
    /// dimensionless (1) and dimensionless (1)".
    @Test("Count and ratio are named differently in dimension messages")
    func countAndRatioMessages() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Count + Slope") }
        #expect(error.code == .dimensionMismatch(operation: "add", left: .count, right: .ratio))
        #expect(error.message == "Cannot add dimensionless count (1) and dimensionless ratio (1) in `Count + Slope`.")
        #expect(QuantityDimension.count.formulaDescription != QuantityDimension.ratio.formulaDescription)
    }

    // MARK: BH-540, BH-543

    /// BH-540. SQRT built its result with the non-flexible factory, so `Length + SQRT(4)` was
    /// refused while `Length + 2` worked. Old output: dimensionMismatch(length, count).
    @Test("SQRT of a literal is a literal")
    func sqrtOfLiteralIsFlexible() throws {
        #expect(try FormulaEngine.compile("SQRT(4)").resultType == .literalNumber)
        let row = try sampleRow(area: "12.5", length: "4")
        // 4 m + sqrt(4) = 6 m; MAX(12.5 m^2, sqrt(9) = 3) = 12.5 m^2.
        #expect(try run("Length + SQRT(4)", row) == .number(.length(6)))
        #expect(try run("MAX(Area, SQRT(9))", row) == .number(.area(try dec("12.5"))))
    }

    /// BH-543. `SQRT` rebuilt the dimension with the memberwise init, dropping the ratio tag, so
    /// `SQRT([Waste]) + Count` type-checked (a factor summed into a count) and
    /// `SQRT([Waste]) + [Waste]` was refused. Old output: `.number(.count)` for `SQRT([Waste])`.
    @Test("SQRT keeps the ratio tag")
    func sqrtKeepsRatio() throws {
        let catalog = try catalog()
        #expect(try FormulaEngine.compile("SQRT([Waste])", catalog: catalog).resultType == .number(.ratio))
        #expect(try FormulaEngine.compile("SQRT(Slope)").resultType == .number(.ratio))
        #expect(try FormulaEngine.compile("SQRT(Count)").resultType == .number(.count))
        let refused = try captureFormulaError { try FormulaEngine.compile("SQRT([Waste]) + Count", catalog: catalog) }
        #expect(refused.code == .dimensionMismatch(operation: "add", left: .ratio, right: .count))

        var row = try sampleRow()
        row.columns[waste] = .number(.ratio(try dec("1.44")))
        // sqrt(1.44) + 1.44 = 1.2 + 1.44 = 2.64, a ratio.
        #expect(try run("SQRT([Waste]) + [Waste]", row) == .number(.ratio(try dec("2.64"))))
        // A dynamic operand holding a ratio keeps it at run time too: sqrt(1.44) = 1.2 ratio.
        row.columns[factor] = .number(.ratio(try dec("1.44")))
        #expect(try run("SQRT([Factor])", row) == .number(.ratio(try dec("1.2"))))
    }

    // MARK: BH-541

    /// BH-541. CONVERT called `NumericPolicy.requireFinite` outside `FormulaRuntimeChecks.wrap`,
    /// so an overflow escaped as a raw `NumericError` that a per-cell `catch FormulaEngineError`
    /// does not catch. Old output: `NumericError.decimalOverflow(operation: "convert")`.
    @Test("A CONVERT overflow is a FormulaEngineError")
    func convertOverflowIsTyped() throws {
        var row = FormulaRow()
        // greatestFiniteMagnitude / 10 x 1 000 000 (m^2 -> mm^2) overflows Decimal to NaN.
        row.columns[big] = .number(.area(Decimal.greatestFiniteMagnitude / 10))
        let program = try FormulaEngine.compile("CONVERT([Big], m2, mm2)", catalog: catalog())
        do {
            _ = try program.evaluate(row: row)
            Issue.record("expected an overflow")
        } catch let error as FormulaEngineError {
            #expect(error.code == .numericOverflow(operation: "convert"))
            #expect(error.subexpression == "CONVERT([Big], m2, mm2)")
        } catch {
            Issue.record("escaped as a foreign error: \(error)")
        }
    }

    // MARK: BH-542

    /// BH-542. With a dynamic operand the static rule returned `dynamicNumber` before literal
    /// transparency ran, so `[Factor] * 100` on a ratio-valued Factor came out a count — and
    /// `[Factor] * 100 + Slope` failed at evaluation. Old output: `115 count`.
    @Test("Literal transparency applies to an undeclared column at run time")
    func literalTransparencyForDynamicOperand() throws {
        var row = try sampleRow()
        row.fields[.slopeRatio] = .ratio(try dec("0.25"))
        row.columns[factor] = .number(.ratio(try dec("1.15")))
        // 1.15 x 100 = 115, still a ratio, like the declared `[Waste] * 100`.
        #expect(try run("[Factor] * 100", row) == .number(.ratio(115)))
        // 100 / 1.15 is a ratio by the same static rule as `100 / [Waste]`.
        #expect(try run("100 / [Factor]", row).dimension() == .ratio)
        // 115 + 0.25 = 115.25 ratio.
        #expect(try run("[Factor] * 100 + Slope", row) == .number(.ratio(try dec("115.25"))))
        // A count-valued Factor stays a count: 4 x 2 = 8 count.
        row.columns[factor] = .number(.count(4))
        #expect(try run("[Factor] * 2", row) == .number(.count(8)))
        // A dimensioned Factor is untouched: 3 m x 2 = 6 m.
        row.columns[factor] = .number(.length(3))
        #expect(try run("[Factor] * 2", row) == .number(.length(6)))
    }

    // MARK: BH-539

    /// BH-539. Supplied input values were never checked against the declared input dimension,
    /// so `Length: 24 m^2, Height: 2.5 count` made `Length * Height * 2` an area that passed the
    /// output check. Old output: `.quantity(120 m^2)` for "Plasterboard both sides".
    @Test("A supplied input in the wrong dimension is refused on the lines that read it")
    func assemblyInputDimensions() throws {
        let results = AssemblyEvaluator.evaluate(.timberStudWall, inputs: [
            "Length": .area(24),
            "Height": .count(try dec("2.5")),
            "Spacing": .length(try dec("0.6"))
        ])
        for line in ["Wall area", "Plates", "Plasterboard both sides", "Studs"] {
            let failure = try #require(results.result(for: line)?.failure, "\(line) produced a quantity")
            guard case .inputDimensionMismatch(let name, let expected, _) = failure.reason else {
                Issue.record("\(line): got \(failure.reason)")
                continue
            }
            #expect(expected == .length)
            #expect(name == "Length" || name == "Height")
        }

        // A dimensionless value for a dimensionless input is re-tagged, not refused.
        let definition = AssemblyDefinition(
            id: UUID(uuid: (0x5A, 0x50, 0x44, 0x46, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x39)),
            name: "Waste",
            inputs: [
                AssemblyInput(name: "Area", dimension: .area),
                AssemblyInput(name: "Allowance", dimension: .ratio)
            ],
            lines: [AssemblyLine(name: "Board", source: "Area * Allowance", outputDimension: .area)]
        )
        let retagged = AssemblyEvaluator.evaluate(definition, inputs: [
            "Area": .area(10),
            "Allowance": .count(try dec("1.1"))
        ])
        let board = try #require(retagged.result(for: "Board")?.quantity)
        // 10 m^2 x 1.1 = 11 m^2, and the provenance records the allowance as the declared ratio.
        #expect(board.value == .area(11))
        #expect(board.inputsUsed["Allowance"] == .ratio(try dec("1.1")))
    }
}
