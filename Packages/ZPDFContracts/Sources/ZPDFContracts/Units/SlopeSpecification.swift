import Foundation

// MARK: - Direction

/// A unit vector in the plane, produced by ``SlopeAzimuth/direction``.
///
/// Not `Codable`: it is a derived value, never a stored one. The stored form is the azimuth in
/// degrees, so a direction can never disagree with the angle the inspector shows the user.
public struct PlanarDirection: Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// `d . u` for a plan displacement — the component of `d` that runs up the fall line.
    public func component(dx: Double, dy: Double) -> Double {
        dx * x + dy * y
    }
}

/// The steepest-ascent direction of a sloped plane, in page space (ADR-0004 §1).
///
/// A slope is a vector, not a scalar. A plane tilted by `theta` has one direction in which it
/// climbs fastest; a plan displacement `d` on that plane changes elevation by `s * (d . u)` and
/// nothing else. Without `u` there is no way to tell an eave from a rake, and the scalar rule
/// `planLength * sqrt(1 + s^2)` silently treats every edge as if it ran straight up the slope.
///
/// Stored as degrees counter-clockwise from the page-space **+x** axis, normalised into
/// `[0, 360)`, because that is what the inspector displays and what the fall-line arrow is drawn
/// from. ``direction`` is exact on the four axes: an azimuth of 90 degrees gives `(0, 1)` with no
/// rounding at all, which is what lets a contour-parallel edge come out *exactly* unelongated
/// rather than merely close.
public struct SlopeAzimuth: Codable, Hashable, Sendable {
    /// Degrees counter-clockwise from the page-space +x axis, in `[0, 360)`.
    public let degrees: Decimal

    public init(degrees value: Decimal) {
        self.degrees = Self.normalised(value)
    }

    private enum CodingKeys: String, CodingKey {
        case degrees
    }

    /// Decodes through the normalising initializer (BH-499): a stored `450` or `-90` is folded
    /// into `[0, 360)` like any other input, so `direction` still hits the exact axis cases
    /// and `opposite` agrees with what is shown. A NaN is refused rather than read as zero.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode(Decimal.self, forKey: .degrees)
        guard !stored.isNaN else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.degrees],
                debugDescription: "SlopeAzimuth.degrees is not a number"
            ))
        }
        self.init(degrees: stored)
    }

    /// The three ways the ADR says a user supplies an azimuth all land here.
    public static func degrees(_ value: Decimal) -> SlopeAzimuth {
        SlopeAzimuth(degrees: value)
    }

    /// From an angle in radians.
    public static func radians(_ value: Double) throws -> SlopeAzimuth {
        guard value.isFinite else { throw SlopeError.nonFiniteAzimuth }
        return SlopeAzimuth(degrees: try NumericPolicy.decimal(from: value / AngleUnit.degree.radiansPerUnit))
    }

    /// From two points picked along the fall line, or from a snapped markup edge: `from` is
    /// downhill, `to` is uphill.
    ///
    /// The four axis-aligned cases are answered from the signs alone, never through `atan2`, so
    /// an eave picked as two points on a horizontal line yields exactly 0 or 180 degrees.
    public static func between(_ from: PDFPoint, _ to: PDFPoint) throws -> SlopeAzimuth {
        let dx = to.x - from.x
        let dy = to.y - from.y
        guard dx.isFinite, dy.isFinite else { throw SlopeError.nonFiniteAzimuth }
        guard dx != 0 || dy != 0 else { throw SlopeError.azimuthFromCoincidentPoints }
        if dy == 0 { return SlopeAzimuth(degrees: dx > 0 ? 0 : 180) }
        if dx == 0 { return SlopeAzimuth(degrees: dy > 0 ? 90 : 270) }
        let radians = Foundation.atan2(dy, dx)
        return try SlopeAzimuth.radians(radians)
    }

    /// The azimuth in radians.
    public var radians: Double {
        NumericPolicy.double(from: degrees) * AngleUnit.degree.radiansPerUnit
    }

    /// The unit vector of steepest ascent, in page space.
    public var direction: PlanarDirection {
        switch degrees {
        case 0: return PlanarDirection(x: 1, y: 0)
        case 90: return PlanarDirection(x: 0, y: 1)
        case 180: return PlanarDirection(x: -1, y: 0)
        case 270: return PlanarDirection(x: 0, y: -1)
        default:
            let angle = radians
            return PlanarDirection(x: Foundation.cos(angle), y: Foundation.sin(angle))
        }
    }

    /// The downhill direction. `(d . u)` is squared in every formula that uses it, so reversing
    /// an azimuth never changes a length — this exists for the UI arrow, not for the arithmetic.
    public var opposite: SlopeAzimuth {
        SlopeAzimuth(degrees: degrees + 180)
    }

    /// Folds any real angle into `[0, 360)` without depending on which way `NSDecimalRound`
    /// rounds a negative quotient.
    static func normalised(_ value: Decimal) -> Decimal {
        guard !value.isNaN else { return 0 }
        if value >= 0, value < 360 { return value }
        var quotient = value / 360
        var whole = Decimal.zero
        NSDecimalRound(&whole, &quotient, 0, .down)
        var remainder = value - whole * 360
        if remainder < 0 { remainder += 360 }
        if remainder >= 360 { remainder -= 360 }
        return remainder
    }
}

// MARK: - Mode

/// How slope is supplied for a measurement (ADR-0004 §1, spec 12.8, 12.9).
///
/// The modes are explicit rather than inferred, because "one plane for the whole markup" and
/// "a rise per segment" give different true lengths from the same drawing.
public enum SlopeMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Flat. Plan values are the only values.
    case none
    /// One tilted plane: a magnitude plus a fall-line azimuth (ADR-0004 §1).
    case uniformPlane
    /// One rise/drop per segment, in the order the segments appear (spec 12.9). Stairs, ramps
    /// and drainage runs, where each segment genuinely has its own grade.
    case perSegmentRiseDrop
    /// A single rise/drop applied across the whole polyline (spec 12.9).
    case totalRiseDrop

    /// Accepts the pre-ADR-0004 spelling `uniformSlope` so a record written under measurement
    /// contract v1 still decodes. Nothing writes that spelling any more.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "uniformSlope" {
            self = .uniformPlane
            return
        }
        guard let mode = SlopeMode(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown SlopeMode \(raw)"
                )
            )
        }
        self = mode
    }
}

// MARK: - Volume depth reference

/// Which direction a volume's depth was measured in (ADR-0004 §2).
///
/// The two rows are the single most common source of silent error in takeoff, so there is no
/// default: a volume on a sloped markup requires the choice.
public enum VolumeDepthReference: String, Codable, Hashable, Sendable, CaseIterable {
    /// Depth measured vertically, plumb. `volume = A_plan * depth` — the projection cancels, so
    /// a vertically measured thickness over a plan area is already the correct volume.
    case verticalDepth
    /// Thickness measured perpendicular to the sloped surface, as a slab or a screed is.
    /// `volume = A_true * thickness = A_plan * sqrt(1 + s^2) * thickness`.
    case perpendicularThickness
}

// MARK: - Specification

/// A slope as ADR-0004 defines it: a magnitude, a direction and an explicit mode.
///
/// The magnitude round-trips exactly through `Decimal` in every form the roofing trade writes it
/// in (``SlopeExpression``). The azimuth is the steepest-ascent direction in page space. Until an
/// azimuth exists, a slope may not be applied to a length or a perimeter — that is a typed error,
/// never a scalar fallback — but it may be applied to an area, because orthographic projection
/// scales every planar region by `cos theta` regardless of the region's shape or orientation.
public struct SlopeSpecification: Codable, Hashable, Sendable {
    public var mode: SlopeMode
    /// The slope magnitude, when ``mode`` is ``SlopeMode/uniformPlane``.
    public var magnitude: SlopeExpression?
    /// The steepest-ascent direction in page space, when it has been established.
    public var azimuth: SlopeAzimuth?
    /// Per-segment rise/drop in metres, when ``mode`` is ``SlopeMode/perSegmentRiseDrop``.
    /// Index `i` applies to segment `i`.
    public var perSegmentRiseDrop: [Decimal]
    /// Total rise/drop in metres, when ``mode`` is ``SlopeMode/totalRiseDrop``.
    public var totalRiseDrop: Decimal?

    public init(
        mode: SlopeMode = .none,
        magnitude: SlopeExpression? = nil,
        azimuth: SlopeAzimuth? = nil,
        perSegmentRiseDrop: [Decimal] = [],
        totalRiseDrop: Decimal? = nil
    ) {
        self.mode = mode
        self.magnitude = magnitude
        self.azimuth = azimuth
        self.perSegmentRiseDrop = perSegmentRiseDrop
        self.totalRiseDrop = totalRiseDrop
    }

    /// Flat: no slope of any kind.
    public static let none = SlopeSpecification()

    /// One tilted plane. The azimuth is optional at construction because an area can be
    /// measured without it; a length cannot, and asking for one then is a typed error.
    public static func uniformPlane(
        _ magnitude: SlopeExpression,
        azimuth: SlopeAzimuth? = nil
    ) -> SlopeSpecification {
        SlopeSpecification(mode: .uniformPlane, magnitude: magnitude, azimuth: azimuth)
    }

    /// One tilted plane whose fall line is given by two page-space points, downhill to uphill.
    public static func uniformPlane(
        _ magnitude: SlopeExpression,
        fallLineFrom from: PDFPoint,
        to end: PDFPoint
    ) throws -> SlopeSpecification {
        SlopeSpecification(
            mode: .uniformPlane,
            magnitude: magnitude,
            azimuth: try SlopeAzimuth.between(from, end)
        )
    }

    public static func perSegment(_ riseDrops: [Decimal]) -> SlopeSpecification {
        SlopeSpecification(mode: .perSegmentRiseDrop, perSegmentRiseDrop: riseDrops)
    }

    public static func total(_ riseDrop: Decimal) -> SlopeSpecification {
        SlopeSpecification(mode: .totalRiseDrop, totalRiseDrop: riseDrop)
    }

    /// Returns a copy carrying `azimuth`.
    public func with(azimuth: SlopeAzimuth) -> SlopeSpecification {
        var copy = self
        copy.azimuth = azimuth
        return copy
    }

    /// ADR-0004 §5: magnitudes above 100 % (45 degrees) are accepted but flagged, since they are
    /// usually a units mistake. A vertical magnitude has no ratio and is not "above 100 %"; it is
    /// its own reported condition.
    public var exceedsOneHundredPercent: Bool {
        guard mode == .uniformPlane, let magnitude, !magnitude.isVertical else { return false }
        guard let ratio = try? magnitude.ratio(), !ratio.isNaN else { return false }
        return Swift.abs(ratio) > 1
    }

    /// The azimuth a directional quantity needs.
    ///
    /// - Throws: ``MeasurementError/slopeAzimuthRequired(_:)`` — never a scalar fallback.
    public func requireAzimuth(for field: MeasurementField) throws -> SlopeAzimuth {
        guard let azimuth else { throw MeasurementError.slopeAzimuthRequired(field) }
        return azimuth
    }

    /// Checks that the input the chosen mode needs is actually present.
    public func validate() throws {
        switch mode {
        case .none:
            break
        case .uniformPlane:
            guard magnitude != nil else { throw MeasurementError.missingParameter(.riseRun) }
        case .perSegmentRiseDrop:
            guard !perSegmentRiseDrop.isEmpty else {
                throw MeasurementError.missingParameter(.perSegmentRiseDrop)
            }
        case .totalRiseDrop:
            guard totalRiseDrop != nil else {
                throw MeasurementError.missingParameter(.totalRiseDrop)
            }
        }
    }
}
