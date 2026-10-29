import Foundation
import ZPDFUIPresentation

// The Cutout tool's contract: a polygon or ellipse drawn inside an existing area markup lowers
// the area's net value by the cutout, the cutout is a child of that area in the ledger, and
// Clipper2 does the subtraction in the engine.
//
// Committing a cutout through the ordinary markup path would build `.addMarkup` with
// `kind: .polygon` and no `parentMarkupID` — an orphan polygon that subtracts nothing — and
// leave `DocumentCommand.addCutout`, with the parent recompute, the Clipper2 difference and
// the undo inverse, unused.
//
// A cutout therefore needs one thing the other tools do not: *which area is this a hole in*.
// That question is answered here, as a pure function over candidate parents, so it can be
// tested without a canvas and reused by the keyboard flow.

/// An area markup a cutout could belong to, as the canvas offers it to the input flow.
///
/// The outline is the parent's outer ring in page space, already flattened — an ellipse arrives
/// as a polyline approximation, because which area holds the first point is the only question
/// asked of it here (whether the finished cutout overlaps it is the engine's, X-cutout-ui). Holes are
/// deliberately absent: a cutout drawn inside an existing hole is still a cutout of the same
/// parent, and the engine's union handles the overlap.
public struct CutoutParentCandidate: Hashable, Sendable, Identifiable {

    /// Identity of the parent markup.
    public let markupID: UUID
    /// The parent's outer ring, in page space, in order. Implicitly closed.
    public let outerRing: [PDFPointValue]
    /// Takeoff subject, used in the refusal message so the estimator knows what was rejected.
    public let subject: String
    /// Short instance label.
    public let label: String

    public var id: UUID { markupID }

    public init(
        markupID: UUID,
        outerRing: [PDFPointValue],
        subject: String = "",
        label: String = ""
    ) {
        self.markupID = markupID
        self.outerRing = outerRing
        self.subject = subject
        self.label = label
    }

    /// A localized name for messages: the subject, the label, or a fallback.
    public var displayName: String {
        let parts = [subject, label].filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return NSLocalizedString("the area", comment: "Fallback name for an unnamed area markup")
        }
        return parts.joined(separator: " · ")
    }

    /// Whether a page-space point lies inside the outer ring.
    ///
    /// Even-odd crossing count, edges inclusive. Edge inclusiveness matters: an estimator who
    /// snaps the first cutout vertex onto the parent's wall line must not be told the cutout is
    /// outside the area they just snapped to.
    public func contains(_ point: PDFPointValue) -> Bool {
        CutoutParentResolver.ring(outerRing, contains: point)
    }
}

/// Why a cutout could not be attached to a parent. Every case carries the words the interface
/// shows: an honest refusal beats a polygon nobody asked for, and that applies just as much
/// to "this is not inside anything".
public enum CutoutRefusalReason: Hashable, Sendable {

    /// The first click landed outside every area markup on the page.
    ///
    /// The only refusal the interface makes on its own. Whether a finished cutout overlaps its
    /// parent is the engine's to say, and the application tier asks it (X-cutout-ui): a cutout
    /// that only partly overlaps is accepted and loses the part outside, one that overlaps
    /// nothing is refused with "A cutout must overlap the area it is subtracted from."
    case noAreaUnderPoint

    /// The localized message, phrased as a refusal with a way forward.
    public var message: String {
        switch self {
        case .noAreaUnderPoint:
            return NSLocalizedString(
                "A cutout must start inside an area measurement. Draw it inside the area you want to subtract from.",
                comment: "Refusal when a cutout's first point is not inside any area markup"
            )
        }
    }
}

/// The outcome of asking "which area does this cutout belong to?".
public enum CutoutParentResolution: Hashable, Sendable {
    /// The cutout belongs to this parent.
    case resolved(CutoutParentCandidate)
    /// It belongs to nothing, for this reason.
    case refused(CutoutRefusalReason)
}

/// Resolves a cutout's parent from the areas on the page. Pure, `Sendable`, no view.
public enum CutoutParentResolver: Sendable {

    /// Picks the parent for a cutout whose first vertex is `point`.
    ///
    /// When several areas contain the point — a slab inside a floor inside a building outline —
    /// the *smallest* wins. That is the one the estimator is looking at, and it is the only
    /// choice that stays stable as the drawing grows outward.
    ///
    /// Equal areas are broken by identity, not by luck. The canvas publishes the candidates
    /// (``MeasurementInputController/setCutoutParents(_:)``) in no promised order, and `min(by:)` keeps whichever equal-area candidate it saw
    /// first — so two areas of the same size under one click (a duplicated markup left in
    /// place, two identical slabs) resolved to whichever the provider happened to list first,
    /// and the hole could come out of a different parent on the next run with the same click on
    /// the same drawing. Ordering by `markupID` makes the answer a function of the drawing.
    /// Finding CR-199.
    public static func resolve(
        firstPoint point: PDFPointValue,
        candidates: [CutoutParentCandidate]
    ) -> CutoutParentResolution {
        let containing = candidates.filter { $0.outerRing.count >= 3 && $0.contains(point) }
        guard let smallest = containing.min(by: { lhs, rhs in
            let lhsArea = absoluteArea(of: lhs.outerRing)
            let rhsArea = absoluteArea(of: rhs.outerRing)
            guard lhsArea == rhsArea else { return lhsArea < rhsArea }
            return lhs.markupID.uuidString < rhs.markupID.uuidString
        }) else { return .refused(.noAreaUnderPoint) }
        return .resolved(smallest)
    }

    /// Picks the parent for an Ellipse Cutout dragged or placed from `corner` to `opposite`
    /// (T-058).
    ///
    /// The two points are corners of the ellipse's bounding box, and the hole the engine
    /// subtracts is the ellipse inscribed in that box (`TakeoffSession.cutoutRings`). Resolving
    /// at the corners refused every concentric circular hole wider than about 0.707 R in a round
    /// parent of radius R — its box corners fall outside the circle while the hole itself fits —
    /// and a press corner inside a smaller neighbouring area attached the hole to an area it does
    /// not sit in. The parent is the smallest area containing the box's centre, exactly as a
    /// polygon cutout's first vertex chooses it.
    ///
    /// The ellipse is not held inside the parent here. That was a containment rule of the
    /// interface's own, stricter than the engine's: the engine accepts an opening that reaches
    /// past its area and subtracts the part inside (ADR-0015), and refuses only one that overlaps
    /// nothing — which the application tier asks the engine about (X-cutout-ui).
    public static func resolveEllipse(
        corner: PDFPointValue,
        opposite: PDFPointValue,
        candidates: [CutoutParentCandidate]
    ) -> CutoutParentResolution {
        let box = ZenitMarkupGeometry.boundingRect(corner, opposite)
        let centre = PDFPointValue(x: box.minX + box.size.width / 2, y: box.minY + box.size.height / 2)
        return resolve(firstPoint: centre, candidates: candidates)
    }

    /// Even-odd point-in-ring test with an on-edge fast path, in page space.
    public static func ring(_ ring: [PDFPointValue], contains point: PDFPointValue) -> Bool {
        guard ring.count >= 3 else { return false }
        var isInside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            if isOnSegment(point, from: previous, to: current) { return true }
            let straddles = (current.y > point.y) != (previous.y > point.y)
            if straddles {
                let t = (point.y - current.y) / (previous.y - current.y)
                let crossingX = current.x + t * (previous.x - current.x)
                if point.x < crossingX { isInside.toggle() }
            }
            previous = current
        }
        return isInside
    }

    /// Absolute shoelace area of a ring in square page points.
    public static func absoluteArea(of ring: [PDFPointValue]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        var previous = ring[ring.count - 1]
        for current in ring {
            sum += previous.x * current.y - current.x * previous.y
            previous = current
        }
        return abs(sum) / 2
    }

    /// Whether `point` lies on the segment `a…b`, within a page-point epsilon.
    private static func isOnSegment(
        _ point: PDFPointValue,
        from a: PDFPointValue,
        to b: PDFPointValue,
        epsilon: Double = 1e-9
    ) -> Bool {
        let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
        let lengthSquared = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)
        guard lengthSquared > 0 else { return point.distance(to: a) <= epsilon }
        guard abs(cross) <= epsilon * lengthSquared.squareRoot() + epsilon else { return false }
        let dot = (point.x - a.x) * (b.x - a.x) + (point.y - a.y) * (b.y - a.y)
        return dot >= -epsilon && dot <= lengthSquared + epsilon
    }
}

// `CutoutCommitting` — committing a cutout through `DocumentCommand.addCutout` rather than as a
// free markup — is declared in ZPDFUIPresentation beside `MeasurementToolPresenting`, so the
// application core can adopt it without depending on this UI package (IM-019).
