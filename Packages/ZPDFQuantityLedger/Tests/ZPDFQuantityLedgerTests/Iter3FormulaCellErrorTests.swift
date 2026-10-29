import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// T-057: a formula cell that fails at
/// run time carries the kind of failure and the engine's diagnostic.
@Suite("Iteration 3 — measurement presentation, formula cell errors")
struct Iter3FormulaCellErrorTests {

    private static let divisor = HandBuiltLedger.columnID("divisor")
    private static let dynamic = HandBuiltLedger.columnID("dynamic")
    private static let quotient = HandBuiltLedger.columnID("quotient")
    private static let remainder = HandBuiltLedger.columnID("remainder")
    private static let mixed = HandBuiltLedger.columnID("mixed")
    private static let doubled = HandBuiltLedger.columnID("doubled")

    private static func columns() throws -> LedgerColumnSet {
        try LedgerColumnSet(columns: [
            LedgerColumnDefinition(id: divisor, key: "divisor", title: "Divisor", kind: .number, dimension: .count, order: 0),
            // No declared dimension: the value decides, row by row.
            LedgerColumnDefinition(id: dynamic, key: "dynamic", title: "Any", kind: .number, dimension: nil, order: 1),
            LedgerColumnDefinition(
                id: quotient, key: "quotient", title: "Quotient", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "100 / [Divisor]"), isEditable: false, order: 2
            ),
            LedgerColumnDefinition(
                id: remainder, key: "remainder", title: "Remainder", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "100 % [Divisor]"), isEditable: false, order: 3
            ),
            LedgerColumnDefinition(
                id: mixed, key: "mixed", title: "Mixed", kind: .formula, dimension: nil,
                formula: FormulaExpression(source: "[Any] + [Divisor]"), isEditable: false, order: 4
            ),
            LedgerColumnDefinition(
                id: doubled, key: "doubled", title: "Doubled", kind: .formula, dimension: nil,
                formula: FormulaExpression(source: "[Any] * 2"), isEditable: false, order: 5
            )
        ])
    }

    /// Old output: every one of these cells was `formulaEvaluation` with the engine's
    /// description (message plus "[offset N]") as its detail, so the table read a bare
    /// "Formula error" for all of them.
    @Test("T-057: a formula failure keeps its kind and the engine's words")
    func failureKindsAndDetail() throws {
        let store = try HandBuiltLedger.makeStore(
            rows: [
                // 100 / 0 and 100 % 0; 2 m + 0 count is a unit conflict.
                [Self.divisor: .number(.count(0)), Self.dynamic: .number(.length(2))],
                // Any is blank: `[Any] * 2` cannot use it.
                [Self.divisor: .number(.count(4))]
            ],
            columns: try Self.columns()
        )
        let division = try #require(store.value(at: 0, column: Self.quotient).cellError)
        #expect(division.kind == .divisionByZero, "old output: formulaEvaluation")
        #expect(division.detail.hasPrefix("Division by zero in `"), "\(division.detail)")
        #expect(!division.detail.contains("[offset"), "the source offset means nothing in a cell")

        let modulo = try #require(store.value(at: 0, column: Self.remainder).cellError)
        #expect(modulo.kind == .divisionByZero, "old output: formulaEvaluation")
        #expect(modulo.detail.hasPrefix("Remainder by zero"), "\(modulo.detail)")

        let conflict = try #require(store.value(at: 0, column: Self.mixed).cellError)
        #expect(conflict.kind == .dimensionMismatch, "old output: formulaEvaluation")
        #expect(conflict.detail.contains("length (m)"), "\(conflict.detail)")
        #expect(conflict.detail.contains("dimensionless count (1)"), "\(conflict.detail)")

        // A blank input is "nothing to compute from" (V-058, ADR-0040), still with the
        // engine's words. Old output: formulaEvaluation, which made every total refuse.
        let blank = try #require(store.value(at: 1, column: Self.doubled).cellError)
        #expect(blank.kind == .missingInput)
        #expect(blank.detail.contains("blank"), "\(blank.detail)")

        // The row that divides by 4 is a number: 100 / 4 = 25, 100 % 4 = 0.
        #expect(store.value(at: 1, column: Self.quotient).quantity?.value == 25)
        #expect(store.value(at: 1, column: Self.remainder).quantity?.value == 0)
    }
}
