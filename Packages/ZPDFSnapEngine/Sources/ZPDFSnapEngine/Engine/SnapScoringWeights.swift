import Foundation
import ZPDFContracts

/// The six terms of `SNAP_CONTRACT` 13.7, with a documented value each.
///
/// ```
/// score = typePriority
///       + screenDistance
///       + confidence
///       + activeLayer
///       + directionConstraint
///       + hysteresis
/// ```
///
/// Lower is better. Every term is expressed in the same synthetic unit, and the unit is pinned
/// by ``screenDistancePerViewPoint``: one unit of score is two view points of cursor travel at
/// the default weights. Reading the other weights against that scale is the whole point of
/// keeping them in a named struct rather than as literals inside the scorer.
///
/// The defaults were chosen so that:
///
/// - one step of priority (1.0) is worth **2 view points** of distance. An `intersection`
///   (priority 2) therefore beats a `nearestPointOnSegment` (priority 9) unless the nearest
///   point is more than 14 view points closer — which, at a 10-point default radius, it cannot
///   be. Priority dominates inside the radius, and distance decides between equals. That is the
///   behaviour a drafter expects and the reason the priority list in 13.7 exists at all;
/// - the full 24-point maximum radius spans 12 units of score, so distance can still overturn a
///   priority gap of up to twelve at the widest setting;
/// - a clip-derived primitive (`confidence` 0.5) pays 1.0, one priority step: enough to lose a
///   tie against real linework, not enough to become unreachable;
/// - an inactive layer pays 6.0, three priority steps, so a candidate on the layer the user is
///   drawing on wins across most of the priority table without ever making other layers
///   unsnappable;
/// - a violated Shift constraint pays 40.0, more than every other term can spread two
///   candidates apart — priority 0...16, distance up to the 24 + 4 view-point held radius
///   (14.0), inactive layer 6.0, confidence 2.0: 38.0 in all — so any candidate that satisfies
///   the constraint beats any that violates it, while the constraint remains a score term
///   rather than a filter, which keeps a single total order over all candidates. It was 12.0,
///   which the file claimed was "effectively absolute"; an endpoint 1.5 view points from the
///   cursor and just outside the band then beat the on-ray target (BH-662). With a priority
///   override wider than the default table the guarantee needs a larger value here.
public struct SnapScoringWeights: Sendable, Hashable, Codable {

    /// Cost of one step down the priority list of `SNAP_CONTRACT` 13.7.
    public var typePriority: Double

    /// Cost per view point of distance between the cursor and the candidate. Distance is scored
    /// in **view points**, not page points, because "near" is a screen judgement (SNAP_CONTRACT,
    /// `SnapCandidate.screenDistancePixels`).
    public var screenDistancePerViewPoint: Double

    /// Cost of `(1 - confidence)`. A fully confident primitive pays nothing.
    public var lowConfidence: Double

    /// Flat cost for a candidate that is not on the active layer.
    public var inactiveLayer: Double

    /// Flat cost for a candidate that violates the active direction constraint (Shift).
    public var directionConstraintViolation: Double

    /// How far past the point of equality the cursor must travel before a held candidate is
    /// released, expressed as a multiple of ``SnapSettings/hysteresisPixels``.
    ///
    /// This is the numeric definition of "clearly better" that `SNAP_CONTRACT` 13.9 leaves
    /// qualitative. Along the axis joining two otherwise equal candidates, moving the cursor a
    /// distance `h` past their midline changes their distance difference by `2h`, so the raw
    /// score advantage of the competitor grows at `2 * h * screenDistancePerViewPoint`. Setting
    /// the factor to 2 therefore makes the rule exactly:
    ///
    /// > the held candidate is released when the cursor has moved more than `hysteresisPixels`
    /// > view points past the position at which the two candidates were equally good.
    ///
    /// which is the rule the stability paths of `QUALITY_BAR` 3.3 are written against: a dither
    /// of +/-3.9 view points about the midline switches nothing, and +/-4.1 may.
    public var hysteresisTravelFactor: Double

    /// Scores closer than this are treated as equal and decided by the total order's later
    /// keys. It exists so that two candidates whose scores differ only in the last bits of a
    /// square root cannot swap places between two runs of the same path.
    public var scoreEqualityEpsilon: Double

    public init(
        typePriority: Double = 1.0,
        screenDistancePerViewPoint: Double = 0.5,
        lowConfidence: Double = 2.0,
        inactiveLayer: Double = 6.0,
        directionConstraintViolation: Double = 40.0,
        hysteresisTravelFactor: Double = 2.0,
        scoreEqualityEpsilon: Double = 1e-9
    ) {
        self.typePriority = typePriority
        self.screenDistancePerViewPoint = screenDistancePerViewPoint
        self.lowConfidence = lowConfidence
        self.inactiveLayer = inactiveLayer
        self.directionConstraintViolation = directionConstraintViolation
        self.hysteresisTravelFactor = hysteresisTravelFactor
        self.scoreEqualityEpsilon = scoreEqualityEpsilon
    }

    public static let standard = SnapScoringWeights()

    /// The raw-score advantage a competitor must have over the held candidate before it counts
    /// as "clearly better" (`SNAP_CONTRACT` 13.9).
    public func clearlyBetterMargin(hysteresisViewPoints: Double) -> Double {
        hysteresisTravelFactor * hysteresisViewPoints * screenDistancePerViewPoint
    }

    public func validate() throws {
        let values: [(String, Double)] = [
            ("typePriority", typePriority),
            ("screenDistancePerViewPoint", screenDistancePerViewPoint),
            ("lowConfidence", lowConfidence),
            ("inactiveLayer", inactiveLayer),
            ("directionConstraintViolation", directionConstraintViolation),
            ("hysteresisTravelFactor", hysteresisTravelFactor),
            ("scoreEqualityEpsilon", scoreEqualityEpsilon)
        ]
        for (name, value) in values {
            guard value.isFinite, value >= 0 else {
                throw SnapEngineError.invalidSettings("weight \(name) must be finite and >= 0")
            }
        }
        guard screenDistancePerViewPoint > 0 else {
            throw SnapEngineError.invalidSettings("screenDistancePerViewPoint must be > 0")
        }
    }
}
