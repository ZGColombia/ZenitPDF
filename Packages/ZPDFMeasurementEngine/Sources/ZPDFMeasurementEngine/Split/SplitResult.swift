import Foundation
import ZPDFContracts

/// What splitting one committed area with a line produced.
///
/// Both refusals are values, not errors, because both are ordinary outcomes of a person drawing
/// a line on a drawing: the line landed next to the area rather than across it, or it shaved a
/// sliver off an edge instead of dividing anything. A refusal is the correct answer to those
/// gestures, and the caller presents it. An `Error` is reserved for input the engine cannot
/// interpret at all — a NaN coordinate, a cut of one point, a ring with no area.
///
/// Invariant: a split never counts area twice — never the original and the parts both in the
/// ledger. The engine's half of that guarantee is ``PolygonSplitter/areaCheck(original:parts:)``
/// — the caller compares the parts against the original **before** it writes anything, and a
/// split whose parts do not sum to the original is never stored.
public enum SplitResult: Equatable, Sendable {

    /// The parts the cut produced, ordered by descending net area (holes already subtracted).
    ///
    /// Normally two. A concave outer ring can legitimately give three or more: a straight line
    /// through an L-shape crosses the boundary four times and leaves three pieces, and every one
    /// of them is a real area that has to appear. They are all returned.
    ///
    /// Ordering is total and deterministic: descending net area, then ascending minimum x, then
    /// ascending minimum y of the outer ring. The tie-breakers matter — the commonest split of
    /// all, a rectangle cut down the middle, produces two parts of exactly equal area, and
    /// "part 1" has to mean the same piece on every run and every machine.
    case parts([PolygonGeometry])

    /// The cut, after extension past the area's bounds, never entered the area.
    ///
    /// This covers the gesture that misses entirely, the gesture that only grazes a vertex, and
    /// the gesture drawn along an existing edge — in each case one side of the cut holds the
    /// whole area and the other holds nothing, so there is no division to make.
    ///
    /// It also covers a cut that crosses only a hole: there is an intersection with the outer
    /// ring's box, but the *net* region — the thing the ledger measures — is not divided.
    case lineMissesPolygon

    /// The cut divided the area, but at least one part is smaller than
    /// ``PolygonSplitOptions/minimumPartArea``.
    ///
    /// The case this exists for is a cut a hair off an edge. Geometrically it is a genuine split;
    /// in a ledger it is the original area plus a sliver, which is a wrong row and a wrong
    /// number. Refusing is the only safe answer, so the smallest part's area travels with the
    /// refusal and the caller can say how small it was.
    ///
    /// - Parameter smallestPartPDFArea: net area of the offending part, in square PDF points.
    case degenerate(smallestPartPDFArea: Double)
}

extension SplitResult {

    /// The parts, or `nil` for either refusal. Convenience for callers that treat both refusals
    /// the same way.
    public var partsIfSplit: [PolygonGeometry]? {
        if case let .parts(parts) = self { return parts }
        return nil
    }

    /// `true` when the engine refused to split.
    public var isRefusal: Bool { partsIfSplit == nil }
}

/// How ``PolygonSplitter`` behaves. Nothing here changes what a split *means*; everything here
/// is a threshold or a construction size.
public struct PolygonSplitOptions: Hashable, Sendable {

    /// Net area in square PDF points below which a part is a sliver and the whole split is
    /// refused with ``SplitResult/degenerate(smallestPartPDFArea:)``.
    ///
    /// The default, `0.01` pt², is a hundredth of a square point: a square a tenth of a point on
    /// a side. At any drawing scale a person could work at, that is not an area anybody meant to
    /// create — at 1:100 it is 0.1 mm x 0.1 mm of real wall — while a real division of a real
    /// area is orders of magnitude above it.
    public var minimumPartArea: Double

    /// The numeric policy the split shares with the cutout pipeline: epsilons, the Clipper2
    /// lattice, the self-intersection policy. Passing the same value here as the engine uses
    /// elsewhere is what makes a part's area comparable with the parent's.
    public var engine: MeasurementEngineOptions

    /// How far past the combined bounds of the area and the cut the cut is extended, and how
    /// deep each side's clip region reaches, as a multiple of the diagonal of those bounds.
    ///
    /// It has to be comfortably more than 1: the clip regions are built from half-strips and
    /// corner wedges, and a wedge only covers its sector out to the chord between its two far
    /// vertices. At a fan step of 60 degrees that chord sits at `cos(30 degrees) = 0.866` of the
    /// reach, so a reach of 8 diagonals still covers every point of the area with a margin of
    /// almost seven diagonals.
    public var reachFactor: Double

    /// Largest angular step, in radians, used when fanning a corner wedge of a bent cut.
    ///
    /// Smaller is safer and costs a handful of triangles. The default is 60 degrees.
    public var maximumFanStep: Double

    public init(
        minimumPartArea: Double = 0.01,
        engine: MeasurementEngineOptions = .default,
        reachFactor: Double = 8,
        maximumFanStep: Double = Double.pi / 3
    ) {
        self.minimumPartArea = minimumPartArea
        self.engine = engine
        self.reachFactor = reachFactor
        self.maximumFanStep = maximumFanStep
    }

    public static let `default` = PolygonSplitOptions()
}
