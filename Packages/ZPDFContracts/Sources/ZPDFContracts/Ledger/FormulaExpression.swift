import Foundation

/// The operators the formula grammar defines (spec 15.4).
///
/// There is no `eval`, no host bridge and no way to add an operator at runtime. The grammar is
/// this enum, a Pratt parser over it, and nothing else.
public enum FormulaOperator: String, Codable, Hashable, Sendable, CaseIterable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case modulo = "%"
    case power = "^"
    case equal = "=="
    case notEqual = "!="
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
    case and = "and"
    case or = "or"
    case not = "not"

    /// Binding power for the Pratt parser. Higher binds tighter. `not` is prefix-only and has
    /// no infix power.
    public var infixBindingPower: Int? {
        switch self {
        case .or: 1
        case .and: 2
        case .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual: 3
        case .add, .subtract: 4
        case .multiply, .divide, .modulo: 5
        case .power: 6
        case .not: nil
        }
    }

    /// True for the right-associative operators. Only `^` is.
    public var isRightAssociative: Bool { self == .power }

    /// True for operators that yield a boolean rather than a dimensioned number.
    public var isPredicate: Bool {
        switch self {
        case .equal, .notEqual, .lessThan, .lessThanOrEqual,
             .greaterThan, .greaterThanOrEqual, .and, .or, .not:
            true
        default:
            false
        }
    }
}

/// The function set the formula grammar defines (spec 15.4). Closed by design.
public enum FormulaFunction: String, Codable, Hashable, Sendable, CaseIterable {
    case iff = "IF"
    case round = "ROUND"
    case roundUp = "ROUNDUP"
    case roundDown = "ROUNDDOWN"
    case min = "MIN"
    case max = "MAX"
    case abs = "ABS"
    case sum = "SUM"
    case count = "COUNT"
    case coalesce = "COALESCE"

    /// Permitted argument counts.
    public var arity: ClosedRange<Int> {
        switch self {
        case .iff: 3...3
        case .round, .roundUp, .roundDown: 1...2
        case .min, .max: 1...64
        case .abs: 1...1
        case .sum, .count: 1...64
        case .coalesce: 1...64
        }
    }
}

/// The built-in variables a formula can reference (spec 15.4).
///
/// Custom columns are referenced by their column key, which is why unknown identifiers are a
/// typed ``FormulaError/unknownVariable(_:)`` resolved against the column set rather than a
/// parse failure.
public enum FormulaVariable: String, Codable, Hashable, Sendable, CaseIterable {
    case count = "Count"
    case length = "Length"
    case trueLength = "TrueLength"
    case perimeter = "Perimeter"
    case area = "Area"
    case trueArea = "TrueArea"
    case wallArea = "WallArea"
    case volume = "Volume"
    case depth = "Depth"
    case height = "Height"
    case slope = "Slope"
    case unitCost = "UnitCost"

    /// The measurement field this variable reads, where one exists.
    public var measurementField: MeasurementField? {
        switch self {
        case .count: .count
        case .length: .planLength
        case .trueLength: .trueLength
        case .perimeter: .perimeter
        case .area: .netArea
        case .trueArea: .trueArea
        case .wallArea: .netWallArea
        case .volume: .volume
        case .depth: .depth
        case .height: .height
        case .slope: .slopeRatio
        case .unitCost: nil
        }
    }

    /// The dimension the variable carries. `UnitCost` is currency per unit and its length power
    /// depends on what it prices, so it is resolved from the column, not from here.
    public var dimension: QuantityDimension? { measurementField?.dimension }
}

/// A stored formula (spec 15.4).
///
/// This is deliberately a *placeholder* in the contract sense: it freezes the persisted shape —
/// source text plus grammar version — without freezing the AST. The Pratt parser, its node
/// types and its evaluator live in the ledger engine package. Persisting the source rather than
/// a serialised AST means a grammar fix re-parses old formulas instead of migrating them, and
/// ``grammarVersion`` is what tells the engine whether it may.
public struct FormulaExpression: Codable, Hashable, Sendable {
    /// The formula as the user typed it. Never evaluated as script; only parsed by the Zenit
    /// Pratt parser.
    public let source: String
    /// The grammar version the source was authored against.
    public let grammarVersion: Int

    public init(source: String, grammarVersion: Int = ContractVersion.formula) {
        self.source = source
        self.grammarVersion = grammarVersion
    }

    /// The checks the contract guarantees before a parser ever sees the source.
    public func validate() throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FormulaError.emptySource
        }
        guard grammarVersion <= ContractVersion.formula else {
            throw FormulaError.unsupportedGrammarVersion(
                stored: grammarVersion,
                supported: ContractVersion.formula
            )
        }
    }
}
