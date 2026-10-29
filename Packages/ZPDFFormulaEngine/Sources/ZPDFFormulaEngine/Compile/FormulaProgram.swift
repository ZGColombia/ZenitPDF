import Foundation
import ZPDFContracts

/// A parsed, type-checked, dimension-checked formula with its evaluation closure already built.
///
/// Compiling once and evaluating many times is the whole point: a 100 000-row ledger parses each
/// formula exactly once and then calls ``evaluate(row:)`` per row. The stored closure is
/// `@Sendable` and captures only value types, so the same program can be shared across tasks.
public struct FormulaProgram: Sendable {
    /// The source the program was compiled from.
    public let source: String
    public let ast: FormulaNode
    /// The AST rendered back to canonical text (see ``FormulaFormatter``).
    public let canonicalText: String
    public let resultType: FormulaStaticType
    public let referencedColumns: Set<ColumnID>
    public let referencedFields: Set<MeasurementField>
    /// True when the formula uses `SUM`, `AVG` or `COUNT`. Such a program type-checks, so a
    /// caller can refuse it by name, but evaluating it throws
    /// ``FormulaEngineErrorCode/aggregateNotEvaluable(_:)`` (U-074).
    public let usesAggregates: Bool

    let body: @Sendable (FormulaRow) throws -> FormulaValue

    init(
        source: String,
        ast: FormulaNode,
        resultType: FormulaStaticType,
        referencedColumns: Set<ColumnID>,
        usesAggregates: Bool,
        body: @escaping @Sendable (FormulaRow) throws -> FormulaValue
    ) {
        self.source = source
        self.ast = ast
        self.canonicalText = FormulaFormatter.render(ast)
        self.resultType = resultType
        self.referencedColumns = referencedColumns
        self.referencedFields = ast.referencedFields
        self.usesAggregates = usesAggregates
        self.body = body
    }

    /// Evaluates the formula against one row, the only argument a compiled formula takes.
    public func evaluate(row: FormulaRow) throws -> FormulaValue {
        try body(row)
    }
}
