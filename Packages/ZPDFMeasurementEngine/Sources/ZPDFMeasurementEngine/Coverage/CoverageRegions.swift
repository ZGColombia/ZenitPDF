import CoreGraphics
import Foundation
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// The page-space plumbing shared by ``CoverageMap``'s two public entry points.
///
/// Nothing here is a new boolean idiom. It is the same sequence `CutoutSolver` performs to get a
/// net area and `PolygonSplitter` performs to get a net region — clean the rings, union the
/// holes, difference them out of the outer ring — reused so that a region the coverage map calls
/// "covered" is exactly the region the ledger calls "measured".
enum CoverageRegions {

    // MARK: - The one area routine

    /// The **only** area routine the coverage map uses, on every path set, on both sides of every
    /// ratio it reports.
    ///
    /// This matters more here than anywhere else in the package. A percentage built from two
    /// different area algorithms — a shoelace for the rectangle and a boolean for the measured
    /// union, say — can be wrong in a way that neither algorithm is wrong: the disagreement
    /// between them shows up as coverage that never quite reaches 100 % on a fully measured
    /// sheet, and an estimator who is told 99.98 % goes looking for a region that is not there.
    ///
    /// `Clipper2.area` is a Kahan-compensated shoelace over the signed rings, so holes (which
    /// come back from every boolean wound opposite to their outer ring) subtract themselves and
    /// the absolute value is the net area.
    static func pdfArea(of paths: ClipperPaths) -> Double {
        Swift.abs(Clipper2.area(of: paths))
    }

    /// The net area of one assembled polygon, through the same routine.
    static func pdfArea(of polygon: PolygonGeometry) -> Double {
        pdfArea(of: rings(of: polygon))
    }

    /// A polygon's outer ring and holes as Clipper paths, in the winding they were stored with.
    static func rings(of polygon: PolygonGeometry) -> ClipperPaths {
        let solvable = flattened(polygon)
        var result: ClipperPaths = [solvable.outer.uniquePoints.map(CutoutSolver.cgPoint)]
        for hole in solvable.holes {
            result.append(hole.uniquePoints.map(CutoutSolver.cgPoint))
        }
        return result
    }

    /// The polygon every Clipper2 step of the coverage map and the double-count guard sees: rings
    /// with arc edges flattened to ``ArealMeasure/arcFlatteningTolerance`` (ADR-0030 §5.2 item 3),
    /// the polygon itself when nothing bends.
    ///
    /// Before ADR-0030 §5.7 these paths took the stored vertices as they were, so an arc entered
    /// the boolean as its chord: two areas overlapping only inside an arc's bulge were never
    /// reported, and the covered region stopped at the chord.
    static func flattened(_ polygon: PolygonGeometry) -> PolygonGeometry {
        guard polygon.outer.hasArcs || polygon.holes.contains(where: \.hasArcs) else { return polygon }
        return PolygonGeometry(
            outer: polygon.outer.flattened(tolerance: ArealMeasure.arcFlatteningTolerance),
            holes: polygon.holes.map { $0.flattened(tolerance: ArealMeasure.arcFlatteningTolerance) }
        )
    }

    // MARK: - Regions

    /// One measured area's **net region**: outer ring minus the union of its holes.
    ///
    /// The holes are unioned before they are subtracted, for the reason spec 12.4 gives —
    /// overlapping cutouts must not be removed twice — and the subtraction is a Clipper2
    /// difference rather than an arithmetic one, so a cutout hanging over the parent's edge
    /// removes only the part that is actually inside.
    ///
    /// A hole is *not covered*. A courtyard cut out of a measured area is a region nobody
    /// measured, and the coverage map says so: it stays lit, exactly like unmeasured sheet.
    static func netRegion(
        of polygon: PolygonGeometry,
        options: MeasurementEngineOptions
    ) throws(MeasurementEngineError) -> ClipperPaths {
        // `resolve` already ran the union and the difference (IM-004); reuse its paths instead
        // of running both booleans a second time on the same input.
        try EngineClipper.netPaths(of: try resolve(flattened(polygon), options: options), scale: options.clipperScale)
    }

    /// The net regions of every measured area, in input order.
    static func netRegions(
        of measured: [PolygonGeometry],
        options: MeasurementEngineOptions
    ) throws(MeasurementEngineError) -> [ClipperPaths] {
        var result: [ClipperPaths] = []
        result.reserveCapacity(measured.count)
        for polygon in measured {
            result.append(try netRegion(of: polygon, options: options))
        }
        return result
    }

    /// The extent rectangle as a single counter-clockwise Clipper path.
    ///
    /// Built from the standardised corners, so a `PDFRect` stored with negative extents — legal,
    /// PDF boxes are two corners in any order — describes the same region here as everywhere else.
    static func rectanglePath(_ rect: PDFRect) -> ClipperPath {
        let box = rect.standardized
        return [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY)
        ]
    }

    // MARK: - Determinism

    /// Descending net area, then ascending minimum x, then ascending minimum y of the outer ring.
    ///
    /// The same total order ``SplitResult/parts(_:)`` uses, and for the same reason: a coverage
    /// overlay that renumbers its regions between two runs over identical input is one an
    /// estimator cannot compare against anything, and the commonest fixture of all — a sheet cut
    /// into equal halves — produces regions of exactly equal area, where the area alone decides
    /// nothing.
    static func ordered(_ polygons: [PolygonGeometry]) -> [PolygonGeometry] {
        EngineClipper.ordered(polygons.map { (polygon: $0, area: pdfArea(of: $0)) })
    }

    /// Ring soup from a boolean, reassembled into ordered polygons.
    static func polygons(
        from paths: ClipperPaths,
        options: MeasurementEngineOptions
    ) throws(MeasurementEngineError) -> [PolygonGeometry] {
        ordered(try RingAssembly.polygons(from: paths, options: options))
    }

    // MARK: - Bridging

    private static func resolve(
        _ polygon: PolygonGeometry,
        options: MeasurementEngineOptions
    ) throws(MeasurementEngineError) -> CutoutSolver.Resolved {
        var warnings = WarningLog()
        do {
            return try CutoutSolver.resolve(
                polygon,
                policy: .subtractFromArea,
                options: options,
                warnings: &warnings
            )
        } catch {
            throw MeasurementEngineError.wrapping(error, tool: .area)
        }
    }

}
