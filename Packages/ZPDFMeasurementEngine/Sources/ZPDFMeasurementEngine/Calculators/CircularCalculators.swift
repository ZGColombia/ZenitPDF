import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Radius, diameter, circumference and area of a circle, shared by the three circle tools.
enum CircleMeasure {
    static func write(
        _ circle: CircleGeometry,
        scale: ScaleTransform,
        options: MeasurementEngineOptions,
        builder: inout MeasurementBuilder
    ) throws {
        // A circle in page space is an ellipse in the real world unless the scale is uniform.
        // Reporting one radius for an ellipse would be a lie, so the non-uniform case is a typed
        // error rather than a number picked from the x axis.
        guard scale.isUniform else {
            throw MeasurementEngineError.scaleApplication(
                .directionRequiredForNonUniformScale(scale.id)
            )
        }
        guard circle.radius.isFinite, circle.center.isFinite else {
            throw MeasurementEngineError.measurement(.nonFiniteCoordinate)
        }
        let metresPerPoint = scale.matrix.metresPerPointX
        let radius = circle.radius * metresPerPoint
        try builder.setLength(.radius, metres: radius)
        try builder.setLength(.diameter, metres: radius * 2)
        try builder.setLength(.circumference, metres: 2 * Double.pi * radius)
        // Radius, Diameter and Three-Point Circle are informational: they read a size off a
        // drawn circle (a pipe, a column, a curved wall). They used to write the disc into
        // `perimeter`, `planArea` and `netArea`, and those fields are the Perimeter, Gross Area
        // and Plan Area ledger columns, so measuring a column's radius added its disc to the
        // subject's area total (formula version 4, ADR-0019). The disc area belongs to the
        // Ellipse Area tool, which already produces it as a quantity.
        // The floor is in square page points, so it is tested on the page-space disc. Testing
        // the disc in square metres made "degenerate" depend on the drawing scale (R-183).
        if Double.pi * circle.radius * circle.radius <= options.epsilon.areaFloor {
            builder.warnings.add(.degenerateArea, field: .radius, detail: "radius ~ 0")
        }
    }
}

/// Two points read as centre and a point on the rim.
public struct RadiusCalculator: MeasurementCalculating {
    public let options: MeasurementEngineOptions

    public init(options: MeasurementEngineOptions = .default) {
        self.options = options
    }

    public func calculate(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters
    ) throws -> MeasurementResult {
        try parameters.validate()
        guard let circle = GeometryInput.circle(geometry, interpretation: .centreAndRim) else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .radius,
                expected: .circleOrTwoPoints
            )
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        try CircleMeasure.write(circle, scale: scale, options: options, builder: &builder)
        return try builder.finish()
    }
}

/// Two points read as opposite ends of a diameter.
public struct DiameterCalculator: MeasurementCalculating {
    public let options: MeasurementEngineOptions

    public init(options: MeasurementEngineOptions = .default) {
        self.options = options
    }

    public func calculate(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters
    ) throws -> MeasurementResult {
        try parameters.validate()
        guard let circle = GeometryInput.circle(geometry, interpretation: .diameterEndpoints) else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .diameter,
                expected: .circleOrTwoPoints
            )
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        try CircleMeasure.write(circle, scale: scale, options: options, builder: &builder)
        return try builder.finish()
    }
}

/// The circle through three points (spec 12.11).
///
/// Near-collinear input is rejected on the normalised measure `|cross| / maxEdge²`, not on an
/// absolute area: three points a metre apart bending by a micrometre define a circle of radius
/// 1e8 m, which is numerical garbage, while three points a millimetre apart can define a
/// perfectly good small circle. A triple that passes but is within a thousand times the
/// threshold still raises ``MeasurementWarning/Code/nearlyCollinearPoints``.
public struct ThreePointCircleCalculator: MeasurementCalculating {
    public let options: MeasurementEngineOptions

    public init(options: MeasurementEngineOptions = .default) {
        self.options = options
    }

    public func calculate(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters
    ) throws -> MeasurementResult {
        try parameters.validate()
        guard geometry.points.count >= 3 else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .threePointCircle,
                expected: .threePoints
            )
        }
        let a = geometry.points[0]
        let b = geometry.points[1]
        let c = geometry.points[2]
        let circle: CircleGeometry
        do {
            circle = try SegmentMath.circumcircle(
                a, b, c,
                collinearityThreshold: options.collinearityThreshold
            )
        } catch let error as GeometryError {
            if case .nearlyCollinearPoints = error {
                throw MeasurementEngineError.measurement(.nearlyCollinearPoints)
            }
            throw MeasurementEngineError.geometry(error)
        }

        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)

        let cross = (a.x - c.x) * (b.y - c.y) - (a.y - c.y) * (b.x - c.x)
        let maxEdge = max(a.distance(to: b), max(b.distance(to: c), c.distance(to: a)))
        if maxEdge > 0 {
            let measure = abs(cross) / (maxEdge * maxEdge)
            if measure < options.collinearityThreshold * 1_000 {
                builder.warnings.add(
                    .nearlyCollinearPoints,
                    field: .radius,
                    detail: "normalised measure \(measure)"
                )
            }
        }
        try CircleMeasure.write(circle, scale: scale, options: options, builder: &builder)
        return try builder.finish()
    }
}

// MARK: - Angle (spec 12.10)

/// ```text
/// u = A - B
/// v = C - B
/// angle = atan2(|cross(u,v)|, dot(u,v))
/// ```
///
/// The `atan2` form is the contract's (spec 12.10) and is well conditioned over the whole
/// range. `acos(clamp(dot / (|u||v|)))` has an infinite derivative at 0 and pi and loses half
/// the available digits there: a 1e-9 rad corner came back as exactly 0 (code review CR-26).
///
/// The three points are mapped into real-world space first. An affine scale with different X and
/// Y factors does not preserve angles, so the angle between two page-space vectors is not the
/// angle on the building; measuring in real space is the only reading that matches a protractor
/// held against the finished wall.
public struct AngleCalculator: MeasurementCalculating {
    public let options: MeasurementEngineOptions

    public init(options: MeasurementEngineOptions = .default) {
        self.options = options
    }

    public func calculate(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters
    ) throws -> MeasurementResult {
        try parameters.validate()
        guard geometry.points.count >= 3 else {
            throw MeasurementEngineError.unsupportedGeometry(tool: .angle, expected: .threePoints)
        }
        // The rays are page-space deltas mapped as deltas, the rule every other length in the
        // engine follows. Mapping the three absolute points and subtracting afterwards carried
        // the translation and the absolute coordinates into the subtraction, costing about
        // |p| / |ray| · eps relative — the 12th digit of the stored angle on a short ray far from
        // the origin — and rebuilt the matrix components three times (R-184).
        let m = scale.matrix.components
        let vertexPoint = geometry.points[1]
        let pageU = (dx: geometry.points[0].x - vertexPoint.x, dy: geometry.points[0].y - vertexPoint.y)
        let pageV = (dx: geometry.points[2].x - vertexPoint.x, dy: geometry.points[2].y - vertexPoint.y)
        let ux = m.a * pageU.dx + m.b * pageU.dy
        let uy = m.c * pageU.dx + m.d * pageU.dy
        let vx = m.a * pageV.dx + m.b * pageV.dy
        let vy = m.c * pageV.dx + m.d * pageV.dy
        let uMagnitude = (ux * ux + uy * uy).squareRoot()
        let vMagnitude = (vx * vx + vy * vy).squareRoot()
        guard uMagnitude > 0, vMagnitude > 0 else {
            throw MeasurementEngineError.geometry(.zeroLengthVector)
        }
        let angle = Foundation.atan2(Swift.abs(ux * vy - uy * vx), ux * vx + uy * vy)

        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        try builder.setAngle(.angle, radians: angle)
        // No `planLength`. The two rays are construction lines, not a run of anything: writing
        // `|ray1| + |ray2|` into the Plan Length column added them to the subject's length total
        // every time an angle was read off a wall (formula version 4, ADR-0019).
        return try builder.finish()
    }
}
