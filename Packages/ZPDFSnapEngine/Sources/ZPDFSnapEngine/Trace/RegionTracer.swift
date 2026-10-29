import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFVectorExtraction

/// One-click auto-trace: click inside a closed region and get its boundary back.
///
/// # The algorithm, and why this one
///
/// A flood fill on the rendered raster would be easier and would be wrong in the one way that
/// matters: a raster cannot tell a 2 pt join failure from a 25 pt door opening, so it either
/// leaks through both or through neither. This works on the vector geometry instead — the same
/// primitives the snap index is built from — and every decision it makes about a break in the
/// boundary is a measured distance in page points that it can report.
///
/// 1. **Flatten to segments.** Lines, `re` rectangles and closed subpaths become segments;
///    cubics become their flattened polylines, bounded by ``TraceOptions/curveFlatness``. The
///    stored curve is untouched — flattening here is the same indexing convenience
///    `SNAP_CONTRACT` 13.4 permits for hit testing.
/// 2. **Build a planar arrangement** (``TracePlanarGraph``): split every segment at its
///    crossings, snap endpoints within ``TraceOptions/joinTolerance`` into shared nodes, and
///    bridge loose ends that stop within ``TraceOptions/gapTolerance`` of something.
/// 3. **Find the edges.** Cast a ray from the click and take every crossing, nearest first.
///    Each crossing's dart is chosen so the click lies on the dart's left.
/// 4. **Walk the face.** Follow "next dart is the cyclic predecessor of the reversed dart" round
///    the node fans until the walk returns to where it started. That traverses one boundary
///    component of the face on the dart's left, so two rooms sharing a wall return one room
///    each. The click's face may have several components — its outer boundary and every
///    island it wraps around, such as a fixture or a room label drawn as outlines — and the
///    nearest crossing may well be an island's, so the crossings are walked in order until one
///    comes back as a counter-clockwise loop that encloses the click: that is the outer
///    boundary, and everything walked before it was a hole, an open outline, or the inside of
///    an island seen from its far edge (BH-034).
/// 5. **Judge it.** A bounded face comes back counter-clockwise, with positive signed area. The
///    unbounded face — which is what a region with a hole in its wall becomes when there is
///    nothing beyond it, because inside and outside are then the same face — does not, and is
///    refused. A face that *is* bounded is then checked for a wall that stops and resumes on
///    the same line, which is what a door opening onto a corridor looks like whether the walls
///    are strokes with loose ends or closed shapes with end caps; see
///    `brokenWallPair(stops:gapTolerance:isDashedLine:)`. When the break is an opening a person might close
///    — a door — its two sides come back as a ``ProposedClosure`` through
///    ``traceProposingClosures(_:click:maximumClosureWidth:maximumClosures:)``, never inserted
///    until the person accepts it (NL-AUTO-07). A face that closes is measured with the hatch
///    cells that only a bridge closes against its boundary counted as part of it; see
///    `absorbingBridgedCells(_:in:options:)`.
///
/// # Refusal is the feature
///
/// The one thing the tracer must never do is *close a gap it invented*: a traced area that
/// quietly included the corridor is the worst number this product can produce. So a break wider than
/// ``TraceOptions/gapTolerance`` is never bridged, and a face whose boundary is broken is
/// refused even when a larger closed loop does exist round it. The walk comes back
/// ``TraceResult/notClosed(gapAt:)`` pointing at the middle of the break, and a bridge that
/// *was* used is reported in ``TracedRegion/largestBridgedGap`` rather than hidden.
///
/// # Working window
///
/// A sheet can hold hundreds of thousands of segments and a room is a few dozen of them, so the
/// arrangement is built inside a square window around the click that doubles until the whole
/// traced ring — or the break the walk refused at — sits strictly inside it with a margin wider
/// than ``TraceOptions/gapTolerance``. Nothing outside such a window can reach into the ring:
/// any segment that crossed it, or came within bridging distance of it, would have intersected
/// the window and been included. The last growth uses the whole page.
public enum RegionTracer {

    /// Follows the smallest closed boundary enclosing `click`.
    ///
    /// - Parameters:
    ///   - primitives: the page's vector geometry, as extracted — the same input the snap index
    ///     is built from.
    ///   - click: a point in canonical PDF page space (origin bottom-left, 72 per inch).
    ///   - options: tolerances and limits. The defaults are the numbers the interface quotes.
    /// - Returns: the ring, or a refusal that names why. Never throws: an unusable page is a
    ///   ``TraceResult/tooComplex(count:)`` and an unusable click is a
    ///   ``TraceResult/notClosed(gapAt:)``.
    public static func trace(
        primitives: [VectorPrimitive],
        click: PDFPoint,
        options: TraceOptions = .standard
    ) -> TraceResult {
        // One click: no tree. Bulk-loading one costs more than the linear scans it saves on
        // a single trace; it pays for itself from the second click on a prepared page.
        trace(prepare(primitives: primitives, options: options, indexed: false), click: click)
    }

    /// The page's segments, flattened, ordered and spatially indexed once, for any number of
    /// clicks on the same page under the same options.
    ///
    /// Every call to ``trace(primitives:click:options:)`` used to flatten every primitive on
    /// the page, scan every segment for the nearest distance and filter every segment again on
    /// each window growth (IM-094). A caller that keeps this value — per page and extraction,
    /// beside the snap layer — pays for the collection once; each click then costs in
    /// proportion to its working window.
    public static func prepare(
        primitives: [VectorPrimitive],
        options: TraceOptions = .standard
    ) -> PreparedTrace {
        prepare(primitives: primitives, options: options, indexed: true)
    }

    /// Prepares the page after leaving out what `filter` excludes — hidden layers, and the
    /// trace choices the person made (NL-AUTO-01, NL-AUTO-11). The filter is applied before
    /// collection, so an excluded primitive can neither split nor close a region.
    public static func prepare(
        primitives: [VectorPrimitive],
        options: TraceOptions = .standard,
        filter: TraceFilter
    ) -> PreparedTrace {
        let prepared = prepare(primitives: filter.apply(to: primitives), options: options, indexed: true)
        return prepared.with(filter: filter)
    }

    static func prepare(
        primitives: [VectorPrimitive],
        options: TraceOptions,
        indexed: Bool
    ) -> PreparedTrace {
        switch TraceSegmentCollector.collect(primitives: primitives, options: options) {
        case .overflow(let count):
            return PreparedTrace(options: options, segments: [], tree: nil, pageBounds: nil, overflow: count)
        case .collected(let segments):
            guard let first = segments.first else {
                return PreparedTrace(options: options, segments: [], tree: nil, pageBounds: nil, overflow: nil)
            }
            var bounds = first.bounds
            for segment in segments { bounds = bounds.union(segment.bounds) }
            // The tree's only failure is a non-finite box, and the collector drops non-finite
            // points; without a tree the page is scanned linearly, as it always was.
            let tree = indexed ? try? PackedRTree(boxes: segments.map(\.bounds)) : nil
            return PreparedTrace(options: options, segments: segments, tree: tree, pageBounds: bounds, overflow: nil)
        }
    }

    /// Follows the smallest closed boundary enclosing `click` on a prepared page.
    public static func trace(_ prepared: PreparedTrace, click: PDFPoint) -> TraceResult {
        traceDetailed(prepared, click: click).result
    }

    /// The trace, together with the one opening the walk refused at when it could name both
    /// of its sides — the evidence ``traceProposingClosures(_:click:maximumClosureWidth:maximumClosures:)``
    /// turns into a proposal.
    static func traceDetailed(_ prepared: PreparedTrace, click: PDFPoint) -> (result: TraceResult, opening: ProposedClosure?) {
        guard click.isFinite else { return (.notClosed(gapAt: nil), nil) }
        if let count = prepared.overflow { return (.tooComplex(count: count), nil) }
        guard let pageBounds = prepared.pageBounds, !prepared.segments.isEmpty else {
            return (.notClosed(gapAt: nil), nil)
        }
        let options = prepared.options
        let segments = prepared.segments

        let nearest = prepared.nearestDistance(to: click)

        // Wide enough that a segment excluded from the window cannot bridge to, or cross,
        // anything inside the inner window.
        let margin = Swift.max(options.gapTolerance, options.joinTolerance) * 4 + 1
        var side = Swift.max(options.initialWindowSide, nearest * 4 + margin * 4)

        for growth in 0...options.maximumWindowGrowths {
            let window = PDFRect(
                x: click.x - side / 2,
                y: click.y - side / 2,
                width: side,
                height: side
            )
            let inner = window.insetBy(-margin)
            let isFinalPass =
                growth == options.maximumWindowGrowths
                || inner.contains(pageBounds)

            let subset: [TraceSegment]
            if isFinalPass {
                subset = segments + prepared.closureSegments
            } else {
                subset = prepared.segments(intersecting: window)
            }

            switch attempt(segments: subset, click: click, prepared: prepared) {
            case .tooComplex(let count):
                return (.tooComplex(count: count), nil)

            case .traced(let region, let walkBounds):
                if isFinalPass || inner.contains(walkBounds) { return (.traced(region), nil) }

            case .notClosed(let gap, let walkBounds, let opening):
                if isFinalPass { return (.notClosed(gapAt: gap), opening) }
                if let walkBounds, inner.contains(walkBounds) { return (.notClosed(gapAt: gap), opening) }
            }

            side *= 2
        }

        return (.notClosed(gapAt: nil), nil)
    }

    // MARK: - One window

    /// The result of one window, with the extent the walk actually touched so the caller can
    /// tell whether the window was big enough to trust the answer.
    private enum Attempt {
        case traced(TracedRegion, walkBounds: PDFRect)
        case notClosed(gapAt: PDFPoint?, walkBounds: PDFRect?, opening: ProposedClosure?)
        case tooComplex(count: Int)
    }

    private static func attempt(
        segments: [TraceSegment],
        click: PDFPoint,
        prepared: PreparedTrace
    ) -> Attempt {
        let options = prepared.options
        guard !segments.isEmpty else { return .notClosed(gapAt: nil, walkBounds: nil, opening: nil) }

        let graph: TracePlanarGraph
        switch TracePlanarGraph.build(segments: segments, options: options) {
        case .tooComplex(let count): return .tooComplex(count: count)
        case .built(let built): graph = built
        }
        guard !graph.edges.isEmpty else { return .notClosed(gapAt: nil, walkBounds: nil, opening: nil) }

        guard let crossings = rayCrossings(in: graph, from: click) else {
            // Every ray runs through a node or along an edge: nothing can be said from here.
            return .notClosed(gapAt: nil, walkBounds: nil, opening: nil)
        }
        // An empty list is a clean ray that crossed nothing: the click is outside everything
        // the window holds.

        // The click's face can have several boundary components: its outer boundary and, inside
        // it, every island the face wraps around — a fixture, a column, a room label drawn as
        // outlines. The ray meets whichever is first, and a walk from an island's edge goes
        // round the island, not round the room (BH-034). So every crossing along the ray is
        // tried in order, and the first walk that is a counter-clockwise loop *enclosing* the
        // click is the face's outer boundary: a hole component is traversed clockwise, an open
        // component out and back, and another face's outer boundary (an island's interior,
        // entered from its far edge) does not enclose the click. Nothing else can come first,
        // because the ray must cross the outer boundary of the click's face before it can reach
        // the outer boundary of any face that surrounds it.
        var steps = 0
        var refusal: (gap: PDFPoint?, bounds: PDFRect?, rank: Int, opening: ProposedClosure?)?
        let dashes = DashedLineProbe(prepared: prepared)

        for crossing in crossings {
            let walk: Walk
            switch walkFace(from: crossing.dart, in: graph, options: options, steps: &steps) {
            case .tooComplex(let count): return .tooComplex(count: count)
            case .walked(let value): walk = value
            }

            let walkPoints = walk.nodes.map { graph.points[$0] }
            let walkBounds = PDFRect.boundingBox(of: walkPoints)
                ?? PDFRect(corner: click, opposite: click)
            // A bounded face is traversed counter-clockwise and has positive signed area. The
            // unbounded face is traversed clockwise; a face whose boundary is an open polyline —
            // exactly what a wall with a hole in it produces, because inside and outside have
            // become one face — is traversed once in each direction and has signed area zero.
            // Neither is a region, and neither may be bridged into one.
            let signed = PolygonMath.signedArea(walkPoints)
            let floor = areaFloor(of: walkBounds)
            let encloses = Self.encloses(walkPoints, click)

            if signed > floor {
                // The interior of an island, seen from its far edge: not the click's face.
                guard encloses else { continue }
                return judge(walk, bounds: walkBounds, in: graph, click: click, options: options, dashes: dashes)
            }

            // Not a region. Its loose ends and jambs are still the best hint there is when
            // nothing else encloses the click, and the walk decides whether the window can be
            // trusted: an open boundary that stretches round the click, or a closed network
            // the click is enclosed by and still connected to the outside of, is a genuine
            // break; an island or a stray outline beside the click says nothing about what may
            // enclose it further out, so the window grows instead.
            let ring = collapseSpurs(walk.nodes).map { graph.points[$0] }
            let stops = Self.stops(
                deadEnds: walk.deadEnds,
                ring: signed < -floor ? Array(ring.reversed()) : [],
                in: graph
            )
            let gap = gapLocation(stops: stops, from: click)
            let trusted = (signed < -floor && encloses)
                || (!walk.deadEnds.isEmpty && walkBounds.contains(click))
            let rank = trusted ? 2 : (gap != nil ? 1 : 0)
            if refusal == nil || rank > (refusal?.rank ?? 0) {
                // The opening is evidence only when the walk that produced it can be trusted:
                // a pair of stops on a stray outline beside the click proves nothing about
                // what encloses it.
                let opening = trusted
                    ? brokenWallPair(stops: stops, gapTolerance: options.gapTolerance, isDashedLine: dashes.isDashedLine)
                        .map { closure(across: $0, click: click) }
                    : nil
                refusal = (gap, trusted ? walkBounds : nil, rank, opening)
            }
        }

        return .notClosed(gapAt: refusal?.gap, walkBounds: refusal?.bounds, opening: refusal?.opening)
    }

    // MARK: - One face

    /// What a click inside one bounded face of `graph` gets, judged from a walk of the face's
    /// outer boundary that the caller made — the room detector's way of reading every face of a
    /// sheet from one arrangement instead of tracing each from scratch (L-73b). `nodes` and
    /// `deadEnds` are exactly what the trace's own walk records: the walk's nodes in order, and
    /// the degree-one nodes it turned round at, each once, in walk order. `seed` stands for the
    /// click: a point inside the face, which only decides which wall face a proposed closure
    /// runs along.
    static func judgeFace(
        nodes: [Int],
        deadEnds: [Int],
        in graph: TracePlanarGraph,
        seed: PDFPoint,
        options: TraceOptions,
        dashes: DashedLineProbe
    ) -> FaceJudgement {
        let points = nodes.map { graph.points[$0] }
        guard let bounds = PDFRect.boundingBox(of: points) else { return .refused(opening: nil) }
        let walk = Walk(nodes: nodes, deadEnds: deadEnds)
        switch judge(walk, bounds: bounds, in: graph, click: seed, options: options, dashes: dashes) {
        case .traced(let region, _): return .traced(region)
        case .notClosed(_, _, let opening): return .refused(opening: opening)
        case .tooComplex: return .refused(opening: nil)
        }
    }

    /// What ``judgeFace(nodes:deadEnds:in:seed:options:dashes:)`` found.
    enum FaceJudgement {
        /// The face closes: the region a click inside it gets.
        case traced(TracedRegion)
        /// Refused; `opening` is the break the refusal names when it could name both sides.
        case refused(opening: ProposedClosure?)
    }

    private struct Walk {
        var nodes: [Int]
        /// Degree-one nodes the walk turned around at, in walk order, each once.
        var deadEnds: [Int]
    }

    private enum WalkOutcome {
        case walked(Walk)
        case tooComplex(count: Int)
    }

    /// Follows the face on the left of `start` until the walk returns to it. `steps` is shared
    /// across the walks of one window, so the work cap is a cap on the window.
    private static func walkFace(
        from start: Int,
        in graph: TracePlanarGraph,
        options: TraceOptions,
        steps: inout Int
    ) -> WalkOutcome {
        var nodes: [Int] = []
        var deadEnds: [Int] = []
        var seenDeadEnd = Set<Int>()
        var dart = start
        repeat {
            nodes.append(graph.from(dart))
            if nodes.count > options.maximumRingVertices {
                return .tooComplex(count: nodes.count)
            }
            let head = graph.to(dart)
            if graph.degree(of: head) == 1, seenDeadEnd.insert(head).inserted {
                deadEnds.append(head)
            }
            dart = graph.next(after: dart)
            steps += 1
            if steps > options.maximumWalkSteps { return .tooComplex(count: steps) }
        } while dart != start
        return .walked(Walk(nodes: nodes, deadEnds: deadEnds))
    }

    /// Turns the accepted outer boundary into a region, or refuses it at an opening.
    private static func judge(
        _ walk: Walk,
        bounds walkBounds: PDFRect,
        in graph: TracePlanarGraph,
        click: PDFPoint,
        options: TraceOptions,
        dashes: DashedLineProbe
    ) -> Attempt {
        let collapsed = collapseSpurs(walk.nodes).map { graph.points[$0] }
        // Simplified for the jamb analysis whatever the output option says: a cap crossed by a
        // dimension line has a node in its middle, and the two turns must be read across it.
        let simplified = dropCollinear(collapsed, tolerance: options.collinearTolerance)

        // A bounded face is not automatically a region. A room with a door opening onto a
        // corridor has no broken loop at all — the smallest closed loop round the click is the
        // room *and* the corridor, and returning its area would be the worst number this
        // product can produce. The opening shows up as two wall ends on the face pointing at
        // each other, so that is what is looked for.
        let stops = Self.stops(deadEnds: walk.deadEnds, ring: simplified, in: graph)
        if let pair = brokenWallPair(stops: stops, gapTolerance: options.gapTolerance, isDashedLine: dashes.isDashedLine) {
            let middle = PDFPoint(x: (pair.0.point.x + pair.1.point.x) / 2, y: (pair.0.point.y + pair.1.point.y) / 2)
            return .notClosed(gapAt: middle, walkBounds: walkBounds, opening: closure(across: pair, click: click))
        }

        // The face is closed. Hatch cells that only a bridge closed against its boundary are
        // part of it, not holes in it: the ring is read from the face with them absorbed. The
        // opening test above stays on the face as walked, so what counts as a door is unchanged.
        let nodes = absorbingBridgedCells(walk.nodes, in: graph, options: options)
        let collapsedRing: [PDFPoint]
        let simplifiedRing: [PDFPoint]
        if nodes == walk.nodes {
            collapsedRing = collapsed
            simplifiedRing = simplified
        } else {
            collapsedRing = collapseSpurs(nodes).map { graph.points[$0] }
            simplifiedRing = dropCollinear(collapsedRing, tolerance: options.collinearTolerance)
        }

        // A closed shape tied to the boundary by one line — the roof plan's snow guard, joined to
        // the eave by an axis dash — or touching it at one point is walked as part of the face's
        // boundary, clockwise, and the shoelace over the whole walk deducted it without a word.
        // A shape inside a room is a proposal, never a deduction (NL-AUTO-10), whether it stands
        // free or is tied: the ring is the walk's outer cycle alone, and every tied shape is
        // offered as an island (L-73 re-check).
        let ring: [PDFPoint]
        let outerNodes: [Int]
        let tied: [[PDFPoint]]
        if let rings = faceRings(nodes, in: graph, click: click, floor: areaFloor(of: walkBounds)) {
            let outer = rings.outer.map { graph.points[$0] }
            ring = canonicalise(
                options.simplifiesCollinearVertices ? dropCollinear(outer, tolerance: options.collinearTolerance) : outer
            )
            outerNodes = rings.outer
            // Seen from the room a tied shape is walked clockwise; islands are counter-clockwise.
            tied = rings.tied.map { Array($0.map { graph.points[$0] }.reversed()) }
        } else {
            ring = canonicalise(options.simplifiesCollinearVertices ? simplifiedRing : collapsedRing)
            outerNodes = collapseSpurs(nodes)
            tied = []
        }
        guard ring.count >= 3 else {
            return .notClosed(gapAt: gapLocation(stops: stops, from: click), walkBounds: walkBounds, opening: nil)
        }

        let area = PolygonMath.area(ring)
        let joins = graph.bridges(alongCycle: outerNodes)
        let region = TracedRegion(
            ring: ring,
            area: area,
            perimeter: SegmentMath.polylineLength(ring, isClosed: true),
            bridgedGapCount: joins.count,
            largestBridgedGap: joins.widest,
            islands: islands(inside: ring, area: area, walked: nodes, tied: tied, in: graph, options: options)
        )
        return .traced(region, walkBounds: walkBounds)
    }

    // MARK: - Hatch cells closed by a bridge

    /// The largest cell absorbed, as a share of the face's area: the island floor, under which a
    /// closed outline inside a room is a letter, a symbol or a hatch mark and is never offered.
    static let absorbedCellShare = islandAreaShare
    /// The longest walk round a cell before it counts as no cell: a hatch mark is a handful of
    /// strokes and bridges.
    static let maximumCellSteps = 256

    /// The face's outer walk with the hatch cells that only a bridge closes against it absorbed,
    /// or `nodes` unchanged when it has none.
    ///
    /// A hatch drawn across a face's boundary leaves short strokes with loose ends beside the
    /// line, and bridging joins those ends to the line and to each other: on the synthetic roof
    /// plan with its hatch drawn across both hips, each glyph's tips are bridged into a cell a
    /// few square points large against the hip. Read as part of the boundary, every such cell
    /// was cut out of the face, and the sedum faces came back up to 0.14 % short. A bridge is
    /// geometry the engine added to close a gap of at most ``TraceOptions/gapTolerance``, not a
    /// line anybody drew, so a cell that exists only because of one is not a hole: when the face
    /// on the far side of a bridge on the walk is bounded, distinct from this face and no larger
    /// than ``absorbedCellShare`` of it, the bridge is taken out and the cell joins the face.
    /// Cells reached through an absorbed cell are tested in turn.
    ///
    /// What stays cut out: anything closed by drawn lines alone, however small — a pilaster, a
    /// closed symbol touching the wall; and anything behind a bridge that is larger than the
    /// island floor — a room next door joined through a closed wall gap is never absorbed.
    /// Doors are decided before this, on the face as walked, so no opening is gained or lost.
    static func absorbingBridgedCells(
        _ nodes: [Int],
        in graph: TracePlanarGraph,
        options: TraceOptions
    ) -> [Int] {
        guard !graph.bridgeOfEdge.isEmpty, nodes.count >= 3 else { return nodes }
        var darts: [Int] = []
        darts.reserveCapacity(nodes.count)
        for index in nodes.indices {
            guard let dart = graph.dart(from: nodes[index], to: nodes[(index + 1) % nodes.count]) else {
                return nodes
            }
            darts.append(dart)
        }
        let faceArea = PolygonMath.signedArea(collapseSpurs(nodes).map { graph.points[$0] })
        guard faceArea > 0 else { return nodes }
        let cellCap = faceArea * absorbedCellShare
        let isBridge: (Int) -> Bool = { dart in
            let edge = graph.edges[dart >> 1]
            return graph.bridgeOfEdge[edge] != nil
        }
        guard darts.contains(where: isBridge) else { return nodes }

        var ignored = Set<Int>()
        // Each pass absorbs the cells behind the bridges now on the walk; a cell's own bridges
        // reach the walk once it is absorbed. Bounded by the bridges there are.
        for _ in 0..<Swift.max(1, graph.bridgeWidths.count) {
            let onWalk = Set(darts)
            var absorbed = false
            for dart in darts where isBridge(dart) && !ignored.contains(dart >> 1) {
                // The face on the far side, walked with what is absorbed so far taken out.
                var cell: [Int] = []
                var current = graph.reverse(dart)
                var closed = false
                var foreign = true
                for _ in 0..<maximumCellSteps {
                    if onWalk.contains(current) { foreign = false; break }
                    cell.append(graph.from(current))
                    current = graph.next(after: current, ignoring: ignored)
                    if current == graph.reverse(dart) { closed = true; break }
                }
                guard closed, foreign else { continue }
                let area = PolygonMath.signedArea(collapseSpurs(cell).map { graph.points[$0] })
                guard area > 0, area <= cellCap else { continue }
                ignored.insert(dart >> 1)
                absorbed = true
            }
            guard absorbed else { break }
            // The face with those cells absorbed, walked from any dart of it still standing.
            guard let start = darts.first(where: { !ignored.contains($0 >> 1) }) else { return nodes }
            var walked: [Int] = []
            var current = start
            repeat {
                walked.append(current)
                current = graph.next(after: current, ignoring: ignored)
                if walked.count > options.maximumRingVertices { return nodes }
            } while current != start
            darts = walked
        }
        return darts.map { graph.from($0) }
    }

    // MARK: - Shapes tied to the boundary (L-73 re-check)

    /// The walk's outer cycle and the closed shapes tied to it, when the walk has any: `nil`
    /// when it is one simple cycle once its spurs are gone, or when it does not split into an
    /// outer cycle round the click.
    ///
    /// The outer boundary of a face is one closed walk. A shape joined to it by a line is walked
    /// out along the line, round the shape clockwise, and back; a shape touching it at a node is
    /// walked round from that node. Cut at every node the walk revisits, the walk falls apart
    /// into the outer cycle (counter-clockwise, round the click), one clockwise cycle per tied
    /// shape, and the spurs and joining lines, which enclose nothing. The outer cycle is the
    /// largest counter-clockwise one, so a sliver cycle — a few millionths of a square point were
    /// seen along the roof plan's sedum outline — can never stand in for it.
    private static func faceRings(
        _ nodes: [Int],
        in graph: TracePlanarGraph,
        click: PDFPoint,
        floor: Double
    ) -> (outer: [Int], tied: [[Int]])? {
        let cycles = simpleCycles(of: nodes)
        guard cycles.count > 1 else { return nil }
        var outer: (nodes: [Int], area: Double)?
        var tied: [[Int]] = []
        for cycle in cycles {
            let signed = PolygonMath.signedArea(cycle.map { graph.points[$0] })
            if signed > floor {
                if signed > (outer?.area ?? 0) { outer = (cycle, signed) }
            } else if signed < -floor {
                tied.append(cycle)
            }
        }
        guard let outer, encloses(outer.nodes.map { graph.points[$0] }, click) else { return nil }
        return (outer.nodes, tied)
    }

    /// The closed walk `nodes` cut into simple cycles at every node it revisits, each cycle of at
    /// least three nodes in walk order. What is walked out and back — a spur, a joining line —
    /// leaves only two-node pieces, which are dropped. Whichever node the walk starts at, the
    /// same cycles come back, each rotated.
    static func simpleCycles(of nodes: [Int]) -> [[Int]] {
        var stack: [Int] = []
        var position: [Int: Int] = [:]
        var cycles: [[Int]] = []
        for node in nodes {
            guard let index = position[node] else {
                position[node] = stack.count
                stack.append(node)
                continue
            }
            let loop = Array(stack[(index + 1)...])
            if loop.count >= 2 { cycles.append([node] + loop) }
            for dropped in loop { position[dropped] = nil }
            stack.removeLast(loop.count)
        }
        if stack.count >= 3 { cycles.append(stack) }
        return cycles
    }

    // MARK: - Islands inside the room (NL-AUTO-10)

    /// The smallest island offered, as a share of the room's area. Letters and symbols drawn as
    /// closed outlines sit far below it; a column in a room sits far above.
    static let islandAreaShare = 0.001
    /// The most islands one trace offers, largest first.
    static let maximumIslands = 8

    /// Every closed outline inside `ring` that is a hole of the room's own face — standing free
    /// (walked clockwise from outside, enclosed by the ring) or `tied` to the boundary (see
    /// `faceRings`) — that is not enclosed by another island and is above the area floor.
    /// Counter-clockwise on return, largest first.
    private static func islands(
        inside ring: [PDFPoint],
        area: Double,
        walked: [Int],
        tied: [[PDFPoint]],
        in graph: TracePlanarGraph,
        options: TraceOptions
    ) -> [[PDFPoint]] {
        guard ring.count >= 3, area > 0 else { return [] }
        let onRing = Set(walked)
        let floor = Swift.max(area * islandAreaShare, 1e-9)
        var visited = Set<Int>()
        var steps = 0
        // Tied shapes are known exactly from the walk; the search below adds the free ones.
        let tiedFound = tied.compactMap { shape -> (ring: [PDFPoint], area: Double)? in
            let shapeArea = PolygonMath.area(shape)
            return shapeArea >= floor ? (shape, shapeArea) : nil
        }
        var found = tiedFound
        // Every interior edge is tested for containment, and a scan of the whole ring per edge
        // was 40 000 edges × 3 200 vertices on a real roof plan's sedum face — thirteen seconds
        // of a single ⌥-click (L-73). The banded index gives the same answer from the ring
        // edges that cross the point's height only.
        let containment = RingContainment(ring)
        let ringVertices = Set(ring)
        guard let ringBounds = PDFRect.boundingBox(of: ring) else { return [] }
        edgeSearch: for (index, edge) in graph.edges.enumerated() {
            let a = graph.points[edge.a], b = graph.points[edge.b]
            let middle = PDFPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            // Outside the ring's box is outside the ring: the room detector judges every face
            // of a sheet against the whole sheet's edges.
            guard middle.x >= ringBounds.minX, middle.x <= ringBounds.maxX,
                  middle.y >= ringBounds.minY, middle.y <= ringBounds.maxY else { continue }
            // Only edges of the room's interior: both ends off the ring and inside it.
            guard !onRing.contains(edge.a), !onRing.contains(edge.b) else { continue }
            guard containment.encloses(middle) else { continue }
            for dart in [index * 2, index * 2 + 1] where !visited.contains(dart) {
                var nodes: [Int] = []
                var current = dart
                var complete = true
                repeat {
                    visited.insert(current)
                    nodes.append(graph.from(current))
                    current = graph.next(after: current)
                    steps += 1
                    if steps > options.maximumWalkSteps || nodes.count > options.maximumRingVertices {
                        complete = false
                        break
                    }
                } while current != dart
                // Over the work cap: no free island is offered rather than a partial list.
                guard complete else {
                    found = tiedFound
                    break edgeSearch
                }
                let points = collapseSpurs(nodes).map { graph.points[$0] }
                let signed = PolygonMath.signedArea(points)
                // Seen from the room, an island's outline is walked clockwise.
                guard signed < -floor, points.allSatisfy({ containment.encloses($0) || ringVertices.contains($0) }) else { continue }
                found.append((Array(points.reversed()), -signed))
            }
        }
        // An outline inside another island belongs to that island's face, not the room's.
        let outermost = found.filter { candidate in
            !found.contains { other in
                other.area > candidate.area && candidate.ring.allSatisfy { encloses(other.ring, $0) }
            }
        }
        return outermost
            .sorted { $0.area > $1.area }
            .prefix(maximumIslands)
            .map { canonicalise(dropCollinear($0.ring, tolerance: options.collinearTolerance)) }
    }

    // MARK: - A wall that stops and resumes

    /// A place where a wall on the face stops: a loose end, or a jamb.
    struct Stop {
        let point: PDFPoint
        /// Unit direction the wall was travelling when it stopped here.
        let heading: (x: Double, y: Double)
        /// `true` for the end cap of a wall drawn as a closed shape, `false` for a stroke's
        /// degree-one end.
        let isJamb: Bool
        /// A jamb's two cap corners — the two faces of the wall where it stops. `nil` for a
        /// loose end, which is its own corner.
        var corners: (PDFPoint, PDFPoint)? = nil
    }

    /// Every stop on a walked face: the loose ends the walk turned around at, plus the jambs
    /// of `ring` (see `jambs(of:)`), capped for the sake of a sheet of stroked text.
    private static func stops(
        deadEnds: [Int],
        ring: [PDFPoint],
        in graph: TracePlanarGraph
    ) -> [Stop] {
        let limit = 512
        var result: [Stop] = []
        for node in deadEnds.prefix(limit) {
            // The direction the stroke was travelling when it stopped at this end.
            guard let dart = graph.adjacency[node].first else { continue }
            let neighbour = graph.points[graph.to(dart)]
            let here = graph.points[node]
            let dx = here.x - neighbour.x
            let dy = here.y - neighbour.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { continue }
            result.append(Stop(point: here, heading: (dx / length, dy / length), isJamb: false))
        }
        if result.count < limit {
            result.append(contentsOf: jambs(of: ring).prefix(limit - result.count))
        }
        return result
    }

    /// The end caps of walls drawn as closed shapes, read off a counter-clockwise ring.
    ///
    /// A wall drawn as a `re` rectangle or a filled polygon has no loose end: where it stops
    /// at a door, the face turns into the wall's thickness, runs across the cap and turns back
    /// along the wall's other side. On a counter-clockwise ring that is an edge whose two
    /// vertices are both reflex (right) turns and whose neighbouring edges run antiparallel —
    /// the same signature a pilaster's outer face has, which is why a jamb on its own means
    /// nothing and only a pair aimed at each other across an opening is ever reported
    /// (BH-035). The stop sits at the cap's midpoint and heads the way the wall was going.
    static func jambs(of ring: [PDFPoint]) -> [Stop] {
        let count = ring.count
        guard count >= 4 else { return [] }
        func unit(_ from: PDFPoint, _ to: PDFPoint) -> (x: Double, y: Double)? {
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return nil }
            return (dx / length, dy / length)
        }
        func isReflex(_ incoming: (x: Double, y: Double), _ outgoing: (x: Double, y: Double)) -> Bool {
            incoming.x * outgoing.y - incoming.y * outgoing.x < -1e-9
        }

        var result: [Stop] = []
        for i in 0..<count {
            let a = ring[(i + count - 1) % count]
            let b = ring[i]
            let c = ring[(i + 1) % count]
            let d = ring[(i + 2) % count]
            guard let ab = unit(a, b), let bc = unit(b, c), let cd = unit(c, d) else { continue }
            guard isReflex(ab, bc), isReflex(bc, cd) else { continue }
            // The two sides of one wall: antiparallel to within about three degrees.
            let dot = ab.x * cd.x + ab.y * cd.y
            let cross = ab.x * cd.y - ab.y * cd.x
            guard dot < 0, Swift.abs(cross) <= 0.05 else { continue }
            result.append(
                Stop(
                    point: PDFPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2),
                    heading: ab,
                    isJamb: true,
                    corners: (b, c)
                )
            )
        }
        return result
    }

    /// The middle of a break in a wall that lies on an otherwise closed face, or `nil` when the
    /// face's boundary is whole.
    ///
    /// # The case this exists for
    ///
    /// Trace a room whose door opens onto a corridor and there is no unbounded face to catch:
    /// the room and the corridor are one closed loop, and its area is a real number that is not
    /// the room. Topologically the two wall ends beside the door are indistinguishable from a
    /// dimension line poking into the room — both are strokes the walk goes out along and comes
    /// back down. Only the geometry separates them, so the geometry is what is tested:
    ///
    /// **two ends of the same broken line.** Each stop is where a wall stopped; extend each
    /// along the direction its wall was heading, and if each ray passes within
    /// ``TraceOptions/gapTolerance`` of the other stop, they are one wall with a hole in it.
    /// A dimension line reaching into a room fails that test in both directions.
    ///
    /// Two loose ends at or under the tolerance were bridgeable, and whether they were bridged
    /// is the arrangement's business, not this test's. Two jambs are never bridged — there is
    /// no loose end to bridge — so an opening between capped walls is refused at any width.
    ///
    /// # What it costs
    ///
    /// Two halves of a dimension line separated by the space its number is printed in *do* aim
    /// at each other, and a room whose boundary they are attached to is refused. That is a
    /// refusal naming a point on the drawing, not a wrong area, and of those two only the
    /// refusal is acceptable. Measuring on one layer is the real answer to that drawing. Two pilasters facing each other across a room, aligned
    /// to within the tolerance, are refused for the same reason.
    ///
    /// Two loose ends with a dashed line's own dashes between them are not a broken wall — see
    /// ``DashedLineProbe`` (L-73).
    private static func brokenWallPair(
        stops: [Stop],
        gapTolerance: Double,
        isDashedLine: (Stop, Stop) -> Bool
    ) -> (Stop, Stop)? {
        guard stops.count > 1 else { return nil }

        /// Distance from `target` to the ray leaving `origin` along `direction`.
        func rayDistance(
            from origin: PDFPoint,
            along direction: (x: Double, y: Double),
            to target: PDFPoint
        ) -> Double {
            let dx = target.x - origin.x
            let dy = target.y - origin.y
            let along = dx * direction.x + dy * direction.y
            guard along > 0 else { return (dx * dx + dy * dy).squareRoot() }
            let offX = dx - along * direction.x
            let offY = dy - along * direction.y
            return (offX * offX + offY * offY).squareRoot()
        }

        var bestSeparation = Double.infinity
        var best: (Stop, Stop)?

        for outer in stops.indices {
            let a = stops[outer]
            for inner in (outer + 1)..<stops.count {
                let b = stops[inner]
                let separation = a.point.distance(to: b.point)
                guard separation < bestSeparation else { continue }
                guard separation > gapTolerance || (a.isJamb && b.isJamb) else { continue }
                guard rayDistance(from: a.point, along: a.heading, to: b.point) <= gapTolerance else { continue }
                guard rayDistance(from: b.point, along: b.heading, to: a.point) <= gapTolerance else { continue }
                guard !isDashedLine(a, b) else { continue }
                bestSeparation = separation
                best = (a, b)
            }
        }

        return best
    }

    /// The segment that would close the opening between two stops aimed at each other, on the
    /// wall face that looks at the click (NL-AUTO-07).
    ///
    /// Two loose ends are joined end to end: they are the wall line. A jamb stands for a wall
    /// with thickness, so the closure runs corner to corner along one face — the face on the
    /// click's side of the wall axis, which for a click inside a room is the room face, so the
    /// closed area stops at the wall line a person would close it at by hand. Every endpoint is
    /// a node the drawing already has; nothing is invented but the segment itself, and that
    /// only when a person accepts it.
    static func closure(across pair: (Stop, Stop), click: PDFPoint) -> ProposedClosure {
        let (a, b) = pair
        let axisOrigin = a.point
        let axis = a.heading
        func side(_ p: PDFPoint) -> Double {
            axis.x * (p.y - axisOrigin.y) - axis.y * (p.x - axisOrigin.x)
        }
        let clickSide = side(click)
        func corner(of stop: Stop) -> PDFPoint {
            guard let (c1, c2) = stop.corners else { return stop.point }
            let s1 = side(c1)
            let s2 = side(c2)
            // The corner on the click's side; with the click on the axis, the lower of the two
            // in a total order, so the answer is still a function of the geometry.
            if (s1 > 0) != (s2 > 0) {
                return (s1 > 0) == (clickSide > 0) ? c1 : c2
            }
            return Swift.abs(s1) >= Swift.abs(s2) ? c1 : c2
        }
        let start = corner(of: a)
        let end = corner(of: b)
        // Canonical direction, so a closure found from either end of the opening is one value.
        if start.x < end.x || (start.x == end.x && start.y <= end.y) {
            return ProposedClosure(start: start, end: end)
        }
        return ProposedClosure(start: end, end: start)
    }

    // MARK: - Where the boundary gives up

    /// The middle of the narrowest break among the stops the walk ran into, or the single stop
    /// when there is only one, or `nil` when the walk met none — the click is simply outside a
    /// boundary that is perfectly closed.
    private static func gapLocation(stops: [Stop], from click: PDFPoint) -> PDFPoint? {
        guard let first = stops.first else { return nil }
        guard stops.count > 1 else { return first.point }

        // Pairwise, capped: a sheet of stroked text can produce a great many stops and the
        // answer is a hint either way.
        let limit = 512
        let considered = stops.count <= limit
            ? stops
            : Array(
                stops.sorted { $0.point.distance(to: click) < $1.point.distance(to: click) }
                    .prefix(limit)
            )

        var bestDistance = Double.infinity
        var bestPoint = first.point
        for outer in considered.indices {
            for inner in (outer + 1)..<considered.count {
                let a = considered[outer].point
                let b = considered[inner].point
                let distance = a.distance(to: b)
                if distance < bestDistance {
                    bestDistance = distance
                    bestPoint = PDFPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                }
            }
        }
        return bestPoint
    }

    // MARK: - Finding the first edge

    /// Deliberately unremarkable directions: no axis, no 45°, no 30°, so a drawing full of
    /// orthogonal walls and hatching does not land on a degenerate ray on the first try. Tried
    /// in order, and the answer does not depend on which one succeeded — the ring is
    /// canonicalised afterwards.
    private static let rayAngles: [Double] = [
        0.1234567, 0.7654321, 1.3210987, 1.9876543,
        2.5432109, 3.1097654, 3.7654321, 4.3210987,
        4.8765432, 5.4321098, 5.9876543, 0.4567891
    ]

    /// Every edge a ray from `click` crosses, nearest first, each as the dart whose left side
    /// the click is on. `nil` when every ray is degenerate; empty when a clean ray crossed
    /// nothing.
    private static func rayCrossings(
        in graph: TracePlanarGraph, from click: PDFPoint
    ) -> [(t: Double, dart: Int)]? {
        for angle in rayAngles {
            let wx = cos(angle)
            let wy = sin(angle)

            var crossings: [(t: Double, dart: Int)] = []
            var degenerate = false

            for (index, edge) in graph.edges.enumerated() {
                let a = graph.points[edge.a]
                let b = graph.points[edge.b]
                let dx = b.x - a.x
                let dy = b.y - a.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0 else { continue }

                // cross(w, d)
                let denominator = wx * dy - wy * dx
                if abs(denominator) <= 1e-9 * length {
                    // The ray runs along this edge. Only a problem when it runs *through* it.
                    let perpendicular = abs((click.x - a.x) * dy - (click.y - a.y) * dx) / length
                    if perpendicular <= 1e-6 { degenerate = true; break }
                    continue
                }

                let t = ((a.x - click.x) * dy - (a.y - click.y) * dx) / denominator
                guard t > 1e-9 else { continue }
                let u = ((click.x - a.x) * wy - (click.y - a.y) * wx) / (dx * wy - dy * wx)
                // Slack on both ends so a hit that rounds a hair outside the edge is not
                // silently skipped in favour of a farther edge — it is caught by the node test
                // immediately below and retried on another ray instead.
                let slack = 1e-6 / length
                guard u >= -slack, u <= 1 + slack else { continue }
                // A hit within a whisker of a node cannot say which side of the fan the click
                // is on. Try another direction rather than guess.
                if u * length <= 1e-6 || (1 - u) * length <= 1e-6 { degenerate = true; break }

                // The click lies to the left of the dart: it is behind the hit along the ray,
                // so the dart is the sense whose direction crosses the ray from left to right,
                // cross(d, w) < 0.
                let crossDW = dx * wy - dy * wx
                crossings.append((t, crossDW < 0 ? index * 2 : index * 2 + 1))
            }

            if degenerate { continue }
            crossings.sort { $0.t != $1.t ? $0.t < $1.t : $0.dart < $1.dart }
            return crossings
        }
        return nil
    }

    /// Even-odd containment of `point` in the polygon through `ring`. An edge walked out and
    /// back is crossed twice and cancels, so an open component encloses nothing.
    package static func encloses(_ ring: [PDFPoint], _ point: PDFPoint) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i]
            let b = ring[j]
            if (a.y > point.y) != (b.y > point.y) {
                let x = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - Ring arithmetic

    /// An area under which a walked ring is not a region. Scaled to the ring's own extent so it
    /// means the same thing on a 10 pt detail and a 2000 pt site plan, and floored well below
    /// anything drawable.
    private static func areaFloor(of bounds: PDFRect) -> Double {
        let extent = Swift.max(bounds.width, bounds.height)
        return Swift.max(1e-9, extent * extent * 1e-12)
    }

    /// Removes `u → v → u` excursions: a dimension line poking into a room is walked out and
    /// back, and contributes nothing to the boundary.
    static func collapseSpurs(_ ring: [Int]) -> [Int] {
        var stack: [Int] = []
        stack.reserveCapacity(ring.count)
        for node in ring {
            if stack.count >= 2, stack[stack.count - 2] == node {
                stack.removeLast()
            } else {
                stack.append(node)
            }
        }
        // The same rule across the wrap, in both senses: the sequence may start in the middle
        // of a spur (`stack[1] == last`, the tip is first) or end in the middle of one
        // (`stack[0] == stack[count - 2]`, the tip is last). The second was missed and left a
        // 15 pt spike in the ring whenever the ray happened to hit the edge a spur hangs off,
        // counted in the perimeter but not the area (BH-217). Collapsing one can expose the
        // other, so both are retried until neither applies.
        var collapsed = true
        while collapsed, stack.count > 3 {
            collapsed = false
            if stack[1] == stack[stack.count - 1] {
                stack.removeLast()
                stack.removeFirst()
                collapsed = true
            } else if stack[0] == stack[stack.count - 2] {
                stack.removeLast(2)
                collapsed = true
            }
        }
        while stack.count > 1, stack[0] == stack[stack.count - 1] {
            stack.removeLast()
        }
        return stack
    }

    /// Drops a vertex that lies on the straight line between its neighbours.
    ///
    /// A wall crossed by a dimension line gains a node where they cross; the wall is still one
    /// straight wall and the ring should say so. The tolerance is at floating-point noise level,
    /// so this can shorten the vertex list and can never move the boundary.
    static func dropCollinear(_ ring: [PDFPoint], tolerance: Double) -> [PDFPoint] {
        guard ring.count > 3 else { return ring }

        func isRedundant(_ a: PDFPoint, _ b: PDFPoint, _ c: PDFPoint) -> Bool {
            let dx = c.x - a.x
            let dy = c.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return false }
            let cross = abs((b.x - a.x) * dy - (b.y - a.y) * dx) / length
            guard cross <= tolerance else { return false }
            let dot = (b.x - a.x) * dx + (b.y - a.y) * dy
            return dot >= 0 && dot <= length * length
        }

        var kept: [PDFPoint] = []
        kept.reserveCapacity(ring.count)
        for point in ring {
            while kept.count >= 2, isRedundant(kept[kept.count - 2], kept[kept.count - 1], point) {
                kept.removeLast()
            }
            kept.append(point)
        }
        while kept.count > 3, isRedundant(kept[kept.count - 2], kept[kept.count - 1], kept[0]) {
            kept.removeLast()
        }
        while kept.count > 3, isRedundant(kept[kept.count - 1], kept[0], kept[1]) {
            kept.removeFirst()
        }
        return kept
    }

    /// A face's spur-free ring in the form a traced region states it — collinear vertices dropped
    /// when the options say so, rotated to its smallest vertex — so one face reached twice (from
    /// two overlapping tiles of the room detector) is recognised as one (L-73b).
    static func canonicalRing(_ collapsed: [PDFPoint], options: TraceOptions) -> [PDFPoint] {
        canonicalise(
            options.simplifiesCollinearVertices
                ? dropCollinear(collapsed, tolerance: options.collinearTolerance)
                : collapsed
        )
    }

    /// Rotates the ring to start at its lexicographically smallest vertex, so the same face
    /// always produces the same array whichever edge the ray happened to hit.
    private static func canonicalise(_ ring: [PDFPoint]) -> [PDFPoint] {
        guard ring.count > 1 else { return ring }
        var best = 0
        for index in ring.indices {
            let candidate = ring[index]
            let incumbent = ring[best]
            if candidate.x < incumbent.x || (candidate.x == incumbent.x && candidate.y < incumbent.y) {
                best = index
            }
        }
        guard best != 0 else { return ring }
        return Array(ring[best...]) + Array(ring[..<best])
    }
}

/// A page prepared for tracing by ``RegionTracer/prepare(primitives:options:)``: its
/// segments in their stable order, a packed R-tree over them, and the options they were
/// collected under. Immutable and `Sendable`, so it can be cached per page and extraction and
/// shared between clicks.
public struct PreparedTrace: Sendable {
    /// The options the segments were collected under; every trace on this value uses them.
    public let options: TraceOptions
    let segments: [TraceSegment]
    let tree: PackedRTree?
    let pageBounds: PDFRect?
    let overflow: Int?
    /// Segments a person accepted to close openings (NL-AUTO-07). Kept apart from
    /// ``segments`` so accepting one never re-sorts or re-indexes the page; every window
    /// includes all of them.
    var closureSegments: [TraceSegment] = []
    /// The filter the page was prepared under. ``TraceFilter/none`` for an unfiltered page.
    public private(set) var filter: TraceFilter = .none

    func with(filter: TraceFilter) -> PreparedTrace {
        var copy = self
        copy.filter = filter
        return copy
    }

    /// This page with `closures` inserted as drawn edges. Only ever called with closures a
    /// person accepted, or while proposing them for the person to accept.
    public func adding(closures: [ProposedClosure]) -> PreparedTrace {
        guard !closures.isEmpty else { return self }
        var copy = self
        var index = closureSegments.count
        for closure in closures where closure.start.isFinite && closure.end.isFinite && closure.width > 0 {
            copy.closureSegments.append(
                TraceSegment(
                    start: closure.start,
                    end: closure.end,
                    // Identifiers from the top of the range: no extractor hands these out.
                    sourceID: UInt64.max - UInt64(index),
                    pieceIndex: 0
                )
            )
            index += 1
        }
        return copy
    }

    /// Segments collected. Zero when the page was refused as too complex.
    public var segmentCount: Int { segments.count }

    /// The distance from `point` to the nearest segment, exactly as a scan of every segment
    /// would give it: square queries that double until they hold a segment, then one more at
    /// the best distance found, because a segment outside a square of half-side `r` is farther
    /// than `r`.
    func nearestDistance(to point: PDFPoint) -> Double {
        func distance(_ segment: TraceSegment) -> Double {
            SegmentMath.nearestPoint(
                on: SegmentGeometry(start: segment.start, end: segment.end), to: point
            ).distance
        }
        guard let tree, let bounds = pageBounds else {
            return segments.reduce(Double.infinity) { Swift.min($0, distance($1)) }
        }
        let reach = Swift.max(
            Swift.abs(point.x - bounds.minX), Swift.abs(point.x - bounds.maxX),
            Swift.abs(point.y - bounds.minY), Swift.abs(point.y - bounds.maxY)
        )
        var half = Swift.max(options.initialWindowSide / 2, 1)
        var hits: [Int] = []
        while true {
            hits.removeAll(keepingCapacity: true)
            tree.query(PDFRect(x: point.x - half, y: point.y - half, width: 2 * half, height: 2 * half), into: &hits)
            var best = Double.infinity
            for index in hits { best = Swift.min(best, distance(segments[index])) }
            if best <= half { return best }
            if half >= reach || !half.isFinite {
                return segments.reduce(Double.infinity) { Swift.min($0, distance($1)) }
            }
            half = best.isFinite ? best : half * 2
        }
    }

    /// Every segment whose bounds intersect `window`, in the stable order of `segments` — the
    /// same subset and order a filter of the whole array gives, so node numbering in the
    /// arrangement stays a function of the subset.
    func segments(intersecting window: PDFRect) -> [TraceSegment] {
        let closures = closureSegments.filter { window.intersects($0.bounds) }
        guard let tree else { return segments.filter { window.intersects($0.bounds) } + closures }
        var hits: [Int] = []
        // A hair wider than the window so a box touching its edge is never lost to a rounding
        // difference between the tree's bounds and `PDFRect`'s; the exact test follows.
        tree.query(window.insetBy(1e-6 * Swift.max(1, window.width)), into: &hits)
        hits.sort()
        var result: [TraceSegment] = []
        result.reserveCapacity(hits.count)
        for index in hits where window.intersects(segments[index].bounds) {
            result.append(segments[index])
        }
        return result + closures
    }
}


// MARK: - Openings a person may close (NL-AUTO-07)

/// A segment that would close one opening in a room's boundary — a door, usually — proposed
/// by the tracer and inserted only when a person accepts it.
///
/// The tracer's refusal to close a gap it invented stands: a proposed closure is shown,
/// measured and named, and the region behind it is committed only after the person says yes.
/// Its two endpoints are nodes the drawing already has — two wall ends aimed at each other, or
/// two jamb corners on the same wall face.
public struct ProposedClosure: Sendable, Hashable {
    public let start: PDFPoint
    public let end: PDFPoint

    public init(start: PDFPoint, end: PDFPoint) {
        self.start = start
        self.end = end
    }

    /// Width of the opening, in page points.
    public var width: Double { start.distance(to: end) }

    /// The middle of the closing line, where the interface labels it.
    public var midpoint: PDFPoint { PDFPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
}

/// A region that closes only across openings, with the closures that close it.
public struct OpeningProposal: Sendable, Hashable {
    /// The ring the trace produces once ``closures`` are inserted.
    public let region: TracedRegion
    /// Every closing line the region needs, in the order the walk found them.
    public let closures: [ProposedClosure]

    public init(region: TracedRegion, closures: [ProposedClosure]) {
        self.region = region
        self.closures = closures
    }
}

/// What a trace that may propose closures produced.
public enum OpeningAwareTraceResult: Sendable, Hashable {
    /// Closed without help: commit as before.
    case traced(TracedRegion)
    /// Closed only across these openings. Nothing is committed until the person accepts.
    case closesOpenings(OpeningProposal)
    /// The plain refusal, exactly as ``RegionTracer/trace(_:click:)`` states it — including
    /// when an opening was found but was wider than the cap, so a missing wall is never
    /// proposed as a door.
    case refused(TraceResult)
}

extension RegionTracer {

    /// Traces the click and, when the walk refuses at an opening whose two sides it can name,
    /// proposes the closing line and tries again, up to `maximumClosures` times.
    ///
    /// - Parameters:
    ///   - maximumClosureWidth: the widest opening that may be proposed, in page points. The
    ///     interface derives it from the page scale (2.5 m by default), so a missing wall is
    ///     never offered as a door.
    ///   - maximumClosures: how many openings one room may need closing. A room that needs
    ///     more is refused as before.
    /// - Returns: ``OpeningAwareTraceResult/refused(_:)`` carries the **first** refusal, so a
    ///   click that cannot be helped says exactly what the plain trace says.
    public static func traceProposingClosures(
        _ prepared: PreparedTrace,
        click: PDFPoint,
        maximumClosureWidth: Double,
        maximumClosures: Int = 4
    ) -> OpeningAwareTraceResult {
        let first = traceDetailed(prepared, click: click)
        if case .traced(let region) = first.result { return .traced(region) }
        guard case .notClosed = first.result, maximumClosureWidth.isFinite, maximumClosureWidth > 0 else {
            return .refused(first.result)
        }
        var closures: [ProposedClosure] = []
        var opening = first.opening
        while let next = opening, closures.count < Swift.max(0, maximumClosures) {
            guard next.width <= maximumClosureWidth, next.width > 0, !closures.contains(next) else { break }
            closures.append(next)
            let attempt = traceDetailed(prepared.adding(closures: closures), click: click)
            switch attempt.result {
            case .traced(let region):
                return .closesOpenings(OpeningProposal(region: region, closures: closures))
            case .tooComplex:
                return .refused(first.result)
            case .notClosed:
                opening = attempt.opening
            }
        }
        return .refused(first.result)
    }

    /// Traces the click with accepted closures inserted as drawn edges.
    public static func trace(
        _ prepared: PreparedTrace,
        click: PDFPoint,
        closures: [ProposedClosure]
    ) -> TraceResult {
        trace(prepared.adding(closures: closures), click: click)
    }
}
