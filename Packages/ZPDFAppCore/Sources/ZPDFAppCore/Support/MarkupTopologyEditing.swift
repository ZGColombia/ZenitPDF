import Foundation
import ZPDFContracts

/// Inserting and deleting vertices of a committed markup (NL-MEASURE-06).
///
/// ``MarkupVertexEditing`` moves a vertex; this changes how many there are. Both write one
/// `DocumentCommand.editVertices`, so the markup keeps its identity, its row, its audit trail,
/// and one ⌘Z takes the edit back.
///
/// Indices are ``MarkupVertexEditing``'s canonical order: free points, segment ends, each
/// polygon's outer ring then its holes, then count marks. Only two chains can grow or shrink:
/// the free-point chain of an open, variable-length tool (polylength), and a polygon's outer
/// ring. Holes are rebuilt from the cutout markups on every recompute, so a hole vertex is
/// edited by editing its cutout; a count mark is removed, never inserted (Continue adds marks).
public enum MarkupTopologyEditing {

    /// The chain a vertex belongs to.
    public enum Chain: Equatable, Sendable {
        /// The free points, open.
        case freePoints
        /// A polygon's outer ring, closed.
        case outerRing(polygon: Int)
        /// The count marks.
        case countMarks
    }

    /// An edge of a committed markup near a point: the vertex it starts at, in canonical order,
    /// and the point on the edge nearest the pointer.
    public struct EdgeHit: Equatable, Sendable {
        public let startVertexIndex: Int
        public let projected: PDFPoint
        public let distance: Double
    }

    /// Whether a tool's vertex count can change. Fixed-count tools — a length is two points,
    /// an angle three — would stop being what they are, and Rise/Drop's per-segment values are
    /// aligned with its segments, so an inserted vertex would silently re-pair them.
    public static func allowsTopologyEdits(_ tool: MeasurementTool?) -> Bool {
        switch tool {
        case .polylength, .perimeter, .area, .volume, .wallArea, .trueSlopedArea, .polygonCutout, .count:
            return true
        default:
            return false
        }
    }

    /// Whether a tool's edges may be arcs (ADR-0030 §5.6.1): the chain and one-ring area tools,
    /// and the Polygon Cutout — its hole is subtracted from the parent on its arcs since
    /// ADR-0037 (C-08); it was left straight while the subtraction was the flattened boolean's.
    /// Not an Ellipse Cutout (an ellipse, with no edges) and not a count.
    public static func allowsArcEdges(_ tool: MeasurementTool?) -> Bool {
        switch tool {
        case .polylength, .perimeter, .area, .volume, .wallArea, .trueSlopedArea, .polygonCutout:
            return true
        default:
            return false
        }
    }

    /// Why an insert or a removal was refused (ADR-0030 §5.7), so the canvas can say so.
    public enum TopologyRefusal: Error, Equatable, Sendable {
        /// The tool's vertex count is fixed, or the index names no edge or vertex this editor
        /// grows or shrinks (a segment end, a hole vertex, the missing edge after an open chain's
        /// last vertex).
        case fixedShape
        /// The chain is at its minimum: two points, a three-point ring, one count mark.
        case atMinimum
        /// A curved edge makes the edit inexact: a vertex that joins a straight edge to an arc or
        /// arcs of two circles, or a click that lands on an arc's end, where there is nothing to cut.
        case curvedEdgeNotExact
    }

    /// The fewest vertices a chain may keep: two for an open chain, three for a ring, one mark.
    static func minimumCount(of chain: Chain) -> Int {
        switch chain {
        case .freePoints: return 2
        case .outerRing: return 3
        case .countMarks: return 1
        }
    }

    /// Where a canonical index lands: its chain and its position inside it, or `nil` for a
    /// segment end or a hole vertex, which this editor does not touch.
    static func locate(_ index: Int, in geometry: MeasurementGeometry) -> (chain: Chain, offset: Int)? {
        guard index >= 0 else { return nil }
        var cursor = index
        if cursor < geometry.points.count { return (.freePoints, cursor) }
        cursor -= geometry.points.count
        if cursor < geometry.segments.count * 2 { return nil }
        cursor -= geometry.segments.count * 2
        for (polygonIndex, polygon) in geometry.polygons.enumerated() {
            if cursor < polygon.outer.points.count { return (.outerRing(polygon: polygonIndex), cursor) }
            cursor -= polygon.outer.points.count
            let holeCount = polygon.holes.reduce(0) { $0 + $1.points.count }
            if cursor < holeCount { return nil }
            cursor -= holeCount
        }
        if cursor < geometry.countPoints.count { return (.countMarks, cursor) }
        return nil
    }

    /// The canonical index of the first vertex of a chain.
    static func base(of chain: Chain, in geometry: MeasurementGeometry) -> Int {
        switch chain {
        case .freePoints:
            return 0
        case .outerRing(let polygon):
            var index = geometry.points.count + geometry.segments.count * 2
            for earlier in geometry.polygons.prefix(polygon) {
                index += earlier.outer.points.count + earlier.holes.reduce(0) { $0 + $1.points.count }
            }
            return index
        case .countMarks:
            // Counted forwards: stored circles' and arcs' handles follow the count marks
            // (NL-MEASURE-06), so "everything but the marks" is no longer the marks' base.
            return geometry.points.count + geometry.segments.count * 2
                + geometry.polygons.reduce(0) { $0 + $1.outer.points.count + $1.holes.reduce(0) { $0 + $1.points.count } }
        }
    }

    /// The edge nearest `point` within `tolerance`, over the chains this editor can grow.
    public static func nearestEdge(
        to point: PDFPoint,
        in geometry: MeasurementGeometry,
        tool: MeasurementTool?,
        tolerance: Double
    ) -> EdgeHit? {
        guard allowsTopologyEdits(tool), tool != .count else { return nil }
        var best: EdgeHit?
        // An arc edge (ADR-0030 §5) is hit on the arc, not on its chord: the projection is the
        // nearest point of the arc, so an inserted vertex lands on the curve.
        func consider(_ a: PDFPoint, _ b: PDFPoint, bulge: Double, start: Int) {
            let projected = BulgeArc.nearestPoint(to: point, from: a, to: b, bulge: bulge).point
            let distance = projected.distance(to: point)
            guard distance <= tolerance, distance < (best?.distance ?? .infinity) else { return }
            best = EdgeHit(startVertexIndex: start, projected: projected, distance: distance)
        }
        if geometry.points.count >= 2, geometry.polygons.isEmpty {
            let bulges = geometry.validPointBulges
            for index in 0..<(geometry.points.count - 1) {
                consider(geometry.points[index], geometry.points[index + 1], bulge: bulges?[index] ?? 0, start: index)
            }
        }
        for polygonIndex in geometry.polygons.indices {
            let outer = geometry.polygons[polygonIndex].outer
            let ring = outer.points
            guard ring.count >= 2 else { continue }
            let bulges = outer.validBulges
            let base = base(of: .outerRing(polygon: polygonIndex), in: geometry)
            for index in ring.indices {
                consider(ring[index], ring[(index + 1) % ring.count], bulge: bulges?[index] ?? 0, start: base + index)
            }
        }
        return best
    }

    /// A copy of `geometry` with `point` inserted after the vertex at `startVertexIndex` — on
    /// the edge that runs from it to the next vertex of the same chain.
    ///
    /// - Returns: `nil` when the tool's vertex count is fixed, the index names no growable
    ///   chain, or it names the last vertex of an open chain (there is no edge after it).
    public static func inserting(
        _ point: PDFPoint,
        afterVertex startVertexIndex: Int,
        in geometry: MeasurementGeometry,
        tool: MeasurementTool?
    ) -> MeasurementGeometry? {
        try? insertion(point, afterVertex: startVertexIndex, in: geometry, tool: tool).get()
    }

    /// ``inserting(_:afterVertex:in:tool:)`` with the reason when nothing can be inserted.
    public static func insertion(
        _ point: PDFPoint,
        afterVertex startVertexIndex: Int,
        in geometry: MeasurementGeometry,
        tool: MeasurementTool?
    ) -> Result<MeasurementGeometry, TopologyRefusal> {
        guard allowsTopologyEdits(tool), tool != .count, point.isFinite,
              let (chain, offset) = locate(startVertexIndex, in: geometry) else { return .failure(.fixedShape) }
        var edited = geometry
        switch chain {
        case .freePoints:
            guard geometry.polygons.isEmpty, offset + 1 < edited.points.count else { return .failure(.fixedShape) }
            // Arc segments (ADR-0030 §5): a straight edge splits into two straight ones; an arc
            // splits into two arcs of the same circle at the point of the arc nearest `point`,
            // each with the bulge of its own sweep — the curve does not move.
            if let bulges = geometry.validPointBulges {
                guard let cut = cutting(from: geometry.points[offset], to: geometry.points[offset + 1], bulge: bulges[offset], near: point) else {
                    return .failure(.curvedEdgeNotExact)
                }
                edited.pointBulges?[offset] = cut.first
                edited.pointBulges?.insert(cut.second, at: offset + 1)
                edited.points.insert(cut.point, at: offset + 1)
            } else {
                edited.points.insert(point, at: offset + 1)
            }
        case .outerRing(let polygon):
            let ring = geometry.polygons[polygon].outer
            if let bulges = ring.validBulges {
                guard let cut = cutting(from: ring.points[offset], to: ring.points[(offset + 1) % ring.points.count], bulge: bulges[offset], near: point) else {
                    return .failure(.curvedEdgeNotExact)
                }
                edited.polygons[polygon].outer.bulges?[offset] = cut.first
                edited.polygons[polygon].outer.bulges?.insert(cut.second, at: offset + 1)
                edited.polygons[polygon].outer.points.insert(cut.point, at: offset + 1)
            } else {
                edited.polygons[polygon].outer.points.insert(point, at: offset + 1)
            }
        case .countMarks:
            return .failure(.fixedShape)
        }
        return .success(edited)
    }

    /// Where an insertion near `point` cuts the edge `a → b`: the vertex to insert and the two
    /// bulges either side of it. A straight edge takes `point` as given with two straight halves;
    /// an arc is cut at its point nearest `point` (``BulgeArc/split(from:to:bulge:at:)``), and a
    /// point that projects onto an end of the arc cuts nothing (`nil`).
    static func cutting(from a: PDFPoint, to b: PDFPoint, bulge: Double, near point: PDFPoint) -> (point: PDFPoint, first: Double, second: Double)? {
        guard bulge != 0, BulgeArc.arc(from: a, to: b, bulge: bulge) != nil else { return (point, 0, 0) }
        let nearest = BulgeArc.nearestPoint(to: point, from: a, to: b, bulge: bulge)
        guard let cut = BulgeArc.split(from: a, to: b, bulge: bulge, at: nearest.fraction),
              cut.point.distance(to: a) > 1e-9, cut.point.distance(to: b) > 1e-9 else { return nil }
        return (cut.point, cut.firstBulge, cut.secondBulge)
    }

    /// A copy of `geometry` whose edge after `startVertexIndex` bends into the circular arc
    /// through `point` (NL-MEASURE-05, ADR-0030 §5) — or straightens, when `point` lies on the
    /// chord. `nil` for an edge this editor cannot bend (a loose segment, a count, a cutout, the
    /// missing edge after an open chain's last vertex) or a point that makes no arc (on an end).
    ///
    /// The bulge is `tan(θ/4)` of the arc through the edge's two ends and `point`: with the
    /// chord `c` and the point's signed distance `h` from the chord (left positive), the sagitta
    /// of the circle through the three points gives `b = −2h' / c` for the arc's own sagitta `h'`,
    /// taken from the circumscribed circle so the arc passes through `point` exactly.
    public static func bending(
        edgeAfter startVertexIndex: Int,
        through point: PDFPoint,
        in geometry: MeasurementGeometry,
        tool: MeasurementTool?
    ) -> MeasurementGeometry? {
        // Only a tool whose edges may be arcs (``allowsArcEdges``): a Polygon Cutout among them
        // since its parent subtracts the hole on its arcs (ADR-0037, C-08).
        guard allowsTopologyEdits(tool), allowsArcEdges(tool), point.isFinite,
              let (chain, offset) = locate(startVertexIndex, in: geometry) else { return nil }
        var edited = geometry
        switch chain {
        case .freePoints:
            guard geometry.polygons.isEmpty, offset + 1 < geometry.points.count,
                  let bulge = bulge(from: geometry.points[offset], to: geometry.points[offset + 1], through: point) else { return nil }
            var bulges = geometry.pointBulges.flatMap { $0.count == geometry.points.count ? $0 : nil }
                ?? Array(repeating: 0, count: geometry.points.count)
            bulges[offset] = bulge
            edited.pointBulges = bulges.contains { $0 != 0 } ? bulges : nil
        case .outerRing(let polygon):
            let ring = geometry.polygons[polygon].outer
            guard ring.points.count >= 3,
                  let bulge = bulge(from: ring.points[offset], to: ring.points[(offset + 1) % ring.points.count], through: point) else { return nil }
            var bulges = ring.bulges.flatMap { $0.count == ring.points.count ? $0 : nil }
                ?? Array(repeating: 0, count: ring.points.count)
            bulges[offset] = bulge
            edited.polygons[polygon].outer.bulges = bulges.contains { $0 != 0 } ? bulges : nil
        case .countMarks:
            return nil
        }
        return edited
    }

    /// The bulge of the arc from `a` to `b` through `p`: `0` when `p` is on the chord, `nil`
    /// when `p` is on an end or the chord is degenerate. The rule is the contracts' one
    /// (`BulgeArc.bulge(from:to:through:)`), which a three-point Arc Length is drawn by (X-042).
    public static func bulge(from a: PDFPoint, to b: PDFPoint, through p: PDFPoint) -> Double? {
        BulgeArc.bulge(from: a, to: b, through: p)
    }

    /// A copy of `geometry` with the vertex at `index` removed.
    ///
    /// - Returns: `nil` when the tool's vertex count is fixed, the index names no editable
    ///   vertex, or removing it would leave the chain below its minimum (two points, a
    ///   three-point ring, one count mark) — a markup is never edited into a shape that is not
    ///   the tool's any more.
    public static func removing(
        vertexAt index: Int,
        in geometry: MeasurementGeometry,
        tool: MeasurementTool?
    ) -> MeasurementGeometry? {
        try? removal(vertexAt: index, in: geometry, tool: tool).get()
    }

    /// ``removing(vertexAt:in:tool:)`` with the reason when the vertex cannot be removed.
    public static func removal(
        vertexAt index: Int,
        in geometry: MeasurementGeometry,
        tool: MeasurementTool?
    ) -> Result<MeasurementGeometry, TopologyRefusal> {
        guard allowsTopologyEdits(tool), let (chain, offset) = locate(index, in: geometry) else { return .failure(.fixedShape) }
        var edited = geometry
        switch chain {
        case .freePoints:
            guard edited.points.count > minimumCount(of: chain) else { return .failure(.atMinimum) }
            // Arc segments (ADR-0030 §5): removing an end of an open chain removes its one edge,
            // arc or not. Removing an inner vertex makes its two edges one: two straight edges
            // become one straight edge, two arcs of one circle turning the same way become the
            // one arc they are part of, and anything else is refused — no single bulge says what
            // a straight edge and an arc, or arcs of two circles, would be.
            if let bulges = geometry.validPointBulges {
                let last = geometry.points.count - 1
                var remaining = bulges
                if offset == 0 {
                    remaining.removeFirst()
                } else if offset == last {
                    remaining.removeLast()
                    remaining[remaining.count - 1] = 0
                } else {
                    guard let joined = joinedBulge(geometry.points[offset - 1], geometry.points[offset], geometry.points[offset + 1],
                                                   first: bulges[offset - 1], second: bulges[offset]) else { return .failure(.curvedEdgeNotExact) }
                    remaining[offset - 1] = joined
                    remaining.remove(at: offset)
                }
                edited.pointBulges = remaining.contains { $0 != 0 } ? remaining : nil
            }
            edited.points.remove(at: offset)
        case .outerRing(let polygon):
            let ring = geometry.polygons[polygon].outer
            guard ring.points.count > minimumCount(of: chain) else { return .failure(.atMinimum) }
            if let bulges = ring.validBulges {
                let count = bulges.count
                let previous = (offset - 1 + count) % count
                guard let joined = joinedBulge(ring.points[previous], ring.points[offset], ring.points[(offset + 1) % count],
                                               first: bulges[previous], second: bulges[offset]) else { return .failure(.curvedEdgeNotExact) }
                var remaining = bulges
                remaining[previous] = joined
                remaining.remove(at: offset)
                edited.polygons[polygon].outer.bulges = remaining.contains { $0 != 0 } ? remaining : nil
            }
            edited.polygons[polygon].outer.points.remove(at: offset)
        case .countMarks:
            guard edited.countPoints.count > minimumCount(of: chain) else { return .failure(.atMinimum) }
            edited.countPoints.remove(at: offset)
        }
        return .success(edited)
    }

    /// The bulge of the one edge `a → c` that replaces `a → b` (bulge `first`) and `b → c` (bulge
    /// `second`) when `b` is removed: `0` for two straight edges (removing a corner of a straight
    /// chain has always straightened it), the joined arc for two arcs of one circle turning the
    /// same way, and `nil` for a straight edge and an arc, or two arcs not on one circle.
    static func joinedBulge(_ a: PDFPoint, _ b: PDFPoint, _ c: PDFPoint, first: Double, second: Double) -> Double? {
        if first == 0, second == 0 { return 0 }
        guard first != 0, second != 0 else { return nil }
        return BulgeArc.joined(a, b, c, first: first, second: second)
    }

    /// The point on segment `a`–`b` nearest `p`.
    public static func project(_ p: PDFPoint, ontoSegmentFrom a: PDFPoint, to b: PDFPoint) -> PDFPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return PDFPoint(x: a.x + t * dx, y: a.y + t * dy)
    }
}
