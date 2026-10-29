import Foundation
import ZPDFContracts
import ZPDFGeometry

// MARK: - Fence lines a person draws (NL-MEASURE-11)

/// What a trace with fence lines produced, and which fences it actually used.
public struct FencedTraceResult: Sendable, Hashable {
    /// The trace, exactly as ``RegionTracer/traceProposingClosures(_:click:maximumClosureWidth:maximumClosures:)``
    /// answers it on the page with the fences drawn in.
    public let outcome: OpeningAwareTraceResult
    /// The fences a boundary edge of the traced region runs along; empty when none was needed.
    public let fencesUsed: [ProposedClosure]
}

extension RegionTracer {

    /// Traces the click on the page with `fences` drawn in as walls (NL-MEASURE-11).
    ///
    /// A fence line is the person closing an opening themselves — one stroke across a door — so
    /// the tracer's refusal to invent a boundary is untouched: the fence is visible, the person
    /// drew it, and the result names the fences the region relied on. A fence that overshoots
    /// the walls is cut at them by the planar arrangement like any drawn line.
    public static func trace(
        _ prepared: PreparedTrace,
        click: PDFPoint,
        fences: [ProposedClosure],
        maximumClosureWidth: Double
    ) -> FencedTraceResult {
        let fenced = prepared.adding(closures: fences)
        let outcome = traceProposingClosures(fenced, click: click, maximumClosureWidth: maximumClosureWidth)
        let ring: [PDFPoint]
        switch outcome {
        case .traced(let region): ring = region.ring
        case .closesOpenings(let proposal): ring = proposal.region.ring
        case .refused(let result): ring = result.region?.ring ?? []
        }
        return FencedTraceResult(outcome: outcome, fencesUsed: fencesUsed(ring: ring, fences: fences))
    }

    /// The fences the ring runs along: a fence is used when it overlaps one of the ring's edges
    /// over a positive length — both lie on one line, within a millionth of the fence's length
    /// (at least 1e-6 pt), and their extents along it overlap. The ring may merge the fence with
    /// the collinear wall pieces on either side into one edge, so the test is an overlap, not a
    /// shared vertex.
    public static func fencesUsed(ring: [PDFPoint], fences: [ProposedClosure]) -> [ProposedClosure] {
        guard ring.count >= 3 else { return [] }
        let edges = ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) }
        return fences.filter { fence in
            let tolerance = Swift.max(1e-6, fence.width * 1e-6)
            return edges.contains { a, b in overlaps(fence: fence, edgeStart: a, edgeEnd: b, tolerance: tolerance) }
        }
    }

    static func overlaps(fence: ProposedClosure, edgeStart a: PDFPoint, edgeEnd b: PDFPoint, tolerance: Double) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > tolerance else { return false }
        let ux = dx / length, uy = dy / length
        func offLine(_ p: PDFPoint) -> Double { Swift.abs((p.x - a.x) * uy - (p.y - a.y) * ux) }
        guard offLine(fence.start) <= tolerance, offLine(fence.end) <= tolerance else { return false }
        func along(_ p: PDFPoint) -> Double { (p.x - a.x) * ux + (p.y - a.y) * uy }
        let lo = Swift.max(0, Swift.min(along(fence.start), along(fence.end)))
        let hi = Swift.min(length, Swift.max(along(fence.start), along(fence.end)))
        return hi - lo > tolerance
    }
}
