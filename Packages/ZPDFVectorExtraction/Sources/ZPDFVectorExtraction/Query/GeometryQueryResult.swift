import CoreGraphics
import Foundation

/// How a query ended.
///
/// A cap is never silent: a result that hit its limit says so in
/// the type rather than by being quietly short, and a query asked with a nonsense
/// parameter says which parameter rather than returning an innocent empty list.
public enum GeometryQueryStatus: Sendable, Hashable {
    /// Every candidate was examined and every match is present.
    case complete
    /// The result limit was reached. There are more matches on the page than are listed.
    case truncated(limit: Int)
    /// The query was rejected before it ran. No candidate was examined.
    case invalidParameter(name: String, reason: String)
}

/// The answer to one geometry query over one page.
///
/// **A result is a set of highlights, never a quantity.** Nothing here is a measurement,
/// nothing here sums, and nothing here may be presented as a takeoff value: the
/// invariant is that a search result becomes a measurement only when a person commits
/// it. That is why this type carries a count and a status and offers no total, and why
/// every match below is named `…Highlight`.
public struct GeometryQueryResult<Match: Sendable & Hashable>: Sendable, Hashable {
    /// In deterministic order: ascending by the primitive identifiers of the match.
    public let matches: [Match]
    public let status: GeometryQueryStatus
    /// How many candidates the query looked at. Its unit is documented per query.
    public let examinedCount: Int
    /// The scale the query's parameters were expressed in: one caller unit is this many
    /// page points. Every geometric field of every match is in **page points**.
    public let pointsPerUnit: Double

    public init(
        matches: [Match],
        status: GeometryQueryStatus,
        examinedCount: Int,
        pointsPerUnit: Double
    ) {
        self.matches = matches
        self.status = status
        self.examinedCount = examinedCount
        self.pointsPerUnit = pointsPerUnit
    }

    /// How many matches are listed. Not how many exist — see ``truncated``.
    public var count: Int { matches.count }

    /// `true` when the page holds more matches than are listed here.
    public var truncated: Bool {
        if case .truncated = status { return true }
        return false
    }

    /// The limit that truncated the result, when one did.
    public var truncationLimit: Int? {
        if case let .truncated(limit) = status { return limit }
        return nil
    }

    /// `true` when the query was rejected before it ran.
    public var wasRejected: Bool {
        if case .invalidParameter = status { return true }
        return false
    }

    /// Convert a page-point distance carried by a match back to the caller's unit.
    public func units(fromPoints points: Double) -> Double {
        pointsPerUnit > 0 ? points / pointsPerUnit : points
    }

    static func rejected(name: String, reason: String, pointsPerUnit: Double) -> Self {
        Self(
            matches: [],
            status: .invalidParameter(name: name, reason: reason),
            examinedCount: 0,
            pointsPerUnit: pointsPerUnit
        )
    }
}

/// Two near-parallel segments a fixed distance apart — the shape of *"every wall 300 mm
/// apart"*.
///
/// **A highlight, not a quantity.** It says two edges are there and where they face each
/// other; it does not say the wall is 300 mm thick, does not say how much wall there is,
/// and must never be totalled. Committing it to a measurement is a person's act.
public struct GeometryParallelPairHighlight: Sendable, Hashable {
    /// The lower of the two ``VectorPrimitive/id`` values, so a pair has one identity.
    public let firstPrimitiveID: UInt64
    public let secondPrimitiveID: UInt64
    /// Perpendicular separation in page points, measured at the middle of the shared
    /// span rather than at an endpoint — over a long segment a legal 1.5° of skew moves
    /// an endpoint-measured separation by many points.
    public let separationPoints: Double
    /// How much of the two segments actually face each other, in page points, measured
    /// along the first segment's direction.
    public let overlapLengthPoints: Double
    /// How far from parallel the two segments are, in degrees.
    public let angleDifferenceDegrees: Double
    /// The facing span as a ring: two corners on the first segment, two on the second.
    /// Not axis-aligned, because a wall on a drawing rarely is — draw this, not
    /// ``bounds``, when the highlight should sit on the linework.
    public let overlapQuad: VectorQuad
    /// The axis-aligned box around ``overlapQuad``, for coarse hit tests and scrolling.
    public let bounds: VectorBounds
}

/// One segment whose length matches what was asked for.
///
/// **A highlight, not a quantity.** ``lengthPoints`` is the length of a line the producer
/// drew, in page points. It is not a measurement of anything the drawing depicts, and the
/// caller converts to real-world units through the page's scale — this package never does.
public struct GeometryLengthHighlight: Sendable, Hashable {
    public let primitiveID: UInt64
    public let lengthPoints: Double
    public let start: CGPoint
    public let end: CGPoint
    public let bounds: VectorBounds
}

/// A chain of cubics that fits a circle of the radius asked for.
///
/// **A highlight, not a quantity.** The extraction model carries no circles: this is a
/// circle *fitted* to the Bézier approximation a producer drew, and
/// ``maximumFitDeviationPoints`` is how far the drawn geometry sat from it. A four-cubic
/// unit circle deviates by 2.7253e-4 of its radius by construction, so a non-zero
/// deviation is normal and is reported rather than hidden.
public struct GeometryCircleHighlight: Sendable, Hashable {
    /// The cubics that were fitted, in drawing order.
    public let primitiveIDs: [UInt64]
    /// The subpath-level primitive they belong to, when the extraction emitted one.
    public let parentID: UInt64?
    public let center: CGPoint
    public let radiusPoints: Double
    /// How much of a full turn the chain covers, in radians. `2π` for a closed circle;
    /// less for an arc.
    public let sweepRadians: Double
    /// The largest distance between a sampled point of the drawn curve and the fitted
    /// circle, in page points.
    public let maximumFitDeviationPoints: Double
    /// The bounds of the drawn curves, not of the fitted circle.
    public let bounds: VectorBounds
}
