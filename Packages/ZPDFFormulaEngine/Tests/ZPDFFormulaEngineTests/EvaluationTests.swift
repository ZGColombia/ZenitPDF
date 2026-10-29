import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

@Suite("Evaluation and typed failures")
struct EvaluationTests {

    @Test("Division by zero is a typed error, never NaN or infinity")
    func divisionByZero() throws {
        let error = try captureFormulaError { try number("1 / 0") }
        #expect(error.code == .divisionByZero)
        #expect(error.subexpression == "1 / 0")
    }

    @Test("Division by a zero-valued measurement is a typed error too")
    func divisionByZeroField() throws {
        let row = FormulaRow(fields: [.netArea: .area(0), .planLength: .length(3)])
        let error = try captureFormulaError { try evaluate("Length / Area", row: row) }
        #expect(error.code == .divisionByZero)
    }

    @Test("A negative power of zero is a typed error")
    func negativePowerOfZero() throws {
        let error = try captureFormulaError { try number("0 ^ -1") }
        #expect(error.code == .divisionByZero)
    }

    @Test("Remainder by zero is its own typed error")
    func moduloByZero() throws {
        let error = try captureFormulaError { try number("5 % 0") }
        #expect(error.code == .moduloByZero)
    }

    @Test("A repeating quotient stays finite")
    func repeatingQuotientIsFinite() throws {
        let value = try number("1 / 3")
        #expect(value > 0)
        #expect(value < 1)
        #expect(!value.isNaN)
        #expect(value * 3 <= 1)
    }

    @Test("A blank cell in arithmetic is an error, not a silent zero")
    func blankIsNotZero() throws {
        let id = makeColumnID(21)
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: id, name: "Waste", type: .number(.count))
        ])
        let error = try captureFormulaError {
            try evaluate("[Waste] * 2", row: FormulaRow(), catalog: catalog)
        }
        guard case .blankValue = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("COALESCE supplies the fallback for a blank cell")
    func coalesceFallback() throws {
        let id = makeColumnID(22)
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: id, name: "Waste", type: .number(.count))
        ])
        #expect(try evaluate("COALESCE([Waste], 1.1) * 2", row: FormulaRow(), catalog: catalog)
            .decimal() == (try dec("2.2")))
    }

    @Test("IF evaluates only the branch it takes")
    func ifShortCircuits() throws {
        // The untaken branch divides by zero; if it were evaluated the test would throw.
        #expect(try number("IF(1 < 2, 10, 1 / 0)") == 10)
        #expect(try number("IF(1 > 2, 1 / 0, 20)") == 20)
    }

    @Test("'and' and 'or' short-circuit")
    func booleanShortCircuit() throws {
        #expect(try evaluate("false and (1 / 0) > 0") == .boolean(false))
        #expect(try evaluate("true or (1 / 0) > 0") == .boolean(true))
    }

    @Test("MIN and MAX respect dimensions and pick the right value")
    func minimumAndMaximum() throws {
        let row = try sampleRow(perimeter: "15", length: "4")
        #expect(try evaluate("MIN(Length, Perimeter)", row: row).decimal() == 4)
        #expect(try evaluate("MAX(Length, Perimeter, 20)", row: row).decimal() == 20)
        let error = try captureFormulaError { try FormulaEngine.compile("MIN(Length, Area)") }
        guard case .dimensionMismatch = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("ABS keeps the dimension and drops the sign")
    func absoluteValue() throws {
        let value = try evaluate("ABS(0 - Length)", row: try sampleRow(length: "4"))
        #expect(try value.decimal() == 4)
        #expect(try value.dimension() == .length)
    }

    @Test("SQRT of a negative number is a typed error, not NaN")
    func negativeSquareRoot() throws {
        let error = try captureFormulaError { try number("SQRT(0 - 4)") }
        guard case .negativeSquareRoot = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("SQRT is accurate to Decimal precision")
    func squareRootAccuracy() throws {
        let root = try DecimalMath.squareRoot(try dec("2"))
        let squared = root * root
        #expect(DecimalMath.abs(squared - 2) < (try dec("0.0000000000000000000000001")))
    }

    @Test("POW matches the '^' operator")
    func powFunction() throws {
        #expect(try number("POW(2, 10)") == 1024)
        #expect(try number("POW(2, -2)") == (try dec("0.25")))
    }

    /// `1000000 ^ 64` saturates `Decimal` to NaN, and a NaN `Decimal` compares as less than
    /// everything, so the old code returned NaN from the power and `0` from the IF — it steered
    /// the comparison silently (code review CR-24). Old output: `number("1000000 ^ 64")` was
    /// `Decimal.nan`; `IF(1000000 ^ 64 > 1, 1, 0)` was `0`.
    @Test("An overflowing power is a typed error, never a NaN that steers a comparison (CR-24)")
    func powerOverflowIsTyped() throws {
        let overflow = try captureFormulaError { try number("1000000 ^ 64") }
        #expect(overflow.code == .numericOverflow(operation: "power"))
        let steered = try captureFormulaError { try number("IF(1000000 ^ 64 > 1, 1, 0)") }
        #expect(steered.code == .numericOverflow(operation: "power"))
        let negative = try captureFormulaError { try number("1000000 ^ -64") }
        #expect(negative.code == .numericOverflow(operation: "power"))
        // The same saturation through multiplication carries the engine's own code too.
        let product = try captureFormulaError { try number("10 ^ 60 * 10 ^ 60 * 10 ^ 60") }
        #expect(product.code == .numericOverflow(operation: "multiply"))
        // A large but representable power is still exact.
        #expect(try number("10 ^ 60") == Decimal(sign: .plus, exponent: 60, significand: 1))
    }

    @Test("An exponent beyond the supported range is refused")
    func exponentRange() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("2 ^ 500") }
        #expect(error.code == .exponentOutOfRange(500))
    }

    @Test("Remainder truncates toward zero and keeps the left dimension")
    func remainderSemantics() throws {
        #expect(try number("7 % 3") == 1)
        #expect(try number("(0 - 7) % 3") == -1)
        let value = try evaluate("Perimeter % 4", row: try sampleRow(perimeter: "15"))
        #expect(try value.decimal() == 3)
        #expect(try value.dimension() == .length)
    }

    @Test("Booleans compare with == and != but not with <")
    func booleanComparison() throws {
        #expect(try evaluate("true == true") == .boolean(true))
        #expect(try evaluate("true != false") == .boolean(true))
        let error = try captureFormulaError { try FormulaEngine.compile("true < false") }
        guard case .typeMismatch = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("Using a number where a condition belongs is a typed error")
    func conditionMustBeBoolean() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("IF(1, 2, 3)") }
        guard case .typeMismatch = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("The same program evaluated twice gives the same answer")
    func evaluationIsPure() throws {
        let program = try FormulaEngine.compile("IF(Area > 10, Area * 2.5, Area * 1.5) + Perimeter * Depth")
        let row = try sampleRow()
        let first = try program.evaluate(row: row)
        let second = try program.evaluate(row: row)
        #expect(first == second)
    }

    @Test("An unknown identifier is reported as an unknown column")
    func unknownColumn() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("Nonexistent + 1") }
        #expect(error.code == .unknownColumnName("Nonexistent"))
    }
}
