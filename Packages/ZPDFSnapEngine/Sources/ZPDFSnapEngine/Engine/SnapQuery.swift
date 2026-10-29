import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry

/// One pointer sample, as data.
///
/// There is deliberately **no timestamp**. `QUALITY_BAR` 3.4 rule 2 forbids any dependence on
/// wall-clock time or elapsed time, and a field that exists is a field something will eventually
/// read. `sequence` is an ordinal for the decision log only and never enters a decision.
public struct SnapPointerEvent: Sendable, Hashable {

    /// The cursor in the page's view space, in AppKit view points.
    public var viewPoint: CGPoint

    /// Zoom, backing scale and the page's placement in the view. Supplied per event, because
    /// zoom can change between two mouse moves.
    public var layout: PageViewLayout

    public var modifiers: SnapModifiers

    /// The in-progress point of the current measurement, in page space. Perpendicular feet,
    /// tangents and the angle constraint are all relative to it, and all three are absent when
    /// it is `nil`.
    public var anchorPagePoint: PDFPoint?

    /// The layer the user is drawing on, for the active-layer score term.
    public var activeLayerID: String?

    /// Event ordinal. Written to the decision log; never read by the scorer.
    public var sequence: Int

    public init(
        viewPoint: CGPoint,
        layout: PageViewLayout,
        modifiers: SnapModifiers = .none,
        anchorPagePoint: PDFPoint? = nil,
        activeLayerID: String? = nil,
        sequence: Int = 0
    ) {
        self.viewPoint = viewPoint
        self.layout = layout
        self.modifiers = modifiers
        self.anchorPagePoint = anchorPagePoint
        self.activeLayerID = activeLayerID
        self.sequence = sequence
    }
}

/// One snap query: an event, the settings in force, and the score weights.
public struct SnapQuery: Sendable, Hashable {
    public var event: SnapPointerEvent
    public var settings: SnapSettings
    public var weights: SnapScoringWeights

    public init(
        event: SnapPointerEvent,
        settings: SnapSettings = .default,
        weights: SnapScoringWeights = .standard
    ) {
        self.event = event
        self.settings = settings
        self.weights = weights
    }
}

/// The answer: the winner, the ranked alternatives, and the payload the UI renders.
public struct SnapResolution: Sendable, Hashable, Codable {

    /// The winning candidate, or `nil` when nothing was in range, snapping was off, or the
    /// user bypassed it with `Option`.
    public let winner: SnapCandidate?

    /// Every other candidate, in the total order of `QUALITY_BAR` S1, capped at
    /// ``SnapIndexLimits/maximumRankedAlternatives``. `Tab` walks this list.
    public let alternatives: [SnapCandidate]

    public let feedback: SnapFeedback?

    public let availability: SnapIndexAvailability

    /// The cursor in page space, before any snap.
    public let rawPagePoint: PDFPoint

    /// The point the tool should actually use: the winner's position, the constrained
    /// projection when `Shift` is held with no winner, otherwise the raw point.
    public let resolvedPagePoint: PDFPoint

    public let tolerancePagePoints: Double
    public let hysteresisPagePoints: Double

    /// Where `Tab` currently is in the ranked list, modulo its length.
    public let cycleIndex: Int

    /// `true` when the winner is only alive because hysteresis is holding it.
    public let isHeldByHysteresis: Bool

    /// One reproducible line for the stability and determinism suites of `QUALITY_BAR` 3.3/3.4.
    public let decision: SnapDecision

    /// How far the intersection search got inside its per-query budget (CR-37).
    ///
    /// When ``SnapIntersectionReport/isTruncated`` is `true` the intersections that were found
    /// are exact but the set is not complete, and a caller that presents "intersection" as
    /// reachable should say so. The same index and event truncate at the same pair, so the
    /// flag is as reproducible as the winner.
    public let intersections: SnapIntersectionReport

    /// ``intersections``' truncation flag, for callers that want one Boolean.
    public var isIntersectionSearchTruncated: Bool { intersections.isTruncated }

    /// The winner's full candidate key — component and whether it follows the cursor
    /// included — which ``SnapCandidate`` does not carry. `nil` when nothing won.
    ///
    /// A replay has to know whether a winner follows the cursor to count a switch honestly:
    /// the nearest point on an edge has a new position every event and is still the same
    /// decision (BH-218). Optional, so a resolution encoded before it existed still decodes.
    public let winnerKey: SnapCandidateKey?
}

/// One line of the snap decision log (`QUALITY_BAR` 3.3 step 2).
///
/// The rendered form uses hexadecimal IEEE-754 bit patterns for every real number. A decimal
/// rendering would be locale-dependent and would round away exactly the last bits a determinism
/// test exists to compare.
public struct SnapDecision: Sendable, Hashable, Codable {
    public let sequence: Int
    public let kind: SnapKind?
    public let primitiveID: UInt64
    public let secondaryPrimitiveID: UInt64
    public let score: Double
    public let point: PDFPoint
    public let candidateCount: Int
    public let isHeld: Bool
    public let availabilityKey: String
    /// `true` when the intersection search stopped at its pair budget (CR-37). Logged, so the
    /// determinism suite compares it across processes like every other part of the decision.
    public let isIntersectionSearchTruncated: Bool

    public var logLine: String {
        let kindText = kind?.rawValue ?? "-"
        return [
            String(sequence),
            kindText,
            String(primitiveID, radix: 16),
            String(secondaryPrimitiveID, radix: 16),
            String(score.bitPattern, radix: 16),
            String(point.x.bitPattern, radix: 16),
            String(point.y.bitPattern, radix: 16),
            String(candidateCount),
            isHeld ? "held" : "fresh",
            availabilityKey,
            isIntersectionSearchTruncated ? "intersections-partial" : "intersections-complete"
        ].joined(separator: " ")
    }
}
