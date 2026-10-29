import Foundation
import ZPDFContracts

/// Applies whichever slope mode the caller chose to a plan quantity (ADR-0004, spec 12.8, 12.9).
///
/// All three sources are implemented here so that "true length" means the same thing in the
/// Length tool, the True Sloped Length tool, the Perimeter tool and the Rise/Drop tool. A tool
/// decides *whether* to apply slope; it never decides *how*.
///
/// The one rule this file exists to enforce: a length on a sloped plane elongates per segment by
/// `sqrt(|d|^2 + (s (d . u))^2)`, never by a blanket `sqrt(1 + s^2)`. Area is the exception — it
/// really is direction-independent — and it is handled by ``applyToArea(netAreaSquareMetres:parameters:builder:)``.
enum SlopeApplication {

    /// A resolved uniform plane: the scalar fields the ledger shows, plus the fall line when one
    /// exists.
    struct Plane: Sendable {
        let resolution: SlopeResolution
        /// `nil` when the plane is vertical (no finite factor exists) or when no azimuth has been
        /// established yet. Which of the two it was is decided by the caller, because an area is
        /// allowed to proceed without an azimuth and a length is not.
        let directional: DirectionalSlope?
    }

    // MARK: - Resolution

    /// Resolves a uniform plane for a **directional** quantity: a length, a perimeter or a wall.
    ///
    /// - Throws: ``MeasurementError/slopeAzimuthRequired(_:)`` when no azimuth has been
    ///   established. There is deliberately no scalar fallback here — falling back would
    ///   over-measure every eave, ridge and contour line in the drawing, silently, which is the
    ///   failure mode ADR-0004 exists to remove.
    static func directionalPlane(
        _ specification: SlopeSpecification,
        scale: ScaleTransform,
        field: MeasurementField,
        warnings: inout WarningLog
    ) throws -> Plane {
        guard let expression = specification.magnitude else {
            throw MeasurementEngineError.measurement(.missingParameter(.riseRun))
        }
        let azimuth = try specification.requireAzimuth(for: field)
        let resolution = try SlopeResolution.resolve(expression)
        noteMagnitude(specification, warnings: &warnings)
        guard let ratio = resolution.ratio, let factor = resolution.trueLengthFactor else {
            // Vertical: there is no finite length factor. The warning is raised by setSlope.
            return Plane(resolution: resolution, directional: nil)
        }
        let directional = try DirectionalSlope.resolve(
            ratio: NumericPolicy.double(from: ratio),
            areaFactor: factor,
            azimuth: azimuth,
            scale: scale
        )
        return Plane(resolution: resolution, directional: directional)
    }

    /// Resolves a uniform plane for an **areal** quantity, where the azimuth is optional.
    ///
    /// Orthographic projection scales every planar region's area by `cos(theta)` regardless of
    /// the region's shape or orientation within the plane, so `A_true = A_plan * sqrt(1 + s^2)`
    /// is exact with no direction at all. The boundary of that area is a different matter: when
    /// no azimuth exists the true perimeter is *absent* and a warning says so, rather than being
    /// filled in with a scalar guess.
    static func arealPlane(
        _ specification: SlopeSpecification,
        scale: ScaleTransform,
        warnings: inout WarningLog
    ) throws -> Plane {
        guard let expression = specification.magnitude else {
            throw MeasurementEngineError.measurement(.missingParameter(.riseRun))
        }
        let resolution = try SlopeResolution.resolve(expression)
        noteMagnitude(specification, warnings: &warnings)
        guard let azimuth = specification.azimuth else {
            warnings.add(
                .slopeAzimuthMissingForBoundary,
                field: .truePerimeter,
                detail: "no fall-line azimuth; the true area is exact, the true perimeter is not reported"
            )
            return Plane(resolution: resolution, directional: nil)
        }
        guard let ratio = resolution.ratio, let factor = resolution.trueLengthFactor else {
            return Plane(resolution: resolution, directional: nil)
        }
        let directional = try DirectionalSlope.resolve(
            ratio: NumericPolicy.double(from: ratio),
            areaFactor: factor,
            azimuth: azimuth,
            scale: scale
        )
        return Plane(resolution: resolution, directional: directional)
    }

    /// ``arealPlane(_:scale:warnings:)`` when the specification is a uniform plane, `nil` for
    /// every other mode. The one spelling of "resolve the plane only if there is one" that Area,
    /// Rectangle Area and Ellipse Area used to each write out by hand (IM-066).
    static func arealPlaneIfUniform(
        _ specification: SlopeSpecification,
        scale: ScaleTransform,
        warnings: inout WarningLog
    ) throws -> Plane? {
        guard specification.mode == .uniformPlane else { return nil }
        return try arealPlane(specification, scale: scale, warnings: &warnings)
    }

    /// ADR-0004 §5: above 100 % is accepted but flagged, since it is usually a units mistake.
    static func noteMagnitude(_ specification: SlopeSpecification, warnings: inout WarningLog) {
        guard specification.exceedsOneHundredPercent else { return }
        warnings.add(
            .slopeMagnitudeAboveOneHundredPercent,
            field: .slopeRatio,
            detail: "slope exceeds 100 % (45 degrees); accepted, but check the units"
        )
    }

    // MARK: - Lengths

    /// Adds `trueLength` and the slope fields to a result that already has `planLength`.
    ///
    /// `measured` carries the real-space delta of every edge, which is what makes the
    /// per-segment rule possible: a blanket factor cannot tell an eave from a rake.
    static func applyToLength(
        measured: LinearMeasure.Result,
        parameters: MeasurementParameters,
        scale: ScaleTransform,
        field: MeasurementField = .trueLength,
        builder: inout MeasurementBuilder
    ) throws {
        switch parameters.slope.mode {
        case .none:
            return

        case .uniformPlane:
            let plane = try directionalPlane(
                parameters.slope,
                scale: scale,
                field: field,
                warnings: &builder.warnings
            )
            try builder.setSlope(plane.resolution)
            guard let directional = plane.directional else { return }
            try builder.setLength(field, metres: measured.trueLength(under: directional))

        case .perSegmentRiseDrop:
            guard !parameters.slope.perSegmentRiseDrop.isEmpty else {
                throw MeasurementEngineError.measurement(.missingParameter(.perSegmentRiseDrop))
            }
            // Every piece of the run takes a rise, in the order the pieces appear: the chain in
            // drawn order with its arcs where they are drawn, then loose segments, then loose
            // arcs (S-110; the rises used to go to every straight edge first and then to the
            // arcs, so an arc in the middle of a chain took the rise of the edge after it).
            // Handing only the straight edges over left every arc out of the true length and
            // the run, so a 10 m edge plus a 5 m arc reported a true length of 10.05 m against
            // a plan length of 15 m, while the total mode on the same drawing included the arc
            // (BH-560, BH-566). The plan length below is the compensated sum of the same pieces
            // and is therefore identical to `measured.totalMetres`.
            let riseDrop = RiseDropMeasure.perSegment(
                segmentLengths: measured.pieceLengths,
                riseDrops: parameters.slope.perSegmentRiseDrop,
                warnings: &builder.warnings
            )
            try applyRiseDrop(riseDrop, field: field, builder: &builder)

        case .totalRiseDrop:
            guard let total = parameters.slope.totalRiseDrop else {
                throw MeasurementEngineError.measurement(.missingParameter(.totalRiseDrop))
            }
            let riseDrop = RiseDropMeasure.total(
                planLengthMetres: measured.totalMetres,
                totalRiseDrop: total
            )
            try applyRiseDrop(riseDrop, field: field, builder: &builder)
        }
    }

    private static func applyRiseDrop(
        _ measured: RiseDropMeasure.Result,
        field: MeasurementField,
        builder: inout MeasurementBuilder
    ) throws {
        try builder.setLength(field, metres: measured.trueLengthMetres)
        try builder.setLength(.rise, metres: measured.riseMetres)
        try builder.setLength(.run, metres: measured.planLengthMetres)
        let resolution = try SlopeResolution.resolve(
            riseMetres: measured.riseMetres,
            runMetres: measured.planLengthMetres
        )
        try builder.setSlope(resolution)
    }

    // MARK: - Areas

    /// `trueArea = netArea * sqrt(1 + slopeRatio^2)` (spec 12.8, ADR-0004 §2).
    ///
    /// This is the one quantity the scalar rule gets right, and the one place the scalar factor
    /// is still correct. A plan area on a sloped plane is the orthographic shadow of the real
    /// surface, and the shadow shrinks every planar region by `cos(theta)` no matter how the
    /// region is shaped or which way it is turned within the plane. The factor is applied **once**
    /// to the net area, so a roof plane with two dormer openings reports the true area of the
    /// surface that actually exists rather than the true area of the outline minus the plan area
    /// of the holes.
    ///
    /// Only a uniform plane has a true area. A rise/drop specification describes a polyline,
    /// not a surface, so under those modes no true area is produced and no slope fields are
    /// written; a caller that *needs* the true area (a perpendicular thickness) refuses
    /// beforehand rather than falling back to the plan area (code review CR-25).
    static func applyToArea(
        netAreaSquareMetres: Decimal,
        plane: Plane?,
        parameters: MeasurementParameters,
        builder: inout MeasurementBuilder
    ) throws {
        guard parameters.slope.mode == .uniformPlane, let plane else { return }
        try builder.setSlope(plane.resolution)
        guard let factor = plane.resolution.trueLengthFactor else { return }
        // The product goes through the one normalising multiplication (CR-23, IM-072): the
        // net area and the factor each carry the policy's 15 digits, so their raw product
        // carries up to 30, and the ledger's exact-or-refuse addition then refused two true
        // areas it would happily add as net areas.
        try builder.setArea(
            .trueArea,
            squareMetres: try EngineNumerics.product(netAreaSquareMetres, try EngineNumerics.decimal(factor))
        )
    }
}
