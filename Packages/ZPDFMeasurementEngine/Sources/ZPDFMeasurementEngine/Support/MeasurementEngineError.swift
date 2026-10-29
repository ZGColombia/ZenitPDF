import Foundation
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// Every way a measurement calculation can fail, as a typed Swift error.
///
/// There is no `fatalError` and no placeholder anywhere in this package. A degenerate ring, a
/// missing depth or a cutout drawn outside its parent are ordinary inputs from a real drawing
/// set, not programmer errors, so each one has a case the caller can present.
public enum MeasurementEngineError: Error, Equatable, Sendable {
    /// The tool needs geometry the caller did not supply, named by what was expected.
    case unsupportedGeometry(tool: MeasurementTool, expected: GeometryRequirement)
    /// A failure raised by the frozen contracts' measurement validation.
    case measurement(MeasurementError)
    /// A failure raised by the page-space geometry core.
    case geometry(GeometryError)
    /// A failure raised while applying a ``ScaleTransform``.
    case scaleApplication(ScaleApplicationError)
    /// A failure raised by the scale itself (singular matrix, malformed storage).
    case scale(ScaleError)
    /// A failure raised by the Clipper2 boolean pipeline used for cutouts (spec 12.4).
    case clipper(ClipperError)
    /// A failure raised while converting a geometry `Double` into a `Decimal` (spec 11.4).
    case numeric(NumericError)
    /// A failure raised by dimensional algebra: incompatible dimensions are never added.
    case dimension(DimensionError)
    /// A failure raised by a ``SlopeExpression`` (spec 12.8).
    case slope(SlopeError)
    /// A parameter's dimension did not match what the parameter means.
    case unitMismatch(UnitConversionError)

    /// What a tool wanted and did not get.
    public enum GeometryRequirement: String, Codable, Hashable, Sendable, CaseIterable {
        case atLeastTwoPoints
        case exactlyOneSegment
        case threePoints
        case closedRing
        case circleOrTwoPoints
        case arc
        case countPoints
        case anyGeometry
        /// A circle or arc carried a negative radius (code review CR-28).
        case positiveRadius
    }
}

extension MeasurementEngineError {
    /// Wraps whatever a dependency threw into the engine's own error space, so a caller only
    /// ever has to catch one type.
    static func wrapping(_ error: any Error, tool: MeasurementTool) -> MeasurementEngineError {
        switch error {
        case let error as MeasurementEngineError: error
        case let error as MeasurementError: .measurement(error)
        case let error as GeometryError: .geometry(error)
        case let error as ScaleApplicationError: .scaleApplication(error)
        case let error as ClipperError: .clipper(error)
        case let error as NumericError: .numeric(error)
        case let error as DimensionError: .dimension(error)
        case let error as SlopeError: .slope(error)
        case let error as UnitConversionError: .unitMismatch(error)
        case let error as ScaleError: .scale(error)
        default: .unsupportedGeometry(tool: tool, expected: .anyGeometry)
        }
    }
}
