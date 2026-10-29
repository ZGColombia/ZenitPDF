import Foundation
import ZPDFContracts
import ZPDFGeometry

/// The planar arrangement the trace walks.
///
/// # What it is
///
/// A drawing is not a graph. It is a heap of independent strokes that happen to touch, cross and
/// very nearly meet. Walking a boundary needs a graph, so this type builds one:
///
/// 1. **Split at crossings.** Every pair of segments whose bounding boxes overlap is intersected,
///    and both are cut at the crossing. This is the step that makes a dimension line harmless: a
///    wall crossed by one is two edges meeting at a node, and the walk continues straight
///    through instead of stopping at a stroke that is not there.
/// 2. **Snap endpoints into nodes.** Points within ``TraceOptions/joinTolerance`` become one
///    node. Points are consumed in lexicographic order, so which points gather is a function of
///    the point set and not of the order the extractor emitted primitives, and each node sits at
///    the one of its points that the longest drawn lines run through, so a long line is never
///    bent off its course towards the end of a short stroke beside it.
/// 3. **Bridge loose ends, but only just.** A node of degree one is a boundary that stops. If
///    another node — or a wall it stops short of — is within ``TraceOptions/gapTolerance``, an
///    edge is added and the distance is recorded. Anything wider is left broken so the walk can
///    refuse and say where.
/// 4. **Mend crossings.** Snapping moves a split point off its segment and bridging adds edges
///    nothing was intersected with, so two edges can end up crossing with no node
///    between them. Every such crossing becomes a node, exactly where the two edges cross.
/// 5. **Contract point edges.** An edge whose two nodes sit at one point has no direction, so
///    it has no place in the angular order below; its two nodes are merged into one.
/// 6. **Sort the darts.** Each edge becomes two directed darts, and every node holds its
///    outgoing darts in counter-clockwise angular order. That ordering is the whole face walk:
///    the next dart after `u→v` is the cyclic predecessor of `v→u` around `v`, which keeps the
///    face on the left and traverses bounded faces counter-clockwise.
///
/// # What it is not
///
/// It is not a general arrangement library. Overlapping collinear edges are merged rather than
/// layered, and a pair of edges between the same two nodes is kept once — a drawing that traces
/// the same wall twice is one wall here.
struct TracePlanarGraph: Sendable {

    struct Edge: Sendable, Hashable {
        var a: Int
        var b: Int
    }

    /// Node positions, indexed by node id.
    let points: [PDFPoint]
    let edges: [Edge]
    /// Outgoing dart ids per node, sorted counter-clockwise by angle.
    let adjacency: [[Int]]
    /// Where each dart sits inside `adjacency[from(dart)]`.
    let dartPosition: [Int]
    /// Every edge bridging added, keyed by its two nodes, to the bridge it belongs to — an index
    /// into ``bridgeWidths``. A bridge later split by another loose end's foot is two edges of
    /// one bridge.
    let bridgeOfEdge: [Edge: Int]
    /// The gap each bridge closed, page points.
    let bridgeWidths: [Double]

    // MARK: - Darts

    /// A dart is an edge with a direction. `dart >> 1` is the edge; the low bit is the sense.
    func reverse(_ dart: Int) -> Int { dart ^ 1 }

    func from(_ dart: Int) -> Int {
        let edge = edges[dart >> 1]
        return dart & 1 == 0 ? edge.a : edge.b
    }

    func to(_ dart: Int) -> Int {
        let edge = edges[dart >> 1]
        return dart & 1 == 0 ? edge.b : edge.a
    }

    /// The next dart of the face that lies to the **left** of `dart`.
    ///
    /// Take the reversed dart at the far node and step one place clockwise in the
    /// counter-clockwise ordering — that is, to its cyclic predecessor. On a square laid out
    /// counter-clockwise this walks the interior; on the same square entered from the other
    /// side it walks the exterior clockwise, which is exactly how the unbounded face is
    /// recognised (its signed area is not positive).
    func next(after dart: Int) -> Int {
        let node = to(dart)
        let back = reverse(dart)
        let ring = adjacency[node]
        guard !ring.isEmpty else { return back }
        let position = dartPosition[back]
        let previous = (position + ring.count - 1) % ring.count
        return ring[previous]
    }

    /// ``next(after:)`` in the arrangement with the edges in `ignoring` taken out: the cyclic
    /// predecessor of the reversed dart among the darts left at the far node, or the reversed
    /// dart itself when nothing else is left there.
    func next(after dart: Int, ignoring: Set<Int>) -> Int {
        guard !ignoring.isEmpty else { return next(after: dart) }
        let node = to(dart)
        let back = reverse(dart)
        let ring = adjacency[node]
        var position = dartPosition[back]
        for _ in 0..<ring.count {
            position = (position + ring.count - 1) % ring.count
            if !ignoring.contains(ring[position] >> 1) { return ring[position] }
        }
        return back
    }

    /// The dart from `u` to `v`, when an edge joins them.
    func dart(from u: Int, to v: Int) -> Int? {
        adjacency[u].first { to($0) == v }
    }

    func degree(of node: Int) -> Int { adjacency[node].count }

    // MARK: - Building

    enum BuildOutcome {
        case built(TracePlanarGraph)
        case tooComplex(count: Int)
    }

    static func build(segments: [TraceSegment], options: TraceOptions) -> BuildOutcome {
        guard !segments.isEmpty else {
            return .built(
                TracePlanarGraph(
                    points: [],
                    edges: [],
                    adjacency: [],
                    dartPosition: [],
                    bridgeOfEdge: [:],
                    bridgeWidths: []
                )
            )
        }

        var budget = options.maximumPairTests

        // 1. Crossings.
        var splits: [[Double]]
        switch splitParameters(segments: segments, budget: &budget) {
        case .failure(let count): return .tooComplex(count: count)
        case .success(let value): splits = value
        }

        // 2. Nodes.
        let maximumRefs = options.maximumSegments * 4
        var refs: [(segment: Int, t: Double, point: PDFPoint)] = []
        refs.reserveCapacity(segments.count * 2)
        for (index, segment) in segments.enumerated() {
            var parameters = splits[index]
            parameters.append(0)
            parameters.append(1)
            parameters.sort()
            guard refs.count + parameters.count <= maximumRefs else {
                return .tooComplex(count: refs.count + parameters.count)
            }
            var lastValue = -Double.infinity
            for raw in parameters {
                let t = Swift.min(Swift.max(raw.isFinite ? raw : 0, 0), 1)
                // Parameters equal to within the join tolerance expressed on this segment
                // collapse anyway once the points are snapped; dropping them here keeps the
                // reference list small on a segment crossed by hundreds of others.
                if t - lastValue < 1e-12 { continue }
                lastValue = t
                refs.append((segment: index, t: t, point: point(on: segment, at: t)))
            }
        }

        let assignment = assignNodes(
            refs: refs,
            lengths: segments.map { $0.start.distance(to: $0.end) },
            joinTolerance: options.joinTolerance
        )
        var points = assignment.points
        let nodeOfRef = assignment.nodeOfRef

        // 3. Edges.
        var edges: [Edge] = []
        var edgeKeys = Set<Edge>()
        var cursor = 0
        while cursor < refs.count {
            let segment = refs[cursor].segment
            var end = cursor
            while end + 1 < refs.count, refs[end + 1].segment == segment { end += 1 }
            var previous = -1
            for index in cursor...end {
                let node = nodeOfRef[index]
                if node != previous, previous >= 0 {
                    let key = Edge(a: Swift.min(previous, node), b: Swift.max(previous, node))
                    if edgeKeys.insert(key).inserted { edges.append(key) }
                }
                if node != previous { previous = node }
            }
            cursor = end + 1
        }

        guard edges.count <= maximumRefs else { return .tooComplex(count: edges.count) }

        // 4. Bridging.
        let bridging = bridgeLooseEnds(
            points: &points,
            edges: &edges,
            edgeKeys: &edgeKeys,
            options: options,
            budget: &budget
        )
        if case .tooComplex(let count) = bridging { return .tooComplex(count: count) }
        guard case .bridged(var bridgeOfEdge, let bridgeWidths) = bridging else {
            return .tooComplex(count: edges.count)
        }

        // 5. Crossings left without a node.
        if let count = mendCrossings(points: &points, edges: &edges, bridgeOfEdge: &bridgeOfEdge, budget: &budget) {
            return .tooComplex(count: count)
        }
        guard edges.count <= maximumRefs else { return .tooComplex(count: edges.count) }

        // 6. Edges too short to have a direction.
        contractPointEdges(points: points, edges: &edges, bridgeOfEdge: &bridgeOfEdge)

        // 7. Darts.
        var adjacency = [[Int]](repeating: [], count: points.count)
        var dartPosition = [Int](repeating: 0, count: edges.count * 2)
        var angles = [Double](repeating: 0, count: edges.count * 2)

        for (index, edge) in edges.enumerated() {
            let forward = index * 2
            let backward = forward + 1
            let a = points[edge.a]
            let b = points[edge.b]
            angles[forward] = atan2(b.y - a.y, b.x - a.x)
            angles[backward] = atan2(a.y - b.y, a.x - b.x)
            adjacency[edge.a].append(forward)
            adjacency[edge.b].append(backward)
        }

        for node in adjacency.indices {
            adjacency[node].sort { left, right in
                if angles[left] != angles[right] { return angles[left] < angles[right] }
                return left < right
            }
            for (position, dart) in adjacency[node].enumerated() { dartPosition[dart] = position }
        }

        return .built(
            TracePlanarGraph(
                points: points,
                edges: edges,
                adjacency: adjacency,
                dartPosition: dartPosition,
                bridgeOfEdge: bridgeOfEdge,
                bridgeWidths: bridgeWidths
            )
        )
    }

    // MARK: - Crossings

    private enum SplitOutcome {
        case success([[Double]])
        case failure(count: Int)
    }

    /// Every parameter at which a segment must be cut, found by a sweep on `minX` with an
    /// active list. Quadratic in the worst case, which is what `budget` is for.
    private static func splitParameters(
        segments: [TraceSegment],
        budget: inout Int
    ) -> SplitOutcome {
        var splits = [[Double]](repeating: [], count: segments.count)
        let order = segments.indices.sorted { left, right in
            let a = segments[left].minX
            let b = segments[right].minX
            return a != b ? a < b : left < right
        }

        var active: [Int] = []
        var tested = 0

        for index in order {
            let current = segments[index]

            var write = 0
            for slot in active.indices where segments[active[slot]].maxX >= current.minX - 1e-9 {
                active[write] = active[slot]
                write += 1
            }
            active.removeLast(active.count - write)

            let currentGeometry = SegmentGeometry(start: current.start, end: current.end)
            for other in active {
                let candidate = segments[other]
                if candidate.maxY < current.minY - 1e-9 { continue }
                if candidate.minY > current.maxY + 1e-9 { continue }

                tested += 1
                if tested > budget { return .failure(count: tested) }

                let candidateGeometry = SegmentGeometry(start: candidate.start, end: candidate.end)
                switch SegmentMath.intersect(currentGeometry, candidateGeometry) {
                case .none, .parallelDisjoint:
                    continue
                case .point(_, let tOnFirst, let tOnSecond):
                    splits[index].append(tOnFirst)
                    splits[other].append(tOnSecond)
                case .collinearOverlap(_, let rangeOnFirst, let rangeOnSecond):
                    splits[index].append(rangeOnFirst.lowerBound)
                    splits[index].append(rangeOnFirst.upperBound)
                    splits[other].append(rangeOnSecond.lowerBound)
                    splits[other].append(rangeOnSecond.upperBound)
                }
            }
            active.append(index)
        }

        budget -= tested
        return .success(splits)
    }

    private static func point(on segment: TraceSegment, at t: Double) -> PDFPoint {
        if t <= 0 { return segment.start }
        if t >= 1 { return segment.end }
        return PDFPoint(
            x: segment.start.x + (segment.end.x - segment.start.x) * t,
            y: segment.start.y + (segment.end.y - segment.start.y) * t
        )
    }

    // MARK: - Node snapping

    private struct CellKey: Hashable {
        let x: Int
        let y: Int
    }

    private static func cellIndex(_ value: Double, _ cell: Double) -> Int {
        let quotient = (value / cell).rounded(.down)
        guard quotient.isFinite else { return 0 }
        return Int(Swift.max(-4.0e18, Swift.min(4.0e18, quotient)))
    }

    /// Gathers the points within the join tolerance of each other into nodes, and places each
    /// node where the drawing's longest lines through it stay straight.
    ///
    /// Membership is decided greedily in lexicographic order: a point joins the nearest node
    /// within the tolerance of the first point that founded it, or founds a node of its own. That
    /// founding point used to be where the node stayed, and when it was the end of a short stroke
    /// beside a long line, every split point of the line within the tolerance was pulled onto
    /// it: the line bent through a point up to 0.75 pt off its course, and so did the boundary of
    /// every face along it, all the way to the line's next node. On the synthetic roof plan one
    /// hatch glyph whose stroke crossed the upper hip 0.73 pt from its base bent the hip 0.71 pt
    /// off its line, and the upper face came back 196 pt² (0.22 %) too large.
    ///
    /// So each node is placed, among its own points, at the one the most drawing runs through:
    /// the points of a cluster that coincide (to ``sameNode``) are one candidate, worth the sum
    /// of the lengths of the distinct segments that have a point there, and the heaviest
    /// candidate wins. A split point of a long line outweighs the end of a short stroke, so the
    /// line stays straight and the stroke moves; a wall corner, where two walls end, outweighs
    /// a hatch stroke crossing one of them just beside it, so the corner stays. A tie keeps the
    /// founding point, which is where every node with one candidate sits anyway.
    private static func assignNodes(
        refs: [(segment: Int, t: Double, point: PDFPoint)],
        lengths: [Double],
        joinTolerance: Double
    ) -> (points: [PDFPoint], nodeOfRef: [Int]) {
        let cell = Swift.max(joinTolerance, 1e-9)
        var buckets: [CellKey: [Int]] = [:]
        var points: [PDFPoint] = []
        var nodeOfRef = [Int](repeating: -1, count: refs.count)

        let order = refs.indices.sorted { left, right in
            let a = refs[left].point
            let b = refs[right].point
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            if refs[left].segment != refs[right].segment {
                return refs[left].segment < refs[right].segment
            }
            return refs[left].t < refs[right].t
        }

        for index in order {
            let candidate = refs[index].point
            let ix = cellIndex(candidate.x, cell)
            let iy = cellIndex(candidate.y, cell)

            var best = -1
            var bestDistance = Double.infinity
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let bucket = buckets[CellKey(x: ix + dx, y: iy + dy)] else { continue }
                    for node in bucket {
                        let distance = points[node].distance(to: candidate)
                        guard distance <= joinTolerance else { continue }
                        if distance < bestDistance || (distance == bestDistance && node < best) {
                            best = node
                            bestDistance = distance
                        }
                    }
                }
            }

            if best >= 0 {
                nodeOfRef[index] = best
            } else {
                let node = points.count
                points.append(candidate)
                buckets[CellKey(x: ix, y: iy), default: []].append(node)
                nodeOfRef[index] = node
            }
        }

        // Only a node that gathered a point off its founding point can move.
        var gathered = [Bool](repeating: false, count: points.count)
        for index in refs.indices where refs[index].point != points[nodeOfRef[index]] {
            gathered[nodeOfRef[index]] = true
        }
        guard gathered.contains(true) else { return (points, nodeOfRef) }
        var members: [Int: [Int]] = [:]
        for index in order where gathered[nodeOfRef[index]] {
            members[nodeOfRef[index], default: []].append(index)
        }
        for node in members.keys.sorted() {
            guard let list = members[node] else { continue }
            points[node] = straightestPosition(of: list, refs: refs, lengths: lengths)
        }
        return (points, nodeOfRef)
    }

    /// The point of a cluster that the longest drawing runs through — see `assignNodes`. `list`
    /// holds the cluster's references in lexicographic order, so the first candidate is the
    /// founding point and a tie keeps it.
    private static func straightestPosition(
        of list: [Int],
        refs: [(segment: Int, t: Double, point: PDFPoint)],
        lengths: [Double]
    ) -> PDFPoint {
        var heads: [PDFPoint] = []
        var weights: [Double] = []
        var through: [Set<Int>] = []
        var cells: [CellKey: [Int]] = [:]
        for index in list {
            let point = refs[index].point
            let segment = refs[index].segment
            let ix = cellIndex(point.x, Self.sameNode)
            let iy = cellIndex(point.y, Self.sameNode)
            var found = -1
            search: for dx in -1...1 {
                for dy in -1...1 {
                    for group in cells[CellKey(x: ix + dx, y: iy + dy)] ?? []
                    where heads[group].distance(to: point) <= Self.sameNode {
                        found = group
                        break search
                    }
                }
            }
            if found < 0 {
                found = heads.count
                heads.append(point)
                weights.append(0)
                through.append([])
                cells[CellKey(x: ix, y: iy), default: []].append(found)
            }
            if through[found].insert(segment).inserted {
                weights[found] += lengths[segment].isFinite ? lengths[segment] : 0
            }
        }
        var best = 0
        for group in heads.indices where weights[group] > weights[best] { best = group }
        return heads[best]
    }

    // MARK: - Bridging

    private enum BridgeOutcome {
        case bridged(bridgeOfEdge: [Edge: Int], widths: [Double])
        case tooComplex(count: Int)
    }

    /// Joins boundaries that stop just short of each other, and only those.
    ///
    /// A node of degree one is a stroke that ends in mid-air. If something is within
    /// ``TraceOptions/gapTolerance`` it is joined; otherwise the break stays, and the walk
    /// refuses at it. This is the only place the tracer adds geometry, which is why the widest
    /// distance it used is carried out to the caller.
    private static func bridgeLooseEnds(
        points: inout [PDFPoint],
        edges: inout [Edge],
        edgeKeys: inout Set<Edge>,
        options: TraceOptions,
        budget: inout Int
    ) -> BridgeOutcome {
        var degree = [Int](repeating: 0, count: points.count)
        var neighbours = [Set<Int>](repeating: [], count: points.count)
        for edge in edges {
            degree[edge.a] += 1
            degree[edge.b] += 1
            neighbours[edge.a].insert(edge.b)
            neighbours[edge.b].insert(edge.a)
        }

        let loose = points.indices
            .filter { degree[$0] == 1 }
            .sorted { left, right in
                let a = points[left]
                let b = points[right]
                if a.x != b.x { return a.x < b.x }
                if a.y != b.y { return a.y < b.y }
                return left < right
            }
        guard !loose.isEmpty else { return .bridged(bridgeOfEdge: [:], widths: []) }

        let cell = Swift.max(options.gapTolerance, 1e-9)
        var buckets: [CellKey: [Int]] = [:]
        for node in points.indices {
            let key = CellKey(x: cellIndex(points[node].x, cell), y: cellIndex(points[node].y, cell))
            buckets[key, default: []].append(node)
        }

        var bridgeOfEdge: [Edge: Int] = [:]
        var widths: [Double] = []

        // The edges a loose end can bridge to are the ones whose box comes within the gap
        // tolerance of it, so they are found through a packed R-tree over the edges as they
        // stand now, not by a scan of every edge per loose end. The scan charged
        // `edges.count` to the pair budget per loose end, before looking, so a sheet of
        // stroked text drained 12 million pair tests on a room a person could trace by hand
        // (BH-667). The budget is now charged for the candidates actually tested.
        //
        // An edge split below keeps its index and shrinks to a piece of itself, so its box in
        // the tree (or its cells in the grid) still covers it. Edges appended during bridging
        // go into a grid keyed on every cell their segment passes through. They used to be
        // tested linearly by every later loose end, which is quadratic in the number of
        // bridges: on a real A1 roof plan whose sedum hatch is thousands of tiny strokes,
        // 3 700 bridges appended 6 300 edges and that tail alone drained the 12 million pair
        // tests, so every ⌥-click whose window reached the hatch came back "too complex"
        // (L-73). The candidates are still visited in ascending index order — the tree's
        // first, then the grid's — which is the order the scan used, so every tie is broken
        // exactly as before.
        let initialEdgeCount = edges.count
        let edgeTree = try? PackedRTree(
            boxes: edges.map { PDFRect(corner: points[$0.a], opposite: points[$0.b]) }
        )
        let reach = options.gapTolerance * (1 + 1e-9) + 1e-9
        var appendedGrid = SegmentCellGrid(cell: 2 * reach)
        var appendedHits: [Int] = []
        var hits: [Int] = []

        for end in loose {
            guard degree[end] == 1 else { continue }
            let origin = points[end]

            var bestNode = -1
            var bestDistance = Double.infinity
            let ix = cellIndex(origin.x, cell)
            let iy = cellIndex(origin.y, cell)
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let bucket = buckets[CellKey(x: ix + dx, y: iy + dy)] else { continue }
                    for node in bucket where node != end && !neighbours[end].contains(node) {
                        let distance = origin.distance(to: points[node])
                        guard distance <= options.gapTolerance else { continue }
                        if distance < bestDistance || (distance == bestDistance && node < bestNode) {
                            bestNode = node
                            bestDistance = distance
                        }
                    }
                }
            }

            // A loose end that stops short of the middle of a wall, rather than of another
            // loose end. The foot has to be strictly inside the edge: an end near an edge's
            // endpoint is the node case above, already handled and cheaper.
            var bestEdge = -1
            var bestFoot = PDFPoint.zero
            hits.removeAll(keepingCapacity: true)
            if let edgeTree {
                // A hair wider than the tolerance, so rounding in the box arithmetic can only
                // add candidates; the exact rejects below decide.
                edgeTree.query(
                    PDFRect(x: origin.x - reach, y: origin.y - reach, width: 2 * reach, height: 2 * reach),
                    into: &hits
                )
                hits.sort()
            } else {
                hits.append(contentsOf: 0..<initialEdgeCount)
            }
            appendedGrid.candidates(near: origin, into: &appendedHits)
            hits.append(contentsOf: appendedHits)
            budget -= hits.count
            if budget < 0 { return .tooComplex(count: edges.count) }
            for index in hits {
                let edge = edges[index]
                if edge.a == end || edge.b == end { continue }
                let a = points[edge.a]
                let b = points[edge.b]
                if origin.x < Swift.min(a.x, b.x) - options.gapTolerance { continue }
                if origin.x > Swift.max(a.x, b.x) + options.gapTolerance { continue }
                if origin.y < Swift.min(a.y, b.y) - options.gapTolerance { continue }
                if origin.y > Swift.max(a.y, b.y) + options.gapTolerance { continue }
                let nearest = SegmentMath.nearestPoint(
                    on: SegmentGeometry(start: a, end: b),
                    to: origin
                )
                guard nearest.distance <= options.gapTolerance, !nearest.isEndpoint else { continue }
                if nearest.distance < bestDistance {
                    bestDistance = nearest.distance
                    bestNode = -1
                    bestEdge = index
                    bestFoot = nearest.point
                }
            }

            if bestEdge >= 0 {
                let old = edges[bestEdge]
                let inserted = points.count
                points.append(bestFoot)
                degree.append(0)
                neighbours.append([])
                let bucketKey = CellKey(
                    x: cellIndex(bestFoot.x, cell),
                    y: cellIndex(bestFoot.y, cell)
                )
                buckets[bucketKey, default: []].append(inserted)

                edgeKeys.remove(old)
                let first = Edge(a: Swift.min(old.a, inserted), b: Swift.max(old.a, inserted))
                let second = Edge(a: Swift.min(old.b, inserted), b: Swift.max(old.b, inserted))
                let bridge = Edge(a: Swift.min(end, inserted), b: Swift.max(end, inserted))
                edges[bestEdge] = first
                edgeKeys.insert(first)
                // A bridge split at the foot stays one bridge, in two pieces.
                if let split = bridgeOfEdge.removeValue(forKey: old) {
                    bridgeOfEdge[first] = split
                    bridgeOfEdge[second] = split
                }
                if edgeKeys.insert(second).inserted {
                    edges.append(second)
                    appendedGrid.insert(edges.count - 1, from: points[second.a], to: points[second.b])
                }
                if edgeKeys.insert(bridge).inserted {
                    edges.append(bridge)
                    appendedGrid.insert(edges.count - 1, from: points[bridge.a], to: points[bridge.b])
                }
                bridgeOfEdge[bridge] = widths.count
                widths.append(bestDistance)

                neighbours[old.a].remove(old.b)
                neighbours[old.b].remove(old.a)
                neighbours[old.a].insert(inserted)
                neighbours[inserted].insert(old.a)
                neighbours[old.b].insert(inserted)
                neighbours[inserted].insert(old.b)
                neighbours[end].insert(inserted)
                neighbours[inserted].insert(end)
                degree[inserted] = 3
                degree[end] += 1
            } else if bestNode >= 0 {
                let bridge = Edge(a: Swift.min(end, bestNode), b: Swift.max(end, bestNode))
                if edgeKeys.insert(bridge).inserted {
                    edges.append(bridge)
                    appendedGrid.insert(edges.count - 1, from: points[bridge.a], to: points[bridge.b])
                    neighbours[end].insert(bestNode)
                    neighbours[bestNode].insert(end)
                    degree[end] += 1
                    degree[bestNode] += 1
                    bridgeOfEdge[bridge] = widths.count
                    widths.append(bestDistance)
                }
            }
        }

        return .bridged(bridgeOfEdge: bridgeOfEdge, widths: widths)
    }

    // MARK: - Crossings without a node

    /// Two points this close are one node, page points: a crossing this near an edge's end is
    /// cut at that end, and an edge this short is contracted.
    private static let sameNode = 1e-9

    /// Puts a node wherever two edges cross with none between them, splitting both, and returns
    /// `nil` — or the pair tests made, when that passes `budget`.
    ///
    /// The face walk turns only at nodes, so an edge that crosses another without one is no
    /// boundary to it: the walk runs straight through a drawn line. Two things leave such a
    /// crossing. Snapping moves every split point to its node's position: when the node used to
    /// sit at the first point of its cluster, a split node of a sedum roof's hip line on a real
    /// roof plan moved about half a point off the line, a hatch stroke beside it then crossed
    /// the line between two nodes, and a click on one face of the roof traced all three faces as
    /// one (L-73 re-check). Placing nodes on the longest line keeps that line straight, but the
    /// strokes it moves can still cross something. And bridging joins a loose end to a node
    /// without intersecting the bridge with anything.
    ///
    /// Only proper crossings are mended — each edge strictly separates the other's two ends — at
    /// the point where the two edges cross, which is not snapped: snapping it is what caused the
    /// crossing. A piece of an edge is part of that edge, so no new crossing can appear, and a
    /// bridge cut in pieces stays one bridge.
    private static func mendCrossings(
        points: inout [PDFPoint],
        edges: inout [Edge],
        bridgeOfEdge: inout [Edge: Int],
        budget: inout Int
    ) -> Int? {
        guard edges.count > 1 else { return nil }
        let order = edges.indices.sorted { left, right in
            let a = Swift.min(points[edges[left].a].x, points[edges[left].b].x)
            let b = Swift.min(points[edges[right].a].x, points[edges[right].b].x)
            return a != b ? a < b : left < right
        }
        func cross(_ o: PDFPoint, _ a: PDFPoint, _ b: PDFPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var cuts: [Int: [(t: Double, node: Int)]] = [:]
        var active: [Int] = []
        var tested = 0
        for index in order {
            let edge = edges[index]
            let a = points[edge.a], b = points[edge.b]
            let minX = Swift.min(a.x, b.x)
            let minY = Swift.min(a.y, b.y), maxY = Swift.max(a.y, b.y)
            var write = 0
            for slot in active.indices
            where Swift.max(points[edges[active[slot]].a].x, points[edges[active[slot]].b].x) >= minX {
                active[write] = active[slot]
                write += 1
            }
            active.removeLast(active.count - write)

            for other in active {
                let candidate = edges[other]
                // Edges sharing a node meet there, which is a node already.
                if candidate.a == edge.a || candidate.a == edge.b || candidate.b == edge.a || candidate.b == edge.b {
                    continue
                }
                let c = points[candidate.a], d = points[candidate.b]
                if Swift.max(c.y, d.y) < minY || Swift.min(c.y, d.y) > maxY { continue }
                tested += 1
                if tested > budget { return tested }
                let d1 = cross(a, b, c), d2 = cross(a, b, d)
                guard (d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0) else { continue }
                let d3 = cross(c, d, a), d4 = cross(c, d, b)
                guard (d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0) else { continue }
                // Along a → b the crossing is where the distance to c–d changes sign; along
                // c → d, where the distance to a–b does.
                let t = d3 / (d3 - d4)
                let u = d1 / (d1 - d2)
                guard t > 0, t < 1, u > 0, u < 1 else { continue }
                let crossing = PDFPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                // A crossing a hair from one of the four ends is that node: the other edge is cut
                // there, and no sliver of an edge is made.
                if let end = [edge.a, edge.b].first(where: { points[$0].distance(to: crossing) <= Self.sameNode }) {
                    cuts[other, default: []].append((u, end))
                } else if let end = [candidate.a, candidate.b].first(where: { points[$0].distance(to: crossing) <= Self.sameNode }) {
                    cuts[index, default: []].append((t, end))
                } else {
                    let node = points.count
                    points.append(crossing)
                    cuts[index, default: []].append((t, node))
                    cuts[other, default: []].append((u, node))
                }
            }
            active.append(index)
        }
        budget -= tested
        guard !cuts.isEmpty else { return nil }

        // Rebuild in the old order, each crossed edge as its run of pieces.
        var rebuilt: [Edge] = []
        var keys = Set<Edge>()
        var bridges: [Edge: Int] = [:]
        rebuilt.reserveCapacity(edges.count + cuts.count * 2)
        for (index, edge) in edges.enumerated() {
            let bridge = bridgeOfEdge[edge]
            var chain = [edge.a]
            if let list = cuts[index] {
                for cut in list.sorted(by: { $0.t != $1.t ? $0.t < $1.t : $0.node < $1.node }) {
                    chain.append(cut.node)
                }
            }
            chain.append(edge.b)
            for step in 1..<chain.count {
                let u = chain[step - 1], v = chain[step]
                guard u != v else { continue }
                let key = Edge(a: Swift.min(u, v), b: Swift.max(u, v))
                if keys.insert(key).inserted { rebuilt.append(key) }
                if let bridge { bridges[key] = bridge }
            }
        }
        edges = rebuilt
        bridgeOfEdge = bridges
        return nil
    }

    // MARK: - Edges without a direction

    /// Merges the two nodes of every edge no longer than ``sameNode``, so that every edge left
    /// has a direction.
    ///
    /// The face walk turns at a node by the counter-clockwise order of its darts, and a dart's
    /// place in that order is the angle of its edge. An edge whose two nodes sit at one point has
    /// no angle: `atan2` of a zero vector files it due east (or west, by the signs of the zeros)
    /// whatever it joins, so the walk can leave the node on the wrong side of a line passing
    /// through it. Two construction steps can make one.
    /// Bridging can find a loose end lying on an edge, or on a node, that snapping or an earlier
    /// bridge put there: on the synthetic roof plan with hatch glyphs crossing the upper hip,
    /// while snapping still placed a node at the first point of its cluster, the hip's split
    /// point snapped onto a glyph base 0.71 pt off the line, the bent hip ran exactly through
    /// another glyph's tip, and the tip was bridged to a foot at its own position. The
    /// zero-length bridge sent the walk across the hip, and a click on the upper face traced the
    /// upper and middle faces as one, 331 800 pt² for 88 200. And mending can cut one edge twice
    /// at the same point when three edges cross there, one node per pair.
    ///
    /// Such an edge joins two points that are one point, so the nodes are merged into the one
    /// with the lower index — the same rule wherever the edges came from — and the edge goes.
    /// A bridge of no width closed no gap, so it is no longer counted as one.
    private static func contractPointEdges(
        points: [PDFPoint],
        edges: inout [Edge],
        bridgeOfEdge: inout [Edge: Int]
    ) {
        var parent: [Int] = []
        func root(_ node: Int) -> Int {
            var node = node
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }
        for edge in edges where points[edge.a].distance(to: points[edge.b]) <= Self.sameNode {
            if parent.isEmpty { parent = Array(points.indices) }
            let a = root(edge.a), b = root(edge.b)
            if a != b { parent[Swift.max(a, b)] = Swift.min(a, b) }
        }
        guard !parent.isEmpty else { return }

        var rebuilt: [Edge] = []
        var keys = Set<Edge>()
        var bridges: [Edge: Int] = [:]
        rebuilt.reserveCapacity(edges.count)
        for edge in edges {
            let a = root(edge.a), b = root(edge.b)
            guard a != b else { continue }
            let key = Edge(a: Swift.min(a, b), b: Swift.max(a, b))
            if keys.insert(key).inserted { rebuilt.append(key) }
            if let bridge = bridgeOfEdge[edge] { bridges[key] = bridge }
        }
        edges = rebuilt
        bridgeOfEdge = bridges
    }

    // MARK: - Bridges a ring uses

    /// How many bridges the closed node cycle `cycle` runs along, and the widest gap among them
    /// — the joins a traced ring actually relies on, not every join made in the window round it.
    /// On the roof plan the window round one 13-vertex facet holds 14 000 bridges inside the
    /// sedum hatch next door, and the note used to quote them all (L-73 re-check).
    func bridges(alongCycle cycle: [Int]) -> (count: Int, widest: Double) {
        guard cycle.count >= 2, !bridgeOfEdge.isEmpty else { return (0, 0) }
        var used = Set<Int>()
        var widest = 0.0
        for index in cycle.indices {
            let u = cycle[index]
            let v = cycle[(index + 1) % cycle.count]
            guard let bridge = bridgeOfEdge[Edge(a: Swift.min(u, v), b: Swift.max(u, v))],
                  used.insert(bridge).inserted else { continue }
            widest = Swift.max(widest, bridgeWidths[bridge])
        }
        return (used.count, widest)
    }
}

extension TracePlanarGraph {

    /// Edges hashed into every grid cell their segment passes through (L-73).
    ///
    /// With the cell twice the query reach, an edge that comes within the reach of a point has
    /// its nearest point in the point's cell or one of the eight around it, and that nearest
    /// point lies on the segment, so its cell holds the edge. A long edge costs a cell per
    /// cell-length it runs, not its bounding box's area: a 600 pt diagonal at a 6 pt cell is a
    /// couple of hundred entries.
    fileprivate struct SegmentCellGrid {
        let cell: Double
        private var buckets: [CellKey: [Int]] = [:]
        /// Edges too long to hash cell by cell — only a drawing with absurd coordinates has one —
        /// returned with every query, which is what the linear scan did for all of them.
        private var oversized: [Int] = []
        /// The most cells an edge may run across in either direction before it is oversized.
        private static let maximumSpan = 4_096

        init(cell: Double) {
            self.cell = Swift.max(cell, 1e-9)
        }

        mutating func insert(_ index: Int, from a: PDFPoint, to b: PDFPoint) {
            let minY = Swift.min(a.y, b.y)
            let maxY = Swift.max(a.y, b.y)
            let dy = b.y - a.y
            let firstRow = cellIndex(minY, cell)
            let lastRow = cellIndex(maxY, cell)
            guard lastRow - firstRow <= Self.maximumSpan,
                  cellIndex(Swift.max(a.x, b.x), cell) - cellIndex(Swift.min(a.x, b.x), cell) <= Self.maximumSpan
            else {
                oversized.append(index)
                return
            }
            for row in firstRow...lastRow {
                // The part of the segment inside this row's band, and the columns it spans.
                let low: Double
                let high: Double
                if dy == 0 || firstRow == lastRow {
                    low = Swift.min(a.x, b.x)
                    high = Swift.max(a.x, b.x)
                } else {
                    let bandLow = Swift.max(Double(row) * cell, minY)
                    let bandHigh = Swift.min(Double(row + 1) * cell, maxY)
                    let x0 = a.x + (bandLow - a.y) * (b.x - a.x) / dy
                    let x1 = a.x + (bandHigh - a.y) * (b.x - a.x) / dy
                    low = Swift.max(Swift.min(x0, x1), Swift.min(a.x, b.x))
                    high = Swift.min(Swift.max(x0, x1), Swift.max(a.x, b.x))
                }
                // A hair wider than the computed span, so the rounding of the band crossing can
                // only add a cell, never drop the one the segment's nearest point sits in.
                let slack = cell * 1e-9
                let first = cellIndex(low - slack, cell)
                for column in first...Swift.max(first, cellIndex(high + slack, cell)) {
                    buckets[CellKey(x: column, y: row), default: []].append(index)
                }
            }
        }

        /// Every edge with a cell in the 3 × 3 block round `point`, ascending, each once.
        func candidates(near point: PDFPoint, into result: inout [Int]) {
            result.removeAll(keepingCapacity: true)
            result.append(contentsOf: oversized)
            guard !buckets.isEmpty else { return }
            let column = cellIndex(point.x, cell)
            let row = cellIndex(point.y, cell)
            for dx in -1...1 {
                for dy in -1...1 {
                    if let bucket = buckets[CellKey(x: column + dx, y: row + dy)] {
                        result.append(contentsOf: bucket)
                    }
                }
            }
            guard result.count > 1 else { return }
            result.sort()
            var write = 1
            for read in 1..<result.count where result[read] != result[write - 1] {
                result[write] = result[read]
                write += 1
            }
            result.removeLast(result.count - write)
        }
    }
}
