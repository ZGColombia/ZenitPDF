import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// Ledger evaluation through the engine's one per-row loop (BH-152, IM-190, R-139).
///
/// R-139 removed the whole-group evaluators (`evaluate(rows:)`, `evaluateConcurrently`, the
/// stage cut and the IM-003 aggregate cache) together with the tests that pinned them: nothing
/// shipping called them, the ledger refuses aggregate formulas, and the store runs
/// ``CompiledFormulaLedger/evaluateCells(of:source:record:)`` per row.
@Suite("Ledger evaluation")
struct LedgerEvaluationTests {

    // MARK: Fixtures

    private func formulaColumn(
        _ index: UInt8,
        _ name: String,
        _ source: String,
        type: FormulaStaticType = .dynamicNumber
    ) -> FormulaColumnDescriptor {
        FormulaColumnDescriptor(
            id: makeColumnID(index),
            name: name,
            type: type,
            formula: FormulaExpression(source: source)
        )
    }

    // MARK: BH-152

    /// BH-152. A formula column whose source is the literal `0.1` stored its flexible literal
    /// type as the inferred type, so `[Waste]` downstream adopted any dimension. Old output:
    /// `Area + [Waste]` compiled and evaluated to 12.5 + 0.1 = 12.6 m^2.
    @Test("A literal-only formula column is not dimension-flexible downstream")
    func literalColumnIsNotFlexible() throws {
        let refused = try FormulaColumnCatalog(columns: [
            formulaColumn(1, "Waste", "0.1"),
            formulaColumn(2, "Bad", "Area + [Waste]")
        ])
        let error = try captureFormulaError { try FormulaEngine.compileLedger(catalog: refused) }
        #expect(error.code == .dimensionMismatch(operation: "add", left: .area, right: .count))

        // Scaling by it is still fine: 12.5 m^2 x 0.1 = 1.25 m^2.
        let scaled = try FormulaEngine.compileLedger(catalog: FormulaColumnCatalog(columns: [
            formulaColumn(1, "Waste", "0.1"),
            formulaColumn(2, "Offcut", "Area * [Waste]")
        ]))
        let row = try scaled.filledRow(sampleRow(area: "12.5"))
        #expect(row.columns[makeColumnID(2)] == .number(.area(try dec("1.25"))))
        #expect(scaled.programs[makeColumnID(1)]?.resultType == .literalNumber)
    }

    // MARK: R-139 — the one per-row loop

    /// A failing cell is reported, reads as blank for the formulas after it, and does not stop
    /// the row: `Share = Area / Perimeter` divides by 0 m, so `Share` fails; `Doubled = [Share]
    /// * 2` then reads a blank and fails with `blankValue`; `Cost = Area * 10` on 12.5 m^2 is
    /// still 125 m^2.
    @Test("A failed cell reads as blank downstream and the rest of the row still fills")
    func failedCellReadsBlank() throws {
        let ledger = try FormulaEngine.compileLedger(catalog: FormulaColumnCatalog(columns: [
            formulaColumn(1, "Share", "Area / Perimeter"),
            formulaColumn(2, "Doubled", "[Share] * 2"),
            formulaColumn(3, "Cost", "Area * 10")
        ]))
        var outcomes: [ColumnID: Result<FormulaValue, FormulaEngineError>] = [:]
        let filled = try ledger.evaluateCells(
            of: try sampleRow(area: "12.5", perimeter: "0"),
            record: { outcomes[$0] = $1 }
        )
        #expect(outcomes.count == 3)
        guard case .failure(let share) = outcomes[makeColumnID(1)] else {
            Issue.record("Share should fail, got \(String(describing: outcomes[makeColumnID(1)]))")
            return
        }
        #expect(share.code == .divisionByZero)
        guard case .failure(let doubled) = outcomes[makeColumnID(2)] else {
            Issue.record("Doubled should fail on a blank Share")
            return
        }
        guard case .blankValue = doubled.code else {
            Issue.record("got \(doubled.code)")
            return
        }
        #expect(filled.columns[makeColumnID(1)] == .blank)
        #expect(filled.columns[makeColumnID(3)] == .number(.area(125)))
        #expect(throws: FormulaEngineError.self) { try ledger.filledRow(try sampleRow(perimeter: "0")) }
    }

    /// A reused cell is not evaluated and not reported, and its dependents read the reused
    /// value: `Top` is kept at 7 m^2, so `Left = [Top] + 1` is 8 m^2 (not 2 x 10 + 1 = 21).
    @Test("A reused cell feeds its dependents without being evaluated")
    func reusedCellFeedsDependents() throws {
        let ledger = try FormulaEngine.compileLedger(catalog: FormulaColumnCatalog(columns: [
            formulaColumn(1, "Top", "Area * 2"),
            formulaColumn(2, "Left", "[Top] + 1")
        ]))
        var reported: [ColumnID] = []
        let filled = try ledger.evaluateCells(
            of: try sampleRow(area: "10"),
            source: { $0 == makeColumnID(1) ? .reuse(.number(.area(7))) : .evaluate },
            record: { id, _ in reported.append(id) }
        )
        #expect(reported == [makeColumnID(2)])
        #expect(filled.columns[makeColumnID(1)] == .number(.area(7)))
        #expect(filled.columns[makeColumnID(2)] == .number(.area(8)))
    }

    // MARK: IM-190

    @Test("Ledger programs are compiled from the dependency graph's own parse")
    func programsUseTheGraphsAST() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            formulaColumn(1, "Top", "Area  *   2"),
            formulaColumn(2, "Left", "[Top] + 1"),
            formulaColumn(3, "Share", "[Left] / SUM(Area)")
        ])
        let graph = try FormulaDependencyGraph.build(catalog: catalog)
        let ledger = try FormulaEngine.compileLedger(catalog: catalog)
        #expect(ledger.evaluationOrder == graph.evaluationOrder)
        for id in graph.evaluationOrder {
            let program = try #require(ledger.programs[id])
            #expect(program.ast == graph.parsedFormulas[id])
            // Same canonical text and type as compiling the source on its own.
            let alone = try FormulaCompiler(catalog: catalog).compile(program.source)
            #expect(program.canonicalText == alone.canonicalText)
        }
        #expect(ledger.programs[makeColumnID(1)]?.canonicalText == "Area * 2")
        #expect(ledger.programs[makeColumnID(3)]?.resultType == .number(.ratio))
    }
}
