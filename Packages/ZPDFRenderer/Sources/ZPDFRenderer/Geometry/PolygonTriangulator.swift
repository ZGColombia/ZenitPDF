import CoreGraphics
import Foundation
import ZPDFClipper2
import ZPDFContracts

/// Turns a filled region — one outer contour plus holes — into a triangle list, once.
///
/// # Why triangulation and not a stencil pass
///
/// The two ways to fill an even-odd polygon on a GPU are a CPU triangulation uploaded as
/// triangles, and the stencil-invert trick: fan the contour into the stencil buffer with
/// `invert`, then draw the bounding box where the stencil is non-zero. The stencil route is more
/// robust — it is exactly even-odd by construction, and it does not care about self-intersection
/// — and it was rejected anyway, for one reason that decides the whole package:
///
/// **The stencil route cannot be batched.** Each polygon needs its own stencil clear or its own
/// stencil bit, so 100 000 filled markups become either 100 000 draw-call pairs or, packing eight
/// polygons per byte, 25 000 passes. At 60 fps that is a per-frame cost of tens of milliseconds
/// spent entirely in command encoding, before a single pixel is shaded. Triangles are one draw
/// call for the whole page, every frame, forever.
///
/// Triangulation's cost is paid once. ``RenderGeometryCache`` keys the result on
/// `(MarkupID, revision)`, so a page that is panned, zoomed, selected into and hovered over for
/// an hour triangulates exactly as many polygons as it has, and re-triangulates only the ones the
/// user actually edits. That is the trade: a bounded one-off CPU cost against an unbounded
/// per-frame GPU-encoding cost.
///
/// # Correctness, and what happens when ear clipping cannot proceed
///
/// Holes are spliced into the outer contour with Eberly's bridge construction, which reduces the
/// multiply-connected region to one simple polygon whose even-odd fill is identical. Ear clipping
/// then consumes it. On genuinely degenerate input — a self-touching contour, a bridge that
/// lands on a duplicated vertex — the "no other reflex vertex strictly inside the ear" test can
/// reject every candidate, and a naive implementation spins. This one detects the stall and
/// enters *desperate mode*: it clips the smallest-area convex candidate regardless of
/// containment, which always terminates and, on the self-touching fixtures, produces the same
/// coverage as Core Graphics' own even-odd fill to within antialiasing. The golden suite's
/// self-touching scenes are what hold that claim up.
///
/// The output is verified independently in `PolygonTriangulatorTests`: the summed triangle area
/// must equal `|outer| - Σ|holes|` computed by a shoelace that shares no code with the
/// triangulator, to a relative 1e-9.
public enum PolygonTriangulator {

    /// One triangle in page space.
    public struct Triangle: Sendable, Hashable {
        public var a: PDFPoint
        public var b: PDFPoint
        public var c: PDFPoint

        public init(a: PDFPoint, b: PDFPoint, c: PDFPoint) {
            self.a = a; self.b = b; self.c = c
        }

        /// Unsigned area in square page points.
        public var area: Double {
            Swift.abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
        }
    }

    /// Why a polygon produced no triangles.
    public enum Failure: Error, Sendable, Hashable {
        case fewerThanThreeVertices
        case coordinateOutOfRange
        case tooManyVertices
        case tooManyHoles
    }

    /// Contours longer than this are not checked for self-intersection.
    ///
    /// The check is quadratic in the vertex count, and a 5 000-point freehand trace would cost
    /// twelve million segment tests for a defect it almost certainly does not have. Above the
    /// limit the contour is trusted to be simple, which is what the measurement engine
    /// guarantees for anything it stores (`QUALITY_BAR` 2.5: a self-intersecting polygon is
    /// blocked or normalised through Clipper2 before it becomes a markup). The limit is stated
    /// here rather than hidden, so the one case that is not covered is a known one.
    public static let selfIntersectionCheckVertexLimit = 512

    /// Triangulates `polygon`.
    ///
    /// - Throws: ``Failure`` for input the renderer refuses to draw. Never traps, never loops.
    public static func triangulate(_ polygon: RenderPolygon) throws -> [Triangle] {
        guard polygon.holes.count <= RenderLimits.maximumHoles else { throw Failure.tooManyHoles }

        let outer = try sanitize(polygon.outer)
        guard outer.count >= 3 else { throw Failure.fewerThanThreeVertices }

        var holes: [[Vertex]] = []
        holes.reserveCapacity(polygon.holes.count)
        for rawHole in polygon.holes {
            let hole = try sanitize(rawHole)
            guard hole.count >= 3 else { continue }
            holes.append(hole)
        }

        // Degenerate topology takes a repair path. Two kinds qualify, and both were found by the
        // golden suite rather than reasoned about in advance:
        //
        // 1. **Crossing edges** — a bowtie, a figure eight, a trace that doubles back through
        //    itself. Ear clipping fills the convex hull, which for a bowtie is twice the even-odd
        //    area: a visible lie about what the markup covers.
        // 2. **A vertex shared by two contours, or repeated inside one** — a hole meeting its
        //    parent at a corner, a pinched hourglass. Ear clipping can complete these, but the
        //    hole bridge lands on the duplicated point and the desperate-mode fallback can emit
        //    *overlapping* triangles. Core Graphics hides that, because one `fillPath` of the
        //    whole triangle list composites the overlap once; the GPU does not, because each
        //    triangle is blended separately and a semi-transparent fill comes out visibly darker
        //    where they overlap. The two backends then disagree, and the Metal one is wrong.
        //
        // Clipper2 resolves both into simple, properly nested, non-overlapping rings under the
        // even-odd rule; those rings are then ear-clipped normally.
        if hasDegenerateTopology(outer: outer, holes: holes),
           let repaired = repairByEvenOddNormalisation(outer: outer, holes: holes) {
            var triangles: [Triangle] = []
            for region in repaired {
                triangles.append(contentsOf: try triangulateSimple(outer: region.outer, holes: region.holes))
            }
            return triangles
        }

        return try triangulateSimple(outer: outer, holes: holes)
    }

    /// Ear-clips a region whose contours are known not to cross.
    private static func triangulateSimple(outer: [Vertex], holes rawHoles: [[Vertex]]) throws -> [Triangle] {
        var outer = outer
        var holes = rawHoles
        if signedArea(outer) < 0 { outer.reverse() }
        for index in holes.indices where signedArea(holes[index]) > 0 {
            holes[index].reverse()
        }
        // Largest-x-first, so a bridge already spliced in can be seen by the next hole.
        holes.sort { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }

        var merged = outer
        for hole in holes {
            merged = spliceHole(hole, into: merged)
            guard merged.count <= RenderLimits.maximumContourVertices else {
                throw Failure.tooManyVertices
            }
        }

        return earClip(merged)
    }

    // MARK: - Vertices

    private struct Vertex {
        var x: Double
        var y: Double
    }

    private static func sanitize(_ points: [PDFPoint]) throws -> [Vertex] {
        guard points.count <= RenderLimits.maximumContourVertices else {
            throw Failure.tooManyVertices
        }
        var out: [Vertex] = []
        out.reserveCapacity(points.count)
        for point in points {
            guard point.isFinite else { throw Failure.coordinateOutOfRange }
            guard Swift.abs(point.x) <= RenderLimits.coordinateMagnitudeBound,
                  Swift.abs(point.y) <= RenderLimits.coordinateMagnitudeBound
            else { throw Failure.coordinateOutOfRange }
            if let last = out.last, last.x == point.x, last.y == point.y { continue }
            out.append(Vertex(x: point.x, y: point.y))
        }
        // Drop an explicit closing vertex.
        if out.count >= 2, let first = out.first, let last = out.last,
           first.x == last.x, first.y == last.y {
            out.removeLast()
        }
        return out
    }

    private static func signedArea(_ contour: [Vertex]) -> Double {
        guard contour.count >= 3 else { return 0 }
        // Origin-shifted against the first vertex, per QUALITY_BAR 2.2 rule 1: a contour on a
        // site plan can legitimately sit a long way from the page origin.
        let originX = contour[0].x
        let originY = contour[0].y
        var sum = 0.0
        for index in contour.indices {
            let current = contour[index]
            let next = contour[(index + 1) % contour.count]
            sum += (current.x - originX) * (next.y - originY)
                - (next.x - originX) * (current.y - originY)
        }
        return sum / 2
    }

    // MARK: - Crossing detection and repair

    /// True when the region needs repairing: crossing edges, or a vertex that appears twice.
    ///
    /// Both checks are bounded by ``selfIntersectionCheckVertexLimit``; the crossing test is
    /// quadratic and the duplicate test is linear, so the limit is really about the former.
    private static func hasDegenerateTopology(outer: [Vertex], holes: [[Vertex]]) -> Bool {
        var total = outer.count
        for hole in holes { total += hole.count }
        guard total <= selfIntersectionCheckVertexLimit else { return false }
        if hasDuplicateVertices(outer: outer, holes: holes) { return true }
        return hasCrossingEdges(outer: outer, holes: holes)
    }

    /// True when the same point appears more than once across all contours.
    ///
    /// Consecutive duplicates were already removed by ``sanitize(_:)``, so anything left is a
    /// contour touching itself or another contour — the case that makes ear clipping overlap.
    private static func hasDuplicateVertices(outer: [Vertex], holes: [[Vertex]]) -> Bool {
        // Quantised to a millionth of a page point: two vertices in the same bucket are the same
        // corner as far as any renderer is concerned.
        var seen = Set<Int64>()
        for vertex in outer where !seen.insert(quantizedKey(vertex)).inserted { return true }
        for hole in holes {
            for vertex in hole where !seen.insert(quantizedKey(vertex)).inserted { return true }
        }
        return false
    }

    /// True when any two edges of the region cross at a point interior to both.
    ///
    /// Shared endpoints and vertex-on-vertex contact are explicitly *not* crossings — those are
    /// caught by ``hasDuplicateVertices(outer:holes:)`` instead — because treating them as
    /// crossings here would send every closed contour, whose consecutive edges share a vertex,
    /// down the repair path.
    private static func hasCrossingEdges(outer: [Vertex], holes: [[Vertex]]) -> Bool {
        var edges: [(Vertex, Vertex)] = []
        edges.reserveCapacity(outer.count + holes.reduce(0) { $0 + $1.count })
        func append(_ contour: [Vertex]) {
            guard contour.count >= 3 else { return }
            for index in contour.indices {
                edges.append((contour[index], contour[(index + 1) % contour.count]))
            }
        }
        append(outer)
        for hole in holes { append(hole) }
        guard edges.count >= 4 else { return false }
        for i in 0..<(edges.count - 1) {
            for j in (i + 1)..<edges.count {
                if segmentsProperlyCross(edges[i], edges[j]) { return true }
            }
        }
        return false
    }

    /// A *proper* crossing: the four orientation tests all disagree, which excludes shared
    /// endpoints, collinear overlap and a vertex lying exactly on the other segment.
    private static func segmentsProperlyCross(
        _ lhs: (Vertex, Vertex),
        _ rhs: (Vertex, Vertex)
    ) -> Bool {
        let d1 = cross(rhs.0, rhs.1, lhs.0)
        let d2 = cross(rhs.0, rhs.1, lhs.1)
        let d3 = cross(lhs.0, lhs.1, rhs.0)
        let d4 = cross(lhs.0, lhs.1, rhs.1)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
            && d1 != 0 && d2 != 0 && d3 != 0 && d4 != 0
    }

    /// One repaired region: a simple outer ring and the rings nested directly inside it.
    private struct Region {
        var outer: [Vertex]
        var holes: [[Vertex]]
    }

    /// Rebuilds a degenerate region into simple, properly nested, non-overlapping rings.
    ///
    /// Three steps, and each one exists because the previous one is not enough on its own:
    ///
    /// 1. **Clipper2, even-odd.** Resolves edges that actually cross. It does not, however,
    ///    always return disjoint rings: two contours that touch at a single vertex come back
    ///    joined into one keyholed ring that visits that vertex twice.
    /// 2. **Split at repeated vertices.** Every loop that visits a point twice is cut there into
    ///    two loops, recursively, until no loop repeats a vertex. This is what turns a keyhole
    ///    back into a parent and a hole, and a pinched hourglass into its two lobes.
    /// 3. **Nest by containment depth.** Splitting alone would fill a keyhole's inner loop, which
    ///    is the opposite of what even-odd says. Depth decides: even is a filled region, odd is a
    ///    hole belonging to the innermost loop that encloses it.
    ///
    /// Returns `nil` only when nothing survives, in which case the caller falls back to plain ear
    /// clipping — a wrong-looking fill is still better than a markup that silently vanishes.
    private static func repairByEvenOddNormalisation(
        outer: [Vertex],
        holes: [[Vertex]]
    ) -> [Region]? {
        var input: [[Vertex]] = [outer]
        input.append(contentsOf: holes)

        var paths: ClipperPaths = input.map { contour in contour.map { CGPoint(x: $0.x, y: $0.y) } }
        var rings: [[Vertex]] = input
        if let normalized = try? Clipper2.normalized(paths, fillRule: .evenOdd, scale: .pagePoints),
           !normalized.isEmpty {
            rings = normalized.map { ring in ring.map { Vertex(x: Double($0.x), y: Double($0.y)) } }
        }
        paths = []

        var contours: [[Vertex]] = []
        for ring in rings {
            contours.append(contentsOf: splitAtRepeatedVertices(ring))
        }
        contours = contours.filter { $0.count >= 3 }
        guard !contours.isEmpty else { return nil }

        // Nesting by containment depth rather than by winding: Clipper2's orientation convention
        // depends on the axis direction of the caller's space, and depth does not.
        var depth = [Int](repeating: 0, count: contours.count)
        var containers = [[Int]](repeating: [], count: contours.count)
        for i in contours.indices {
            for j in contours.indices where i != j {
                if contour(contours[j], contains: contours[i]) {
                    depth[i] += 1
                    containers[i].append(j)
                }
            }
        }

        var regions: [Int: Region] = [:]
        for i in contours.indices where depth[i] % 2 == 0 {
            regions[i] = Region(outer: contours[i], holes: [])
        }
        for i in contours.indices where depth[i] % 2 == 1 {
            // The immediate parent is the container with the greatest depth: the innermost loop
            // that still encloses this one.
            guard let parent = containers[i].max(by: { depth[$0] < depth[$1] }) else { continue }
            regions[parent]?.holes.append(contours[i])
        }
        let result = Array(regions.values).map(separatingTouchingHoles)
        return result.isEmpty ? nil : result
    }

    /// Nudges a hole that shares a vertex with its parent or with another hole.
    ///
    /// The bridge construction cuts a channel from the parent's boundary to the hole's rightmost
    /// vertex. If the hole *also* touches the parent somewhere else, the merged contour pinches
    /// at that point, ear clipping stalls, and the desperate-mode fallback emits overlapping
    /// triangles — which Core Graphics hides behind a single `fillPath` and the GPU does not.
    ///
    /// Shrinking the hole about its centroid by ``touchSeparationPagePoints`` breaks the contact.
    /// One micro-point is 6/100 000 of a device pixel at 6400 % zoom, so nothing is visible and
    /// no measurement is affected — the measurement engine never sees this geometry, which exists
    /// only to be rasterised. Doing it here, rather than in the bridge, keeps the nudge confined
    /// to the one configuration that needs it: a region that has already been found degenerate.
    private static func separatingTouchingHoles(_ region: Region) -> Region {
        guard !region.holes.isEmpty else { return region }
        var occupied = Set<Int64>()
        for vertex in region.outer { occupied.insert(quantizedKey(vertex)) }
        var holes: [[Vertex]] = []
        holes.reserveCapacity(region.holes.count)
        for hole in region.holes {
            let touches = hole.contains { occupied.contains(quantizedKey($0)) }
            let adjusted = touches ? shrunk(hole, by: touchSeparationPagePoints) : hole
            for vertex in adjusted { occupied.insert(quantizedKey(vertex)) }
            holes.append(adjusted)
        }
        return Region(outer: region.outer, holes: holes)
    }

    /// How far a touching hole is pulled away from its parent, in page points.
    private static let touchSeparationPagePoints = 1e-6

    /// Scales a contour about its centroid so its outermost vertex moves inward by `epsilon`.
    private static func shrunk(_ contour: [Vertex], by epsilon: Double) -> [Vertex] {
        guard !contour.isEmpty else { return contour }
        let count = Double(contour.count)
        let centerX = contour.reduce(0.0) { $0 + $1.x } / count
        let centerY = contour.reduce(0.0) { $0 + $1.y } / count
        var radius = 0.0
        for vertex in contour {
            let dx = vertex.x - centerX
            let dy = vertex.y - centerY
            radius = Swift.max(radius, (dx * dx + dy * dy).squareRoot())
        }
        guard radius > epsilon else { return contour }
        let factor = 1 - epsilon / radius
        return contour.map {
            Vertex(x: centerX + ($0.x - centerX) * factor, y: centerY + ($0.y - centerY) * factor)
        }
    }

    /// Cuts a loop that visits the same point twice into two loops, recursively.
    ///
    /// Bounded: a loop of n vertices can be split at most n times, and the work list is capped so
    /// that a pathological contour cannot spin.
    private static func splitAtRepeatedVertices(_ contour: [Vertex]) -> [[Vertex]] {
        var finished: [[Vertex]] = []
        var pending: [[Vertex]] = [contour]
        var iterations = 0
        let limit = Swift.max(64, contour.count * 4)
        while let loop = pending.popLast() {
            iterations += 1
            guard iterations <= limit else {
                finished.append(loop)
                continue
            }
            var firstSeen: [Int64: Int] = [:]
            var cut: (Int, Int)?
            for (index, vertex) in loop.enumerated() {
                let key = quantizedKey(vertex)
                if let prior = firstSeen[key] {
                    cut = (prior, index)
                    break
                }
                firstSeen[key] = index
            }
            guard let (first, second) = cut else {
                if loop.count >= 3 { finished.append(loop) }
                continue
            }
            // The two loops each keep one copy of the shared vertex.
            let inner = Array(loop[first..<second])
            let outerLoop = Array(loop[second...]) + Array(loop[..<first])
            if inner.count >= 3 { pending.append(inner) }
            if outerLoop.count >= 3 { pending.append(outerLoop) }
        }
        return finished
    }

    /// A point quantised to a millionth of a page point, for identity comparison.
    private static func quantizedKey(_ vertex: Vertex) -> Int64 {
        let x = Int64((vertex.x * 1_000_000).rounded())
        let y = Int64((vertex.y * 1_000_000).rounded())
        return x &* 73_856_093 &+ y &* 19_349_663
    }

    /// True when every tested vertex of `inner` lies inside `outer` by even-odd ray crossing.
    ///
    /// Up to five vertices are tested and the majority decides, so a single vertex that happens
    /// to sit exactly on the other ring's boundary cannot flip the answer.
    private static func contour(_ outer: [Vertex], contains inner: [Vertex]) -> Bool {
        guard outer.count >= 3, !inner.isEmpty else { return false }
        let step = Swift.max(1, inner.count / 5)
        var inside = 0
        var tested = 0
        var index = 0
        while index < inner.count, tested < 5 {
            if pointInContour(inner[index], outer) { inside += 1 }
            tested += 1
            index += step
        }
        return tested > 0 && inside * 2 > tested
    }

    private static func pointInContour(_ point: Vertex, _ contour: [Vertex]) -> Bool {
        var crossings = 0
        for index in contour.indices {
            let a = contour[index]
            let b = contour[(index + 1) % contour.count]
            guard (a.y > point.y) != (b.y > point.y) else { continue }
            let t = (point.y - a.y) / (b.y - a.y)
            guard t.isFinite else { continue }
            if a.x + t * (b.x - a.x) > point.x { crossings += 1 }
        }
        return crossings % 2 == 1
    }

    // MARK: - Hole bridging (Eberly)

    private static func spliceHole(_ hole: [Vertex], into outer: [Vertex]) -> [Vertex] {
        guard let mIndex = hole.indices.max(by: { hole[$0].x < hole[$1].x }) else { return outer }
        let m = hole[mIndex]

        // Cast +x from M and find the nearest crossing of an outer edge.
        var bestX = Double.infinity
        var bestEdge: Int?
        for index in outer.indices {
            let a = outer[index]
            let b = outer[(index + 1) % outer.count]
            guard (a.y > m.y) != (b.y > m.y) else { continue }
            let t = (m.y - a.y) / (b.y - a.y)
            guard t.isFinite else { continue }
            let x = a.x + t * (b.x - a.x)
            guard x.isFinite, x >= m.x, x < bestX else { continue }
            bestX = x
            bestEdge = index
        }
        guard let edge = bestEdge, bestX.isFinite else { return outer }

        let a = outer[edge]
        let b = outer[(edge + 1) % outer.count]
        // P: the endpoint of the crossed edge with the larger x, Eberly's initial candidate.
        var pIndex = a.x >= b.x ? edge : (edge + 1) % outer.count
        let intersection = Vertex(x: bestX, y: m.y)

        // Any reflex outer vertex inside triangle (M, I, P) blocks the bridge; the one with the
        // smallest angle to +x from M replaces P, and among equal angles the nearest wins.
        var bestAngle = Double.infinity
        var bestDistance = Double.infinity
        let initialP = outer[pIndex]
        var replacement: Int?
        for index in outer.indices {
            let v = outer[index]
            guard isReflex(outer, index) else { continue }
            guard pointInTriangle(v, m, intersection, initialP) else { continue }
            let dx = v.x - m.x
            let dy = v.y - m.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance > 0 else { continue }
            let angle = Swift.abs(dy) / distance
            if angle < bestAngle || (angle == bestAngle && distance < bestDistance) {
                bestAngle = angle
                bestDistance = distance
                replacement = index
            }
        }
        if let replacement { pIndex = replacement }

        // Splice: outer[0...p], hole rotated to start at M, M again, outer[p...].
        var merged: [Vertex] = []
        merged.reserveCapacity(outer.count + hole.count + 2)
        for index in 0...pIndex { merged.append(outer[index]) }
        for offset in 0..<hole.count { merged.append(hole[(mIndex + offset) % hole.count]) }
        merged.append(hole[mIndex])
        merged.append(outer[pIndex])
        for index in (pIndex + 1)..<outer.count { merged.append(outer[index]) }
        return merged
    }

    private static func isReflex(_ contour: [Vertex], _ index: Int) -> Bool {
        let count = contour.count
        let previous = contour[(index + count - 1) % count]
        let current = contour[index]
        let next = contour[(index + 1) % count]
        return cross(previous, current, next) < 0
    }

    private static func cross(_ a: Vertex, _ b: Vertex, _ c: Vertex) -> Double {
        (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
    }

    private static func pointInTriangle(_ p: Vertex, _ a: Vertex, _ b: Vertex, _ c: Vertex) -> Bool {
        let d1 = cross(a, b, p)
        let d2 = cross(b, c, p)
        let d3 = cross(c, a, p)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    // MARK: - Ear clipping

    private static func earClip(_ contour: [Vertex]) -> [Triangle] {
        var indices = Array(contour.indices)
        var triangles: [Triangle] = []
        triangles.reserveCapacity(Swift.max(0, contour.count - 2))

        var stalledPasses = 0
        var cursor = 0
        while indices.count > 3 {
            let count = indices.count
            let previous = indices[(cursor + count - 1) % count]
            let current = indices[cursor % count]
            let next = indices[(cursor + 1) % count]
            let a = contour[previous], b = contour[current], c = contour[next]

            let convex = cross(a, b, c) > 0
            var isEar = convex
            if isEar {
                for index in indices where index != previous && index != current && index != next {
                    if pointInTriangle(contour[index], a, b, c) {
                        isEar = false
                        break
                    }
                }
            }

            if isEar {
                triangles.append(Triangle(
                    a: PDFPoint(x: a.x, y: a.y),
                    b: PDFPoint(x: b.x, y: b.y),
                    c: PDFPoint(x: c.x, y: c.y)
                ))
                indices.remove(at: cursor % count)
                if cursor >= indices.count { cursor = 0 }
                stalledPasses = 0
                continue
            }

            cursor = (cursor + 1) % count
            stalledPasses += 1
            if stalledPasses > count {
                // Desperate mode: no vertex passes the containment test, which means the contour
                // is self-touching or numerically degenerate. Clip the smallest-area convex
                // candidate — or, if none is convex, the smallest-area candidate at all — so the
                // loop always terminates with a triangulation whose coverage still matches an
                // even-odd fill of the same contour.
                let victim = smallestCandidate(contour, indices)
                let cnt = indices.count
                let pIdx = indices[(victim + cnt - 1) % cnt]
                let cIdx = indices[victim]
                let nIdx = indices[(victim + 1) % cnt]
                triangles.append(Triangle(
                    a: PDFPoint(x: contour[pIdx].x, y: contour[pIdx].y),
                    b: PDFPoint(x: contour[cIdx].x, y: contour[cIdx].y),
                    c: PDFPoint(x: contour[nIdx].x, y: contour[nIdx].y)
                ))
                indices.remove(at: victim)
                cursor = 0
                stalledPasses = 0
            }
        }

        if indices.count == 3 {
            let a = contour[indices[0]], b = contour[indices[1]], c = contour[indices[2]]
            triangles.append(Triangle(
                a: PDFPoint(x: a.x, y: a.y),
                b: PDFPoint(x: b.x, y: b.y),
                c: PDFPoint(x: c.x, y: c.y)
            ))
        }
        return triangles.filter { $0.area > 0 }
    }

    private static func smallestCandidate(_ contour: [Vertex], _ indices: [Int]) -> Int {
        let count = indices.count
        var bestConvex: (position: Int, area: Double)?
        var bestAny: (position: Int, area: Double) = (0, .infinity)
        for position in 0..<count {
            let a = contour[indices[(position + count - 1) % count]]
            let b = contour[indices[position]]
            let c = contour[indices[(position + 1) % count]]
            let signed = cross(a, b, c)
            let area = Swift.abs(signed) / 2
            if area < bestAny.area { bestAny = (position, area) }
            if signed > 0, bestConvex == nil || area < bestConvex!.area {
                bestConvex = (position, area)
            }
        }
        return bestConvex?.position ?? bestAny.position
    }
}
