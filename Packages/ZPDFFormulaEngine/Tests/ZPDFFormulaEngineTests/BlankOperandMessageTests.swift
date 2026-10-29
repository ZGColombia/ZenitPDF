import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

// U-071: the "is blank" error names the operand that was blank, and its COALESCE advice is one
// that works when followed literally.

private let wasteID = makeColumnID(71)
private let doneID = makeColumnID(72)

private func blankCatalog() throws -> FormulaColumnCatalog {
    try FormulaColumnCatalog(columns: [
        FormulaColumnDescriptor(id: wasteID, name: "Waste", type: .number(.count)),
        FormulaColumnDescriptor(id: doneID, name: "Done", type: .boolean)
    ])
}

private func blankError(_ source: String) throws -> FormulaEngineError {
    let catalog = try blankCatalog()
    return try captureFormulaError { try evaluate(source, row: FormulaRow(), catalog: catalog) }
}

@Suite("A blank operand is named in the error — U-071")
struct BlankOperandMessageTests {

    /// Old output: code `.blankValue("[Waste] * 2")`, message "`[Waste] * 2` is blank and cannot
    /// be used in arithmetic. Wrap it in COALESCE."
    @Test("`[Waste] * 2` names `[Waste]` and keeps the product as context")
    func productNamesTheBlankColumn() throws {
        let error = try blankError("[Waste] * 2")
        #expect(error.code == .blankValue("[Waste]"))
        #expect(error.subexpression == "[Waste] * 2")
        #expect(error.message == "`[Waste]` is blank in `[Waste] * 2` and cannot be used in a calculation. Use COALESCE([Waste], 0) to give it a value.")
    }

    /// Old output: `.blankValue("2 * [Waste]")` — the right operand was not told apart either.
    @Test("The right-hand operand is named when it is the blank one")
    func rightOperand() throws {
        let error = try blankError("2 + [Waste]")
        #expect(error.code == .blankValue("[Waste]"))
        #expect(error.subexpression == "2 + [Waste]")
    }

    /// Old output: `.blankValue("ROUND([Waste], 2)")`.
    @Test("`ROUND([Waste], 2)` names `[Waste]`")
    func roundNamesTheBlankColumn() throws {
        let error = try blankError("ROUND([Waste], 2)")
        #expect(error.code == .blankValue("[Waste]"))
        #expect(error.message.contains("in `ROUND([Waste], 2)`"))
        #expect(error.message.contains("COALESCE([Waste], 0)"))
    }

    @Test("Unary minus, SQRT, CONVERT, comparisons and MAX name the operand too", arguments: [
        "-[Waste]", "SQRT([Waste])", "CONVERT([Waste], m, mm)", "[Waste] > 1", "MAX(1, [Waste])", "[Waste] ^ 2"
    ])
    func everyNumericCheckNamesTheOperand(source: String) throws {
        let error = try blankError(source)
        #expect(error.code == .blankValue("[Waste]"), "\(source)")
        #expect(error.subexpression != "[Waste]", "the enclosing expression stays as context")
        #expect(error.message.contains("COALESCE([Waste], 0)"))
    }

    /// Old output: `.blankValue("IF([Done], 1, 2)")` with "cannot be used in arithmetic", which
    /// is not what a condition does.
    @Test("A blank condition is its own code, with a true/false fallback in the advice")
    func blankCondition() throws {
        let error = try blankError("IF([Done], 1, 2)")
        #expect(error.code == .blankCondition("[Done]"))
        #expect(error.message == "`[Done]` is blank in `IF([Done], 1, 2)` and cannot be used as true or false. Use COALESCE([Done], false) to give it a value.")
        #expect(!error.message.contains("arithmetic"))
    }

    @Test("`not` and `and` name the blank condition operand")
    func booleanOperators() throws {
        #expect(try blankError("not [Done]").code == .blankCondition("[Done]"))
        #expect(try blankError("(1 < 2) and [Done]").code == .blankCondition("[Done]"))
    }

    /// The advice, followed literally, works: under the old message the only thing to wrap was
    /// `[Waste] * 2`, and `COALESCE([Waste] * 2, 0)` fails with the same error from inside.
    @Test("Following the advice evaluates, where wrapping the whole expression did not")
    func adviceWorks() throws {
        let catalog = try blankCatalog()
        let wrappedWhole = try captureFormulaError {
            try evaluate("COALESCE([Waste] * 2, 0)", row: FormulaRow(), catalog: catalog)
        }
        #expect(wrappedWhole.code == .blankValue("[Waste]"))
        // Hand-derived: COALESCE(blank, 0) = 0, and 0 * 2 = 0.
        #expect(try evaluate("COALESCE([Waste], 0) * 2", row: FormulaRow(), catalog: catalog).decimal() == 0)
        #expect(try evaluate("IF(COALESCE([Done], false), 1, 2)", row: FormulaRow(), catalog: catalog).decimal() == 2)
    }
}
