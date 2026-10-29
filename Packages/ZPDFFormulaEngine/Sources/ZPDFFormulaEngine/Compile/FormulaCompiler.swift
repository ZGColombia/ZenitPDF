import Foundation
import ZPDFContracts

/// Compiles formula source into a ``FormulaProgram``.
///
/// Compilation is: lex -> Pratt parse -> resolve names against the column catalog -> static type
/// and dimension analysis -> build a tree of `@Sendable` closures. Everything that *can* be
/// decided without a row is decided here, exactly once. What cannot — a column that declared no
/// dimension — becomes a runtime check inside the closure, and the closure carries the
/// sub-expression text so the message reads the same either way.
public struct FormulaCompiler: Sendable {

    public let catalog: FormulaColumnCatalog

    public init(catalog: FormulaColumnCatalog = .empty) {
        self.catalog = catalog
    }

    // MARK: - Public entry points

    /// Parses without resolving names. Used by the dependency graph before any column is known
    /// to be compilable.
    public func parse(_ source: String) throws -> FormulaNode {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FormulaEngineError(code: .emptySource)
        }
        return try FormulaParser(source: source).parse()
    }

    public func compile(_ source: String) throws -> FormulaProgram {
        try compile(source, typeOverrides: [:])
    }

    /// Compiles a stored ``FormulaExpression``, honouring its grammar version stamp.
    public func compile(_ expression: FormulaExpression) throws -> FormulaProgram {
        guard expression.grammarVersion <= FormulaGrammar.version else {
            throw FormulaEngineError(
                code: .unsupportedGrammarVersion(
                    stored: expression.grammarVersion,
                    supported: FormulaGrammar.version
                )
            )
        }
        return try compile(expression.source)
    }

    func compile(
        _ source: String,
        typeOverrides: [ColumnID: FormulaStaticType]
    ) throws -> FormulaProgram {
        try compile(ast: try parse(source), source: source, typeOverrides: typeOverrides)
    }

    /// Compiles an AST that has already been parsed from `source` — the ledger hands in the tree
    /// its dependency graph parsed, so the edges and the program come from one parse (IM-190).
    func compile(
        ast: FormulaNode,
        source: String,
        typeOverrides: [ColumnID: FormulaStaticType]
    ) throws -> FormulaProgram {
        var environment = Environment(typeOverrides: typeOverrides)
        let compiled = try compile(ast, &environment)
        return FormulaProgram(
            source: source,
            ast: ast,
            resultType: compiled.type,
            referencedColumns: environment.referencedColumns,
            usesAggregates: environment.usedAggregate,
            body: compiled.eval
        )
    }

    // MARK: - Internals

    /// A value plus whether *this* value came from literals only.
    typealias MarkedValue = (value: FormulaValue, literal: Bool)
    typealias MarkedEval = @Sendable (FormulaRow) throws -> MarkedValue

    struct CompiledExpression {
        let type: FormulaStaticType
        let eval: @Sendable (FormulaRow) throws -> FormulaValue
        /// Set only on a `dynamicNumber` expression some of whose runtime paths yield a
        /// literal-only value — `COALESCE([Extra], 0)` on a row where `Extra` is blank. The
        /// static type cannot say "flexible on some rows", so the evaluator reports it per value
        /// and the enclosing additive operation lets such a value adopt its partner's dimension
        /// at run time, exactly as a literal does at compile time (BH-153).
        let markedEval: MarkedEval?

        init(
            type: FormulaStaticType,
            eval: @escaping @Sendable (FormulaRow) throws -> FormulaValue
        ) {
            self.type = type
            self.eval = eval
            self.markedEval = nil
        }

        init(type: FormulaStaticType, markedEval: @escaping MarkedEval) {
            self.type = type
            self.eval = { row in try markedEval(row).value }
            self.markedEval = markedEval
        }

        /// Builds from a marked body, keeping the marking only when the static type cannot carry
        /// the flexibility itself (a `dynamicNumber`) and `keepMarking` says a literal path exists.
        init(type: FormulaStaticType, keepMarking: Bool, body: @escaping MarkedEval) {
            if keepMarking, case .dynamicNumber = type {
                self.init(type: type, markedEval: body)
            } else {
                self.init(type: type) { row in try body(row).value }
            }
        }

        /// Whether any runtime path of this expression can yield a literal-only value.
        var mayBeLiteral: Bool { markedEval != nil || type.isFlexible }

        /// The marked evaluator: the real one when there is one, otherwise the static flexibility
        /// attached to every value.
        var marked: MarkedEval {
            if let markedEval { return markedEval }
            let eval = self.eval
            let literal = type.isFlexible
            return { row in (try eval(row), literal) }
        }
    }

    struct Environment {
        var typeOverrides: [ColumnID: FormulaStaticType]
        var aggregateDepth = 0
        var referencedColumns: Set<ColumnID> = []
        var usedAggregate = false
    }

    /// Compiles one node.
    ///
    /// # Stack discipline
    ///
    /// Compilation recurses once per tree level, on a thread that may have only 512 KiB of
    /// stack, and an unoptimised build gives every function a frame big enough for *all* of its
    /// locals and temporaries at once. So the functions on the recursive path — this one,
    /// ``compileUnary``, ``compileBinary`` — only compile their children and then hand over to a
    /// separate function that builds the result; the big frames are never on the stack while a
    /// child is being compiled. `SyntaxFixTests.formulaAtTheLimitWorksOnASmallStack` holds that at
    /// ``FormulaParser/maximumNestingDepth``.
    func compile(_ node: FormulaNode, _ environment: inout Environment) throws -> CompiledExpression {
        switch node {
        case .unary(let symbol, let operand, _):
            return try compileUnary(symbol, operand, node, &environment)
        case .binary(let symbol, let lhs, let rhs, _):
            return try compileBinary(symbol, lhs, rhs, node, &environment)
        case .call(let function, let arguments, _):
            return try compileCall(function, arguments, node, &environment)
        case .convert(let operand, let from, let to, _):
            return try compileConvert(operand, from: from, to: to, node, &environment)
        case .number, .boolean, .variable, .columnByName, .columnByID:
            return try compileLeaf(node, &environment)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func compileLeaf(_ node: FormulaNode, _ environment: inout Environment) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText

        switch node {
        case .number(let value, _):
            let quantity = DecimalQuantity(value: value, dimension: .count)
            return CompiledExpression(type: .literalNumber) { _ in .number(quantity) }

        case .boolean(let value, _):
            return CompiledExpression(type: .boolean) { _ in .boolean(value) }

        case .variable(let variable, _):
            if variable == .unitCost {
                return CompiledExpression(type: .dynamicNumber) { row in
                    row.unitCost.map(FormulaValue.number) ?? .blank
                }
            }
            guard let field = variable.measurementField else {
                throw FormulaEngineError(
                    code: .unknownVariable(variable.rawValue),
                    span: span,
                    subexpression: text
                )
            }
            return CompiledExpression(type: .number(field.dimension)) { row in
                row.value(for: field)
            }

        case .columnByName(let name, _):
            guard let descriptor = try catalog.resolve(named: name, span: span, subexpression: text) else {
                throw FormulaEngineError(
                    code: .unknownColumnName(name),
                    span: span,
                    subexpression: text
                )
            }
            return try columnExpression(descriptor, node, &environment)

        case .columnByID(let id, _):
            guard let descriptor = catalog.column(id: id) else {
                throw FormulaEngineError(
                    code: .unknownColumnID(id),
                    span: span,
                    subexpression: text
                )
            }
            return try columnExpression(descriptor, node, &environment)

        case .unary, .binary, .call, .convert:
            throw FormulaEngineError(code: .unexpectedToken(text), span: span, subexpression: text)
        }
    }

    private func columnExpression(
        _ descriptor: FormulaColumnDescriptor,
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        // A text, date or choice cell has no numeric reading; the old path typed it as a number
        // and read every filled cell as blank (BH-157).
        if let kind = descriptor.unreadableKind {
            throw FormulaEngineError(
                code: .typeMismatch(
                    expected: "a number or a true/false value",
                    actual: "the \(kind.rawValue) column `[\(descriptor.name)]`"
                ),
                span: node.span,
                subexpression: node.canonicalText
            )
        }
        environment.referencedColumns.insert(descriptor.id)
        let id = descriptor.id
        let type = environment.typeOverrides[id] ?? descriptor.type
        return CompiledExpression(type: type) { row in row.value(for: id) }
    }

    // MARK: - Unary

    private func compileUnary(
        _ symbol: FormulaOperator,
        _ operandNode: FormulaNode,
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        try combineUnary(symbol, try compile(operandNode, &environment), operandNode, node)
    }

    private func combineUnary(
        _ symbol: FormulaOperator,
        _ operand: CompiledExpression,
        _ operandNode: FormulaNode,
        _ node: FormulaNode
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText

        if symbol == .not {
            guard case .boolean = operand.type else {
                throw FormulaTypeRules.typeError(
                    expected: "a true/false value",
                    actual: operand.type,
                    node: node
                )
            }
            let inner = operand.eval
            return CompiledExpression(type: .boolean) { row in
                .boolean(!(try FormulaRuntimeChecks.requireBoolean(inner(row), operandNode, in: text, span)))
            }
        }

        guard operand.type.isNumeric else {
            throw FormulaTypeRules.typeError(expected: "a number", actual: operand.type, node: node)
        }
        let inner = operand.marked
        return CompiledExpression(type: operand.type, keepMarking: operand.markedEval != nil) { row in
            let (value, literal) = try inner(row)
            let quantity = try FormulaRuntimeChecks.requireNumber(value, operandNode, in: text, span)
            return (.number(quantity.negated), literal)
        }
    }

    // MARK: - Binary

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func compileBinary(
        _ symbol: FormulaOperator,
        _ lhsNode: FormulaNode,
        _ rhsNode: FormulaNode,
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        // `^` needs its exponent before the right side is compiled as a value.
        if symbol == .power {
            return try compilePower(lhsNode, rhsNode, node, &environment)
        }
        let left = try compile(lhsNode, &environment)
        let right = try compile(rhsNode, &environment)
        return try combineBinary(symbol, left, right, lhsNode, rhsNode, node)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func combineBinary(
        _ symbol: FormulaOperator,
        _ left: CompiledExpression,
        _ right: CompiledExpression,
        _ lhsNode: FormulaNode,
        _ rhsNode: FormulaNode,
        _ node: FormulaNode
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        let leftEval = left.eval
        let rightEval = right.eval

        switch symbol {
        case .and, .or:
            guard case .boolean = left.type else {
                throw FormulaTypeRules.typeError(
                    expected: "a true/false value", actual: left.type, node: lhsNode
                )
            }
            guard case .boolean = right.type else {
                throw FormulaTypeRules.typeError(
                    expected: "a true/false value", actual: right.type, node: rhsNode
                )
            }
            let isAnd = symbol == .and
            return CompiledExpression(type: .boolean) { row in
                let first = try FormulaRuntimeChecks.requireBoolean(leftEval(row), lhsNode, in: text, span)
                if isAnd && !first { return .boolean(false) }
                if !isAnd && first { return .boolean(true) }
                return .boolean(try FormulaRuntimeChecks.requireBoolean(rightEval(row), rhsNode, in: text, span))
            }

        case .add, .subtract:
            let operation = symbol == .add ? "add" : "subtract"
            let (type, coercion) = try FormulaTypeRules.additive(
                left.type, right.type, operation: operation, node: node
            )
            let isAdd = symbol == .add
            if left.markedEval != nil || right.markedEval != nil {
                let leftMarked = left.marked
                let rightMarked = right.marked
                return CompiledExpression(type: type, keepMarking: true) { row in
                    let (va, la) = try leftMarked(row)
                    let (vb, lb) = try rightMarked(row)
                    let a = try FormulaRuntimeChecks.requireNumber(va, lhsNode, in: text, span)
                    let b = try FormulaRuntimeChecks.requireNumber(vb, rhsNode, in: text, span)
                    let (x, y) = FormulaRuntimeChecks.alignLiterals(a, la, b, lb)
                    do {
                        return (.number(isAdd ? try x.adding(y) : try x.subtracting(y)), la && lb)
                    } catch {
                        throw FormulaRuntimeChecks.wrap(error, operation: operation, text, span)
                    }
                }
            }
            return CompiledExpression(type: type) { row in
                let a = try FormulaRuntimeChecks.requireNumber(leftEval(row), lhsNode, in: text, span)
                let b = try FormulaRuntimeChecks.requireNumber(rightEval(row), rhsNode, in: text, span)
                let (x, y) = FormulaRuntimeChecks.align(a, b, coercion)
                do {
                    return .number(isAdd ? try x.adding(y) : try x.subtracting(y))
                } catch {
                    throw FormulaRuntimeChecks.wrap(error, operation: operation, text, span)
                }
            }

        case .multiply:
            let type = try FormulaTypeRules.multiplicative(
                left.type, right.type, isDivision: false, node: node
            )
            let staticDimension = type.dimension
            if staticDimension == nil {
                return dynamicProduct(left, right, lhsNode, rhsNode, type: type, isDivision: false, text: text, span: span)
            }
            return CompiledExpression(type: type) { row in
                let a = try FormulaRuntimeChecks.requireNumber(leftEval(row), lhsNode, in: text, span)
                let b = try FormulaRuntimeChecks.requireNumber(rightEval(row), rhsNode, in: text, span)
                do {
                    return .number(FormulaRuntimeChecks.retagged(try a.multiplied(by: b), to: staticDimension))
                } catch {
                    throw FormulaRuntimeChecks.wrap(error, operation: "multiply", text, span)
                }
            }

        case .divide:
            let type = try FormulaTypeRules.multiplicative(
                left.type, right.type, isDivision: true, node: node
            )
            let staticDimension = type.dimension
            if staticDimension == nil {
                return dynamicProduct(left, right, lhsNode, rhsNode, type: type, isDivision: true, text: text, span: span)
            }
            return CompiledExpression(type: type) { row in
                let a = try FormulaRuntimeChecks.requireNumber(leftEval(row), lhsNode, in: text, span)
                let b = try FormulaRuntimeChecks.requireNumber(rightEval(row), rhsNode, in: text, span)
                guard b.value != 0 else {
                    throw FormulaEngineError(code: .divisionByZero, span: span, subexpression: text)
                }
                do {
                    return .number(FormulaRuntimeChecks.retagged(try a.divided(by: b), to: staticDimension))
                } catch {
                    throw FormulaRuntimeChecks.wrap(error, operation: "divide", text, span)
                }
            }

        case .modulo:
            let (type, coercion) = try FormulaTypeRules.additive(
                left.type, right.type, operation: "take the remainder of", node: node
            )
            let runtimeLiterals = left.markedEval != nil || right.markedEval != nil
            let leftMarked = left.marked
            let rightMarked = right.marked
            return CompiledExpression(type: type, keepMarking: runtimeLiterals) { row in
                let (va, la) = try leftMarked(row)
                let (vb, lb) = try rightMarked(row)
                let a = try FormulaRuntimeChecks.requireNumber(va, lhsNode, in: text, span)
                let b = try FormulaRuntimeChecks.requireNumber(vb, rhsNode, in: text, span)
                let (x, y) = runtimeLiterals
                    ? FormulaRuntimeChecks.alignLiterals(a, la, b, lb)
                    : FormulaRuntimeChecks.align(a, b, coercion)
                do {
                    try x.dimension.requireAdditive(with: y.dimension)
                } catch {
                    throw FormulaRuntimeChecks.wrap(
                        error, operation: "take the remainder of", text, span
                    )
                }
                let value = try FormulaRuntimeChecks.remainder(x.value, y.value, text, span)
                return (.number(DecimalQuantity(value: value, dimension: x.dimension)), la && lb)
            }

        case .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            return try compileComparison(
                symbol, left, right, lhsNode, rhsNode, node
            )

        case .not, .power:
            throw FormulaEngineError(
                code: .unexpectedToken(symbol.rawValue),
                span: span,
                subexpression: text
            )
        }
    }

    private func compileComparison(
        _ symbol: FormulaOperator,
        _ left: CompiledExpression,
        _ right: CompiledExpression,
        _ lhsNode: FormulaNode,
        _ rhsNode: FormulaNode,
        _ node: FormulaNode
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        let leftEval = left.eval
        let rightEval = right.eval

        if case .boolean = left.type, case .boolean = right.type {
            guard symbol == .equal || symbol == .notEqual else {
                throw FormulaTypeRules.typeError(
                    expected: "a number", actual: left.type, node: node
                )
            }
            let wantEqual = symbol == .equal
            return CompiledExpression(type: .boolean) { row in
                let a = try FormulaRuntimeChecks.requireBoolean(leftEval(row), lhsNode, in: text, span)
                let b = try FormulaRuntimeChecks.requireBoolean(rightEval(row), rhsNode, in: text, span)
                return .boolean((a == b) == wantEqual)
            }
        }

        let (_, coercion) = try FormulaTypeRules.additive(
            left.type, right.type, operation: "compare", node: node
        )
        let runtimeLiterals = left.markedEval != nil || right.markedEval != nil
        let leftMarked = left.marked
        let rightMarked = right.marked
        return CompiledExpression(type: .boolean) { row in
            let (va, la) = try leftMarked(row)
            let (vb, lb) = try rightMarked(row)
            let a = try FormulaRuntimeChecks.requireNumber(va, lhsNode, in: text, span)
            let b = try FormulaRuntimeChecks.requireNumber(vb, rhsNode, in: text, span)
            let (x, y) = runtimeLiterals
                ? FormulaRuntimeChecks.alignLiterals(a, la, b, lb)
                : FormulaRuntimeChecks.align(a, b, coercion)
            do {
                try x.dimension.requireAdditive(with: y.dimension)
            } catch {
                throw FormulaRuntimeChecks.wrap(error, operation: "compare", text, span)
            }
            let result: Bool
            switch symbol {
            case .equal: result = x.value == y.value
            case .notEqual: result = x.value != y.value
            case .lessThan: result = x.value < y.value
            case .lessThanOrEqual: result = x.value <= y.value
            case .greaterThan: result = x.value > y.value
            default: result = x.value >= y.value
            }
            return .boolean(result)
        }
    }

    /// `a * b` or `a / b` whose dimension is only known per row.
    ///
    /// ADR-0014 makes a bare literal transparent to the count/ratio tag: `Slope * 100` is a
    /// ratio. The static rule applies that when both dimensions are known; here the operand that
    /// is not a literal is only known per row, so the tag is carried over at run time instead
    /// (BH-542: `[Factor] * 100` on a ratio-valued `Factor` came out a count). Two literals make
    /// a plain count, as in the static rule.
    private func dynamicProduct(
        _ left: CompiledExpression,
        _ right: CompiledExpression,
        _ lhsNode: FormulaNode,
        _ rhsNode: FormulaNode,
        type: FormulaStaticType,
        isDivision: Bool,
        text: String,
        span: FormulaSourceSpan
    ) -> CompiledExpression {
        let leftMarked = left.marked
        let rightMarked = right.marked
        let operation = isDivision ? "divide" : "multiply"
        let keepMarking = left.markedEval != nil || right.markedEval != nil
        return CompiledExpression(type: type, keepMarking: keepMarking) { row in
            let (va, la) = try leftMarked(row)
            let (vb, lb) = try rightMarked(row)
            let a = try FormulaRuntimeChecks.requireNumber(va, lhsNode, in: text, span)
            let b = try FormulaRuntimeChecks.requireNumber(vb, rhsNode, in: text, span)
            if isDivision, b.value == 0 {
                throw FormulaEngineError(code: .divisionByZero, span: span, subexpression: text)
            }
            do {
                let raw = isDivision ? try a.divided(by: b) : try a.multiplied(by: b)
                return (.number(FormulaRuntimeChecks.literalTransparent(raw, a, la, b, lb)), la && lb)
            } catch {
                throw FormulaRuntimeChecks.wrap(error, operation: operation, text, span)
            }
        }
    }

    private func compilePower(
        _ baseNode: FormulaNode,
        _ exponentNode: FormulaNode,
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        let base = try compile(baseNode, &environment)
        let exponent = try staticExponent(exponentNode, node)
        let type = try FormulaTypeRules.power(base.type, exponent: exponent, node: node)
        // A power of a runtime literal is a literal (BH-153, T-060): without the marking
        // `Area + COALESCE([Extra], 0) ^ 2` refused every row whose Extra was blank.
        let baseMarked = base.marked
        let staticDimension = type.dimension
        return CompiledExpression(type: type, keepMarking: base.markedEval != nil) { row in
            let (baseValue, literal) = try baseMarked(row)
            let quantity = try FormulaRuntimeChecks.requireNumber(baseValue, baseNode, in: text, span)
            let value = try DecimalMath.power(
                quantity.value, exponent, span: span, subexpression: text
            )
            let dimension = try staticDimension ?? FormulaTypeRules.powerDimension(
                quantity.dimension, exponent, node: node
            )
            return (.number(DecimalQuantity(value: value, dimension: dimension)), literal)
        }
    }

    /// Exponents must be whole numbers known at compile time, which is what lets the dimension of
    /// `x ^ n` be a fact about the formula rather than about a row.
    ///
    /// "Known at compile time" is a little wider than "is a literal": `2 ^ 3 ^ 2` is
    /// right-associative, so the exponent of the outer power is the expression `3 ^ 2`. Any
    /// sub-tree built only from numeric literals is folded here.
    private func staticExponent(_ node: FormulaNode, _ parent: FormulaNode) throws -> Int {
        guard let value = FormulaCompiler.foldLiteral(node) else {
            throw FormulaEngineError(
                code: .typeMismatch(expected: "a whole-number exponent", actual: node.canonicalText),
                span: node.span,
                subexpression: parent.canonicalText
            )
        }
        guard DecimalMath.isInteger(value) else {
            throw FormulaEngineError(
                code: .nonIntegerExponent(value),
                span: node.span,
                subexpression: parent.canonicalText
            )
        }
        // A whole number too large to hold as an `Int` (past 2^53) is still a whole number: it is
        // out of range, not fractional. It used to be refused as `nonIntegerExponent`, whose
        // message told the user a whole number "is not" one (C-03).
        guard let exponent = DecimalMath.integer(value) else {
            throw FormulaEngineError(
                code: .exponentOutOfRange(value),
                span: node.span,
                subexpression: parent.canonicalText
            )
        }
        return exponent
    }

    /// Constant-folds a sub-tree made only of numeric literals.
    ///
    /// Returns nil for anything that reads a row, and for the two cases that would need an error
    /// rather than a value (division by zero, an exponent this fold cannot itself evaluate). The
    /// caller turns nil into a typed error, so no failure escapes as a NaN.
    static func foldLiteral(_ node: FormulaNode) -> Decimal? {
        switch node {
        case .number(let value, _):
            return value
        case .unary(let symbol, let operand, _):
            guard let value = foldLiteral(operand) else { return nil }
            switch symbol {
            case .subtract: return -value
            case .add: return value
            default: return nil
            }
        case .binary(let symbol, let lhs, let rhs, _):
            guard let left = foldLiteral(lhs), let right = foldLiteral(rhs) else { return nil }
            switch symbol {
            case .add: return left + right
            case .subtract: return left - right
            case .multiply: return left * right
            case .divide: return right == 0 ? nil : left / right
            case .power:
                guard let exponent = DecimalMath.integer(right),
                      let value = try? DecimalMath.power(left, exponent)
                else { return nil }
                return value
            default: return nil
            }
        default:
            return nil
        }
    }
}
