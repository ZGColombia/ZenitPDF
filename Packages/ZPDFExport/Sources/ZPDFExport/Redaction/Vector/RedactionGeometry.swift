import CoreGraphics
import Foundation

/// One piece of a path: a straight line or a cubic Bézier, in whatever space its points are in.
enum RedactionSegment: Equatable {
    case line(CGPoint, CGPoint)
    case cubic(CGPoint, CGPoint, CGPoint, CGPoint)

    var start: CGPoint {
        switch self {
        case let .line(a, _), let .cubic(a, _, _, _): a
        }
    }

    var end: CGPoint {
        switch self {
        case let .line(_, b), let .cubic(_, _, _, b): b
        }
    }

    var controlPoints: [CGPoint] {
        switch self {
        case let .line(a, b): [a, b]
        case let .cubic(a, b, c, d): [a, b, c, d]
        }
    }

    func applying(_ transform: CGAffineTransform) -> RedactionSegment {
        switch self {
        case let .line(a, b): .line(a.applying(transform), b.applying(transform))
        case let .cubic(a, b, c, d): .cubic(a.applying(transform), b.applying(transform), c.applying(transform), d.applying(transform))
        }
    }

    func point(at t: Double) -> CGPoint {
        switch self {
        case let .line(a, b):
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        case let .cubic(p0, p1, p2, p3):
            let u = 1 - t
            let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
            let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
            return CGPoint(x: x, y: y)
        }
    }

    /// The part of the segment between parameters `t0` and `t1` — exact, by de Casteljau.
    func portion(from t0: Double, to t1: Double) -> RedactionSegment {
        switch self {
        case .line:
            return .line(point(at: t0), point(at: t1))
        case let .cubic(p0, p1, p2, p3):
            // Split at t1, keep the left; split that at t0 / t1, keep the right.
            func split(_ q0: CGPoint, _ q1: CGPoint, _ q2: CGPoint, _ q3: CGPoint, _ t: Double)
                -> (left: [CGPoint], right: [CGPoint]) {
                func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
                let a = lerp(q0, q1), b = lerp(q1, q2), c = lerp(q2, q3)
                let d = lerp(a, b), e = lerp(b, c)
                let f = lerp(d, e)
                return ([q0, a, d, f], [f, e, c, q3])
            }
            var left = [p0, p1, p2, p3]
            if t1 < 1 { left = split(p0, p1, p2, p3, t1).left }
            guard t0 > 0, t1 > 0 else {
                return .cubic(left[0], left[1], left[2], left[3])
            }
            let right = split(left[0], left[1], left[2], left[3], t0 / t1).right
            return .cubic(right[0], right[1], right[2], right[3])
        }
    }

    /// The bounding box of the control points (which contains the curve).
    var hull: CGRect {
        let points = controlPoints
        var minX = points[0].x, maxX = points[0].x, minY = points[0].y, maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Parameters in (0, 1) where the segment meets the line `axis == value`.
    func crossings(x value: Double) -> [Double] { crossings(value, \.x) }
    func crossings(y value: Double) -> [Double] { crossings(value, \.y) }

    private func crossings(_ value: Double, _ axis: KeyPath<CGPoint, CGFloat>) -> [Double] {
        switch self {
        case let .line(a, b):
            let da = a[keyPath: axis] - value, db = b[keyPath: axis] - value
            guard (da < 0 && db > 0) || (da > 0 && db < 0) else { return [] }
            let t = da / (da - db)
            return t > 1e-12 && t < 1 - 1e-12 ? [t] : []
        case let .cubic(p0, p1, p2, p3):
            let v0 = p0[keyPath: axis] - value, v1 = p1[keyPath: axis] - value
            let v2 = p2[keyPath: axis] - value, v3 = p3[keyPath: axis] - value
            if (v0 > 0 && v1 > 0 && v2 > 0 && v3 > 0) || (v0 < 0 && v1 < 0 && v2 < 0 && v3 < 0) { return [] }
            return RedactionGeometry.cubicRoots(v0, v1, v2, v3)
        }
    }

    /// Length, exactly for a line and by Gauss–Legendre quadrature for a curve.
    var length: Double {
        switch self {
        case let .line(a, b):
            return hypot(b.x - a.x, b.y - a.y)
        case let .cubic(p0, p1, p2, p3):
            let nodes: [(Double, Double)] = [
                (-0.9602898564975363, 0.1012285362903763), (-0.7966664774136267, 0.2223810344533745),
                (-0.5255324099163290, 0.3137066458778873), (-0.1834346424956498, 0.3626837833783620),
                (0.1834346424956498, 0.3626837833783620), (0.5255324099163290, 0.3137066458778873),
                (0.7966664774136267, 0.2223810344533745), (0.9602898564975363, 0.1012285362903763)
            ]
            var total = 0.0
            let pieces = 4
            for piece in 0..<pieces {
                let lo = Double(piece) / Double(pieces), hi = Double(piece + 1) / Double(pieces)
                for (node, weight) in nodes {
                    let t = (hi - lo) / 2 * node + (hi + lo) / 2
                    let u = 1 - t
                    let dx = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
                    let dy = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
                    total += weight * (hi - lo) / 2 * hypot(dx, dy)
                }
            }
            return total
        }
    }
}

/// A subpath: its segments in order, and whether `h` closed it.
struct RedactionSubpath: Equatable {
    var start: CGPoint
    var segments: [RedactionSegment]
    var closed: Bool

    /// The segments with the closing line made explicit.
    var closedSegments: [RedactionSegment] {
        guard closed, let last = segments.last else { return segments }
        if RedactionGeometry.same(last.end, start) { return segments }
        return segments + [.line(last.end, start)]
    }

    var hull: CGRect {
        segments.reduce(CGRect(origin: start, size: .zero)) { $0.union($1.hull) }
    }

    func applying(_ transform: CGAffineTransform) -> RedactionSubpath {
        RedactionSubpath(start: start.applying(transform), segments: segments.map { $0.applying(transform) }, closed: closed)
    }
}

/// A stroke piece that survived clipping, with how far along its original subpath it starts
/// (for the dash phase).
struct RedactionStrokePiece: Equatable {
    var subpath: RedactionSubpath
    var offset: Double
    var startsOriginal: Bool
}

/// The exact geometry of cutting boxes out of paths (NL-PDF-14 phase 2, ADR-0033 §3).
///
/// Every operation splits Béziers at their exact parameters with de Casteljau, so what is kept
/// outside a box is the original curve, not an approximation of it.
enum RedactionGeometry {

    static let epsilon = 1e-7

    /// The largest singular value of `transform`'s linear part: the most it stretches any
    /// direction, so a line width `w` placed by it paints at most `w × stretch` wide.
    static func largestStretch(_ transform: CGAffineTransform) -> Double {
        let a = Double(transform.a), b = Double(transform.b), c = Double(transform.c), d = Double(transform.d)
        let sum = a * a + b * b + c * c + d * d
        let determinant = a * d - b * c
        return ((sum + (max(0, sum * sum - 4 * determinant * determinant)).squareRoot()) / 2).squareRoot()
    }

    /// How far, in half line widths, a stroke of `subpaths` (user space) reaches from its
    /// centreline (ISO 32000-1 §8.4.3.3–5).
    ///
    /// A round or bevel join and a butt or round cap stay within half the width. A mitred join
    /// whose segments meet at angle θ reaches `1 / sin(θ/2)` half widths from the vertex while
    /// that ratio is at most the miter limit — about 5.8 for a 20° corner, against 1 for the hull
    /// the stroke test grew before (S-067) — and is bevelled beyond it. A projecting square cap
    /// reaches √2 half widths at its corners.
    static func strokeReach(_ subpaths: [RedactionSubpath], lineCap: Int, lineJoin: Int, miterLimit: Double) -> Double {
        var reach = lineCap == 2 ? 2.0.squareRoot() : 1.0
        guard lineJoin == 0, miterLimit > 1 else { return reach }
        for subpath in subpaths {
            let segments = subpath.closedSegments
            let tangents = segments.compactMap { segment -> (start: CGVector, end: CGVector)? in
                guard let start = startTangent(segment), let end = endTangent(segment) else { return nil }
                return (start, end)
            }
            guard tangents.count > 1 || (subpath.closed && tangents.count == 1) else { continue }
            let joins = subpath.closed ? tangents.count : tangents.count - 1
            for index in 0..<joins {
                let incoming = tangents[index].end, outgoing = tangents[(index + 1) % tangents.count].start
                let cosine = (incoming.dx * outgoing.dx + incoming.dy * outgoing.dy)
                    / (hypot(incoming.dx, incoming.dy) * hypot(outgoing.dx, outgoing.dy))
                // 1 / sin(θ/2) with θ the angle between the segments = √(2 / (1 + cos φ)) with φ the turn.
                guard cosine > -1 else { continue }
                let ratio = (2 / (1 + min(1, cosine))).squareRoot()
                if ratio <= miterLimit { reach = max(reach, ratio) }
            }
        }
        return reach
    }

    private static func startTangent(_ segment: RedactionSegment) -> CGVector? {
        let points = segment.controlPoints
        for point in points.dropFirst() where !same(point, points[0]) {
            return CGVector(dx: point.x - points[0].x, dy: point.y - points[0].y)
        }
        return nil
    }

    private static func endTangent(_ segment: RedactionSegment) -> CGVector? {
        let points = segment.controlPoints, last = points[points.count - 1]
        for point in points.dropLast().reversed() where !same(point, last) {
            return CGVector(dx: last.x - point.x, dy: last.y - point.y)
        }
        return nil
    }

    /// Which tiles of a tiling pattern meet an area (ISO 32000-1 §8.7.3.3).
    enum TileCover: Equatable { case none, one(Int, Int), many }

    /// The tiles of a pattern with cell `cell` and steps `xStep`/`yStep` that meet the area whose
    /// corners, in pattern space, are `corners`. The rewriter and the read-back share it.
    ///
    /// A step just above the 1e-9 guard against a wide area, or a near-singular pattern matrix,
    /// puts the tile index far past `Int`; that is reported as many tiles (both callers then
    /// refuse), never converted with an `Int(Double)` trap (S-065).
    static func tileCover(corners: [CGPoint], cell: CGRect, xStep: Double, yStep: Double) -> TileCover {
        let xs = corners.map { Double($0.x) }, ys = corners.map { Double($0.y) }
        let sx = abs(xStep), sy = abs(yStep), e = 1e-6
        let bounds = [((xs.min() ?? 0) + e - cell.maxX) / sx, ((xs.max() ?? 0) - e - cell.minX) / sx,
                      ((ys.min() ?? 0) + e - cell.maxY) / sy, ((ys.max() ?? 0) - e - cell.minY) / sy]
        let limit = Double(1 << 40)
        guard !xs.isEmpty, bounds.allSatisfy({ $0.isFinite && abs($0) < limit }) else { return .many }
        let firstI = Int(bounds[0].rounded(.down)) + 1, lastI = Int(bounds[1].rounded(.up)) - 1
        let firstJ = Int(bounds[2].rounded(.down)) + 1, lastJ = Int(bounds[3].rounded(.up)) - 1
        guard lastI >= firstI, lastJ >= firstJ else { return .none }
        return firstI == lastI && firstJ == lastJ ? .one(firstI, firstJ) : .many
    }

    static func same(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) <= 1e-9 * max(1, abs(a.x)) && abs(a.y - b.y) <= 1e-9 * max(1, abs(a.y))
    }

    /// Roots in (0, 1) of the cubic Bézier polynomial with control values `v0…v3`: the curve is
    /// cut into monotone pieces at the roots of its derivative, and each sign change is bisected.
    static func cubicRoots(_ v0: Double, _ v1: Double, _ v2: Double, _ v3: Double) -> [Double] {
        let a = -v0 + 3 * v1 - 3 * v2 + v3
        let b = 3 * v0 - 6 * v1 + 3 * v2
        let c = -3 * v0 + 3 * v1
        let d = v0
        func f(_ t: Double) -> Double { ((a * t + b) * t + c) * t + d }
        // Derivative 3a t² + 2b t + c.
        var stops: [Double] = [0, 1]
        let qa = 3 * a, qb = 2 * b, qc = c
        let scale = max(abs(qa), abs(qb), abs(qc), 1e-300)
        if abs(qa) / scale < 1e-12 {
            if abs(qb) / scale > 1e-12 { stops.append(-qc / qb) }
        } else {
            let discriminant = qb * qb - 4 * qa * qc
            if discriminant >= 0 {
                let root = discriminant.squareRoot()
                stops.append((-qb + root) / (2 * qa))
                stops.append((-qb - root) / (2 * qa))
            }
        }
        stops = stops.filter { $0 >= 0 && $0 <= 1 }.sorted()
        var roots: [Double] = []
        let magnitude = max(abs(v0), abs(v1), abs(v2), abs(v3), 1)
        for index in 0..<(stops.count - 1) {
            var lo = stops[index], hi = stops[index + 1]
            guard hi - lo > 1e-15 else { continue }
            var flo = f(lo), fhi = f(hi)
            if abs(fhi) <= 1e-12 * magnitude {
                if hi > 1e-9, hi < 1 - 1e-9 { roots.append(hi) }
                continue
            }
            guard (flo < 0 && fhi > 0) || (flo > 0 && fhi < 0) else { continue }
            for _ in 0..<80 {
                let mid = (lo + hi) / 2
                let fmid = f(mid)
                if (fmid < 0) == (flo < 0) { lo = mid; flo = fmid } else { hi = mid; fhi = fmid }
                if hi - lo < 1e-15 { break }
            }
            let root = (lo + hi) / 2
            if root > 1e-9, root < 1 - 1e-9 { roots.append(root) }
        }
        var unique: [Double] = []
        for root in roots.sorted() where unique.last.map({ root - $0 > 1e-12 }) ?? true { unique.append(root) }
        return unique
    }

    /// The segment split at every parameter where it meets one of the box's four edge lines.
    static func split(_ segment: RedactionSegment, at box: CGRect) -> [RedactionSegment] {
        var ts = segment.crossings(x: box.minX) + segment.crossings(x: box.maxX)
            + segment.crossings(y: box.minY) + segment.crossings(y: box.maxY)
        guard !ts.isEmpty else { return [segment] }
        ts.sort()
        var out: [RedactionSegment] = []
        var previous = 0.0
        for t in ts + [1] where t - previous > 1e-12 {
            out.append(segment.portion(from: previous, to: t))
            previous = t
        }
        return out
    }

    /// Whether a piece that does not cross the box's edge lines lies inside it: its middle, and
    /// for a curve every control-point-bounded sample, strictly inside.
    static func isInside(_ piece: RedactionSegment, _ box: CGRect) -> Bool {
        let inner = box.insetBy(dx: epsilon, dy: epsilon)
        let mid = piece.point(at: 0.5)
        return inner.contains(mid) && mid.x > inner.minX && mid.y > inner.minY
    }

    static func intersects(_ rect: CGRect, _ box: CGRect) -> Bool {
        rect.maxX > box.minX + epsilon && rect.minX < box.maxX - epsilon
            && rect.maxY > box.minY + epsilon && rect.minY < box.maxY - epsilon
    }

    // MARK: - Strokes

    /// What remains of stroked subpaths once every box is cut out: open pieces outside all of
    /// them, each with its distance along its original subpath measured by `measure`.
    static func clipStroke(
        _ subpaths: [RedactionSubpath],
        boxes: [CGRect],
        measure: (RedactionSegment) -> Double
    ) -> [RedactionStrokePiece] {
        var out: [RedactionStrokePiece] = []
        for subpath in subpaths {
            let segments = subpath.closedSegments
            guard !segments.isEmpty else { continue }
            // Pieces with their "inside some box" flag and their start distance.
            var pieces: [(segment: RedactionSegment, inside: Bool, offset: Double)] = []
            var distance = 0.0
            for segment in segments {
                var parts = [segment]
                for box in boxes { parts = parts.flatMap { split($0, at: box) } }
                for part in parts {
                    let inside = boxes.contains { isInside(part, $0) }
                    pieces.append((part, inside, distance))
                    distance += measure(part)
                }
            }
            if !pieces.contains(where: \.inside) {
                out.append(RedactionStrokePiece(subpath: subpath, offset: 0, startsOriginal: true))
                continue
            }
            var runs: [[(segment: RedactionSegment, inside: Bool, offset: Double)]] = []
            var current: [(segment: RedactionSegment, inside: Bool, offset: Double)] = []
            for piece in pieces {
                if piece.inside {
                    if !current.isEmpty { runs.append(current); current = [] }
                } else {
                    current.append(piece)
                }
            }
            if !current.isEmpty { runs.append(current) }
            // A closed subpath whose first and last pieces both survive is one run through its
            // start point: join them so no cap appears where the original had a join.
            var joinedFirst = false
            if subpath.closed, runs.count >= 2, !(pieces.first?.inside ?? true), !(pieces.last?.inside ?? true) {
                let last = runs.removeLast()
                runs[0] = last + runs[0]
                joinedFirst = true
            }
            for (index, run) in runs.enumerated() {
                guard let first = run.first else { continue }
                let startsOriginal = (index == 0 && !joinedFirst && first.offset == 0)
                out.append(RedactionStrokePiece(
                    subpath: RedactionSubpath(start: first.segment.start, segments: run.map(\.segment), closed: false),
                    offset: first.offset,
                    startsOriginal: startsOriginal
                ))
            }
        }
        return out
    }

    // MARK: - Fills and clips

    private enum Side { case atMost, atLeast }
    private struct HalfPlane {
        var vertical: Bool   // true: the line x = value; false: y = value
        var value: Double
        var side: Side
    }

    /// The region the closed subpaths enclose, less every box, for either fill rule: each box's
    /// outside is cut into four strips, and each contour is clipped to each strip with
    /// Sutherland–Hodgman generalised to Bézier segments. Clipping a contour to a half-plane
    /// preserves every winding number inside that half-plane (the excursion outside is replaced
    /// by a chord along the edge), and the strips are disjoint, so the union has the original
    /// winding number everywhere outside the boxes and zero inside them.
    static func difference(_ contours: [RedactionSubpath], boxes: [CGRect]) -> [RedactionSubpath] {
        var current = contours.map { RedactionSubpath(start: $0.start, segments: $0.closedSegments, closed: true) }
        for box in boxes {
            var next: [RedactionSubpath] = []
            let strips: [[HalfPlane]] = [
                [HalfPlane(vertical: true, value: box.minX, side: .atMost)],
                [HalfPlane(vertical: true, value: box.maxX, side: .atLeast)],
                [HalfPlane(vertical: true, value: box.minX, side: .atLeast), HalfPlane(vertical: true, value: box.maxX, side: .atMost),
                 HalfPlane(vertical: false, value: box.minY, side: .atMost)],
                [HalfPlane(vertical: true, value: box.minX, side: .atLeast), HalfPlane(vertical: true, value: box.maxX, side: .atMost),
                 HalfPlane(vertical: false, value: box.maxY, side: .atLeast)]
            ]
            for contour in current {
                guard !contour.segments.isEmpty else { continue }
                guard intersects(contour.hull, box) else {
                    next.append(contour)
                    continue
                }
                for strip in strips {
                    var piece: [RedactionSegment]? = contour.segments
                    for plane in strip {
                        guard let segments = piece else { break }
                        piece = clip(segments, to: plane)
                    }
                    if let segments = piece, let first = segments.first {
                        next.append(RedactionSubpath(start: first.start, segments: segments, closed: true))
                    }
                }
            }
            current = next
        }
        return current
    }

    private static func coordinate(_ point: CGPoint, _ plane: HalfPlane) -> Double {
        plane.vertical ? point.x : point.y
    }

    private static func keeps(_ point: CGPoint, _ plane: HalfPlane) -> Bool {
        let value = coordinate(point, plane)
        let tolerance = epsilon * max(1, abs(plane.value))
        return plane.side == .atMost ? value <= plane.value + tolerance : value >= plane.value - tolerance
    }

    /// One closed loop of segments clipped to a half-plane, or `nil` when nothing is left.
    private static func clip(_ loop: [RedactionSegment], to plane: HalfPlane) -> [RedactionSegment]? {
        var pieces: [(RedactionSegment, Bool)] = []
        for segment in loop {
            let ts = (plane.vertical ? segment.crossings(x: plane.value) : segment.crossings(y: plane.value)).sorted()
            var previous = 0.0
            for t in ts + [1] where t - previous > 1e-12 {
                let part = segment.portion(from: previous, to: t)
                pieces.append((part, keeps(part.point(at: 0.5), plane)))
                previous = t
            }
        }
        if pieces.allSatisfy(\.1) { return loop }
        guard pieces.contains(where: \.1) else { return nil }
        var out: [RedactionSegment] = []
        for (part, kept) in pieces where kept {
            if let last = out.last?.end, !same(last, part.start) {
                out.append(.line(last, part.start))
            }
            out.append(part)
        }
        if let last = out.last?.end, let first = out.first?.start, !same(last, first) {
            out.append(.line(last, first))
        }
        return out.count >= 2 ? out : nil
    }

    // MARK: - Areas outside the boxes, for clipping paint that cannot be cut

    /// A large rectangle less every box, as contours for a nonzero clip: everything outside
    /// the boxes, and nothing inside them.
    static func outside(of boxes: [CGRect], within frame: CGRect) -> [RedactionSubpath] {
        let rect = RedactionSubpath(
            start: CGPoint(x: frame.minX, y: frame.minY),
            segments: [
                .line(CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY)),
                .line(CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY)),
                .line(CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)),
                .line(CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.minY))
            ],
            closed: true
        )
        return difference([rect], boxes: boxes)
    }
}
