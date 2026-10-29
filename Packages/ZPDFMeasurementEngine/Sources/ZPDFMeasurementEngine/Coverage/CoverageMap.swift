import CoreGraphics
import Foundation
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// The coverage map, engine half: which part of a sheet the area measurements already account
/// for, which part is still unaccounted for, and what fraction of *what* that is.
///
/// # What the caller must do before calling this
///
/// **`measured` is the quantity-producing areas on one page, and nothing else.** The engine
/// cannot tell an area measurement from a decoration, and it does not try: a `PolygonGeometry`
/// carries a ring and its holes, not the markup's subject, tool, visibility or ledger role. Every
/// polygon handed to ``coverage(of:within:)`` is treated as measured sheet.
///
/// Invariant: decoration never counts as coverage — **only quantity-producing areas dim the
/// sheet.** Honouring it is a filtering
/// decision at the document layer, where subject, tool and visibility live. Concretely, the
/// caller passes committed area markups whose measurement produces a quantity, and leaves out
/// clouds, highlights, hatched call-outs, legend boxes, revision bubbles, zone outlines and
/// anything else shaped like a polygon that nobody is billing for. If a decorative polygon
/// reaches this call, the sheet dims where nothing was measured, the percentage climbs, and the
/// overlay lies in the one direction it must never lie: it says a region is accounted for when it
/// is not.
///
/// # What the caller must not do
///
/// **Do not synthesise the extent.** ``CoverageExtent`` is `.inkBounds` when the vector
/// extraction produced ink bounds for this page and `.pageBox` when it did not. The engine will
/// not derive ink bounds from the measured polygons — that would make the denominator a function
/// of the numerator, and the percentage would rise towards 100 % simply because the estimator
/// stopped measuring.
///
/// # The union comes first
///
/// Two areas that overlap cover their shared region once. The map therefore unions the measured
/// net regions *before* it measures anything, and the uncovered regions are the extent minus that
/// union. A coverage map built by summing areas would report more than 100 % coverage on exactly
/// the drawing that has a genuine double count, and would hide it rather than show it.
///
/// The double count is not thrown away: ``OverlapGuard/overlaps(of:floor:options:)`` names the
/// pairs of measured areas that overlap, from the same net regions, and is the one overlap rule
/// in the engine (R-175).
///
/// # Holes are not covered
///
/// A courtyard cut out of a measured area was not measured. Every measured polygon is reduced to
/// its net region — `difference(outer, union(holes))`, the same idiom `CutoutSolver` and
/// `PolygonSplitter` use — so a hole stays lit in the overlay and appears in
/// ``CoverageResult/uncoveredPolygons`` as a region of its own.
///
/// # Page space only
///
/// Everything here is canonical PDF page space in points. No `ScaleTransform` is applied, no
/// real-world unit is produced, and nothing this type returns is a takeoff quantity or belongs in
/// the Quantity Ledger. Areas exist here to be divided by each other.
public struct CoverageMap: Sendable {

    public let options: CoverageOptions

    public init(options: CoverageOptions = .default) {
        self.options = options
    }

    // MARK: - Coverage

    /// The coverage of `extent` by `measured`.
    ///
    /// - Parameters:
    ///   - measured: the **quantity-producing** areas on one page, in page space. See the type's
    ///     documentation: filtering decoration out of this list is the caller's job and the
    ///     coverage invariant depends on it. Order does not affect the result.
    ///   - extent: the rectangle to divide by, and the name of where it came from. Pass
    ///     ``CoverageExtent/inkBounds(_:)`` whenever the vector extraction has produced ink
    ///     bounds for the page.
    /// - Returns: covered and uncovered regions, both areas, the fraction, and the denominator's
    ///   name.
    /// - Throws: ``MeasurementEngineError`` for geometry the engine cannot interpret — a
    ///   non-finite coordinate, a ring with fewer than three unique points, a self-intersecting
    ///   ring under ``SelfIntersectionPolicy/reject``, or a Clipper2 failure. One unusable
    ///   polygon fails the whole map rather than being skipped: a coverage overlay that quietly
    ///   drops a region it could not parse would show that region as unmeasured, which is
    ///   indistinguishable from the answer the estimator is looking for.
    public func coverage(
        of measured: [PolygonGeometry],
        within extent: CoverageExtent
    ) throws(MeasurementEngineError) -> CoverageResult {
        let rect = extent.rect
        guard rect.isFinite else {
            throw MeasurementEngineError.measurement(.nonFiniteCoordinate)
        }

        let extentPaths: ClipperPaths = [CoverageRegions.rectanglePath(rect)]
        let extentArea = CoverageRegions.pdfArea(of: extentPaths)

        // A degenerate extent — a zero-width ink-bounds box on a page whose extraction found a
        // single straight line, for instance — has nothing to be a fraction of. Zero is the only
        // honest answer, and it is not an error: the page is real, the denominator is empty.
        guard extentArea > options.engine.epsilon.areaFloor else {
            return CoverageResult(
                coveredPolygons: [],
                uncoveredPolygons: [],
                coveredPDFArea: 0,
                extentPDFArea: extentArea,
                coveredFraction: 0,
                denominator: extent.kind
            )
        }

        let union = try unionOfMeasured(try CoverageRegions.netRegions(of: measured, options: options.engine))

        guard !union.isEmpty else {
            let uncoveredPaths = try EngineClipper.run {
                () throws(ClipperError) -> ClipperPaths in
                try Clipper2.normalized(
                    extentPaths,
                    fillRule: .nonZero,
                    scale: options.engine.clipperScale
                )
            }
            return CoverageResult(
                coveredPolygons: [],
                uncoveredPolygons: try CoverageRegions.polygons(
                    from: uncoveredPaths,
                    options: options.engine
                ),
                coveredPDFArea: 0,
                extentPDFArea: extentArea,
                coveredFraction: 0,
                denominator: extent.kind
            )
        }

        // Clip to the extent. A measured area that runs off the drawn extent — a hatch that
        // overshoots the plan, an area measured across a fold — must contribute only the part
        // inside, or the fraction exceeds 1 for a sheet that is not fully measured.
        let coveredPaths = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.intersection(
                union,
                extentPaths,
                fillRule: .nonZero,
                scale: options.engine.clipperScale
            )
        }
        let uncoveredPaths = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.difference(
                extentPaths,
                union,
                fillRule: .nonZero,
                scale: options.engine.clipperScale
            )
        }

        let coveredArea = CoverageRegions.pdfArea(of: coveredPaths)
        return CoverageResult(
            coveredPolygons: try CoverageRegions.polygons(
                from: coveredPaths,
                options: options.engine
            ),
            uncoveredPolygons: try CoverageRegions.polygons(
                from: uncoveredPaths,
                options: options.engine
            ),
            coveredPDFArea: coveredArea,
            extentPDFArea: extentArea,
            coveredFraction: Swift.min(Swift.max(coveredArea / extentArea, 0), 1),
            denominator: extent.kind
        )
    }

    // MARK: - Candidate pairs

    /// For each box `i`, the indices `j > i` whose box intersects it, ascending (IM-068). The
    /// candidate-pair search of ``OverlapGuard``, the engine's one overlap rule (R-175).
    ///
    /// A packed R-tree turns the `n(n-1)/2` box tests of the old double loop into one query per
    /// box. The tree is only a prefilter: every hit is re-checked with `PDFRect.intersects`, the
    /// predicate the double loop used, and the query box is grown by a hair so the tree's own
    /// `origin + size` arithmetic cannot drop a pair that touches to the last ulp. The pair set is
    /// therefore identical to the double loop's. A nil box (a polygon with no outer points)
    /// pairs with nothing, as before.
    static func intersectingPartners(of boxes: [PDFRect?]) -> [[Int]] {
        var partners = Array(repeating: [Int](), count: boxes.count)
        var indexed: [PDFRect] = []
        var original: [Int] = []
        indexed.reserveCapacity(boxes.count)
        original.reserveCapacity(boxes.count)
        for (index, box) in boxes.enumerated() {
            if let box, box.isFinite {
                indexed.append(box)
                original.append(index)
            }
        }
        guard let tree = try? PackedRTree(boxes: indexed) else {
            // Unreachable for finite boxes; the exhaustive loop is the reference behaviour.
            for i in 0..<boxes.count {
                guard let left = boxes[i] else { continue }
                for j in (i + 1)..<boxes.count where boxes[j].map(left.intersects) == true {
                    partners[i].append(j)
                }
            }
            return partners
        }
        var hits: [Int] = []
        for (position, left) in indexed.enumerated() {
            let i = original[position]
            let slack = 1e-9 * Swift.max(1, Swift.abs(left.minX), Swift.abs(left.maxX), Swift.abs(left.minY), Swift.abs(left.maxY))
            let probe = PDFRect(
                corner: PDFPoint(x: left.minX - slack, y: left.minY - slack),
                opposite: PDFPoint(x: left.maxX + slack, y: left.maxY + slack)
            )
            hits.removeAll(keepingCapacity: true)
            tree.query(probe, into: &hits)
            var row: [Int] = []
            for hit in hits {
                let j = original[hit]
                if j > i, left.intersects(indexed[hit]) { row.append(j) }
            }
            row.sort()
            partners[i] = row
        }
        return partners
    }

    // MARK: - Stages

    /// The union of every measured area's net region, unclipped.
    ///
    /// Each net region arrives with Clipper2's own ring orientation — outer rings one way, holes
    /// the other — so the non-zero union over the concatenation is plain set union, and a hole
    /// that a *second* measured area covers is correctly filled: winding `+1 - 1 + 1`.
    private func unionOfMeasured(
        _ regions: [ClipperPaths]
    ) throws(MeasurementEngineError) -> ClipperPaths {
        guard !regions.isEmpty else { return [] }
        var all: ClipperPaths = []
        for region in regions {
            all.append(contentsOf: region)
        }
        guard !all.isEmpty else { return [] }
        return try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.union(all, [], fillRule: .nonZero, scale: options.engine.clipperScale)
        }
    }
}
