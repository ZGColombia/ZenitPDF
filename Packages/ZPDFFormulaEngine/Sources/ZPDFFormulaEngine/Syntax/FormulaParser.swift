import Foundation
import ZPDFContracts

/// A Pratt (top-down operator precedence) parser for the frozen formula grammar.
///
/// Binding powers come from ``FormulaOperator/infixBindingPower``, so precedence lives in the
/// contract and not in this file:
///
/// ```text
/// or                                   1
/// and                                  2
/// == != < <= > >=                      3
/// + -                                  4
/// * / %                                5
/// ^  (right associative)               6
/// ```
///
/// Prefix `-` and `+` bind at 6, which makes `-2 ^ 2` parse as `-(2 ^ 2)` — the mathematical
/// reading, not the spreadsheet one. Prefix `not` binds at 3, so `not a == b` is `not (a == b)`
/// and `not a and b` is `(not a) and b`.
///
/// # Nesting limit
///
/// Parsing, compiling, rendering and walking a tree all recurse once per level, and a formula
/// column is compiled on a cooperative-pool thread whose stack is 512 KiB. A corrupt or hostile
/// project whose formula is a few thousand `(` or `-` characters — or `1 + 1 + ... + 1` with
/// thousands of terms, which is a tree that deep — used to overflow that stack and kill the
/// process on open (BH-158). The parser now refuses anything nested deeper than
/// ``maximumNestingDepth`` levels with ``FormulaEngineErrorCode/nestingTooDeep(limit:)``.
/// The limit counts both the parser's own recursion (so redundant parentheses count) and the
/// height of the tree it builds; a chain of `n` terms joined by one operator is `n` levels.
///
/// Why 64: a real takeoff formula is a handful of levels deep (`IF(Area > 10, ROUND(Area * 1.07,
/// 2), Area)` is 4). The ceiling comes from the unoptimised build, whose frames are largest:
/// measured on a 512 KiB thread, every recursive construct (chains, parentheses, negation,
/// powers, ABS, IF, COALESCE, ROUND, MAX, CONVERT) still parsed, compiled, evaluated and rendered
/// at 112 levels, and the first failure was at 128. 64 keeps at least 1.75x headroom there and
/// far more in a release build. `SyntaxFixTests.formulaAtTheLimitWorksOnASmallStack` holds that
/// line; a longer sum belongs in more than one formula column.
public struct FormulaParser: Sendable {

    /// The deepest nesting ``parse()`` accepts. See the type documentation.
    public static let maximumNestingDepth = 64

    private let tokens: [FormulaToken]

    /// Parses a token array built by a caller rather than by ``FormulaLexer``.
    ///
    /// A trailing ``FormulaTokenKind/endOfInput`` is appended when it is missing, so an array
    /// that omits it is a parse error rather than an out-of-range trap (BH-546).
    public init(tokens: [FormulaToken]) {
        if let last = tokens.last, case .endOfInput = last.kind {
            self.tokens = tokens
        } else {
            let end = tokens.last?.span.end ?? 0
            self.tokens = tokens + [
                FormulaToken(kind: .endOfInput, span: FormulaSourceSpan(start: end, end: end), text: "")
            ]
        }
    }

    public init(source: String) throws {
        self.tokens = try FormulaLexer(source).tokenize()
    }

    /// Parses one complete expression and requires the input to end there.
    public func parse() throws -> FormulaNode {
        guard tokens.count > 1 else {
            throw FormulaEngineError(code: .emptySource)
        }
        var index = 0
        let node = try parseExpression(&index, minimumBindingPower: 0, depth: 0).node
        let trailing = tokens[index]
        guard case .endOfInput = trailing.kind else {
            throw FormulaEngineError(
                code: .trailingInput(trailing.text),
                span: trailing.span
            )
        }
        return node
    }

    // MARK: - Pratt loop

    /// A parsed sub-tree and its height (a leaf is 1).
    private typealias Parsed = (node: FormulaNode, height: Int)

    private func checkDepth(_ depth: Int, at index: Int) throws {
        guard depth <= FormulaParser.maximumNestingDepth else {
            let token = tokens[Swift.min(index, tokens.count - 1)]
            throw FormulaEngineError(
                code: .nestingTooDeep(limit: FormulaParser.maximumNestingDepth),
                span: token.span
            )
        }
    }

    private func parseExpression(
        _ index: inout Int,
        minimumBindingPower: Int,
        depth: Int
    ) throws -> Parsed {
        try checkDepth(depth, at: index)
        var left = try parsePrefix(&index, depth: depth)
        while true {
            let token = tokens[index]
            guard case .op(let symbol) = token.kind,
                  let power = symbol.infixBindingPower,
                  power >= minimumBindingPower
            else { break }
            index += 1
            let nextMinimum = symbol.isRightAssociative ? power : power + 1
            let right = try parseExpression(&index, minimumBindingPower: nextMinimum, depth: depth + 1)
            // A left-associative chain builds its depth in this loop, not by recursion.
            left = try joined(symbol, left, right, at: index)
        }
        return left
    }

    private func joined(_ symbol: FormulaOperator, _ left: Parsed, _ right: Parsed, at index: Int) throws -> Parsed {
        let height = 1 + Swift.max(left.height, right.height)
        try checkDepth(height, at: index)
        return (.binary(symbol, left.node, right.node, span: left.node.span.merged(with: right.node.span)), height)
    }

    private func prefixed(_ symbol: FormulaOperator, start: FormulaSourceSpan, _ operand: Parsed, at index: Int) throws -> Parsed {
        if symbol == .add { return operand }
        let height = operand.height + 1
        try checkDepth(height, at: index)
        return (.unary(symbol, operand.node, span: start.merged(with: operand.node.span)), height)
    }

    /// Only the cases that recurse live here; leaves and refusals are parsed out of line so
    /// their temporaries are not on the stack once per nesting level (see ``maximumNestingDepth``).
    private func parsePrefix(_ index: inout Int, depth: Int) throws -> Parsed {
        switch tokens[index].kind {
        case .identifier:
            if case .leftParenthesis = tokens[index + 1].kind {
                return try parseCall(&index, depth: depth)
            }
            return try parseLeaf(&index)

        case .leftParenthesis:
            index += 1
            let inner = try parseExpression(&index, minimumBindingPower: 0, depth: depth + 1)
            try expect(&index, .rightParenthesis, in: "a parenthesised expression")
            return inner

        case .op(let symbol) where symbol == .subtract || symbol == .add || symbol == .not:
            let start = tokens[index].span
            index += 1
            let power = FormulaFormatter.prefixBindingPower(symbol)
            let operand = try parseExpression(&index, minimumBindingPower: power, depth: depth + 1)
            return try prefixed(symbol, start: start, operand, at: index)

        default:
            return try parseLeaf(&index)
        }
    }

    private func parseLeaf(_ index: inout Int) throws -> Parsed {
        let token = tokens[index]
        switch token.kind {
        case .endOfInput:
            throw FormulaEngineError(code: .unexpectedEndOfInput, span: token.span)

        case .number(let value):
            index += 1
            return (.number(value, span: token.span), 1)

        case .boolean(let value):
            index += 1
            return (.boolean(value, span: token.span), 1)

        case .string:
            throw FormulaEngineError(
                code: .unexpectedToken(token.text),
                span: token.span,
                message: "Quoted text is only allowed as a unit name inside CONVERT."
            )

        case .bracketReference(let inner):
            index += 1
            return (try bracketNode(inner, span: token.span), 1)

        case .identifier(let name):
            index += 1
            if let variable = FormulaBuiltinVariable.named(name) {
                return (.variable(variable, span: token.span), 1)
            }
            return (.columnByName(name, span: token.span), 1)

        case .op, .rightParenthesis, .comma, .leftParenthesis:
            throw FormulaEngineError(code: .unexpectedToken(token.text), span: token.span)
        }
    }

    // MARK: - Pieces

    private func bracketNode(_ inner: String, span: FormulaSourceSpan) throws -> FormulaNode {
        guard !inner.isEmpty else {
            throw FormulaEngineError(
                code: .unknownColumnName(""),
                span: span,
                message: "An empty column reference `[]` names nothing."
            )
        }
        // `[col:<uuid>]` (and the `column:` / `id:` spellings) is an id reference only when
        // what follows really is a UUID. Otherwise the whole text is a column *name*: a title
        // such as `ID: Door` or `Column: Notes` stays referenceable, and a typo is reported as
        // "no column named `col:5F1C-typo`" in the user's own spelling (BH-547).
        let lowercased = inner.lowercased()
        for prefix in ["col:", "column:", "id:"] where lowercased.hasPrefix(prefix) {
            let raw = String(inner.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if let uuid = UUID(uuidString: raw) {
                return .columnByID(ColumnID(uuid), span: span)
            }
        }
        return .columnByName(inner, span: span)
    }

    private func parseCall(_ index: inout Int, depth: Int) throws -> Parsed {
        let nameToken = tokens[index]
        let function = try resolveFunction(nameToken)
        index += 2 // name and '('

        if function == .convert {
            return try parseConvert(&index, nameToken: nameToken, depth: depth)
        }

        var arguments: [Parsed] = []
        if !isRightParenthesis(index) {
            while true {
                arguments.append(try parseExpression(&index, minimumBindingPower: 0, depth: depth + 1))
                guard isComma(index) else { break }
                index += 1
            }
        }
        return try finishCall(function, nameToken: nameToken, arguments: arguments, &index)
    }

    private func resolveFunction(_ nameToken: FormulaToken) throws -> FormulaEngineFunction {
        guard case .identifier(let name) = nameToken.kind else {
            throw FormulaEngineError(code: .unexpectedToken(nameToken.text), span: nameToken.span)
        }
        guard let function = FormulaEngineFunction.named(name) else {
            throw FormulaEngineError(code: .unknownFunction(name), span: nameToken.span)
        }
        return function
    }

    private func isRightParenthesis(_ index: Int) -> Bool {
        if case .rightParenthesis = tokens[index].kind { return true }
        return false
    }

    private func isComma(_ index: Int) -> Bool {
        if case .comma = tokens[index].kind { return true }
        return false
    }

    private func finishCall(
        _ function: FormulaEngineFunction,
        nameToken: FormulaToken,
        arguments parsed: [Parsed],
        _ index: inout Int
    ) throws -> Parsed {
        let height = 1 + (parsed.map(\.height).max() ?? 0)
        try checkDepth(height, at: index)
        let arguments = parsed.map(\.node)
        let closing = tokens[index]
        try expect(&index, .rightParenthesis, in: "the argument list of \(function.rawValue)")
        let span = nameToken.span.merged(with: closing.span)
        guard function.arity.contains(arguments.count) else {
            throw FormulaParser.arityError(function, arguments.count, span)
        }
        return (.call(function, arguments, span: span), height)
    }

    private func parseConvert(_ index: inout Int, nameToken: FormulaToken, depth: Int) throws -> Parsed {
        let parsed = try parseExpression(&index, minimumBindingPower: 0, depth: depth + 1)
        let value = parsed.node
        let height = parsed.height + 1
        try checkDepth(height, at: index)
        try expect(&index, .comma, in: "CONVERT")
        let from = try parseUnitArgument(&index, argumentIndex: 1)
        try expect(&index, .comma, in: "CONVERT")
        let to = try parseUnitArgument(&index, argumentIndex: 2)
        let closing = tokens[index]
        try expect(&index, .rightParenthesis, in: "CONVERT")
        return (
            .convert(
                value,
                from: from,
                to: to,
                span: nameToken.span.merged(with: closing.span)
            ),
            height
        )
    }

    private func parseUnitArgument(
        _ index: inout Int,
        argumentIndex: Int
    ) throws -> AnyDisplayUnit {
        let token = tokens[index]
        let text: String
        switch token.kind {
        case .identifier(let name): text = name
        case .string(let name): text = name
        case .number(let value) where value == 1: text = "1"
        default:
            throw FormulaEngineError(
                code: .expectedUnitLiteral(function: "CONVERT", argumentIndex: argumentIndex),
                span: token.span
            )
        }
        guard let unit = FormulaUnitCatalog.unit(named: text) else {
            throw FormulaEngineError(code: .unknownUnit(text), span: token.span)
        }
        index += 1
        return unit
    }

    private static func arityError(
        _ function: FormulaEngineFunction,
        _ count: Int,
        _ span: FormulaSourceSpan
    ) -> FormulaEngineError {
        FormulaEngineError(
            code: .argumentCountMismatch(function: function.rawValue, expected: function.arity, actual: count),
            span: span
        )
    }

    private func expect(
        _ index: inout Int,
        _ kind: FormulaTokenKind,
        in context: String
    ) throws {
        guard tokens[index].kind == kind else {
            throw unexpected(tokens[index], in: context)
        }
        index += 1
    }

    private func unexpected(_ token: FormulaToken, in context: String) -> FormulaEngineError {
        if case .endOfInput = token.kind {
            return FormulaEngineError(
                code: .unexpectedEndOfInput,
                span: token.span,
                message: "\(context) is missing its closing token."
            )
        }
        return FormulaEngineError(
            code: .unexpectedToken(token.text),
            span: token.span,
            message: "Unexpected `\(token.text)` in \(context)."
        )
    }
}
