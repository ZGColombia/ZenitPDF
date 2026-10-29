import Foundation
import ZPDFContracts
import ZPDFGeometry

// MARK: - Volume (spec 12.6)

/// Two explicit modes, and no default (ADR-0004 §2):
///
/// ```text
/// verticalDepth          volume = A_plan * depth
/// perpendicularThickness volume = A_plan * sqrt(1 + s^2) * thickness = A_true * thickness
/// ```
///
/// A vertically measured thickness over a plan area is *already* the right volume — the
/// projection cancels — while a thickness measured square to the surface has to be laid over the
/// true area. The two answers differ by exactly `sqrt(1 + s^2)`, which on a 6:12 roof is 11.8 %,
/// and nothing in the drawing distinguishes them. So a volume on a sloped markup requires the
/// mode: guessing here is the single most common source of silent error in takeoff.
///
/// The depth is a ``DecimalQuantity`` in metres, whatever the user typed it in, and the product
/// goes through ``DecimalQuantity/multiplied(by:)`` so the resulting dimension is derived, not
/// asserted: metres squared times metres is metres cubed or it is an error.
public struct VolumeCalculator: MeasurementCalculating {
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
        guard let depth = parameters.depth else {
            throw MeasurementEngineError.measurement(.missingParameter(.depth))
        }
        guard depth.dimension == .length else {
            throw MeasurementEngineError.unitMismatch(
                .dimensionMismatch(expected: .length, actual: depth.dimension)
            )
        }
        let isSloped = parameters.slope.mode != .none
        guard let reference = parameters.volumeDepthReference ?? (isSloped ? nil : .verticalDepth) else {
            throw MeasurementEngineError.measurement(.volumeDepthReferenceRequired)
        }
        // A thickness measured square to the surface has to be laid over the true area, and a
        // true area exists only for a uniform plane: a per-segment or total rise/drop describes
        // a polyline, not a surface. Using the plan area instead was an 11.8 % under-measure on
        // a 6:12 roof with a warning about something else (code review CR-25).
        if reference == .perpendicularThickness, isSloped, parameters.slope.mode != .uniformPlane {
            throw MeasurementEngineError.measurement(.missingParameter(.riseRun))
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        let outcome = try AreaCalculator.measure(
            geometry: geometry,
            scale: scale,
            parameters: parameters,
            options: options,
            tool: .volume,
            builder: &builder
        )
        try SlopeApplication.applyToArea(
            netAreaSquareMetres: outcome.measured.netArea,
            plane: outcome.plane,
            parameters: parameters,
            builder: &builder
        )
        try builder.set(.depth, depth)
        // A negative depth is refused by `MeasurementParameters.validate()` (QUALITY_BAR P11: a
        // negative net quantity is a typed error, never a value — a 50 m² slab at −0.2 m used
        // to store −10 m³ and sum it exactly into the totals, BH-163). A zero depth is a
        // legitimate zero, flagged like every other degenerate quantity rather than refused.
        if depth.value == 0 {
            builder.warnings.add(.degenerateArea, field: .volume, detail: "depth = 0")
        }

        // Plan and true areas are both already stored; the mode only decides which of them the
        // depth multiplies. Neither is overwritten by the other.
        let base: Decimal
        switch reference {
        case .verticalDepth:
            base = outcome.measured.netArea
        case .perpendicularThickness where !isSloped:
            // A flat markup: `sqrt(1 + 0²) = 1`, so the true area is the plan area and a
            // thickness square to the surface is a plumb depth. This used to fall through to the
            // plane lookup below, find no plane (a flat markup has none) and refuse with
            // `unsupportedField(.trueArea)`, so a Volume preset set to perpendicular thickness
            // failed on every flat slab (R-168).
            base = outcome.measured.netArea
        case .perpendicularThickness:
            // A vertical plane has no finite length factor and therefore no true area, so
            // there is nothing to lay a perpendicular thickness over. Falling back to the plan
            // area here reported a plan-area volume for a surface whose true area is
            // undefined — the exact fallback the CR-25 rule above refuses for the rise/drop
            // modes (BH-558). The refusal names the field the mode needed and did not get.
            guard let factor = outcome.plane?.resolution.trueLengthFactor else {
                throw MeasurementEngineError.measurement(.unsupportedField(.trueArea))
            }
            // Normalising multiplication (CR-23, IM-072): the product of two policy-normalised
            // decimals can still exceed the significance the aggregation path can add exactly
            // once the depth multiplies it too.
            base = try EngineNumerics.product(outcome.measured.netArea, try EngineNumerics.decimal(factor))
        }
        // The area carries the policy's 15 digits and the depth is whatever the person typed;
        // their raw product carries more than the policy allows, and the ledger's exact
        // addition then refuses two volumes it would add as areas (code review CR-23). The
        // extra digits are noise from the Double geometry stage, not information — the
        // normalising product takes them off (IM-072).
        try builder.set(.volume, try EngineNumerics.product(DecimalQuantity.area(base), depth))
        return try builder.finish()
    }
}

// MARK: - Wall Area (spec 12.7)

/// ```text
/// wallArea    = trueLength(selected edges) × wallHeight            (height measured vertically)
/// wallArea    = trueLength(selected edges) × (h_start + h_end) / 2 (sloping top edge)
/// netWallArea = wallArea - openings
/// ```
///
/// The base length is the polygon perimeter when the markup is an area, and the polyline length
/// when it is a line — the "selected length or perimeter" of the spec, decided by what was drawn
/// rather than by a mode the user has to remember to set.
///
/// ADR-0004 §2 fixes two things here. The base length is the **true** length, per segment, so a
/// wall following a sloping site does not gain area on the stretches that run along the contour.
/// And the height is measured **vertically**: a gable wall whose top edge slopes is a trapezoid,
/// `(h_start + h_end) / 2 × L`, not a rectangle scaled by a slope factor — those are different
/// numbers and only the first one is the wall.
public struct WallAreaCalculator: MeasurementCalculating {
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
        guard let height = parameters.height else {
            throw MeasurementEngineError.measurement(.missingParameter(.height))
        }
        guard height.dimension == .length else {
            throw MeasurementEngineError.unitMismatch(
                .dimensionMismatch(expected: .length, actual: height.dimension)
            )
        }

        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)

        // A wall area is a length times a height, so ADR-0004 requires a fall line before a
        // slope may touch it.
        let plane = parameters.slope.mode == .uniformPlane
            ? try SlopeApplication.directionalPlane(
                parameters.slope,
                scale: scale,
                field: .wallArea,
                warnings: &builder.warnings
            )
            : nil
        if let plane { try builder.setSlope(plane.resolution) }

        let planBaseLength: Decimal
        let trueBaseLength: Decimal
        if !geometry.polygons.isEmpty {
            // A rise/drop describes a polyline: one rise per edge in the order they were drawn,
            // or one fall across the whole run. A closed ring has neither — its edges come out
            // of the cutout pipeline cleaned and possibly reordered, and a single fall around a
            // loop returns to where it started. The slope on a wall drawn as an area must be a
            // uniform plane; anything else used to be accepted and silently discarded, so a
            // 3 m wall around a 10 m run with a 2 m total drop measured 30 m² instead of
            // 3 * sqrt(104) = 30.59 m² (BH-559).
            if parameters.slope.mode == .perSegmentRiseDrop || parameters.slope.mode == .totalRiseDrop {
                throw MeasurementEngineError.measurement(.missingParameter(.riseRun))
            }
            let measured = try ArealMeasure.measure(
                geometry.polygons,
                scale: scale,
                parameters: parameters,
                options: options,
                slope: plane?.directional,
                warnings: &builder.warnings
            )
            planBaseLength = try EngineNumerics.decimal(measured.perimeter)
            trueBaseLength = try EngineNumerics.decimal(measured.truePerimeter ?? measured.perimeter)
            try builder.setLength(.perimeter, metres: planBaseLength)
            if measured.truePerimeter != nil {
                try builder.setLength(.truePerimeter, metres: trueBaseLength)
            }
            try builder.setArea(.planArea, squareMetres: measured.planArea)
        } else {
            let linear = GeometryInput.linear(geometry)
            guard !linear.isEmpty else {
                throw MeasurementEngineError.unsupportedGeometry(
                    tool: .wallArea,
                    expected: .atLeastTwoPoints
                )
            }
            let measured = try LinearMeasure.measure(linear, scale: scale)
            planBaseLength = try EngineNumerics.decimal(measured.totalMetres)
            try builder.setLength(.planLength, metres: planBaseLength)
            switch parameters.slope.mode {
            case .none:
                trueBaseLength = planBaseLength
            case .uniformPlane:
                if let directional = plane?.directional {
                    trueBaseLength = try EngineNumerics.decimal(measured.trueLength(under: directional))
                    try builder.setLength(.trueLength, metres: trueBaseLength)
                } else {
                    // Vertical plane: no finite factor exists; `setSlope` above has warned.
                    trueBaseLength = planBaseLength
                }
            case .perSegmentRiseDrop, .totalRiseDrop:
                // The same rise/drop application every length tool uses, so "true length"
                // means one thing (BH-559). It writes `trueLength`, `rise`, `run` and the
                // slope fields, and the wall stands on that true length.
                try SlopeApplication.applyToLength(
                    measured: measured,
                    parameters: parameters,
                    scale: scale,
                    builder: &builder
                )
                guard let applied = builder.values[.trueLength] else {
                    throw MeasurementEngineError.measurement(.unsupportedField(.trueLength))
                }
                trueBaseLength = applied.value
            }
        }

        try builder.set(.height, height)
        // A sloping top edge is a trapezoid, not a rectangle with a factor on it.
        let effectiveHeight: DecimalQuantity
        if let heightAtEnd = parameters.heightAtEnd {
            effectiveHeight = .length((height.value + heightAtEnd.value) / 2)
        } else {
            effectiveHeight = height
        }
        // Normalising products (CR-23, IM-072): a 15-digit length times a typed height is not
        // a value the ledger can add exactly.
        let wallArea = try EngineNumerics.product(DecimalQuantity.length(trueBaseLength), effectiveHeight)
        let planWallArea = try EngineNumerics.product(DecimalQuantity.length(planBaseLength), effectiveHeight)
        try builder.set(.planWallArea, planWallArea)
        try builder.set(.wallArea, wallArea)

        // Openings arrive as square metres and are summed in Decimal: they are an aggregate,
        // not geometry, so there is no Double stage for them to lose significance in.
        let openings = parameters.openingAreas.reduce(Decimal.zero, +)
        let net = wallArea.value - openings
        // QUALITY_BAR P11: a negative net area is a typed error, never a value. 40 m² of wall
        // with 100 m² of openings used to store −60 m² (code review CR-27); openings that
        // exactly consume the wall are a legitimate zero and are flagged, not refused.
        guard net >= 0 else {
            throw MeasurementEngineError.measurement(.negativeNetArea(.netWallArea))
        }
        try builder.setArea(.netWallArea, squareMetres: net)
        if !parameters.openingAreas.isEmpty {
            try builder.setArea(.cutoutArea, squareMetres: openings)
        }
        if net == 0 {
            builder.warnings.add(
                .degenerateArea,
                field: .netWallArea,
                detail: "openings (\(openings)) equal the gross wall area (\(wallArea.value))"
            )
        }
        return try builder.finish()
    }
}

// MARK: - Slope (spec 12.8)

/// Reports a slope as ratio, percent and angle. Informational: it writes no summed column.
///
/// `run == 0` produces a result with the angle at ±90° and a
/// ``MeasurementWarning/Code/verticalSlopeUndefinedRun`` warning; `slopeRatio` and `slopePercent`
/// are absent rather than infinite.
public struct SlopeCalculator: MeasurementCalculating {
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
        guard let expression = parameters.slope.magnitude else {
            throw MeasurementEngineError.measurement(.missingParameter(.riseRun))
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)

        let resolution = try SlopeResolution.resolve(expression)
        try builder.setSlope(resolution)
        SlopeApplication.noteMagnitude(parameters.slope, warnings: &builder.warnings)
        // A `riseOverRun` pair is "in the same length unit", and that unit is not known here:
        // `6:12` is a pitch, `1.5 over 3` may be metres or feet. Writing the pair into the
        // metre-dimensioned `rise` and `run` fields showed a 6:12 roof as "6 m / 12 m" in the
        // ledger and the archive (code review CR-22). The pair is fully represented by the
        // ratio, percent and angle; `rise` and `run` in metres come only from a rise/drop
        // measurement, where they really are metres.

        // The drawn run only says where the slope is read. It is not a quantity: writing it
        // into `planLength` (and its stretched length into `trueLength`) added a roof-pitch
        // annotation to the subject's Plan Length and True Length totals (formula version 4,
        // ADR-0019). A sloped run that *is* a quantity is the True Sloped Length tool's job.
        _ = geometry
        return try builder.finish()
    }
}

// MARK: - Rise/Drop (spec 12.9)

/// Per-segment and total-applied rise/drop, as two explicit modes.
///
/// ```text
/// per segment: trueSegment = sqrt(planSegment^2 + riseDrop^2); total = Σ trueSegment
/// total:       total       = sqrt(planLength^2  + totalRiseDrop^2)
/// ```
public struct RiseDropCalculator: MeasurementCalculating {
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
        guard parameters.slope.mode == .perSegmentRiseDrop
            || parameters.slope.mode == .totalRiseDrop else {
            throw MeasurementEngineError.measurement(.missingParameter(.perSegmentRiseDrop))
        }
        let linear = GeometryInput.linear(geometry)
        guard !linear.isEmpty else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .riseDrop,
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

// MARK: - True Sloped Length (spec 12.8)

/// `trueLength = Σ sqrt(|d_i|² + (s · (d_i · û))²)` (ADR-0004 §2).
///
/// Not `planLength × sqrt(1 + s²)`: that is the answer for a line running straight up the fall
/// line, and it over-measures every edge that does not.
public struct TrueSlopedLengthCalculator: MeasurementCalculating {
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
        guard parameters.slope.mode != .none else {
            throw MeasurementEngineError.measurement(.missingParameter(.riseRun))
        }
        let linear = GeometryInput.linear(geometry)
        guard !linear.isEmpty else {
            throw MeasurementEngineError.unsupportedGeometry(
                tool: .trueSlopedLength,
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

// MARK: - True Sloped Area (spec 12.8)

/// `trueArea = netArea × sqrt(1 + slopeRatio²)`, applied once to the net area (spec 12.8).
///
/// Area is the one quantity the scalar factor is exactly right for, and it needs no azimuth.
public struct TrueSlopedAreaCalculator: MeasurementCalculating {
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
        guard parameters.slope.mode == .uniformPlane, parameters.slope.magnitude != nil else {
            throw MeasurementEngineError.measurement(.missingParameter(.riseRun))
        }
        var builder = MeasurementBuilder(display: parameters.display)
        builder.warnings.inspect(scale: scale, options: options)
        let outcome = try AreaCalculator.measure(
            geometry: geometry,
            scale: scale,
            parameters: parameters,
            options: options,
            tool: .trueSlopedArea,
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
}
