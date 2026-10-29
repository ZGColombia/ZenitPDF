import Foundation
import ZPDFContracts

/// Renders an AST back to canonical formula text.
///
/// Canonical means: one space around every infix operator, none after a prefix operator except
/// `not`, `, ` between arguments, uppercase function names, `[Name]` for named columns,
/// `[col:UUID]` for id references, and the minimum set of parentheses that reproduces the same
/// tree. `FormulaFormatter.render(parse(render(parse(x)))) == render(parse(x))` for every formula
/// the parser accepts, which is what makes the rendering safe to store, diff and show back.
public enum FormulaFormatter: Sendable {

    /// Binding power of a prefix operator, matching what ``FormulaParser`` uses.
    static func prefixBindingPower(_ symbol: FormulaOperator) -> Int {
        symbol == .not ? 3 : 6
    }

    public static func render(_ node: FormulaNode) -> String {
        render(node, minimumBindingPower: 0)
    }

    /// Recursion goes through this dispatcher and one small function per recursive case, so an
    /// unoptimised build does not put every case's temporaries on the stack once per level.
    private static func render(_ node: FormulaNode, minimumBindingPower: Int) -> String {
        switch node {
        case .unary(let symbol, let operand, _):
            return renderUnary(symbol, operand, minimumBindingPower)
        case .binary(let symbol, let lhs, let rhs, _):
            return renderBinary(symbol, lhs, rhs, minimumBindingPower)
        case .call(let function, let arguments, _):
            return renderCall(function, arguments)
        case .convert(let operand, let from, let to, _):
            return renderConvert(operand, from, to)
        case .number, .boolean, .variable, .columnByName, .columnByID:
            return renderLeaf(node)
        }
    }

    private static func renderLeaf(_ node: FormulaNode) -> String {
        switch node {
        case .number(let value, _):
            return canonicalNumber(value)
        case .boolean(let value, _):
            return value ? "true" : "false"
        case .variable(let variable, _):
            return variable.rawValue
        case .columnByName(let name, _):
            return "[" + bracketed(name) + "]"
        case .columnByID(let id, _):
            return "[col:" + id.rawValue.uuidString + "]"
        case .unary, .binary, .call, .convert:
            return render(node)
        }
    }

    private static func renderUnary(_ symbol: FormulaOperator, _ operand: FormulaNode, _ minimum: Int) -> String {
        let power = prefixBindingPower(symbol)
        let inner = render(operand, minimumBindingPower: power)
        let text = symbol == .not ? "not " + inner : symbol.rawValue + inner
        return power < minimum ? "(" + text + ")" : text
    }

    private static func renderBinary(
        _ symbol: FormulaOperator,
        _ lhs: FormulaNode,
        _ rhs: FormulaNode,
        _ minimum: Int
    ) -> String {
        let power = symbol.infixBindingPower ?? 0
        let leftMinimum = symbol.isRightAssociative ? power + 1 : power
        let rightMinimum = symbol.isRightAssociative ? power : power + 1
        let left = render(lhs, minimumBindingPower: leftMinimum)
        let right = render(rhs, minimumBindingPower: rightMinimum)
        let text = left + " " + symbol.rawValue + " " + right
        return power < minimum ? "(" + text + ")" : text
    }

    private static func renderCall(_ function: FormulaEngineFunction, _ arguments: [FormulaNode]) -> String {
        let rendered = arguments.map { render($0, minimumBindingPower: 0) }
        return function.rawValue + "(" + rendered.joined(separator: ", ") + ")"
    }

    private static func renderConvert(_ operand: FormulaNode, _ from: AnyDisplayUnit, _ to: AnyDisplayUnit) -> String {
        "CONVERT(" + render(operand, minimumBindingPower: 0) + ", "
            + from.formulaToken + ", " + to.formulaToken + ")"
    }

    /// A column name as it goes between the brackets of a reference.
    ///
    /// Balanced brackets (`Cost [SEK]`) nest in the lexer and are written as they are. A name
    /// with an unbalanced bracket has every bracket escaped with a backslash, so the rendering
    /// always lexes back to the same name (BH-544).
    static func bracketed(_ name: String) -> String {
        var depth = 0
        var balanced = true
        var previous: Character?
        for character in name {
            if character == "[" && previous == "\\" || character == "]" && previous == "\\" {
                balanced = false
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth < 0 { balanced = false }
            }
            previous = character
        }
        if balanced && depth == 0 { return name }
        var escaped = ""
        for character in name {
            if character == "[" || character == "]" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// A locale-independent decimal rendering. `Decimal.description` is already invariant, but
    /// this keeps the intent explicit and strips a `-0`.
    static func canonicalNumber(_ value: Decimal) -> String {
        value == 0 ? "0" : "\(value)"
    }
}
