import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine

/// An independent, deliberately naive reimplementation of `SNAP_CONTRACT` 13.7, written from the
/// specification rather than from the engine's source.
///
/// `QUALITY_BAR` S1 requires the engine's winner to equal the winner computed by "a brute-force
/// scorer in the test target that evaluates every primitive on the page". This is that scorer.
/// It walks every entry in the index — no R-tree, no radius pre-filter, no truncation, no
/// caching — enumerates the derived targets by hand, applies the score formula as written, and
/// sorts by the documented total order.
///
/// It shares nothing with the engine except the frozen contract types and the index it is
/// handed. Where it and the engine disagree, one of them is wrong, and that is the point.
///
/// Curves are covered as well as straight edges (CR-43): circles, arcs and cubics contribute
/// their own features, and every pair of curves of different primitives is intersected — by
/// closed form where one exists and by dense sampling with bisection or by box subdivision
/// where it does not. The numerics here were written from the definitions, not copied from
/// the engine's solver.
struct SnapBruteForceReference {

    struct Candidate: Hashable {
        var kind: SnapKind
        var position: PDFPoint
        var primitiveID: UInt64
        var secondaryPrimitiveID: UInt64
        var score: Double
        var priority: Int
        var component: Int
    }

    let settings: SnapSettings
    let weights: SnapScoringWeights

    /// Crossings are cursor-independent, so one index's crossings are computed once per
    /// reference instance and reused across a sweep. Instance state, not shared state: the
    /// golden tests run in parallel.
    private var memoKey: (generation: UInt64, count: Int)?
    private var memoCrossings: [Raw] = []

    init(settings: SnapSettings, weights: SnapScoringWeights = .standard) {
        self.settings = settings
        self.weights = weights
    }

    /// The winner at `cursor`, or `nil` when nothing is inside the radius.
    mutating func winner(
        in index: SnapIndex,
        cursor: PDFPoint,
        zoom: Double,
        anchor: PDFPoint? = nil,
        activeLayerID: String? = nil
    ) -> Candidate? {
        ranked(
            in: index, cursor: cursor, zoom: zoom, anchor: anchor, activeLayerID: activeLayerID
        ).first
    }

    struct Raw {
        var kind: SnapKind
        var point: PDFPoint
        var id: UInt64
        var second: UInt64
        var confidence: Float
        var layerID: String?
        var component: Int
    }

    mutating func ranked(
        in index: SnapIndex,
        cursor: PDFPoint,
        zoom: Double,
        anchor: PDFPoint? = nil,
        activeLayerID: String? = nil
    ) -> [Candidate] {
        let radiusViewPoints = settings.clampedRadiusPixels(settings.defaultPixels)
        let radius = radiusViewPoints / zoom

        var entries: [SnapIndexEntry] = []
        if index.availability.allowsVectorCandidates {
            entries += index.allEntries(in: .vector)
        }
        entries += index.allEntries(in: .markup)
        entries += index.allEntries(in: .boundary)

        var raw: [Raw] = []
        for entry in entries {
            raw += Self.features(of: entry, cursor: cursor, anchor: anchor)
        }

        // Intersections between every pair of curves of different primitives on the page.
        // They do not depend on the cursor, so one index's crossings are computed once.
        raw += crossings(of: entries, index: index)

        // Grid, which has no primitive behind it.
        if settings.enabledKinds.contains(.grid), settings.gridSpacingPoints > 0 {
            let origin = index.page.visibleBox.standardized
            let gx = origin.minX
                + ((cursor.x - origin.minX) / settings.gridSpacingPoints).rounded()
                * settings.gridSpacingPoints
            let gy = origin.minY
                + ((cursor.y - origin.minY) / settings.gridSpacingPoints).rounded()
                * settings.gridSpacingPoints
            raw.append(Raw(kind: .grid, point: PDFPoint(x: gx, y: gy), id: 0, second: 0,
                           confidence: 1.0, layerID: nil, component: 0))
        }

        var candidates: [Candidate] = []
        for item in raw {
            guard settings.enabledKinds.contains(item.kind) else { continue }
            if item.kind.requiresVectorContent, !index.availability.allowsVectorCandidates {
                continue
            }
            let distance = item.point.distance(to: cursor)
            guard distance.isFinite, distance <= radius else { continue }

            let onActiveLayer: Bool
            if let activeLayerID {
                onActiveLayer = item.layerID == nil || item.layerID == activeLayerID
            } else {
                onActiveLayer = true
            }
            let priority = settings.priority(of: item.kind)
            let score = Double(priority) * weights.typePriority
                + distance * zoom * weights.screenDistancePerViewPoint
                + Double(1 - item.confidence) * weights.lowConfidence
                + (onActiveLayer ? 0 : weights.inactiveLayer)
            candidates.append(
                Candidate(
                    kind: item.kind,
                    position: item.point,
                    primitiveID: item.id,
                    secondaryPrimitiveID: item.second,
                    score: score,
                    priority: priority,
                    component: item.component
                )
            )
        }

        // The documented total order. Scores compare on a grid of the equality epsilon — two
        // scores in one cell are equal — because "within epsilon of each other" is not
        // transitive and does not order anything (CR-45).
        let epsilon = weights.scoreEqualityEpsilon
        func cell(_ score: Double) -> Double {
            epsilon > 0 ? (score / epsilon).rounded() : score
        }
        candidates.sort { a, b in
            if cell(a.score) != cell(b.score) { return cell(a.score) < cell(b.score) }
            if a.priority != b.priority { return a.priority < b.priority }
            if a.primitiveID != b.primitiveID { return a.primitiveID < b.primitiveID }
            if a.secondaryPrimitiveID != b.secondaryPrimitiveID {
                return a.secondaryPrimitiveID < b.secondaryPrimitiveID
            }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.position.x != b.position.x { return a.position.x < b.position.x }
            if a.position.y != b.position.y { return a.position.y < b.position.y }
            return a.component < b.component
        }

        // Positional de-duplication, matching the documented behaviour: one point of one kind
        // is one snap target however many primitives produced it.
        var seen = Set<String>()
        var result: [Candidate] = []
        for candidate in candidates {
            let key = "\(candidate.kind.rawValue)"
                + "|\(Int64((candidate.position.x / 1e-6).rounded()))"
                + "|\(Int64((candidate.position.y / 1e-6).rounded()))"
            if seen.insert(key).inserted { result.append(candidate) }
        }
        return result
    }

    // MARK: - Features of one primitive

    static func features(of entry: SnapIndexEntry, cursor: PDFPoint, anchor: PDFPoint?) -> [Raw] {
        let kinds = entry.kindSet
        let confidence = entry.primitive.confidence
        let layerID = entry.primitive.layerID
        var raw: [Raw] = []
        func add(_ kind: SnapKind, _ point: PDFPoint, component: Int = 0) {
            raw.append(Raw(kind: kind, point: point, id: entry.id, second: 0,
                           confidence: confidence, layerID: layerID, component: component))
        }
        func edgeFeatures(_ s: SegmentGeometry, component: Int, midpoint: Bool) {
            if midpoint { add(kinds.edgeMidpoint, Self.midpoint(s), component: component) }
            add(kinds.onEdge, Self.nearest(cursor, on: s), component: component)
            if let anchor, let foot = Self.perpendicularFoot(anchor, on: s) {
                add(kinds.perpendicular, foot, component: component)
            }
        }

        switch entry.primitive.geometry {
        case .point(let p):
            add(kinds.vertex, p)

        case .segment(let s):
            add(kinds.vertex, s.start)
            add(kinds.vertex, s.end, component: 1)
            edgeFeatures(s, component: 0, midpoint: true)

        case .polyline(let points, let isClosed):
            guard points.count >= 2 else { break }
            for (i, p) in points.enumerated() { add(kinds.vertex, p, component: i) }
            let edgeCount = isClosed ? points.count : points.count - 1
            for i in 0..<edgeCount {
                let s = SegmentGeometry(start: points[i], end: points[(i + 1) % points.count])
                edgeFeatures(s, component: i, midpoint: true)
            }
            // Only a parallelogram has a centre: the point where its diagonals bisect each
            // other. The bounding-box centre of any other closed outline is not on it (CR-40).
            if isClosed, points.count == 4 {
                let first = PDFPoint(x: (points[0].x + points[2].x) / 2, y: (points[0].y + points[2].y) / 2)
                let second = PDFPoint(x: (points[1].x + points[3].x) / 2, y: (points[1].y + points[3].y) / 2)
                let extent = Swift.max(
                    1,
                    points.map(\.x).max()! - points.map(\.x).min()!,
                    points.map(\.y).max()! - points.map(\.y).min()!
                )
                if first.distance(to: second) <= 1e-9 * extent {
                    add(kinds.center, first)
                }
            }

        case .rectangle(let rect):
            let r = rect.standardized
            let corners = [
                PDFPoint(x: r.minX, y: r.minY), PDFPoint(x: r.maxX, y: r.minY),
                PDFPoint(x: r.maxX, y: r.maxY), PDFPoint(x: r.minX, y: r.maxY)
            ]
            for (i, corner) in corners.enumerated() { add(kinds.vertex, corner, component: i) }
            for i in 0..<4 {
                edgeFeatures(SegmentGeometry(start: corners[i], end: corners[(i + 1) % 4]),
                             component: i, midpoint: true)
            }
            add(kinds.center, PDFPoint(x: (r.minX + r.maxX) / 2, y: (r.minY + r.maxY) / 2))

        case .cubicCurve(let p0, let p1, let p2, let p3):
            raw += cubicFeatures(p0, p1, p2, p3, kinds: kinds, entry: entry, cursor: cursor, anchor: anchor)

        case .quadraticCurve(let start, let control, let end):
            // Degree elevation: the same curve as a cubic.
            let p1 = PDFPoint(x: start.x + 2.0 / 3.0 * (control.x - start.x), y: start.y + 2.0 / 3.0 * (control.y - start.y))
            let p2 = PDFPoint(x: end.x + 2.0 / 3.0 * (control.x - end.x), y: end.y + 2.0 / 3.0 * (control.y - end.y))
            raw += cubicFeatures(start, p1, p2, end, kinds: kinds, entry: entry, cursor: cursor, anchor: anchor)

        case .circle(let circle):
            add(kinds.center, circle.center)
            for i in 0..<4 {
                add(kinds.quadrant, Self.pointOnCircle(circle.center, circle.radius, Double(i) * Double.pi / 2), component: i)
            }
            if let nearest = Self.nearestOnCircle(circle.center, circle.radius, to: cursor) {
                add(kinds.onEdge, nearest)
            }
            if let anchor {
                for (i, point) in Self.tangentPoints(circle.center, circle.radius, from: anchor).enumerated() {
                    add(kinds.tangent, point, component: i)
                }
            }

        case .ellipticalArc(let arc):
            add(kinds.center, arc.center)
            add(kinds.vertex, arc.startPoint)
            add(kinds.vertex, arc.endPoint, component: 1)
            add(kinds.edgeMidpoint, Self.pointOnCircle(arc.center, arc.radius, arc.startAngle + arc.sweepAngle / 2))
            for i in 0..<4 {
                let angle = Double(i) * Double.pi / 2
                if Self.arcContains(arc, angle) {
                    add(kinds.quadrant, Self.pointOnCircle(arc.center, arc.radius, angle), component: i)
                }
            }
            if let nearest = Self.nearestOnArc(arc, to: cursor) {
                add(kinds.onEdge, nearest)
            }
            if let anchor {
                for (i, point) in Self.tangentPoints(arc.center, arc.radius, from: anchor).enumerated()
                where Self.arcContains(arc, Self.angle(of: point, about: arc.center)) {
                    add(kinds.tangent, point, component: i)
                }
            }
        }
        return raw
    }

    static func cubicFeatures(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint,
        kinds: SnapEntryKindSet, entry: SnapIndexEntry, cursor: PDFPoint, anchor: PDFPoint?
    ) -> [Raw] {
        var raw: [Raw] = []
        func add(_ kind: SnapKind, _ point: PDFPoint, component: Int = 0) {
            raw.append(Raw(kind: kind, point: point, id: entry.id, second: 0,
                           confidence: entry.primitive.confidence,
                           layerID: entry.primitive.layerID, component: component))
        }
        add(kinds.vertex, p0)
        add(kinds.vertex, p3, component: 1)
        // The arc-length midpoint (BH-663), computed independently of the engine: adaptive
        // Simpson for the length and Newton on the length function for the parameter.
        add(kinds.edgeMidpoint, Self.bezier(p0, p1, p2, p3, Self.arcLengthMidpoint(p0, p1, p2, p3)))
        let t = Self.nearestParameter(p0, p1, p2, p3, to: cursor)
        add(kinds.onEdge, Self.bezier(p0, p1, p2, p3, t))
        if let anchor {
            for u in Self.tangentParameters(p0, p1, p2, p3, from: anchor) {
                add(kinds.tangent, Self.bezier(p0, p1, p2, p3, u))
            }
        }
        return raw
    }

    // MARK: - Crossings

    enum Curve {
        case line(PDFPoint, PDFPoint)
        case cubic(PDFPoint, PDFPoint, PDFPoint, PDFPoint)
        case circle(PDFPoint, Double)
        case arc(ArcGeometry)

        var terminals: [PDFPoint] {
            switch self {
            case .line(let a, let b): [a, b]
            case .cubic(let p0, _, _, let p3): [p0, p3]
            case .circle: []
            case .arc(let arc): [arc.startPoint, arc.endPoint]
            }
        }

        /// A unit tangent at `point`, which is assumed to lie on the curve.
        func tangent(at point: PDFPoint) -> (dx: Double, dy: Double)? {
            switch self {
            case .line(let a, let b):
                return SnapBruteForceReference.unit(b.x - a.x, b.y - a.y)
            case .cubic(let p0, let p1, let p2, let p3):
                let t = SnapBruteForceReference.nearestParameter(p0, p1, p2, p3, to: point)
                let d = SnapBruteForceReference.bezierDerivative(p0, p1, p2, p3, t)
                return SnapBruteForceReference.unit(d.dx, d.dy)
            case .circle(let centre, _):
                return SnapBruteForceReference.unit(-(point.y - centre.y), point.x - centre.x)
            case .arc(let arc):
                return SnapBruteForceReference.unit(-(point.y - arc.center.y), point.x - arc.center.x)
            }
        }
    }

    struct OwnedCurve {
        let curve: Curve
        let id: UInt64
        let confidence: Float
        let layerID: String?
        let kinds: SnapEntryKindSet
    }

    static func allCurves(_ entries: [SnapIndexEntry]) -> [OwnedCurve] {
        var curves: [OwnedCurve] = []
        for entry in entries {
            func add(_ curve: Curve) {
                curves.append(OwnedCurve(curve: curve, id: entry.id, confidence: entry.primitive.confidence,
                                         layerID: entry.primitive.layerID, kinds: entry.kindSet))
            }
            switch entry.primitive.geometry {
            case .point:
                continue
            case .segment(let s):
                add(.line(s.start, s.end))
            case .polyline(let points, let isClosed):
                guard points.count >= 2 else { continue }
                let edgeCount = isClosed ? points.count : points.count - 1
                for i in 0..<edgeCount { add(.line(points[i], points[(i + 1) % points.count])) }
            case .rectangle(let rect):
                let r = rect.standardized
                let corners = [
                    PDFPoint(x: r.minX, y: r.minY), PDFPoint(x: r.maxX, y: r.minY),
                    PDFPoint(x: r.maxX, y: r.maxY), PDFPoint(x: r.minX, y: r.maxY)
                ]
                for i in 0..<4 { add(.line(corners[i], corners[(i + 1) % 4])) }
            case .cubicCurve(let p0, let p1, let p2, let p3):
                add(.cubic(p0, p1, p2, p3))
            case .quadraticCurve(let start, let control, let end):
                let p1 = PDFPoint(x: start.x + 2.0 / 3.0 * (control.x - start.x), y: start.y + 2.0 / 3.0 * (control.y - start.y))
                let p2 = PDFPoint(x: end.x + 2.0 / 3.0 * (control.x - end.x), y: end.y + 2.0 / 3.0 * (control.y - end.y))
                add(.cubic(start, p1, p2, end))
            case .circle(let c):
                add(.circle(c.center, c.radius))
            case .ellipticalArc(let arc):
                add(.arc(arc))
            }
        }
        return curves
    }

    mutating func crossings(of entries: [SnapIndexEntry], index: SnapIndex) -> [Raw] {
        let key = (index.generation, entries.count)
        if let cached = memoKey, cached == key { return memoCrossings }
        let curves = Self.allCurves(entries)
        var raw: [Raw] = []
        if curves.count >= 2 {
            for i in 0..<(curves.count - 1) {
                for j in (i + 1)..<curves.count {
                    let a = curves[i]
                    let b = curves[j]
                    guard a.id != b.id else { continue }
                    for point in Self.intersections(a.curve, b.curve) {
                        // A crossing at a terminal point of either curve is a corner or a
                        // T-junction: the endpoint candidate already covers that coordinate.
                        let terminals = a.curve.terminals + b.curve.terminals
                        if terminals.contains(where: { $0.distance(to: point) <= 1e-9 }) { continue }
                        // S5: below half a degree the crossing is refused.
                        guard let ta = a.curve.tangent(at: point), let tb = b.curve.tangent(at: point) else { continue }
                        let sine = Swift.abs(ta.dx * tb.dy - ta.dy * tb.dx)
                        guard sine >= Foundation.sin(0.5 * Double.pi / 180) else { continue }
                        let lower = Swift.min(a.id, b.id)
                        let upper = Swift.max(a.id, b.id)
                        let owner = a.id == lower ? a : b
                        raw.append(Raw(kind: owner.kinds.intersection, point: point, id: lower, second: upper,
                                       confidence: Swift.min(a.confidence, b.confidence),
                                       layerID: owner.layerID, component: 0))
                    }
                }
            }
        }
        memoKey = key
        memoCrossings = raw
        return raw
    }

    /// Every crossing of two curves, each on both curves to well within `1e-9`.
    static func intersections(_ a: Curve, _ b: Curve) -> [PDFPoint] {
        switch (a, b) {
        case (.line(let a0, let a1), .line(let b0, let b1)):
            return intersect(SegmentGeometry(start: a0, end: a1), SegmentGeometry(start: b0, end: b1)).map { [$0] } ?? []
        case (.line(let a0, let a1), .cubic(let p0, let p1, let p2, let p3)),
             (.cubic(let p0, let p1, let p2, let p3), .line(let a0, let a1)):
            return lineCubic(a0, a1, p0, p1, p2, p3)
        case (.line(let a0, let a1), .circle(let c, let r)), (.circle(let c, let r), .line(let a0, let a1)):
            return lineCircle(a0, a1, c, r)
        case (.line(let a0, let a1), .arc(let arc)), (.arc(let arc), .line(let a0, let a1)):
            return lineCircle(a0, a1, arc.center, arc.radius).filter { arcContains(arc, angle(of: $0, about: arc.center)) }
        case (.circle(let c1, let r1), .circle(let c2, let r2)):
            return circleCircle(c1, r1, c2, r2)
        case (.circle(let c, let r), .arc(let arc)), (.arc(let arc), .circle(let c, let r)):
            return circleCircle(c, r, arc.center, arc.radius).filter { arcContains(arc, angle(of: $0, about: arc.center)) }
        case (.arc(let a1), .arc(let a2)):
            return circleCircle(a1.center, a1.radius, a2.center, a2.radius).filter {
                arcContains(a1, angle(of: $0, about: a1.center)) && arcContains(a2, angle(of: $0, about: a2.center))
            }
        case (.cubic(let p0, let p1, let p2, let p3), .circle(let c, let r)),
             (.circle(let c, let r), .cubic(let p0, let p1, let p2, let p3)):
            return cubicCircle(p0, p1, p2, p3, c, r)
        case (.cubic(let p0, let p1, let p2, let p3), .arc(let arc)),
             (.arc(let arc), .cubic(let p0, let p1, let p2, let p3)):
            return cubicCircle(p0, p1, p2, p3, arc.center, arc.radius).filter { arcContains(arc, angle(of: $0, about: arc.center)) }
        case (.cubic(let a0, let a1, let a2, let a3), .cubic(let b0, let b1, let b2, let b3)):
            return cubicCubic((a0, a1, a2, a3), (b0, b1, b2, b3))
        }
    }

    // MARK: - Hand-written geometry: straight

    static func midpoint(_ s: SegmentGeometry) -> PDFPoint {
        PDFPoint(x: (s.start.x + s.end.x) / 2, y: (s.start.y + s.end.y) / 2)
    }

    static func nearest(_ q: PDFPoint, on s: SegmentGeometry) -> PDFPoint {
        let dx = s.end.x - s.start.x
        let dy = s.end.y - s.start.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return s.start }
        var t = ((q.x - s.start.x) * dx + (q.y - s.start.y) * dy) / squared
        t = Swift.min(1, Swift.max(0, t))
        return PDFPoint(x: s.start.x + t * dx, y: s.start.y + t * dy)
    }

    static func perpendicularFoot(_ q: PDFPoint, on s: SegmentGeometry) -> PDFPoint? {
        let dx = s.end.x - s.start.x
        let dy = s.end.y - s.start.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return nil }
        let t = ((q.x - s.start.x) * dx + (q.y - s.start.y) * dy) / squared
        return PDFPoint(x: s.start.x + t * dx, y: s.start.y + t * dy)
    }

    /// Segment-segment intersection, with an independent parallel refusal at the
    /// `QUALITY_BAR` S5 floor of half a degree.
    static func intersect(_ a: SegmentGeometry, _ b: SegmentGeometry) -> PDFPoint? {
        let ax = a.end.x - a.start.x
        let ay = a.end.y - a.start.y
        let bx = b.end.x - b.start.x
        let by = b.end.y - b.start.y
        let aLength = (ax * ax + ay * ay).squareRoot()
        let bLength = (bx * bx + by * by).squareRoot()
        guard aLength > 0, bLength > 0 else { return nil }
        let cross = ax * by - ay * bx
        let sine = Swift.abs(cross) / (aLength * bLength)
        guard sine >= Foundation.sin(0.5 * Double.pi / 180) else { return nil }

        let dx = b.start.x - a.start.x
        let dy = b.start.y - a.start.y
        let t = (dx * by - dy * bx) / cross
        let u = (dx * ay - dy * ax) / cross
        guard t >= -1e-12, t <= 1 + 1e-12, u >= -1e-12, u <= 1 + 1e-12 else { return nil }
        return PDFPoint(x: a.start.x + t * ax, y: a.start.y + t * ay)
    }

    static func unit(_ dx: Double, _ dy: Double) -> (dx: Double, dy: Double)? {
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-300 else { return nil }
        return (dx / length, dy / length)
    }

    // MARK: - Hand-written geometry: circles and arcs

    static func pointOnCircle(_ centre: PDFPoint, _ radius: Double, _ angle: Double) -> PDFPoint {
        PDFPoint(x: centre.x + radius * Foundation.cos(angle), y: centre.y + radius * Foundation.sin(angle))
    }

    static func angle(of point: PDFPoint, about centre: PDFPoint) -> Double {
        Foundation.atan2(point.y - centre.y, point.x - centre.x)
    }

    /// The angle in `[0, 2π)`.
    static func wrap(_ angle: Double) -> Double {
        let twoPi = 2 * Double.pi
        var value = angle.truncatingRemainder(dividingBy: twoPi)
        if value < 0 { value += twoPi }
        return value
    }

    /// `angle` is on the arc when, measured from the start in the sweep's direction, it is
    /// no farther than the sweep. Inclusive at both ends, as a quadrant on an arc's end is
    /// still on the arc.
    static func arcContains(_ arc: ArcGeometry, _ angle: Double) -> Bool {
        if Swift.abs(arc.sweepAngle) >= 2 * Double.pi { return true }
        let start = wrap(arc.startAngle)
        let travelled = wrap(arc.sweepAngle >= 0 ? angle - start : start - angle)
        return travelled <= Swift.abs(arc.sweepAngle) + 1e-12
    }

    static func nearestOnCircle(_ centre: PDFPoint, _ radius: Double, to q: PDFPoint) -> PDFPoint? {
        guard let direction = unit(q.x - centre.x, q.y - centre.y) else { return nil }
        return PDFPoint(x: centre.x + direction.dx * radius, y: centre.y + direction.dy * radius)
    }

    static func nearestOnArc(_ arc: ArcGeometry, to q: PDFPoint) -> PDFPoint? {
        guard let radial = nearestOnCircle(arc.center, arc.radius, to: q) else { return nil }
        if arcContains(arc, angle(of: q, about: arc.center)) { return radial }
        let start = arc.startPoint
        let end = arc.endPoint
        return start.distance(to: q) <= end.distance(to: q) ? start : end
    }

    /// The two points where tangents from `anchor` touch the circle; none from inside it.
    static func tangentPoints(_ centre: PDFPoint, _ radius: Double, from anchor: PDFPoint) -> [PDFPoint] {
        let dx = anchor.x - centre.x
        let dy = anchor.y - centre.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > radius + 1e-12, radius > 0 else { return [] }
        let base = Foundation.atan2(dy, dx)
        let opening = Foundation.acos(Swift.min(1, Swift.max(-1, radius / distance)))
        return [pointOnCircle(centre, radius, base + opening), pointOnCircle(centre, radius, base - opening)]
    }

    static func lineCircle(_ a: PDFPoint, _ b: PDFPoint, _ centre: PDFPoint, _ radius: Double) -> [PDFPoint] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let fx = a.x - centre.x
        let fy = a.y - centre.y
        let qa = dx * dx + dy * dy
        guard qa > 0, radius > 0 else { return [] }
        let qb = 2 * (fx * dx + fy * dy)
        let qc = fx * fx + fy * fy - radius * radius
        let discriminant = qb * qb - 4 * qa * qc
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        var ts: [Double] = []
        if root == 0 {
            ts = [-qb / (2 * qa)]
        } else {
            // Vieta's form, so a near-tangent line keeps its digits.
            let q = -0.5 * (qb + (qb < 0 ? -root : root))
            ts = [q / qa, qc / q].filter(\.isFinite)
        }
        return ts
            .filter { $0 >= -1e-12 && $0 <= 1 + 1e-12 }
            .map { PDFPoint(x: a.x + $0 * dx, y: a.y + $0 * dy) }
    }

    static func circleCircle(_ c1: PDFPoint, _ r1: Double, _ c2: PDFPoint, _ r2: Double) -> [PDFPoint] {
        let dx = c2.x - c1.x
        let dy = c2.y - c1.y
        let d = (dx * dx + dy * dy).squareRoot()
        guard d > 1e-12, r1 > 0, r2 > 0, d <= r1 + r2, d >= Swift.abs(r1 - r2) else { return [] }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let hSquared = r1 * r1 - a * a
        guard hSquared >= 0 else { return [] }
        let h = hSquared.squareRoot()
        let base = PDFPoint(x: c1.x + a * dx / d, y: c1.y + a * dy / d)
        if h <= 1e-15 { return [base] }
        return [
            PDFPoint(x: base.x - dy / d * h, y: base.y + dx / d * h),
            PDFPoint(x: base.x + dy / d * h, y: base.y - dx / d * h)
        ]
    }

    // MARK: - Hand-written geometry: cubics

    static func bezier(_ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, _ t: Double) -> PDFPoint {
        let u = 1 - t
        let b0 = u * u * u
        let b1 = 3 * u * u * t
        let b2 = 3 * u * t * t
        let b3 = t * t * t
        return PDFPoint(
            x: b0 * p0.x + b1 * p1.x + b2 * p2.x + b3 * p3.x,
            y: b0 * p0.y + b1 * p1.y + b2 * p2.y + b3 * p3.y
        )
    }

    /// The parameter halfway along the curve by arc length: adaptive Simpson on the speed to an
    /// absolute tolerance of 1e-13, then Newton, bracketed, on s(t) - L/2. Deliberately a
    /// different method from the engine's fixed Gauss-Legendre pieces.
    static func arcLengthMidpoint(_ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint) -> Double {
        func speed(_ t: Double) -> Double {
            let d = bezierDerivative(p0, p1, p2, p3, t)
            return (d.dx * d.dx + d.dy * d.dy).squareRoot()
        }
        func simpson(_ a: Double, _ b: Double, _ fa: Double, _ fm: Double, _ fb: Double) -> Double {
            (b - a) / 6 * (fa + 4 * fm + fb)
        }
        func adaptive(_ a: Double, _ b: Double, _ fa: Double, _ fm: Double, _ fb: Double,
                      _ whole: Double, _ tolerance: Double, _ depth: Int) -> Double {
            let m = 0.5 * (a + b)
            let lm = 0.5 * (a + m), rm = 0.5 * (m + b)
            let flm = speed(lm), frm = speed(rm)
            let left = simpson(a, m, fa, flm, fm)
            let right = simpson(m, b, fm, frm, fb)
            if depth <= 0 || Swift.abs(left + right - whole) <= 15 * tolerance {
                return left + right + (left + right - whole) / 15
            }
            return adaptive(a, m, fa, flm, fm, left, tolerance / 2, depth - 1)
                + adaptive(m, b, fm, frm, fb, right, tolerance / 2, depth - 1)
        }
        func length(_ a: Double, _ b: Double) -> Double {
            guard b > a else { return 0 }
            let fa = speed(a), fb = speed(b), fm = speed(0.5 * (a + b))
            return adaptive(a, b, fa, fm, fb, simpson(a, b, fa, fm, fb), 1e-13, 40)
        }
        let total = length(0, 1)
        guard total > 0, total.isFinite else { return 0.5 }
        var lo = 0.0, hi = 1.0, t = 0.5
        for _ in 0..<100 {
            let f = length(0, t) - total / 2
            if f < 0 { lo = t } else { hi = t }
            let v = speed(t)
            var next = v > 0 ? t - f / v : 0.5 * (lo + hi)
            if !(next > lo && next < hi) { next = 0.5 * (lo + hi) }
            if Swift.abs(next - t) <= 1e-15 { return next }
            t = next
        }
        return t
    }

    static func bezierDerivative(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, _ t: Double
    ) -> (dx: Double, dy: Double) {
        let u = 1 - t
        let dx = 3 * (u * u * (p1.x - p0.x) + 2 * u * t * (p2.x - p1.x) + t * t * (p3.x - p2.x))
        let dy = 3 * (u * u * (p1.y - p0.y) + 2 * u * t * (p2.y - p1.y) + t * t * (p3.y - p2.y))
        return (dx, dy)
    }

    /// The parameter of the point nearest to `q`: dense sampling picks the basin, bisection on
    /// `d/dt |B(t) - q|² = 0` finishes it. A minimum on the boundary is the boundary.
    static func nearestParameter(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, to q: PDFPoint
    ) -> Double {
        let samples = 1024
        var best = 0.0
        var bestDistance = Double.infinity
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let d = bezier(p0, p1, p2, p3, t).distance(to: q)
            if d < bestDistance {
                bestDistance = d
                best = t
            }
        }
        func slope(_ t: Double) -> Double {
            let p = bezier(p0, p1, p2, p3, t)
            let d = bezierDerivative(p0, p1, p2, p3, t)
            return (p.x - q.x) * d.dx + (p.y - q.y) * d.dy
        }
        var lo = Swift.max(0, best - 1 / Double(samples))
        var hi = Swift.min(1, best + 1 / Double(samples))
        if slope(lo) >= 0 { return lo }
        if slope(hi) <= 0 { return hi }
        for _ in 0..<200 {
            let mid = 0.5 * (lo + hi)
            if slope(mid) < 0 { lo = mid } else { hi = mid }
        }
        return 0.5 * (lo + hi)
    }

    /// Every sign change of `f` over `[0, 1]`, bisected to the last bit.
    static func roots(of f: (Double) -> Double, samples: Int = 4096) -> [Double] {
        var result: [Double] = []
        var previousT = 0.0
        var previous = f(0)
        if previous == 0 { result.append(0) }
        for i in 1...samples {
            let t = Double(i) / Double(samples)
            let value = f(t)
            if value == 0 {
                result.append(t)
            } else if previous != 0, (previous < 0) != (value < 0) {
                var lo = previousT
                var hi = t
                let loNegative = previous < 0
                for _ in 0..<200 {
                    let mid = 0.5 * (lo + hi)
                    let m = f(mid)
                    if m == 0 { lo = mid; hi = mid; break }
                    if (m < 0) == loNegative { lo = mid } else { hi = mid }
                }
                result.append(0.5 * (lo + hi))
            }
            previousT = t
            previous = value
        }
        return result
    }

    static func tangentParameters(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, from anchor: PDFPoint
    ) -> [Double] {
        roots(of: { t in
            let b = bezier(p0, p1, p2, p3, t)
            let d = bezierDerivative(p0, p1, p2, p3, t)
            return (b.x - anchor.x) * d.dy - (b.y - anchor.y) * d.dx
        })
    }

    static func lineCubic(
        _ a: PDFPoint, _ b: PDFPoint,
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint
    ) -> [PDFPoint] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return [] }
        // Signed distance of the curve to the line, up to the line's length.
        let ts = roots(of: { t in
            let p = bezier(p0, p1, p2, p3, t)
            return (p.x - a.x) * dy - (p.y - a.y) * dx
        })
        return ts
            .map { bezier(p0, p1, p2, p3, $0) }
            .filter { point in
                let u = ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared
                return u >= -1e-9 && u <= 1 + 1e-9
            }
    }

    static func cubicCircle(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint,
        _ centre: PDFPoint, _ radius: Double
    ) -> [PDFPoint] {
        roots(of: { t in bezier(p0, p1, p2, p3, t).distance(to: centre) - radius })
            .map { bezier(p0, p1, p2, p3, $0) }
    }

    typealias Cubic = (PDFPoint, PDFPoint, PDFPoint, PDFPoint)

    /// Crossings of two cubics by bounding-box subdivision: split whichever piece is larger
    /// until the overlapping pieces are smaller than `1e-10`, then take the piece centre.
    static func cubicCubic(_ a: Cubic, _ b: Cubic) -> [PDFPoint] {
        var found: [PDFPoint] = []
        var visited = 0
        func box(_ c: Cubic) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
            let xs = [c.0.x, c.1.x, c.2.x, c.3.x]
            let ys = [c.0.y, c.1.y, c.2.y, c.3.y]
            return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
        }
        func split(_ c: Cubic) -> (Cubic, Cubic) {
            func mid(_ p: PDFPoint, _ q: PDFPoint) -> PDFPoint { PDFPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
            let p01 = mid(c.0, c.1), p12 = mid(c.1, c.2), p23 = mid(c.2, c.3)
            let p012 = mid(p01, p12), p123 = mid(p12, p23)
            let m = mid(p012, p123)
            return ((c.0, p01, p012, m), (m, p123, p23, c.3))
        }
        func recurse(_ x: Cubic, _ y: Cubic) {
            visited += 1
            guard visited < 400_000 else { return }
            let bx = box(x)
            let by = box(y)
            guard bx.minX <= by.maxX + 1e-12, by.minX <= bx.maxX + 1e-12,
                  bx.minY <= by.maxY + 1e-12, by.minY <= bx.maxY + 1e-12 else { return }
            let sx = Swift.max(bx.maxX - bx.minX, bx.maxY - bx.minY)
            let sy = Swift.max(by.maxX - by.minX, by.maxY - by.minY)
            if sx < 1e-10, sy < 1e-10 {
                found.append(PDFPoint(x: (bx.minX + bx.maxX + by.minX + by.maxX) / 4,
                                      y: (bx.minY + bx.maxY + by.minY + by.maxY) / 4))
                return
            }
            if sx >= sy {
                let (x0, x1) = split(x)
                recurse(x0, y)
                recurse(x1, y)
            } else {
                let (y0, y1) = split(y)
                recurse(x, y0)
                recurse(x, y1)
            }
        }
        recurse(a, b)
        // Pieces that meet at a common crossing all report it: keep one per point.
        var unique: [PDFPoint] = []
        for point in found where !unique.contains(where: { $0.distance(to: point) <= 1e-8 }) {
            unique.append(point)
        }
        return unique
    }
}
