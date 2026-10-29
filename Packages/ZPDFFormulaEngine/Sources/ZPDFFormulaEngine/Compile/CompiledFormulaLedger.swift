import Foundation
import ZPDFContracts

/// Every formula column of one ledger, compiled once, in dependency order.
///
/// This is the object a 100 000-row table holds: parsing happens when the column set changes, not
/// when a row is drawn. ``evaluateCells(of:source:record:)`` fills a row's formula cells in an
/// order where each formula's inputs are already present, and it is the only such loop: the
/// ledger store calls it once per row (R-139 removed a second, whole-group loop with its own
/// stage cache and task group that nothing shipping called).
public struct CompiledFormulaLedger: Sendable {
    public let catalog: FormulaColumnCatalog
    public let programs: [ColumnID: FormulaProgram]
    /// Formula columns ordered so that every dependency is evaluated first.
    public let evaluationOrder: [ColumnID]
    public let dependencies: [ColumnID: Set<ColumnID>]

    init(
        catalog: FormulaColumnCatalog,
        programs: [ColumnID: FormulaProgram],
        evaluationOrder: [ColumnID],
        dependencies: [ColumnID: Set<ColumnID>]
    ) {
        self.catalog = catalog
        self.programs = programs
        self.evaluationOrder = evaluationOrder
        self.dependencies = dependencies
    }

    /// Where one formula cell's value comes from in ``evaluateCells(of:source:record:)``.
    public enum CellSource: Sendable {
        /// Evaluate the column's program.
        case evaluate
        /// Do not evaluate; dependents read this value (a cell kept from an earlier pass).
        case reuse(FormulaValue)
    }

    /// Fills every formula cell of one row in dependency order and returns the completed row.
    ///
    /// A cell that fails with a ``FormulaEngineError`` is reported to `record` and reads as
    /// blank for every formula after it, so one bad cell does not fail its row. A column whose
    /// `source` is ``CellSource/reuse(_:)`` is not evaluated and not reported. An aggregate
    /// formula would fail its cell with ``FormulaEngineErrorCode/aggregateNotEvaluable(_:)``; the
    /// ledger refuses aggregate formulas before they get here.
    ///
    /// - Throws: only an error that is not a ``FormulaEngineError``, unchanged.
    @discardableResult
    public func evaluateCells(
        of row: FormulaRow,
        source: (ColumnID) -> CellSource = { _ in .evaluate },
        record: (ColumnID, Result<FormulaValue, FormulaEngineError>) -> Void = { _, _ in }
    ) throws -> FormulaRow {
        var result = row
        for id in evaluationOrder {
            guard let program = programs[id] else { continue }
            if case .reuse(let value) = source(id) {
                result.columns[id] = value
                continue
            }
            do {
                let value = try program.evaluate(row: result)
                result.columns[id] = value
                record(id, .success(value))
            } catch let error as FormulaEngineError {
                result.columns[id] = .blank
                record(id, .failure(error))
            }
        }
        return result
    }
}

/// How far a chunked, concurrent formula pass over a ledger's rows has got (the ledger store
/// reports it while it builds).
public struct FormulaEvaluationProgress: Hashable, Sendable {
    /// Row evaluations finished so far.
    public let completed: Int
    /// Row evaluations in the whole call.
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    /// `completed / total`, or 1 for an empty call.
    public var fraction: Double {
        total == 0 ? 1 : Double(completed) / Double(total)
    }
}

extension FormulaCompiler {

    /// Parses and compiles every formula column in the catalog.
    ///
    /// Compilation runs in dependency order, so a formula column that reads another formula column
    /// sees the *inferred* result type of its dependency rather than the declared one. That is what
    /// lets `[Cost] = [Area] * [Rate]` be known to be money even when the ledger only declared
    /// `Cost` as a formula column. The inferred type is read as a *column* value: it is never
    /// dimension-flexible, even when the dependency's formula is a bare literal (BH-152), because
    /// a dimensionless value that comes from a column never adopts a dimension.
    ///
    /// Each program is compiled from the tree the dependency graph parsed, so the edges and the
    /// program come from one parse (IM-190).
    ///
    /// - Throws: ``FormulaEngineError`` for a cycle, an unknown reference, or any parse, type or
    ///   dimension failure in any column.
    public func compileLedger() throws -> CompiledFormulaLedger {
        let graph = try FormulaDependencyGraph.build(catalog: catalog)
        var programs: [ColumnID: FormulaProgram] = [:]
        var inferred: [ColumnID: FormulaStaticType] = [:]
        for id in graph.evaluationOrder {
            guard let descriptor = catalog.column(id: id), let formula = descriptor.formula else {
                continue
            }
            let program: FormulaProgram
            if let ast = graph.parsedFormulas[id] {
                program = try compile(ast: ast, source: formula.source, typeOverrides: inferred)
            } else {
                program = try compile(formula.source, typeOverrides: inferred)
            }
            programs[id] = program
            inferred[id] = program.resultType.readThroughColumn
        }
        return CompiledFormulaLedger(
            catalog: catalog,
            programs: programs,
            evaluationOrder: graph.evaluationOrder,
            dependencies: graph.dependencies
        )
    }
}
