import Foundation

/// The measurement tools the product ships (spec 12.1).
public enum MeasurementTool: String, Codable, Hashable, Sendable, CaseIterable {
    case length
    case dimension
    case polylength
    case perimeter
    case area
    case rectangleArea
    case ellipseArea
    case polygonCutout
    case ellipseCutout
    case volume
    case wallArea
    case count
    case radius
    case diameter
    case threePointCircle
    case angle
    case slope
    case riseDrop
    case trueSlopedLength
    case trueSlopedArea
    case arcLength
    case temporaryMeasure
}

/// Every quantity a measurement can produce (spec 12, 15.2).
///
/// The field is the key of ``MeasurementResult/values``, so this enum is the frozen list of
/// things the ledger can show and a formula can reference. Each case names its own dimension,
/// which is what keeps a slope percent from ever being added to a wall area.
public enum MeasurementField: String, Codable, Hashable, Sendable, CaseIterable {
    /// Number of count points. Dimensionless.
    case count
    /// Length as drawn on the plan, in metres.
    case planLength
    /// Length after slope or rise/drop is applied, in metres (spec 12.8, 12.9).
    case trueLength
    /// Boundary length of an area as drawn on the plan, in metres (spec 12.5).
    case perimeter
    /// Boundary length of an area on the sloped surface, in metres (ADR-0004 §2). Summed with
    /// the per-segment rule, so an eave contributes its plan length and a rake contributes more.
    case truePerimeter
    /// Area as drawn on the plan, in square metres, before cutouts.
    case planArea
    /// Plan area after slope is applied, in square metres (spec 12.8).
    case trueArea
    /// Plan area minus the union of its cutouts, in square metres (spec 12.4).
    case netArea
    /// Total area of the cutouts subtracted, in square metres.
    case cutoutArea
    /// Wall area over the plan base length, in square metres (spec 12.7).
    case planWallArea
    /// Wall area over the true base length, in square metres (spec 12.7, ADR-0004 §2). Equal to
    /// ``planWallArea`` when the markup is flat.
    case wallArea
    /// Wall area minus openings, in square metres (spec 12.7).
    case netWallArea
    /// Volume, in cubic metres (spec 12.6).
    case volume
    /// Vertical component of a slope, in metres.
    case rise
    /// Horizontal component of a slope, in metres.
    case run
    /// `rise / run`. Dimensionless.
    case slopeRatio
    /// `100 * rise / run`. Dimensionless.
    case slopePercent
    /// Slope angle from horizontal, in radians.
    case slopeAngle
    /// Extrusion depth used for volume, in metres.
    case depth
    /// Wall height used for wall area, in metres.
    case height
    /// Circle radius, in metres.
    case radius
    /// Circle diameter, in metres.
    case diameter
    /// Circle circumference, in metres.
    case circumference
    /// Arc length, in metres (spec 12.12).
    case arcLength
    /// A measured angle, in radians (spec 12.10).
    case angle

    /// The dimension every value of this field carries.
    ///
    /// `slopeRatio` and `slopePercent` are ``QuantityDimension/ratio``, not ``QuantityDimension/count``:
    /// a slope is a factor, and it must never sum into a count total (ADR-0014).
    public var dimension: QuantityDimension {
        switch self {
        case .count:
            .count
        case .slopeRatio, .slopePercent:
            .ratio
        case .planLength, .trueLength, .perimeter, .truePerimeter, .rise, .run,
             .depth, .height, .radius, .diameter, .circumference, .arcLength:
            .length
        case .planArea, .trueArea, .netArea, .cutoutArea, .planWallArea, .wallArea, .netWallArea:
            .area
        case .volume:
            .volume
        case .slopeAngle, .angle:
            .angle
        }
    }
}

extension MeasurementField: CodingKeyRepresentable {
    public var codingKey: any CodingKey {
        ContractIdentifierCodingKey(stringValue: rawValue)
    }

    public init?<Key>(codingKey: Key) where Key: CodingKey {
        self.init(rawValue: codingKey.stringValue)
    }
}

/// What to do with cutouts when an area is computed (spec 12.4).
public enum CutoutPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Net area = outer area - union(cutouts). The default.
    case subtractFromArea
    /// Cutouts are drawn but do not change the parent's quantity.
    case ignore
    /// Cutouts are subtracted, and each cutout's own area is also reported, read-only, in the
    /// ledger's `Cutout Area` column on its row. It is never summed: a cutout is part of its
    /// parent, not a quantity of its own (ADR-0018).
    case subtractAndReportSeparately
}

/// Which edges count towards a perimeter (spec 12.5).
public enum PerimeterPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Outer ring only.
    case outerOnly
    /// Outer ring plus every cutout edge.
    case outerPlusCutoutEdges
}

/// The display units and precision a measurement is presented with.
public struct DisplayUnitPolicy: Codable, Hashable, Sendable {
    public var length: LengthUnit
    public var area: AreaUnit
    public var volume: VolumeUnit
    public var angle: AngleUnit
    public var slopeForm: SlopeForm
    public var precision: PrecisionMode

    public init(
        length: LengthUnit = .metre,
        area: AreaUnit = .squareMetre,
        volume: VolumeUnit = .cubicMetre,
        angle: AngleUnit = .degree,
        slopeForm: SlopeForm = .percent,
        precision: PrecisionMode = .defaultMetric
    ) {
        self.length = length
        self.area = area
        self.volume = volume
        self.angle = angle
        self.slopeForm = slopeForm
        self.precision = precision
    }

    public static let metric = DisplayUnitPolicy()

    public static let imperial = DisplayUnitPolicy(
        length: .foot,
        area: .squareFoot,
        volume: .cubicYard,
        angle: .degree,
        slopeForm: .ratioNToOne,
        precision: .defaultImperial
    )
}

/// Everything a measurement needs beyond geometry and scale (spec 12.6-12.9, ADR-0004).
///
/// Every length-like parameter is a ``DecimalQuantity`` in SI base units, so a depth typed in
/// inches and a depth typed in millimetres are the same value by the time the engine sees them.
public struct MeasurementParameters: Codable, Hashable, Sendable {
    /// Extrusion depth or thickness for Volume (spec 12.6). Dimension: length.
    public var depth: DecimalQuantity?
    /// Wall height for Wall Area, measured vertically (spec 12.7). Dimension: length.
    public var height: DecimalQuantity?
    /// Wall height at the far end of the run, when the top edge slopes (ADR-0004 §2). When it is
    /// present the wall area uses the trapezoid form `(h_start + h_end) / 2 * trueLength`, which
    /// is the actual area of a gable wall; a slope factor is not the same number and is wrong.
    /// Dimension: length.
    public var heightAtEnd: DecimalQuantity?
    /// The slope: magnitude, fall-line azimuth and mode (ADR-0004 §1).
    public var slope: SlopeSpecification
    /// Whether a volume's depth was measured vertically or perpendicular to the sloped surface
    /// (ADR-0004 §2). Required for a volume on a sloped markup; there is no default.
    public var volumeDepthReference: VolumeDepthReference?
    /// Cutout handling.
    public var cutoutPolicy: CutoutPolicy
    /// Perimeter edge selection.
    public var perimeterPolicy: PerimeterPolicy
    /// Areas of openings subtracted from a wall area, in square metres (spec 12.7).
    public var openingAreas: [Decimal]
    /// Display units and precision. Metadata only; it never changes a stored value.
    public var display: DisplayUnitPolicy
    /// This markup's own display units and precision, when it has any (NL-MEASURE-10,
    /// ADR-0035). `nil` — every record written before ADR-0035, and every markup nobody gave
    /// units of its own — shows in the project's units. ``display`` cannot say this: it
    /// defaults to metric, so "no override" and "a metric override" were the same bytes.
    /// Metadata only; it never changes a stored value, and totals still sum in SI.
    public var displayOverride: DisplayUnitPolicy?

    public init(
        depth: DecimalQuantity? = nil,
        height: DecimalQuantity? = nil,
        heightAtEnd: DecimalQuantity? = nil,
        slope: SlopeSpecification = .none,
        volumeDepthReference: VolumeDepthReference? = nil,
        cutoutPolicy: CutoutPolicy = .subtractFromArea,
        perimeterPolicy: PerimeterPolicy = .outerOnly,
        openingAreas: [Decimal] = [],
        display: DisplayUnitPolicy = .metric,
        displayOverride: DisplayUnitPolicy? = nil
    ) {
        self.depth = depth
        self.height = height
        self.heightAtEnd = heightAtEnd
        self.slope = slope
        self.volumeDepthReference = volumeDepthReference
        self.cutoutPolicy = cutoutPolicy
        self.perimeterPolicy = perimeterPolicy
        self.openingAreas = openingAreas
        self.display = display
        self.displayOverride = displayOverride
    }

    public static let `default` = MeasurementParameters()

    /// Checks that the parameters needed by the chosen mode are actually present, that any
    /// supplied depth or height really is a length, and that it is not negative.
    ///
    /// The sign guard is ADR-0016: a depth of `-0.2 m` used to pass, and the volume built from
    /// it was stored as `-2 m³` and subtracted from every subtotal it entered. A thickness has
    /// no sign, so a negative one is refused as ``MeasurementError/negativeParameter(_:)`` at
    /// the point of calculation. Decoding is not validation: a stored record with such a value
    /// still reads, and fails only when it is recomputed.
    public func validate() throws {
        let lengths: [(MeasurementParameterKey, DecimalQuantity?)] = [
            (.depth, depth), (.height, height), (.heightAtEnd, heightAtEnd)
        ]
        for (key, quantity) in lengths {
            guard let quantity else { continue }
            guard quantity.dimension == .length else {
                throw UnitConversionError.dimensionMismatch(expected: .length, actual: quantity.dimension)
            }
            guard !quantity.value.isNaN, quantity.value >= 0 else {
                throw MeasurementError.negativeParameter(key)
            }
        }
        // An opening is an area removed from a wall; it has no sign either. No control sets
        // these, so only a corrupt or hand-edited record carries one, and a negative opening
        // used to be added to the net wall area instead of removed from it (R-182, ADR-0035).
        // A NaN one was caught later by the net >= 0 guard; it is named here instead.
        for opening in openingAreas where opening.isNaN || opening < 0 {
            throw MeasurementError.negativeParameter(.openingAreas)
        }
        try slope.validate()
    }
}

/// A non-fatal finding attached to a measurement (spec 12.3, 12.8, 13.11).
///
/// A warning never replaces a value. The engine still returns the number it computed, and the UI
/// is responsible for showing that the number came with a caveat — never with colour alone.
public struct MeasurementWarning: Codable, Hashable, Sendable {
    /// The frozen set of things the engine can complain about.
    public enum Code: String, Codable, Hashable, Sendable, CaseIterable {
        /// The polygon crosses itself; the shoelace area is not the visible area (spec 12.3).
        case selfIntersectingPolygon
        /// The polygon was normalised through a boolean op after user confirmation.
        case polygonNormalized
        /// The area is indistinguishable from zero.
        case degenerateArea
        /// Consecutive duplicate vertices were collapsed.
        case duplicatePointsCollapsed
        /// Fewer than three unique points; no area exists.
        case fewerThanThreeUniquePoints
        /// An open ring was closed implicitly to compute an area.
        case openPolygonClosedImplicitly
        /// Three-point circle input is close to collinear; the centre is ill-conditioned.
        case nearlyCollinearPoints
        /// `run == 0`: the slope is vertical (spec 12.8).
        case verticalSlopeUndefinedRun
        /// The slope magnitude is above 100 % (45 degrees). Accepted, but usually a units
        /// mistake (ADR-0004 §5).
        case slopeMagnitudeAboveOneHundredPercent
        /// A sloped area was measured without a fall-line azimuth, so its true *area* is
        /// reported but its true *perimeter* is not (ADR-0004 §1). The number is absent, never
        /// guessed.
        case slopeAzimuthMissingForBoundary
        /// A cutout does not lie inside its parent.
        case cutoutOutsideParent
        /// The scale is outside the sane range.
        case extremeScale
        /// The measurement was computed under an older scale version than the current one.
        case staleScaleVersion
        /// Summation lost significance; the compensated path was used.
        case numericalPrecisionLoss
        /// A conversion factor is not exact (angles).
        case unitConversionApproximated
        /// The page has no vector content (spec 13.11).
        case vectorSnapUnavailable
        /// The geometry spans two Scale Regions (spec 10.4).
        case mixedScaleRegions
        /// A per-segment rise/drop list was shorter or longer than the segment list.
        case riseDropCountMismatch
        /// The outline has more vertices than the self-intersection check examines
        /// (`selfIntersectionVertexLimit`), so it was measured as drawn without being checked
        /// for self-crossings. The number is returned; whether the outline crosses itself is
        /// unknown (ADR-0018, IM-070).
        case selfIntersectionCheckSkipped
    }

    public let code: Code
    /// The field the warning is about, when it is about one field in particular.
    public let field: MeasurementField?
    /// Diagnostic detail. Not a user-facing string; the UI maps ``code`` to localized copy.
    public let detail: String

    public init(code: Code, field: MeasurementField? = nil, detail: String = "") {
        self.code = code
        self.field = field
        self.detail = detail
    }
}

/// The result of one measurement (spec 12.15, verbatim shape).
public struct MeasurementResult: Codable, Hashable, Sendable {
    /// Every quantity the engine produced, keyed by field. Values are SI base units and are
    /// **not** rounded.
    public let values: [MeasurementField: DecimalQuantity]
    /// Non-fatal findings.
    public let warnings: [MeasurementWarning]
    /// The formula version that produced these values, so a later build can tell whether a
    /// stored result predates a calculation change.
    public let formulaVersion: Int
    /// The derivation this result was computed from (ADR-0007). Present when the calculation
    /// ran through a provenance-recording engine; `nil` for a bare engine call, so existing
    /// callers and stored results keep working unchanged.
    public let provenance: MeasurementProvenance?

    public init(
        values: [MeasurementField: DecimalQuantity],
        warnings: [MeasurementWarning] = [],
        formulaVersion: Int = ContractVersion.measurementFormulaVersion,
        provenance: MeasurementProvenance? = nil
    ) {
        self.values = values
        self.warnings = warnings
        self.formulaVersion = formulaVersion
        self.provenance = provenance
    }

    /// The same result carrying the given derivation record (ADR-0007).
    public func attaching(_ provenance: MeasurementProvenance) -> MeasurementResult {
        MeasurementResult(
            values: values,
            warnings: warnings,
            formulaVersion: formulaVersion,
            provenance: provenance
        )
    }

    public static let empty = MeasurementResult(values: [:])

    private enum CodingKeys: String, CodingKey {
        case values, warnings, formulaVersion, provenance
    }

    /// Decodes a stored result, re-tagging dimensionless values to the dimension their field
    /// declares (ADR-0014 migration).
    ///
    /// Before ADR-0014 a ``QuantityDimension/ratio`` and a ``QuantityDimension/count`` were the
    /// same bytes, so a `slopeRatio` written by an earlier build decodes as a count. The field
    /// is the authority on what its value means — it always was; the tag just could not say
    /// so — and re-tagging here is what keeps ``validateDimensions()`` true for every result
    /// ever stored. Only the count/ratio tag is touched: a value whose length power, angle or
    /// currency disagrees with its field is left as it is, so the mismatch is still visible.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var values = try container.decode([MeasurementField: DecimalQuantity].self, forKey: .values)
        for (field, quantity) in values
        where quantity.dimension != field.dimension
            && quantity.dimension.isDimensionless
            && field.dimension.isDimensionless {
            values[field] = DecimalQuantity(value: quantity.value, dimension: field.dimension)
        }
        self.values = values
        self.warnings = try container.decodeIfPresent([MeasurementWarning].self, forKey: .warnings) ?? []
        self.formulaVersion = try container.decode(Int.self, forKey: .formulaVersion)
        self.provenance = try container.decodeIfPresent(MeasurementProvenance.self, forKey: .provenance)
    }

    public subscript(field: MeasurementField) -> DecimalQuantity? { values[field] }

    /// True when any warning carries the given code.
    public func hasWarning(_ code: MeasurementWarning.Code) -> Bool {
        warnings.contains { $0.code == code }
    }

    /// Checks that every value's dimension matches the dimension its field declares. This is the
    /// invariant a measurement engine implementation is tested against.
    public func validateDimensions() throws {
        for (field, quantity) in values where quantity.dimension != field.dimension {
            throw DimensionError.incompatibleDimensions(
                left: field.dimension,
                right: quantity.dimension
            )
        }
    }
}

/// The measurement engine's entire surface (spec 12.15, verbatim shape).
///
/// One function, three value inputs, one value output. It is `Sendable` and pure: no clock, no
/// id generation, no I/O, no view state. Given the same three inputs it returns the same result
/// on every machine and in every build with the same `formulaVersion`.
public protocol MeasurementCalculating: Sendable {
    func calculate(
        geometry: MeasurementGeometry,
        scale: ScaleTransform,
        parameters: MeasurementParameters
    ) throws -> MeasurementResult
}

/// A count group: the container Count measurements aggregate into (spec 12.13).
public struct CountGroup: Codable, Hashable, Sendable {
    public var id: CountGroupID
    /// The symbol every point in the group is drawn with.
    public var symbolID: SymbolID?
    public var pageID: PageID
    public var zoneID: ZoneID?
    public var subject: String
    public var label: String
    /// Point ids in placement order. Sequential numbering follows this order.
    public var pointIDs: [CountPointID]
    /// Whether the group shows a running sequential number on each point.
    public var showsSequentialNumbering: Bool

    public init(
        id: CountGroupID,
        symbolID: SymbolID? = nil,
        pageID: PageID,
        zoneID: ZoneID? = nil,
        subject: String,
        label: String,
        pointIDs: [CountPointID] = [],
        showsSequentialNumbering: Bool = false
    ) {
        self.id = id
        self.symbolID = symbolID
        self.pageID = pageID
        self.zoneID = zoneID
        self.subject = subject
        self.label = label
        self.pointIDs = pointIDs
        self.showsSequentialNumbering = showsSequentialNumbering
    }

    public var count: Int { pointIDs.count }
}
