import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

@Suite("Group aggregates are detected, type-checked and refused at evaluation — U-074")
struct AggregateTests {

    private let row = FormulaRow(fields: [.netArea: .area(2)])

    /// Old behaviour: the program looped over a caller-supplied `FormulaGroup` — `SUM(Area)` over
    /// rows of 1.5, 2.5 and 6 m² gave 10 m², `AVG(Area)` over 2, 4, 6 gave 4, and `AVG` over no
    /// rows threw `.emptyAggregate`. No product caller ever supplied a group (the ledger and the
    /// assembly evaluator refuse aggregate formulas first), so that second summing path is gone
    /// and evaluation is refused by name.
    @Test("SUM, AVG and COUNT refuse to evaluate, naming the function", arguments: [
        ("SUM(Area)", "SUM"), ("SUM(Area * 2)", "SUM"), ("AVG(Area)", "AVG"),
        ("COUNT(Area)", "COUNT"), ("Area / SUM(Area)", "SUM"), ("COUNT(Area) + Count", "COUNT")
    ])
    func refusedAtEvaluation(source: String, function: String) throws {
        let error = try captureFormulaError { try evaluate(source, row: row) }
        #expect(error.code == .aggregateNotEvaluable(function))
        #expect(error.message.hasPrefix("\(function) ranges over a group of rows"))
    }

    @Test("Aggregates keep their static types, so a caller can reason about them before refusing")
    func staticTypesKept() throws {
        #expect(try FormulaEngine.compile("SUM(Area)").resultType == .number(.area))
        #expect(try FormulaEngine.compile("AVG(Length)").resultType == .number(.length))
        #expect(try FormulaEngine.compile("COUNT(Area)").resultType.dimension == .count)
        // A share is a factor, not a count of things (ADR-0014).
        #expect(try FormulaEngine.compile("Area / SUM(Area)").resultType == .number(.ratio))
    }

    @Test("SUM and AVG still refuse a true/false argument at compile time")
    func numericArgumentChecked() throws {
        for source in ["SUM(1 < 2)", "AVG(Area > 1)"] {
            let error = try captureFormulaError { try FormulaEngine.compile(source) }
            guard case .typeMismatch = error.code else {
                Issue.record("\(source): got \(error.code)")
                continue
            }
        }
        // COUNT counts values of any kind, so a condition is a valid argument.
        #expect(try FormulaEngine.compile("COUNT(1 < 2)").usesAggregates)
    }

    @Test("Nested aggregates are refused")
    func nestedAggregates() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("SUM(SUM(Area))") }
        guard case .nestedAggregate = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("A program says whether it uses an aggregate")
    func aggregateFlag() throws {
        #expect(try FormulaEngine.compile("SUM(Area)").usesAggregates)
        #expect(try !FormulaEngine.compile("Area * 2").usesAggregates)
    }

    @Test("An aggregate in a ledger formula column fails its cell, not the row")
    func ledgerCellRefusal() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(
                id: makeColumnID(41), name: "Share", type: .dynamicNumber,
                formula: FormulaExpression(source: "Area / SUM(Area)")
            ),
            FormulaColumnDescriptor(
                id: makeColumnID(42), name: "Twice", type: .dynamicNumber,
                formula: FormulaExpression(source: "Area * 2")
            )
        ])
        let ledger = try FormulaEngine.compileLedger(catalog: catalog)
        var failures: [ColumnID: FormulaEngineErrorCode] = [:]
        let filled = try ledger.evaluateCells(of: row, record: { id, outcome in
            if case .failure(let error) = outcome { failures[id] = error.code }
        })
        #expect(failures == [makeColumnID(41): .aggregateNotEvaluable("SUM")])
        // Hand-derived: 2 m² * 2 = 4 m².
        #expect(filled.columns[makeColumnID(42)] == .number(.area(4)))
    }
}

@Suite("Cycle detection and ledger compilation")
struct LedgerTests {

    private func formulaColumn(
        _ index: UInt8,
        _ name: String,
        _ source: String
    ) -> FormulaColumnDescriptor {
        FormulaColumnDescriptor(
            id: makeColumnID(index),
            name: name,
            type: .dynamicNumber,
            formula: FormulaExpression(source: source)
        )
    }

    @Test("A column that references itself is a one-step cycle")
    func selfCycle() throws {
        let catalog = try FormulaColumnCatalog(columns: [formulaColumn(1, "Total", "[Total] + 1")])
        let error = try captureFormulaError { try FormulaEngine.compileLedger(catalog: catalog) }
        #expect(error.code == .cycleDetected(path: ["Total", "Total"]))
    }

    @Test("A two-column cycle reports both columns and closes the loop")
    func twoColumnCycle() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            formulaColumn(1, "A", "[B] + 1"),
            formulaColumn(2, "B", "[A] * 2")
        ])
        let error = try captureFormulaError { try FormulaEngine.compileLedger(catalog: catalog) }
        #expect(error.code == .cycleDetected(path: ["A", "B", "A"]))
    }

    @Test("A three-column cycle reports the full path")
    func threeColumnCycle() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            formulaColumn(1, "Total", "[Subtotal] + 1"),
            formulaColumn(2, "Subtotal", "[Markup] * 2"),
            formulaColumn(3, "Markup", "[Total] / 4")
        ])
        let error = try captureFormulaError { try FormulaEngine.compileLedger(catalog: catalog) }
        #expect(error.code == .cycleDetected(path: ["Total", "Subtotal", "Markup", "Total"]))
        #expect(error.message.contains("Total -> Subtotal -> Markup -> Total"))
    }

    @Test("A diamond of dependencies is not a cycle")
    func diamondIsAcyclic() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            formulaColumn(1, "Top", "Area * 2"),
            formulaColumn(2, "Left", "[Top] + 1"),
            formulaColumn(3, "Right", "[Top] * 3"),
            formulaColumn(4, "Bottom", "[Left] + [Right]")
        ])
        let ledger = try FormulaEngine.compileLedger(catalog: catalog)
        let order = ledger.evaluationOrder.map { catalog.column(id: $0)?.name ?? "?" }
        let top = try #require(order.firstIndex(of: "Top"))
        let left = try #require(order.firstIndex(of: "Left"))
        let bottom = try #require(order.firstIndex(of: "Bottom"))
        #expect(top < left)
        #expect(left < bottom)
        #expect(order.count == 4)
    }

    @Test("The evaluation order is deterministic across repeated builds")
    func orderIsDeterministic() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            formulaColumn(1, "Top", "Area * 2"),
            formulaColumn(2, "Left", "[Top] + 1"),
            formulaColumn(3, "Right", "[Top] * 3"),
            formulaColumn(4, "Bottom", "[Left] + [Right]")
        ])
        let first = try FormulaEngine.compileLedger(catalog: catalog).evaluationOrder
        for _ in 0..<8 {
            #expect(try FormulaEngine.compileLedger(catalog: catalog).evaluationOrder == first)
        }
    }

    @Test("A ledger fills dependent formula columns in one pass")
    func ledgerEvaluation() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(
                id: makeColumnID(1),
                name: "Net area",
                type: .number(.area),
                formula: FormulaExpression(source: "Area * 1.1")
            ),
            FormulaColumnDescriptor(
                id: makeColumnID(2),
                name: "Cost",
                type: .dynamicNumber,
                formula: FormulaExpression(source: "[Net area] * 450")
            )
        ])
        let ledger = try FormulaEngine.compileLedger(catalog: catalog)
        let filled = try ledger.filledRow(try sampleRow(area: "10"))
        #expect(filled.columns[makeColumnID(1)]?.quantity?.value == 11)
        #expect(filled.columns[makeColumnID(2)]?.quantity?.value == 4950)
    }

    @Test("A dependent formula column inherits the inferred dimension of its input")
    func inferredTypesFlowDownstream() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(
                id: makeColumnID(1),
                name: "Sides",
                type: .dynamicNumber,
                formula: FormulaExpression(source: "Length * 2")
            ),
            FormulaColumnDescriptor(
                id: makeColumnID(2),
                name: "Face",
                type: .dynamicNumber,
                formula: FormulaExpression(source: "[Sides] * Height")
            )
        ])
        let ledger = try FormulaEngine.compileLedger(catalog: catalog)
        #expect(ledger.programs[makeColumnID(1)]?.resultType == .number(.length))
        #expect(ledger.programs[makeColumnID(2)]?.resultType == .number(.area))
    }

    @Test("A cycle through an id reference is caught the same way")
    func cycleThroughIDReference() throws {
        let a = makeColumnID(1)
        let b = makeColumnID(2)
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(
                id: a, name: "A", type: .dynamicNumber,
                formula: FormulaExpression(source: "[col:\(b.rawValue.uuidString)] + 1")
            ),
            FormulaColumnDescriptor(
                id: b, name: "B", type: .dynamicNumber,
                formula: FormulaExpression(source: "[col:\(a.rawValue.uuidString)] + 1")
            )
        ])
        let error = try captureFormulaError { try FormulaEngine.compileLedger(catalog: catalog) }
        #expect(error.code == .cycleDetected(path: ["A", "B", "A"]))
    }

    /// Before BH-022 the catalog itself threw here, which refused every ledger holding two
    /// same-named columns even when no formula used the name. The refusal now happens where the
    /// ambiguous name is written.
    @Test("A formula naming two same-named columns is refused before it runs")
    func duplicateColumnNames() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: makeColumnID(1), name: "Total", type: .dynamicNumber),
            FormulaColumnDescriptor(id: makeColumnID(2), name: "total", type: .dynamicNumber)
        ])
        let error = try captureFormulaError {
            try FormulaEngine.compile("[Total] + 1", catalog: catalog)
        }
        guard case .duplicateColumnName = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }

    @Test("A formula stored against a newer grammar is refused, not guessed at")
    func futureGrammarVersion() throws {
        let expression = FormulaExpression(source: "1 + 1", grammarVersion: FormulaGrammar.version + 1)
        let error = try captureFormulaError { try FormulaCompiler().compile(expression) }
        guard case .unsupportedGrammarVersion = error.code else {
            Issue.record("got \(error.code)")
            return
        }
    }
}
