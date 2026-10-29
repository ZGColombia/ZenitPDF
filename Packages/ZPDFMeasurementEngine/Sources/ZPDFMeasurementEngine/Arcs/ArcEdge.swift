import Foundation
import ZPDFContracts

/// One edge of a ring or chain with arc segments (NL-MEASURE-05, ADR-0030 §5): a straight segment
/// (`bulge == 0`) or the circular arc `bulge = tan(θ/4)` from ``start`` to ``end``.
///
/// This is the vocabulary the exact edits are written in — splitting an area along a line, merging
/// areas, cutting a chain at a Scale Region boundary. Every operation keeps an arc an arc: an arc
/// that is cut becomes two arcs of the same circle with the bulges of their own sweeps, never chords.
public struct ArcEdge: Hashable, Sendable {

    public var start: PDFPoint
    public var end: PDFPoint
    /// `tan(θ/4)` of the included angle; `0` is straight.
    public var bulge: Double

    public init(start: PDFPoint, end: PDFPoint, bulge: Double = 0) {
        self.start = start
        self.end = end
        self.bulge = bulge.isFinite ? bulge : 0
    }

    /// The exact circle, or `nil` for a straight edge.
    public var arc: ArcGeometry? { BulgeArc.arc(from: start, to: end, bulge: bulge) }

    /// Whether the edge is an arc.
    public var isArc: Bool { arc != nil }

    /// The same edge walked the other way: the ends swapped and the turn reversed.
    public var reversed: ArcEdge { ArcEdge(start: end, end: start, bulge: -bulge) }

    /// Page length: `r·|θ|` for an arc, the chord for a straight edge.
    public var length: Double { arc?.pdfArcLength ?? start.distance(to: end) }

    /// The point at `fraction` of the edge, by length.
    public func point(at fraction: Double) -> PDFPoint {
        BulgeArc.point(from: start, to: end, bulge: bulge, at: fraction)
    }

    /// The midpoint by length.
    public var midpoint: PDFPoint { point(at: 0.5) }

    /// The unit direction of travel at `fraction` of the edge.
    public func tangent(at fraction: Double) -> (dx: Double, dy: Double) {
        if let arc {
            let angle = arc.startAngle + arc.sweepAngle * Swift.max(0, Swift.min(1, fraction))
            let sign: Double = arc.sweepAngle > 0 ? 1 : -1
            return (-Foundation.sin(angle) * sign, Foundation.cos(angle) * sign)
        }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return (0, 0) }
        return (dx / length, dy / length)
    }

    /// The signed curvature: `+1/r` for a counter-clockwise arc, `−1/r` clockwise, `0` straight.
    public var curvature: Double {
        guard let arc, arc.radius > 0 else { return 0 }
        return (arc.sweepAngle > 0 ? 1 : -1) / arc.radius
    }

    /// The point of the edge nearest `probe`, with its fraction and distance.
    public func nearest(to probe: PDFPoint) -> (point: PDFPoint, fraction: Double, distance: Double) {
        BulgeArc.nearestPoint(to: probe, from: start, to: end, bulge: bulge)
    }

    /// The fraction at which a point already known to lie on the edge sits, or `nil` when it is not
    /// within `tolerance` of the edge.
    public func fraction(of point: PDFPoint, tolerance: Double) -> Double? {
        let hit = nearest(to: point)
        return hit.distance <= tolerance ? hit.fraction : nil
    }

    /// The edge cut at the given fractions, which must be strictly inside `(0, 1)` and ascending:
    /// `n` fractions give `n + 1` pieces whose ends join exactly. An arc's pieces are arcs of the
    /// same circle, each with the bulge of its own sweep, `tan(Δf·θ/4)`.
    ///
    /// - Parameter points: the cut points to use for the joins, one per fraction, when the caller
    ///   already holds them (an intersection shared with another edge must be the *same* point on
    ///   both, or the pieces of two rings would not meet). `nil` computes them from the fractions.
    public func split(at fractions: [Double], points: [PDFPoint]? = nil) -> [ArcEdge] {
        guard !fractions.isEmpty else { return [self] }
        let joins = points ?? fractions.map { point(at: $0) }
        let sweep = arc?.sweepAngle
        var pieces: [ArcEdge] = []
        pieces.reserveCapacity(fractions.count + 1)
        var from = start
        var previous = 0.0
        for (index, fraction) in fractions.enumerated() {
            let to = joins[index]
            pieces.append(ArcEdge(start: from, end: to, bulge: sweep.map { BulgeArc.bulge(forSweep: $0 * (fraction - previous)) } ?? 0))
            from = to
            previous = fraction
        }
        pieces.append(ArcEdge(start: from, end: end, bulge: sweep.map { BulgeArc.bulge(forSweep: $0 * (1 - previous)) } ?? 0))
        return pieces
    }

    /// The signed area this edge adds to a ring's shoelace, origin-shifted to `origin`: the
    /// cross-product term of its chord plus the signed circular segment of its arc.
    func signedAreaContribution(origin: PDFPoint) -> Double {
        let ax = start.x - origin.x, ay = start.y - origin.y
        let bx = end.x - origin.x, by = end.y - origin.y
        return (ax * by - bx * ay) / 2 + BulgeArc.segmentArea(from: start, to: end, bulge: bulge)
    }

    /// Whether the bounding boxes of two edges, grown by `tolerance`, overlap — the cheap test
    /// that keeps the pairwise crossing loops from solving circles for edges far apart.
    func mayMeet(_ other: ArcEdge, tolerance: Double) -> Bool {
        let a = bounds, b = other.bounds
        return a.minX - tolerance <= b.maxX && b.minX - tolerance <= a.maxX
            && a.minY - tolerance <= b.maxY && b.minY - tolerance <= a.maxY
    }

    /// The bounding box of the edge: its stored ends and, on an arc, the arc's axis extremes
    /// (`ArcGeometry.axisExtremes`, the one extent rule shared with `PolygonRing.bounds` and the
    /// snap index, W-089).
    var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Swift.min(start.x, end.x), maxX = Swift.max(start.x, end.x)
        var minY = Swift.min(start.y, end.y), maxY = Swift.max(start.y, end.y)
        for point in arc?.axisExtremes ?? [] {
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }
        return (minX, minY, maxX, maxY)
    }
}

// MARK: - Intersections

extension ArcEdge {

    /// One crossing of two edges: the point and its fraction on each.
    public struct Crossing: Hashable, Sendable {
        public var point: PDFPoint
        public var fractionOnFirst: Double
        public var fractionOnSecond: Double
    }

    /// Where two edges meet, ends included, ordered along the first. Overlapping collinear straight
    /// edges and overlapping arcs of one circle report the ends of the overlap. A tangent contact
    /// is reported once.
    public func crossings(with other: ArcEdge, tolerance: Double) -> [Crossing] {
        let raw: [Crossing]
        switch (arc, other.arc) {
        case (nil, nil): raw = Self.lineLine(self, other, tolerance: tolerance)
        case (let a?, nil): raw = Self.arcLine(self, a, other, tolerance: tolerance)
        case (nil, let b?): raw = Self.arcLine(other, b, self, tolerance: tolerance).map {
            Crossing(point: $0.point, fractionOnFirst: $0.fractionOnSecond, fractionOnSecond: $0.fractionOnFirst)
        }
        case (let a?, let b?): raw = Self.arcArc(self, a, other, b, tolerance: tolerance)
        }
        // Merge duplicates (a tangent contact solved twice, an end found by two routes).
        var result: [Crossing] = []
        for crossing in raw.sorted(by: { $0.fractionOnFirst < $1.fractionOnFirst })
        where !result.contains(where: { $0.point.distance(to: crossing.point) <= tolerance }) {
            result.append(crossing)
        }
        return result
    }

    private static func clamp(_ value: Double) -> Double { Swift.max(0, Swift.min(1, value)) }

    private static func lineLine(_ p: ArcEdge, _ q: ArcEdge, tolerance: Double) -> [Crossing] {
        let rx = p.end.x - p.start.x, ry = p.end.y - p.start.y
        let sx = q.end.x - q.start.x, sy = q.end.y - q.start.y
        let rLength = (rx * rx + ry * ry).squareRoot(), sLength = (sx * sx + sy * sy).squareRoot()
        guard rLength > 0, sLength > 0 else { return [] }
        let denominator = rx * sy - ry * sx
        let qpx = q.start.x - p.start.x, qpy = q.start.y - p.start.y
        if Swift.abs(denominator) <= 1e-14 * rLength * sLength {
            // Parallel. Collinear when q's start is on p's line; then the overlap's ends count.
            let offLine = Swift.abs(qpx * ry - qpy * rx) / rLength
            guard offLine <= tolerance else { return [] }
            var result: [Crossing] = []
            func add(_ point: PDFPoint) {
                guard let t = p.fraction(of: point, tolerance: tolerance),
                      let u = q.fraction(of: point, tolerance: tolerance) else { return }
                result.append(Crossing(point: point, fractionOnFirst: t, fractionOnSecond: u))
            }
            add(p.start); add(p.end); add(q.start); add(q.end)
            return result
        }
        let t = (qpx * sy - qpy * sx) / denominator
        let u = (qpx * ry - qpy * rx) / denominator
        let tSlack = tolerance / rLength, uSlack = tolerance / sLength
        guard t >= -tSlack, t <= 1 + tSlack, u >= -uSlack, u <= 1 + uSlack else { return [] }
        let tc = clamp(t), uc = clamp(u)
        // An end within tolerance is that end exactly, so two rings that share a vertex share it.
        let point: PDFPoint
        if tc == 0 || t <= tSlack { point = p.start }
        else if tc == 1 || t >= 1 - tSlack { point = p.end }
        else if uc == 0 || u <= uSlack { point = q.start }
        else if uc == 1 || u >= 1 - uSlack { point = q.end }
        else { point = PDFPoint(x: p.start.x + t * rx, y: p.start.y + t * ry) }
        return [Crossing(
            point: point,
            fractionOnFirst: p.fraction(of: point, tolerance: .infinity) ?? tc,
            fractionOnSecond: q.fraction(of: point, tolerance: .infinity) ?? uc
        )]
    }

    /// Line–circle: `|a + t·(b − a) − c|² = r²`, kept where `t ∈ [0, 1]` and the angle is inside
    /// the sweep.
    private static func arcLine(_ arcEdge: ArcEdge, _ arc: ArcGeometry, _ line: ArcEdge, tolerance: Double) -> [Crossing] {
        let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
        let fx = line.start.x - arc.center.x, fy = line.start.y - arc.center.y
        let a = dx * dx + dy * dy
        guard a > 0 else { return [] }
        let b = 2 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - arc.radius * arc.radius
        var discriminant = b * b - 4 * a * c
        let length = a.squareRoot()
        // Distance from the centre to the line, against the radius: a near-tangent is a tangent.
        let distance = Swift.abs(fx * dy - fy * dx) / length
        if Swift.abs(distance - arc.radius) <= tolerance { discriminant = Swift.max(0, discriminant) }
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        let ts = root == 0 ? [-b / (2 * a)] : [(-b - root) / (2 * a), (-b + root) / (2 * a)]
        var result: [Crossing] = []
        let slack = tolerance / length
        for t in ts where t >= -slack && t <= 1 + slack {
            var point = PDFPoint(x: line.start.x + clamp(t) * dx, y: line.start.y + clamp(t) * dy)
            // Snap to a shared end so the two rings meet in one vertex.
            for end in [arcEdge.start, arcEdge.end, line.start, line.end] where end.distance(to: point) <= tolerance {
                point = end
                break
            }
            guard let onArc = arcEdge.fraction(of: point, tolerance: tolerance),
                  let onLine = line.fraction(of: point, tolerance: tolerance) else { continue }
            result.append(Crossing(point: point, fractionOnFirst: onArc, fractionOnSecond: onLine))
        }
        return result
    }

    /// Circle–circle, or the ends of the overlap for two arcs of one circle.
    private static func arcArc(_ p: ArcEdge, _ a: ArcGeometry, _ q: ArcEdge, _ b: ArcGeometry, tolerance: Double) -> [Crossing] {
        let dx = b.center.x - a.center.x, dy = b.center.y - a.center.y
        let d = (dx * dx + dy * dy).squareRoot()
        var candidates: [PDFPoint] = []
        if d <= tolerance, Swift.abs(a.radius - b.radius) <= tolerance {
            candidates = [p.start, p.end, q.start, q.end]
        } else {
            guard d > 0, d <= a.radius + b.radius + tolerance, d >= Swift.abs(a.radius - b.radius) - tolerance else { return [] }
            let along = (d * d + a.radius * a.radius - b.radius * b.radius) / (2 * d)
            let height = Swift.max(0, a.radius * a.radius - along * along).squareRoot()
            let mx = a.center.x + along * dx / d, my = a.center.y + along * dy / d
            if height <= tolerance {
                candidates = [PDFPoint(x: mx, y: my)]
            } else {
                candidates = [
                    PDFPoint(x: mx - height * dy / d, y: my + height * dx / d),
                    PDFPoint(x: mx + height * dy / d, y: my - height * dx / d)
                ]
            }
        }
        var result: [Crossing] = []
        for var point in candidates {
            for end in [p.start, p.end, q.start, q.end] where end.distance(to: point) <= tolerance {
                point = end
                break
            }
            guard let t = p.fraction(of: point, tolerance: tolerance),
                  let u = q.fraction(of: point, tolerance: tolerance) else { continue }
            result.append(Crossing(point: point, fractionOnFirst: t, fractionOnSecond: u))
        }
        return result
    }
}

// MARK: - Rings

/// A closed ring of ``ArcEdge``s and the questions the exact edits ask of it.
public struct ArcRing: Hashable, Sendable {

    public var edges: [ArcEdge]

    public init(edges: [ArcEdge]) {
        self.edges = edges
    }

    /// The ring of a stored ``PolygonRing``: its edges with their bulges, consecutive duplicate
    /// points dropped. `nil` for a ring with fewer than two edges.
    public init?(_ ring: PolygonRing) {
        guard ring.isClosed else { return nil }
        let edges = ring.bulgedEdges.map { ArcEdge(start: $0.start, end: $0.end, bulge: $0.bulge) }
        guard edges.count >= 2 else { return nil }
        self.edges = edges
    }

    /// The exact signed area, origin-shifted to the first vertex (QUALITY_BAR §2.2 rule 1):
    /// positive counter-clockwise.
    public var signedArea: Double {
        guard let origin = edges.first?.start else { return 0 }
        var terms: [Double] = []
        terms.reserveCapacity(edges.count)
        for edge in edges { terms.append(edge.signedAreaContribution(origin: origin)) }
        return EngineNumerics.sum(terms)
    }

    /// The ring walked the other way.
    public var reversed: ArcRing { ArcRing(edges: edges.reversed().map(\.reversed)) }

    /// The ring counter-clockwise.
    public var counterClockwise: ArcRing { signedArea < 0 ? reversed : self }

    /// The stored form: one point per edge start, one bulge per point, `nil` bulges when every
    /// edge is straight.
    public var polygonRing: PolygonRing {
        let bulges = edges.map(\.bulge)
        return PolygonRing(
            points: edges.map(\.start),
            isClosed: true,
            bulges: bulges.contains { $0 != 0 } ? bulges : nil
        )
    }

    /// The perimeter in page points, every arc by `r·θ`.
    public var length: Double { EngineNumerics.sum(edges.map(\.length)) }

    /// The bounding box, arcs' extreme points included.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var box = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        for edge in edges {
            let b = edge.bounds
            box = (Swift.min(box.minX, b.minX), Swift.min(box.minY, b.minY), Swift.max(box.maxX, b.maxX), Swift.max(box.maxY, b.maxY))
        }
        return box
    }

    /// A tolerance for "the same point" scaled to the ring: `1e-9` of its diagonal, at least `1e-9`.
    public var tolerance: Double {
        let box = bounds
        let diagonal = ((box.maxX - box.minX) * (box.maxX - box.minX) + (box.maxY - box.minY) * (box.maxY - box.minY)).squareRoot()
        return Swift.max(1e-9, 1e-9 * diagonal)
    }

    /// The distance from `point` to the nearest edge.
    public func boundaryDistance(to point: PDFPoint) -> Double {
        edges.reduce(Double.infinity) { Swift.min($0, $1.nearest(to: point).distance) }
    }

    /// The direction of the ray ``winding(of:)`` casts: a fixed angle that is no multiple of a
    /// right angle or of 45°, so a ray from a point of a drawing practically never runs exactly
    /// through a vertex or along an edge, which is what makes a crossing count ambiguous.
    static let rayDirection = (dx: Foundation.cos(0.219_911_485_751_285_5), dy: Foundation.sin(0.219_911_485_751_285_5))

    /// The winding number of the ring about `point`, by casting a ray and counting the boundary's
    /// signed crossings — arcs crossed on their circles, not as chords, so a point on an arc's chord
    /// (the centre of a semicircle, say) is answered by the curve that is actually there. `+1` for a
    /// crossing where the boundary turns counter-clockwise about the point. For a point on the
    /// boundary the answer is not meaningful; ask ``boundaryDistance(to:)`` first.
    public func winding(of point: PDFPoint) -> Int {
        let u = Self.rayDirection
        var winding = 0
        for edge in edges {
            if let arc = edge.arc {
                // |p + s·u − c|² = r², s > 0.
                let fx = point.x - arc.center.x, fy = point.y - arc.center.y
                let b = u.dx * fx + u.dy * fy
                let c = fx * fx + fy * fy - arc.radius * arc.radius
                let discriminant = b * b - c
                guard discriminant > 0 else { continue }
                let root = discriminant.squareRoot()
                for s in [-b - root, -b + root] where s > 0 {
                    let angle = Foundation.atan2(fy + s * u.dy, fx + s * u.dx)
                    guard let fraction = BulgeArc.fraction(of: angle, on: arc), fraction < 1 else { continue }
                    let tangent = edge.tangent(at: fraction)
                    let turn = u.dx * tangent.dy - u.dy * tangent.dx
                    if turn > 0 { winding += 1 } else if turn < 0 { winding -= 1 }
                }
            } else {
                let dx = edge.end.x - edge.start.x, dy = edge.end.y - edge.start.y
                let denominator = u.dx * dy - u.dy * dx
                guard denominator != 0 else { continue }
                let qx = edge.start.x - point.x, qy = edge.start.y - point.y
                let s = (qx * dy - qy * dx) / denominator       // along the ray
                let t = (qx * u.dy - qy * u.dx) / denominator   // along the edge
                guard s > 0, t >= 0, t < 1 else { continue }
                winding += denominator > 0 ? 1 : -1
            }
        }
        return winding
    }

    /// Whether `point` is strictly inside (non-zero winding and not on the boundary).
    public func contains(_ point: PDFPoint, tolerance: Double) -> Bool {
        boundaryDistance(to: point) > tolerance && winding(of: point) != 0
    }

    /// Whether any two non-adjacent edges meet, or two adjacent edges meet anywhere but at their
    /// shared vertex: a ring that crosses itself has no area to split or merge exactly.
    public func isSelfIntersecting(tolerance: Double) -> Bool {
        let count = edges.count
        guard count >= 3 else { return false }
        // A sweep along x: only edges whose grown boxes overlap in x are compared, so a ring of
        // thousands of edges costs its sort, not the square of its size.
        let boxes = edges.map(\.bounds)
        let order = (0..<count).sorted { boxes[$0].minX < boxes[$1].minX }
        for (position, i) in order.enumerated() {
            for j in order[(position + 1)...] {
                if boxes[j].minX - tolerance > boxes[i].maxX { break }
                guard boxes[i].minY - tolerance <= boxes[j].maxY, boxes[j].minY - tolerance <= boxes[i].maxY else { continue }
                let (low, high) = i < j ? (i, j) : (j, i)
                let adjacent = high == low + 1 || (low == 0 && high == count - 1)
                let hits = edges[low].crossings(with: edges[high], tolerance: tolerance)
                if !adjacent, !hits.isEmpty { return true }
                if adjacent {
                    let shared = high == low + 1 ? edges[low].end : edges[low].start
                    if hits.contains(where: { $0.point.distance(to: shared) > tolerance }) { return true }
                }
            }
        }
        return false
    }
}
