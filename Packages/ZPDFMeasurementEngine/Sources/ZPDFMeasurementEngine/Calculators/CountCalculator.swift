import Foundation
import ZPDFContracts

/// The Count tool (spec 12.13): the number of placed symbols.
///
/// Count is dimensionless and exact. It is the one measurement in the product that is an
/// integer, and it stays one: there is no scale, no `Double` stage and no rounding anywhere in
/// its path.
public struct CountCalculator: MeasurementCalculating {
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
        let count = geometry.countPoints.isEmpty ? geometry.points.count : geometry.countPoints.count
        // Geometry that carries no count points and no bare points — a polygon, a circle — is
        // not a count of anything. It used to pass as `count 0` with no warning, which is a
        // silent zero in a total (code review CR-30).
        guard count > 0 else {
            throw MeasurementEngineError.unsupportedGeometry(tool: .count, expected: .countPoints)
        }
        var builder = MeasurementBuilder(display: parameters.display)
        try builder.setCount(.count, count)
        return try builder.finish()
    }
}

/// The Temporary Measure tool (spec 12.14): overlay-only, accumulating, never persisted.
///
/// It measures whatever is present — polyline and arc length, polygon and circle area, count
/// points — and reports only the fields that had input, so an accumulated scratch measurement
/// never shows a `0 m²` for an area nobody drew.
public struct TemporaryMeasureCalculator: MeasurementCalculating {
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
        guard !geometry.isEmpty else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .temporaryMeasure,
                expected: .anyGeometry
            )
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)

        let linear = GeometryInput.linear(geometry)
        if !linear.isEmpty {
            let measured = try LinearMeasure.measure(linear, scale: scale)
            try builder.setLength(.planLength, metres: measured.totalMetres)
        }
        if !geometry.polygons.isEmpty {
            let measured = try ArealMeasure.measure(
                geometry.polygons,
                scale: scale,
                parameters: parameters,
                options: options,
                warnings: &builder.warnings
            )
            try builder.setArea(.planArea, squareMetres: measured.planArea)
            try builder.setArea(.netArea, squareMetres: measured.netArea)
            try builder.setLength(.perimeter, metres: measured.perimeter)
        }
        if !geometry.circles.isEmpty {
            var circleAreas: [Double] = []
            for circle in geometry.circles {
                let axes = EllipseMath.realSemiAxes(
                    pageSemiAxisX: circle.radius,
                    pageSemiAxisY: circle.radius,
                    scale: scale
                )
                circleAreas.append(EllipseMath.area(semiMajor: axes.major, semiMinor: axes.minor))
            }
            // A circle has no cutouts, so it adds to the net area as well as the plan area;
            // adding it to the plan area alone left netArea short by every circle (CR-31).
            let circleTotal = try EngineNumerics.decimal(EngineNumerics.sum(circleAreas))
            let existingPlan = builder.values[.planArea]?.value ?? 0
            let existingNet = builder.values[.netArea]?.value ?? 0
            try builder.setArea(.planArea, squareMetres: existingPlan + circleTotal)
            try builder.setArea(.netArea, squareMetres: existingNet + circleTotal)
        }
        if !geometry.countPoints.isEmpty {
            try builder.setCount(.count, geometry.countPoints.count)
        }
        // Geometry that is present but measures nothing — a single bare point from a one-click
        // Temporary Measure — used to return a result with no values and no warnings, a
        // measurement of nothing. Every other tool refuses input it cannot measure (BH-557).
        guard !builder.values.isEmpty else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .temporaryMeasure,
                expected: .anyGeometry
            )
        }
        return try builder.finish()
    }
}
