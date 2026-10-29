import Foundation
import ZPDFContracts

// MARK: - Exact area edits on rings with arc edges (NL-MEASURE-05, ADR-0030 §5.6)
//
// Clipper2 works on integer polygons, so a ring with arcs can only enter it flattened — and a split or
// a merge done that way would store chords where the person drew an arc, and parts that no longer sum
// to the parent exactly. These routines work on the arcs themselves: every crossing of an arc is solved
// on its circle, every piece of an arc is an arc of the same circle with the bulge of its own sweep,
// and every area is the exact shoelace-plus-segments. They are used only when an arc is involved; a
// straight ring still goes through the Clipper2 pipeline it always has.

/// Why an exact edit of a ring with arcs was refused. Each case is a situation the exact method cannot
/// resolve without approximating, and the caller says so rather than approximating silently.
public enum ArcEditRefusal: Error, Equatable, Sendable {
    /// The geometry is not a closed ring of at least two edges.
    case notAClosedRing
    /// The ring crosses itself.
    case selfIntersecting
    /// The ring has holes (cutouts); the exact edit handles plain rings.
    case holes
    /// The cut line crosses itself.
    case cutSelfIntersects
    /// Two edges meet so that the order around a point cannot be decided (they leave it along the
    /// same tangent with the same curvature).
    case ambiguousContact
    /// The pieces did not close up or did not add up to the whole; nothing is returned.
    case inconsistent
}

/// A pool of vertices where two points closer than the tolerance are one vertex, so the pieces of two
/// edges that meet at a crossing meet at the *same* point.
struct ArcVertexPool {
    let tolerance: Double
    private(set) var points: [PDFPoint] = []
    /// Points by grid cell of the tolerance's size: two points within the tolerance are in the same
    /// or a neighbouring cell, so a lookup reads nine cells instead of every point.
    private var cells: [Cell: [Int]] = [:]

    private struct Cell: Hashable {
        let x: Int64
        let y: Int64
    }

    init(tolerance: Double) { self.tolerance = tolerance }

    private func cell(of point: PDFPoint) -> Cell? {
        let size = Swift.max(tolerance, 1e-12)
        let x = (point.x / size).rounded(.down), y = (point.y / size).rounded(.down)
        guard x.isFinite, y.isFinite, Swift.abs(x) < 1e17, Swift.abs(y) < 1e17 else { return nil }
        return Cell(x: Int64(x), y: Int64(y))
    }

    mutating func id(for point: PDFPoint) -> Int {
        guard let home = cell(of: point) else {
            // Out of the grid's range: the plain scan, still correct.
            if let index = points.firstIndex(where: { $0.distance(to: point) <= tolerance }) { return index }
            points.append(point)
            return points.count - 1
        }
        var best: (index: Int, distance: Double)?
        for dx in -1...1 {
            for dy in -1...1 {
                for index in cells[Cell(x: home.x + Int64(dx), y: home.y + Int64(dy))] ?? [] {
                    let distance = points[index].distance(to: point)
                    if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (index, distance) }
                }
            }
        }
        if let best { return best.index }
        points.append(point)
        cells[home, default: []].append(points.count - 1)
        return points.count - 1
    }
}

/// A directed piece between two pooled vertices.
struct ArcPiece {
    var from: Int
    var to: Int
    var edge: ArcEdge
}

/// Where a piece of one ring lies against another ring.
enum ArcPlace {
    /// Strictly inside the other ring's region.
    case inside
    /// Strictly outside it.
    case outside
    /// On the other ring's boundary, running the same way as the other ring's piece there.
    case sharedSame
    /// On the other ring's boundary, running the opposite way.
    case sharedOpposite
}

/// Rings cut into pieces wherever an edge of one crosses or touches an edge of another, and the
/// classifier that says where each piece lies against another ring — the one implementation the
/// exact booleans (``ArcRingBoolean``) and the exact cutout net (``ArcCutoutNet``) share (U-092).
///
/// Every crossing — straight/straight, straight/arc on the circle, arc/arc circle to circle, and
/// the ends of a collinear or co-circular overlap — is pooled once (``ArcVertexPool``), so the
/// pieces of both rings meet in the same vertex, and a cut arc becomes arcs of the same circle.
///
/// The ambiguity rule, one for both callers: a piece is **shared** with the other ring when a
/// piece of the other ring has the same pooled ends and a midpoint within `16 × tolerance` of its
/// own; otherwise its midpoint by length decides — **ambiguous** (`nil`) when that midpoint lies
/// within `tolerance` of the other ring's boundary, else inside or outside by the winding number
/// of the true boundary (arcs as arcs).
struct ArcArrangement {

    private typealias Box = (minX: Double, minY: Double, maxX: Double, maxY: Double)

    private struct Ends: Hashable {
        let low: Int
        let high: Int
        init(_ piece: ArcPiece) {
            low = Swift.min(piece.from, piece.to)
            high = Swift.max(piece.from, piece.to)
        }
    }

    let rings: [ArcRing]
    let tolerance: Double
    let pool: ArcVertexPool
    /// The pieces of every ring, in ring and edge order.
    let pieces: [[ArcPiece]]
    /// How many crossings or touches were found between different rings.
    let crossingCount: Int
    /// Edge pairs and point–edge tests performed so far, for a caller's work budget.
    private(set) var work: Int
    private let edgeBoxes: [[Box]]
    private let ringBoxes: [Box]
    private let byEnds: [[Ends: [Int]]]

    /// Cuts `rings` at their crossings with one another, or `nil` when that takes more than
    /// `workBudget` edge pairs.
    init?(rings: [ArcRing], tolerance: Double, workBudget: Int = .max) {
        self.rings = rings
        self.tolerance = tolerance
        var work = rings.reduce(0) { $0 + $1.edges.count }
        guard work <= workBudget else { return nil }
        let edgeBoxes: [[Box]] = rings.map { $0.edges.map(\.bounds) }
        let ringBoxes: [Box] = edgeBoxes.map { boxes in
            boxes.reduce((Double.infinity, Double.infinity, -Double.infinity, -Double.infinity)) {
                (Swift.min($0.0, $1.minX), Swift.min($0.1, $1.minY), Swift.max($0.2, $1.maxX), Swift.max($0.3, $1.maxY))
            }
        }
        func overlaps(_ a: Box, _ b: Box) -> Bool {
            a.minX - tolerance <= b.maxX && b.minX - tolerance <= a.maxX
                && a.minY - tolerance <= b.maxY && b.minY - tolerance <= a.maxY
        }

        var pool = ArcVertexPool(tolerance: tolerance)
        let startIDs = rings.map { ring in ring.edges.map { pool.id(for: $0.start) } }
        var events: [[[(fraction: Double, id: Int)]]] = rings.map { Array(repeating: [], count: $0.edges.count) }
        var crossingCount = 0
        for first in rings.indices {
            for second in (first + 1)..<rings.count where overlaps(ringBoxes[first], ringBoxes[second]) {
                let edgesA = rings[first].edges.indices.filter { overlaps(edgeBoxes[first][$0], ringBoxes[second]) }
                let edgesB = rings[second].edges.indices.filter { overlaps(edgeBoxes[second][$0], ringBoxes[first]) }
                work += edgesA.count * edgesB.count
                guard work <= workBudget else { return nil }
                for i in edgesA {
                    for j in edgesB where overlaps(edgeBoxes[first][i], edgeBoxes[second][j]) {
                        for crossing in rings[first].edges[i].crossings(with: rings[second].edges[j], tolerance: tolerance) {
                            let id = pool.id(for: crossing.point)
                            events[first][i].append((crossing.fractionOnFirst, id))
                            events[second][j].append((crossing.fractionOnSecond, id))
                            crossingCount += 1
                        }
                    }
                }
            }
        }
        var pieces: [[ArcPiece]] = []
        for (index, ring) in rings.enumerated() {
            var ringPieces: [ArcPiece] = []
            let ids = startIDs[index]
            for (edge, arcEdge) in ring.edges.enumerated() {
                ringPieces += ArcTopology.pieces(
                    of: arcEdge, startID: ids[edge], endID: ids[(edge + 1) % ids.count], events: events[index][edge], pool: pool
                )
            }
            pieces.append(ringPieces)
        }
        self.pool = pool
        self.pieces = pieces
        self.crossingCount = crossingCount
        self.work = work
        self.edgeBoxes = edgeBoxes
        self.ringBoxes = ringBoxes
        self.byEnds = pieces.map { ringPieces in Dictionary(grouping: ringPieces.indices, by: { Ends(ringPieces[$0]) }) }
    }

    /// The bounding box of ring `index`'s edges, arcs' extreme points included.
    func bounds(ofRing index: Int) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        ringBoxes[index]
    }

    /// Where `piece` lies against ring `other`, or `nil` when that is ambiguous (the type's rule).
    mutating func place(_ piece: ArcPiece, in other: Int) -> ArcPlace? {
        let midpoint = piece.edge.midpoint
        for index in byEnds[other][Ends(piece)] ?? []
        where pieces[other][index].edge.midpoint.distance(to: midpoint) <= tolerance * 16 {
            return pieces[other][index].from == piece.from ? .sharedSame : .sharedOpposite
        }
        let box = ringBoxes[other]
        guard midpoint.x >= box.minX - tolerance, midpoint.x <= box.maxX + tolerance,
              midpoint.y >= box.minY - tolerance, midpoint.y <= box.maxY + tolerance else { return .outside }
        work += 2 * rings[other].edges.count
        for (index, edge) in rings[other].edges.enumerated() {
            let edgeBox = edgeBoxes[other][index]
            guard midpoint.x >= edgeBox.minX - tolerance, midpoint.x <= edgeBox.maxX + tolerance,
                  midpoint.y >= edgeBox.minY - tolerance, midpoint.y <= edgeBox.maxY + tolerance else { continue }
            if edge.nearest(to: midpoint).distance <= tolerance { return nil }
        }
        return rings[other].winding(of: midpoint) != 0 ? .inside : .outside
    }
}

enum ArcTopology {

    /// Cuts `edge` at the pooled vertices in `events` (fraction, vertex), returning the pieces with
    /// their pooled ends. `startID`/`endID` are the edge's own ends.
    static func pieces(of edge: ArcEdge, startID: Int, endID: Int, events: [(fraction: Double, id: Int)], pool: ArcVertexPool) -> [ArcPiece] {
        var inner: [(fraction: Double, id: Int)] = []
        for event in events.sorted(by: { $0.fraction < $1.fraction })
        where event.id != startID && event.id != endID && !inner.contains(where: { $0.id == event.id }) {
            inner.append(event)
        }
        let cuts = inner.filter { $0.fraction > 0 && $0.fraction < 1 }
        let edges = edge.split(at: cuts.map(\.fraction), points: cuts.map { pool.points[$0.id] })
        let ids = [startID] + cuts.map(\.id) + [endID]
        return edges.enumerated().compactMap { index, piece in
            ids[index] == ids[index + 1] ? nil : ArcPiece(from: ids[index], to: ids[index + 1], edge: piece)
        }
    }

    /// The signed turn from direction `d` to direction `o`, in `(−π, π]`: positive is a left turn.
    static func turn(_ d: (dx: Double, dy: Double), _ o: (dx: Double, dy: Double)) -> Double {
        Foundation.atan2(d.dx * o.dy - d.dy * o.dx, d.dx * o.dx + d.dy * o.dy)
    }

    /// Of the candidate pieces leaving the end of `arriving`, the one turning furthest left — the
    /// rule that walks the smallest face with its interior on the left. Equal tangents are broken by
    /// curvature (the piece curving further left); a tie in both is refused.
    static func leftmost(after arriving: ArcEdge, among candidates: [Int], pieces: [ArcPiece]) throws(ArcEditRefusal) -> Int {
        let incoming = arriving.tangent(at: 1)
        var best: (index: Int, turn: Double, curvature: Double)?
        var tied = false
        for index in candidates {
            let edge = pieces[index].edge
            let turn = Self.turn(incoming, edge.tangent(at: 0))
            // Straight back along the arriving piece is the last resort, never a left turn.
            let value = turn >= Double.pi - 1e-12 ? -Double.pi : turn
            let curvature = edge.curvature
            guard let current = best else {
                best = (index, value, curvature)
                continue
            }
            if Swift.abs(value - current.turn) <= 1e-9 {
                if Swift.abs(curvature - current.curvature) <= 1e-12 * Swift.max(1, Swift.abs(curvature)) {
                    tied = true
                } else if curvature > current.curvature {
                    best = (index, value, curvature)
                    tied = false
                }
            } else if value > current.turn {
                best = (index, value, curvature)
                tied = false
            }
        }
        guard let best, !tied else { throw ArcEditRefusal.ambiguousContact }
        return best.index
    }

    /// Joins, around a ring, consecutive straight pieces that run on in the same direction and
    /// consecutive arcs of one circle, so a split or merge leaves no vertex where there is no corner.
    static func simplified(_ ring: ArcRing, tolerance: Double) -> ArcRing {
        var edges = ring.edges
        var changed = true
        while changed, edges.count > 2 {
            changed = false
            for index in 0..<edges.count {
                let next = (index + 1) % edges.count
                let a = edges[index], b = edges[next]
                var joined: ArcEdge?
                if a.bulge == 0, b.bulge == 0 {
                    let ux = a.end.x - a.start.x, uy = a.end.y - a.start.y
                    let vx = b.end.x - b.start.x, vy = b.end.y - b.start.y
                    let lu = (ux * ux + uy * uy).squareRoot(), lv = (vx * vx + vy * vy).squareRoot()
                    if lu > 0, lv > 0, Swift.abs(ux * vy - uy * vx) <= tolerance * Swift.max(lu, lv), ux * vx + uy * vy > 0 {
                        joined = ArcEdge(start: a.start, end: b.end)
                    }
                } else if a.bulge != 0, b.bulge != 0,
                          let bulge = BulgeArc.joined(a.start, a.end, b.end, first: a.bulge, second: b.bulge) {
                    joined = ArcEdge(start: a.start, end: b.end, bulge: bulge)
                }
                guard let joined else { continue }
                if next == 0 {
                    edges[index] = joined
                    edges.removeFirst()
                } else {
                    edges[index] = joined
                    edges.remove(at: next)
                }
                changed = true
                break
            }
        }
        return ArcRing(edges: edges)
    }

    /// Chains directed pieces into closed rings, starting each ring from the first unused piece and
    /// turning furthest left wherever more than one piece leaves a vertex.
    static func chain(_ pieces: [ArcPiece]) throws(ArcEditRefusal) -> [ArcRing] {
        var outgoing: [Int: [Int]] = [:]
        for (index, piece) in pieces.enumerated() { outgoing[piece.from, default: []].append(index) }
        var used = Set<Int>()
        var rings: [ArcRing] = []
        for first in pieces.indices where !used.contains(first) {
            var ring = [first]
            used.insert(first)
            var current = first
            var guardSteps = 0
            while true {
                let vertex = pieces[current].to
                var candidates = (outgoing[vertex] ?? []).filter { !used.contains($0) }
                if vertex == pieces[first].from { candidates.append(first) }
                guard !candidates.isEmpty else { throw ArcEditRefusal.inconsistent }
                let next = candidates.count == 1
                    ? candidates[0]
                    : try leftmost(after: pieces[current].edge, among: candidates, pieces: pieces)
                if next == first { break }
                ring.append(next)
                used.insert(next)
                current = next
                guardSteps += 1
                guard guardSteps <= pieces.count else { throw ArcEditRefusal.inconsistent }
            }
            rings.append(ArcRing(edges: ring.map { pieces[$0].edge }))
        }
        return rings
    }

    /// Outer rings (counter-clockwise) with the holes (clockwise) that lie inside them, in the
    /// splitter's deterministic order.
    static func polygons(from rings: [ArcRing], tolerance: Double) -> [PolygonGeometry] {
        var outers: [(ring: ArcRing, area: Double, holes: [ArcRing])] = []
        var holes: [ArcRing] = []
        for ring in rings {
            let area = ring.signedArea
            guard Swift.abs(area) > tolerance * tolerance else { continue }
            if area > 0 { outers.append((ring, area, [])) } else { holes.append(ring) }
        }
        for hole in holes {
            let probe = hole.edges[0].midpoint
            // The smallest outer that contains the hole.
            if let index = outers.indices
                .filter({ outers[$0].ring.winding(of: probe) != 0 || outers[$0].ring.boundaryDistance(to: probe) <= tolerance })
                .min(by: { outers[$0].area < outers[$1].area }) {
                outers[index].holes.append(hole)
            }
        }
        let measured = outers.map { outer in
            (polygon: PolygonGeometry(outer: outer.ring.polygonRing, holes: outer.holes.map(\.polygonRing)),
             area: outer.area + outer.holes.reduce(0) { $0 + $1.signedArea })
        }
        return EngineClipper.ordered(measured)
    }
}

// MARK: - Splitting an area along a drawn line

/// Splits an area whose ring has arc edges along a drawn line, exactly (NL-MEASURE-06 split on
/// NL-MEASURE-05 arcs).
///
/// # The method
///
/// The line is extended past the area, as ``PolygonSplitter`` does, and crossed with every edge; an
/// arc is crossed on its circle. The ring is cut at the crossings — an arc into arcs of the same
/// circle — and the pieces of the line that lie inside the ring become chords, usable both ways. The
/// parts are the faces of that plane graph, each walked from a ring piece turning furthest left at
/// every vertex. No part ever holds a chord where the ring had an arc, and the parts' exact areas sum
/// to the parent's: the method checks that before it returns them.
public enum ArcAreaSplitter {

    /// Splits `polygon` along `cut`.
    ///
    /// - Returns: the parts (``SplitResult/parts(_:)``, ordered as ``PolygonSplitter`` orders them),
    ///   ``SplitResult/lineMissesPolygon`` when the line does not divide the area, or
    ///   ``SplitResult/degenerate(smallestPartPDFArea:)`` for a sliver.
    /// - Throws: ``ArcEditRefusal`` when the split cannot be made exactly.
    public static func split(
        _ polygon: PolygonGeometry,
        along cut: [PDFPoint],
        options: PolygonSplitOptions = .default
    ) throws(ArcEditRefusal) -> SplitResult {
        guard polygon.holes.isEmpty else { throw ArcEditRefusal.holes }
        guard let stored = ArcRing(polygon.outer), cut.allSatisfy(\.isFinite) else { throw ArcEditRefusal.notAClosedRing }
        let ring = stored.counterClockwise
        let tolerance = ring.tolerance
        guard !ring.isSelfIntersecting(tolerance: tolerance) else { throw ArcEditRefusal.selfIntersecting }

        // The cut, without repeated points, extended past everything at both ends.
        var line: [PDFPoint] = []
        for point in cut where line.last.map({ $0.distance(to: point) > tolerance }) ?? true { line.append(point) }
        guard line.count >= 2 else { return .lineMissesPolygon }
        let box = ring.bounds
        var minX = box.minX, minY = box.minY, maxX = box.maxX, maxY = box.maxY
        for point in line {
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }
        let reach = options.reachFactor * Swift.max(1, ((maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY)).squareRoot())
        func extended(_ from: PDFPoint, _ to: PDFPoint) -> PDFPoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let length = (dx * dx + dy * dy).squareRoot()
            return PDFPoint(x: to.x + dx / length * reach, y: to.y + dy / length * reach)
        }
        line[0] = extended(line[1], line[0])
        line[line.count - 1] = extended(line[line.count - 2], line[line.count - 1])
        let cutEdges = (0..<(line.count - 1)).map { ArcEdge(start: line[$0], end: line[$0 + 1]) }
        for i in cutEdges.indices {
            for j in cutEdges.indices where j > i + 1 && cutEdges[i].mayMeet(cutEdges[j], tolerance: tolerance)
                && !cutEdges[i].crossings(with: cutEdges[j], tolerance: tolerance).isEmpty {
                throw ArcEditRefusal.cutSelfIntersects
            }
        }

        // Vertices: the ring's own first, so a shared vertex keeps the ring's exact coordinates.
        var pool = ArcVertexPool(tolerance: tolerance)
        let ringIDs = ring.edges.map { pool.id(for: $0.start) }
        var ringEvents = Array(repeating: [(fraction: Double, id: Int)](), count: ring.edges.count)
        var cutEvents = Array(repeating: [(fraction: Double, id: Int)](), count: cutEdges.count)
        for (k, edge) in ring.edges.enumerated() {
            for (j, cutEdge) in cutEdges.enumerated() where edge.mayMeet(cutEdge, tolerance: tolerance) {
                for crossing in edge.crossings(with: cutEdge, tolerance: tolerance) {
                    let id = pool.id(for: crossing.point)
                    ringEvents[k].append((crossing.fractionOnFirst, id))
                    cutEvents[j].append((crossing.fractionOnSecond, id))
                }
            }
        }

        var pieces: [ArcPiece] = []
        for (k, edge) in ring.edges.enumerated() {
            pieces += ArcTopology.pieces(of: edge, startID: ringIDs[k], endID: ringIDs[(k + 1) % ringIDs.count], events: ringEvents[k], pool: pool)
        }
        let ringPieceCount = pieces.count
        var chordPairs: [(Int, Int)] = []
        for (j, cutEdge) in cutEdges.enumerated() {
            let startID = pool.id(for: cutEdge.start)
            let endID = pool.id(for: cutEdge.end)
            var events = [(fraction: 0.0, id: startID)] + cutEvents[j] + [(fraction: 1.0, id: endID)]
            events.sort { $0.fraction < $1.fraction }
            var previous = events[0]
            for event in events.dropFirst() where event.id != previous.id {
                let chord = ArcEdge(start: pool.points[previous.id], end: pool.points[event.id])
                if ring.contains(chord.midpoint, tolerance: tolerance) {
                    pieces.append(ArcPiece(from: previous.id, to: event.id, edge: chord))
                    pieces.append(ArcPiece(from: event.id, to: previous.id, edge: chord.reversed))
                    chordPairs.append((pieces.count - 2, pieces.count - 1))
                }
                previous = event
            }
        }
        guard !chordPairs.isEmpty else { return .lineMissesPolygon }

        // Faces, each walked from an unused ring piece.
        var twin: [Int: Int] = [:]
        for (a, b) in chordPairs { twin[a] = b; twin[b] = a }
        var outgoing: [Int: [Int]] = [:]
        for (index, piece) in pieces.enumerated() { outgoing[piece.from, default: []].append(index) }
        var used = Set<Int>()
        var faces: [ArcRing] = []
        for first in 0..<ringPieceCount where !used.contains(first) {
            var face = [first]
            used.insert(first)
            var current = first
            var steps = 0
            while true {
                let candidates = (outgoing[pieces[current].to] ?? []).filter { $0 != twin[current] }
                guard !candidates.isEmpty else { throw ArcEditRefusal.inconsistent }
                let next = try ArcTopology.leftmost(after: pieces[current].edge, among: candidates, pieces: pieces)
                if next == first { break }
                guard !used.contains(next) else { throw ArcEditRefusal.inconsistent }
                face.append(next)
                used.insert(next)
                current = next
                steps += 1
                guard steps <= pieces.count else { throw ArcEditRefusal.inconsistent }
            }
            faces.append(ArcTopology.simplified(ArcRing(edges: face.map { pieces[$0].edge }), tolerance: tolerance))
        }
        guard chordPairs.allSatisfy({ used.contains($0.0) && used.contains($0.1) }) else { throw ArcEditRefusal.inconsistent }
        guard faces.count >= 2 else { return .lineMissesPolygon }

        let areas = faces.map(\.signedArea)
        guard areas.allSatisfy({ $0 > 0 }) else { throw ArcEditRefusal.inconsistent }
        // The invariant (a split never counts area twice): the parts sum to the parent.
        let whole = ring.signedArea
        guard Swift.abs(EngineNumerics.sum(areas) - whole) <= Swift.max(1e-12 * whole, tolerance * tolerance) * 16 else {
            throw ArcEditRefusal.inconsistent
        }
        if let smallest = areas.min(), smallest < options.minimumPartArea {
            return .degenerate(smallestPartPDFArea: smallest)
        }
        return .parts(EngineClipper.ordered(zip(faces, areas).map { (polygon: PolygonGeometry(outer: $0.polygonRing), area: $1) }))
    }
}

// MARK: - Booleans of rings with arcs

/// Union, intersection and difference of two rings with arc edges, exactly.
///
/// # The method
///
/// Every edge of one ring is crossed with every edge of the other — straight with straight, straight
/// with an arc on its circle, arc with arc circle to circle, and overlapping collinear or co-circular
/// edges at the ends of their overlap. Both rings are cut at the crossings. Each piece is then either
/// on the other ring's boundary (a piece of the other ring with the same ends and midpoint, walked the
/// same way or the opposite way) or strictly inside or outside it (the winding number at its midpoint,
/// arcs' circular segments included). The result keeps, for a union, the pieces outside the other ring
/// and one copy of a boundary shared in the same direction; for an intersection the pieces inside and
/// the shared same-direction boundary; for a difference `A − B` the pieces of A outside B, the pieces of
/// B inside A reversed, and the boundary shared in opposite directions. The kept pieces are chained into
/// rings, turning furthest left where a vertex offers more than one way on.
public enum ArcRingBoolean {

    public enum Operation: Sendable, Equatable {
        case union
        case intersection
        case difference
    }

    /// The result as rings: counter-clockwise outers and clockwise holes, collinear joins removed.
    public static func apply(_ operation: Operation, _ first: ArcRing, _ second: ArcRing) throws(ArcEditRefusal) -> [ArcRing] {
        let a = first.counterClockwise, b = second.counterClockwise
        let tolerance = Swift.max(a.tolerance, b.tolerance)
        guard !a.isSelfIntersecting(tolerance: tolerance), !b.isSelfIntersecting(tolerance: tolerance) else {
            throw ArcEditRefusal.selfIntersecting
        }
        // The shared cutting and classifier (U-092); an unbounded budget never answers nil.
        guard var arrangement = ArcArrangement(rings: [a, b], tolerance: tolerance) else { throw ArcEditRefusal.inconsistent }
        let aPieces = arrangement.pieces[0], bPieces = arrangement.pieces[1]
        func place(_ piece: ArcPiece, in other: Int) throws(ArcEditRefusal) -> ArcPlace {
            guard let place = arrangement.place(piece, in: other) else { throw ArcEditRefusal.ambiguousContact }
            return place
        }

        var kept: [ArcPiece] = []
        for piece in aPieces {
            switch (try place(piece, in: 1), operation) {
            case (.outside, .union), (.outside, .difference), (.inside, .intersection),
                 (.sharedSame, .union), (.sharedSame, .intersection), (.sharedOpposite, .difference):
                kept.append(piece)
            default:
                break
            }
        }
        for piece in bPieces {
            switch (try place(piece, in: 0), operation) {
            case (.outside, .union), (.inside, .intersection):
                kept.append(piece)
            case (.inside, .difference):
                kept.append(ArcPiece(from: piece.to, to: piece.from, edge: piece.edge.reversed))
            default:
                break
            }
        }
        guard !kept.isEmpty else { return [] }
        return try ArcTopology.chain(kept)
            .map { ArcTopology.simplified($0, tolerance: tolerance) }
            .filter { Swift.abs($0.signedArea) > tolerance * tolerance }
    }

    /// The result as polygons: every counter-clockwise ring an outer, every clockwise ring a hole of
    /// the smallest outer containing it, ordered as ``PolygonSplitter`` orders its parts.
    public static func polygons(_ operation: Operation, _ first: ArcRing, _ second: ArcRing) throws(ArcEditRefusal) -> [PolygonGeometry] {
        let tolerance = Swift.max(first.tolerance, second.tolerance)
        return ArcTopology.polygons(from: try apply(operation, first, second), tolerance: tolerance)
    }

    /// The union of several plain areas (no holes).
    ///
    /// The areas are folded into the first one: each pass unions the next area that joins the
    /// accumulated shape into one ring, so the order the areas were selected in does not matter.
    /// Areas that never join are returned as further polygons, and the caller refuses to store one
    /// markup that is secretly two shapes. A union that encloses a hole is returned with the hole.
    public static func union(_ polygons: [PolygonGeometry]) throws(ArcEditRefusal) -> [PolygonGeometry] {
        guard !polygons.isEmpty else { return [] }
        guard polygons.allSatisfy({ $0.holes.isEmpty }) else { throw ArcEditRefusal.holes }
        var rings: [ArcRing] = []
        for polygon in polygons {
            guard let ring = ArcRing(polygon.outer) else { throw ArcEditRefusal.notAClosedRing }
            rings.append(ring.counterClockwise)
        }
        var accumulated = rings.removeFirst()
        let tolerance = ([accumulated] + rings).reduce(1e-9) { Swift.max($0, $1.tolerance) }
        while !rings.isEmpty {
            var joined = false
            for index in rings.indices {
                let result = try apply(.union, accumulated, rings[index])
                let outers = result.filter { $0.signedArea > 0 }
                guard outers.count == 1, let outer = outers.first else { continue }
                rings.remove(at: index)
                if result.count > 1 {
                    // The union closed around a hole. It is one shape, but nothing can be unioned
                    // into a shape with a hole here; with more areas to go the merge is refused.
                    guard rings.isEmpty else { throw ArcEditRefusal.holes }
                    return ArcTopology.polygons(from: result, tolerance: tolerance)
                }
                accumulated = outer
                joined = true
                break
            }
            if !joined { break }
        }
        return ArcTopology.polygons(from: [accumulated] + rings, tolerance: tolerance)
    }
}
