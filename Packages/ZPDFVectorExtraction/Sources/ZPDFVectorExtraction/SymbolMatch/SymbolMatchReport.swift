import CoreGraphics
import Foundation

/// A similarity transform — rotation or reflection, uniform scale, translation — stored
/// as six `Double`s so it can be hashed, coded and compared exactly.
///
/// Maps a point the way `CGAffineTransform` does: `x' = a·x + c·y + tx`,
/// `y' = b·x + d·y + ty`.
public struct SymbolTransform: Sendable, Hashable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = SymbolTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public func apply(_ point: CGPoint) -> CGPoint {
        CGPoint(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
    }

    public var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// Negative for a reflection.
    public var determinant: Double { a * d - b * c }
}

/// One place on the page the matcher confirmed as an instance of the exemplar.
public struct SymbolInstance: Sendable, Hashable {
    /// The primitives that make the instance up, ascending.
    public let primitiveIDs: [UInt64]
    /// The exemplar's feature-point centroid carried through ``transform`` — where a count
    /// marker for it belongs. It is the symbol's own centre, not the centre of every
    /// stroke the cluster happened to contain.
    public let position: CGPoint
    /// The tight bounds of the member primitives.
    public let bounds: VectorBounds
    /// Maps exemplar page coordinates onto this instance's page coordinates.
    public let transform: SymbolTransform
    /// `true` when the instance is the exemplar's mirror image — the alignment needed a
    /// reflection, not just a rotation.
    public let isMirrored: Bool
    /// Instance size over exemplar size. `1` for a same-size instance.
    public let scaleFactor: Double
    /// The match residual — the worst per-stroke nearest-neighbour distance after the
    /// declared contamination shares are set aside, measured both ways — as a fraction
    /// of the instance's RMS radius: the same unit as
    /// ``SymbolMatchOptions/residualThreshold``, and always at or below it for a
    /// confirmed instance. Never a percentage of anything else, and never a guess.
    public let residual: Double
    /// `true` for the instance the estimator clicked — the one every other instance was
    /// matched against. Its ``transform`` is the identity.
    public let isExemplar: Bool

    public init(
        primitiveIDs: [UInt64],
        position: CGPoint,
        bounds: VectorBounds,
        transform: SymbolTransform,
        isMirrored: Bool,
        scaleFactor: Double,
        residual: Double,
        isExemplar: Bool
    ) {
        self.primitiveIDs = primitiveIDs
        self.position = position
        self.bounds = bounds
        self.transform = transform
        self.isMirrored = isMirrored
        self.scaleFactor = scaleFactor
        self.residual = residual
        self.isExemplar = isExemplar
    }
}

/// Why one candidate was **not** confirmed. Typed, because "skipped four doors" is only
/// useful when each of the four says why.
public enum SymbolRejectionReason: Sendable, Hashable {
    /// The best alignment still left this much residual, against this threshold. Both
    /// values are fractions of the candidate's RMS radius.
    case residualTooHigh(residual: Double, threshold: Double)
    /// Part of the candidate's geometry sits outside the searched region, so the matcher
    /// could not see the whole shape and refuses to judge half of one.
    case partialOverlap
    /// Too few primitives to be an instance of this exemplar.
    case tooFewPrimitives(found: Int, required: Int)
    /// The candidate's size relative to the exemplar falls outside the scale band.
    case scaleOutsideBand(scale: Double, band: ClosedRange<Double>)
    /// A drawing of the boxed CAD block itself — the same Form XObject, placed again — that is
    /// not whole on the sheet: a clip cut some of its primitives away, or the layer filter hides
    /// some. `visible` of the block's `total` usable primitives show. Only
    /// ``ExactBlockMatcher`` reports it, and unlike ``partialOverlap`` (a geometric cluster
    /// crossing the searched region's edge, which may be anything) it is certainly an instance
    /// of the symbol, so a review lists it for a person to decide rather than counting it among
    /// the shapes that did not resemble the symbol (T-066).
    case partialBlock(visible: Int, total: Int)
}

/// One place on the page the matcher looked at and turned down.
public struct SymbolRejection: Sendable, Hashable {
    /// The primitives of the rejected candidate, ascending.
    public let primitiveIDs: [UInt64]
    /// Where the candidate sits, so the interface can point at what was skipped.
    public let position: CGPoint
    public let bounds: VectorBounds
    public let reason: SymbolRejectionReason

    public init(
        primitiveIDs: [UInt64],
        position: CGPoint,
        bounds: VectorBounds,
        reason: SymbolRejectionReason
    ) {
        self.primitiveIDs = primitiveIDs
        self.position = position
        self.bounds = bounds
        self.reason = reason
    }
}

/// Everything one match run found, everything it skipped, and why — an invariant
/// made structural: *a door list that silently missed four doors is worse
/// than no door list*, so the skipped doors are in the type, not in a log.
///
/// Deterministic: the same exemplar over the same primitives with the same options
/// produces an equal report, with ``confirmed`` and ``rejected`` each ordered by their
/// lowest primitive identifier.
public struct SymbolMatchReport: Sendable, Hashable {
    /// Instances that matched, the exemplar itself among them with the identity
    /// transform. Ordered by lowest primitive identifier.
    public let confirmed: [SymbolInstance]
    /// Candidates that did not match, each with a typed reason. Ordered by lowest
    /// primitive identifier. **Candidates the search never reached are not in this list**
    /// — when that happens, ``wasTruncated`` says so.
    public let rejected: [SymbolRejection]
    /// The region the matcher actually searched. Candidates crossing its edge are
    /// rejected as ``SymbolRejectionReason/partialOverlap``, never half-judged.
    public let searchedRegion: VectorBounds
    /// How many candidate clusters the page produced.
    public let candidateCount: Int
    /// `true` when any cap in ``SymbolMatchOptions`` stopped the search before every
    /// candidate was examined. A truncated report is not a complete schedule and must
    /// never be presented as one.
    public let wasTruncated: Bool
    /// The ``SymbolMatchOptions/residualThreshold`` this run used, echoed so a consumer
    /// can state confidence as *residual over threshold* rather than inventing a number.
    public let residualThreshold: Double

    public init(
        confirmed: [SymbolInstance],
        rejected: [SymbolRejection],
        searchedRegion: VectorBounds,
        candidateCount: Int,
        wasTruncated: Bool,
        residualThreshold: Double
    ) {
        self.confirmed = confirmed
        self.rejected = rejected
        self.searchedRegion = searchedRegion
        self.candidateCount = candidateCount
        self.wasTruncated = wasTruncated
        self.residualThreshold = residualThreshold
    }
}
