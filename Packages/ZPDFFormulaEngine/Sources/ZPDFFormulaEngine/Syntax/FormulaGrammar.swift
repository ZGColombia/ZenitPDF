import Foundation
import ZPDFContracts

/// The grammar version this engine implements. Matches ``ContractVersion/formula``.
public enum FormulaGrammar: Sendable {
    public static let version = ContractVersion.formula
}

/// The measurement fields a formula can name directly.
///
/// This is a strict superset of the frozen ``FormulaVariable``: the contract froze the twelve
/// names the first ledger shipped with, and the engine adds the remaining measurement fields the
/// takeoff already produces (`SlopePercent`, `Radius`, `Diameter`, `Circumference`, `ArcLength`,
/// `Angle`, `Rise`, `Run`). Every contract case is present with the same spelling and the same
/// meaning, so a formula written against ``FormulaVariable`` parses unchanged.
public enum FormulaBuiltinVariable: String, Hashable, Sendable, CaseIterable {
    case count = "Count"
    case length = "Length"
    case trueLength = "TrueLength"
    case perimeter = "Perimeter"
    case planArea = "PlanArea"
    case area = "Area"
    case trueArea = "TrueArea"
    case cutoutArea = "CutoutArea"
    case wallArea = "WallArea"
    case grossWallArea = "GrossWallArea"
    case volume = "Volume"
    case depth = "Depth"
    case height = "Height"
    case slope = "Slope"
    case slopePercent = "SlopePercent"
    case slopeAngle = "SlopeAngle"
    case rise = "Rise"
    case run = "Run"
    case radius = "Radius"
    case diameter = "Diameter"
    case circumference = "Circumference"
    case arcLength = "ArcLength"
    case angle = "Angle"
    case unitCost = "UnitCost"

    /// The measurement field this variable reads. `UnitCost` has none: it is a ledger column, not
    /// a measured quantity, so it is resolved from the row's unit cost slot.
    public var measurementField: MeasurementField? {
        switch self {
        case .count: .count
        case .length: .planLength
        case .trueLength: .trueLength
        case .perimeter: .perimeter
        case .planArea: .planArea
        case .area: .netArea
        case .trueArea: .trueArea
        case .cutoutArea: .cutoutArea
        case .wallArea: .netWallArea
        case .grossWallArea: .wallArea
        case .volume: .volume
        case .depth: .depth
        case .height: .height
        case .slope: .slopeRatio
        case .slopePercent: .slopePercent
        case .slopeAngle: .slopeAngle
        case .rise: .rise
        case .run: .run
        case .radius: .radius
        case .diameter: .diameter
        case .circumference: .circumference
        case .arcLength: .arcLength
        case .angle: .angle
        case .unitCost: nil
        }
    }

    /// The dimension the variable always carries, or nil when it is resolved per row.
    public var dimension: QuantityDimension? { measurementField?.dimension }

    /// Case-insensitive lookup, so `area` and `Area` are the same variable.
    public static func named(_ text: String) -> FormulaBuiltinVariable? {
        lowercasedIndex[text.lowercased()]
    }

    private static let lowercasedIndex: [String: FormulaBuiltinVariable] = {
        var index: [String: FormulaBuiltinVariable] = [:]
        for variable in FormulaBuiltinVariable.allCases {
            index[variable.rawValue.lowercased()] = variable
        }
        return index
    }()
}

/// The closed function set. There is no `eval`, no host bridge and no registration hook.
///
/// Superset of the frozen ``FormulaFunction`` in the same way ``FormulaBuiltinVariable`` is a
/// superset of ``FormulaVariable``: every contract function is here with its contract spelling.
/// The additions are `CEILING`, `FLOOR`, `AVG`, `SQRT`, `POW` and `CONVERT`.
public enum FormulaEngineFunction: String, Hashable, Sendable, CaseIterable {
    case iff = "IF"
    case round = "ROUND"
    case roundUp = "ROUNDUP"
    case roundDown = "ROUNDDOWN"
    case ceiling = "CEILING"
    case floor = "FLOOR"
    case abs = "ABS"
    case min = "MIN"
    case max = "MAX"
    case sum = "SUM"
    case avg = "AVG"
    case count = "COUNT"
    case sqrt = "SQRT"
    case pow = "POW"
    case convert = "CONVERT"
    case coalesce = "COALESCE"

    /// Permitted argument counts.
    ///
    /// `SUM`, `AVG` and `COUNT` take exactly one argument here, unlike the frozen
    /// ``FormulaFunction/arity`` which allowed a variadic list. They are *group* aggregates: the
    /// single argument is evaluated once per row of the current group. A variadic `SUM(a, b, c)`
    /// would mean something else entirely, so it is spelled `a + b + c`.
    public var arity: ClosedRange<Int> {
        switch self {
        case .iff: 3...3
        case .round, .roundUp, .roundDown, .ceiling, .floor: 1...2
        case .abs, .sqrt: 1...1
        case .min, .max: 1...64
        case .sum, .avg, .count: 1...1
        case .pow: 2...2
        case .convert: 3...3
        case .coalesce: 1...64
        }
    }

    /// True for the functions that read the whole group rather than the current row.
    public var isAggregate: Bool {
        switch self {
        case .sum, .avg, .count: true
        default: false
        }
    }

    /// Case-insensitive lookup, so `if` and `IF` are the same function.
    public static func named(_ text: String) -> FormulaEngineFunction? {
        lowercasedIndex[text.lowercased()]
    }

    private static let lowercasedIndex: [String: FormulaEngineFunction] = {
        var index: [String: FormulaEngineFunction] = [:]
        for function in FormulaEngineFunction.allCases {
            index[function.rawValue.lowercased()] = function
        }
        return index
    }()
}
