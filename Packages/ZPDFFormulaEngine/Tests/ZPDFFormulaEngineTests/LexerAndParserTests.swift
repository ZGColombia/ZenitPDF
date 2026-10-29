import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

@Suite("Lexing and parsing")
struct LexerAndParserTests {

    @Test("The decimal separator is '.' in every locale")
    func decimalPointIsUniversal() throws {
        #expect(try number("1.5 + 1.5") == (try dec("3")))
    }

    @Test("A comma is an argument separator, never a decimal comma")
    func commaIsNotADecimalSeparator() throws {
        // `1,5` must not silently become one-and-a-half for a Swedish user.
        let error = try captureFormulaError { try number("1,5") }
        guard case .trailingInput(let text) = error.code else {
            Issue.record("expected trailing input, got \(error.code)")
            return
        }
        #expect(text == ",")
    }

    @Test("Unknown characters are rejected with their offset")
    func unknownCharacter() throws {
        let error = try captureFormulaError { try number("1 + $2") }
        guard case .unexpectedCharacter(let character) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(character == "$")
        #expect(error.span?.start == 4)
    }

    @Test("An unterminated column reference is a typed error")
    func unterminatedBracket() throws {
        let error = try captureFormulaError { try FormulaEngine.parse("[Area") }
        #expect(error.code == .unterminatedColumnReference)
    }

    @Test("A number with two decimal points is malformed, not two tokens")
    func malformedNumber() throws {
        let error = try captureFormulaError { try FormulaEngine.parse("1.2.3") }
        guard case .malformedNumber = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("Equality is spelled '==' and a lone '=' is rejected")
    func singleEqualsRejected() throws {
        let error = try captureFormulaError { try FormulaEngine.parse("1 = 1") }
        #expect(error.code == .unexpectedCharacter("="))
        #expect(try evaluate("1 == 1") == .boolean(true))
    }

    @Test("An empty formula is an empty-source error, not a crash")
    func emptySource() throws {
        let error = try captureFormulaError { try FormulaEngine.parse("   ") }
        #expect(error.code == .emptySource)
    }

    @Test("Input after a complete expression is reported, not ignored")
    func trailingInput() throws {
        let error = try captureFormulaError { try FormulaEngine.parse("1 2") }
        guard case .trailingInput(let text) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(text == "2")
    }

    @Test("Columns can be referenced by name or by stable id")
    func columnReferences() throws {
        let id = makeColumnID(7)
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: id, name: "Waste factor", type: .number(.count))
        ])
        let row = FormulaRow(columns: [id: .number(.count(try dec("1.1")))])
        #expect(try evaluate("[Waste factor]", row: row, catalog: catalog).decimal() == (try dec("1.1")))
        let byID = "[col:\(id.rawValue.uuidString)]"
        #expect(try evaluate(byID, row: row, catalog: catalog).decimal() == (try dec("1.1")))
    }

    @Test("Variable and function names are case-insensitive")
    func caseInsensitiveNames() throws {
        let row = try sampleRow()
        #expect(try evaluate("area", row: row).decimal() == (try dec("12.5")))
        #expect(try evaluate("abs(0 - AREA)", row: row).decimal() == (try dec("12.5")))
    }

    @Test("Whitespace never changes the parse")
    func whitespaceIsIrrelevant() throws {
        let dense = try FormulaEngine.parse("1+2*3")
        let sparse = try FormulaEngine.parse("  1 +\t2  *   3 ")
        #expect(FormulaEngine.canonicalText(dense) == FormulaEngine.canonicalText(sparse))
    }

    @Test("An unknown function name names itself")
    func unknownFunction() throws {
        let error = try captureFormulaError { try FormulaEngine.parse("FROBNICATE(1)") }
        #expect(error.code == .unknownFunction("FROBNICATE"))
    }

    @Test("Wrong argument counts are caught at parse time")
    func argumentCount() throws {
        let error = try captureFormulaError { try FormulaEngine.parse("IF(true, 1)") }
        guard case .argumentCountMismatch(let function, _, let actual) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(function == "IF")
        #expect(actual == 2)
    }
}

@Suite("Operator precedence and associativity")
struct PrecedenceTests {

    @Test("Multiplication binds tighter than addition")
    func multiplicationFirst() throws {
        #expect(try number("1 + 2 * 3") == 7)
    }

    @Test("Parentheses override precedence")
    func parentheses() throws {
        #expect(try number("(1 + 2) * 3") == 9)
    }

    @Test("Exponentiation is right associative")
    func powerIsRightAssociative() throws {
        #expect(try number("2 ^ 3 ^ 2") == 512)
    }

    @Test("Unary minus binds looser than '^', so -2 ^ 2 is -4")
    func unaryMinusVersusPower() throws {
        #expect(try number("-2 ^ 2") == -4)
        #expect(try number("(-2) ^ 2") == 4)
    }

    @Test("Subtraction is left associative")
    func subtractionIsLeftAssociative() throws {
        #expect(try number("10 - 3 - 2") == 5)
    }

    @Test("'not' binds tighter than 'and'")
    func notBindsTighterThanAnd() throws {
        let value = try evaluate("not false and false")
        #expect(value == .boolean(false))
        #expect(try evaluate("not (false and false)") == .boolean(true))
    }

    @Test("Comparisons bind tighter than 'and'")
    func comparisonsBeforeAnd() throws {
        #expect(try evaluate("1 < 2 and 3 > 4") == .boolean(false))
        #expect(try evaluate("1 < 2 and 4 > 3") == .boolean(true))
    }

    @Test("Comparison chains are not folded into arithmetic")
    func additionBeforeComparison() throws {
        #expect(try evaluate("1 + 1 == 2") == .boolean(true))
    }
}

@Suite("Canonical formatting")
struct FormatterTests {

    @Test(
        "Rendering an AST produces text that re-parses to the same AST",
        arguments: [
            "1 + 2 * 3",
            "(1 + 2) * 3",
            "2 ^ 3 ^ 2",
            "(2 ^ 3) ^ 2",
            "-2 ^ 2",
            "10 - (3 - 2)",
            "not (true and false)",
            "IF(Area > 10, Area * 2, Area)",
            "ROUND(Area * 1.25, 2)",
            "MIN(Length, Perimeter, 3)",
            "CONVERT(Area, m2, ft2)",
            "SUM(Area) / COUNT(Area)"
        ]
    )
    func roundTrip(source: String) throws {
        let first = try FormulaEngine.parse(source)
        let text = FormulaEngine.canonicalText(first)
        let second = try FormulaEngine.parse(text)
        #expect(first == second)
        #expect(FormulaEngine.canonicalText(second) == text)
    }

    @Test("Canonical text normalises spelling and spacing")
    func canonicalSpelling() throws {
        let node = try FormulaEngine.parse("round( area*1.25 ,2)")
        #expect(FormulaEngine.canonicalText(node) == "ROUND(Area * 1.25, 2)")
    }

    @Test("A column id renders back as [col:UUID]")
    func canonicalColumnID() throws {
        let id = makeColumnID(3)
        let node = try FormulaEngine.parse("[col:\(id.rawValue.uuidString)] + 1")
        #expect(FormulaEngine.canonicalText(node) == "[col:\(id.rawValue.uuidString)] + 1")
    }
}
