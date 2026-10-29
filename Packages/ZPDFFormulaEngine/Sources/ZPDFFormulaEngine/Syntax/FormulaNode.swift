import Foundation
import ZPDFContracts

/// The abstract syntax tree of a formula.
///
/// Deterministic by construction: the tree is a value type, every node carries its source span,
/// and nothing in it depends on a clock, a random number or a locale. Two parses of the same text
/// are `==`.
public indirect enum FormulaNode: Hashable, Sendable {
    /// A numeric literal. Dimensionless, and *dimension-flexible*: see ``FormulaStaticType``.
    case number(Decimal, span: FormulaSourceSpan)
    case boolean(Bool, span: FormulaSourceSpan)
    /// A built-in measurement variable such as `Area`.
    case variable(FormulaBuiltinVariable, span: FormulaSourceSpan)
    /// A custom column referenced by name: `[Waste factor]` or a bare `WasteFactor`.
    case columnByName(String, span: FormulaSourceSpan)
    /// A custom column referenced by its stable id: `[col:5F1C...]`.
    case columnByID(ColumnID, span: FormulaSourceSpan)
    /// Prefix `-`, `+` or `not`.
    case unary(FormulaOperator, FormulaNode, span: FormulaSourceSpan)
    case binary(FormulaOperator, FormulaNode, FormulaNode, span: FormulaSourceSpan)
    case call(FormulaEngineFunction, [FormulaNode], span: FormulaSourceSpan)
    /// `CONVERT(x, from, to)`. The units are resolved at parse time, which is why this is its own
    /// node rather than a `call` with two string arguments.
    case convert(FormulaNode, from: AnyDisplayUnit, to: AnyDisplayUnit, span: FormulaSourceSpan)

    public var span: FormulaSourceSpan {
        switch self {
        case .number(_, let span), .boolean(_, let span), .variable(_, let span),
             .columnByName(_, let span), .columnByID(_, let span),
             .unary(_, _, let span), .binary(_, _, _, let span),
             .call(_, _, let span), .convert(_, _, _, let span):
            span
        }
    }

    /// The direct children, in evaluation order.
    public var children: [FormulaNode] {
        switch self {
        case .number, .boolean, .variable, .columnByName, .columnByID:
            []
        case .unary(_, let operand, _):
            [operand]
        case .binary(_, let lhs, let rhs, _):
            [lhs, rhs]
        case .call(_, let arguments, _):
            arguments
        case .convert(let operand, _, _, _):
            [operand]
        }
    }

    /// Depth-first pre-order walk. Deterministic, and the order the compiler uses.
    public func forEachNode(_ body: (FormulaNode) throws -> Void) rethrows {
        try body(self)
        for child in children { try child.forEachNode(body) }
    }

    /// Every column referenced by name anywhere in the tree.
    public var referencedColumnNames: [String] {
        var names: [String] = []
        forEachNode { node in
            if case .columnByName(let name, _) = node { names.append(name) }
        }
        return names
    }

    /// Every column referenced by id anywhere in the tree.
    public var referencedColumnIDs: [ColumnID] {
        var ids: [ColumnID] = []
        forEachNode { node in
            if case .columnByID(let id, _) = node { ids.append(id) }
        }
        return ids
    }

    /// Every measurement field the tree reads.
    public var referencedFields: Set<MeasurementField> {
        var fields: Set<MeasurementField> = []
        forEachNode { node in
            if case .variable(let variable, _) = node, let field = variable.measurementField {
                fields.insert(field)
            }
        }
        return fields
    }

    /// The canonical text of this node. See ``FormulaFormatter``.
    public var canonicalText: String { FormulaFormatter.render(self) }
}
