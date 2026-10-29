import Foundation
import ZPDFContracts
import ZPDFGeometry

/// The net area of one simple outer ring minus the union of simple cutout rings, computed from
/// the drawn coordinates with no lattice anywhere (S-108, iteration-2 re-fix; QUALITY_BAR P11).
///
/// # Why the boolean's own area is not enough
///
/// Clipper2 is exact on its integer lattice, but the lattice is not the drawing: every drawn
/// vertex is rounded onto it by up to 5e-7 pt, and every point where two edges cross is rounded
/// again. Measured against the drawn rings (``CutoutSolver``'s drawn-ring formula) the first
/// rounding cancels; the second does not. A tiny cutout straddling a long diagonal edge of another
/// cutout moves that edge's rounded crossing points off the edge, and the thin triangles this adds
/// or removes — up to about `½ · edge length · 7e-7 pt` — can outweigh everything the tiny cutout
/// removes. Replayed over rotated 10 pt and 500 pt cutouts with 1e-3 and 1e-4 pt cutouts
/// straddling their edges, 89 of 132 additions raised the stored net area, by up to 8.2e-6 pt².
/// Adding a cutout must never raise it (P11).
///
/// # How
///
/// Green's theorem: an area is `½ ∮ (x dy − y dx)` around its boundary. The boundary of
/// `outer − ∪ holes` is made of pieces of the drawn edges, so every edge is split wherever another
/// ring's edge crosses it or touches it, and each piece is kept or dropped by where its midpoint
/// lies:
///
/// - a piece of the outer ring is kept when it lies outside every cutout;
/// - a piece of a cutout is kept, reversed, when it lies inside the outer ring and outside every
///   other cutout;
/// - a piece two rings share is kept once when both rings lie on the same side of it (an outer
///   edge a cutout runs along from outside, two cutouts overlapping along a common edge), and
///   dropped when it separates what it bounds from what the other ring bounds (a cutout along the
///   outer edge from inside, two cutouts side by side).
///
/// Every crossing point is computed once and shared by both edges, and a touching vertex is used
/// as it was drawn, so the kept pieces close up exactly. The sum is taken relative to the outer
/// ring's bounding-box corner (translation-safe, QUALITY_BAR §2.2 rule 1) and compensated.
///
/// The result is `nil` — and the caller keeps the drawn-ring lattice formula — when the work
/// would exceed ``workBudget`` or a piece's position is genuinely ambiguous (its midpoint on
/// another ring's edge without running along it). The caller also compares the answer with the
/// lattice formula and keeps the lattice one if the two disagree by more than the lattice's own
/// rounding could explain: this routine sharpens a number, it can never replace one wholesale.
enum ExactNetArea {

    /// The most edge-pair and point-edge tests one call performs before answering `nil`.
    static let workBudget = 20_000_000

    /// Where a piece's midpoint lies relative to one other ring.
    enum Location: Equatable {
        case inside
        case outside
        /// On the ring's boundary, running the same way as the ring's edge there.
        case boundarySame
        /// On the ring's boundary, running against the ring's edge there.
        case boundaryOpposite
    }

    private struct Split {
        var t: Double
        var point: PDFPoint
    }

    private struct Box {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        init(_ points: [PDFPoint]) {
            for point in points { include(point) }
        }

        init(_ a: PDFPoint, _ b: PDFPoint) {
            include(a)
            include(b)
        }

        mutating func include(_ point: PDFPoint) {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }

        func grown(by amount: Double) -> Box {
            var box = self
            box.minX -= amount
            box.minY -= amount
            box.maxX += amount
            box.maxY += amount
            return box
        }

        func overlaps(_ other: Box) -> Bool {
            !(maxX < other.minX || other.maxX < minX || maxY < other.minY || other.maxY < minY)
        }

        func contains(_ point: PDFPoint) -> Bool {
            point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
        }

        var magnitude: Double {
            Swift.max(Swift.abs(minX), Swift.abs(maxX), Swift.abs(minY), Swift.abs(maxY))
        }
    }

    /// The net area in square page points, or `nil` when it cannot be decided robustly.
    ///
    /// - Parameters:
    ///   - outer: one simple ring, either winding.
    ///   - holes: simple rings, either winding, in the caller's canonical order (the order decides
    ///     only which of two identical shared pieces is the one kept, never the value).
    ///   - strictlyInside: per hole, whether it is already known to lie strictly inside the outer
    ///     ring (``CutoutContainment/isStrictlyInside(_:outer:epsilon:)``); its pieces then skip
    ///     the winding test against a possibly very long outer ring. Empty means none is known.
    static func netArea(outer: [PDFPoint], holes: [[PDFPoint]], strictlyInside: [Bool] = []) -> Double? {
        guard outer.count >= 3, holes.allSatisfy({ $0.count >= 3 }),
              strictlyInside.isEmpty || strictlyInside.count == holes.count else { return nil }
        let knownInside = [false] + (strictlyInside.isEmpty ? Array(repeating: false, count: holes.count) : strictlyInside)
        let rings = ([outer] + holes).map { ring in
            PolygonMath.signedArea(ring) >= 0 ? ring : Array(ring.reversed())
        }
        let boxes = rings.map(Box.init)
        // A few ulps of the largest coordinate: points closer than this are the same point, a
        // point closer than this to an edge lies on it. It separates exact coincidences (shared
        // vertices, snapped edges, a cutout drawn along the outer edge) from real geometry, and
        // is far below the lattice step the caller's cross-check allows for.
        let magnitude = boxes.reduce(1.0) { Swift.max($0, $1.magnitude) }
        let tolerance = 64 * magnitude.ulp
        let anchor = PDFPoint(x: boxes[0].minX, y: boxes[0].minY)
        var work = 0

        // 1. Split every edge where another ring's edge crosses or touches it. Each pair of rings
        //    is visited once and each crossing point is computed once, for both edges.
        var splits: [[[Split]]] = rings.map { Array(repeating: [], count: $0.count) }
        for first in 0..<rings.count {
            for second in (first + 1)..<rings.count {
                guard boxes[first].grown(by: tolerance).overlaps(boxes[second]) else { continue }
                let a = rings[first]
                let b = rings[second]
                let edgesA = edgeIndices(of: a, reaching: boxes[second].grown(by: tolerance))
                let edgesB = edgeIndices(of: b, reaching: boxes[first].grown(by: tolerance))
                work += edgesA.count * edgesB.count
                guard work <= workBudget else { return nil }
                for edgeA in edgesA {
                    let p0 = a[edgeA]
                    let p1 = a[edgeA + 1 == a.count ? 0 : edgeA + 1]
                    let reach = Box(p0, p1).grown(by: tolerance)
                    for edgeB in edgesB {
                        let q0 = b[edgeB]
                        let q1 = b[edgeB + 1 == b.count ? 0 : edgeB + 1]
                        guard reach.overlaps(Box(q0, q1)) else { continue }
                        for hit in intersections(p0, p1, q0, q1, tolerance: tolerance) {
                            if let t = hit.onA { splits[first][edgeA].append(Split(t: t, point: hit.point)) }
                            if let t = hit.onB { splits[second][edgeB].append(Split(t: t, point: hit.point)) }
                        }
                    }
                }
            }
        }

        // 2. Keep the pieces that bound the net region and integrate along them.
        var terms: [Double] = []
        for index in rings.indices {
            let ring = rings[index]
            for edge in ring.indices {
                var points = [ring[edge]]
                for split in splits[index][edge].sorted(by: { $0.t < $1.t }) {
                    if distance(points[points.count - 1], split.point) > tolerance {
                        points.append(split.point)
                    }
                }
                let end = ring[edge + 1 == ring.count ? 0 : edge + 1]
                if points.count > 1, distance(points[points.count - 1], end) <= tolerance {
                    points[points.count - 1] = end
                } else {
                    points.append(end)
                }
                for step in 0..<(points.count - 1) {
                    let start = points[step]
                    let stop = points[step + 1]
                    guard start != stop else { continue }
                    guard let keep = keeps(
                        from: start, to: stop, ringIndex: index, rings: rings, boxes: boxes,
                        knownInside: knownInside[index], tolerance: tolerance, work: &work
                    ) else { return nil }
                    guard keep else { continue }
                    let term = (start.x - anchor.x) * (stop.y - anchor.y) - (stop.x - anchor.x) * (start.y - anchor.y)
                    terms.append(index == 0 ? term : -term)
                }
            }
        }
        let twice = EngineNumerics.sum(terms)
        guard twice.isFinite else { return nil }
        return Swift.max(0, twice / 2)
    }

    // MARK: - Pieces

    /// Whether the piece `start → stop` of ring `ringIndex` bounds the net region; `nil` when that
    /// cannot be decided.
    private static func keeps(
        from start: PDFPoint,
        to stop: PDFPoint,
        ringIndex: Int,
        rings: [[PDFPoint]],
        boxes: [Box],
        knownInside: Bool,
        tolerance: Double,
        work: inout Int
    ) -> Bool? {
        let middle = PDFPoint(x: (start.x + stop.x) / 2, y: (start.y + stop.y) / 2)
        let direction = PDFPoint(x: stop.x - start.x, y: stop.y - start.y)
        // A piece this short contributes at most its length times the drawing's size; its
        // position is decided by the winding rule alone rather than refused as ambiguous.
        let isSliver = distance(start, stop) <= 1024 * tolerance
        func location(in other: Int) -> Location? {
            guard boxes[other].grown(by: tolerance).contains(middle) else { return .outside }
            work += rings[other].count
            return Self.location(
                of: middle, direction: direction, in: rings[other], tolerance: tolerance, isSliver: isSliver
            )
        }
        if ringIndex == 0 {
            for other in 1..<rings.count {
                guard let place = location(in: other) else { return nil }
                switch place {
                case .inside, .boundarySame: return false
                case .outside, .boundaryOpposite: continue
                }
            }
        } else {
            if !knownInside {
                guard let place = location(in: 0) else { return nil }
                guard place == .inside else { return false }
            }
            for other in 1..<rings.count where other != ringIndex {
                guard let place = location(in: other) else { return nil }
                switch place {
                case .inside, .boundaryOpposite: return false
                case .boundarySame: if other < ringIndex { return false }
                case .outside: continue
                }
            }
        }
        guard work <= workBudget else { return nil }
        return true
    }

    /// Where `point`, the midpoint of a piece running along `direction`, lies relative to `ring`.
    static func location(
        of point: PDFPoint,
        direction: PDFPoint,
        in ring: [PDFPoint],
        tolerance: Double,
        isSliver: Bool
    ) -> Location? {
        let length = (direction.x * direction.x + direction.y * direction.y).squareRoot()
        for index in ring.indices {
            let a = ring[index]
            let b = ring[index + 1 == ring.count ? 0 : index + 1]
            if Swift.min(a.x, b.x) - tolerance > point.x || Swift.max(a.x, b.x) + tolerance < point.x
                || Swift.min(a.y, b.y) - tolerance > point.y || Swift.max(a.y, b.y) + tolerance < point.y {
                continue
            }
            guard segmentDistance(point, a, b) <= tolerance else { continue }
            let edge = PDFPoint(x: b.x - a.x, y: b.y - a.y)
            let edgeLength = (edge.x * edge.x + edge.y * edge.y).squareRoot()
            let sine = Swift.abs(direction.x * edge.y - direction.y * edge.x) / (length * edgeLength)
            if sine <= 1e-9 {
                return direction.x * edge.x + direction.y * edge.y > 0 ? .boundarySame : .boundaryOpposite
            }
            // On the edge without running along it: only a sliver may be settled by winding.
            guard isSliver else { return nil }
            break
        }
        return PolygonMath.windingNumber(of: point, in: ring) != 0 ? .inside : .outside
    }

    // MARK: - Edge intersections

    /// One point where two edges meet, with its parameter on each edge when it lies strictly
    /// inside that edge (`nil` when it is that edge's end point, which needs no split).
    struct Hit {
        var point: PDFPoint
        var onA: Double?
        var onB: Double?
    }

    /// Every point where edge `p0 → p1` and edge `q0 → q1` cross or touch: a proper crossing, an
    /// end point of one lying on the other, or the end points of a collinear overlap. An end
    /// point is returned exactly as drawn, so the two rings' pieces meet in the same point.
    static func intersections(
        _ p0: PDFPoint,
        _ p1: PDFPoint,
        _ q0: PDFPoint,
        _ q1: PDFPoint,
        tolerance: Double
    ) -> [Hit] {
        let r = PDFPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        let s = PDFPoint(x: q1.x - q0.x, y: q1.y - q0.y)
        let rr = r.x * r.x + r.y * r.y
        let ss = s.x * s.x + s.y * s.y
        guard rr > 0, ss > 0 else { return [] }
        let lengthR = rr.squareRoot()
        let lengthS = ss.squareRoot()
        let toleranceA = tolerance / lengthR
        let toleranceB = tolerance / lengthS
        func interiorA(_ t: Double) -> Double? { t > toleranceA && t < 1 - toleranceA ? t : nil }
        func interiorB(_ t: Double) -> Double? { t > toleranceB && t < 1 - toleranceB ? t : nil }

        let q0Off = cross(r, PDFPoint(x: q0.x - p0.x, y: q0.y - p0.y)) / lengthR
        let q1Off = cross(r, PDFPoint(x: q1.x - p0.x, y: q1.y - p0.y)) / lengthR
        let p0Off = cross(s, PDFPoint(x: p0.x - q0.x, y: p0.y - q0.y)) / lengthS
        let p1Off = cross(s, PDFPoint(x: p1.x - q0.x, y: p1.y - q0.y)) / lengthS
        let collinear = (Swift.abs(q0Off) <= tolerance && Swift.abs(q1Off) <= tolerance)
            || (Swift.abs(p0Off) <= tolerance && Swift.abs(p1Off) <= tolerance)
        if collinear {
            // Split each edge at the other's end points that fall strictly inside it.
            var hits: [Hit] = []
            for point in [q0, q1] {
                let t = ((point.x - p0.x) * r.x + (point.y - p0.y) * r.y) / rr
                if let t = interiorA(t) { hits.append(Hit(point: point, onA: t, onB: nil)) }
            }
            for point in [p0, p1] {
                let t = ((point.x - q0.x) * s.x + (point.y - q0.y) * s.y) / ss
                if let t = interiorB(t) { hits.append(Hit(point: point, onA: nil, onB: t)) }
            }
            return hits
        }

        let denominator = cross(r, s)
        guard denominator != 0 else { return [] }
        let qp = PDFPoint(x: q0.x - p0.x, y: q0.y - p0.y)
        let tA = cross(qp, s) / denominator
        let tB = cross(qp, r) / denominator
        guard tA >= -toleranceA, tA <= 1 + toleranceA, tB >= -toleranceB, tB <= 1 + toleranceB else { return [] }
        // An end point of either edge that lies on the other is used exactly as drawn.
        let point: PDFPoint
        if tB <= toleranceB {
            point = q0
        } else if tB >= 1 - toleranceB {
            point = q1
        } else if tA <= toleranceA {
            point = p0
        } else if tA >= 1 - toleranceA {
            point = p1
        } else {
            point = PDFPoint(x: p0.x + tA * r.x, y: p0.y + tA * r.y)
        }
        let hit = Hit(point: point, onA: interiorA(tA), onB: interiorB(tB))
        return hit.onA == nil && hit.onB == nil ? [] : [hit]
    }

    // MARK: - Small helpers

    private static func edgeIndices(of ring: [PDFPoint], reaching box: Box) -> [Int] {
        ring.indices.filter { index in
            Box(ring[index], ring[index + 1 == ring.count ? 0 : index + 1]).overlaps(box)
        }
    }

    private static func cross(_ a: PDFPoint, _ b: PDFPoint) -> Double {
        a.x * b.y - a.y * b.x
    }

    private static func distance(_ a: PDFPoint, _ b: PDFPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private static func segmentDistance(_ point: PDFPoint, _ a: PDFPoint, _ b: PDFPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(point, a) }
        let t = Swift.min(1, Swift.max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return distance(point, PDFPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}
