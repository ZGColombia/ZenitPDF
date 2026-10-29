import Foundation
import os
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// Engine fixes: lexer and parser robustness (BH-156, BH-158, BH-544, BH-546, BH-547).
@Suite("Lexer and parser robustness")
struct SyntaxFixTests {

    // MARK: BH-156

    /// BH-156. `Character.isNumber` admitted superscripts, fractions and other scripts' digits,
    /// and `Decimal(string:)` parses a prefix, so `2 * 10²` evaluated to 20 with no error.
    /// Old output: `.number(20 count)`.
    @Test("Non-ASCII numerals are refused, never read as a prefix")
    func nonASCIINumerals() throws {
        for source in ["2 * 10²", "1٣", "3½", "10１"] {
            let error = try captureFormulaError { try FormulaEngine.parse(source) }
            guard case .malformedNumber = error.code else {
                Issue.record("\(source): got \(error.code)")
                continue
            }
        }
        for source in ["²", "½ + 1", "١"] {
            let error = try captureFormulaError { try FormulaEngine.parse(source) }
            guard case .unexpectedCharacter = error.code else {
                Issue.record("\(source): got \(error.code)")
                continue
            }
        }
        // ASCII still works: 2 x 10 = 20, 0.25 + 1.5 = 1.75.
        #expect(try number("2 * 10") == 20)
        #expect(try number("0.25 + 1.5") == (try dec("1.75")))
    }

    // MARK: BH-158

    private static let limit = FormulaParser.maximumNestingDepth

    private func tooDeep(_ source: String) throws {
        let error = try captureFormulaError { try FormulaEngine.parse(source) }
        #expect(error.code == .nestingTooDeep(limit: Self.limit), "got \(error.code)")
        #expect(error.message.contains("nests more than \(Self.limit) levels"))
    }

    /// BH-158. Parsing recursed once per `(` or prefix `-`, with no limit, and compiling,
    /// rendering and walking recursed once per tree level — so a few thousand of them, or a
    /// `1 + 1 + ...` chain with thousands of terms, overflowed the stack and killed the process.
    /// Old output: a stack-overflow crash (no value, no error). These sources are far past the
    /// point that crashed a 512 KiB cooperative thread.
    @Test("Pathologically deep formulas are refused with a clear error")
    func deepFormulasAreRefused() throws {
        try tooDeep(String(repeating: "(", count: 100_000) + "1" + String(repeating: ")", count: 100_000))
        try tooDeep(String(repeating: "-", count: 100_000) + "1")
        try tooDeep(String(repeating: "not ", count: 50_000) + "true")
        try tooDeep("1" + String(repeating: " + 1", count: 100_000))
        try tooDeep("2" + String(repeating: " ^ 2", count: 100_000))
        try tooDeep(String(repeating: "ABS(", count: 20_000) + "1" + String(repeating: ")", count: 20_000))
        // One past the limit is refused.
        try tooDeep(String(repeating: "(", count: Self.limit + 1) + "1" + String(repeating: ")", count: Self.limit + 1))
        try tooDeep("1" + String(repeating: " + 1", count: Self.limit))
        try tooDeep(String(repeating: "IF(true, ", count: Self.limit) + "1" + String(repeating: ", 0)", count: Self.limit))
        let error = try captureFormulaError {
            try FormulaEngine.parse(String(repeating: "-", count: 5_000) + "1")
        }
        #expect(error.code == .nestingTooDeep(limit: Self.limit))
    }

    /// The limit is safe: a formula exactly at it — for every construct that recurses — parses,
    /// compiles, evaluates, renders, re-parses, hashes and is walked on a thread with the
    /// cooperative pool's 512 KiB stack, in this unoptimised test build.
    ///
    /// Headroom, measured on this build while choosing the limit (probe with the limit lifted,
    /// same 512 KiB thread, all phases): every construct below still passed at 112 levels; the
    /// first failures were nested COALESCE and ROUND at 128. So 64 leaves at least 1.75x in a
    /// debug build, and release frames are several times smaller.
    @Test("A formula at the nesting limit works on a 512 KiB stack")
    func formulaAtTheLimitWorksOnASmallStack() throws {
        let limit = Self.limit
        func nested(_ open: String, _ close: String) -> String {
            String(repeating: open, count: limit - 1) + "1" + String(repeating: close, count: limit - 1)
        }
        // Each source is exactly `limit` levels deep (tree height or parser recursion).
        let cases: [(name: String, source: String, value: Decimal)] = [
            ("chain", "1" + String(repeating: " + 1", count: limit - 1), Decimal(limit)),
            ("parentheses", String(repeating: "(", count: limit) + "1" + String(repeating: ")", count: limit), 1),
            // 63 negations of 1: an odd count, so -1.
            ("negation", String(repeating: "-", count: limit - 1) + "1", -1),
            ("power", String(repeating: "1 ^ ", count: limit - 1) + "1", 1),
            ("ABS", nested("ABS(", ")"), 1),
            ("IF", nested("IF(true, ", ", 0)"), 1),
            ("COALESCE", nested("COALESCE(", ", 0)"), 1),
            ("ROUND", nested("ROUND(", ", 2)"), 1),
            ("MAX", nested("MAX(0, ", ")"), 1),
            ("CONVERT", nested("CONVERT(", ", m, m)"), 1)
        ]
        let sources = cases.map(\.source)
        let outcome = OSAllocatedUnfairLock<[String]?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            var report: [String] = []
            for source in sources {
                do {
                    let program = try FormulaEngine.compile(source)
                    let value = try program.evaluate(row: FormulaRow())
                    // Render, re-parse, compare, hash and walk: every recursive path at depth.
                    let reparsed = try FormulaEngine.parse(program.canonicalText)
                    var hasher = Hasher()
                    program.ast.hash(into: &hasher)
                    _ = hasher.finalize()
                    _ = reparsed == program.ast
                    let shape = reparsed.canonicalText == program.canonicalText ? "renders" : "differs"
                    report.append("\(value.quantity?.value ?? -999) \(shape) \(program.ast.referencedColumnNames.count)")
                } catch {
                    report.append("error: \(error)")
                }
            }
            let finished = report
            outcome.withLock { $0 = finished }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        let report = try #require(outcome.withLock { $0 })
        for (index, entry) in cases.enumerated() {
            #expect(report[index] == "\(entry.value) renders 0", "\(entry.name)")
        }
    }

    // MARK: BH-544

    /// BH-544. The lexer stopped a bracket reference at the first `]`, so a title carrying its
    /// unit — `Cost [SEK]` — could not be referenced at all. Old output: `unexpectedCharacter("]")`.
    @Test("Column titles containing brackets are referenceable and round-trip")
    func bracketsInColumnNames() throws {
        let names = ["Cost [SEK]", "Area [m2]", "a]b", "x[y", "Odd \\] name", "[[nested]] twice"]
        let columns = names.enumerated().map { index, name in
            FormulaColumnDescriptor(id: makeColumnID(UInt8(index + 1)), name: name, type: .dynamicNumber)
        }
        let catalog = try FormulaColumnCatalog(columns: columns)
        for (index, name) in names.enumerated() {
            let reference = "[\(FormulaFormatter.bracketed(name))]"
            let program = try FormulaEngine.compile("\(reference) * 2", catalog: catalog)
            #expect(program.referencedColumns == [makeColumnID(UInt8(index + 1))], "\(name)")
            // The canonical rendering lexes back to the same tree.
            #expect(try FormulaEngine.parse(program.canonicalText) == program.ast, "\(name)")
            // 3 x 2 = 6
            let value = try program.evaluate(row: FormulaRow(columns: [makeColumnID(UInt8(index + 1)): .number(.count(3))]))
            #expect(value == .number(.count(6)))
        }
        // The natural spelling of a balanced title works without any escape.
        let natural = try FormulaEngine.compile("[Cost [SEK]] + 1", catalog: catalog)
        #expect(natural.canonicalText == "[Cost [SEK]] + 1")
        // An unbalanced name renders escaped.
        #expect(FormulaFormatter.bracketed("a]b") == "a\\]b")
        // A reference that never closes is still reported as unterminated.
        let open = try captureFormulaError { try FormulaEngine.parse("[Cost [SEK] + 1") }
        #expect(open.code == .unterminatedColumnReference)
    }

    // MARK: BH-546

    /// BH-546. `FormulaParser(tokens:)` trusted a trailing `endOfInput`; without it the Pratt
    /// loop read past the end of the array. Old output: a fatal index-out-of-range trap.
    @Test("A hand-built token array without endOfInput is parsed, not trapped")
    func tokensWithoutEndOfInput() throws {
        let tokens = [
            FormulaToken(kind: .op(.subtract), span: FormulaSourceSpan(start: 0, end: 1), text: "-"),
            FormulaToken(kind: .number(1), span: FormulaSourceSpan(start: 1, end: 2), text: "1")
        ]
        let node = try FormulaParser(tokens: tokens).parse()
        #expect(FormulaFormatter.render(node) == "-1")
        let dangling = [
            FormulaToken(kind: .identifier("ABS"), span: FormulaSourceSpan(start: 0, end: 3), text: "ABS")
        ]
        // A lone identifier reads as a column name rather than trapping on tokens[index + 1].
        #expect(try FormulaParser(tokens: dangling).parse() == .columnByName("ABS", span: FormulaSourceSpan(start: 0, end: 3)))
        let operatorOnly = [
            FormulaToken(kind: .op(.add), span: FormulaSourceSpan(start: 0, end: 1), text: "+")
        ]
        let error = try captureFormulaError { try FormulaParser(tokens: operatorOnly).parse() }
        #expect(error.code == .unexpectedEndOfInput)
        let empty = try captureFormulaError { try FormulaParser(tokens: []).parse() }
        #expect(empty.code == .emptySource)
    }

    // MARK: BH-547

    /// BH-547. The `col:` / `column:` / `id:` prefixes were tested before the catalog, so a
    /// column titled `ID: Door` was unreferenceable and the error named a spelling the user
    /// never typed. Old output: malformedColumnIdentifier with the message
    /// "`[col:Door]` does not contain a valid column identifier."
    @Test("A title that starts with col:, column: or id: is a name unless a UUID follows")
    func prefixedTitles() throws {
        let door = makeColumnID(1)
        let notes = makeColumnID(2)
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: door, name: "ID: Door", type: .dynamicNumber),
            FormulaColumnDescriptor(id: notes, name: "Column: Notes", type: .dynamicNumber)
        ])
        #expect(try FormulaEngine.compile("[ID: Door] + 1", catalog: catalog).referencedColumns == [door])
        #expect(try FormulaEngine.compile("[column: notes] + 1", catalog: catalog).referencedColumns == [notes])
        // A real id still resolves by id.
        let byID = try FormulaEngine.parse("[col:\(door.rawValue.uuidString)]")
        #expect(byID == .columnByID(door, span: byID.span))
        // A typo is reported in the user's own spelling.
        let typo = try captureFormulaError { try FormulaEngine.compile("[col:5F1C-typo] + 1", catalog: catalog) }
        #expect(typo.code == .unknownColumnName("col:5F1C-typo"))
        #expect(typo.message == "There is no column named `col:5F1C-typo`.")
    }
}
