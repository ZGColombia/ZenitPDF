import Foundation
import ZPDFContracts

/// The measurement engine: one ``MeasurementCalculating`` per tool in spec 12.1.
///
/// ```swift
/// let engine = MeasurementEngine()
/// let result = try engine.calculate(tool: .area, geometry: geometry, scale: scale, parameters: .default)
/// ```
///
/// The engine is a value, is `Sendable`, and holds nothing but its options. Every calculation is
/// a pure function of `(tool, geometry, scale, parameters)`: no clock, no identifier generation,
/// no I/O, no caching. The same four inputs give the same ``MeasurementResult`` — including the
/// same warnings in the same order — on every machine and in every build that stamps the same
/// ``MeasurementResult/formulaVersion``.
public struct MeasurementEngine: Sendable {
    public let options: MeasurementEngineOptions

    public init(options: MeasurementEngineOptions = .default) {
        self.options = options
    }

    /// The formula version every result produced by this build carries (spec 12.15).
    public static var formulaVersion: Int { ContractVersion.measurementFormulaVersion }

    /// The calculator that implements a tool.
    public func calculator(for tool: MeasurementTool) -> any MeasurementCalculating {
        switch tool {
        case .length: LengthCalculator(options: options)
        case .dimension: DimensionCalculator(options: options)
        case .polylength: PolylengthCalculator(options: options)
        case .perimeter: PerimeterCalculator(options: options)
        case .area: AreaCalculator(options: options)
        case .rectangleArea: RectangleAreaCalculator(options: options)
        case .ellipseArea: EllipseAreaCalculator(options: options)
        case .polygonCutout: PolygonCutoutCalculator(options: options)
        case .ellipseCutout: EllipseCutoutCalculator(options: options)
        case .volume: VolumeCalculator(options: options)
        case .wallArea: WallAreaCalculator(options: options)
        case .count: CountCalculator(options: options)
        case .radius: RadiusCalculator(options: options)
        case .diameter: DiameterCalculator(options: options)
        case .threePointCircle: ThreePointCircleCalculator(options: options)
        case .angle: AngleCalculator(options: options)
        case .slope: SlopeCalculator(options: options)
        case .riseDrop: RiseDropCalculator(options: options)
        case .trueSlopedLength: TrueSlopedLengthCalculator(options: options)
        case .trueSlopedArea: TrueSlopedAreaCalculator(options: options)
        case .arcLength: ArcLengthCalculator(options: options)
        case .temporaryMeasure: TemporaryMeasureCalculator(options: options)
        }
    }

    /// Runs a tool.
    ///
    /// - Throws: ``MeasurementEngineError``. Every failure from a dependency — geometry, scale
    ///   application, Clipper2, the numeric policy — is re-raised in that one error space, so a
    ///   caller catches one type rather than six.
    public func calculate(
        tool: MeasurementTool,
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters = .default
    ) throws -> MeasurementResult {
        guard geometry.isFinite else {
            throw MeasurementEngineError.measurement(.nonFiniteCoordinate)
        }
        // QUALITY_BAR 2.5 "Huge coordinates": a page cannot reach 1e7 points, so geometry out
        // there is a corrupt file or a bad CTM. It used to be measured like any other and came
        // back as a plausible-looking quantity; it is a typed refusal now (R-169, ADR-0035).
        guard geometry.isWithinCoordinateBound, Self.arcEdgesAreWithinCoordinateBound(geometry) else {
            throw MeasurementEngineError.measurement(.coordinateOutOfRange)
        }
        // A radius is a distance. A negative one came through every circle and arc tool as a
        // negative length — an arc length of −5 m (code review CR-28). Zero is a degenerate
        // circle and is warned about by the tool; negative is not a circle at all.
        if geometry.circles.contains(where: { $0.radius < 0 })
            || geometry.arcs.contains(where: { $0.radius < 0 }) {
            throw MeasurementEngineError.unsupportedGeometry(tool: tool, expected: .positiveRadius)
        }
        do {
            return try calculator(for: tool).calculate(
                geometry: geometry,
                scale: scale,
                parameters: parameters
            )
        } catch {
            throw MeasurementEngineError.wrapping(error, tool: tool)
        }
    }

    /// R-169 for the arcs implied by bulges (S-109): every point of every bulged ring or chain
    /// edge lies within ``MeasurementGeometry/coordinateMagnitudeBound``.
    ///
    /// ``MeasurementGeometry/isWithinCoordinateBound`` checks the stored vertices, but a bulge is
    /// only required to be finite, so a corrupt bulge of 1e12 on a 100 pt chord made an arc of
    /// radius 2.5e13 pt, and the area was stored as about 2e27 pt² (or failed as a Clipper
    /// overflow once a boolean ran). The test is on the arc's extent — its end points and the
    /// axis extremes its sweep passes — not on its centre and radius: a nearly straight arc the
    /// canvas draws legitimately (a 1000 pt chord with a 0.01 pt sagitta has r = 1.25e7 pt) keeps
    /// its centre far away while every point of it stays on the page.
    static func arcEdgesAreWithinCoordinateBound(_ geometry: MeasurementGeometry) -> Bool {
        let bound = MeasurementGeometry.coordinateMagnitudeBound
        func inside(_ points: [PDFPoint], bulges: [Double]?, isClosed: Bool) -> Bool {
            guard let bulges = PolygonRing(points: points, isClosed: isClosed, bulges: bulges).validBulges else {
                return true
            }
            let edgeCount = isClosed ? points.count : points.count - 1
            for index in 0..<Swift.max(edgeCount, 0) where bulges[index] != 0 {
                let box = ArcEdge(start: points[index], end: points[(index + 1) % points.count], bulge: bulges[index]).bounds
                // Written so a NaN extent (an overflowing radius) is outside, not inside.
                guard box.minX >= -bound, box.maxX <= bound, box.minY >= -bound, box.maxY <= bound else {
                    return false
                }
            }
            return true
        }
        return inside(geometry.points, bulges: geometry.pointBulges, isClosed: false)
            && geometry.polygons.allSatisfy { polygon in
                // A polygon ring's perimeter is measured closed whatever its flag says, so its
                // closing edge's bulge counts too.
                ([polygon.outer] + polygon.holes).allSatisfy { inside($0.points, bulges: $0.bulges, isClosed: true) }
            }
    }
}
