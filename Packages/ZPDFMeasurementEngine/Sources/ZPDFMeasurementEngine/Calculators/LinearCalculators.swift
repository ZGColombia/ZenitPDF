import Foundation
import ZPDFContracts
import ZPDFGeometry

// MARK: - Length (spec 12.2)

/// `length = Σ ||r_i+1 - r_i||`, evaluated in real-world metres.
///
/// Free points form one open chain; loose segments and arcs each contribute their own length, so
/// a markup that mixes a traced polyline with two dimension lines measures all of it.
public struct LengthCalculator: MeasurementCalculating {
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
        let linear = GeometryInput.linear(geometry)
        guard !linear.isEmpty else {
            throw MeasurementEngineError.unsupportedGeometry(tool: .length, expected: .atLeastTwoPoints)
        }
        let measured = try LinearMeasure.measure(linear, scale: scale)

        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        try builder.setLength(.planLength, metres: measured.totalMetres)
        try SlopeApplication.applyToLength(
            measured: measured,
            parameters: parameters,
            scale: scale,
            builder: &builder
        )
        return try builder.finish()
    }
}

// MARK: - Dimension

/// A single measured distance between two points: the annotated dimension line.
///
/// It differs from Length by refusing more than one edge. A dimension that quietly summed three
/// segments would be indistinguishable from a polylength on the ledger.
public struct DimensionCalculator: MeasurementCalculating {
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
        let segment: SegmentGeometry
        if geometry.points.count == 2 {
            segment = SegmentGeometry(start: geometry.points[0], end: geometry.points[1])
        } else if geometry.segments.count == 1, geometry.points.isEmpty {
            segment = geometry.segments[0]
        } else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .dimension,
                expected: .exactlyOneSegment
            )
        }

        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        let measured = try LinearMeasure.measure(
            GeometryInput.Linear(polyline: [], isClosed: false, segments: [segment], arcs: []),
            scale: scale
        )
        guard measured.totalMetres.isFinite else {
            throw MeasurementEngineError.measurement(.nonFiniteCoordinate)
        }
        try builder.setLength(.planLength, metres: measured.totalMetres)
        try SlopeApplication.applyToLength(
            measured: measured,
            parameters: parameters,
            scale: scale,
            builder: &builder
        )
        return try builder.finish()
    }
}

// MARK: - Polylength

/// A chained multi-segment length. Same formula as Length, but it requires a chain of at least
/// two vertices.
///
/// It deliberately writes no `.count`. ``MeasurementField/count`` is "number of count points",
/// and the ledger's Count column sums that field over every row regardless of tool, so a
/// segment count stored there added seven phantom pieces to the Count total for one
/// seven-segment run (BH-024). The segment count is a property of the geometry, not a quantity.
public struct PolylengthCalculator: MeasurementCalculating {
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
        let linear = GeometryInput.linear(geometry)
        guard linear.polyline.count >= 2 || linear.segments.count >= 1 else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .polylength,
                expected: .atLeastTwoPoints
            )
        }
        let measured = try LinearMeasure.measure(linear, scale: scale)

        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        try builder.setLength(.planLength, metres: measured.totalMetres)
        try SlopeApplication.applyToLength(
            measured: measured,
            parameters: parameters,
            scale: scale,
            builder: &builder
        )
        return try builder.finish()
    }
}

// MARK: - Perimeter (spec 12.5)

/// `outerPerimeter = Σ outerEdges`, plus the cutout edges when the policy asks for them.
public struct PerimeterCalculator: MeasurementCalculating {
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
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)

        let areal = GeometryInput.areal(geometry)
        guard !areal.polygons.isEmpty else {
            throw MeasurementEngineError.unsupportedGeometry(tool: .perimeter, expected: .closedRing)
        }
        if areal.closedImplicitly {
            builder.warnings.add(.openPolygonClosedImplicitly, field: .perimeter)
        }
        // A perimeter is a length, so ADR-0004 requires a fall line before a slope may touch it.
        let plane = parameters.slope.mode == .uniformPlane
            ? try SlopeApplication.directionalPlane(
                parameters.slope,
                scale: scale,
                field: .truePerimeter,
                warnings: &builder.warnings
            )
            : nil
        let measured = try ArealMeasure.measure(
            areal.polygons,
            scale: scale,
            parameters: parameters,
            options: options,
            slope: plane?.directional,
            warnings: &builder.warnings
        )
        try builder.setLength(.perimeter, metres: measured.perimeter)
        try builder.setArea(.planArea, squareMetres: measured.planArea)
        try builder.setArea(.netArea, squareMetres: measured.netArea)
        if let truePerimeter = measured.truePerimeter {
            try builder.setLength(.truePerimeter, metres: truePerimeter)
        }
        try SlopeApplication.applyToArea(
            netAreaSquareMetres: measured.netArea,
            plane: plane,
            parameters: parameters,
            builder: &builder
        )
        return try builder.finish()
    }
}

// MARK: - Arc Length (spec 12.12)

/// `arcLength = radius × centralAngleRadians` under a uniform scale; under any other scale the
/// arc maps to an arc of an ellipse, measured by quadrature on the curve (T-075).
///
/// Accepts an explicit arc, or three points read as start / on-curve / end, which is how an arc
/// is actually drawn in the viewport. Consecutive duplicates are collapsed (and said so); any
/// other count is refused with ``MeasurementEngineError/GeometryRequirement/threePoints``. A
/// fourth point used to be dropped without a word, so the value ignored points the person had
/// placed (X-042). An Arc Length saved that way opens as the three it was measured on
/// (``storedGeometry(_:options:)``).
///
/// The arcs are measured by ``LinearMeasure``, the one arc-length rule of the engine: `r·θ·s` on
/// a uniform scale, ``ArcLengthQuadrature`` otherwise. This tool used to refuse every separate
/// X/Y scale with `directionRequiredForNonUniformScale` while Length measured the same arc on the
/// same sheet (S-106). Radius and Angle are written only under a uniform scale: a mapped ellipse
/// has neither.
public struct ArcLengthCalculator: MeasurementCalculating {
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
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        let arcs: [ArcGeometry]
        if !geometry.arcs.isEmpty {
            arcs = geometry.arcs
        } else if geometry.points.isEmpty {
            throw MeasurementEngineError.unsupportedGeometry(tool: .arcLength, expected: .arc)
        } else {
            let cleanup = try Self.distinctPoints(geometry.points, options: options)
            guard cleanup.points.count == 3 else {
                throw MeasurementEngineError.unsupportedGeometry(tool: .arcLength, expected: .threePoints)
            }
            if cleanup.removedDuplicates > 0 {
                builder.warnings.add(.duplicatePointsCollapsed, detail: "removed=\(cleanup.removedDuplicates)")
            }
            let points = cleanup.points
            arcs = [
                try SegmentMath.arc(
                    through: points[0],
                    points[1],
                    points[2],
                    collinearityThreshold: options.collinearityThreshold
                )
            ]
        }

        let measured = try LinearMeasure.measure(
            GeometryInput.Linear(polyline: [], isClosed: false, segments: [], arcs: arcs),
            scale: scale
        )
        let total = measured.totalMetres
        try builder.setLength(.arcLength, metres: total)
        try builder.setLength(.planLength, metres: total)
        if arcs.count == 1, scale.isUniform {
            try builder.setLength(.radius, metres: arcs[0].radius * scale.matrix.metresPerPointX)
            try builder.setAngle(.angle, radians: abs(arcs[0].sweepAngle))
        }
        return try builder.finish()
    }

    /// The point list with consecutive duplicates collapsed, within the engine's
    /// ``GeometryEpsilon/pointMerge`` — the one rule ``calculate(geometry:scale:parameters:)``
    /// and ``storedGeometry(_:options:)`` read.
    static func distinctPoints(_ points: [PDFPoint], options: MeasurementEngineOptions) throws -> PolygonCleanupResult {
        try PolygonCleanup.cleanup(
            points,
            options: PolygonCleanupOptions(epsilon: options.epsilon, isClosedRing: false, removesCollinearVertices: false)
        )
    }

    /// The geometry a stored Arc Length opens with (X-042).
    ///
    /// Before X-042 a point-form Arc Length could be committed with more than three points, and the
    /// engine measured the arc through the first three and ignored the rest. Measured again today
    /// it would be refused, and a refusal on open is the damaged-file error — so it opens as its
    /// first three distinct points instead: exactly the arc its stored value was measured on, so
    /// the number does not move, and the drawing and the snap now show that arc. Any other
    /// geometry is returned unchanged, as is one with fewer than three distinct points (which the
    /// old engine could not have measured either).
    public static func storedGeometry(
        _ geometry: MeasurementGeometry,
        options: MeasurementEngineOptions = .default
    ) -> MeasurementGeometry {
        guard geometry.arcs.isEmpty, geometry.points.count > 3,
              let distinct = try? distinctPoints(geometry.points, options: options).points,
              distinct.count >= 3 else { return geometry }
        var repaired = geometry
        repaired.points = Array(distinct.prefix(3))
        repaired.pointBulges = nil
        return repaired
    }

    /// The geometry an Arc Length is kept with once it is measured (X-042, cycle 2).
    ///
    /// ``calculate(geometry:scale:parameters:)`` collapses consecutive duplicates — a doubled
    /// click — and measures the three points left. A record that kept the doubled point was
    /// measured as that arc but drawn and snapped as its chords
    /// (``MarkupRecord/drawnPointChain`` draws an arc for exactly three stored points). Here a
    /// point list that collapses to **exactly** three points becomes those three, so what is
    /// stored is what is measured, drawn and snapped. Any other geometry is returned unchanged,
    /// for `calculate` to measure or refuse: four distinct points stay four and are refused.
    public static func measuredGeometry(
        _ geometry: MeasurementGeometry,
        options: MeasurementEngineOptions = .default
    ) -> MeasurementGeometry {
        guard geometry.arcs.isEmpty, geometry.points.count > 3,
              let distinct = try? distinctPoints(geometry.points, options: options).points,
              distinct.count == 3 else { return geometry }
        var collapsed = geometry
        collapsed.points = distinct
        collapsed.pointBulges = nil
        return collapsed
    }
}
