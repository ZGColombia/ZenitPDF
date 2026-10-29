import CoreGraphics
import Foundation
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// The cutout pipeline of spec 12.4: `netArea = outerArea - union(cutoutAreas)`.
///
/// # Why the union comes first
///
/// Two overlapping cutouts share a region. Subtracting each one's own area from the parent
/// removes that shared region twice and reports a net area that is too small — the classic
/// takeoff error this pipeline exists to prevent. So the holes are unioned into a single region
/// *before* anything is subtracted, and the subtraction is a Clipper2 difference rather than a
/// scalar subtraction, which also handles a cutout that hangs over the parent's edge: only the
/// part actually inside the parent can be removed from it.
///
/// # Exactness
///
/// Clipper2 is an exact integer clipper. Coordinates are quantised onto a 1e-6 pt lattice by
/// ``ClipperScale/pagePoints``, roughly 3.5 µm of real space on a 1:100 drawing, which is four
/// orders of magnitude below anything a construction takeoff resolves. The no-hole case, and the
/// case where every hole lies strictly inside a simple outer ring and no two holes meet, skip
/// Clipper2 entirely and use the exact shoelace (IM-069, S-108), so the common cases carry no
/// quantisation at all. Every other case — holes that meet, a hole touching or crossing the outer
/// boundary, an unchecked outer — goes through the union and the difference, whose rings feed the
/// perimeter, the coverage map and the splitter. Even then the stored net area is measured against
/// the drawn rings: from the drawn coordinates alone (``ExactNetArea``) when the outer ring and
/// every cutout are known simple, else by the drawn-ring lattice formula, where the lattice only
/// supplies what the rings do to each other
/// (``drawnRingNetArea(outerArea:outerPaths:latticeNetArea:holes:whollyInside:canonicalOrder:scale:)``).
enum CutoutSolver {

    struct Resolved: Sendable {
        /// The outer boundary after cleanup and any normalisation, in page space.
        var outerRings: [[PDFPoint]]
        /// The cutout boundaries after cleanup, in page space.
        var holeRings: [[PDFPoint]]
        /// The boundary rings of the **net** region: the rings of the Clipper2 difference when
        /// cutouts took part, else ``outerRings``. This — not ``outerRings`` plus ``holeRings`` —
        /// is what a perimeter under `outerPlusCutoutEdges` measures. Summing every hole's full
        /// boundary counted the overlap of two overlapping holes twice, counted the part of a
        /// hole hanging outside the parent, and counted a shared parent edge twice (code review
        /// CR-21: two overlapping 4 x 4 holes gave 72 m against a true 64).
        var netRings: [[PDFPoint]]
        /// The net region as Clipper2 paths, ready to feed another boolean: the difference
        /// output when the union-and-difference ran, the oriented `[outer, hole]` pair on the
        /// exact one-hole path, and `nil` when there were no cutouts (the caller normalises the
        /// outer ring itself — the plain-area path never pays for a boolean it does not need).
        /// CoverageRegions and PolygonSplitter read this instead of redoing the booleans (IM-004).
        var netPaths: ClipperPaths?
        /// Absolute outer area in square PDF points, before cutouts.
        var outerPDFArea: Double
        /// Absolute area in square PDF points after the union of cutouts is removed, measured
        /// against the drawn rings. On the exact path it is `Clipper2.area(of: netPaths)` bit for
        /// bit (IM-004). When the union and the difference
        /// ran, ``netPaths`` sit on the 1e-6 pt lattice and this value differs from their area by
        /// the drawn rings' own lattice rounding, about `0.7e-6 pt × perimeter` (S-108).
        var netPDFArea: Double
        /// The area actually removed: `outerPDFArea - netPDFArea`.
        var cutoutPDFArea: Double
        /// The index in `PolygonGeometry.holes` of every cutout that took part, in drawn order.
        var holeIndices: [Int] = []
        /// For each cutout of ``holeIndices``, in the same order: `nil` when the drawn ring is
        /// the region it removes, or the rings of its non-zero normalisation when it crosses
        /// itself (or is over the check's vertex limit) and was normalised before the union. The
        /// exact arc net reads these for such a cutout instead of refusing the whole call (U-087).
        var normalizedHoleRings: [[[PDFPoint]]?] = []
        /// How the boundary of the net region relates to the drawn rings, for a perimeter that
        /// must measure arc edges exactly (ADR-0030 §5.2, R-181).
        var boundary: NetBoundary = .outerOnly
        /// False when ``outerRings`` is a normalisation of a crossing outer ring rather than the
        /// drawn ring itself. The exact arc-edged area and perimeter of the drawn ring then
        /// describe a region the engine did not measure, so a caller must read these rings and
        /// areas instead (S-105).
        var outerIsDrawnRing: Bool = true
    }

    /// What the boundary of the net region is made of.
    enum NetBoundary: Sendable, Equatable {
        /// No cutout took part: the boundary is the outer ring.
        case outerOnly
        /// Every cutout is a simple ring strictly inside one simple outer ring, and no two
        /// cutouts meet: the boundary is exactly the drawn outer ring plus every drawn cutout
        /// ring, so each can be measured as drawn, arcs included.
        case outerPlusDisjointHoles
        /// Every cutout lies strictly inside one simple outer ring, but some meet or overlap:
        /// the boundary is the drawn outer ring plus these rings of the union of the cutouts.
        case outerPlusUnion([[PDFPoint]])
        /// A cutout touches, crosses or hangs over the outer boundary, or the outer ring was not
        /// one known-simple ring: only the rings of the boolean difference describe the boundary.
        case booleanOnly
    }

    /// One drawn cutout on its way into the union: the cleaned ring, whether it is known to be
    /// one simple ring, and the Clipper2 paths that stand for it in the union.
    private struct HoleRegion {
        var index: Int
        var ring: [PDFPoint]
        var isKnownSimple: Bool
        var paths: ClipperPaths
    }

    /// Resolves one polygon's outer ring and holes into plan, net and cutout areas.
    static func resolve(
        _ polygon: PolygonGeometry,
        policy: CutoutPolicy,
        options: MeasurementEngineOptions,
        warnings: inout WarningLog
    ) throws -> Resolved {
        let outer = try cleanRing(
            polygon.outer,
            options: options,
            warnings: &warnings,
            requireThreePoints: true
        )

        var outerRings: [[PDFPoint]] = [outer]
        /// True once the outer ring is known to be one simple ring — the precondition of every
        /// shortcut below that avoids a boolean.
        var outerIsKnownSimple = true
        /// True while `outerRings` is the drawn ring itself, not a normalisation of it — the
        /// precondition for measuring the drawn ring, arcs included, as part of the boundary.
        var outerIsDrawnRing = true
        if outer.count > options.selfIntersectionVertexLimit {
            // The self-intersection check is skipped above the vertex limit. It used to answer
            // "not self-intersecting" silently, so a traced 50 001-vertex figure-eight was stored
            // as the difference of its lobes under either policy (BH-564). The number is still
            // returned — refusing every large traced outline would be worse — but it now says the
            // check did not run, and nothing downstream treats the ring as known-simple.
            // The warning has its own code since ADR-0018 (IM-070); it was the interim
            // `numericalPrecisionLoss`, which the UI maps to no user-facing warning.
            outerIsKnownSimple = false
            warnings.add(
                .selfIntersectionCheckSkipped,
                field: .planArea,
                detail: "vertices=\(outer.count) limit=\(options.selfIntersectionVertexLimit)"
            )
        } else if try isSelfIntersecting(outer, options: options) {
            switch options.selfIntersectionPolicy {
            case .reject:
                throw MeasurementError.selfIntersectingPolygon
            case .normalize:
                warnings.add(.selfIntersectingPolygon, field: .planArea)
                let outerPath = [outer.map(cgPoint)]
                let normalized = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
                    try Clipper2.normalized(outerPath, fillRule: .nonZero, scale: options.clipperScale)
                }
                outerRings = normalized.map { $0.map(pdfPoint) }
                outerIsKnownSimple = outerRings.count == 1
                outerIsDrawnRing = false
                warnings.add(
                    .polygonNormalized,
                    field: .planArea,
                    detail: "rings=\(outerRings.count)"
                )
            }
        }

        let outerArea = abs(area(of: outerRings))

        var holes: [HoleRegion] = []
        if policy != .ignore {
            for (index, hole) in polygon.holes.enumerated() {
                let cleaned = try cleanRing(
                    hole,
                    options: options,
                    warnings: &warnings,
                    requireThreePoints: false
                )
                guard cleaned.count >= 3 else {
                    warnings.add(
                        .fewerThanThreeUniquePoints,
                        field: .cutoutArea,
                        detail: "cutout \(index) with \(cleaned.count) unique points ignored"
                    )
                    continue
                }
                holes.append(try holeRegion(cleaned, index: index, options: options, warnings: &warnings))
            }
        }

        guard !holes.isEmpty else {
            var result = Resolved(
                outerRings: outerRings,
                holeRings: [],
                netRings: outerRings,
                netPaths: nil,
                outerPDFArea: outerArea,
                netPDFArea: outerArea,
                cutoutPDFArea: 0
            )
            result.outerIsDrawnRing = outerIsDrawnRing
            flagDegenerate(result, options: options, warnings: &warnings)
            return result
        }
        let holeRings = holes.map(\.ring)
        let holeIndices = holes.map(\.index)
        let normalizedHoleRings: [[[PDFPoint]]?] = holes.map { hole in
            hole.isKnownSimple ? nil : hole.paths.map { $0.map(pdfPoint) }
        }

        // Which cutouts lie strictly inside a simple outer ring: every vertex inside, none on
        // the boundary, no edge meeting an outer edge. For those the containment boolean can
        // only report "fully inside", so it is skipped (IM-071). A cutout that crosses itself is
        // never one of them, whatever its vertices do: its own shoelace is not its area (R-166).
        let strictlyInside: [Bool] = holes.map { hole in
            hole.isKnownSimple && outerIsKnownSimple && outerRings.count == 1
                && CutoutContainment.isStrictlyInside(hole.ring, outer: outerRings[0], epsilon: options.epsilon)
        }
        let allStrictlyInside = !strictlyInside.contains(false)

        if allStrictlyInside, CutoutContainment.arePairwiseApart(holeRings, epsilon: options.epsilon) {
            // The exact path (IM-069, S-108): a simple outer with simple holes strictly inside
            // it, no two of which meet, has net area |outer| − Σ|hole| by the shoelace, with no
            // lattice anywhere. It used to be taken for one hole only; two or more went through
            // the union and the difference, whose output sits on the 1e-6 pt lattice — outer ring
            // included — so on a 1000 pt parent with off-lattice corners the rounding moved the
            // net area by up to about 2e-3 pt², and adding a second cutout smaller than that
            // raised the stored net area (QUALITY_BAR P11).
            let outerRing = outerRings[0]
            // Clipper2's convention for a region with holes: the outer ring wound positive, each
            // hole negative — so these paths mean the same thing as a difference's output under
            // the non-zero rule when a later boolean consumes them. The holes follow the
            // canonical order, so the compensated sum is the same for every drawn order (P5).
            let orientedOuter = PolygonMath.signedArea(outerRing) >= 0 ? outerRing : outerRing.reversed()
            let orientedHoles = canonicalOrder(of: holeRings).map { index -> [PDFPoint] in
                let hole = holeRings[index]
                return PolygonMath.signedArea(hole) <= 0 ? hole : hole.reversed()
            }
            let exactRings = [orientedOuter] + orientedHoles
            let netPaths: ClipperPaths = exactRings.map { $0.map(cgPoint) }
            // The net area through the same compensated shoelace the coverage map applies to
            // these very paths (CoverageRegions.pdfArea), so the ledger's net area and the map's
            // "measured" area agree bit for bit. No lattice: Clipper2.area reads raw points.
            let netArea = abs(Clipper2.area(of: netPaths))
            var result = Resolved(
                outerRings: outerRings,
                holeRings: holeRings,
                netRings: exactRings,
                netPaths: netPaths,
                outerPDFArea: outerArea,
                netPDFArea: netArea,
                cutoutPDFArea: outerArea - netArea
            )
            result.holeIndices = holeIndices
            result.normalizedHoleRings = normalizedHoleRings
            result.boundary = outerIsDrawnRing ? .outerPlusDisjointHoles : .booleanOnly
            result.outerIsDrawnRing = outerIsDrawnRing
            flagDegenerate(result, options: options, warnings: &warnings)
            return result
        }

        let outerPaths = outerRings.map { $0.map(cgPoint) }
        // QUALITY_BAR P5: the stored net area is identical whatever order the cutouts were
        // drawn in. The union's output — which rings, which start vertices, in which order —
        // follows its input order, and the compensated shoelace over that output is only
        // order-exact for one order. So the union always sees the cutouts in one canonical
        // order (R-171). Refusals and warnings still walk the drawn order and name drawn indices.
        let order = canonicalOrder(of: holeRings)
        let holePaths = order.flatMap { holes[$0].paths }

        // Union first: overlapping cutouts must not be subtracted twice (spec 12.4).
        let unionedHoles = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.union(holePaths, [], fillRule: .nonZero, scale: options.clipperScale)
        }

        let whollyInside = try flagCutoutsOutsideParent(
            holes: holes,
            strictlyInside: strictlyInside,
            outerPaths: outerPaths,
            options: options,
            warnings: &warnings
        )

        let netPaths = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.difference(outerPaths, unionedHoles, fillRule: .nonZero, scale: options.clipperScale)
        }
        let latticeNetArea = abs(Clipper2.area(of: netPaths))
        var netArea = drawnRingNetArea(
            outerArea: outerArea,
            outerPaths: outerPaths,
            latticeNetArea: latticeNetArea,
            holes: holes,
            whollyInside: whollyInside,
            canonicalOrder: order,
            scale: options.clipperScale
        )
        // Sharpened to the drawn coordinates when one simple outer ring and simple cutouts allow
        // it: the lattice rounding of crossing points is gone too, so adding a cutout can never
        // raise the net (S-108, P11). The lattice answer stays whenever the two disagree by more
        // than its own rounding could explain.
        if latticeNetArea > 0, outerIsKnownSimple, outerRings.count == 1, holes.allSatisfy(\.isKnownSimple),
           let exact = ExactNetArea.netArea(
               outer: outerRings[0],
               holes: order.map { holeRings[$0] },
               strictlyInside: order.map { strictlyInside[$0] }
           ),
           abs(exact - netArea) <= latticeRoundingBound(outer: outerRings[0], holes: holeRings, outerArea: outerArea, scale: options.clipperScale) {
            netArea = Swift.min(outerArea, exact)
        }

        var result = Resolved(
            outerRings: outerRings,
            holeRings: holeRings,
            netRings: netPaths.map { $0.map(pdfPoint) },
            netPaths: netPaths,
            outerPDFArea: outerArea,
            netPDFArea: netArea,
            cutoutPDFArea: outerArea - netArea
        )
        result.holeIndices = holeIndices
        result.normalizedHoleRings = normalizedHoleRings
        result.outerIsDrawnRing = outerIsDrawnRing
        // Cutouts all strictly inside but not known to be apart (the exact path above took every
        // case known to be apart): the drawn outer ring plus the rings of their union.
        result.boundary = allStrictlyInside && outerIsDrawnRing
            ? .outerPlusUnion(unionedHoles.map { $0.map(pdfPoint) })
            : .booleanOnly
        flagDegenerate(result, options: options, warnings: &warnings)
        return result
    }

    /// The net area of the boolean branch, measured against the drawn rings (S-108, iteration-2
    /// re-fix; QUALITY_BAR P11).
    ///
    /// The union and the difference run on the 1e-6 pt lattice, and their output — the outer ring
    /// included — sits on it. The exact path, and ``Resolved/outerPDFArea``, read the drawn
    /// points. Storing `|difference|` therefore mixed two different outers: the same markup
    /// measured on the exact path with one cutout and on the boolean path with two was compared
    /// across the outer ring's own rounding, about `0.7e-6 pt × perimeter` — 1.5e-3 pt² on an
    /// off-lattice 1000 pt parent — so a second cutout smaller than that raised the stored net
    /// area. A tiny cutout straddling an existing cutout's edge did it by +1.55e-3 pt², one
    /// touching the outer edge from inside by +1.47e-3 pt².
    ///
    /// Now every drawn ring enters the stored value at its drawn area, and the lattice supplies
    /// only what the rings do to each other:
    ///
    /// `net = |outer| − removed`, `removed = (|outer_lattice| − |net_lattice|)
    ///        + Σ (|hole| − |hole_lattice|)` over every hole wholly inside the outer ring.
    ///
    /// `|outer_lattice| − |net_lattice|` is the area the boolean removed, measured on one lattice
    /// against one lattice outer, so the outer ring's rounding cancels. Each wholly-inside hole's
    /// own rounding is then exchanged for its drawn area, which makes the formula agree with the
    /// exact path's `Σ |hole|` whenever the holes do not in fact meet, and removes the step
    /// where adding one tiny cutout switched a large off-lattice cutout from its drawn area to
    /// its lattice one. A hole that hangs over the edge keeps its lattice area: only part of it
    /// is removed, and its drawn area is not the part that is.
    ///
    /// What is left is the lattice rounding of the region where cutouts actually overlap, or where
    /// a crossing cutout meets the outer edge, and of the rounded intersection points on those
    /// edges — bounded by about `0.7e-6 pt` times the length of the edges involved, and enough
    /// for a tiny cutout straddling a long diagonal edge to raise the net. ``ExactNetArea``
    /// removes it whenever the rings are known simple; this formula is its fallback and its
    /// cross-check.
    ///
    /// An empty difference is zero exactly, never the rounding residue (QUALITY_BAR §2.5,
    /// "cutout equals parent"), and the value stays within `[0, |outer|]`. The corrections are
    /// taken in the canonical cutout order, and ``EngineNumerics/sum(_:)`` orders its terms by
    /// magnitude, so the stored value is the same for every drawn order (P5).
    private static func drawnRingNetArea(
        outerArea: Double,
        outerPaths: ClipperPaths,
        latticeNetArea: Double,
        holes: [HoleRegion],
        whollyInside: [Bool],
        canonicalOrder: [Int],
        scale: ClipperScale
    ) -> Double {
        guard latticeNetArea > 0 else { return 0 }
        let latticeOuterArea = abs(Clipper2.area(of: outerPaths.map { quantized($0, scale: scale) }))
        var terms = [outerArea, -(latticeOuterArea - latticeNetArea)]
        for position in canonicalOrder where whollyInside[position] {
            let paths = holes[position].paths
            // A simple hole's paths are its drawn ring; a normalised one's are already on the
            // lattice, so its correction is zero.
            let drawn = abs(Clipper2.area(of: paths))
            let lattice = abs(Clipper2.area(of: paths.map { quantized($0, scale: scale) }))
            terms.append(lattice - drawn)
        }
        return Swift.min(outerArea, Swift.max(0, EngineNumerics.sum(terms)))
    }

    /// How far the drawn-ring lattice formula can honestly be from the drawn geometry: every
    /// vertex and every crossing point moves by at most `√2/2` lattice steps, and a vertex moved by
    /// `δ` moves an area by at most `δ` times the length of its two edges' halves — so the whole
    /// is bounded by about `1.5 · step · Σ perimeters`. Twice that, plus a relative floor for the
    /// Double arithmetic, is the tolerance ``ExactNetArea`` must meet to replace it. A
    /// disagreement beyond it is not rounding: the lattice answer is kept.
    private static func latticeRoundingBound(
        outer: [PDFPoint],
        holes: [[PDFPoint]],
        outerArea: Double,
        scale: ClipperScale
    ) -> Double {
        let perimeters = EngineNumerics.sum(([outer] + holes).map { PolygonMath.perimeter($0, isClosed: true) })
        return 4 * perimeters / scale.value + 1e-12 * outerArea
    }

    /// One cleaned cutout ring, checked for self-crossings the way the outer ring is (R-166).
    ///
    /// Only the outer ring used to be checked. A bowtie cutout — (4,4), (6,6), (6,4), (4,6)
    /// inside a 10 x 10 parent — passed the strictly-inside test and took the exact one-hole
    /// path, whose shoelace of a bowtie is its two lobes cancelling: net 100 instead of 98, with
    /// no warning. With a second cutout the non-zero union filled both lobes and the same cutout
    /// removed 2, so the answer depended on how many cutouts there were. A crossing cutout is
    /// now refused under `.reject`, and under `.normalize` it is warned about and replaced by
    /// its non-zero normalisation before it meets the union, so it removes what it covers.
    private static func holeRegion(
        _ ring: [PDFPoint],
        index: Int,
        options: MeasurementEngineOptions,
        warnings: inout WarningLog
    ) throws -> HoleRegion {
        if ring.count > options.selfIntersectionVertexLimit {
            // Unchecked, as for the outer ring (BH-564): measured through the union, which
            // normalises it, and never treated as known-simple.
            warnings.add(
                .selfIntersectionCheckSkipped,
                field: .cutoutArea,
                detail: "cutout \(index) vertices=\(ring.count) limit=\(options.selfIntersectionVertexLimit)"
            )
            let path = [ring.map(cgPoint)]
            let normalized = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
                try Clipper2.normalized(path, fillRule: .nonZero, scale: options.clipperScale)
            }
            return HoleRegion(index: index, ring: ring, isKnownSimple: false, paths: normalized)
        }
        guard try isSelfIntersecting(ring, options: options) else {
            // Every simple cutout ring is oriented the same way BEFORE the union. A non-zero
            // union of rings in the winding the person happened to draw lets two overlapping
            // cutouts wound opposite ways cancel in their overlap (+1 −1 = 0), so the overlap was
            // not subtracted at all — 10×10 with a CCW 4×4 and a CW 4×4 overlapping came out
            // 76 m² instead of 72 (code review CR-20, 2026-08-31). Ellipse cutouts are always
            // CCW, so a clockwise polygon cutout over one hit this in the running app.
            return HoleRegion(
                index: index,
                ring: ring,
                isKnownSimple: true,
                paths: [CutRegion.counterClockwise(ring.map(cgPoint))]
            )
        }
        switch options.selfIntersectionPolicy {
        case .reject:
            throw MeasurementError.selfIntersectingPolygon
        case .normalize:
            warnings.add(.selfIntersectingPolygon, field: .cutoutArea, detail: "cutout \(index)")
            // The non-zero normalisation fills both lobes of a bowtie and comes back in
            // Clipper2's orientation (outer rings positive), the same winding every simple
            // cutout is given above, so the union cannot cancel one cutout against another.
            let path = [ring.map(cgPoint)]
            let normalized = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
                try Clipper2.normalized(path, fillRule: .nonZero, scale: options.clipperScale)
            }
            warnings.add(
                .polygonNormalized,
                field: .cutoutArea,
                detail: "cutout \(index) rings=\(normalized.count)"
            )
            return HoleRegion(index: index, ring: ring, isKnownSimple: false, paths: normalized)
        }
    }

    /// The positions of `rings` in one canonical order that does not depend on the order they
    /// were drawn in (R-171, QUALITY_BAR P5): bounding box, then area, then vertex count, then
    /// the vertices themselves — a total order, so every permutation of the same cutouts sorts
    /// to the same sequence.
    static func canonicalOrder(of rings: [[PDFPoint]]) -> [Int] {
        let keys = rings.map(sortKey)
        return rings.indices.sorted { left, right in
            if keys[left] != keys[right] { return keys[left].lexicographicallyPrecedes(keys[right]) }
            let a = rings[left]
            let b = rings[right]
            if a.count != b.count { return a.count < b.count }
            for (p, q) in zip(a, b) {
                if p.x != q.x { return p.x < q.x }
                if p.y != q.y { return p.y < q.y }
            }
            return left < right
        }
    }

    private static func sortKey(_ ring: [PDFPoint]) -> [Double] {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for point in ring {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        return [minX, minY, maxX, maxY, PolygonMath.area(ring)]
    }

    // MARK: - Ring hygiene

    static func cleanRing(
        _ ring: PolygonRing,
        options: MeasurementEngineOptions,
        warnings: inout WarningLog,
        requireThreePoints: Bool
    ) throws -> [PDFPoint] {
        for point in ring.points where !point.isFinite {
            throw MeasurementError.nonFiniteCoordinate
        }
        if !ring.isClosed {
            warnings.add(.openPolygonClosedImplicitly, field: .planArea)
        }
        let cleanup = try PolygonCleanup.cleanup(
            ring.points,
            options: PolygonCleanupOptions(
                epsilon: options.epsilon,
                isClosedRing: true,
                removesCollinearVertices: false
            )
        )
        if cleanup.removedDuplicates > 0 {
            warnings.add(
                .duplicatePointsCollapsed,
                detail: "removed=\(cleanup.removedDuplicates)"
            )
        }
        if requireThreePoints, cleanup.points.count < 3 {
            throw MeasurementError.fewerThanThreeUniquePoints
        }
        return cleanup.points
    }

    static func isSelfIntersecting(
        _ ring: [PDFPoint],
        options: MeasurementEngineOptions
    ) throws -> Bool {
        guard ring.count >= 4, ring.count <= options.selfIntersectionVertexLimit else {
            return false
        }
        let intersections = try PolygonMath.selfIntersections(
            ring,
            isClosed: true,
            epsilon: options.epsilon,
            options: SelfIntersectionOptions(
                maximumReported: 1,
                vertexLimit: options.selfIntersectionVertexLimit
            )
        )
        return !intersections.isEmpty
    }

    // MARK: - Diagnostics

    private static func flagDegenerate(
        _ resolved: Resolved,
        options: MeasurementEngineOptions,
        warnings: inout WarningLog
    ) {
        if resolved.netPDFArea <= options.epsilon.areaFloor {
            warnings.add(
                .degenerateArea,
                field: .netArea,
                detail: "netPDFArea=\(resolved.netPDFArea)"
            )
        }
    }

    /// A cutout with no overlap at all is refused; one that only partly overlaps is accepted,
    /// subtracts the part inside, and warns (QUALITY_BAR 2.5, ADR-0015).
    ///
    /// Until code review CR-33 the no-overlap case only warned and
    /// ``MeasurementError/cutoutOutsideParent(cutoutIndex:)`` was thrown nowhere; spec 12.4
    /// requires a cutout to overlap its parent, and a cutout that removes nothing from
    /// something it is not part of is a drawing mistake the person needs to hear about, not a
    /// footnote on a correct-looking number.
    ///
    /// Returns, per hole in drawn order, whether it lies wholly inside the parent — strictly, or
    /// touching its boundary from inside, to the containment tolerance — which is when the net
    /// area may measure it by its drawn area (S-108).
    private static func flagCutoutsOutsideParent(
        holes: [HoleRegion],
        strictlyInside: [Bool],
        outerPaths: ClipperPaths,
        options: MeasurementEngineOptions,
        warnings: inout WarningLog
    ) throws -> [Bool] {
        var whollyInside = strictlyInside
        for (position, hole) in holes.enumerated() {
            // Strictly inside a simple outer: the intersection could only return the hole
            // itself, so there is nothing to flag and nothing to refuse (IM-071).
            if strictlyInside[position] { continue }
            let index = hole.index
            // Both sides of the comparison on the same lattice. `insideArea` is the area of a
            // boolean result, whose vertices sit on the ClipperScale lattice; comparing it with
            // the shoelace of the raw vertices flagged a cutout lying wholly inside its parent
            // as "only 0.99999995 inside" whenever rounding shrank it by more than the 1e-9
            // tolerance — and the warning is blocking (BH-165). The cutout is its region — a
            // crossing cutout's normalised lobes, never its self-cancelling shoelace (R-166).
            let holeArea = abs(Clipper2.area(of: hole.paths.map { quantized($0, scale: options.clipperScale) }))
            guard holeArea > 0 else { continue }
            let holePaths = hole.paths
            let inside = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
                try Clipper2.intersection(holePaths, outerPaths, fillRule: .nonZero, scale: options.clipperScale)
            }
            let insideArea = abs(Clipper2.area(of: inside))
            if insideArea <= holeArea * options.cutoutContainmentTolerance {
                throw MeasurementEngineError.measurement(.cutoutOutsideParent(cutoutIndex: index))
            } else if insideArea < holeArea * (1 - options.cutoutContainmentTolerance) {
                warnings.add(
                    .cutoutOutsideParent,
                    field: .cutoutArea,
                    detail: "cutout \(index) is only \(insideArea / holeArea) inside its parent"
                )
            } else {
                whollyInside[position] = true
            }
        }
        return whollyInside
    }

    // MARK: - Conversions

    /// A path rounded onto the Clipper2 lattice exactly as the bridge rounds its input
    /// (`round(value * scale) / scale`, half away from zero), without running a boolean.
    static func quantized(_ path: ClipperPath, scale: ClipperScale) -> ClipperPath {
        path.map { point in
            CGPoint(
                x: (Double(point.x) * scale.value).rounded() / scale.value,
                y: (Double(point.y) * scale.value).rounded() / scale.value
            )
        }
    }

    static func cgPoint(_ point: PDFPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    static func pdfPoint(_ point: CGPoint) -> PDFPoint {
        PDFPoint(x: Double(point.x), y: Double(point.y))
    }

    static func area(of rings: [[PDFPoint]]) -> Double {
        EngineNumerics.sum(rings.map { PolygonMath.signedArea($0) })
    }
}
