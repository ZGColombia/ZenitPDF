import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Converts resolved page-space polygons into real-world areas and perimeters
/// (spec 12.3, 12.4, 12.5, ADR-0004).
enum ArealMeasure {

    /// The largest chord sagitta, in page points, of a ring flattened for the booleans only
    /// (ADR-0030 §5). A thousandth of a point is 0.35 µm of paper.
    static let arcFlatteningTolerance = 1e-3

    /// The sagitta the chords of `polygon` flattened to ``arcFlatteningTolerance`` really stay
    /// within: the tolerance itself, or what the capped chords reach on an arc too long for
    /// ``BulgeArc/maximumChordSteps``. Every warning that names the chords' error, and the
    /// exact net's cross-check slack, reads this figure (V-084).
    static func chordSagitta(of polygon: PolygonGeometry) -> Double {
        ([polygon.outer] + polygon.holes).reduce(arcFlatteningTolerance) { largest, ring in
            Swift.max(largest, ring.flatteningSagitta(tolerance: arcFlatteningTolerance))
        }
    }

    struct Result: Sendable {
        /// Outer area before cutouts, in square metres.
        var planArea: Decimal
        /// Area after the union of cutouts is removed, in square metres.
        var netArea: Decimal
        /// The area removed, in square metres.
        var cutoutArea: Decimal
        /// Boundary length under the caller's ``PerimeterPolicy``, in metres, as drawn on the plan.
        var perimeter: Double
        /// Boundary length on the sloped surface, in metres, or `nil` when the markup is flat or
        /// no fall-line azimuth exists. It is never a scalar multiple of ``perimeter``: the
        /// per-segment rule is applied edge by edge around every counted ring, hole boundaries
        /// included when the policy counts them (ADR-0004 §2).
        var truePerimeter: Double?
        /// True when at least one cutout took part.
        var hasCutouts: Bool
    }

    /// Measures every polygon in the input and adds the parts up.
    ///
    /// Multiple polygons are summed rather than unioned: two separate slabs on the same markup
    /// are two slabs. Cutouts are unioned *within* their own parent, which is where double
    /// subtraction can actually happen.
    static func measure(
        _ polygons: [PolygonGeometry],
        scale: ScaleTransform,
        parameters: MeasurementParameters,
        options: MeasurementEngineOptions,
        slope: DirectionalSlope? = nil,
        warnings: inout WarningLog
    ) throws -> Result {
        guard !polygons.isEmpty else { throw MeasurementError.emptyGeometry }

        var planAreas: [Double] = []
        var netAreas: [Double] = []
        var perimeters: [Double] = []
        var truePerimeters: [Double] = []
        var hasCutouts = false

        for drawn in polygons {
            // An area is closed. A ring flagged open is closed here, once, with every bulge it
            // carries — its closing edge's included — so the exact area, the flattened boolean,
            // the exact net and the perimeter all read the same ring. They read three: the exact
            // area dropped every arc of an open ring, the flattening dropped only the closing
            // arc, and the perimeter kept them all, so the golden 10 × 5 with a semicircle side
            // reported 50 of its 59.82 (U-091). The warning is the one ring hygiene raised.
            if !drawn.outer.isClosed || drawn.holes.contains(where: { !$0.isClosed }) {
                warnings.add(.openPolygonClosedImplicitly, field: .planArea)
            }
            let polygon = PolygonGeometry(
                outer: Self.closed(drawn.outer),
                holes: drawn.holes.map(Self.closed)
            )
            // Arc segments (ADR-0030 §5): the booleans (self-intersection, cutouts) run on the
            // ring flattened to `arcFlatteningTolerance`, and the exact outer area — shoelace plus
            // every edge's circular segment — replaces the flattened one unless the flattened ring
            // crossed itself and was normalised (S-105). The cutouts removed are the flattened
            // boolean's, so a hole that stays clear of the arcs is exact.
            let arcs = polygon.outer.validBulges
            let anyArcs = arcs != nil || polygon.holes.contains(where: \.hasArcs)
            let solvable = !anyArcs ? polygon : PolygonGeometry(
                outer: polygon.outer.flattened(tolerance: Self.arcFlatteningTolerance),
                holes: polygon.holes.map { $0.flattened(tolerance: Self.arcFlatteningTolerance) }
            )
            let resolved = try CutoutSolver.resolve(
                solvable,
                policy: parameters.cutoutPolicy,
                options: options,
                warnings: &warnings
            )
            // Cutouts strictly inside the outer ring and apart from each other remove exactly
            // their own areas. When an arc is involved, those exact areas — shoelace plus each
            // arc's circular segment — replace the flattened boolean's (ADR-0034 §2, K-10: the
            // cutout Merge Areas keeps for an enclosed gap is bounded by the areas' own arcs).
            let exactRemoved: Double? = anyArcs && resolved.boundary == .outerPlusDisjointHoles
                ? EngineNumerics.sum(resolved.holeIndices.map { Swift.abs(polygon.holes[$0].exactSignedArea) })
                : nil
            // The exact arc-edged area is the drawn ring's. When the flattened ring crossed
            // itself and was normalised, the region measured is the normalisation, and the drawn
            // ring's shoelace-plus-segments is its lobes cancelling: a bowtie with one bulged
            // edge stored 6.68 pt² for a 50 pt² region under warnings that said it had been
            // normalised (S-105). The normalised flattened area is used then, and says so.
            let exactOuterApplies = arcs != nil && resolved.outerIsDrawnRing
            if arcs != nil, !resolved.outerIsDrawnRing {
                warnings.add(
                    .numericalPrecisionLoss,
                    field: .planArea,
                    detail: "arc edges of a normalised outer ring measured as chords of sagitta <= \(chordSagitta(of: polygon)) pt"
                )
            }
            let plan: Double
            var net: Double
            if exactOuterApplies {
                let exactOuter = Swift.abs(polygon.outer.exactSignedArea)
                plan = exactOuter
                net = exactOuter - (exactRemoved ?? (resolved.outerPDFArea - resolved.netPDFArea))
            } else if let exactRemoved {
                plan = resolved.outerPDFArea
                net = resolved.outerPDFArea - exactRemoved
            } else {
                plan = resolved.outerPDFArea
                net = resolved.netPDFArea
            }
            // C-08: wherever a cutout meets an arc, or cutouts with arcs meet each other or the
            // outer ring, the region removed is taken on the arcs themselves — never the chord
            // polygon of the flattened boolean above, which is kept only as the cross-check and
            // the fallback.
            let arcNet = anyArcs
                ? Self.exactArcNet(of: polygon, resolved: resolved, flattenedNet: net, options: options, warnings: &warnings)
                : nil
            if let arcNet { net = Swift.min(plan, arcNet.area) }
            planAreas.append(plan)
            netAreas.append(net)
            hasCutouts = hasCutouts || !resolved.holeRings.isEmpty

            // `outerOnly` is the drawn outer boundary, unchanged by any cutout (QUALITY_BAR P12).
            // `outerPlusCutoutEdges` is the boundary of what is left: the rings of the boolean
            // difference, so an overlapping, overhanging or shared-edge cutout never counts an
            // edge twice (CR-21). It is not `outer + every hole's full boundary`.
            // An outer ring with arcs is measured exactly, arc by arc, whenever the boundary
            // counted is the drawn one (ADR-0030 §5).
            let countsCutoutEdges = parameters.perimeterPolicy == .outerPlusCutoutEdges
                && !resolved.holeRings.isEmpty
            if !countsCutoutEdges, arcs != nil, !resolved.outerIsDrawnRing {
                // The boundary of a normalised ring is the normalisation's, flattened (S-105).
                warnings.add(
                    .numericalPrecisionLoss,
                    field: .perimeter,
                    detail: "arc edges of a normalised outer ring measured as chords of sagitta <= \(chordSagitta(of: polygon)) pt"
                )
            }
            if !countsCutoutEdges, let arcs, resolved.outerIsDrawnRing {
                let measured = try LinearMeasure.ring(polygon.outer.points, scale: scale, bulges: arcs)
                perimeters.append(measured.totalMetres)
                if let slope {
                    truePerimeters.append(measured.trueLength(under: slope))
                }
                continue
            }
            let counted: [LinearMeasure.Result]
            if countsCutoutEdges, let arcNet {
                // The boundary of what is left, piece by piece as drawn: arcs at r·θ (C-08).
                counted = [try LinearMeasure.pieces(arcNet.boundary, scale: scale)]
            } else if countsCutoutEdges, anyArcs {
                counted = try exactBoundary(
                    of: polygon,
                    resolved: resolved,
                    scale: scale,
                    warnings: &warnings
                )
            } else {
                let rings = countsCutoutEdges ? resolved.netRings : resolved.outerRings
                counted = try rings.map { try LinearMeasure.ring($0, scale: scale) }
            }
            for measured in counted {
                perimeters.append(measured.totalMetres)
                if let slope {
                    truePerimeters.append(measured.trueLength(under: slope))
                }
            }
        }

        let factor = scale.matrix.areaFactor
        let planPDF = EngineNumerics.sum(planAreas)
        let netPDF = EngineNumerics.sum(netAreas)
        // The products are re-normalised to the policy significance: `factor` is a derived
        // `Decimal` (metres-per-point squared) that carries a full-width mantissa after a
        // two-point calibration, and storing the raw product would hand the ledger values
        // its exact addition must refuse to sum (see ``EngineNumerics/product(_:_:)``).
        let plan = try EngineNumerics.product(EngineNumerics.decimal(planPDF), factor)
        let net = try EngineNumerics.product(EngineNumerics.decimal(netPDF), factor)

        return Result(
            planArea: plan,
            netArea: net,
            cutoutArea: plan - net,
            perimeter: EngineNumerics.sum(perimeters),
            truePerimeter: slope == nil ? nil : EngineNumerics.sum(truePerimeters),
            hasCutouts: hasCutouts
        )
    }

    /// `ring` as a closed ring with the same points and bulges.
    static func closed(_ ring: PolygonRing) -> PolygonRing {
        ring.isClosed ? ring : PolygonRing(points: ring.points, isClosed: true, bulges: ring.bulges)
    }

    /// The net region of an area with arcs and cutouts taken on the arcs (C-08), or `nil` when
    /// the measurement above already is exact or the exact region cannot be decided.
    ///
    /// `nil` in three ways, and the flattened result stands in each:
    ///
    /// - no cutout took part, or the outer ring was normalised (S-105: the drawn ring is not the
    ///   region measured), or a ring is over the self-intersection vertex limit;
    /// - the cutouts lie inside the outer ring and apart from one another and from every arc —
    ///   ``CutoutSolver``'s exact path, whose `|outer| − Σ|hole|` from the drawn rings' own areas
    ///   is already exact (K-10) and is kept bit for bit;
    /// - ``ArcCutoutNet`` could not decide (an ambiguous contact, its work budget), or its answer
    ///   and the flattened boolean's disagree by more than the flattening and the lattice can
    ///   explain. Then the result says the chords were used (`numericalPrecisionLoss` on the net
    ///   area).
    ///
    /// A cutout that crosses itself removes its non-zero normalisation (``CutoutSolver``), so that
    /// is the region handed over for it — straight rings, as the boolean saw them — while every
    /// other cutout goes as drawn, arcs and all. Refusing the whole exact call for one such
    /// cutout sent every cutout back to the chords, so adding a tiny bowtie beside a cutout
    /// across an arc raised the stored net by the chords' 1.5e-5 pt² (QUALITY_BAR P11, U-087).
    /// A self-crossing cutout that has arcs of its own is normalised on its chords, and the
    /// result says so.
    private static func exactArcNet(
        of polygon: PolygonGeometry,
        resolved: CutoutSolver.Resolved,
        flattenedNet: Double,
        options: MeasurementEngineOptions,
        warnings: inout WarningLog
    ) -> ArcCutoutNet.Result? {
        guard !resolved.holeIndices.isEmpty, resolved.outerIsDrawnRing else { return nil }
        let drawnHoles = resolved.holeIndices.map { polygon.holes[$0] }
        let limit = options.selfIntersectionVertexLimit
        guard polygon.outer.points.count <= limit, drawnHoles.allSatisfy({ $0.points.count <= limit }) else { return nil }
        let sagitta = chordSagitta(of: polygon)
        let chordNote = "cutouts meeting arc edges subtracted as chords of sagitta <= \(sagitta) pt"
        var holes: [PolygonRing] = []
        for (position, drawn) in drawnHoles.enumerated() {
            let normalized = resolved.normalizedHoleRings.indices.contains(position) ? resolved.normalizedHoleRings[position] : nil
            guard let normalized else {
                holes.append(drawn)
                continue
            }
            // Each ring of a non-zero normalisation is an outer (positive, Clipper2's
            // convention) unless the cutout wound round a region zero times and left it as a hole
            // of its own; the union of cutouts has no way to say "except here", so that case
            // keeps the flattened boolean, as before.
            guard normalized.allSatisfy({ PolygonMath.signedArea($0) > 0 }) else {
                warnings.add(.numericalPrecisionLoss, field: .netArea, detail: chordNote)
                return nil
            }
            if drawn.hasArcs { warnings.add(.numericalPrecisionLoss, field: .netArea, detail: chordNote) }
            holes += normalized.map { PolygonRing(points: $0, isClosed: true) }
        }
        // The canonical cutout order (P5): which of two identical shared pieces is kept.
        let ordered = CutoutSolver.canonicalOrder(of: holes.map(\.points)).map { holes[$0] }
        guard let exact = ArcCutoutNet.net(outer: polygon.outer, holes: ordered) else {
            // Cutouts apart inside the outer ring are measured from their own areas either way.
            if resolved.boundary != .outerPlusDisjointHoles {
                warnings.add(.numericalPrecisionLoss, field: .netArea, detail: chordNote)
            }
            return nil
        }
        if resolved.boundary == .outerPlusDisjointHoles, exact.ringsAreApart { return nil }
        // Chords of sagitta t fall short of their arcs by less than t per unit of arc length, and
        // the lattice moves every point by under a step: far more than enough slack for rounding,
        // far less than any real disagreement.
        let lengths = ([polygon.outer] + holes).reduce(0.0) { total, ring in
            total + (ArcRing(Self.closed(ring))?.length ?? 0)
        }
        let slack = 2 * sagitta * lengths + 4 * lengths / options.clipperScale.value
            + 1e-9 * resolved.outerPDFArea
        guard Swift.abs(exact.area - flattenedNet) <= slack else {
            warnings.add(.numericalPrecisionLoss, field: .netArea, detail: chordNote)
            return nil
        }
        return exact
    }

    /// The boundary of an area with arcs and cutouts under `outerPlusCutoutEdges`, arc edges at
    /// `r·θ` wherever the drawn ring is the boundary (ADR-0030 §5.2, QUALITY_BAR §2.2 rule 4).
    ///
    /// Before R-181 this case measured the rings of the flattened boolean difference, so every
    /// arc of a curved slab with a cutout counted as its chords — about `t / (3r)` short, 4.7e-6
    /// relative at r = 71 pt. When every cutout lies strictly inside the outer ring, the drawn
    /// outer ring is part of the boundary unchanged and is measured exactly; so is every cutout
    /// when no two meet. Only where the boundary genuinely follows a boolean — overlapping
    /// cutouts that bend, or a cutout on the outer edge — is it the flattened ring, and then the
    /// result says so (`numericalPrecisionLoss` on the perimeter; the chords stay within the
    /// 1e-3 pt sagitta of the flattening).
    private static func exactBoundary(
        of polygon: PolygonGeometry,
        resolved: CutoutSolver.Resolved,
        scale: ScaleTransform,
        warnings: inout WarningLog
    ) throws -> [LinearMeasure.Result] {
        let exactOuter = try LinearMeasure.ring(polygon.outer.points, scale: scale, bulges: polygon.outer.validBulges)
        switch resolved.boundary {
        case .outerPlusDisjointHoles:
            var rings = [exactOuter]
            for index in resolved.holeIndices {
                let hole = polygon.holes[index]
                rings.append(try LinearMeasure.ring(hole.points, scale: scale, bulges: hole.validBulges))
            }
            return rings
        case .outerPlusUnion(let unionRings):
            let chordedIndices = resolved.holeIndices.filter { polygon.holes[$0].hasArcs }
            if !chordedIndices.isEmpty {
                warnings.add(
                    .numericalPrecisionLoss,
                    field: .perimeter,
                    detail: "arc edges of meeting cutouts \(chordedIndices) measured as chords of sagitta <= \(chordSagitta(of: polygon)) pt"
                )
            }
            return [exactOuter] + (try unionRings.map { try LinearMeasure.ring($0, scale: scale) })
        case .booleanOnly, .outerOnly:
            warnings.add(
                .numericalPrecisionLoss,
                field: .perimeter,
                detail: "arc edges on a boundary shared with a cutout measured as chords of sagitta <= \(chordSagitta(of: polygon)) pt"
            )
            return try resolved.netRings.map { try LinearMeasure.ring($0, scale: scale) }
        }
    }
}
