import Foundation
import ZPDFContracts

/// Assembles a ``MeasurementResult`` field by field.
///
/// Two rules are enforced here rather than in twenty-two calculators: a field is only ever
/// written with a quantity whose dimension the field declares, and no value is rounded on the
/// way in. A dimension clash is a typed error, not a silently coerced number, which is the
/// mechanism behind "incompatible dimensions are never added" in spec 11.4.
struct MeasurementBuilder {
    private(set) var values: [MeasurementField: DecimalQuantity] = [:]
    var warnings = WarningLog()
    /// Display metadata. It never changes a stored value; it only decides whether an angle
    /// needs the "this display unit is an inexact conversion" warning.
    let display: DisplayUnitPolicy

    init(display: DisplayUnitPolicy = .metric) {
        self.display = display
    }

    mutating func set(_ field: MeasurementField, _ quantity: DecimalQuantity) throws {
        guard quantity.dimension == field.dimension else {
            throw MeasurementEngineError.dimension(
                .incompatibleDimensions(left: field.dimension, right: quantity.dimension)
            )
        }
        values[field] = quantity
    }

    mutating func setLength(_ field: MeasurementField, metres: Double) throws {
        try set(field, .length(try EngineNumerics.decimal(metres)))
    }

    mutating func setLength(_ field: MeasurementField, metres: Decimal) throws {
        try set(field, .length(metres))
    }

    mutating func setArea(_ field: MeasurementField, squareMetres: Decimal) throws {
        try set(field, .area(squareMetres))
    }

    mutating func setAngle(_ field: MeasurementField, radians: Double) throws {
        try set(field, .angle(try EngineNumerics.decimal(radians)))
        if !display.angle.isExactByDefinition {
            warnings.add(
                .unitConversionApproximated,
                field: field,
                detail: "stored in radians; \(display.angle.symbol) display is an inexact conversion"
            )
        }
    }

    mutating func setRatio(_ field: MeasurementField, _ value: Decimal) throws {
        try set(field, .ratio(value))
    }

    mutating func setCount(_ field: MeasurementField, _ value: Int) throws {
        try set(field, .count(value))
    }

    /// Writes the slope fields the tools share, including the vertical case where the ratio and
    /// the percent simply do not exist.
    mutating func setSlope(_ resolution: SlopeResolution) throws {
        if let ratio = resolution.ratio { try setRatio(.slopeRatio, ratio) }
        if let percent = resolution.percent { try setRatio(.slopePercent, percent) }
        try setAngle(.slopeAngle, radians: resolution.angleRadians)
        warnings.noteVertical(resolution)
    }

    func finish() throws -> MeasurementResult {
        let result = MeasurementResult(
            values: values,
            warnings: warnings.warnings,
            formulaVersion: ContractVersion.measurementFormulaVersion
        )
        try result.validateDimensions()
        return result
    }
}
