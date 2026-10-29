import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Every room on a sheet, proposed at once (NL-AUTO-08).
///
/// The one-click trace answers "which room is this point in"; this answers "which rooms are on
/// this sheet". It builds the page's planar arrangement once, walks every bounded face, and
/// judges each face exactly as ``RegionTracer`` judges the face a click lands in — the same walk,
/// the same refusal of an opening, the same ring. So every rule the trace keeps holds here too: a
/// gap wider than the join tolerance is never bridged silently, a room behind a door is closed
/// only across the door's own two jambs and the closure is part of the proposal, and a missing
/// wall is never taken for a door. The corridor is never absorbed into the room: a face the
/// judgement refuses at an opening is traced from interior points with
/// ``RegionTracer/traceProposingClosures(_:click:maximumClosureWidth:maximumClosures:)``, each of
/// which lands in one of the rooms, and the closure separates them.
///
/// Faces are filtered by what a room can be: an area band the caller derives from the page scale,
/// and a minimum width — twice the area over the perimeter, which for a long thin face is its
/// thickness — so the slivers between the two lines of a wall are not rooms. Identical rings are
/// one room. Nothing is committed; the caller shows the proposals and a person accepts them.
///
/// # A real sheet (L-73b)
///
/// Every face used to be traced from scratch from five interior points, each trace growing its
/// own window until the face fitted — on a real A1 roof plan two and a half minutes of windows
/// over a sedum hatch. A face that closes is now judged straight from the sheet's
/// arrangement; only a face refused at an opening is traced from its interior points.
///
/// When the whole sheet is over a work cap for one arrangement, the sheet is read in square
/// tiles instead: each tile's arrangement is built from the segments that reach it, and a face
/// is accepted from a tile only when its whole walk lies inside the tile shrunk by the tracer's
/// working-window margin — the condition under which the one-click trace trusts a window, so
/// the face and its judgement are the ones the whole sheet would give. Tiles overlap by half,
/// so any face up to half a tile across lies inside some tile; the tiles double in size until
/// one would cover the sheet. A tile that is itself over a cap is skipped and the result says
/// the search stopped short, never that it read everything.
public enum RoomDetector {

    public struct Options: Sendable, Hashable {
        /// Smallest room, square page points.
        public var minimumArea: Double
        /// Largest room, square page points.
        public var maximumArea: Double
        /// Narrowest room, page points: 2 × area / perimeter must reach it.
        public var minimumWidth: Double
        /// Widest opening a proposal may close, page points.
        public var maximumClosureWidth: Double
        /// Faces examined before the search stops, stated when it bites: bounded faces of at
        /// least ``minimumArea``, each counted once however many seeds it gives (X-045).
        public var maximumFaces: Int

        public init(minimumArea: Double, maximumArea: Double, minimumWidth: Double, maximumClosureWidth: Double, maximumFaces: Int = 2_000) {
            self.minimumArea = minimumArea
            self.maximumArea = maximumArea
            self.minimumWidth = minimumWidth
            self.maximumClosureWidth = maximumClosureWidth
            self.maximumFaces = Swift.max(1, maximumFaces)
        }
    }

    /// One proposed room.
    public struct Room: Sendable, Hashable {
        public let region: TracedRegion
        /// Openings closed to reach it, each a person's decision to accept.
        public let closures: [ProposedClosure]
        /// A point inside the room — where a label is looked for, and where it was traced from.
        public let seed: PDFPoint
    }

    public enum Result: Sendable, Hashable {
        /// The rooms found, top to bottom then left to right. `truncated` when the face cap
        /// stopped the search, or part of the sheet was too dense to read: the sheet may hold
        /// more.
        case rooms([Room], truncated: Bool)
        /// Not one part of the sheet could be read: the page was refused when it was prepared,
        /// or every tile was over a work cap.
        case tooComplex(count: Int)
    }

    /// The smallest tile the sheet is read in when it is over a cap as a whole, page points.
    static let initialTileSide = 512.0

    public static func detect(_ prepared: PreparedTrace, options: Options) -> Result {
        if let count = prepared.overflow { return .tooComplex(count: count) }
        guard !prepared.segments.isEmpty, let pageBounds = prepared.pageBounds else {
            return .rooms([], truncated: false)
        }
        var search = Search(prepared: prepared, options: options)
        switch TracePlanarGraph.build(segments: prepared.segments, options: prepared.options) {
        case .built(let graph):
            if case .tooComplex(let count) = search.readFaces(of: graph, inside: nil) {
                return .tooComplex(count: count)
            }
        case .tooComplex(let count):
            if let refusal = search.readTiles(pageBounds: pageBounds, sheetRefusal: count) {
                return refusal
            }
        }
        return search.finish()
    }

    /// The work of one detection: faces judged so far, rooms found, seeds still to trace.
    private struct Search {
        let prepared: PreparedTrace
        let options: Options
        var rooms: [Room] = []
        var seen = Set<[PDFPoint]>()
        /// Canonical rings of faces already judged, so a face found again — in an overlapping
        /// tile, or at the next tile size — costs nothing.
        var judged = Set<[PDFPoint]>()
        var pendingSeeds: [PDFPoint] = []
        var faces = 0
        var truncated = false

        init(prepared: PreparedTrace, options: Options) {
            self.prepared = prepared
            self.options = options
        }

        enum FaceOutcome {
            case read
            case tooComplex(count: Int)
        }

        /// Walks every face of `graph` once and judges each bounded face of at least the
        /// minimum area whose whole walk lies inside `inner` (the whole graph when `nil`).
        mutating func readFaces(of graph: TracePlanarGraph, inside inner: PDFRect?) -> FaceOutcome {
            let traceOptions = prepared.options
            let dashes = DashedLineProbe(prepared: prepared)
            var visited = [Bool](repeating: false, count: graph.edges.count * 2)
            var steps = 0
            for start in 0..<(graph.edges.count * 2) where !visited[start] {
                // The trace's own walk: nodes in order, and the degree-one nodes it turns round
                // at, each once, in walk order.
                var nodes: [Int] = []
                var deadEnds: [Int] = []
                var seenDeadEnd = Set<Int>()
                var dart = start
                repeat {
                    visited[dart] = true
                    nodes.append(graph.from(dart))
                    let head = graph.to(dart)
                    if graph.degree(of: head) == 1, seenDeadEnd.insert(head).inserted { deadEnds.append(head) }
                    dart = graph.next(after: dart)
                    steps += 1
                    if steps > traceOptions.maximumWalkSteps { return .tooComplex(count: steps) }
                } while dart != start
                guard nodes.count <= traceOptions.maximumRingVertices else { continue }
                let ring = RegionTracer.collapseSpurs(nodes).map { graph.points[$0] }
                // Counter-clockwise faces are bounded; anything under the room floor is a
                // sliver, a letter or a hatch cell. The ceiling waits for the judged ring: a face
                // can be two rooms joined at a door, which the trace separates.
                guard PolygonMath.signedArea(ring) >= options.minimumArea else { continue }
                if let inner {
                    guard let walkBounds = PDFRect.boundingBox(of: nodes.map { graph.points[$0] }),
                          inner.contains(walkBounds) else { continue }
                }
                let key = RegionTracer.canonicalRing(ring, options: traceOptions)
                guard judged.insert(key).inserted else { continue }
                // The cap counts faces, as documented (X-045).
                if faces >= options.maximumFaces {
                    truncated = true
                    return .read
                }
                faces += 1
                let seeds = RoomDetector.interiorPoints(of: ring)
                guard let seed = seeds.first else { continue }
                switch RegionTracer.judgeFace(
                    nodes: nodes, deadEnds: deadEnds, in: graph, seed: seed, options: traceOptions, dashes: dashes
                ) {
                case .traced(let region):
                    consider(region, closures: [], seed: seed)
                case .refused(let opening):
                    // Refused at an opening a proposal may close: one face that is two rooms
                    // joined at a door, and each interior point's trace lands in one of them. A
                    // face refused at no nameable opening, or at one wider than any proposal
                    // closes, is refused from every interior point too — the trace's first step
                    // is this judgement — so its points are not traced: on the roof plan the
                    // sheet frame's face cost two whole-sheet traces per point. The slack is the
                    // bridging tolerance: a closure across jambs runs along the wall face nearer
                    // the click, and another point may see the other face.
                    guard let opening,
                          opening.width <= options.maximumClosureWidth + traceOptions.gapTolerance
                    else { continue }
                    pendingSeeds.append(contentsOf: seeds)
                }
            }
            return .read
        }

        /// Reads the sheet in tiles that double in size until one would cover it. Returns the
        /// refusal when no tile at all could be read.
        mutating func readTiles(pageBounds: PDFRect, sheetRefusal: Int) -> Result? {
            let traceOptions = prepared.options
            let margin = Swift.max(traceOptions.gapTolerance, traceOptions.joinTolerance) * 4 + 1
            let extent = Swift.max(pageBounds.width, pageBounds.height) + 2 * margin
            var side = RoomDetector.initialTileSide
            var readAny = false
            var worst = sheetRefusal
            while side < extent {
                let stride = side / 2
                let columns = Swift.max(1, Int(((pageBounds.width + 2 * margin - side) / stride).rounded(.up)) + 1)
                let rows = Swift.max(1, Int(((pageBounds.height + 2 * margin - side) / stride).rounded(.up)) + 1)
                for row in 0..<rows {
                    for column in 0..<columns {
                        let window = PDFRect(
                            x: pageBounds.minX - margin + Double(column) * stride,
                            y: pageBounds.minY - margin + Double(row) * stride,
                            width: side,
                            height: side
                        )
                        let segments = prepared.segments(intersecting: window)
                        guard !segments.isEmpty else { continue }
                        switch TracePlanarGraph.build(segments: segments, options: traceOptions) {
                        case .tooComplex(let count):
                            truncated = true
                            worst = Swift.max(worst, count)
                        case .built(let graph):
                            switch readFaces(of: graph, inside: window.outsetBy(-margin)) {
                            case .read: readAny = true
                            case .tooComplex(let count):
                                truncated = true
                                worst = Swift.max(worst, count)
                            }
                        }
                        if faces >= options.maximumFaces, truncated { return nil }
                    }
                }
                side *= 2
            }
            // Faces wider than the largest tile that was read are not found; say so.
            truncated = true
            return readAny ? nil : .tooComplex(count: worst)
        }

        /// A region found from a face or a seed, kept when it is a room and new.
        mutating func consider(_ region: TracedRegion, closures: [ProposedClosure], seed: PDFPoint) {
            guard region.area >= options.minimumArea, region.area <= options.maximumArea,
                  region.perimeter > 0, 2 * region.area / region.perimeter >= options.minimumWidth
            else { return }
            // The ring is canonicalised, so one room found twice is one array.
            guard seen.insert(region.ring).inserted else { return }
            rooms.append(Room(region: region, closures: closures, seed: seed))
        }

        mutating func finish() -> Result {
            for seed in pendingSeeds {
                // A seed inside a room already found adds nothing.
                if rooms.contains(where: { RegionTracer.encloses($0.region.ring, seed) }) { continue }
                let outcome = RegionTracer.traceProposingClosures(
                    prepared, click: seed, maximumClosureWidth: options.maximumClosureWidth
                )
                let region: TracedRegion
                let closures: [ProposedClosure]
                switch outcome {
                case .traced(let traced): (region, closures) = (traced, [])
                case .closesOpenings(let proposal): (region, closures) = (proposal.region, proposal.closures)
                case .refused: continue
                }
                // A seed that fell inside a doorway — between the two jambs — cannot say which
                // side of the opening it belongs to, and the closure it gets is a coin toss. Its
                // answer is dropped; a seed well inside a room finds that room.
                if closures.contains(where: { closure in
                    let nearest = SegmentMath.nearestPoint(
                        on: SegmentGeometry(start: closure.start, end: closure.end), to: seed
                    ).distance
                    return nearest < closure.width / 2
                }) { continue }
                consider(region, closures: closures, seed: seed)
            }
            rooms.sort {
                let a = centroid($0.region.ring), b = centroid($1.region.ring)
                return a.y != b.y ? a.y > b.y : a.x < b.x
            }
            return .rooms(rooms, truncated: truncated)
        }
    }

    /// Points strictly inside `ring`: the middle of every inside span of horizontal lines at
    /// five heights through the ring (nudged off vertex heights, so no crossing counts twice).
    static func interiorPoints(of ring: [PDFPoint]) -> [PDFPoint] {
        guard ring.count >= 3 else { return [] }
        let ys = ring.map(\.y)
        guard let minY = ys.min(), let maxY = ys.max(), maxY > minY else { return [] }
        let vertexHeights = Set(ys)
        var points: [PDFPoint] = []
        for fraction in [0.5, 0.1, 0.3, 0.7, 0.9] {
            var y = minY + (maxY - minY) * fraction
            var nudge = (maxY - minY) * 1e-3
            while vertexHeights.contains(y) { y += nudge; nudge *= 1.7 }
            var xs: [Double] = []
            var j = ring.count - 1
            for i in ring.indices {
                let a = ring[i], b = ring[j]
                if (a.y > y) != (b.y > y) {
                    xs.append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
                }
                j = i
            }
            xs.sort()
            var index = 0
            while index + 1 < xs.count {
                if xs[index + 1] - xs[index] > 0 {
                    points.append(PDFPoint(x: (xs[index] + xs[index + 1]) / 2, y: y))
                }
                index += 2
            }
        }
        return points
    }

    static func centroid(_ ring: [PDFPoint]) -> PDFPoint {
        let n = Double(Swift.max(1, ring.count))
        return PDFPoint(x: ring.reduce(0) { $0 + $1.x } / n, y: ring.reduce(0) { $0 + $1.y } / n)
    }
}
