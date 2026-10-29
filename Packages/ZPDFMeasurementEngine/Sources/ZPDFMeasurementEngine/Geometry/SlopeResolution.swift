import Foundation
import ZPDFContracts

/// A slope reduced to the numbers spec 12.8 names, with the vertical case carried explicitly.
///
/// ```text
/// slopeRatio   = rise / run
/// slopePercent = 100 * rise / run
/// slopeAngle   = atan(rise / run)
/// trueLength   = planLength * sqrt(1 + slopeRatio^2)
/// trueArea     = planArea   * sqrt(1 + slopeRatio^2)
/// ```
///
/// `run == 0` is vertical: ``ratio``, ``percent`` and ``trueLengthFactor`` are `nil` and the
/// caller emits ``MeasurementWarning/Code/verticalSlopeUndefinedRun``. No field ever holds an
/// infinity or a NaN — a value that cannot exist is absent, not poisoned.
public struct SlopeResolution: Hashable, Sendable {
    public let ratio: Decimal?
    public let percent: Decimal?
    public let angleRadians: Double
    public let trueLengthFactor: Double?
    public let isVertical: Bool

    init(ratio: Decimal?, percent: Decimal?, angleRadians: Double, trueLengthFactor: Double?, isVertical: Bool) {
        self.ratio = ratio
        self.percent = percent
        self.angleRadians = angleRadians
        self.trueLengthFactor = trueLengthFactor
        self.isVertical = isVertical
    }

    /// Reduces a ``SlopeExpression``. Vertical never throws; it resolves.
    public static func resolve(_ expression: SlopeExpression) throws -> SlopeResolution {
        let angle: Double
        do {
            angle = try expression.angleRadians()
        } catch let error as SlopeError {
            throw MeasurementEngineError.slope(error)
        }
        if expression.isVertical {
            return SlopeResolution(
                ratio: nil,
                percent: nil,
                angleRadians: angle,
                trueLengthFactor: nil,
                isVertical: true
            )
        }
        let ratio: Decimal
        let factor: Double
        do {
            ratio = try expression.ratio()
            factor = try expression.trueLengthFactor()
        } catch let error as SlopeError {
            throw MeasurementEngineError.slope(error)
        }
        return SlopeResolution(
            ratio: ratio,
            percent: ratio * 100,
            angleRadians: angle,
            trueLengthFactor: factor,
            isVertical: false
        )
    }

    /// Reduces an explicit rise and run in metres, the form Rise/Drop produces.
    public static func resolve(riseMetres: Double, runMetres: Double) throws -> SlopeResolution {
        guard riseMetres.isFinite, runMetres.isFinite else {
            throw MeasurementEngineError.measurement(.nonFiniteCoordinate)
        }
        guard runMetres != 0 else {
            return SlopeResolution(
                ratio: nil,
                percent: nil,
                angleRadians: riseMetres < 0 ? -Double.pi / 2 : Double.pi / 2,
                trueLengthFactor: nil,
                isVertical: true
            )
        }
        let ratio = riseMetres / runMetres
        let decimal = try EngineNumerics.decimal(ratio)
        return SlopeResolution(
            ratio: decimal,
            percent: decimal * 100,
            angleRadians: Foundation.atan(ratio),
            trueLengthFactor: (1 + ratio * ratio).squareRoot(),
            isVertical: false
        )
    }
}

extension WarningLog {
    /// Adds the slope fields a result should carry, and the vertical warning when they are absent.
    mutating func noteVertical(_ resolution: SlopeResolution, detail: String = "run == 0") {
        if resolution.isVertical {
            add(.verticalSlopeUndefinedRun, field: .slopeRatio, detail: detail)
        }
    }
}
