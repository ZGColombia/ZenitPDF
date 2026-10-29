import Foundation

/// A straight segment in page space.
public struct SegmentGeometry: Codable, Hashable, Sendable {
    public var start: PDFPoint
    public var end: PDFPoint

    public init(start: PDFPoint, end: PDFPoint) {
        self.start = start
        self.end = end
    }

    public var bounds: PDFRect { PDFRect(corner: start, opposite: end) }
}

/// One closed or open ring of a polygon.
public struct PolygonRing: Codable, Hashable, Sendable {
    /// Vertices in order. The closing vertex is **not** repeated; closure is a flag, not a
    /// duplicated point, so that "three unique points" means what it says.
    public var points: [PDFPoint]
    /// True when the last vertex connects back to the first.
    public var isClosed: Bool
    /// Arc segments (NL-MEASURE-05, ADR-0030 §5): `bulges[i]` bends the edge that starts at
    /// `points[i]` into a circular arc, as `tan(θ/4)` of its included angle θ — the convention CAD
    /// exchange formats use. `0` is straight; a positive bulge turns counter-clockwise from the
    /// edge's start to its end, a negative one clockwise. The array is honoured only when it has
    /// exactly one entry per point (the last entry bends the closing edge of a closed ring and is
    /// ignored on an open one); `nil`, the default and every record written before ADR-0030, is
    /// every edge straight.
    public var bulges: [Double]?

    public init(points: [PDFPoint], isClosed: Bool = true, bulges: [Double]? = nil) {
        self.points = points
        self.isClosed = isClosed
        self.bulges = bulges
    }

    /// The bulges when they line up with the points and bend at least one edge; `nil` otherwise.
    public var validBulges: [Double]? {
        guard let bulges, bulges.count == points.count, bulges.allSatisfy(\.isFinite),
              bulges.contains(where: { $0 != 0 }) else { return nil }
        return bulges
    }

    /// Whether any edge is an arc.
    public var hasArcs: Bool { validBulges != nil }

    /// Vertices with consecutive duplicates removed, and the wrap-around duplicate removed for a
    /// closed ring. This is the set that polygon validation counts.
    public var uniquePoints: [PDFPoint] {
        var result: [PDFPoint] = []
        for point in points where result.last != point {
            result.append(point)
        }
        if isClosed, result.count > 1, result.first == result.last {
            result.removeLast()
        }
        return result
    }

    /// The ring's box as drawn: its vertices plus, on every arc edge, the arc's
    /// ``ArcGeometry/axisExtremes`` (W-089). A ring of straight edges is its vertices' box, as it
    /// always was; a semicircle bulging 2.5 pt past its chord reaches 2.5 pt past the vertices,
    /// which the vertex box left out — so a marquee over the bulge missed the markup and Align
    /// Right left the arc standing past the line.
    public var bounds: PDFRect? {
        guard hasArcs else { return PDFRect.boundingBox(of: points) }
        var extent = points
        for edge in bulgedEdges where edge.bulge != 0 {
            guard let arc = BulgeArc.arc(from: edge.start, to: edge.end, bulge: edge.bulge) else { continue }
            extent.append(contentsOf: arc.axisExtremes)
        }
        return PDFRect.boundingBox(of: extent)
    }

    /// Edges, including the closing edge for a closed ring.
    public var segments: [SegmentGeometry] {
        let vertices = uniquePoints
        guard vertices.count >= 2 else { return [] }
        var result: [SegmentGeometry] = []
        for index in 0..<(vertices.count - 1) {
            result.append(SegmentGeometry(start: vertices[index], end: vertices[index + 1]))
        }
        if isClosed, let first = vertices.first, let last = vertices.last {
            result.append(SegmentGeometry(start: last, end: first))
        }
        return result
    }
}

/// A polygon with an outer ring and any number of holes (spec 12.4).
///
/// Holes are the persisted form of cutouts. They are stored with the parent rather than as free
/// geometry so that a net area is never assembled from two records that could drift apart.
public struct PolygonGeometry: Codable, Hashable, Sendable {
    public var outer: PolygonRing
    /// Inner rings, subtracted from the outer area. Each must lie inside `outer`.
    public var holes: [PolygonRing]

    public init(outer: PolygonRing, holes: [PolygonRing] = []) {
        self.outer = outer
        self.holes = holes
    }

    public var bounds: PDFRect? { outer.bounds }
}

/// A circular arc in page space (spec 12.12).
public struct ArcGeometry: Codable, Hashable, Sendable {
    public var center: PDFPoint
    /// Radius in PDF points.
    public var radius: Double
    /// Start angle in radians, measured counter-clockwise from the page-space +x axis.
    public var startAngle: Double
    /// Signed sweep in radians. Negative sweeps run clockwise.
    public var sweepAngle: Double

    public init(center: PDFPoint, radius: Double, startAngle: Double, sweepAngle: Double) {
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.sweepAngle = sweepAngle
    }

    /// Arc length in PDF points: `radius * |sweep|` (spec 12.12).
    public var pdfArcLength: Double { radius * Swift.abs(sweepAngle) }

    public var startPoint: PDFPoint {
        PDFPoint(
            x: center.x + radius * Foundation.cos(startAngle),
            y: center.y + radius * Foundation.sin(startAngle)
        )
    }

    public var endPoint: PDFPoint {
        let angle = startAngle + sweepAngle
        return PDFPoint(
            x: center.x + radius * Foundation.cos(angle),
            y: center.y + radius * Foundation.sin(angle)
        )
    }

    /// The circle's four axis points — at 0, π/2, π and 3π/2 about the centre, in that order —
    /// that lie inside the sweep (``BulgeArc/fraction(of:on:)``). An arc's box is its two ends
    /// and these; nothing else on it is further out (W-089).
    ///
    /// The one rule for an arc's extent: ``bounds``, ``PolygonRing/bounds`` on an arc edge, the
    /// measurement engine's `ArcEdge.bounds` and the snap index's arc box all read it.
    public var axisExtremes: [PDFPoint] {
        var result: [PDFPoint] = []
        for quarter in 0..<4 {
            let angle = Double(quarter) * Double.pi / 2
            guard BulgeArc.fraction(of: angle, on: self) != nil else { continue }
            result.append(PDFPoint(
                x: center.x + radius * Foundation.cos(angle),
                y: center.y + radius * Foundation.sin(angle)
            ))
        }
        return result
    }

    /// The arc's own box: ``startPoint``, ``endPoint`` and the ``axisExtremes`` inside the sweep.
    /// The whole circle only for a whole turn. A shallow arc — a 400 pt chord with bulge 0.02 has
    /// r ≈ 5000 pt — was boxed as its circle, a box larger than the sheet (W-087, W-089).
    public var bounds: PDFRect {
        var minX = Swift.min(startPoint.x, endPoint.x), maxX = Swift.max(startPoint.x, endPoint.x)
        var minY = Swift.min(startPoint.y, endPoint.y), maxY = Swift.max(startPoint.y, endPoint.y)
        for point in axisExtremes {
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }
        return PDFRect(corner: PDFPoint(x: minX, y: minY), opposite: PDFPoint(x: maxX, y: maxY))
    }
}

/// A full circle in page space (spec 12.11).
public struct CircleGeometry: Codable, Hashable, Sendable {
    public var center: PDFPoint
    /// Radius in PDF points.
    public var radius: Double

    public init(center: PDFPoint, radius: Double) {
        self.center = center
        self.radius = radius
    }

    public var pdfArea: Double { Double.pi * radius * radius }

    public var bounds: PDFRect {
        PDFRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// One placed count symbol (spec 12.13).
public struct CountPoint: Codable, Hashable, Sendable {
    public var id: CountPointID
    /// Position in page space.
    public var position: PDFPoint
    /// Position in the group's sequential numbering, when numbering is switched on. 1-based.
    public var sequenceNumber: Int?
    /// The count group this point belongs to.
    public var groupID: CountGroupID?
    /// The symbol drawn at this point.
    public var symbolID: SymbolID?

    public init(
        id: CountPointID,
        position: PDFPoint,
        sequenceNumber: Int? = nil,
        groupID: CountGroupID? = nil,
        symbolID: SymbolID? = nil
    ) {
        self.id = id
        self.position = position
        self.sequenceNumber = sequenceNumber
        self.groupID = groupID
        self.symbolID = symbolID
    }
}

/// Everything a measurement can be made of, in canonical PDF page space (spec 12).
///
/// This is a struct with parallel collections rather than an enum of shapes. A single takeoff
/// markup routinely mixes kinds — a slab polygon with an arc edge, an area with count points
/// dropped inside it — and an enum would force those into separate records that can drift apart.
/// Every collection is empty for a measurement that does not use it.
///
/// All coordinates are PDF points: 72 per inch, bottom-left origin, no zoom, no screen scale.
public struct MeasurementGeometry: Codable, Hashable, Sendable {
    /// The page these coordinates belong to. Geometry never spans pages.
    public var pageID: PageID
    /// Free points: polyline vertices for Length/Polylength, the three points of a
    /// Three-Point Circle, the three points of an Angle.
    public var points: [PDFPoint]
    /// Arc segments of the free-point chain (NL-MEASURE-05, ADR-0030 §5), in the same convention
    /// as ``PolygonRing/bulges``: `pointBulges[i]` bends the edge from `points[i]` to
    /// `points[i + 1]`; one entry per point, the last ignored. `nil` is every edge straight.
    public var pointBulges: [Double]?
    /// Independent segments, for Dimension and multi-segment length tools.
    public var segments: [SegmentGeometry]
    /// Closed areas, with holes for cutouts.
    public var polygons: [PolygonGeometry]
    /// Arcs, for Arc Length and curved edges.
    public var arcs: [ArcGeometry]
    /// Circles, for Radius / Diameter / Ellipse-area tools.
    public var circles: [CircleGeometry]
    /// Count symbol placements.
    public var countPoints: [CountPoint]

    public init(
        pageID: PageID,
        points: [PDFPoint] = [],
        segments: [SegmentGeometry] = [],
        polygons: [PolygonGeometry] = [],
        arcs: [ArcGeometry] = [],
        circles: [CircleGeometry] = [],
        countPoints: [CountPoint] = [],
        pointBulges: [Double]? = nil
    ) {
        self.pageID = pageID
        self.points = points
        self.pointBulges = pointBulges
        self.segments = segments
        self.polygons = polygons
        self.arcs = arcs
        self.circles = circles
        self.countPoints = countPoints
    }

    public var isEmpty: Bool {
        points.isEmpty && segments.isEmpty && polygons.isEmpty
            && arcs.isEmpty && circles.isEmpty && countPoints.isEmpty
    }

    /// True when every coordinate is finite. The engine rejects anything else.
    /// The chain's bulges when they line up with ``points`` and bend at least one edge.
    public var validPointBulges: [Double]? {
        PolygonRing(points: points, isClosed: false, bulges: pointBulges).validBulges
    }

    public var isFinite: Bool {
        points.allSatisfy(\.isFinite)
            && segments.allSatisfy { $0.start.isFinite && $0.end.isFinite }
            && polygons.allSatisfy { polygon in
                polygon.outer.points.allSatisfy(\.isFinite)
                    && polygon.holes.allSatisfy { $0.points.allSatisfy(\.isFinite) }
            }
            && arcs.allSatisfy { $0.center.isFinite && $0.radius.isFinite && $0.startAngle.isFinite && $0.sweepAngle.isFinite }
            && circles.allSatisfy { $0.center.isFinite && $0.radius.isFinite }
            && countPoints.allSatisfy { $0.position.isFinite }
            // Arc segments (ADR-0030 §5): a bulge that is present must be a number.
            && (pointBulges ?? []).allSatisfy(\.isFinite)
            && polygons.allSatisfy { polygon in
                ([polygon.outer] + polygon.holes).allSatisfy { ($0.bulges ?? []).allSatisfy(\.isFinite) }
            }
    }

    /// The largest coordinate magnitude a measurement accepts, in PDF points (QUALITY_BAR 2.5,
    /// ADR-0035). A PDF user-space page cannot legitimately exceed 14 400 units; geometry beyond
    /// `1e7` is a corrupt file or a bad transform, and the engine refuses it with
    /// ``MeasurementError/coordinateOutOfRange`` rather than returning a plausible number.
    public static let coordinateMagnitudeBound: Double = 1e7

    /// True when every point, vertex, centre and radius is at most
    /// ``coordinateMagnitudeBound`` in magnitude. A non-finite value is outside the bound too;
    /// ``isFinite`` is the check that names that case.
    public var isWithinCoordinateBound: Bool {
        let bound = Self.coordinateMagnitudeBound
        func inside(_ point: PDFPoint) -> Bool { Swift.abs(point.x) <= bound && Swift.abs(point.y) <= bound }
        return points.allSatisfy(inside)
            && segments.allSatisfy { inside($0.start) && inside($0.end) }
            && polygons.allSatisfy { polygon in
                ([polygon.outer] + polygon.holes).allSatisfy { $0.points.allSatisfy(inside) }
            }
            && arcs.allSatisfy { inside($0.center) && Swift.abs($0.radius) <= bound }
            && circles.allSatisfy { inside($0.center) && Swift.abs($0.radius) <= bound }
            && countPoints.allSatisfy { inside($0.position) }
    }

    /// The bounding box of everything present as it is drawn, or `nil` when empty: the point
    /// chain with its arc edges, every outer ring with its arc edges, every loose arc's own box
    /// (``ArcGeometry/bounds``, not its whole circle), circles, segments and counts (W-089).
    public var bounds: PDFRect? {
        var boxes: [PDFRect] = []
        if let box = PolygonRing(points: points, isClosed: false, bulges: pointBulges).bounds { boxes.append(box) }
        boxes.append(contentsOf: segments.map(\.bounds))
        boxes.append(contentsOf: polygons.compactMap(\.bounds))
        boxes.append(contentsOf: arcs.map(\.bounds))
        boxes.append(contentsOf: circles.map(\.bounds))
        if let box = PDFRect.boundingBox(of: countPoints.map(\.position)) { boxes.append(box) }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The axis-aligned page-space box an Ellipse Area or Ellipse Cutout is drawn inscribed in:
    /// its circle, else its points (two are opposite corners, more are bounded), else its
    /// segment, else its outer ring; `nil` when it has none of them.
    ///
    /// The one rule (U-093) for the ellipse the child measures (the engine's ellipse
    /// calculator), the hole its parent loses (`TakeoffSession.cutoutRings`) and the ellipse
    /// the canvas draws and the snap index offers (``MarkupRecord/inscribedEllipseBox``). It was
    /// written out three times, the third as the union of every collection, and nothing tied
    /// them together.
    public var ellipseBox: PDFRect? {
        if let circle = circles.first { return circle.bounds }
        if points.count == 2 { return PDFRect(corner: points[0], opposite: points[1]) }
        if points.count > 2 { return PDFRect.boundingBox(of: points) }
        if let segment = segments.first { return segment.bounds }
        return polygons.first?.bounds
    }
}


// MARK: - Arc segments (NL-MEASURE-05, ADR-0030 §5)

/// The exact geometry of one bulged edge.
public enum BulgeArc {

    /// The arc from `start` to `end` with `bulge = tan(θ/4)`, or `nil` for a straight edge (`0`),
    /// a degenerate chord, or a non-finite value.
    ///
    /// Hand geometry: chord `c`, included angle `θ = 4·atan(b)`, radius `r = c / (2·sin(θ/2))`,
    /// and the centre on the chord's perpendicular bisector at `(r − s)` from the chord, on the
    /// left of the edge for a counter-clockwise (positive) arc under half a turn, where the
    /// sagitta `s = |b|·c/2`.
    public static func arc(from start: PDFPoint, to end: PDFPoint, bulge: Double) -> ArcGeometry? {
        guard bulge != 0, bulge.isFinite, start.isFinite, end.isFinite else { return nil }
        let dx = end.x - start.x, dy = end.y - start.y
        let chord = (dx * dx + dy * dy).squareRoot()
        guard chord > 0 else { return nil }
        let theta = 4 * Foundation.atan(bulge)                 // signed included angle
        let radius = chord / (2 * Swift.abs(Foundation.sin(theta / 2)))
        // Distance from the chord midpoint to the centre, signed toward the edge's left.
        let apothem = chord / (2 * Foundation.tan(theta / 2))
        let mx = (start.x + end.x) / 2, my = (start.y + end.y) / 2
        let nx = -dy / chord, ny = dx / chord                 // left normal
        let center = PDFPoint(x: mx + nx * apothem, y: my + ny * apothem)
        let startAngle = Foundation.atan2(start.y - center.y, start.x - center.x)
        return ArcGeometry(center: center, radius: radius, startAngle: startAngle, sweepAngle: theta)
    }

    /// The signed area between the chord and the arc, in square page units: positive when the arc
    /// bends to the right of the edge (outward for a counter-clockwise ring). `r²/2 · (θ − sin θ)`.
    public static func segmentArea(from start: PDFPoint, to end: PDFPoint, bulge: Double) -> Double {
        guard let arc = arc(from: start, to: end, bulge: bulge) else { return 0 }
        let theta = Swift.abs(arc.sweepAngle)
        let magnitude = arc.radius * arc.radius / 2 * thetaMinusSine(theta)
        return bulge > 0 ? magnitude : -magnitude
    }

    /// `θ − sin θ` for `θ ≥ 0`, without cancellation (ADR-0030 §5.7).
    ///
    /// Written as the difference, a nearly straight arc loses about `log10(6/θ²)` digits while
    /// `r² ~ (c/θ)²` grows, so the segment's error grows like `c²·ε/θ`: at a bulge of 1e-7 on a
    /// 100 pt chord it was 0.24 % off, and below about 5e-9 it was zero. Below `θ = 1` the Taylor
    /// series `θ³/3! − θ⁵/5! + θ⁷/7! − …` is summed instead: every term is exact to a rounding, and
    /// after `θ¹⁹/19!` the next term is below `θ³/6 · 5e-17` for `θ < 1`. At and above `θ = 1` the
    /// difference loses at most a factor `θ / (θ − sin θ) ≤ 6.3` of one rounding.
    static func thetaMinusSine(_ theta: Double) -> Double {
        guard theta < 1 else { return theta - Foundation.sin(theta) }
        let square = theta * theta
        var term = theta * square / 6            // θ³/3!
        var sum = term
        var k = 2.0
        while k <= 9 {                            // up to θ¹⁹/19!
            term *= -square / ((2 * k) * (2 * k + 1))
            sum += term
            k += 1
        }
        return sum
    }

    /// The most equal chords one arc is ever cut into (``chordSteps(radius:sweep:tolerance:minimum:)``),
    /// so a hostile bulge cannot turn one edge into millions of points. Every arc a page can
    /// carry needs fewer: a whole circle of r = 8.7e5 pt needs 65 536 at 1e-3 pt. Past the cap
    /// the chords are longer than asked, and ``chordSagitta(radius:sweep:tolerance:minimum:)`` says by
    /// how much.
    public static let maximumChordSteps = 65_536

    /// The number of equal steps that cut an arc of `radius` spanning `sweep` radians into
    /// chords of sagitta at most `tolerance` — the one step rule for every reader that
    /// flattens or samples an arc (V-084).
    ///
    /// A chord spanning `φ` has sagitta `r·(1 − cos(φ/2)) = 2r·sin²(φ/4)`, so the widest step
    /// is `φ = 4·asin(√(t / 2r))`, written that way because `1 − t/r` cancels to nothing at a
    /// large radius. The rule had a floor of 1e-3 rad besides, whose chord has sagitta
    /// `r·1.25e-7`: above 1e-3 pt past r = 8000 pt, so a gently bent edge (a 1000 pt chord with
    /// bulge 0.001 has r = 250 000 pt) was cut into 4 chords of sagitta 0.031 pt where 23 meet
    /// the tolerance. Clamped to `[minimum, maximumChordSteps]`.
    public static func chordSteps(radius: Double, sweep: Double, tolerance: Double, minimum: Int = 2) -> Int {
        let theta = Swift.abs(sweep)
        guard theta.isFinite, radius.isFinite, radius > 0, tolerance > 0 else { return minimum }
        let half = Swift.min(1, (tolerance / (2 * radius)).squareRoot())
        let widest = 4 * Foundation.asin(half)
        let wanted = (theta / widest).rounded(.up)
        guard wanted.isFinite else { return maximumChordSteps }
        return Swift.max(minimum, Int(Swift.min(Double(maximumChordSteps), wanted)))
    }

    /// The largest sagitta of the chords ``chordSteps(radius:sweep:tolerance:minimum:)`` cuts
    /// the arc into: `r·(1 − cos(θ/2n))`, written `2r·sin²(θ/4n)`. At most `tolerance`, unless
    /// the arc needed more than ``maximumChordSteps``.
    public static func chordSagitta(radius: Double, sweep: Double, tolerance: Double, minimum: Int = 2) -> Double {
        let steps = chordSteps(radius: radius, sweep: sweep, tolerance: tolerance, minimum: minimum)
        let quarterStep = Swift.abs(sweep) / (4 * Double(steps))
        let sine = Foundation.sin(quarterStep)
        return 2 * radius * sine * sine
    }

    /// Points along the arc, excluding `start` and including `end`, no chord's sagitta above
    /// `tolerance` page units — for drawing and for the booleans that need a polygon. (Past
    /// ``maximumChordSteps`` the chords are ``chordSagitta(radius:sweep:tolerance:minimum:)``.)
    public static func flattened(from start: PDFPoint, to end: PDFPoint, bulge: Double, tolerance: Double) -> [PDFPoint] {
        guard let arc = arc(from: start, to: end, bulge: bulge), tolerance > 0 else { return [end] }
        let steps = chordSteps(radius: arc.radius, sweep: arc.sweepAngle, tolerance: tolerance)
        var result: [PDFPoint] = []
        result.reserveCapacity(steps)
        for step in 1..<steps {
            let angle = arc.startAngle + arc.sweepAngle * Double(step) / Double(steps)
            result.append(PDFPoint(x: arc.center.x + arc.radius * Foundation.cos(angle), y: arc.center.y + arc.radius * Foundation.sin(angle)))
        }
        result.append(end)
        return result
    }
}

extension PolygonRing {

    /// The largest chord sagitta ``flattened(tolerance:)`` leaves on this ring: `0` without
    /// arcs, at most `tolerance` for every arc under ``BulgeArc/maximumChordSteps`` chords, and
    /// what the capped chords really reach past it — the figure a caller states as the error of
    /// the chords (V-084).
    public func flatteningSagitta(tolerance: Double) -> Double {
        guard hasArcs else { return 0 }
        return bulgedEdges.reduce(0.0) { largest, edge in
            guard edge.bulge != 0, let arc = BulgeArc.arc(from: edge.start, to: edge.end, bulge: edge.bulge) else { return largest }
            return Swift.max(largest, BulgeArc.chordSagitta(radius: arc.radius, sweep: arc.sweepAngle, tolerance: tolerance))
        }
    }

    /// The ring with every arc edge replaced by chords of at most `tolerance` sagitta; the ring
    /// itself when it has no arcs.
    public func flattened(tolerance: Double) -> PolygonRing {
        guard let bulges = validBulges else { return self }
        var result: [PDFPoint] = []
        let count = points.count
        for index in 0..<count {
            let start = points[index]
            result.append(start)
            let isLastOpen = !isClosed && index == count - 1
            guard !isLastOpen else { break }
            let end = points[(index + 1) % count]
            if bulges[index] != 0 {
                result.append(contentsOf: BulgeArc.flattened(from: start, to: end, bulge: bulges[index], tolerance: tolerance).dropLast())
            }
        }
        return PolygonRing(points: result, isClosed: isClosed)
    }

    /// The exact signed area of a closed ring with arc edges: the shoelace over the vertices plus
    /// every edge's signed circular segment. Positive for a counter-clockwise ring.
    ///
    /// The shoelace is origin-shifted to the first vertex (QUALITY_BAR §2.2 rule 1) and the terms
    /// are added with Neumaier compensation (ADR-0030 §5.7). Summed over raw page coordinates, the
    /// products at an A0 sheet position (x ≈ 3000 pt) round at about 1e-9 pt², which put the area
    /// of the rounded-corner fixture 4.8e-12 off at (3000.37, 2000.61) and 1.5e-10 off at
    /// (14000.37, 13000.61), and made Split Area refuse valid splits of small arc areas.
    public var exactSignedArea: Double {
        let count = points.count
        guard count >= 2 else { return 0 }
        let origin = points[0]
        var sum = 0.0
        var compensation = 0.0
        func add(_ value: Double) {
            let total = sum + value
            compensation += Swift.abs(sum) >= Swift.abs(value) ? (sum - total) + value : (value - total) + sum
            sum = total
        }
        for index in 0..<count {
            let a = points[index], b = points[(index + 1) % count]
            let ax = a.x - origin.x, ay = a.y - origin.y
            let bx = b.x - origin.x, by = b.y - origin.y
            add((ax * by - bx * ay) / 2)
        }
        if let bulges = validBulges, isClosed {
            for index in 0..<count where bulges[index] != 0 {
                add(BulgeArc.segmentArea(from: points[index], to: points[(index + 1) % count], bulge: bulges[index]))
            }
        }
        return sum + compensation
    }
}
