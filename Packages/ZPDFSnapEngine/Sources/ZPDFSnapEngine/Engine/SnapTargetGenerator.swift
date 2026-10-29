import Foundation
import ZPDFContracts
import ZPDFGeometry

/// A snap target before it has been scored: a point, the kind it would be, and where it came
/// from.
public struct SnapTarget: Sendable, Hashable {
    public let kind: SnapKind
    public let position: PDFPoint
    public let primitiveID: UInt64?
    public let secondaryPrimitiveID: UInt64?
    public let source: SnapGeometrySource
    public let confidence: Float
    public let layerID: String?

    /// The guide the UI draws for this target: the segment that produced a perpendicular foot,
    /// the circle a tangent touched, the two primitives an intersection crossed.
    public let guide: SnapGuideGeometry

    /// Which part of the primitive produced this target: the edge or vertex index of a polyline
    /// or rectangle, `0` where the primitive has one part. With the kind and the primitive it
    /// identifies the target across queries, which the position alone cannot do for a target
    /// that moves with the cursor (CR-38).
    public let component: Int

    /// `true` for a target whose position is a function of the cursor — the nearest point on
    /// an edge — and therefore no part of its identity (CR-38).
    public let followsCursor: Bool

    public init(
        kind: SnapKind,
        position: PDFPoint,
        primitiveID: UInt64?,
        secondaryPrimitiveID: UInt64? = nil,
        source: SnapGeometrySource,
        confidence: Float,
        layerID: String?,
        guide: SnapGuideGeometry = .none,
        component: Int = 0,
        followsCursor: Bool = false
    ) {
        self.kind = kind
        self.position = position
        self.primitiveID = primitiveID
        self.secondaryPrimitiveID = secondaryPrimitiveID
        self.source = source
        self.confidence = confidence
        self.layerID = layerID
        self.guide = guide
        self.component = component
        self.followsCursor = followsCursor
    }
}

/// How far the intersection search got inside its budget (CR-37).
public struct SnapIntersectionReport: Sendable, Hashable, Codable {
    /// Curve pairs the intersection solver was asked about.
    public let pairsEvaluated: Int
    /// `true` when the per-query pair budget stopped the search before every candidate pair
    /// was solved. The intersections that were found are exact; the set is not complete.
    public let isTruncated: Bool

    public init(pairsEvaluated: Int, isTruncated: Bool) {
        self.pairsEvaluated = pairsEvaluated
        self.isTruncated = isTruncated
    }

    public static let none = SnapIntersectionReport(pairsEvaluated: 0, isTruncated: false)
}

/// Derives snap targets from the primitives inside a query radius.
///
/// Everything here is **lazy and local**. Nothing is precomputed at index time: a 250 000-
/// primitive page has of the order of a million endpoints and an unbounded number of
/// intersections, and materialising either would cost more memory than the page and more time
/// than the frame. What is generated is what the cursor can actually reach this event.
public struct SnapTargetGenerator: Sendable {

    public let limits: SnapIndexLimits

    /// Curve pairs one query may hand to the intersection solver.
    ///
    /// The pair count is quadratic in the edges of the participating primitives, and a
    /// polygonised ring has hundreds of them: 24 rings of 360 edges inside the radius at 5 %
    /// zoom are 36 million pairs, measured at 38 s of CPU per pointer event before this budget
    /// existed (CR-37). Pairs are enumerated in a deterministic order — participants by
    /// `(box distance, id)`, edges by `(minimum x, ordinal)` — so the same index and event stop
    /// at the same pair, and the resolution reports that the search was cut short.
    ///
    /// 8 192 solves is under a few milliseconds of release CPU in the worst case. Only pairs
    /// whose bounding boxes overlap are counted, and a real crossing is one such pair, so the
    /// budget is reached by dense linework crossing dense linework and by nothing else.
    public var maximumIntersectionPairs: Int

    public init(limits: SnapIndexLimits = .standard, maximumIntersectionPairs: Int = 8_192) {
        self.limits = limits
        self.maximumIntersectionPairs = Swift.max(0, maximumIntersectionPairs)
    }

    /// A primitive paired with the curves it decomposed into inside the radius.
    struct LocalPrimitive {
        let entry: SnapIndexEntry
        let curves: [SnapLocalCurve]
        /// Distance from the cursor to the primitive's bounding box; the truncation key.
        let boxDistance: Double
    }

    /// Restricts the entry set to what is reachable, decomposes each entry into local curves,
    /// and truncates deterministically to ``SnapIndexLimits/maximumCandidatePrimitives``.
    func localPrimitives(
        _ entries: [SnapIndexEntry],
        cursor: PDFPoint,
        radius: Double
    ) -> [LocalPrimitive] {
        // The truncation order is `(bounding-box distance, primitive id)` — a total order, so
        // the truncated set is a function of the entry set alone (`QUALITY_BAR` S1, S15).
        //
        // Only the nearest `maximumCandidatePrimitives` survive, so the selection is a bounded
        // `k`-smallest, never a full sort: at the minimum supported zoom (5 %) a 10-view-point
        // radius is 200 page points and the search box over a 250 000-primitive sheet holds
        // tens of thousands of entries, of which 512 are kept. Sorting all of them was more
        // than half the query's cost and is `O(n log n)` where `O(n log k)` answers the same
        // question. The retained set and its order are identical either way.
        //
        // `Candidate` carries the *index* of the entry, not the entry: `SnapIndexEntry` owns a
        // `PrimitiveGeometry` that can hold an array, so copying one into a scratch buffer is
        // a retain, and doing that tens of thousands of times per pointer move is the other
        // half of the cost.
        struct Candidate {
            var distance: Double
            var id: UInt64
            var index: Int
        }

        /// `true` when `a` sorts before `b` in the truncation order.
        func precedes(_ a: Candidate, _ b: Candidate) -> Bool {
            a.distance != b.distance ? a.distance < b.distance : a.id < b.id
        }

        let limit = limits.maximumCandidatePrimitives
        var heap: [Candidate] = []
        heap.reserveCapacity(Swift.min(entries.count, limit) + 1)

        /// Sifts `heap[start]` down a max-heap ordered by ``precedes`` reversed, so `heap[0]`
        /// is always the *worst* of the `k` kept and is the one a better candidate evicts.
        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1
                guard left < heap.count else { return }
                var largest = precedes(heap[parent], heap[left]) ? left : parent
                let right = left + 1
                if right < heap.count, precedes(heap[largest], heap[right]) { largest = right }
                if largest == parent { return }
                heap.swapAt(parent, largest)
                parent = largest
            }
        }

        func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[parent], heap[child]) else { return }
                heap.swapAt(parent, child)
                child = parent
            }
        }

        for index in entries.indices {
            let entry = entries[index]
            let distance = Self.boxDistance(from: cursor, to: entry.bounds)
            guard distance <= radius else { continue }
            let candidate = Candidate(distance: distance, id: entry.id, index: index)
            if heap.count < limit {
                heap.append(candidate)
                siftUp(heap.count - 1)
            } else if limit > 0, precedes(candidate, heap[0]) {
                heap[0] = candidate
                siftDown(0)
            }
        }

        heap.sort(by: precedes)

        return heap.map { item in
            let entry = entries[item.index]
            return LocalPrimitive(
                entry: entry,
                curves: SnapCurve.decompose(entry, near: cursor, within: radius),
                boxDistance: item.distance
            )
        }
    }

    /// Every derived target within `radius` of `cursor`, and how far the intersection search
    /// got.
    ///
    /// - Parameter anchor: the in-progress point of the current measurement. Perpendicular feet
    ///   and tangents are *from* it, so when there is no in-progress point neither kind exists —
    ///   which is correct: a perpendicular has to be perpendicular to something.
    func targets(
        from locals: [LocalPrimitive],
        cursor: PDFPoint,
        anchor: PDFPoint?,
        radius: Double,
        enabledKinds: Set<SnapKind>,
        allowsVectorKinds: Bool
    ) -> (targets: [SnapTarget], intersections: SnapIntersectionReport) {
        var result: [SnapTarget] = []
        result.reserveCapacity(locals.count * 4)

        // Which kinds can survive the final filter, resolved per kind set rather than per
        // target: a disabled kind's computation — a cubic's 48-sample tangent scan, a
        // perpendicular foot, a nearest-point Newton — is skipped instead of being done and
        // then thrown away (IM-087). Entries of one source share one kind set, so the cache is
        // a handful of entries long.
        var wantsCache: [(SnapEntryKindSet, Wants)] = []
        func wants(_ kindSet: SnapEntryKindSet) -> Wants {
            for (key, value) in wantsCache where key == kindSet { return value }
            let value = Wants(kindSet, enabledKinds: enabledKinds, allowsVectorKinds: allowsVectorKinds)
            wantsCache.append((kindSet, value))
            return value
        }

        for local in locals {
            let wanted = wants(local.entry.kindSet)
            guard wanted.any else { continue }
            appendPointTargets(local, cursor: cursor, radius: radius, wants: wanted, into: &result)
            appendCurveTargets(
                local, cursor: cursor, anchor: anchor, radius: radius, wants: wanted, into: &result
            )
        }
        let report = appendIntersections(
            locals, cursor: cursor, radius: radius, enabledKinds: enabledKinds, into: &result
        )

        // The final filter stays — it is what the contract promises — but in place, without a
        // second array per pointer event.
        result.removeAll { target in
            guard enabledKinds.contains(target.kind) else { return true }
            if target.kind.requiresVectorContent && !allowsVectorKinds { return true }
            return !(target.position.isFinite && target.position.distance(to: cursor) <= radius)
        }
        return (result, report)
    }

    /// The slots of one kind set that can produce a surviving target this query.
    struct Wants {
        let vertex: Bool
        let edgeMidpoint: Bool
        let center: Bool
        let onEdge: Bool
        let quadrant: Bool
        let tangent: Bool
        let perpendicular: Bool

        init(_ kinds: SnapEntryKindSet, enabledKinds: Set<SnapKind>, allowsVectorKinds: Bool) {
            func live(_ kind: SnapKind) -> Bool {
                enabledKinds.contains(kind) && (allowsVectorKinds || !kind.requiresVectorContent)
            }
            vertex = live(kinds.vertex)
            edgeMidpoint = live(kinds.edgeMidpoint)
            center = live(kinds.center)
            onEdge = live(kinds.onEdge)
            quadrant = live(kinds.quadrant)
            tangent = live(kinds.tangent)
            perpendicular = live(kinds.perpendicular)
        }

        var any: Bool {
            vertex || edgeMidpoint || center || onEdge || quadrant || tangent || perpendicular
        }
    }

    // MARK: - Per-primitive targets

    private func appendPointTargets(
        _ local: LocalPrimitive,
        cursor: PDFPoint,
        radius: Double,
        wants: Wants,
        into result: inout [SnapTarget]
    ) {
        let entry = local.entry
        let geometry = entry.primitive.geometry

        let kinds = entry.kindSet
        func isWanted(_ kind: SnapKind) -> Bool {
            (wants.vertex && kind == kinds.vertex)
                || (wants.edgeMidpoint && kind == kinds.edgeMidpoint)
                || (wants.center && kind == kinds.center)
                || (wants.quadrant && kind == kinds.quadrant)
        }
        guard wants.vertex || wants.edgeMidpoint || wants.center || wants.quadrant else { return }

        func emit(
            _ kind: SnapKind, _ point: PDFPoint, guide: SnapGuideGeometry = .none, component: Int = 0
        ) {
            guard isWanted(kind), point.distance(to: cursor) <= radius else { return }
            result.append(
                SnapTarget(
                    kind: kind,
                    position: point,
                    primitiveID: entry.id,
                    source: entry.source,
                    confidence: entry.primitive.confidence,
                    layerID: entry.primitive.layerID,
                    guide: guide,
                    component: component
                )
            )
        }

        switch geometry {
        case .point(let p):
            emit(entry.kindSet.vertex, p, guide: .crosshair(p))

        case .segment(let s):
            emit(entry.kindSet.vertex, s.start, guide: .crosshair(s.start))
            emit(entry.kindSet.vertex, s.end, guide: .crosshair(s.end), component: 1)
            emit(entry.kindSet.edgeMidpoint, SegmentMath.midpoint(of: s), guide: .segment(s))

        case .polyline(let points, let isClosed):
            let edgeCount = isClosed ? points.count : points.count - 1
            guard edgeCount >= 1 else { return }
            // Only the edges near the cursor can carry a vertex or midpoint inside the radius: a
            // vertex within the radius lies in the radius-grown box of both edges that meet
            // there, and a midpoint in its own edge's, and `local.curves` is exactly the edges
            // whose grown box contains the cursor. So the targets come from those edges, not
            // from a scan of the whole ring — a 50 000-vertex contour was 100 000 distance
            // tests per pointer event (IM-088). The full scan remains for the one case the
            // edge list cannot vouch for: decomposition stopped at its edge cap.
            let edgesAreComplete = points.count >= 2
                && local.curves.count < SnapCurve.defaultVertexLimit
            if edgesAreComplete {
                var vertices: [Int] = []
                vertices.reserveCapacity(local.curves.count * 2)
                for item in local.curves {
                    vertices.append(item.ordinal)
                    vertices.append(isClosed ? (item.ordinal + 1) % points.count : item.ordinal + 1)
                }
                vertices.sort()
                var previous = -1
                for i in vertices where i != previous {
                    previous = i
                    let point = points[i]
                    guard point.distance(to: cursor) <= radius else { continue }
                    emit(entry.kindSet.vertex, point, guide: .crosshair(point), component: i)
                }
                for item in local.curves {
                    let i = item.ordinal
                    let segment = SegmentGeometry(
                        start: points[i], end: points[(i + 1) % points.count]
                    )
                    let midpoint = SegmentMath.midpoint(of: segment)
                    guard midpoint.distance(to: cursor) <= radius else { continue }
                    emit(entry.kindSet.edgeMidpoint, midpoint, guide: .segment(segment), component: i)
                }
            } else {
                for (i, point) in points.enumerated() where point.distance(to: cursor) <= radius {
                    emit(entry.kindSet.vertex, point, guide: .crosshair(point), component: i)
                }
                for i in 0..<edgeCount {
                    let segment = SegmentGeometry(
                        start: points[i], end: points[(i + 1) % points.count]
                    )
                    let midpoint = SegmentMath.midpoint(of: segment)
                    guard midpoint.distance(to: cursor) <= radius else { continue }
                    emit(entry.kindSet.edgeMidpoint, midpoint, guide: .segment(segment), component: i)
                }
            }
            if isClosed, let centre = Self.parallelogramCentre(of: points) {
                emit(entry.kindSet.center, centre, guide: .crosshair(centre))
            }

        case .rectangle(let rect):
            let r = rect.standardized
            let corners = [
                PDFPoint(x: r.minX, y: r.minY), PDFPoint(x: r.maxX, y: r.minY),
                PDFPoint(x: r.maxX, y: r.maxY), PDFPoint(x: r.minX, y: r.maxY)
            ]
            for (i, corner) in corners.enumerated() {
                emit(entry.kindSet.vertex, corner, guide: .crosshair(corner), component: i)
            }
            for i in 0..<4 {
                let segment = SegmentGeometry(start: corners[i], end: corners[(i + 1) % 4])
                emit(
                    entry.kindSet.edgeMidpoint,
                    SegmentMath.midpoint(of: segment),
                    guide: .segment(segment),
                    component: i
                )
            }
            emit(entry.kindSet.center, r.center, guide: .crosshair(r.center))

        case .cubicCurve(let start, let c1, let c2, let end):
            emit(entry.kindSet.vertex, start, guide: .crosshair(start))
            emit(entry.kindSet.vertex, end, guide: .crosshair(end), component: 1)
            // The midpoint by arc length, not the parametric t = 0.5 (BH-663) — and on the
            // ellipse itself for a quarter of a markup ellipse, not on its cubic (U-089).
            if wants.edgeMidpoint, let ellipse = entry.ellipseArc {
                let mid = ellipse.arcLengthMidpoint
                emit(entry.kindSet.edgeMidpoint, mid, guide: .crosshair(mid))
            } else if wants.edgeMidpoint {
                let t = SnapCurveMath.arcLengthMidpointParameter(start, c1, c2, end)
                let mid = SnapCurveMath.cubicPoint(start, c1, c2, end, at: t)
                emit(entry.kindSet.edgeMidpoint, mid, guide: .crosshair(mid))
            }

        case .quadraticCurve(let start, let control, let end):
            emit(entry.kindSet.vertex, start, guide: .crosshair(start))
            emit(entry.kindSet.vertex, end, guide: .crosshair(end), component: 1)
            if wants.edgeMidpoint {
                let (p0, p1, p2, p3) = SnapCurveMath.elevate(start, control, end)
                let t = SnapCurveMath.arcLengthMidpointParameter(p0, p1, p2, p3)
                let mid = SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: t)
                emit(entry.kindSet.edgeMidpoint, mid, guide: .crosshair(mid))
            }

        case .circle(let circle):
            emit(entry.kindSet.center, circle.center, guide: .circle(circle))
            for i in 0..<4 {
                let angle = Double(i) * Double.pi / 2
                let point = PDFPoint(
                    x: circle.center.x + circle.radius * Foundation.cos(angle),
                    y: circle.center.y + circle.radius * Foundation.sin(angle)
                )
                emit(entry.kindSet.quadrant, point, guide: .circle(circle), component: i)
            }

        case .ellipticalArc(let arc):
            // A markup's arc is only its curve here. Its ends and its centre are pieces of their
            // own in the markup's projection (``SnapMarkupGeometry/from(_:unprojectedCutouts:)``):
            // the centre lies off the arc's box, so the arc's entry is not found near it (W-087),
            // and a bulged edge's ends are its stored vertices bit for bit, where `startPoint`
            // and `endPoint` are recomputed from centre and radius and drift past S2's 1e-9 pt
            // on a nearly straight arc (W-088).
            if entry.source != .zenitMarkup {
                emit(entry.kindSet.center, arc.center, guide: .crosshair(arc.center))
                emit(entry.kindSet.vertex, arc.startPoint, guide: .crosshair(arc.startPoint))
                emit(entry.kindSet.vertex, arc.endPoint, guide: .crosshair(arc.endPoint), component: 1)
            }
            let midAngle = arc.startAngle + arc.sweepAngle / 2
            let mid = PDFPoint(
                x: arc.center.x + arc.radius * Foundation.cos(midAngle),
                y: arc.center.y + arc.radius * Foundation.sin(midAngle)
            )
            emit(entry.kindSet.edgeMidpoint, mid, guide: .crosshair(mid))
            for i in 0..<4 {
                let angle = Double(i) * Double.pi / 2
                guard SnapCurveMath.arcContains(arc, angle: angle) else { continue }
                let point = PDFPoint(
                    x: arc.center.x + arc.radius * Foundation.cos(angle),
                    y: arc.center.y + arc.radius * Foundation.sin(angle)
                )
                emit(entry.kindSet.quadrant, point, guide: .crosshair(point), component: i)
            }
        }
    }

    /// The centre of a closed four-vertex outline whose diagonals bisect each other — a
    /// parallelogram, which is what a `re` rectangle is under any affine CTM. The candidate is
    /// the diagonals' common midpoint.
    ///
    /// Any other closed outline has no centre here. Every closed polyline used to emit the
    /// centre of its bounding box, so an L-shape carried a priority-5 target 50 pt from its
    /// nearest edge, at a point where nothing is drawn (CR-40).
    static func parallelogramCentre(of points: [PDFPoint]) -> PDFPoint? {
        guard points.count == 4, let box = PDFRect.boundingBox(of: points) else { return nil }
        let first = PDFPoint(
            x: (points[0].x + points[2].x) / 2, y: (points[0].y + points[2].y) / 2
        )
        let second = PDFPoint(
            x: (points[1].x + points[3].x) / 2, y: (points[1].y + points[3].y) / 2
        )
        let tolerance = 1e-9 * Swift.max(1, box.width, box.height)
        guard first.isFinite, second.isFinite, first.distance(to: second) <= tolerance else {
            return nil
        }
        return first
    }

    private func appendCurveTargets(
        _ local: LocalPrimitive,
        cursor: PDFPoint,
        anchor: PDFPoint?,
        radius: Double,
        wants: Wants,
        into result: inout [SnapTarget]
    ) {
        let entry = local.entry
        let fromAnchor = anchor != nil && (wants.tangent || wants.perpendicular)
        guard wants.onEdge || fromAnchor else { return }

        for item in local.curves {
            let curve = item.curve
            // Nearest point on the curve. It moves with the cursor, so its identity is the
            // curve it lies on, not the point (CR-38).
            if wants.onEdge,
               let nearest = curve.nearestPoint(to: cursor),
               nearest.distance <= radius,
               curve.contains(parameter: nearest.parameter) {
                result.append(
                    SnapTarget(
                        kind: entry.kindSet.onEdge,
                        position: nearest.point,
                        primitiveID: entry.id,
                        source: entry.source,
                        confidence: entry.primitive.confidence,
                        layerID: entry.primitive.layerID,
                        guide: Self.guide(for: curve),
                        component: item.ordinal,
                        followsCursor: true
                    )
                )
            }

            guard let anchor, fromAnchor else { continue }

            switch curve {
            case .line(let segment):
                guard wants.perpendicular else { continue }
                // The foot of the perpendicular dropped from the in-progress point.
                if let foot = try? SegmentMath.perpendicularFoot(
                    from: anchor, onLineThrough: segment.start, and: segment.end
                   ),
                   foot.distance(to: cursor) <= radius {
                    result.append(
                        SnapTarget(
                            kind: entry.kindSet.perpendicular,
                            position: foot,
                            primitiveID: entry.id,
                            source: entry.source,
                            confidence: entry.primitive.confidence,
                            layerID: entry.primitive.layerID,
                            guide: .segment(SegmentGeometry(start: anchor, end: foot)),
                            component: item.ordinal
                        )
                    )
                }

            case .circle(let circle):
                guard wants.tangent else { continue }
                appendCircleTangents(
                    entry: entry, center: circle.center, radius: circle.radius,
                    anchor: anchor, cursor: cursor, tolerance: radius,
                    arc: nil, into: &result
                )

            case .arc(let arc):
                guard wants.tangent else { continue }
                appendCircleTangents(
                    entry: entry, center: arc.center, radius: arc.radius,
                    anchor: anchor, cursor: cursor, tolerance: radius,
                    arc: arc, into: &result
                )

            case .ellipseArc(let ellipse):
                guard wants.tangent else { continue }
                for (side, theta) in ellipse.tangentParameters(from: anchor).enumerated() {
                    let point = ellipse.point(at: theta)
                    guard point.distance(to: cursor) <= radius else { continue }
                    result.append(
                        SnapTarget(
                            kind: entry.kindSet.tangent,
                            position: point,
                            primitiveID: entry.id,
                            source: entry.source,
                            confidence: entry.primitive.confidence,
                            layerID: entry.primitive.layerID,
                            guide: .segment(SegmentGeometry(start: anchor, end: point)),
                            component: side
                        )
                    )
                }

            case .cubic(let p0, let p1, let p2, let p3):
                guard wants.tangent else { continue }
                for t in SnapCurveMath.tangentParametersOnCubic(p0, p1, p2, p3, from: anchor) {
                    let point = SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: t)
                    guard point.distance(to: cursor) <= radius else { continue }
                    result.append(
                        SnapTarget(
                            kind: entry.kindSet.tangent,
                            position: point,
                            primitiveID: entry.id,
                            source: entry.source,
                            confidence: entry.primitive.confidence,
                            layerID: entry.primitive.layerID,
                            guide: .segment(SegmentGeometry(start: anchor, end: point)),
                            component: item.ordinal
                        )
                    )
                }
            }
        }
    }

    private func appendCircleTangents(
        entry: SnapIndexEntry,
        center: PDFPoint,
        radius circleRadius: Double,
        anchor: PDFPoint,
        cursor: PDFPoint,
        tolerance: Double,
        arc: ArcGeometry?,
        into result: inout [SnapTarget]
    ) {
        let toAnchor = PDFVector(from: center, to: anchor)
        let distance = toAnchor.magnitude
        guard distance > circleRadius + 1e-12, circleRadius > 0 else { return }
        let base = toAnchor.angle
        let opening = Foundation.acos(Swift.min(1, Swift.max(-1, circleRadius / distance)))
        for (side, sign) in [1.0, -1.0].enumerated() {
            let angle = base + sign * opening
            if let arc, !SnapCurveMath.arcContains(arc, angle: angle) { continue }
            let point = PDFPoint(
                x: center.x + circleRadius * Foundation.cos(angle),
                y: center.y + circleRadius * Foundation.sin(angle)
            )
            guard point.distance(to: cursor) <= tolerance else { continue }
            result.append(
                SnapTarget(
                    kind: entry.kindSet.tangent,
                    position: point,
                    primitiveID: entry.id,
                    source: entry.source,
                    confidence: entry.primitive.confidence,
                    layerID: entry.primitive.layerID,
                    guide: .segment(SegmentGeometry(start: anchor, end: point)),
                    component: side
                )
            )
        }
    }

    // MARK: - Intersections

    /// One curve as the sweep sees it: its grown bounding box and the ordinal that orders it.
    private struct SweptCurve {
        let curve: SnapCurve
        let ordinal: Int
        let box: PDFRect
    }

    private func appendIntersections(
        _ locals: [LocalPrimitive],
        cursor: PDFPoint,
        radius: Double,
        enabledKinds: Set<SnapKind>,
        into result: inout [SnapTarget]
    ) -> SnapIntersectionReport {
        // Only the nearest few primitives participate: the pair count is quadratic, and this is
        // the one derived target whose cost can leave the frame budget. `locals` is already in
        // `(box distance, id)` order, so the prefix is deterministic.
        //
        // A participant must have a curve near the cursor: one that has none can cross nothing
        // here, yet a closed frame, an area ring or a zone outline round the cursor has box
        // distance 0 and sorted ahead of every axis-aligned line (whose zero-width box is
        // rarely exactly under the cursor). Twenty-three such frames took the slots of the two
        // lines actually crossing under the cursor, and the crossing was never solved (W-087).
        let participants = Array(
            locals.lazy.filter { !$0.curves.isEmpty }.prefix(limits.maximumIntersectionPrimitives)
        )
        guard participants.count >= 2 else { return .none }
        // Nothing to search for when no participant could emit an enabled intersection kind.
        guard participants.contains(where: { enabledKinds.contains($0.entry.kindSet.intersection) })
        else { return .none }

        // Each participant's curves in `(minimum x, ordinal)` order: the sweep key. The grown
        // box keeps two curves that touch exactly at a shared box edge from being skipped, the
        // same epsilon the solver applies.
        let swept: [[SweptCurve]] = participants.map { local in
            local.curves
                .compactMap { item -> SweptCurve? in
                    guard let box = item.curve.bounds else { return nil }
                    return SweptCurve(curve: item.curve, ordinal: item.ordinal, box: box.standardized.insetBy(1e-9))
                }
                .sorted { $0.box.minX != $1.box.minX ? $0.box.minX < $1.box.minX : $0.ordinal < $1.ordinal }
        }

        var pairs = 0
        let budget = maximumIntersectionPairs

        for i in 0..<(participants.count - 1) {
            let a = participants[i]
            let curvesA = swept[i]
            guard !curvesA.isEmpty else { continue }
            for j in (i + 1)..<participants.count {
                let b = participants[j]
                let curvesB = swept[j]
                guard !curvesB.isEmpty else { continue }
                // Two curves of the *same* primitive are not crossed: a closed ring meets
                // itself at every vertex, and those are endpoints, not intersections.
                guard a.entry.id != b.entry.id else { continue }
                guard a.entry.bounds.insetBy(1e-9).intersects(b.entry.bounds) else { continue }

                // An x-sweep over the two sorted edge lists (CR-37): a curve of `b` becomes
                // active when its box reaches the current curve of `a` and retires once no
                // later curve of `a` can reach it, so only box-overlapping pairs are solved
                // instead of every pair — a ring against a ring is a few dozen solves, not
                // 130 000. Every step below is ordered by the sort keys, so the pair at which
                // the budget runs out is a function of the input alone.
                var next = 0
                var active: [Int] = []
                for curveA in curvesA {
                    while next < curvesB.count, curvesB[next].box.minX <= curveA.box.maxX {
                        active.append(next)
                        next += 1
                    }
                    active.removeAll { curvesB[$0].box.maxX < curveA.box.minX }
                    for indexB in active {
                        let curveB = curvesB[indexB]
                        guard curveB.box.minX <= curveA.box.maxX,
                              curveB.box.maxX >= curveA.box.minX,
                              curveB.box.minY <= curveA.box.maxY,
                              curveB.box.maxY >= curveA.box.minY
                        else { continue }
                        // A crossing lies in both boxes, so in their overlap. When the overlap
                        // is out of reach of the cursor the solver would discard every hit, so
                        // the pair is not solved and not charged: the budget goes to pairs that
                        // can produce a candidate (IM-089). Exact, and in the same order, so
                        // truncation stays a function of the input.
                        let overlap = PDFRect(
                            corner: PDFPoint(
                                x: Swift.max(curveA.box.minX, curveB.box.minX),
                                y: Swift.max(curveA.box.minY, curveB.box.minY)
                            ),
                            opposite: PDFPoint(
                                x: Swift.min(curveA.box.maxX, curveB.box.maxX),
                                y: Swift.min(curveA.box.maxY, curveB.box.maxY)
                            )
                        )
                        guard Self.boxDistance(from: cursor, to: overlap) <= radius else { continue }
                        guard pairs < budget else {
                            return SnapIntersectionReport(pairsEvaluated: pairs, isTruncated: true)
                        }
                        pairs += 1

                        let hits = SnapIntersectionSolver.intersections(
                            curveA.curve, curveB.curve, near: cursor, within: radius
                        )
                        guard !hits.isEmpty else { continue }
                        let terminals = curveA.curve.terminals + curveB.curve.terminals
                        for hit in hits {
                            // A crossing that lands on a terminal point of either curve is a
                            // corner or a T-junction, and the endpoint candidate already covers
                            // that coordinate with the honest label.
                            if terminals.contains(where: {
                                $0.distance(to: hit.point) <= Self.terminalCoincidence
                            }) { continue }
                            // Order the pair by identifier so the same crossing always reports
                            // the same primary and secondary primitive.
                            let lower = Swift.min(a.entry.id, b.entry.id)
                            let upper = Swift.max(a.entry.id, b.entry.id)
                            let owner = lower == a.entry.id ? a.entry : b.entry
                            result.append(
                                SnapTarget(
                                    kind: owner.kindSet.intersection,
                                    position: hit.point,
                                    primitiveID: lower,
                                    secondaryPrimitiveID: upper,
                                    source: owner.source,
                                    confidence: Swift.min(
                                        a.entry.primitive.confidence,
                                        b.entry.primitive.confidence
                                    ),
                                    layerID: owner.primitive.layerID,
                                    guide: .crosshair(hit.point)
                                )
                            )
                        }
                    }
                }
            }
        }
        return SnapIntersectionReport(pairsEvaluated: pairs, isTruncated: false)
    }

    // MARK: - Helpers

    static func guide(for curve: SnapCurve) -> SnapGuideGeometry {
        switch curve {
        case .line(let s): .segment(s)
        case .circle(let c): .circle(c)
        case .arc(let a): .arc(a)
        case .cubic(let p0, _, _, let p3): .segment(SegmentGeometry(start: p0, end: p3))
        case .ellipseArc(let e): .segment(SegmentGeometry(start: e.start, end: e.end))
        }
    }

    /// How close an intersection may come to a curve's own terminal point before it is treated
    /// as that terminal point instead. Well below any snap tolerance and well above the
    /// floating-point noise of the solver.
    static let terminalCoincidence = 1e-9

    /// Euclidean distance from a point to a rectangle, zero inside it.
    static func boxDistance(from point: PDFPoint, to rect: PDFRect) -> Double {
        let box = rect.standardized
        let dx = Swift.max(box.minX - point.x, 0, point.x - box.maxX)
        let dy = Swift.max(box.minY - point.y, 0, point.y - box.maxY)
        if dx == 0 && dy == 0 { return 0 }
        return (dx * dx + dy * dy).squareRoot()
    }
}
