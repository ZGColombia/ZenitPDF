import Foundation
import ZPDFContracts

/// The façade of the formula engine (spec 15.4).
///
/// ```swift
/// let catalog = try FormulaColumnCatalog(ledgerColumns: columns)
/// let ledger = try FormulaCompiler(catalog: catalog).compileLedger()
/// let filled = try ledger.evaluateCells(of: row) { column, outcome in /* store the cell */ }
/// ```
///
/// # Guarantees
///
/// - **No JavaScript, no eval, no host bridge.** The grammar is a frozen enum and this parser.
/// - **Dimension safe.** Adding length to area is refused at compile time when both dimensions are
///   known and at evaluation time when one only becomes known per row. Either way the message
///   names both dimensions and the offending sub-expression.
/// - **Decimal.** Every arithmetic step is `Decimal`. No `Double` enters or leaves the evaluator.
/// - **No NaN, no infinity.** Division by zero, a negative square root and a zero-base negative
///   power are typed errors.
/// - **Deterministic.** No `Date()`, no `UUID()`, no locale, no dictionary-order dependence.
/// - **Pure and `Sendable`.** A ``FormulaProgram`` can be shared across tasks; evaluation touches
///   nothing but its argument.
public enum FormulaEngine: Sendable {

    /// The grammar version this build implements.
    public static var grammarVersion: Int { FormulaGrammar.version }

    /// Parses source into an AST without resolving column names.
    public static func parse(_ source: String) throws -> FormulaNode {
        try FormulaCompiler().parse(source)
    }

    /// Renders an AST back to canonical text.
    public static func canonicalText(_ node: FormulaNode) -> String {
        FormulaFormatter.render(node)
    }

    /// Compiles one formula against a column catalog.
    public static func compile(
        _ source: String,
        catalog: FormulaColumnCatalog = .empty
    ) throws -> FormulaProgram {
        try FormulaCompiler(catalog: catalog).compile(source)
    }

    /// Compiles every formula column of a ledger, detecting cycles.
    public static func compileLedger(
        catalog: FormulaColumnCatalog
    ) throws -> CompiledFormulaLedger {
        try FormulaCompiler(catalog: catalog).compileLedger()
    }
}
