import Foundation
import ZPDFContracts

/// One piece of non-PDF, non-markup snappable geometry: sources 4, 5 and 6 of `SNAP_CONTRACT` 13.2.
///
/// The grid is deliberately **not** modelled here. A grid has no bounded extent and indexing it
/// would mean materialising an unbounded lattice; it is computed analytically inside the query
/// radius instead (see ``SnapGridTargets``), which is also what keeps grid snap alive on a
/// scanned page whose index is empty.
public struct SnapBoundary: Sendable, Hashable, Codable, Identifiable {

    public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
        case zone
        case scaleRegion
        case temporaryGuide
        case calibrationPoint

        var source: SnapGeometrySource {
            switch self {
            case .zone: .zoneBoundary
            case .scaleRegion: .scaleRegionBoundary
            case .temporaryGuide: .temporaryGuide
            // A calibration point is Zenit-owned data, so its geometry source is the Zenit
            // markup source; its *kind* is `calibrationPoint`, priority 1.
            case .calibrationPoint: .zenitMarkup
            }
        }

        var kindSet: SnapEntryKindSet {
            switch self {
            case .zone, .scaleRegion: .boundary
            case .temporaryGuide: .temporaryGuide
            case .calibrationPoint: .calibration
            }
        }
    }

    /// Stable identity of the owning object, as a string. Incremental updates address it.
    public let id: String
    public let category: Category

    /// The geometry, in canonical page space. One boundary may contribute several primitives
    /// (a zone with holes); each element is one primitive.
    public let geometry: [PrimitiveGeometry]

    /// OCG or Zenit layer identity, used by the active-layer score term.
    public let layerID: String?

    /// `0...1`. Boundaries are authored, not inferred, so the default is full confidence.
    public let confidence: Float

    public init(
        id: String,
        category: Category,
        geometry: [PrimitiveGeometry],
        layerID: String? = nil,
        confidence: Float = 1.0
    ) {
        self.id = id
        self.category = category
        self.geometry = geometry
        self.layerID = layerID
        self.confidence = Swift.min(1, Swift.max(0, confidence))
    }
}

/// A markup as the snap index sees it.
///
/// `MarkupRecord` carries style, ledger cells, timestamps and a measurement result; none of
/// that is snappable. Projecting it down to geometry at the boundary of this package keeps the
/// index small and keeps a markup edit that changed only a colour from dirtying the index.
public struct SnapMarkupGeometry: Sendable, Hashable, Codable, Identifiable {

    /// How the snap engine reads one piece of a markup's geometry (ADR-0037, T-071).
    public enum Role: String, Sendable, Hashable, Codable {
        /// A drawn outline, chain or point: its vertices are markup vertices (priority 0).
        case outline
        /// A piece of a curve that has no corners — an ellipse drawn from its box. Its ends are
        /// the curve's quadrant points, not vertices, so they snap as a markup circle's quadrants
        /// do (`markupCenter`); the curve itself is a `markupEdge`.
        case smoothCurve
        /// A construction point with nothing drawn at it — an ellipse's centre, an arc's centre:
        /// `markupCenter`.
        case centre
    }

    public let id: MarkupID
    public let geometry: [PrimitiveGeometry]
    public let layerID: String?
    /// One role per piece of ``geometry``; `nil` (every geometry built before ADR-0037, and the
    /// default) is every piece an ``Role/outline``.
    public let roles: [Role]?

    /// A hidden or locked markup is not a snap target. The caller decides; the index only
    /// stores what it is given, and `from(_:)` applies the rule once.
    public init(id: MarkupID, geometry: [PrimitiveGeometry], layerID: String? = nil, roles: [Role]? = nil) {
        self.id = id
        self.geometry = geometry
        self.layerID = layerID
        self.roles = roles.flatMap { $0.count == geometry.count ? $0 : nil }
    }

    /// The role of piece `index`.
    public func role(at index: Int) -> Role {
        guard let roles, roles.indices.contains(index) else { return .outline }
        return roles[index]
    }

    /// Projects a `MarkupRecord` onto its snappable geometry, as it is drawn, or `nil` when it
    /// has none.
    ///
    /// Hidden markups are excluded: an invisible construction line that silently captures the
    /// cursor is exactly the "confidently wrong snap" `QUALITY_BAR` 3.6 names as the failure
    /// mode to prevent. Locked markups are kept — locked means "do not edit", not "do not touch".
    /// A markup on a hidden layer is hidden too: the caller passes the record its layer set
    /// resolves (`MarkupLayerSet.effective`), whose `hidden` says so.
    ///
    /// The geometry is the drawn one (ADR-0037, T-071), never the stored points read blindly:
    ///
    /// - an Ellipse annotation, and an Ellipse Area or Ellipse Cutout, is the ellipse inscribed
    ///   in its stored box — a circle when round, else four quarter curves through its quadrant
    ///   points, plus its centre. The box corners, where nothing is drawn, are never targets;
    /// - a chain that is drawn as a chain — a measurement's points, a Line, Arrow, Polyline or
    ///   freehand stroke — is an open polyline split at its arc edges, so its straight edges
    ///   offer the nearest point and their midpoints, not only its vertices; the chain is
    ///   ``MarkupRecord/drawnPointChain``, so a three-point Arc Length is its arc (X-042);
    /// - a box-drawn markup (``MarkupRecord/storesBoxCorners``) is the frame the canvas draws
    ///   (``MarkupRecord/drawnFrameBox``) — four corners and four edges — plus a callout's
    ///   target, and nothing at the stored corners of a box that draws no frame (an unframed
    ///   Text box);
    /// - a markup the canvas turns (``MarkupRecord/turnsWithStyleRotation``) is turned by the
    ///   same angle about the same centre, so a rotated rectangle snaps at its drawn corners;
    /// - an arc piece is only its curve (the target generator reads no end or centre off a
    ///   markup arc). Its construction points are pieces of their own, after every drawn piece so
    ///   the other pieces keep their components: a bulged edge's **stored** vertices that no
    ///   straight run already carries (W-088 — `startPoint`/`endPoint` are recomputed from centre
    ///   and radius and drift past S2's 1e-9 pt on a nearly straight arc), a loose arc's two
    ///   ends, and every arc's centre (``Role/centre``), which lies off the arc's own box and so
    ///   could not be reached through the arc's entry (W-087).
    ///
    /// - Parameter unprojectedCutouts: the cutouts of `record` that project nothing of their
    ///   own — hidden, or on a hidden layer (the caller passes the effective records). A parent
    ///   indexes none of its stored holes (U-085), yet the canvas still draws the hole of a
    ///   hidden cutout on the visible parent, so each of these contributes its own drawn
    ///   pieces here — an Ellipse Cutout's quarters and centre, a Polygon Cutout's ring — and
    ///   never the parent's derived 360-facet ring (V-085). A record that is not one of
    ///   `record`'s cutouts is ignored; the order is `record.cutoutMarkupIDs`.
    public static func from(_ record: MarkupRecord, unprojectedCutouts: [MarkupRecord] = []) -> SnapMarkupGeometry? {
        guard !record.hidden, var drawn = drawnPieces(of: record) else { return nil }
        if !unprojectedCutouts.isEmpty {
            let given = Dictionary(unprojectedCutouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in record.cutoutMarkupIDs {
                guard let cutout = given[id], let own = drawnPieces(of: cutout) else { continue }
                drawn.pieces += own.pieces
                drawn.roles += own.roles
            }
        }
        return SnapMarkupGeometry(
            id: record.id,
            geometry: drawn.pieces,
            layerID: record.layerID.map(\.rawValue.uuidString),
            roles: drawn.roles.allSatisfy { $0 == .outline } ? nil : drawn.roles
        )
    }

    /// The pieces `record` is drawn as, each with its role, turned as the canvas turns it, or
    /// `nil` when it has none. Hidden or not: ``from(_:unprojectedCutouts:)`` decides that.
    static func drawnPieces(of record: MarkupRecord) -> (pieces: [PrimitiveGeometry], roles: [Role])? {
        guard let source = record.geometry else { return nil }
        var pieces: [PrimitiveGeometry] = []
        var roles: [Role] = []
        func add(_ piece: PrimitiveGeometry, _ role: Role = .outline) {
            pieces.append(piece)
            roles.append(role)
        }
        // Every arc's construction points, added after all drawn pieces (W-087, W-088).
        var arcPoints: [(PrimitiveGeometry, Role)] = []
        func addRing(_ ring: PolygonRing) {
            let split = Self.ringPieces(ring)
            for piece in split.pieces { add(piece) }
            arcPoints += split.arcPoints
        }

        if let box = record.inscribedEllipseBox {
            // The ellipse tools read their box and nothing else (the engine's ellipse bounds).
            for (piece, role) in ellipsePieces(in: box) { add(piece, role) }
        } else {
            if record.storesBoxCorners {
                // The stored points are box corners, drawn only as the frame (ADR-0037 §4.3):
                // the callout's target is where its leader lands; the frame is a closed ring,
                // in the order the canvas draws it.
                if let target = record.calloutTarget { add(.point(target)) }
                if let frame = record.drawnFrameBox { add(frameRing(frame)) }
            } else if drawsPointsAsChain(record), let chain = record.drawnPointChain {
                // Arc segments of the chain (NL-MEASURE-05, ADR-0030 §5.6) stay arcs; the
                // straight runs are polylines with their vertices and edge midpoints. The chain is
                // the one the canvas draws: a three-point Arc Length is its arc, with its two
                // ends and its centre, not two chords (X-042).
                addRing(chain)
            } else {
                for point in source.points { add(.point(point)) }
            }
            for segment in source.segments { add(.segment(segment)) }
            // A parent's stored holes are derived from its cutouts and nothing else
            // (`TakeoffSession.rebuildingHoles`), and every visible cutout projects its own
            // drawn geometry; a hidden one is added by `from(_:unprojectedCutouts:)` (V-085).
            // Indexing the derived ring as well put an Ellipse Cutout's 360-facet polygon
            // under the cursor as 360 priority-0 markup vertices, which beat the cutout's own
            // curve and quadrants (U-085).
            let holesAreCutouts = !record.cutoutMarkupIDs.isEmpty
            for polygon in source.polygons {
                addRing(polygon.outer)
                guard !holesAreCutouts else { continue }
                for hole in polygon.holes { addRing(hole) }
            }
            for arc in source.arcs {
                add(.ellipticalArc(arc))
                // A loose arc stores no ends of its own: its ends are the computed ones.
                arcPoints += [(.point(arc.startPoint), .outline), (.point(arc.endPoint), .outline), (.point(arc.center), .centre)]
            }
            for circle in source.circles { add(.circle(circle)) }
            for count in source.countPoints { add(.point(count.position)) }
            for (piece, role) in arcPoints { add(piece, role) }
        }

        guard !pieces.isEmpty else { return nil }
        let degrees = record.drawnRotationDegrees
        if degrees != 0, let centre = record.styleRotationCentre {
            pieces = pieces.map { turned($0, about: centre, degrees: degrees) }
        }
        return (pieces, roles)
    }

    /// Whether the record's point list is drawn as an open chain: every measurement drawn from
    /// its points (the canvas's dimensioned polyline), and the Line, Arrow, Polyline and
    /// freehand annotations. The box-drawn kinds store corners, read by
    /// ``MarkupRecord/drawnFrameBox`` instead.
    static func drawsPointsAsChain(_ record: MarkupRecord) -> Bool {
        if record.tool != nil { return true }
        switch record.kind {
        case .measurement, .line, .arrow, .polyline, .freehand: return true
        default: return false
        }
    }

    /// A drawn frame as the closed ring the canvas strokes: (minX, minY), (maxX, minY),
    /// (maxX, maxY), (minX, maxY) — four markup vertices and four edges with their midpoints.
    static func frameRing(_ box: PDFRect) -> PrimitiveGeometry {
        .polyline(
            points: [
                PDFPoint(x: box.minX, y: box.minY), PDFPoint(x: box.maxX, y: box.minY),
                PDFPoint(x: box.maxX, y: box.maxY), PDFPoint(x: box.minX, y: box.maxY)
            ],
            isClosed: true
        )
    }

    /// The ellipse inscribed in `box`: a circle when its semi-axes agree to 1e-9 pt (the snap
    /// accuracy bound, QUALITY_BAR S2), a segment or a point when it has no width or height, and
    /// otherwise four quarter cubics with the standard handle `4/3·(√2 − 1)` plus the centre.
    ///
    /// The frozen primitive vocabulary has no ellipse, so the cubic is what the index stores; it
    /// is exact at the four quadrant points and within `2.7e-4` of the semi-axis between them.
    /// The engine never answers on that cubic: every quarter carries the role
    /// ``Role/smoothCurve``, and the target generator reads it as the exact ellipse quarter it
    /// stands for (``SnapEllipseArc``) — nearest point, arc-length midpoint, tangents and
    /// crossings on the ellipse, within S2's 1e-9 pt (U-089).
    static func ellipsePieces(in box: PDFRect) -> [(PrimitiveGeometry, Role)] {
        let centre = box.center
        let rx = box.width / 2
        let ry = box.height / 2
        guard rx.isFinite, ry.isFinite else { return [] }
        if rx == 0, ry == 0 { return [(.point(centre), .outline)] }
        if rx == 0 || ry == 0 {
            let start = PDFPoint(x: centre.x - rx, y: centre.y - ry)
            let end = PDFPoint(x: centre.x + rx, y: centre.y + ry)
            return [(.segment(SegmentGeometry(start: start, end: end)), .outline)]
        }
        if Swift.abs(rx - ry) <= 1e-9 {
            return [(.circle(CircleGeometry(center: centre, radius: (rx + ry) / 2)), .outline)]
        }
        let k = 4.0 / 3.0 * (2.0.squareRoot() - 1)
        func p(_ x: Double, _ y: Double) -> PDFPoint { PDFPoint(x: centre.x + x, y: centre.y + y) }
        let quarters: [PrimitiveGeometry] = [
            .cubicCurve(start: p(rx, 0), control1: p(rx, k * ry), control2: p(k * rx, ry), end: p(0, ry)),
            .cubicCurve(start: p(0, ry), control1: p(-k * rx, ry), control2: p(-rx, k * ry), end: p(-rx, 0)),
            .cubicCurve(start: p(-rx, 0), control1: p(-rx, -k * ry), control2: p(-k * rx, -ry), end: p(0, -ry)),
            .cubicCurve(start: p(0, -ry), control1: p(k * rx, -ry), control2: p(rx, -k * ry), end: p(rx, 0))
        ]
        return quarters.map { ($0, Role.smoothCurve) } + [(.point(centre), Role.centre)]
    }

    /// `piece` turned counter-clockwise by `degrees` about `centre` in page space (y up) — the
    /// turn ``MarkupRecord/drawnPosition(of:)`` gives a point. A rectangle, which cannot be
    /// axis-aligned once turned, becomes its closed ring of four corners.
    static func turned(_ piece: PrimitiveGeometry, about centre: PDFPoint, degrees: Double) -> PrimitiveGeometry {
        let radians = degrees * Double.pi / 180
        let cosine = Foundation.cos(radians)
        let sine = Foundation.sin(radians)
        func turn(_ point: PDFPoint) -> PDFPoint {
            let dx = point.x - centre.x
            let dy = point.y - centre.y
            return PDFPoint(x: centre.x + dx * cosine - dy * sine, y: centre.y + dx * sine + dy * cosine)
        }
        switch piece {
        case .point(let point):
            return .point(turn(point))
        case .segment(let segment):
            return .segment(SegmentGeometry(start: turn(segment.start), end: turn(segment.end)))
        case .polyline(let points, let isClosed):
            return .polyline(points: points.map(turn), isClosed: isClosed)
        case .cubicCurve(let start, let control1, let control2, let end):
            return .cubicCurve(start: turn(start), control1: turn(control1), control2: turn(control2), end: turn(end))
        case .quadraticCurve(let start, let control, let end):
            return .quadraticCurve(start: turn(start), control: turn(control), end: turn(end))
        case .rectangle(let rect):
            let r = rect.standardized
            let corners = [
                PDFPoint(x: r.minX, y: r.minY), PDFPoint(x: r.maxX, y: r.minY),
                PDFPoint(x: r.maxX, y: r.maxY), PDFPoint(x: r.minX, y: r.maxY)
            ]
            return .polyline(points: corners.map(turn), isClosed: true)
        case .circle(let circle):
            return .circle(CircleGeometry(center: turn(circle.center), radius: circle.radius))
        case .ellipticalArc(let arc):
            return .ellipticalArc(ArcGeometry(
                center: turn(arc.center), radius: arc.radius, startAngle: arc.startAngle + radians, sweepAngle: arc.sweepAngle
            ))
        }
    }

    /// A ring as snap primitives. A ring of straight edges is one polyline, exactly as before. A
    /// ring with arc edges (ADR-0030 §5.6) is its straight runs as open polylines — vertices and
    /// edge midpoints as always — and every arc edge as the arc it is, so the snap lands on the
    /// curve (nearest point, arc midpoint, centre) and never on the chord. An open chain is read
    /// the same way (T-071).
    ///
    /// `arcPoints` are the arcs' construction points, for the caller to add after every drawn
    /// piece: each stored vertex at an arc's end that no straight run carries (a vertex between
    /// two arcs, or a chain end on an arc) as an ``Role/outline`` point — the drawn vertex bit
    /// for bit, never the arc's recomputed `startPoint`/`endPoint` (W-088) — and each arc's centre
    /// as a ``Role/centre`` point (W-087). In ring order: an arc edge's start, then its centre,
    /// then its end.
    static func ringPieces(_ ring: PolygonRing) -> (pieces: [PrimitiveGeometry], arcPoints: [(PrimitiveGeometry, Role)]) {
        guard ring.hasArcs else { return ([.polyline(points: ring.points, isClosed: ring.isClosed)], []) }
        var pieces: [PrimitiveGeometry] = []
        var arcPoints: [(PrimitiveGeometry, Role)] = []
        var run: [PDFPoint] = []
        func flush() {
            if run.count >= 2 { pieces.append(.polyline(points: run, isClosed: false)) }
            run = []
        }
        let edges = ring.bulgedEdges
        let arcs = edges.map { edge in
            edge.bulge == 0 ? nil : BulgeArc.arc(from: edge.start, to: edge.end, bulge: edge.bulge)
        }
        /// The edge before / after `index` along the ring, `nil` past an open chain's ends.
        func neighbour(of index: Int, by step: Int) -> Int? {
            let other = index + step
            if edges.indices.contains(other) { return other }
            return ring.isClosed && edges.count > 1 ? (other + edges.count) % edges.count : nil
        }
        for (index, edge) in edges.enumerated() {
            guard let arc = arcs[index] else {
                if run.isEmpty { run.append(edge.start) }
                run.append(edge.end)
                continue
            }
            flush()
            pieces.append(.ellipticalArc(arc))
            // The start is this arc's to offer unless a straight edge before it carries it (a
            // run's vertex); between two arcs the later one offers it, so it is offered once.
            if neighbour(of: index, by: -1).map({ arcs[$0] != nil }) ?? true {
                arcPoints.append((.point(edge.start), .outline))
            }
            arcPoints.append((.point(arc.center), .centre))
            // The end only where nothing follows: a straight edge's run carries it, and a next
            // arc offers it as its own start.
            if neighbour(of: index, by: 1) == nil {
                arcPoints.append((.point(edge.end), .outline))
            }
        }
        flush()
        return (pieces, arcPoints)
    }
}
