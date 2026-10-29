import CoreGraphics
import Foundation
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// Divides one committed area with a drawn line, and gives the caller the means to prove the
/// division was honest before anything is written down.
///
/// # The pipeline
///
/// 1. The area's outer ring and holes go through the **same** `CutoutSolver` cleanup the cutout
///    pipeline uses, so the parent's net area here is the number the ledger already holds.
/// 2. The holes are unioned and subtracted from the outer ring, exactly as in spec 12.4. What
///    comes out is the *net region*: the thing the ledger actually measures, with holes carried
///    as opposite-wound rings.
/// 3. The cutting polyline is extended past the bounds of everything involved, and each side of
///    it becomes a closed clip region (see ``CutRegion``).
/// 4. Each side's parts are `net INTERSECT region`. Holes need no special handling in step 4 and
///    get none: a hole entirely on one side arrives in that side's result as a hole, and a hole
///    the cut passes through arrives as a bite out of both parts' boundaries. That is measured,
///    not assumed — `PolygonSplitTests` asserts both cases.
/// 5. The ring soup from each side is reassembled into polygons (see ``RingAssembly``), the
///    parts are measured, and a sliver refuses the whole split.
///
/// # The invariant
///
/// A split must never count area twice. Its engine-level form is: **the parts' net areas
/// sum to the parent's net area.** ``areaCheck(original:parts:)`` returns that signed error and
/// ``invariantPDFTolerance(for:)`` says how large it may be, so the command layer refuses a bad
/// split instead of storing one. The splitter deliberately does not make that decision itself —
/// refusing to store is a document-level act, and the engine is pure.
///
/// # Not a scale-aware API
///
/// Everything here is page space, in PDF points. Parts inherit their parent's subject and scale
/// by being handed back as bare geometry: the split cannot change a scale it never sees.
public struct PolygonSplitter: Sendable {

    public let options: PolygonSplitOptions

    public init(options: PolygonSplitOptions = .default) {
        self.options = options
    }

    // MARK: - Splitting

    /// Splits `polygon` with `cut` and returns the parts, or the reason it refused.
    ///
    /// - Parameters:
    ///   - polygon: the committed area, in page space, outer ring plus holes.
    ///   - cut: two or more points in page space. The line is extended past the area's bounds
    ///     before it is used, so a cut whose endpoints sit inside the area still divides it.
    /// - Returns: ``SplitResult/parts(_:)`` ordered by descending net area, or a refusal.
    /// - Throws: ``MeasurementEngineError`` only for input that cannot be interpreted at all:
    ///   a non-finite coordinate, a cut that collapses to a single point, an outer ring with
    ///   fewer than three unique vertices, or a Clipper2 failure. A cut that misses, and a cut
    ///   that would produce a sliver, are ``SplitResult`` values rather than errors.
    public func split(
        _ polygon: PolygonGeometry,
        along cut: [PDFPoint]
    ) throws(MeasurementEngineError) -> SplitResult {
        let cleanedCut = try CutRegion.cleaned(cut, epsilon: options.engine.epsilon)
        let region = try netRegion(of: polygon)
        guard !region.paths.isEmpty else {
            throw MeasurementEngineError.measurement(.degenerateArea)
        }

        let reach = CutRegion.reach(
            outer: region.outerRings.flatMap { $0 },
            cut: cleanedCut,
            factor: options.reachFactor
        )
        // Extend past the bounds so a stroke released inside the area still cuts through it,
        // then plant a vertex at every point where the extended cut crosses the region's
        // boundary, so Clipper2 has nothing left to round there.
        let anchored = CutRegion.anchored(
            CutRegion.extended(cleanedCut, by: reach),
            crossing: region.paths.map { $0.map(CutoutSolver.pdfPoint) },
            scale: options.engine.clipperScale.value,
            epsilon: options.engine.epsilon
        )

        let leftPaths = try side(.left, of: anchored, reach: reach, clipping: region.paths)
        let rightPaths = try side(.right, of: anchored, reach: reach, clipping: region.paths)

        let floor = options.engine.epsilon.areaFloor
        guard Swift.abs(Clipper2.area(of: leftPaths)) > floor,
              Swift.abs(Clipper2.area(of: rightPaths)) > floor
        else {
            return .lineMissesPolygon
        }

        var measured: [(polygon: PolygonGeometry, area: Double)] = []
        for paths in [leftPaths, rightPaths] {
            for part in try RingAssembly.polygons(from: paths, options: options.engine) {
                measured.append((polygon: part, area: try netPDFArea(of: part)))
            }
        }
        guard measured.count >= 2 else { return .lineMissesPolygon }

        if let smallest = measured.map(\.area).min(), smallest < options.minimumPartArea {
            return .degenerate(smallestPartPDFArea: smallest)
        }
        return .parts(EngineClipper.ordered(measured))
    }

    // MARK: - The invariant

    /// The signed page-space error of a split: `sum(net area of each part) - net area of the
    /// original`, in square PDF points, as a `Decimal`.
    ///
    /// Zero for a correct split. Positive means the parts claim more area than the parent had —
    /// the double count a split must never produce. Negative means area was lost.
    ///
    /// Both sides of the subtraction are produced by `CutoutSolver`, the same routine that
    /// computes a cutout net area everywhere else in this package, so this compares like with
    /// like: it cannot pass because two different area formulas happened to agree, and it
    /// cannot fail because they happened to differ.
    ///
    /// Compare the magnitude against ``invariantPDFTolerance(for:)``.
    public func areaCheck(
        original: PolygonGeometry,
        parts: [PolygonGeometry]
    ) throws(MeasurementEngineError) -> Decimal {
        let originalArea = try netPDFArea(of: original)
        var partAreas: [Double] = []
        partAreas.reserveCapacity(parts.count)
        for part in parts {
            partAreas.append(try netPDFArea(of: part))
        }
        return try EngineNumerics.decimal(EngineNumerics.sum(partAreas) - originalArea)
    }

    /// The largest magnitude ``areaCheck(original:parts:)`` may honestly return for a correct
    /// split of `polygon`, in square PDF points.
    ///
    /// Three terms, largest wins:
    ///
    /// * `epsilon.areaFloor` — the package's existing "this is zero" threshold.
    /// * `1e-12 * netArea` — the relative bound QUALITY_BAR **P6** holds the cutout booleans to.
    /// * `4 * diagonal * quantum` — the honest cost of Clipper2's integer lattice. Every vertex
    ///   the boolean introduces can move by up to half a lattice step (`quantum / 2`, where
    ///   `quantum` is `1 / clipperScale`, i.e. 1e-6 pt by default), and a displaced vertex
    ///   changes an area by roughly its displacement times the length of the edges meeting it.
    ///   Bounding those edges by the geometry's diagonal and allowing several new vertices gives
    ///   this term. It is not slack for a wrong algorithm: for coordinates that already sit on
    ///   the lattice — which every hand-derived fixture does — the quantisation is exact and the
    ///   real error is zero, which is why the tests assert 1e-9 rather than this.
    public func invariantPDFTolerance(
        for polygon: PolygonGeometry
    ) throws(MeasurementEngineError) -> Double {
        let netArea = try netPDFArea(of: polygon)
        let points = polygon.outer.uniquePoints
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for point in points {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        let width = Swift.max(maxX - minX, 0)
        let height = Swift.max(maxY - minY, 0)
        let diagonal = (width * width + height * height).squareRoot()
        let quantum = 1 / options.engine.clipperScale.value
        return Swift.max(
            options.engine.epsilon.areaFloor,
            Swift.max(1e-12 * netArea, 4 * diagonal * quantum)
        )
    }

    /// The net area of `polygon` in square PDF points, through the cutout pipeline of spec 12.4.
    ///
    /// This is the routine both sides of ``areaCheck(original:parts:)`` use, and it is the same
    /// one `MeasurementEngine` uses for `netArea`.
    public func netPDFArea(
        of polygon: PolygonGeometry
    ) throws(MeasurementEngineError) -> Double {
        try resolve(polygon).netPDFArea
    }

    // MARK: - Stages

    /// The parent's net region as Clipper2 paths: outer ring minus the union of the holes,
    /// exactly the sequence `CutoutSolver` performs to get a net area.
    private func netRegion(
        of polygon: PolygonGeometry
    ) throws(MeasurementEngineError) -> (paths: ClipperPaths, outerRings: [[PDFPoint]]) {
        let resolved = try resolve(polygon)
        // `resolve` already ran the union and the difference (IM-004).
        let paths = try EngineClipper.netPaths(of: resolved, scale: options.engine.clipperScale)
        return (paths: paths, outerRings: resolved.outerRings)
    }

    /// One side's parts: the net region intersected with that side's clip region.
    private func side(
        _ side: CutSide,
        of extendedCut: [PDFPoint],
        reach: Double,
        clipping net: ClipperPaths
    ) throws(MeasurementEngineError) -> ClipperPaths {
        let scale = options.engine.clipperScale
        let pieces = CutRegion.pieces(
            along: extendedCut,
            side: side,
            depth: reach,
            maximumFanStep: options.maximumFanStep
        )
        guard !pieces.isEmpty else { return [] }
        // The pieces are all wound counter-clockwise, so a non-zero union is set union and the
        // region comes out as one simple area even for a bent cut.
        //
        // `preservingCollinearVertices` is not a stylistic choice here. The bridge drops
        // collinear vertices by default, which would delete exactly the crossing vertices
        // `CutRegion.anchored` planted along the cut — they sit mid-edge on a straight run — and
        // hand the intersection a single long edge to re-derive them from, at one lattice step
        // of rounding each. Keeping them is what makes a slanted cut exact. The extra vertices
        // do not reach the caller: the intersection below drops its own collinear vertices, so
        // the parts still come out minimal.
        let region = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.union(
                pieces,
                [],
                fillRule: .nonZero,
                preservingCollinearVertices: true,
                scale: scale
            )
        }
        guard !region.isEmpty else { return [] }
        return try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.intersection(net, region, fillRule: .nonZero, scale: scale)
        }
    }

    // MARK: - Bridging

    private func resolve(
        _ polygon: PolygonGeometry
    ) throws(MeasurementEngineError) -> CutoutSolver.Resolved {
        var warnings = WarningLog()
        do {
            return try CutoutSolver.resolve(
                polygon,
                policy: .subtractFromArea,
                options: options.engine,
                warnings: &warnings
            )
        } catch {
            throw MeasurementEngineError.wrapping(error, tool: .area)
        }
    }

}
