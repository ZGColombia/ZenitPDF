import Foundation
import ZPDFContracts
import ZPDFGeometry

// MARK: - Area (spec 12.3, 12.4, 12.5)

/// Shoelace area of the outer ring, minus the union of its cutouts, plus the perimeter under the
/// caller's ``PerimeterPolicy``.
///
/// ```text
/// area    = 1/2 × abs(Σ(x_i × y_i+1 - x_i+1 × y_i))
/// netArea = outerArea - union(cutoutAreas)
/// ```
public struct AreaCalculator: MeasurementCalculating {
    public let options: MeasurementEngineOptions
    let tool: MeasurementTool

    public init(options: MeasurementEngineOptions = .default) {
        self.init(options: options, tool: .area)
    }

    init(options: MeasurementEngineOptions, tool: MeasurementTool) {
        self.options = options
        self.tool = tool
    }

    public func calculate(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters
    ) throws -> MeasurementResult {
        try parameters.validate()
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        let outcome = try Self.measure(
            geometry: geometry,
            scale: scale,
            parameters: parameters,
            options: options,
            tool: tool,
            builder: &builder
        )
        try SlopeApplication.applyToArea(
            netAreaSquareMetres: outcome.measured.netArea,
            plane: outcome.plane,
            parameters: parameters,
            builder: &builder
        )
        return try builder.finish()
    }

    /// What ``measure(geometry:scale:parameters:options:tool:builder:)`` hands back: the plan
    /// numbers and, when the markup carries a uniform plane, the resolved slope so the caller
    /// does not resolve it a second time and risk resolving it differently.
    struct Outcome: Sendable {
        var measured: ArealMeasure.Result
        var plane: SlopeApplication.Plane?
    }

    /// Shared by Area, Volume, Wall Area and True Sloped Area: resolve polygons, write
    /// `planArea` / `netArea` / `cutoutArea` / `perimeter` / `truePerimeter`, return the numbers.
    static func measure(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters,
        options: MeasurementEngineOptions,
        tool: MeasurementTool,
        builder: inout MeasurementBuilder
    ) throws -> Outcome {
        let areal = GeometryInput.areal(geometry)
        guard !areal.polygons.isEmpty else {
            throw MeasurementEngineError.unsupportedGeometry(tool: tool, expected: .closedRing)
        }
        if areal.closedImplicitly {
            builder.warnings.add(.openPolygonClosedImplicitly, field: .planArea)
        }
        let plane = try SlopeApplication.arealPlaneIfUniform(
            parameters.slope,
            scale: scale,
            warnings: &builder.warnings
        )
        let measured = try ArealMeasure.measure(
            areal.polygons,
            scale: scale,
            parameters: parameters,
            options: options,
            slope: plane?.directional,
            warnings: &builder.warnings
        )
        try write(measured, parameters: parameters, into: &builder)
        return Outcome(measured: measured, plane: plane)
    }

    /// The **one** place the areal ledger fields are written: `planArea`, `netArea`,
    /// `cutoutArea` (when a cutout took part, or when the policy reports cutouts as their own
    /// rows even if there were none), `perimeter` and `truePerimeter`.
    ///
    /// Area and Rectangle Area used to each write these by hand, and the copies had already
    /// drifted: a rectangle measured under `.subtractAndReportSeparately` with no holes showed
    /// no cutout column while a polygon area showed `0 m²` (IM-066). One writer, one ledger.
    static func write(
        _ measured: ArealMeasure.Result,
        parameters: MeasurementParameters,
        into builder: inout MeasurementBuilder
    ) throws {
        try builder.setArea(.planArea, squareMetres: measured.planArea)
        try builder.setArea(.netArea, squareMetres: measured.netArea)
        if measured.hasCutouts || parameters.cutoutPolicy == .subtractAndReportSeparately {
            try builder.setArea(.cutoutArea, squareMetres: measured.cutoutArea)
        }
        try builder.setLength(.perimeter, metres: measured.perimeter)
        if let truePerimeter = measured.truePerimeter {
            try builder.setLength(.truePerimeter, metres: truePerimeter)
        }
    }
}

// MARK: - Rectangle Area

/// A four-corner area. Two points are read as opposite corners of an axis-aligned page-space
/// rectangle; four or more are read as the ring that was drawn, so a rotated rectangle keeps its
/// rotation instead of being re-derived from a bounding box.
public struct RectangleAreaCalculator: MeasurementCalculating {
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
        guard let ring = GeometryInput.rectangleRing(geometry) else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .rectangleArea,
                expected: .closedRing
            )
        }
        // A stored ring with arc edges (ADR-0030 §5) is measured as stored, bulges and all: Merge
        // Areas keeps the first record's tool, so a Rectangle Area merged with an arc area carries
        // the arc, and the canvas draws it. Rebuilding the ring from its unique points threw the
        // bulges away and measured the chords — 80 m² for 80 + 3.125π (ADR-0030 §5.7).
        let polygon: PolygonGeometry
        if let stored = geometry.polygons.first, stored.outer.hasArcs {
            polygon = PolygonGeometry(outer: stored.outer, holes: stored.holes)
        } else {
            polygon = PolygonGeometry(
                outer: PolygonRing(points: ring, isClosed: true),
                holes: geometry.polygons.first?.holes ?? []
            )
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        let plane = try SlopeApplication.arealPlaneIfUniform(
            parameters.slope,
            scale: scale,
            warnings: &builder.warnings
        )
        let measured = try ArealMeasure.measure(
            [polygon],
            scale: scale,
            parameters: parameters,
            options: options,
            slope: plane?.directional,
            warnings: &builder.warnings
        )
        try AreaCalculator.write(measured, parameters: parameters, into: &builder)
        try SlopeApplication.applyToArea(
            netAreaSquareMetres: measured.netArea,
            plane: plane,
            parameters: parameters,
            builder: &builder
        )
        return try builder.finish()
    }
}

// MARK: - Ellipse Area

/// Area and circumference of an ellipse drawn into an axis-aligned page-space box.
///
/// The real-world semi-axes are the singular values of the scale matrix applied to the page-space
/// axes, so a rotated page or a separate-XY calibration produces the right shape rather than the
/// right-looking one. Area is exact (`pi a b`); the circumference is the elliptic integral
/// integrated on the curve to 1e-14 relative — see
/// ``EllipseMath/circumference(pageSemiAxisX:pageSemiAxisY:scale:)`` (T-074).
public struct EllipseAreaCalculator: MeasurementCalculating {
    public let options: MeasurementEngineOptions
    let tool: MeasurementTool

    public init(options: MeasurementEngineOptions = .default) {
        self.init(options: options, tool: .ellipseArea)
    }

    init(options: MeasurementEngineOptions, tool: MeasurementTool) {
        self.options = options
        self.tool = tool
    }

    public func calculate(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters
    ) throws -> MeasurementResult {
        try parameters.validate()
        guard let bounds = geometry.ellipseBox else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: tool,
                expected: .circleOrTwoPoints
            )
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)

        let axes = EllipseMath.realSemiAxes(
            pageSemiAxisX: bounds.width / 2,
            pageSemiAxisY: bounds.height / 2,
            scale: scale
        )
        let area = EllipseMath.area(semiMajor: axes.major, semiMinor: axes.minor)
        // Both tolerances are page-space quantities — `areaFloor` in square points, `pointMerge`
        // in points — so both tests run on the drawn shape, not on metres. Comparing m² with a
        // pt² floor and a metre difference with a point tolerance made the warning and the
        // radius/diameter fields depend on the drawing scale: at 1:1 an axis mismatch of about
        // 0.0028 pt counted as a circle, at 1:100 it did not (R-183).
        let pageArea = EllipseMath.area(semiMajor: bounds.width / 2, semiMinor: bounds.height / 2)
        if pageArea <= options.epsilon.areaFloor {
            builder.warnings.add(.degenerateArea, field: .planArea, detail: "ellipse area ~ 0")
        }
        let circumference = EllipseMath.circumference(
            pageSemiAxisX: bounds.width / 2,
            pageSemiAxisY: bounds.height / 2,
            scale: scale
        )

        let decimalArea = try EngineNumerics.decimal(area)
        try builder.setArea(.planArea, squareMetres: decimalArea)
        try builder.setLength(.circumference, metres: circumference)
        try builder.setLength(.perimeter, metres: circumference)
        // The real axes differ by a length in metres; one page point is at most `stretch`
        // metres in any direction (the scale's largest singular value), so the mismatch is
        // brought back to points by that factor before it meets the point tolerance. Under a
        // uniform scale this is exactly the page-space test |w - h| / 2 <= pointMerge.
        // The difference is the one ``EllipseMath/realSemiAxes`` computes without cancellation,
        // never `major − minor`: those came from a cancelling discriminant, and a drawn circle
        // got Radius and Diameter or not depending on where it sat on the sheet (T-073).
        let stretch = EllipseMath.realSemiAxes(pageSemiAxisX: 1, pageSemiAxisY: 1, scale: scale).major
        if axes.difference <= options.epsilon.pointMerge * stretch {
            try builder.setLength(.radius, metres: axes.major)
            try builder.setLength(.diameter, metres: axes.major * 2)
        }
        // A cutout measured on its own reports what it takes away, and nothing more — the same
        // field set as `PolygonCutoutCalculator`. It used to write `netArea` (and, when sloped,
        // `trueArea`) as well, so the `Area` formula variable and the True Area column added the
        // cutout straight back into the subject total it had just been subtracted from
        // (BH-023). The parent owns its holes and its slope; the cutout row owns neither.
        guard tool != .ellipseCutout else {
            try builder.setArea(.cutoutArea, squareMetres: decimalArea)
            return try builder.finish()
        }
        try builder.setArea(.netArea, squareMetres: decimalArea)
        let plane = try SlopeApplication.arealPlaneIfUniform(
            parameters.slope,
            scale: scale,
            warnings: &builder.warnings
        )
        try SlopeApplication.applyToArea(
            netAreaSquareMetres: decimalArea,
            plane: plane,
            parameters: parameters,
            builder: &builder
        )
        return try builder.finish()
    }
}

// MARK: - Polygon Cutout (spec 12.4)

/// The cutout markup measured on its own: what it takes away from its parent.
///
/// It reports the same number under `planArea` and `cutoutArea`. The parent's `netArea` is *not*
/// computed here, because two records that each hold half of a subtraction are two records that
/// can drift apart; the parent owns its holes and does the subtraction itself.
public struct PolygonCutoutCalculator: MeasurementCalculating {
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
        let areal = GeometryInput.areal(geometry)
        guard let polygon = areal.polygons.first else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .polygonCutout,
                expected: .closedRing
            )
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        if areal.closedImplicitly {
            builder.warnings.add(.openPolygonClosedImplicitly, field: .cutoutArea)
        }
        // The cutout's own holes are never subtracted from it: a hole in a hole is a separate
        // markup, not a nested boolean.
        let outerOnly = PolygonGeometry(outer: polygon.outer)
        let measured = try ArealMeasure.measure(
            [outerOnly],
            scale: scale,
            parameters: MeasurementParameters(
                cutoutPolicy: .ignore,
                perimeterPolicy: .outerOnly,
                display: parameters.display
            ),
            options: options,
            warnings: &builder.warnings
        )
        try builder.setArea(.planArea, squareMetres: measured.planArea)
        try builder.setArea(.cutoutArea, squareMetres: measured.planArea)
        try builder.setLength(.perimeter, metres: measured.perimeter)
        return try builder.finish()
    }
}

/// The elliptical cutout markup measured on its own (spec 12.4).
public struct EllipseCutoutCalculator: MeasurementCalculating {
    public let options: MeasurementEngineOptions
    private let ellipse: EllipseAreaCalculator

    public init(options: MeasurementEngineOptions = .default) {
        self.options = options
        self.ellipse = EllipseAreaCalculator(options: options, tool: .ellipseCutout)
    }

    public func calculate(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters
    ) throws -> MeasurementResult {
        try ellipse.calculate(geometry: geometry, scale: scale, parameters: parameters)
    }
}
