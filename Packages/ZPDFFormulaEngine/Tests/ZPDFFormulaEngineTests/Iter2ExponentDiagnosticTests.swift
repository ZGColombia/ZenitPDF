import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// C-03: an exponent past 2^53 is a
/// whole number that is out of range, and the diagnostic says so.
///
/// Old output: `Area ^ 5000000000000000000` was refused as
/// `nonIntegerExponent(5000000000000000000)`, whose message read "Exponents must be whole numbers;
/// `5000000000000000000` is not" — telling the user a whole number is not one. The cause was
/// `DecimalMath.integer` returning nil both for a fraction and for a whole number too large for
/// the Int-safe range, and the compiler reading every nil as "fractional".
@Suite("Iteration 2 — measurement presentation, exponent diagnostics")
struct Iter2ExponentDiagnosticTests {

    @Test("A whole-number exponent past 2^53 is out of range, not fractional")
    func hugeWholeExponentIsOutOfRange() throws {
        let huge = try dec("5000000000000000000")
        let error = try captureFormulaError { try FormulaEngine.compile("Area ^ 5000000000000000000") }
        #expect(error.code == .exponentOutOfRange(huge))
        #expect(error.message.contains("outside the supported range -64...64"))
        #expect(!error.message.contains("whole numbers"))
    }

    @Test("Int.min as an exponent is out of range, and so is a folded literal past 2^53")
    func negativeAndFoldedExponents() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("2 ^ -9223372036854775808") }
        #expect(error.code == .exponentOutOfRange(try dec("-9223372036854775808")))
        // `10 ^ 20` folds to 1e20, a whole number beyond Int's safe range.
        let folded = try captureFormulaError { try FormulaEngine.compile("2 ^ (10 ^ 20)") }
        #expect(folded.code == .exponentOutOfRange(try dec("100000000000000000000")))
    }

    @Test("The in-range bounds and the fractional refusal are unchanged")
    func boundsAndFractionsUnchanged() throws {
        #expect(throws: Never.self) { _ = try FormulaEngine.compile("2 ^ 64") }
        #expect(try captureFormulaError { try FormulaEngine.compile("2 ^ 65") }.code == .exponentOutOfRange(65))
        #expect(try captureFormulaError { try FormulaEngine.compile("2 ^ -65") }.code == .exponentOutOfRange(-65))
        let fractional = try captureFormulaError { try FormulaEngine.compile("Length ^ 1.5") }
        #expect(fractional.code == .nonIntegerExponent(try dec("1.5")))
        #expect(fractional.message.contains("whole numbers"))
    }
}
