import Foundation
import ZPDFContracts

/// Which formula column depends on which, and in what order they may be evaluated.
///
/// Cycle detection is an iterative depth-first search with an explicit stack, so a pathological
/// ledger cannot blow the Swift stack. The reported path is the *whole* cycle, opened and closed
/// on the same column: `Total -> Subtotal -> Markup -> Total`.
public struct FormulaDependencyGraph: Sendable {

    /// For each formula column, the columns it reads.
    public let dependencies: [ColumnID: Set<ColumnID>]
    /// Formula columns in an order where every dependency comes first.
    public let evaluationOrder: [ColumnID]
    /// The AST of every formula column, parsed exactly once.
    public let parsedFormulas: [ColumnID: FormulaNode]

    /// Builds the graph, resolving every reference against the catalog.
    ///
    /// - Throws: ``FormulaEngineError`` with ``FormulaEngineErrorCode/cycleDetected(path:)``,
    ///   ``FormulaEngineErrorCode/unknownColumnName(_:)`` or
    ///   ``FormulaEngineErrorCode/unknownColumnID(_:)``.
    public static func build(catalog: FormulaColumnCatalog) throws -> FormulaDependencyGraph {
        let compiler = FormulaCompiler(catalog: catalog)
        var dependencies: [ColumnID: Set<ColumnID>] = [:]
        var parsed: [ColumnID: FormulaNode] = [:]
        var ordered: [ColumnID] = []

        for column in catalog.columns {
            guard let formula = column.formula else { continue }
            guard formula.grammarVersion <= FormulaGrammar.version else {
                throw FormulaEngineError(
                    code: .unsupportedGrammarVersion(
                        stored: formula.grammarVersion,
                        supported: FormulaGrammar.version
                    )
                )
            }
            let ast = try compiler.parse(formula.source)
            parsed[column.id] = ast
            ordered.append(column.id)

            var references: Set<ColumnID> = []
            for name in ast.referencedColumnNames {
                guard let referenced = try catalog.resolve(named: name) else {
                    throw FormulaEngineError(code: .unknownColumnName(name))
                }
                references.insert(referenced.id)
            }
            for id in ast.referencedColumnIDs {
                guard catalog.column(id: id) != nil else {
                    throw FormulaEngineError(code: .unknownColumnID(id))
                }
                references.insert(id)
            }
            dependencies[column.id] = references
        }

        let order = try topologicalOrder(
            of: ordered,
            dependencies: dependencies,
            catalog: catalog
        )
        return FormulaDependencyGraph(
            dependencies: dependencies,
            evaluationOrder: order,
            parsedFormulas: parsed
        )
    }

    private enum Mark: UInt8 { case unvisited, inProgress, done }

    private static func topologicalOrder(
        of columns: [ColumnID],
        dependencies: [ColumnID: Set<ColumnID>],
        catalog: FormulaColumnCatalog
    ) throws -> [ColumnID] {
        var marks: [ColumnID: Mark] = [:]
        var order: [ColumnID] = []

        // Sorting each node's edges by the catalog's declared order keeps the output identical
        // across runs; `Set` iteration order is not stable and would leak into the result.
        var rank: [ColumnID: Int] = [:]
        for (index, column) in catalog.columns.enumerated() { rank[column.id] = index }
        func sortedDependencies(_ id: ColumnID) -> [ColumnID] {
            (dependencies[id] ?? []).sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
        }

        for root in columns where marks[root] != .done {
            var stack: [(column: ColumnID, next: Int, edges: [ColumnID])] = [
                (root, 0, sortedDependencies(root))
            ]
            var path: [ColumnID] = [root]
            marks[root] = .inProgress

            while let frame = stack.last {
                if frame.next == frame.edges.count {
                    marks[frame.column] = .done
                    order.append(frame.column)
                    stack.removeLast()
                    path.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let child = frame.edges[frame.next]
                // Columns that are not formula columns are leaves: nothing to descend into.
                guard dependencies[child] != nil else { continue }
                switch marks[child] ?? .unvisited {
                case .done:
                    continue
                case .inProgress:
                    let start = path.firstIndex(of: child) ?? 0
                    let cycle = Array(path[start...]) + [child]
                    throw FormulaEngineError(
                        code: .cycleDetected(path: cycle.map { name(of: $0, in: catalog) })
                    )
                case .unvisited:
                    marks[child] = .inProgress
                    path.append(child)
                    stack.append((child, 0, sortedDependencies(child)))
                }
            }
        }
        return order
    }

    private static func name(of id: ColumnID, in catalog: FormulaColumnCatalog) -> String {
        catalog.column(id: id)?.name ?? id.description
    }
}
