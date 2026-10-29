import Foundation
import ZPDFContracts

extension FormulaCompiler {

    /// Dispatch only: see the stack discipline on ``compile(_:_:)``.
    func compileCall(
        _ function: FormulaEngineFunction,
        _ arguments: [FormulaNode],
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        guard function.arity.contains(arguments.count) else {
            throw FormulaCompiler.arityError(function, arguments.count, node)
        }
        if function.isAggregate {
            return try compileAggregate(function, arguments[0], node, &environment)
        }
        switch function {
        case .iff:
            return try compileIf(arguments, node, &environment)
        case .round, .roundUp, .roundDown, .ceiling, .floor:
            return try compileRounding(function, arguments, node, &environment)
        case .abs, .sqrt:
            return try combineSingle(function, try compile(arguments[0], &environment), arguments, node)
        case .pow:
            return try compileBinary(.power, arguments[0], arguments[1], node, &environment)
        case .min, .max:
            return try compileExtremum(function, arguments, node, &environment)
        case .coalesce:
            return try compileCoalesce(arguments, node, &environment)
        case .convert, .sum, .avg, .count:
            // `convert` never reaches here (the parser makes its own node) and the aggregates were
            // handled above. Keeping the case explicit stops a future function from slipping
            // through unimplemented.
            throw FormulaCompiler.unknownFunctionError(function, node)
        }
    }

    // Error construction lives out of line so its temporaries are not part of the recursive
    // frames (see the stack discipline on `compile(_:_:)`).
    static func arityError(
        _ function: FormulaEngineFunction,
        _ count: Int,
        _ node: FormulaNode
    ) -> FormulaEngineError {
        FormulaEngineError(
            code: .argumentCountMismatch(function: function.rawValue, expected: function.arity, actual: count),
            span: node.span,
            subexpression: node.canonicalText
        )
    }

    static func requireNumeric(_ expression: CompiledExpression, _ expected: String, _ node: FormulaNode) throws {
        guard expression.type.isNumeric else {
            throw FormulaTypeRules.typeError(expected: expected, actual: expression.type, node: node)
        }
    }

    static func requireBoolean(_ expression: CompiledExpression, _ expected: String, _ node: FormulaNode) throws {
        guard case .boolean = expression.type else {
            throw FormulaTypeRules.typeError(expected: expected, actual: expression.type, node: node)
        }
    }

    static func incompatibleUnitsError(
        _ from: AnyDisplayUnit,
        _ to: AnyDisplayUnit,
        _ node: FormulaNode
    ) -> FormulaEngineError {
        FormulaEngineError(
            code: .incompatibleUnits(from: from.formulaToken, to: to.formulaToken),
            span: node.span,
            subexpression: node.canonicalText
        )
    }

    static func unknownFunctionError(_ function: FormulaEngineFunction, _ node: FormulaNode) -> FormulaEngineError {
        FormulaEngineError(
            code: .unknownFunction(function.rawValue),
            span: node.span,
            subexpression: node.canonicalText
        )
    }

    /// `ABS(x)` and `SQRT(x)` once `x` is compiled.
    private func combineSingle(
        _ function: FormulaEngineFunction,
        _ operand: CompiledExpression,
        _ arguments: [FormulaNode],
        _ node: FormulaNode
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        let operandNode = arguments[0]
        switch function {
        case .abs:
            guard operand.type.isNumeric else {
                throw FormulaTypeRules.typeError(
                    expected: "a number", actual: operand.type, node: arguments[0]
                )
            }
            let inner = operand.marked
            return CompiledExpression(type: operand.type, keepMarking: operand.markedEval != nil) { row in
                let (value, literal) = try inner(row)
                let quantity = try FormulaRuntimeChecks.requireNumber(value, operandNode, in: text, span)
                return (.number(quantity.magnitude), literal)
            }

        default:
            guard operand.type.isNumeric else {
                throw FormulaTypeRules.typeError(
                    expected: "a number", actual: operand.type, node: arguments[0]
                )
            }
            let staticDimension: QuantityDimension?
            if case .number(let dimension, _) = operand.type {
                staticDimension = try FormulaTypeRules.squareRoot(dimension, node: node)
            } else {
                staticDimension = nil
            }
            // The root of a literal is a literal: `Length + SQRT(4)` works like `Length + 2`,
            // as ABS, ROUND, POW and unary minus already did (BH-540).
            let resultType: FormulaStaticType = staticDimension
                .map { FormulaStaticType.number($0, flexible: operand.type.isFlexible) } ?? .dynamicNumber
            // A dynamic operand that is a literal on some rows keeps saying so per value
            // (BH-153): `Length + SQRT(COALESCE([Extra], 0))` failed on every row whose Extra
            // was blank, while the same formula with ABS worked (T-060).
            let inner = operand.marked
            return CompiledExpression(type: resultType, keepMarking: operand.markedEval != nil) { row in
                let (operandValue, literal) = try inner(row)
                let quantity = try FormulaRuntimeChecks.requireNumber(operandValue, operandNode, in: text, span)
                let dimension = try staticDimension
                    ?? FormulaTypeRules.squareRoot(quantity.dimension, node: node)
                let value = try DecimalMath.squareRoot(
                    quantity.value, span: span, subexpression: text
                )
                return (.number(DecimalQuantity(value: value, dimension: dimension)), literal)
            }
        }
    }

    // MARK: - IF

    private func compileIf(
        _ arguments: [FormulaNode],
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        let condition = try compile(arguments[0], &environment)
        try FormulaCompiler.requireBoolean(condition, "a true/false condition", arguments[0])
        let thenBranch = try compile(arguments[1], &environment)
        let elseBranch = try compile(arguments[2], &environment)
        return try combineIf(condition, thenBranch, elseBranch, node)
    }

    private func combineIf(
        _ condition: CompiledExpression,
        _ thenBranch: CompiledExpression,
        _ elseBranch: CompiledExpression,
        _ node: FormulaNode
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        let conditionNode = node.children[0]
        let conditionEval = condition.eval
        let thenEval = thenBranch.eval
        let elseEval = elseBranch.eval

        if case .boolean = thenBranch.type, case .boolean = elseBranch.type {
            return CompiledExpression(type: .boolean) { row in
                let flag = try FormulaRuntimeChecks.requireBoolean(conditionEval(row), conditionNode, in: text, span)
                return try flag ? thenEval(row) : elseEval(row)
            }
        }

        let (type, _) = try FormulaTypeRules.additive(
            thenBranch.type, elseBranch.type, operation: "choose between", node: node
        )
        let resultDimension = type.dimension
        let resultFlexible = type.isFlexible
        let thenMarked = thenBranch.marked
        let elseMarked = elseBranch.marked
        // With a dynamic sibling the result type is dynamic, and a literal branch would lose its
        // flexibility: `IF(c, 0, [Extra]) + Length` failed on exactly the rows taking the 0
        // (BH-153). The marking carries it to the enclosing operation instead.
        let keepMarking = thenBranch.mayBeLiteral || elseBranch.mayBeLiteral
        return CompiledExpression(type: type, keepMarking: keepMarking) { row in
            let flag = try FormulaRuntimeChecks.requireBoolean(conditionEval(row), conditionNode, in: text, span)
            let (value, literal) = try flag ? thenMarked(row) : elseMarked(row)
            guard let dimension = resultDimension,
                  literal,
                  case .number(let quantity) = value,
                  quantity.dimension.isDimensionless
            else { return (value, literal) }
            return (.number(FormulaRuntimeChecks.adopt(quantity, to: dimension)), resultFlexible)
        }
    }

    // MARK: - Rounding family

    private func compileRounding(
        _ function: FormulaEngineFunction,
        _ arguments: [FormulaNode],
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        let value = try compile(arguments[0], &environment)
        try FormulaCompiler.requireNumeric(value, "a number", arguments[0])
        guard arguments.count == 2 else {
            return combineRounding(function, value, nil, node)
        }
        let digits = try compile(arguments[1], &environment)
        try FormulaCompiler.requireNumeric(digits, "a whole number of digits", arguments[1])
        return combineRounding(function, value, digits, node)
    }

    private func combineRounding(
        _ function: FormulaEngineFunction,
        _ value: CompiledExpression,
        _ digitsExpression: CompiledExpression?,
        _ node: FormulaNode
    ) -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        let valueNode = node.children[0]
        let digitsNode = node.children.count > 1 ? node.children[1] : node
        let digitsEval = digitsExpression?.eval
        // The rounded value of a runtime literal is still a literal (BH-153): building the
        // result without the marking made `Length + ROUND(COALESCE([Extra], 0), 2)` refuse
        // "Cannot add length (m) and dimensionless count (1)" on every row whose Extra was
        // blank (T-060).
        let valueMarked = value.marked
        let kind = function
        return CompiledExpression(type: value.type, keepMarking: value.markedEval != nil) { row in
            let (operandValue, literal) = try valueMarked(row)
            let quantity = try FormulaRuntimeChecks.requireNumber(operandValue, valueNode, in: text, span)
            var digits = 0
            if let digitsEval {
                digits = try FormulaRuntimeChecks.roundingDigits(digitsEval(row), digitsNode, in: text, span)
            }
            let rounded: Decimal
            switch kind {
            case .round: rounded = DecimalMath.roundHalfAwayFromZero(quantity.value, digits: digits)
            case .roundUp: rounded = DecimalMath.roundAwayFromZero(quantity.value, digits: digits)
            case .roundDown: rounded = DecimalMath.truncateTowardZero(quantity.value, digits: digits)
            case .ceiling: rounded = DecimalMath.ceiling(quantity.value, digits: digits)
            default: rounded = DecimalMath.floor(quantity.value, digits: digits)
            }
            return (.number(DecimalQuantity(value: rounded, dimension: quantity.dimension)), literal)
        }
    }

    // MARK: - MIN / MAX

    private func compileExtremum(
        _ function: FormulaEngineFunction,
        _ arguments: [FormulaNode],
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        var compiled: [CompiledExpression] = []
        for argument in arguments {
            let expression = try compile(argument, &environment)
            try FormulaCompiler.requireNumeric(expression, "a number", argument)
            compiled.append(expression)
        }
        return try combineExtremum(function, compiled, node)
    }

    private func combineExtremum(
        _ function: FormulaEngineFunction,
        _ compiled: [CompiledExpression],
        _ node: FormulaNode
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        var type = FormulaStaticType.literalNumber
        for (index, expression) in compiled.enumerated() {
            type = index == 0
                ? expression.type
                : try FormulaTypeRules.additive(type, expression.type, operation: "compare", node: node).type
        }
        let evaluators = compiled.map(\.marked)
        let operandNodes = node.children
        let wantMaximum = function == .max
        let keepMarking = compiled.contains { $0.markedEval != nil }
        return CompiledExpression(type: type, keepMarking: keepMarking) { row in
            var values: [DecimalQuantity] = []
            var flexible: [Bool] = []
            values.reserveCapacity(evaluators.count)
            flexible.reserveCapacity(evaluators.count)
            for (index, evaluator) in evaluators.enumerated() {
                let (value, literal) = try evaluator(row)
                values.append(try FormulaRuntimeChecks.requireNumber(value, operandNodes[index], in: text, span))
                flexible.append(literal)
            }
            let aligned = try FormulaRuntimeChecks.alignList(values, flexible: flexible, text, span)
            var best = aligned[0]
            for candidate in aligned.dropFirst() {
                if wantMaximum ? candidate.value > best.value : candidate.value < best.value {
                    best = candidate
                }
            }
            return (.number(best), !flexible.contains(false))
        }
    }

    // MARK: - COALESCE

    private func compileCoalesce(
        _ arguments: [FormulaNode],
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        var compiled: [CompiledExpression] = []
        var allBoolean = true
        for argument in arguments {
            let expression = try compile(argument, &environment)
            if case .boolean = expression.type {} else { allBoolean = false }
            compiled.append(expression)
        }
        return try combineCoalesce(compiled, allBoolean: allBoolean, arguments, node)
    }

    private func combineCoalesce(
        _ compiled: [CompiledExpression],
        allBoolean: Bool,
        _ arguments: [FormulaNode],
        _ node: FormulaNode
    ) throws -> CompiledExpression {
        var type: FormulaStaticType?
        if !allBoolean {
            for (index, expression) in compiled.enumerated() {
                guard expression.type.isNumeric else {
                    throw FormulaTypeRules.typeError(
                        expected: "a number", actual: expression.type, node: arguments[index]
                    )
                }
                type = index == 0
                    ? expression.type
                    : try FormulaTypeRules.additive(
                        type ?? expression.type,
                        expression.type,
                        operation: "combine",
                        node: node
                    ).type
            }
        }
        let resultType = allBoolean ? FormulaStaticType.boolean : (type ?? .dynamicNumber)
        let resultDimension = resultType.dimension
        let resultFlexible = resultType.isFlexible
        let evaluators = compiled.map(\.marked)
        // `COALESCE([Extra], 0)` with an undeclared `Extra` is dynamic; the literal fallback keeps
        // its flexibility through the marking so `Length + COALESCE([Extra], 0)` works on the
        // rows where `Extra` is blank (BH-153).
        let keepMarking = !allBoolean && compiled.contains(where: \.mayBeLiteral)
        return CompiledExpression(type: resultType, keepMarking: keepMarking) { row in
            for evaluator in evaluators {
                let (value, literal) = try evaluator(row)
                if value.isBlank { continue }
                guard let dimension = resultDimension,
                      literal,
                      case .number(let quantity) = value,
                      quantity.dimension.isDimensionless
                else { return (value, literal) }
                return (.number(FormulaRuntimeChecks.adopt(quantity, to: dimension)), resultFlexible)
            }
            return (.blank, false)
        }
    }

    // MARK: - Aggregates

    private func compileAggregate(
        _ function: FormulaEngineFunction,
        _ argument: FormulaNode,
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        guard environment.aggregateDepth == 0 else {
            throw FormulaEngineError(
                code: .nestedAggregate(text),
                span: span,
                subexpression: text
            )
        }
        environment.aggregateDepth += 1
        environment.usedAggregate = true
        let inner = try compile(argument, &environment)
        environment.aggregateDepth -= 1

        // Detection and type-checking only (U-074). No evaluation supplies a group of rows —
        // the ledger and the assembly evaluator both refuse an aggregate formula before
        // evaluating — so the program refuses too, by name, rather than keeping a second
        // summing path (with its own AVG division) that never ran in the product.
        let functionName = function.rawValue
        let refusal: @Sendable (FormulaRow) throws -> FormulaValue = { _ in
            throw FormulaEngineError(
                code: .aggregateNotEvaluable(functionName),
                span: span,
                subexpression: text
            )
        }
        if function == .count {
            return CompiledExpression(type: .number(.count), eval: refusal)
        }
        guard inner.type.isNumeric else {
            throw FormulaTypeRules.typeError(
                expected: "a number", actual: inner.type, node: argument
            )
        }
        return CompiledExpression(type: inner.type, eval: refusal)
    }

    // MARK: - CONVERT

    /// `CONVERT(x, from, to)` — "how many `to` is `x`, given that `x` is in `from`".
    ///
    /// # Why the result is dimensionless
    ///
    /// A ``DecimalQuantity`` is defined to hold its magnitude in the **SI base unit** of its
    /// dimension. `CONVERT` produces a magnitude in the *target display unit*, which is a
    /// different thing. Tagging that magnitude with the target's SI dimension — which is what
    /// this used to do — let a value in millimetres present itself as a length in metres, and
    /// the additive checker, which only compares dimensions, waved it through:
    ///
    /// ```text
    /// CONVERT(1, m, mm) + CONVERT(1, m, m)   ==   1001 m
    /// ```
    ///
    /// One metre plus one metre, reported as 1001 metres, with no error and no warning. So the
    /// result is a **dimensionless magnitude**: it can be multiplied by a rate, compared, or
    /// rounded, but it can no longer be added to a quantity that is genuinely in SI units.
    ///
    /// The operand is accepted when it carries the source unit's dimension (`CONVERT(Area, m2,
    /// ft2)`), when it is dimensionless (a literal, or a nested `CONVERT` that already produced a
    /// magnitude in the source unit), or when its dimension is only known per row — in which case
    /// the same check runs at evaluation time.
    ///
    /// # A measured operand is read from its base unit only
    ///
    /// A dimensioned operand is a ``DecimalQuantity``, so its magnitude is in the SI base unit
    /// whatever the project displays. Its `from` therefore has to *be* that base unit. Anything
    /// else is refused with ``FormulaEngineErrorCode/convertSourceNotBaseUnit(from:base:)``,
    /// statically when the dimension is known and at evaluation time when it is only known per
    /// row. Before R-136 the unit was never checked: on a row with Area = 10 m²,
    /// `CONVERT(Area, ft2, m2)` read 10 as square feet and returned 0.929 with no error.
    func compileConvert(
        _ operand: FormulaNode,
        from: AnyDisplayUnit,
        to: AnyDisplayUnit,
        _ node: FormulaNode,
        _ environment: inout Environment
    ) throws -> CompiledExpression {
        guard from.dimension == to.dimension else {
            throw FormulaCompiler.incompatibleUnitsError(from, to, node)
        }
        return try combineConvert(try compile(operand, &environment), from: from, to: to, node)
    }

    private func combineConvert(
        _ value: CompiledExpression,
        from: AnyDisplayUnit,
        to: AnyDisplayUnit,
        _ node: FormulaNode
    ) throws -> CompiledExpression {
        let span = node.span
        let text = node.canonicalText
        let sourceDimension = from.dimension

        let mismatch: @Sendable (QuantityDimension) -> FormulaEngineError = { actual in
            FormulaEngineError(
                code: .dimensionMismatch(
                    operation: "convert",
                    left: actual,
                    right: sourceDimension
                ),
                span: span,
                subexpression: text
            )
        }

        let base = from.formulaBaseUnit
        let sourceIsBase = from == base
        let notBase: @Sendable () -> FormulaEngineError = {
            FormulaEngineError(
                code: .convertSourceNotBaseUnit(from: from.formulaToken, base: base.formulaToken),
                span: span,
                subexpression: text
            )
        }

        var checkAtRuntime = false
        switch value.type {
        case .boolean:
            throw FormulaTypeRules.typeError(expected: "a number", actual: value.type, node: node)
        case .number(let dimension, _):
            // A dimensionless operand is a bare magnitude the caller is asserting is already in
            // `from`; anything else is a quantity held in the SI base unit, so it has to carry
            // `from`'s dimension *and* `from` has to be that base unit (R-136).
            guard dimension == sourceDimension || dimension.isDimensionless else {
                throw mismatch(dimension)
            }
            if !dimension.isDimensionless, !sourceIsBase {
                throw notBase()
            }
        case .dynamicNumber:
            checkAtRuntime = true
        }

        let inner = value.eval
        let operandNode = node.children[0]
        let shouldCheck = checkAtRuntime
        return CompiledExpression(type: .number(.count, flexible: false)) { row in
            let quantity = try FormulaRuntimeChecks.requireNumber(inner(row), operandNode, in: text, span)
            if shouldCheck, !quantity.dimension.isDimensionless {
                guard quantity.dimension == sourceDimension else {
                    throw mismatch(quantity.dimension)
                }
                guard sourceIsBase else { throw notBase() }
            }
            guard let converted = from.formulaConvert(quantity.value, to: to) else {
                throw FormulaEngineError(
                    code: .incompatibleUnits(from: from.formulaToken, to: to.formulaToken),
                    span: span,
                    subexpression: text
                )
            }
            // An overflow must surface as the engine's own typed error, like every arithmetic
            // closure, or a ledger that catches `FormulaEngineError` per cell fails the whole
            // store build instead of one cell (BH-541).
            let finite: Decimal
            do {
                finite = try NumericPolicy.requireFinite(converted, operation: "convert")
            } catch {
                throw FormulaRuntimeChecks.wrap(error, operation: "convert", text, span)
            }
            return .number(DecimalQuantity(value: finite, dimension: .count))
        }
    }
}
