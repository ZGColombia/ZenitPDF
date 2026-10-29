import Foundation
import ZPDFContracts

/// Answers "which Scale Region owns this?" for one page (spec 10.4).
///
/// Regions are indexed in a ``PackedRTree`` so a point test costs a bounding-box query plus a
/// point-in-polygon test on the few candidates it returns, rather than a scan of every region on
/// a page that may carry dozens of detail views.
///
/// The type is immutable and `Sendable`; a page's region set changes by building a new resolver.
public struct ScaleRegionResolver: Sendable {
    public let pageID: PageID
    public let regions: [ScaleRegion]
    public let epsilon: GeometryEpsilon
    private let index: PackedRTree
    /// Position of each region in ``regions``, which is also its priority rank. Built once so
    /// resolution never rebuilds a UUID dictionary per vertex (IM-065). The first occurrence
    /// wins for a duplicated id instead of trapping.
    private let rankByID: [ScaleRegionID: Int]

    /// - Throws: ``ScaleApplicationError/invalidRegionBoundary(_:underlying:)`` for an unusable
    ///   boundary, or a ``GeometryError`` from the index build.
    public init(
        pageID: PageID,
        regions: [ScaleRegion],
        epsilon: GeometryEpsilon = .standard
    ) throws {
        self.pageID = pageID
        // Deterministic order: the ambiguity prompt must list the same regions in the same
        // sequence on every run and every machine.
        self.regions = regions
            .filter { $0.pageID == pageID }
            .sorted { lhs, rhs in
                lhs.priority == rhs.priority
                    ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                    : lhs.priority > rhs.priority
            }
        self.epsilon = epsilon
        self.rankByID = Dictionary(
            self.regions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        var boxes: [PDFRect] = []
        boxes.reserveCapacity(self.regions.count)
        for region in self.regions {
            guard let bounds = region.bounds else {
                throw ScaleApplicationError.invalidRegionBoundary(
                    region.id,
                    underlying: .fewerThanThreeUniquePoints(count: region.boundary.points.count)
                )
            }
            boxes.append(bounds)
        }
        self.index = try PackedRTree(boxes: boxes)
    }

    /// Validates every boundary and rejects overlap, which spec 10.4 forbids by default.
    ///
    /// Overlap means shared **area**: two regions overlap when an edge of one properly crosses
    /// an edge of the other, when a vertex of either lies strictly inside the other (which is
    /// what catches a region fully nested inside another, with no crossing edges at all), or
    /// when their boundaries run together with both interiors on the same side (identical or
    /// edge-sharing nested frames). Detail frames snapped edge to edge or corner to corner
    /// share no area and are **not** overlap (BH-161); a point on such a shared edge is still
    /// reported ambiguous by ``resolve(point:policy:)``, which is where that belongs.
    ///
    /// - Throws: ``ScaleApplicationError/overlappingRegions(_:_:)`` or
    ///   ``ScaleApplicationError/invalidRegionBoundary(_:underlying:)``.
    public func validateNoOverlap() throws {
        for region in regions { try region.validate(epsilon: epsilon) }
        for (position, region) in regions.enumerated() {
            guard let bounds = region.bounds else { continue }
            for candidate in index.query(bounds) where candidate > position {
                let other = regions[candidate]
                if overlaps(region, other) {
                    throw ScaleApplicationError.overlappingRegions(region.id, other.id)
                }
            }
        }
    }

    private func overlaps(_ lhs: ScaleRegion, _ rhs: ScaleRegion) -> Bool {
        PolygonMath.interiorsOverlap(lhs.boundary.points, rhs.boundary.points, epsilon: epsilon)
    }

    // MARK: - Resolution

    /// Which region owns a single point.
    ///
    /// A point on a region boundary counts as inside that region: a user snapping to the edge of
    /// a detail view intends the detail view's scale. When that puts the point on the shared edge
    /// of two abutting regions, the answer is ambiguous, which is the correct outcome — abutting
    /// regions with different scales have a genuinely undefined boundary.
    public func resolve(
        point: PDFPoint,
        policy: ScaleRegionResolutionPolicy = .strict
    ) -> ScaleRegionResolution {
        decide(hits: containingRegionIndices(of: point), policy: policy)
    }

    /// Which region owns a whole piece of geometry.
    ///
    /// Every vertex is resolved; the answers must agree. They do not agree when the geometry
    /// spans two regions (``ScaleRegionAmbiguityReason/geometryCrossesRegionBoundary``) or when
    /// it leaves the regions entirely
    /// (``ScaleRegionAmbiguityReason/geometryPartlyOutsideAnyRegion``). Both are returned as
    /// ``ScaleRegionResolution/ambiguous(_:)`` — the caller then applies the user's
    /// ``ScaleRegionCrossingPolicy``: split at the boundary, ask, or block.
    ///
    /// Under ``ScaleRegionResolutionPolicy/highestPriorityWins`` each vertex is first given its
    /// own owner — the strictly highest-priority region containing it — and the geometry
    /// resolves only when every vertex has the same owner (BH-162). A vertex in `A` alone and a
    /// vertex in `A ∩ B` with `B` on top have owners `A` and `B`: the markup runs out of the
    /// area priority gives to `A` into the area it gives to `B`, which is a crossing, not an
    /// overlap priority can break.
    ///
    /// Vertex sampling is exact for the case that matters (a polyline or polygon whose vertices
    /// are the only places its scale could be read) and conservative elsewhere: a segment whose
    /// two ends are in the same region but which bulges through a third is not detected. That
    /// case is documented rather than solved because it requires clipping every edge against
    /// every boundary, and because a region is by construction a convex-ish view frame on a
    /// drawing sheet.
    public func resolve(
        geometry points: [PDFPoint],
        policy: ScaleRegionResolutionPolicy = .strict
    ) throws -> ScaleRegionResolution {
        guard !points.isEmpty else { throw ScaleApplicationError.emptyGeometry }

        // Region positions double as priority ranks, so a bitmap replaces `seen.contains`.
        var seenMask = [Bool](repeating: false, count: regions.count)
        var seen: [Int] = []
        var sawPageDefault = false
        var sawPointLevelOverlap = false
        // Per-vertex owners, for the priority policy only.
        var commonOwner: Int?
        var ownersAgree = true
        var sawTiedVertex = false

        for point in points {
            let hits = containingRegionIndices(of: point)
            if hits.isEmpty {
                sawPageDefault = true
                continue
            }
            if hits.count > 1 { sawPointLevelOverlap = true }
            for hit in hits where !seenMask[hit] {
                seenMask[hit] = true
                seen.append(hit)
            }
            if policy == .highestPriorityWins {
                // `hits` is in rank order, so `hits[0]` carries the highest priority.
                if hits.count > 1, regions[hits[1]].priority == regions[hits[0]].priority {
                    sawTiedVertex = true
                } else if let owner = commonOwner {
                    if owner != hits[0] { ownersAgree = false }
                } else {
                    commonOwner = hits[0]
                }
            }
        }

        if seen.isEmpty { return .pageDefault }
        if seen.count == 1 && !sawPageDefault && !sawPointLevelOverlap {
            return .region(regions[seen[0]].id)
        }

        let reason: ScaleRegionAmbiguityReason
        if sawPointLevelOverlap {
            reason = .pointInOverlappingRegions
        } else if seen.count > 1 {
            reason = .geometryCrossesRegionBoundary
        } else {
            reason = .geometryPartlyOutsideAnyRegion
        }
        let candidates = seen.sorted().map { regions[$0].id }

        // Priority can only break a true overlap, never a genuine crossing: a markup that spans
        // two adjacent regions has no single correct scale no matter what the priorities say.
        if policy == .highestPriorityWins, reason == .pointInOverlappingRegions, !sawPageDefault {
            if sawTiedVertex {
                return .ambiguous(
                    ScaleRegionAmbiguity(
                        candidates: candidates,
                        includesPageDefault: false,
                        reason: .tiedPriorities
                    )
                )
            }
            if ownersAgree, let owner = commonOwner {
                return .region(regions[owner].id)
            }
            return .ambiguous(
                ScaleRegionAmbiguity(
                    candidates: candidates,
                    includesPageDefault: false,
                    reason: .geometryCrossesRegionBoundary
                )
            )
        }

        return .ambiguous(
            ScaleRegionAmbiguity(
                candidates: candidates,
                includesPageDefault: sawPageDefault,
                reason: reason
            )
        )
    }

    /// Convenience for a markup's geometry bundle: resolves over ``samplePoints(of:tool:)``.
    public func resolve(
        geometry: MeasurementGeometry,
        tool: MeasurementTool? = nil,
        policy: ScaleRegionResolutionPolicy = .strict
    ) throws -> ScaleRegionResolution {
        try resolve(geometry: Self.samplePoints(of: geometry, tool: tool), policy: policy)
    }

    /// The largest distance, in page points, between an arc and the chords of its samples.
    public static let arcSampleTolerance = 0.25

    /// The points a Scale Region resolution of `geometry` is taken over — the one sampler.
    ///
    /// Every kind of geometry contributes the points that decide where it sits: a polyline its
    /// vertices, an area every vertex of its outer ring and of its cutouts, a count its symbol
    /// positions. A circle contributes its centre and the four extremes of its bounding box,
    /// because a circle whose centre is inside a region but whose rim is not is exactly the
    /// ambiguity the prompt exists for. Every arc — an arc edge of a chain or a ring (ADR-0030
    /// §5.6) and a loose arc alike — is sampled along its curve, within
    /// ``arcSampleTolerance``, and a loose arc also at its mid-sweep point, never at its centre:
    /// the centre is not on the drawn curve and lies outside the region for any shallow arc
    /// traced along a wall (BH-552).
    ///
    /// An Ellipse Area or Ellipse Cutout (`tool`) stores the corners of the box it is drawn in,
    /// and nothing is drawn or measured at them: it is sampled on the ellipse inscribed in
    /// ``MeasurementGeometry/ellipseBox`` — its centre, its four quadrant points and points
    /// along the curve within ``arcSampleTolerance`` — and never at the corners. Sampling the
    /// corners raised a false "crosses a region" prompt for an ellipse wholly inside a region
    /// whose box corner poked out, and resolved an ellipse bulging out through a notch to the
    /// region because both corners were inside (U-090).
    ///
    /// There used to be two samplers. This one was reached only by tests; the app committed
    /// through a copy in AppCore that gave a loose arc only its two ends and skipped cutouts, so
    /// an arc bulging out of a region with both ends inside resolved to the region in the running
    /// app while the BH-552 test asserted `.ambiguous` (R-170).
    public static func samplePoints(of geometry: MeasurementGeometry, tool: MeasurementTool? = nil) -> [PDFPoint] {
        if tool == .ellipseArea || tool == .ellipseCutout {
            return geometry.ellipseBox.map(ellipseSamples(in:)) ?? []
        }
        var points = geometry.points
        if geometry.validPointBulges != nil {
            points.append(contentsOf: arcSamples(of: PolygonRing(
                points: geometry.points,
                isClosed: false,
                bulges: geometry.pointBulges
            )))
        }
        for segment in geometry.segments {
            points.append(segment.start)
            points.append(segment.end)
        }
        for polygon in geometry.polygons {
            for ring in [polygon.outer] + polygon.holes {
                points.append(contentsOf: ring.points)
                points.append(contentsOf: arcSamples(of: ring))
            }
        }
        for arc in geometry.arcs {
            points.append(arc.startPoint)
            points.append(arc.endPoint)
            let middle = arc.startAngle + arc.sweepAngle / 2
            points.append(PDFPoint(
                x: arc.center.x + arc.radius * Foundation.cos(middle),
                y: arc.center.y + arc.radius * Foundation.sin(middle)
            ))
            points.append(contentsOf: curveSamples(of: arc))
        }
        for circle in geometry.circles {
            points.append(circle.center)
            points.append(PDFPoint(x: circle.center.x + circle.radius, y: circle.center.y))
            points.append(PDFPoint(x: circle.center.x - circle.radius, y: circle.center.y))
            points.append(PDFPoint(x: circle.center.x, y: circle.center.y + circle.radius))
            points.append(PDFPoint(x: circle.center.x, y: circle.center.y - circle.radius))
        }
        for countPoint in geometry.countPoints { points.append(countPoint.position) }
        return points
    }

    /// The ellipse inscribed in `box`: its centre, its four quadrant points, and points at equal
    /// parameter steps with every chord within ``arcSampleTolerance`` of the curve.
    ///
    /// The ellipse is the circle of radius `R = max(a, b)` scaled by `a / R` across and `b / R`
    /// up, a map that shortens every distance, so sampling it at the step that keeps the circle's
    /// chords within the tolerance keeps the ellipse's chords within it too.
    static func ellipseSamples(in box: PDFRect) -> [PDFPoint] {
        let centre = box.center
        let a = box.width / 2
        let b = box.height / 2
        guard centre.isFinite, a.isFinite, b.isFinite else { return [] }
        var points = [
            centre,
            PDFPoint(x: centre.x + a, y: centre.y), PDFPoint(x: centre.x, y: centre.y + b),
            PDFPoint(x: centre.x - a, y: centre.y), PDFPoint(x: centre.x, y: centre.y - b)
        ]
        let radius = Swift.max(a, b)
        guard radius > 0 else { return points }
        // The one step rule (V-084): it had its own copy with a 1e-3 rad floor.
        let steps = BulgeArc.chordSteps(radius: radius, sweep: 2 * Double.pi, tolerance: arcSampleTolerance, minimum: 4)
        for step in 0..<steps {
            let angle = 2 * Double.pi * Double(step) / Double(steps)
            points.append(PDFPoint(x: centre.x + a * Foundation.cos(angle), y: centre.y + b * Foundation.sin(angle)))
        }
        return points
    }

    /// Points strictly inside a ring's or chain's arc edges (its vertices are counted already).
    static func arcSamples(of ring: PolygonRing) -> [PDFPoint] {
        guard ring.hasArcs else { return [] }
        var samples: [PDFPoint] = []
        for edge in ring.bulgedEdges where edge.bulge != 0 {
            samples.append(contentsOf: BulgeArc.flattened(
                from: edge.start, to: edge.end, bulge: edge.bulge, tolerance: arcSampleTolerance
            ).dropLast())
        }
        return samples
    }

    /// Points strictly inside a loose arc, at equal angles, with every chord within
    /// ``arcSampleTolerance`` of the curve — the step rule `BulgeArc.flattened` uses, called
    /// rather than copied (V-084).
    static func curveSamples(of arc: ArcGeometry) -> [PDFPoint] {
        let sweep = arc.sweepAngle
        guard sweep.isFinite, sweep != 0, arc.radius.isFinite, arc.radius > 0 else { return [] }
        let steps = BulgeArc.chordSteps(radius: arc.radius, sweep: sweep, tolerance: arcSampleTolerance)
        return (1..<steps).map { step in
            let angle = arc.startAngle + sweep * Double(step) / Double(steps)
            return PDFPoint(
                x: arc.center.x + arc.radius * Foundation.cos(angle),
                y: arc.center.y + arc.radius * Foundation.sin(angle)
            )
        }
    }

    // MARK: - Internals

    /// Positions in ``regions`` (so, ranks) of every region containing `point`, ascending.
    ///
    /// The R-tree query box is the point inflated by ``GeometryEpsilon/onSegment``: `classify`
    /// counts anything within that distance of an edge as on the boundary, so a zero-size query
    /// would drop a point just outside a region's bounding box that the boundary rule accepts,
    /// making the rule asymmetric across the edge (BH-553).
    private func containingRegionIndices(of point: PDFPoint) -> [Int] {
        let reach = epsilon.onSegment
        let box = PDFRect(
            corner: PDFPoint(x: point.x - reach, y: point.y - reach),
            opposite: PDFPoint(x: point.x + reach, y: point.y + reach)
        )
        var hits: [Int] = []
        for candidate in index.query(box) {
            switch PolygonMath.classify(point, in: regions[candidate].boundary.points, epsilon: epsilon) {
            case .inside, .onBoundary: hits.append(candidate)
            case .outside: continue
            }
        }
        hits.sort()
        return hits
    }

    private func decide(hits: [Int], policy: ScaleRegionResolutionPolicy) -> ScaleRegionResolution {
        guard let top = hits.first else { return .pageDefault }
        if hits.count == 1 { return .region(regions[top].id) }
        let candidates = hits.map { regions[$0].id }
        if policy == .highestPriorityWins {
            // Rank order: the top is unique exactly when the runner-up has a lower priority.
            if regions[hits[1]].priority < regions[top].priority { return .region(regions[top].id) }
            return .ambiguous(
                ScaleRegionAmbiguity(candidates: candidates, includesPageDefault: false, reason: .tiedPriorities)
            )
        }
        return .ambiguous(
            ScaleRegionAmbiguity(
                candidates: candidates,
                includesPageDefault: false,
                reason: .pointInOverlappingRegions
            )
        )
    }

    /// The scale that applies, given a resolution and the page default.
    ///
    /// - Throws: ``ScaleApplicationError/unknownScale(_:region:)`` when a region names a scale
    ///   the table does not hold. Returns `nil` for an ambiguous resolution — deliberately, so a
    ///   caller cannot accidentally treat "ask the user" as "use the default".
    public func scale(
        for resolution: ScaleRegionResolution,
        pageDefault: ScaleTransform,
        scales: [ScaleID: ScaleTransform]
    ) throws -> ScaleTransform? {
        switch resolution {
        case .pageDefault:
            return pageDefault
        case .region(let id):
            guard let rank = rankByID[id] else { return nil }
            let region = regions[rank]
            guard let scale = scales[region.scaleID] else {
                throw ScaleApplicationError.unknownScale(region.scaleID, region: id)
            }
            return scale
        case .ambiguous:
            return nil
        }
    }
}
