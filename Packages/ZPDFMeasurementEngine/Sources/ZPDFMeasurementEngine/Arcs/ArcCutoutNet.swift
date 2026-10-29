import Foundation
import ZPDFContracts

/// The net region of an outer ring minus the union of cutout rings when any of them has arc edges,
/// computed on the arcs themselves (NL-MEASURE-05 remainder, C-08).
///
/// # Why
///
/// Clipper2 sees integer polygons, so ``ArealMeasure`` runs the cutout booleans on every ring
/// flattened to chords of at most 1e-3 pt sagitta (ADR-0030 §5.2). That is exact for a cutout clear
/// of every arc, and was kept exact for cutouts strictly inside and apart from one another (K-10).
/// Anywhere else — a circular cutout over the outer edge, two round cutouts that overlap, a straight
/// cutout across an arc edge of the outer ring — the area removed was the chord polygon's: a radius-2
/// cutout over an edge removed 4.8e-3 pt² too little, two overlapping ones 1.1e-2, and a cutout
/// drawn exactly on an arc-edged parent left the chords' residue standing instead of zero. The
/// boundary under `outerPlusCutoutEdges` was the chords too, under a precision warning.
///
/// # How
///
/// Green's theorem, as ``ExactNetArea`` does for straight rings, with ``ArcEdge``'s exact crossings:
///
/// - every ring is made counter-clockwise, and every edge is cut wherever an edge of another ring
///   crosses or touches it — straight/straight, straight/arc on the circle, arc/arc circle–circle,
///   and the ends of a collinear or co-circular overlap. A cut arc becomes arcs of the same circle
///   (``ArcEdge/split(at:points:)``), and each crossing is pooled once so both rings meet in the
///   same point (``ArcVertexPool``);
/// - a piece of the outer ring bounds the net region when it lies outside every cutout, or on a
///   cutout's boundary running the other way (the cutout lies outside there);
/// - a piece of a cutout bounds it, walked backwards, when it lies inside the outer ring and outside
///   every other cutout; a piece two cutouts share running the same way is kept once;
/// - the area is the sum over the kept pieces of each piece's chord term and circular segment
///   (``ArcEdge/signedAreaContribution(origin:)``), origin-shifted and compensated.
///
/// The cutting and the placing are ``ArcArrangement``'s, the same code the exact booleans run: a
/// piece's place is read at its midpoint by length — on the curve, never on the chord — by the
/// winding number of the true boundary (``ArcRing/winding(of:)``). A midpoint that lies on another
/// ring's boundary without the two pieces coinciding is ambiguous, and the answer is `nil`; so is a
/// ring that crosses itself, and so is work beyond ``workBudget``. The caller then keeps the
/// flattened boolean and says so: this routine sharpens a number, it never guesses one.
enum ArcCutoutNet {

    /// The most edge pairs and point-edge tests one call performs before answering `nil`.
    static let workBudget = 20_000_000

    struct Result: Sendable {
        /// The net area in square page points: the outer ring less the union of the cutouts.
        var area: Double
        /// The pieces of the drawn edges that bound the net region, each walked with the region on
        /// its left, arcs as arcs.
        var boundary: [ArcEdge]
        /// True when no two rings meet anywhere and every cutout lies inside the outer ring and
        /// outside every other cutout, so the net region is the outer ring less each cutout's own
        /// area — the case ``ArealMeasure`` already measures exactly from the rings' own areas.
        var ringsAreApart: Bool
    }

    /// The net region of `outer` minus the union of `holes`, or `nil` when it cannot be decided
    /// exactly (see the type's documentation).
    ///
    /// - Parameters:
    ///   - outer: one closed ring, either winding, arcs as bulges.
    ///   - holes: closed rings, either winding, in the caller's canonical order — which decides only
    ///     which of two identical shared pieces is the one kept, never the value.
    static func net(outer: PolygonRing, holes: [PolygonRing]) -> Result? {
        guard let outerRing = ArcRing(ArealMeasure.closed(outer)) else { return nil }
        var rings = [outerRing.counterClockwise]
        for hole in holes {
            guard let ring = ArcRing(ArealMeasure.closed(hole)) else { return nil }
            rings.append(ring.counterClockwise)
        }
        let tolerance = rings.reduce(1e-9) { Swift.max($0, $1.tolerance) }
        guard rings.reduce(0, { $0 + $1.edges.count }) <= workBudget else { return nil }
        for ring in rings where ring.isSelfIntersecting(tolerance: tolerance) { return nil }

        // 1. and 2. Cut every edge where an edge of another ring crosses or touches it, and place
        //    each piece against the other rings: the arrangement the exact booleans use (U-092).
        guard var arrangement = ArcArrangement(rings: rings, tolerance: tolerance, workBudget: workBudget) else { return nil }
        let pieces = arrangement.pieces

        // 3. Keep the pieces that bound the net region and integrate along them.
        let outerBox = arrangement.bounds(ofRing: 0)
        let origin = PDFPoint(x: outerBox.minX, y: outerBox.minY)
        var terms: [Double] = []
        var boundary: [ArcEdge] = []
        var keptAll = true
        for (index, ringPieces) in pieces.enumerated() {
            for piece in ringPieces {
                var keep = true
                if index == 0 {
                    for other in 1..<rings.count {
                        guard let location = arrangement.place(piece, in: other) else { return nil }
                        if location == .inside || location == .sharedSame { keep = false; break }
                    }
                } else {
                    guard let inOuter = arrangement.place(piece, in: 0) else { return nil }
                    keep = inOuter == .inside
                    if keep {
                        for other in 1..<rings.count where other != index {
                            guard let location = arrangement.place(piece, in: other) else { return nil }
                            switch location {
                            case .inside, .sharedOpposite: keep = false
                            case .sharedSame: if other < index { keep = false }
                            case .outside: break
                            }
                            if !keep { break }
                        }
                    }
                }
                guard arrangement.work <= workBudget else { return nil }
                guard keep else {
                    keptAll = false
                    continue
                }
                if index == 0 {
                    terms.append(piece.edge.signedAreaContribution(origin: origin))
                    boundary.append(piece.edge)
                } else {
                    let reversed = piece.edge.reversed
                    terms.append(reversed.signedAreaContribution(origin: origin))
                    boundary.append(reversed)
                }
            }
        }
        let area = EngineNumerics.sum(terms)
        guard area.isFinite else { return nil }
        // The net region can never exceed the outer ring; more is a failure, not a value.
        let outerArea = rings[0].signedArea
        guard area <= outerArea + 64 * tolerance * rings[0].length else { return nil }
        return Result(
            area: Swift.min(outerArea, Swift.max(0, area)),
            boundary: boundary,
            ringsAreApart: arrangement.crossingCount == 0 && keptAll
        )
    }
}
