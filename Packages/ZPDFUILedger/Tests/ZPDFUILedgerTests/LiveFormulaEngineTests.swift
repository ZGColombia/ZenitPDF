import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFQuantityLedger

/// The formula behaviour the ledger relies on, asserted against the engine that ships.
///
/// Until loop iteration 1 (R-123) this package carried a second formula engine of its own —
/// `Sources/ZPDFUILedger/Formula/*`, about 2 200 lines — that no shipping code called: the
/// Column Manager checks a formula through `LedgerColumnManaging.checkFormula`, which the
/// application answers by building a ``LedgerColumnSet`` over ``FormulaEngine``. The
/// duplicate went, and so did the tests that only exercised its own artefacts (its completion
/// engine, its editor model, its preview text, its variadic `SUM`). Every test of formula
/// *behaviour* moved here, onto the live engine, with the same assertion or a stronger one;
/// each names the test it replaces. Where the live engine's words differ from the duplicate's
/// (an error code, a function's arity), the assertion follows the live engine and says so.
@Suite("Ledger formulas on the live engine", .ledgerTierSerialised)
struct LiveFormulaEngineTests {

    // MARK: Fixture

    private static func columnID(_ index: UInt8) -> ColumnID {
        ColumnID(UUID(uuid: (0x7E, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x0F, index)))
    }

    static let wasteFactor = columnID(1)
    static let totalCost = columnID(2)

    /// The ledger's custom columns as the engine sees them: a ratio-typed factor
    /// (ADR-0014) and a money column in SEK.
    static let catalog: FormulaColumnCatalog = {
        do {
            return try FormulaColumnCatalog(columns: [
                FormulaColumnDescriptor(id: wasteFactor, name: "Waste Factor", key: "wasteFactor", type: .number(.ratio)),
                FormulaColumnDescriptor(id: totalCost, name: "Total Cost", key: "totalCost", type: .number(.currency("SEK")))
            ])
        } catch {
            preconditionFailure("the fixture catalog is valid: \(error)")
        }
    }()

    /// The sample project's first row: 12 m, 40 m², 2 pieces, 4 000 SEK, waste 0.05.
    static func row(count: Decimal = 2, wasteFactor waste: FormulaValue? = nil) -> FormulaRow {
        FormulaRow(
            fields: [
                .planLength: DecimalQuantity(value: 12, dimension: .length),
                .netArea: DecimalQuantity(value: 40, dimension: .area),
                .planArea: DecimalQuantity(value: 40, dimension: .area),
                .count: DecimalQuantity(value: count, dimension: .count)
            ],
            columns: [
                Self.wasteFactor: waste ?? .number(DecimalQuantity(value: Decimal(string: "0.05")!, dimension: .ratio)),
                Self.totalCost: .number(DecimalQuantity(value: 4_000, dimension: .currency("SEK")))
            ]
        )
    }

    static func type(_ source: String) throws -> FormulaStaticType {
        try FormulaEngine.compile(source, catalog: catalog).resultType
    }

    static func value(_ source: String, row: FormulaRow = row()) throws -> FormulaValue {
        try FormulaEngine.compile(source, catalog: catalog).evaluate(row: row)
    }

    static func code(_ body: () throws -> Any) -> FormulaEngineErrorCode? {
        do {
            _ = try body()
            return nil
        } catch let error as FormulaEngineError {
            return error.code
        } catch {
            return nil
        }
    }

    static func quantity(_ value: Decimal, _ dimension: QuantityDimension) -> FormulaValue {
        .number(DecimalQuantity(value: value, dimension: dimension))
    }

    // MARK: Parsing (was LedgerFormulaTests)

    @Test("Precedence and associativity follow the grammar (was: precedence)")
    func precedence() throws {
        // Each value is reachable only through the documented parse: 1 + (2 * 3), 2 ^ (3 ^ 2).
        #expect(try Self.value("1 + 2 * 3").quantity?.value == 7)
        #expect(try Self.value("2 ^ 3 ^ 2").quantity?.value == 512)
        #expect(try Self.value("(1 + 2) * 3").quantity?.value == 9)
    }

    @Test("Column tokens resolve, including bracketed custom columns (was: identifierResolution)")
    func identifierResolution() throws {
        let program = try FormulaEngine.compile("Area + [Waste Factor] * Area", catalog: Self.catalog)
        #expect(program.referencedColumns == [Self.wasteFactor])
        #expect(program.referencedFields == [.netArea])
    }

    @Test("Unknown names, unknown functions and broken syntax are typed errors (was: unknownNames)")
    func unknownNames() {
        #expect(Self.code { try Self.type("Nonexistent + 1") } != nil)
        #expect(Self.code { try Self.type("EVAL(1)") } == .unknownFunction("EVAL"))
        #expect(Self.code { try Self.type("1 + ") } != nil)
        #expect(Self.code { try Self.type("(1 + 2") } != nil)
        #expect(Self.code { try Self.type("1 $ 2") } == .unexpectedCharacter("$"))
    }

    // MARK: Dimension analysis (was LedgerFormulaTests)

    @Test("Adding an area to a length is refused, in unit terms (was: cannotAddAreaToLength)")
    func cannotAddAreaToLength() throws {
        do {
            _ = try Self.type("Length + Area")
            Issue.record("Length + Area type-checked")
        } catch let error as FormulaEngineError {
            #expect(error.code == .dimensionMismatch(operation: "add", left: .length, right: .area))
            #expect(error.message.contains("m^2"))
            #expect(error.message.contains("(m)"))
        }
    }

    @Test("A written-out number takes the unit of what it is combined with (was: literalsAdoptTheOtherDimension)")
    func literalsAdoptTheOtherDimension() throws {
        #expect(try Self.type("Area + 5").dimension == .area)
        #expect(try Self.type("5 + Area").dimension == .area)
        #expect(try Self.value("Area + 5") == Self.quantity(45, .area))
    }

    @Test("Adding compatible quantities keeps the dimension (was: addCompatible)")
    func addCompatible() throws {
        #expect(try Self.type("Length + Length").dimension == .length)
    }

    @Test("Multiplication adds length exponents and division subtracts them (was: dimensionAlgebra)")
    func dimensionAlgebra() throws {
        #expect(try Self.type("Length * Length").dimension == .area)
        #expect(try Self.type("Area / Length").dimension == .length)
        #expect(try Self.type("Area * Length").dimension == .volume)
        // Money times money is no quantity; money over money is a plain ratio.
        #expect(Self.code { try Self.type("[Total Cost] * [Total Cost]") } != nil)
        #expect(try Self.type("[Total Cost] / [Total Cost]").dimension == .ratio)
    }

    @Test("A power needs a whole-number literal exponent (was: powerRules)")
    func powerRules() throws {
        #expect(try Self.type("Length ^ 2").dimension == .area)
        #expect(Self.code { try Self.type("Length ^ 1.5") } == .nonIntegerExponent(Decimal(string: "1.5")!))
        // The duplicate refused a dimensioned exponent; the live engine refuses every
        // non-literal exponent, which includes it.
        #expect(Self.code { try Self.type("2 ^ Length") } != nil)
    }

    @Test("Comparisons and logic type-check to a true/false value (was: booleanTyping)")
    func booleanTyping() throws {
        #expect(try Self.type("Area > 10") == .boolean)
        #expect(try Self.type("Area > 10 and Count > 1") == .boolean)
        #expect(try Self.type("not (Area > 10)") == .boolean)
        #expect(Self.code { try Self.type("Area > Length") } != nil)
        guard case .typeMismatch? = Self.code({ try Self.type("Area and Count") }) else {
            Issue.record("a number was accepted as a condition")
            return
        }
    }

    @Test("Several arguments that do not share a dimension are refused (was: sumRejectsMixedUnits)")
    func mixedArgumentsAreRefused() {
        // The duplicate's SUM took several arguments; the live SUM is a group aggregate of one.
        // The live functions that take several arguments refuse the same mixture.
        for source in ["MAX(Length, Area)", "MIN(Length, Area)"] {
            guard case .dimensionMismatch(_, let left, let right)? = Self.code({ try Self.type(source) }) else {
                Issue.record("\(source) type-checked")
                continue
            }
            #expect(left == .length, "\(source)")
            #expect(right == .area, "\(source)")
        }
    }

    @Test("Function arity is enforced (was: arity)")
    func arity() {
        guard case .argumentCountMismatch(let function, _, let actual)? = Self.code({ try Self.type("ABS(1, 2)") }) else {
            Issue.record("ABS took two arguments")
            return
        }
        #expect(function == "ABS")
        #expect(actual == 2)
        guard case .argumentCountMismatch(_, let expected, _)? = Self.code({ try Self.type("IF(Area > 1, 1)") }) else {
            Issue.record("IF took two arguments")
            return
        }
        #expect(expected == 3...3)
    }

    // MARK: Evaluation (was LedgerFormulaTests)

    @Test("Arithmetic evaluates in Decimal against a real row (was: evaluation)")
    func evaluation() throws {
        #expect(try Self.value("Area * 2") == Self.quantity(80, .area))
    }

    @Test("The waste-factor formula evaluates exactly, in the column's currency (was: wasteFactorFormula)")
    func wasteFactorFormula() throws {
        #expect(try Self.value("[Total Cost] * (1 + [Waste Factor])") == Self.quantity(4_200, .currency("SEK")))
    }

    @Test("IF, ROUND, ROUNDUP and COALESCE behave as documented (was: functions)")
    func functions() throws {
        #expect(try Self.value("IF(Area > 10, Area, 0)") == Self.quantity(40, .area))
        #expect(try Self.value("ROUND(Area / 3, 2)").quantity?.value == Decimal(string: "13.33"))
        #expect(try Self.value("ROUNDUP(Area / 3, 0)").quantity?.value == 14)
        let blank = Self.row(wasteFactor: .blank)
        #expect(try Self.value("COALESCE([Waste Factor], 1)", row: blank).quantity?.value == 1)
    }

    @Test("Division by zero is a typed error, not a crash or an infinity (was: divisionByZero)")
    func divisionByZero() {
        #expect(Self.code { try Self.value("Area / 0") } == .divisionByZero)
    }

    // MARK: Ratios (was Fix2U2FormulaTests, ADR-0014)

    @Test("BH-043: ratio x ratio stays a ratio, and a factor scales a count or an area")
    func ratioProductIsRatio() throws {
        #expect(Self.code { try Self.type("Count + [Waste Factor] * 1") } != nil)
        #expect(try Self.type("[Waste Factor] * [Waste Factor]").dimension == .ratio)
        #expect(try Self.type("Count * [Waste Factor]").dimension == .count)
        #expect(try Self.type("Area * [Waste Factor]").dimension == .area)
    }

    @Test("BH-044 / BH-238: MIN and MAX adapt a literal wherever it stands")
    func minMaxAdaptLiterals() throws {
        #expect(try Self.value("MIN(Area, 100)") == Self.quantity(40, .area))
        #expect(try Self.value("MAX(Area, 100)") == Self.quantity(100, .area))
        #expect(try Self.value("MAX(100, Area)") == Self.quantity(100, .area))
        #expect(try Self.value("MAX(2, 3, Area)") == Self.quantity(40, .area))
    }

    @Test("BH-230: a huge literal exponent is refused instead of trapping")
    func hugeExponentIsBounded() throws {
        // The bound is 64, as it was in the duplicate: 64 type-checks, 65 is out of range.
        #expect(throws: Never.self) { _ = try Self.type("2 ^ 64") }
        #expect(Self.code { try Self.type("2 ^ 65") } == .exponentOutOfRange(65))
        // Past 2^53 the literal is still a whole number, so it is out of range, as the
        // duplicate said; it was refused as non-integer until C-03. Either way it never traps.
        #expect(Self.code { try Self.type("Area ^ 5000000000000000000") }
            == .exponentOutOfRange(Decimal(string: "5000000000000000000")!))
    }

    @Test("BH-231: a like/like quotient is a ratio and does not sum into Count")
    func likeQuotientIsRatio() throws {
        #expect(try Self.type("Area / Area").dimension == .ratio)
        #expect(try Self.type("Count / Count").dimension == .ratio)
        #expect(try Self.type("Count / [Waste Factor]").dimension == .count)
        #expect(Self.code { try Self.type("Count + Area / Area") } != nil)
    }

    @Test("BH-232 / BH-233: Area reads the net area and Slope reads the ratio")
    func standardBindingsMatchTheEngine() throws {
        #expect(try FormulaEngine.compile("Area").referencedFields == [.netArea])
        #expect(try FormulaEngine.compile("PlanArea").referencedFields == [.planArea])
        #expect(try FormulaEngine.compile("Slope").referencedFields == [.slopeRatio])
        #expect(try FormulaEngine.compile("Slope").resultType.dimension == .ratio)
    }

    @Test("BH-234: a division by zero on one row is a runtime error, not a refused formula")
    func runtimeErrorIsNotAStaticError() throws {
        let program = try FormulaEngine.compile("[Total Cost] / Count", catalog: Self.catalog)
        #expect(program.resultType.dimension == .currency("SEK"))
        #expect(Self.code { try program.evaluate(row: Self.row(count: 0)) } == .divisionByZero)
        // The Column Manager's check — a column set built over the formula — accepts it too.
        #expect(throws: Never.self) { _ = try LedgerColumnSets.make(formula: "[Total Cost] / Count") }
    }

    @Test("BH-715: a negative literal exponent is a whole number")
    func negativeExponent() throws {
        #expect(try Self.type("Length ^ -1").dimension == QuantityDimension(lengthPower: -1))
    }

    @Test("BH-716: summing true/false tests is refused")
    func sumOfBooleans() {
        #expect(Self.code { try Self.type("SUM(Area > 1)") } != nil)
        #expect(Self.code { try Self.type("(Area > 1) + (Length > 1)") } != nil)
    }

    @Test("BH-719 / BH-720: a blank formula is refused")
    func blankSourceIsRefused() {
        #expect(Self.code { try Self.type("\n") } == .emptySource)
        #expect(throws: (any Error).self) { _ = try LedgerColumnSets.make(formula: "\n") }
    }

    @Test("BH-722 / BH-723: exponents are bounded, and never read from a cell")
    func exponentBounds() {
        // The duplicate bounded a cell-valued exponent at run time; the live engine refuses a
        // non-literal exponent before any row is read, so no cell can drive a long loop.
        #expect(Self.code { try Self.type("[Waste Factor] ^ Slope") } != nil)
        // Int.min as an exponent is refused, not negated into a trap (see BH-230 for the code).
        #expect(Self.code { try Self.type("2 ^ -9223372036854775808") }
            == .exponentOutOfRange(Decimal(string: "-9223372036854775808")!))
        #expect(Self.code { try Self.type("2 ^ -65") } == .exponentOutOfRange(-65))
    }

    @Test("BH-724: a fractional ROUND digit count is an error, not 0 digits")
    func roundDigits() throws {
        // The live engine checks the digit count as it evaluates (the duplicate did it while
        // type-checking); either way the cell is an error, never a value rounded to 0 digits.
        #expect(Self.code { try Self.value("ROUND(Area, 1.5)") } == .invalidRoundingDigits(Decimal(string: "1.5")!))
        #expect(Self.code { try Self.value("ROUND(Area, 99)") } == .invalidRoundingDigits(99))
        #expect(try Self.value("ROUND(Area, 1)") == Self.quantity(40, .area))
    }

    @Test("BH-725 / BH-726: a superscript is never read as a digit, and a bracket must close")
    func lexerEdges() {
        // The duplicate reported the character; the live engine reports the malformed number.
        // Either way "3²" is refused rather than read as 3.
        guard case .malformedNumber? = Self.code({ try Self.type("Area * 3²") }) else {
            Issue.record("3² was accepted")
            return
        }
        #expect(Self.code { try Self.type("[Waste Factor * 2") } == .unterminatedColumnReference)
    }

    // MARK: Counts (was CodeReviewRegressionTests.countsStayCounts, ADR-0014)

    @Test("COUNT() types as a count, so it still adds to the Count column")
    func countsStayCounts() throws {
        let program = try FormulaEngine.compile("COUNT(Area) + Count", catalog: Self.catalog)
        #expect(program.resultType.dimension == .count)
        // U-074: the engine no longer evaluates group aggregates (no product caller ever gave it
        // a group); the program type-checks and refuses evaluation by name. The old assertion
        // here evaluated COUNT over a hand-built group of three rows (COUNT 3 + Count 2 = 5).
        #expect(Self.code { try program.evaluate(row: Self.row()) } == .aggregateNotEvaluable("COUNT"))
    }

    // MARK: The Column Manager's check (was LedgerFormulaTests / Fix2U2FormulaTests)

    @Test("A cycle between formula columns is detected and names both (was: cycleDetection)")
    func cycleDetection() {
        do {
            _ = try LedgerColumnSets.make(formulas: [("First", "[Second] + 1"), ("Second", "[First] * 2")])
            Issue.record("a two-column loop was accepted")
        } catch let error as FormulaEngineError {
            guard case .cycleDetected(let path) = error.code else {
                Issue.record("got \(error.code)")
                return
            }
            #expect(path.contains("First"))
            #expect(path.contains("Second"))
        } catch {
            Issue.record("got \(error)")
        }
    }

    @Test("BH-235: a formula that reads its own column is a cycle")
    func selfReferenceIsACycle() {
        do {
            _ = try LedgerColumnSets.make(formulas: [("Extended Cost", "[Extended Cost] * 2")])
            Issue.record("a self-reference was accepted")
        } catch let error as FormulaEngineError {
            guard case .cycleDetected = error.code else {
                Issue.record("got \(error.code)")
                return
            }
        } catch {
            Issue.record("got \(error)")
        }
    }

    @Test("The grammar is versioned, and a newer grammar is refused (was: grammarVersion)")
    func grammarVersion() {
        #expect(FormulaEngine.grammarVersion == ContractVersion.formula)
        #expect(throws: (any Error).self) {
            _ = try LedgerColumnSets.make(formula: "Length * 2", grammarVersion: ContractVersion.formula + 1)
        }
    }
}

/// Column sets built the way `AppLedgerPresenter.checkFormula` builds one: the formula
/// column added to the ledger's columns, and the set constructed — which is where the ledger
/// core refuses a formula.
enum LedgerColumnSets {

    static func make(formula: String, grammarVersion: Int = ContractVersion.formula) throws -> LedgerColumnSet {
        try make(formulas: [("Checked", formula)], grammarVersion: grammarVersion)
    }

    static func make(
        formulas: [(title: String, source: String)],
        grammarVersion: Int = ContractVersion.formula
    ) throws -> LedgerColumnSet {
        var columns: [LedgerColumnDefinition] = [
            LedgerColumnDefinition(
                id: LiveFormulaEngineTests.totalCost, key: "totalCost", title: "Total Cost", kind: .currency,
                dimension: .currency("SEK"), displayUnit: .currency("SEK"), order: 0
            ),
            LedgerColumnDefinition(
                id: LiveFormulaEngineTests.wasteFactor, key: "wasteFactor", title: "Waste Factor", kind: .number,
                dimension: .ratio, order: 1
            )
        ]
        for (offset, formula) in formulas.enumerated() {
            columns.append(LedgerColumnDefinition(
                id: ColumnID(UUID(uuid: (0x7E, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x1F, UInt8(offset)))),
                key: "formula\(offset)",
                title: formula.title,
                kind: .formula,
                formula: FormulaExpression(source: formula.source, grammarVersion: grammarVersion),
                order: 2 + offset
            ))
        }
        return try LedgerColumnSet(columns: columns)
    }
}
