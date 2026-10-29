import Foundation
import ZPDFContracts

/// One closed region, ready to become an area markup.
public struct TracedRegion: Sendable, Hashable {

    /// The boundary in order, counter-clockwise, with the closing vertex **not** repeated —
    /// the same convention as `PolygonRing`.
    ///
    /// The array is canonicalised: it starts at the ring's lexicographically smallest vertex
    /// and runs counter-clockwise, so the same face always produces the same array whichever
    /// edge the walk happened to start from.
    public let ring: [PDFPoint]

    /// Unsigned area of ``ring`` in square page points, by the shoelace formula. This is page
    /// space: no drawing scale has been applied.
    public let area: Double

    /// Perimeter of ``ring`` in page points.
    public let perimeter: Double

    /// How many breaks in the boundary were joined under ``TraceOptions/gapTolerance``: the
    /// joins ``ring`` runs along, not every join made in the drawing round it.
    public let bridgedGapCount: Int

    /// The widest break on ``ring`` that was joined, in page points, or `0` when the boundary
    /// met exactly.
    ///
    /// This is the number the interface owes the user: a region traced across a 2.4 pt join is
    /// a different claim from one whose walls met.
    public let largestBridgedGap: Double

    /// Closed outlines inside the ring — columns, shafts, fixed furniture drawn as closed shapes,
    /// standing free or tied to the boundary by a line or a shared corner — each
    /// counter-clockwise, largest first (NL-AUTO-10). **Not** deducted from ``area``: they are
    /// proposals the interface offers as cutouts, and only a person decides that a closed
    /// outline inside a room is a hole in its floor.
    public let islands: [[PDFPoint]]

    public init(
        ring: [PDFPoint],
        area: Double,
        perimeter: Double,
        bridgedGapCount: Int,
        largestBridgedGap: Double,
        islands: [[PDFPoint]] = []
    ) {
        self.ring = ring
        self.area = area
        self.perimeter = perimeter
        self.bridgedGapCount = bridgedGapCount
        self.largestBridgedGap = largestBridgedGap
        self.islands = islands
    }
}

/// What a trace produced. Refusal is a result, not an error: two of the three cases are the
/// engine declining to guess, and both name why.
public enum TraceResult: Sendable, Hashable {

    /// A closed boundary was followed all the way round.
    case traced(TracedRegion)

    /// No closed boundary encloses the click.
    ///
    /// - Parameter gapAt: where the boundary gives up, when the engine can point at it — the
    ///   middle of the narrowest unbridged break on the face it walked. `nil` when there is
    ///   nothing to point at: the click sits in the unbounded outside of the drawing, or in a
    ///   region whose boundary simply is not there.
    ///
    /// This is the case the tracer's refusal rule exists for. A break wider than
    /// ``TraceOptions/gapTolerance`` produces this, never a bridged ring.
    case notClosed(gapAt: PDFPoint?)

    /// The page, or the work the trace would need, is over a limit in ``TraceOptions``.
    ///
    /// - Parameter count: the measured quantity that broke its cap — primitives, segments,
    ///   pair tests or walk steps, whichever tripped first.
    case tooComplex(count: Int)

    /// The region, when there is one.
    public var region: TracedRegion? {
        if case .traced(let region) = self { return region }
        return nil
    }

    /// `true` when the engine declined to produce a region.
    public var isRefusal: Bool {
        if case .traced = self { return false }
        return true
    }
}

extension TraceResult: CustomStringConvertible {
    public var description: String {
        switch self {
        case .traced(let region):
            "traced \(region.ring.count) vertices, area \(region.area) pt^2"
        case .notClosed(let gap):
            if let gap {
                "boundary not closed near (\(gap.x), \(gap.y))"
            } else {
                "boundary not closed: no enclosing region"
            }
        case .tooComplex(let count):
            "too complex to trace: \(count)"
        }
    }
}
