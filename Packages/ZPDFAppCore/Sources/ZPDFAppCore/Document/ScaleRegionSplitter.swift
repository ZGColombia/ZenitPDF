import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFMeasurementEngine

/// One piece of a measurement that was cut at a Scale Region boundary.
public struct ScaleRegionSplitPart: Sendable, Hashable {

    /// The region the piece lies in, or `nil` for the part outside every region.
    public let regionID: ScaleRegionID?
    /// The piece's vertices, in the original order.
    public let points: [PDFPoint]
    /// The arc segments of a chain piece (ADR-0030 §5.6), one bulge per point in
    /// ``MeasurementGeometry/pointBulges``'s convention; `nil` when every edge is straight.
    public let bulges: [Double]?
    /// The piece of an **area**, when an area was cut: its ring (with any arcs) as a polygon.
    /// `nil` for a chain piece.
    public let polygon: PolygonGeometry?

    /// Creates a part.
    public init(regionID: ScaleRegionID?, points: [PDFPoint], bulges: [Double]? = nil, polygon: PolygonGeometry? = nil) {
        self.regionID = regionID
        self.points = points
        self.bulges = bulges
        self.polygon = polygon
    }

    /// The geometry a piece is stored with: the area piece's polygon, or the chain piece's points
    /// with their bulges.
    public func geometry(pageID: PageID) -> MeasurementGeometry {
        if let polygon { return MeasurementGeometry(pageID: pageID, polygons: [polygon]) }
        return MeasurementGeometry(pageID: pageID, points: points, pointBulges: bulges)
    }
}

/// Cuts a measurement at the Scale Region boundaries it crosses (spec §10.4, outcome 1).
///
/// # What this can and cannot cut, and why the difference is load-bearing
///
/// **Polylines it can cut.** A length or polylength is a chain of segments, and cutting one at a
/// boundary is a segment-against-segment intersection followed by a point-in-polygon test on each
/// resulting piece. Both primitives are `ZPDFGeometry`'s, public and already gated; this file
/// composes them and adds no arithmetic of its own.
///
/// **Areas it can, since ADR-0030 §5.6.** Clipping a polygon against another polygon is a boolean
/// operation, and this file still writes none of its own: an area is cut with
/// `ZPDFMeasurementEngine`'s exact ring booleans (`ArcRingBoolean`), the ones Split and Merge use
/// for arcs — crossings solved in closed form, arcs cut on their circles, and the pieces checked
/// to sum to the whole before they are offered. (Until then the only boolean was the Clipper2
/// `CutoutSolver`, internal and shaped for holes, so areas were never offered the cut.) An area
/// that would need a hole — a region wholly inside it — is still not cut: a hole is a cutout, and
/// a split does not invent one.
///
/// **Counts it cannot**, for the reason the crossing prompt already states: a count group's
/// symbols are placements, not a path, so there is no boundary to cut at.
///
/// So ``split(polyline:resolver:)`` returns `nil` whenever the cut cannot be made exactly, the
/// caller offers "Split at the boundary" only when it returned parts, and the estimator is never
/// shown an outcome the app cannot deliver. The other two outcomes — one chosen scale, or refuse
/// the measurement — are always available.
public enum ScaleRegionSplitter {

    /// Whether a measurement's *tool* survives being cut into pieces that are each measured on
    /// their own.
    ///
    /// Only the chain tools do: a length, a dimension, a polylength and a true sloped length
    /// on one plane are the sum of their pieces. Every other points-only tool is not — a
    /// Radius cut at a boundary became two radii with fabricated areas, a Slope or a Rise/Drop
    /// applied its whole rise to each shorter piece, a Three-Point Circle piece described a
    /// different circle, and a two-point Angle piece was refused after the split had been
    /// offered (BH-004, BH-006). For those tools "Split at the boundary" is not offered.
    ///
    /// Since ADR-0030 §5.6 the plan-area tools are cut too, through the exact ring booleans: an
    /// area, a rectangle and a volume are the sum of their pieces (net area, and net area × the
    /// one depth), and a true sloped area on one plane is (plan area × one factor). Their pieces'
    /// perimeters include the boundary they were cut along, exactly as Split Area's parts do. A
    /// Perimeter or a Wall Area is *not* cut: its quantity is the boundary, and a piece's boundary
    /// includes the cut.
    public static func isCuttable(_ record: MarkupRecord) -> Bool {
        switch record.tool {
        case .length?, .dimension?, .polylength?:
            return true
        case .trueSlopedLength?:
            return record.parameters?.slope.mode == .uniformPlane
        case .area?, .rectangleArea?, .volume?:
            return record.cutoutMarkupIDs.isEmpty
        case .trueSlopedArea?:
            return record.cutoutMarkupIDs.isEmpty && record.parameters?.slope.mode == .uniformPlane
        default:
            return false
        }
    }

    /// The cut of a whole measurement's geometry, whichever kind it is: a chain (with or without
    /// arcs) through ``split(polyline:bulges:resolver:epsilon:)``, a plain area through
    /// ``split(area:resolver:)``. `nil` when it cannot be cut exactly.
    public static func split(
        geometry: MeasurementGeometry,
        resolver: ScaleRegionResolver,
        epsilon: GeometryEpsilon = .standard
    ) -> [ScaleRegionSplitPart]? {
        if let chain = chain(of: geometry) {
            return split(polyline: chain.points, bulges: chain.bulges, resolver: resolver, epsilon: epsilon)
        }
        if geometry.points.isEmpty, geometry.segments.isEmpty, geometry.arcs.isEmpty,
           geometry.circles.isEmpty, geometry.countPoints.isEmpty,
           geometry.polygons.count == 1, let polygon = geometry.polygons.first {
            return split(area: polygon, resolver: resolver)
        }
        return nil
    }

    /// The open chain a geometry is, with its arc segments: free points (and their bulges) and
    /// nothing else.
    public static func chain(of geometry: MeasurementGeometry) -> (points: [PDFPoint], bulges: [Double]?)? {
        guard geometry.points.count >= 2,
              geometry.segments.isEmpty,
              geometry.polygons.isEmpty,
              geometry.arcs.isEmpty,
              geometry.circles.isEmpty,
              geometry.countPoints.isEmpty
        else { return nil }
        return (geometry.points, geometry.validPointBulges)
    }

    /// The open polyline a geometry is, or `nil` when it is not one.
    ///
    /// "Is a polyline" means: free points and nothing else. A geometry that also carries an
    /// area, an arc or a count is not a chain this can cut.
    public static func polyline(of geometry: MeasurementGeometry) -> [PDFPoint]? {
        // A chain with arc edges is cut by ``split(geometry:resolver:epsilon:)``, which keeps its
        // bulges (ADR-0030 §5.6); the points alone would drop them.
        guard geometry.validPointBulges == nil else { return nil }
        guard geometry.points.count >= 2,
              geometry.segments.isEmpty,
              geometry.polygons.isEmpty,
              geometry.arcs.isEmpty,
              geometry.circles.isEmpty,
              geometry.countPoints.isEmpty
        else { return nil }
        return geometry.points
    }

    /// Cuts a polyline into runs, each owned by one region or by the page default.
    ///
    /// - Returns: two or more parts, or `nil` when the chain lies in one place, when a cut point
    ///   falls in overlapping regions (which has no single right answer, so it is not cut), or
    ///   when a piece degenerates to a single point.
    public static func split(
        polyline points: [PDFPoint],
        resolver: ScaleRegionResolver,
        epsilon: GeometryEpsilon = .standard
    ) -> [ScaleRegionSplitPart]? {
        split(polyline: points, bulges: nil, resolver: resolver, epsilon: epsilon)
    }

    /// Cuts a chain with arc segments into runs (ADR-0030 §5.6). A straight edge is cut exactly as
    /// before; an arc edge is crossed with every boundary edge on its circle and cut into arcs of
    /// the same circle, each with the bulge of its own sweep, so every piece is measured by `r·θ`
    /// at its own region's scale. A piece is owned by the region its midpoint is in — for an arc,
    /// the midpoint of the arc, not of its chord.
    public static func split(
        polyline points: [PDFPoint],
        bulges: [Double]?,
        resolver: ScaleRegionResolver,
        epsilon: GeometryEpsilon = .standard
    ) -> [ScaleRegionSplitPart]? {
        guard points.count >= 2 else { return nil }
        let aligned = bulges.flatMap { $0.count == points.count ? $0 : nil }

        // 1. Subdivide every edge at each boundary crossing, keeping the original order.
        var subdivided: [PDFPoint] = [points[0]]
        var subBulges: [Double] = []
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let bulge = aligned?[index] ?? 0
            if bulge != 0, BulgeArc.arc(from: start, to: end, bulge: bulge) != nil {
                let pieces = arcPieces(from: start, to: end, bulge: bulge, resolver: resolver, epsilon: epsilon)
                for piece in pieces {
                    subdivided.append(piece.end)
                    subBulges.append(piece.bulge)
                }
            } else {
                let cuts = crossings(from: start, to: end, resolver: resolver, epsilon: epsilon)
                subdivided.append(contentsOf: cuts)
                subdivided.append(end)
                subBulges.append(contentsOf: Array(repeating: 0, count: cuts.count + 1))
            }
        }

        // 2. Classify each sub-segment by the region its midpoint is in. The midpoint, not an
        //    endpoint: an endpoint sitting exactly on a boundary belongs to both sides, and
        //    asking it which side the segment is on has no answer.
        guard subdivided.count >= 2 else { return nil }
        var owners: [ScaleRegionID?] = []
        owners.reserveCapacity(subdivided.count - 1)
        for index in 0..<(subdivided.count - 1) {
            let midpoint = BulgeArc.midpoint(from: subdivided[index], to: subdivided[index + 1], bulge: subBulges[index])
            switch resolver.resolve(point: midpoint) {
            case .pageDefault:
                owners.append(nil)
            case let .region(id):
                owners.append(id)
            case .ambiguous:
                // Overlapping regions. There is no honest cut here, and the panel's overlap
                // warning is the thing that needs answering first.
                return nil
            }
        }

        // 3. Merge consecutive sub-segments with the same owner into one run.
        var parts: [ScaleRegionSplitPart] = []
        var runStart = 0
        for index in 1...owners.count {
            let ends = index == owners.count || owners[index] != owners[runStart]
            guard ends else { continue }
            let run = Array(subdivided[runStart...index])
            if run.count >= 2 {
                let runBulges = Array(subBulges[runStart..<index]) + [0]
                parts.append(ScaleRegionSplitPart(
                    regionID: owners[runStart],
                    points: run,
                    bulges: runBulges.contains { $0 != 0 } ? runBulges : nil
                ))
            }
            runStart = index
        }

        guard parts.count >= 2 else { return nil }
        // Every part must still be a usable chain; a zero-length piece would measure nothing
        // and would put a row in the ledger that is not a measurement of anything.
        for part in parts where part.points.count < 2 { return nil }
        return parts
    }

    /// One arc edge cut at every region boundary it crosses: the pieces in order, each with its
    /// end point and bulge. An arc that crosses nothing is one piece, itself.
    static func arcPieces(
        from start: PDFPoint,
        to end: PDFPoint,
        bulge: Double,
        resolver: ScaleRegionResolver,
        epsilon: GeometryEpsilon
    ) -> [(end: PDFPoint, bulge: Double)] {
        let edge = ArcEdge(start: start, end: end, bulge: bulge)
        var hits: [(fraction: Double, point: PDFPoint)] = []
        for region in resolver.regions {
            let ring = region.boundary.points
            guard ring.count >= 3 else { continue }
            let boundaryBulges = region.boundary.validBulges
            for index in 0..<ring.count {
                let boundary = ArcEdge(start: ring[index], end: ring[(index + 1) % ring.count], bulge: boundaryBulges?[index] ?? 0)
                for crossing in edge.crossings(with: boundary, tolerance: epsilon.pointMerge)
                where crossing.point.distance(to: start) > epsilon.pointMerge && crossing.point.distance(to: end) > epsilon.pointMerge {
                    hits.append((crossing.fractionOnFirst, crossing.point))
                }
            }
        }
        hits.sort { $0.fraction < $1.fraction }
        var kept: [(fraction: Double, point: PDFPoint)] = []
        for hit in hits where hit.fraction > 0 && hit.fraction < 1 {
            if let last = kept.last, last.point.distance(to: hit.point) <= epsilon.pointMerge { continue }
            kept.append(hit)
        }
        return edge.split(at: kept.map(\.fraction), points: kept.map(\.point)).map { ($0.end, $0.bulge) }
    }

    /// Cuts a plain area (no holes) at the region boundaries it crosses, exactly (ADR-0030 §5.6):
    /// the piece in each region is the area's ring intersected with the region's, and the piece on
    /// the bare sheet is the ring less every region — arcs cut on their circles throughout.
    ///
    /// - Returns: two or more pieces whose exact areas sum to the whole, or `nil` when the area
    ///   lies in one place, when regions overlap inside it (a double count), when a piece would
    ///   need a hole (a region wholly inside the area: a hole is a cutout, which this does not
    ///   invent), or when the exact method refuses.
    public static func split(area polygon: PolygonGeometry, resolver: ScaleRegionResolver) -> [ScaleRegionSplitPart]? {
        guard polygon.holes.isEmpty, let ring = ArcRing(polygon.outer) else { return nil }
        let whole = Swift.abs(ring.signedArea)
        guard whole > 0 else { return nil }
        var parts: [ScaleRegionSplitPart] = []
        var rest: [ArcRing] = [ring]
        do {
            for region in resolver.regions {
                // A region's boundary is closed whatever its flag says (ScaleRegion's rule).
                guard let boundary = ArcRing(PolygonRing(points: region.boundary.points, isClosed: true, bulges: region.boundary.bulges)) else { return nil }
                for piece in try ArcRingBoolean.polygons(.intersection, ring, boundary) {
                    guard piece.holes.isEmpty else { return nil }
                    parts.append(ScaleRegionSplitPart(regionID: region.id, points: piece.outer.points, bulges: piece.outer.bulges, polygon: piece))
                }
                var remaining: [ArcRing] = []
                for current in rest {
                    let result = try ArcRingBoolean.apply(.difference, current, boundary)
                    guard result.allSatisfy({ $0.signedArea > 0 }) else { return nil }
                    remaining.append(contentsOf: result)
                }
                rest = remaining
            }
        } catch {
            return nil
        }
        for piece in rest {
            let polygon = PolygonGeometry(outer: piece.polygonRing)
            parts.append(ScaleRegionSplitPart(regionID: nil, points: polygon.outer.points, bulges: polygon.outer.bulges, polygon: polygon))
        }
        guard parts.count >= 2 else { return nil }
        // Overlapping regions would count their shared piece twice; the pieces must tile the area.
        let sum = parts.reduce(0.0) { $0 + Swift.abs(ArcRing($1.polygon?.outer ?? PolygonRing(points: []))?.signedArea ?? 0) }
        guard Swift.abs(sum - whole) <= Swift.max(1e-12 * whole, 1e-12) * 16 else { return nil }
        return parts
    }

    /// Where one segment crosses any region boundary, ordered along the segment.
    private static func crossings(
        from start: PDFPoint,
        to end: PDFPoint,
        resolver: ScaleRegionResolver,
        epsilon: GeometryEpsilon
    ) -> [PDFPoint] {
        let edge = SegmentGeometry(start: start, end: end)
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > epsilon.pointMerge else { return [] }

        var hits: [(t: Double, point: PDFPoint)] = []
        for region in resolver.regions {
            let ring = region.boundary.points
            guard ring.count >= 3 else { continue }
            for index in 0..<ring.count {
                let boundaryEdge = SegmentGeometry(
                    start: ring[index],
                    end: ring[(index + 1) % ring.count]
                )
                switch SegmentMath.intersect(edge, boundaryEdge, epsilon: epsilon) {
                case let .point(hit, tOnFirst, _):
                    // The intersection's own parameter, which it clamps to exactly 0 or 1 at an
                    // endpoint — not one re-derived from the hit, which can land one ulp inside
                    // the segment and emit a ~1e-13 pt sub-segment whose midpoint sits on the
                    // boundary (BH-428). A hit within merge distance of either end of the
                    // segment is a vertex on the boundary, not a crossing of this segment.
                    guard tOnFirst > 0, tOnFirst < 1,
                          hit.distance(to: start) > epsilon.pointMerge,
                          hit.distance(to: end) > epsilon.pointMerge
                    else { continue }
                    hits.append((tOnFirst, hit))
                case .collinearOverlap, .parallelDisjoint, .none:
                    // A chain running *along* a boundary is not crossing it, and cutting at
                    // the span's ends would produce a zero-length piece.
                    continue
                }
            }
        }
        hits.sort { $0.t < $1.t }

        // Two regions that abut share an edge, so the same point arrives twice. Collapse
        // duplicates rather than emitting a zero-length run between them.
        var result: [PDFPoint] = []
        for hit in hits {
            if let last = result.last,
               hypot(last.x - hit.point.x, last.y - hit.point.y) <= epsilon.pointMerge {
                continue
            }
            result.append(hit.point)
        }
        return result
    }
}
