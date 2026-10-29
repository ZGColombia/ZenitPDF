import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

@Suite("Dimensional analysis")
struct DimensionTests {

    @Test("Adding length to area is refused at parse time, naming both dimensions")
    func lengthPlusAreaIsRefused() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Length + Area") }
        guard case .dimensionMismatch(let operation, let left, let right) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(operation == "add")
        #expect(left == .length)
        #expect(right == .area)
        #expect(error.subexpression == "Length + Area")
        #expect(error.message.contains("length (m)"))
        #expect(error.message.contains("area (m^2)"))
        #expect(error.message.contains("Length + Area"))
    }

    @Test("The reported sub-expression is the offending node, not the whole formula")
    func subexpressionIsTheOffendingNode() throws {
        let error = try captureFormulaError {
            try FormulaEngine.compile("ROUND(Perimeter + WallArea, 2) * 2")
        }
        #expect(error.subexpression == "Perimeter + WallArea")
    }

    @Test("Metre times metre is a square metre")
    func lengthTimesLength() throws {
        let program = try FormulaEngine.compile("Length * Length")
        #expect(program.resultType == .number(.area))
        let row = try sampleRow(length: "3")
        #expect(try program.evaluate(row: row).decimal() == 9)
        #expect(try program.evaluate(row: row).dimension() == .area)
    }

    @Test("Area divided by length is a length")
    func areaOverLength() throws {
        let program = try FormulaEngine.compile("Area / Length")
        #expect(program.resultType == .number(.length))
    }

    @Test("A bare number adopts the dimension it is added to")
    func literalsAreDimensionFlexible() throws {
        let program = try FormulaEngine.compile("Length + 5")
        #expect(program.resultType == .number(.length))
        let value = try program.evaluate(row: try sampleRow(length: "4"))
        #expect(try value.decimal() == 9)
        #expect(try value.dimension() == .length)
    }

    @Test("A dimensionless variable does not adopt anything")
    func dimensionlessVariablesAreNotFlexible() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Area + Count") }
        guard case .dimensionMismatch(_, let left, let right) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(left == .area)
        #expect(right == .count)
    }

    @Test("Comparing an area against a bare number is allowed")
    func comparisonAgainstLiteral() throws {
        let row = try sampleRow(area: "12.5")
        #expect(try evaluate("Area > 10", row: row) == .boolean(true))
    }

    @Test("Comparing an area against a length is refused")
    func comparisonAcrossDimensions() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Area > Length") }
        guard case .dimensionMismatch(let operation, _, _) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(operation == "compare")
    }

    /// ADR-0014 (code review CR-102): a ratio-dimensioned column — a waste factor, a slope —
    /// keeps its tag through bare literals, scales whatever it multiplies, and never adds to a
    /// count. Before the tag existed every line here typed as `.count`, and `Count + [Waste]`
    /// compiled and summed to 5.15.
    @Test("A ratio column keeps its tag through literals and is absorbed by a count (ADR-0014)")
    func ratioColumnsType() throws {
        let waste = makeColumnID(1)
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: waste, name: "Waste", type: .number(.ratio))
        ])
        var row = try sampleRow(area: "10")
        row.fields[.count] = .count(4)
        row.columns[waste] = .number(.ratio(try dec("1.15")))

        func typed(_ source: String) throws -> FormulaStaticType {
            try FormulaEngine.compile(source, catalog: catalog).resultType
        }
        func run(_ source: String) throws -> FormulaValue {
            try evaluate(source, row: row, catalog: catalog)
        }

        #expect(try typed("[Waste] * 100") == .number(.ratio))
        #expect(try run("[Waste] * 100").dimension() == .ratio)
        #expect(try run("[Waste] * 100").decimal() == 115)
        #expect(try typed("100 / [Waste]") == .number(.ratio))
        #expect(try run("[Waste] + 1").dimension() == .ratio)
        #expect(try run("[Waste] ^ 2").dimension() == .ratio)
        #expect(try run("[Waste] * [Waste]").dimension() == .ratio)

        // A factor scales a count and an area without changing what they are.
        #expect(try typed("Count * [Waste]") == .number(.count))
        #expect(try run("Count * [Waste]").dimension() == .count)
        let scaledCount = try dec("4.6")
        #expect(try run("Count * [Waste]").decimal() == scaledCount)
        #expect(try run("Area * [Waste]").dimension() == .area)
        #expect(try run("Count / [Waste]").dimension() == .count)

        // A literal is transparent: half the doors is still doors; doors per door is a ratio.
        #expect(try typed("Count / 2") == .number(.count))
        #expect(try run("Count / 2").dimension() == .count)
        #expect(try run("Count / Count").dimension() == .ratio)
        #expect(try run("Count ^ 2").dimension() == .count)
        #expect(try typed("2 * 3") == .literalNumber)

        // The point of the tag: a factor never sums into a count.
        let error = try captureFormulaError { try FormulaEngine.compile("Count + [Waste]", catalog: catalog) }
        guard case .dimensionMismatch(let operation, let left, let right) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(operation == "add")
        #expect(left == .count)
        #expect(right == .ratio)
    }

    @Test("An integer power raises the dimension with it")
    func integerPowerRaisesDimension() throws {
        #expect(try FormulaEngine.compile("Length ^ 2").resultType == .number(.area))
        #expect(try FormulaEngine.compile("Length ^ 3").resultType == .number(.volume))
        #expect(try FormulaEngine.compile("Length ^ 0").resultType == .number(.count, flexible: false))
    }

    @Test("A power that leaves the supported length range is refused")
    func powerOutOfRange() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Length ^ 4") }
        #expect(error.code == .dimensionRejected(.unsupportedLengthPower(4)))
    }

    @Test("A fractional exponent is refused: exponents are whole numbers only")
    func fractionalExponent() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Length ^ 1.5") }
        guard case .nonIntegerExponent = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("A non-literal exponent is refused, so x ^ n has a compile-time dimension")
    func nonLiteralExponent() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Length ^ Count") }
        guard case .typeMismatch = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("SQRT halves an even length power and refuses an odd one")
    func squareRootDimensions() throws {
        #expect(try FormulaEngine.compile("SQRT(Area)").resultType == .number(.length))
        let error = try captureFormulaError { try FormulaEngine.compile("SQRT(Length)") }
        #expect(error.code == .squareRootOfOddDimension(.length))
    }

    @Test("A column with no declared dimension defers its check to evaluation")
    func dynamicColumnCheckedAtRuntime() throws {
        let id = makeColumnID(11)
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: id, name: "Imported", type: .dynamicNumber)
        ])
        let program = try FormulaEngine.compile("[Imported] + Length", catalog: catalog)
        #expect(program.resultType == .dynamicNumber)

        var row = try sampleRow(length: "2")
        row.columns[id] = .number(.length(try dec("3")))
        #expect(try program.evaluate(row: row).decimal() == 5)

        row.columns[id] = .number(.area(try dec("3")))
        let error = try captureFormulaError { try program.evaluate(row: row) }
        guard case .dimensionMismatch(let operation, let left, let right) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(operation == "add")
        #expect(left == .area)
        #expect(right == .length)
        #expect(error.subexpression == "[Imported] + Length")
    }

    @Test("Angle times angle has no meaning and is refused")
    func angleSquaredIsRefused() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Angle * Angle") }
        #expect(error.code == .dimensionRejected(.angleProductUndefined))
    }

    @Test("A unit price times an area is money")
    func unitPriceTimesArea() throws {
        let price = makeColumnID(12)
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(
                id: price,
                name: "Price",
                type: .number(.currencyRate("SEK", perLengthPower: 2))
            )
        ])
        let program = try FormulaEngine.compile("Area * [Price]", catalog: catalog)
        #expect(program.resultType == .number(.currency("SEK")))
        var row = try sampleRow(area: "10")
        row.columns[price] = .number(
            DecimalQuantity(value: try dec("450"), dimension: .currencyRate("SEK", perLengthPower: 2))
        )
        #expect(try program.evaluate(row: row).decimal() == 4500)
    }
}
