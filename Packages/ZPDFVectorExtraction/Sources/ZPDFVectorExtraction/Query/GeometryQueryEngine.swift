import CoreGraphics
import Foundation

/// Asks one page's extracted geometry a typed question and returns highlights.
///
/// *Searchable geometry* is *"ask the drawing a question and get every
/// match lit up on the sheet"*. Three questions are answerable from what extraction
/// carries:
///
/// | Question | Method |
/// |---|---|
/// | every pair of lines a fixed distance apart | ``parallelPairs(gap:tolerance:minimumOverlap:angleToleranceDegrees:resultLimit:)`` |
/// | every line of a given length | ``segments(ofLength:tolerance:resultLimit:)`` |
/// | every circle of a given radius | ``circles(radius:tolerance:minimumSweepRadians:fitToleranceFraction:minimumFitTolerance:resultLimit:)`` |
///
/// ## Results are highlights, not quantities
///
/// One invariant is unconditional and it is the reason this type exists in
/// the shape it does: **a search result is a highlight; it becomes a measurement only
/// when a person commits it.** Nothing here totals anything, nothing here returns an area
/// or a count of metres, and no result of this engine may be written into the Quantity
/// Ledger, an export or a summary without a person committing it first. The types say so
/// too — every match is a `…Highlight`, and ``GeometryQueryResult`` offers a count and a
/// status but no sum.
///
/// ## Units
///
/// The engine works in page points, because that is what extraction produces. Query
/// parameters are expressed in the caller's unit and multiplied by ``pointsPerUnit``, so
/// a caller that has resolved a page's scale can ask for *300 mm* and a caller that has
/// not can leave ``pointsPerUnit`` at `1` and ask in points. Every geometric field of
/// every match is in page points; ``GeometryQueryResult/units(fromPoints:)`` converts back.
///
/// ## Cost
///
/// The parallel-pair query builds a ``GeometrySegmentGrid`` per call — cell size depends
/// on the gap being asked about, so the index cannot be shared between different
/// questions. Building it is linear; the query is then linear in the number of candidate
/// pairs the grid admits rather than in `n²`.
public struct GeometryQueryEngine: Sendable {

    /// `QUALITY_BAR`-scale tolerance for "the producer meant these to be parallel":
    /// drawing software rounds coordinates, and a wall drawn at 1° off is drawn at 1° off.
    public static let defaultAngleToleranceDegrees: Double = 1.5
    /// The result cap. A crowded sheet can hold hundreds of thousands of parallel pairs
    /// and a UI that tries to light them all up stops being a UI.
    public static let defaultResultLimit = 5_000
    /// A chain must cover very nearly a full turn to be called a circle. Lower it to
    /// match arcs.
    public static let defaultMinimumSweepRadians: Double = 2 * .pi - 0.15
    /// A fitted circle is accepted when no sampled point sits further from it than this
    /// fraction of the radius. `0.01` passes the standard four-cubic circle, whose
    /// deviation is `2.7253e-4` of the radius by construction, and rejects an octagon,
    /// whose is `0.038`.
    public static let defaultFitToleranceFraction: Double = 0.01
    /// The floor under the fit tolerance, in page points, so a very small circle is not
    /// held to an impossible absolute bar.
    public static let defaultMinimumFitTolerance: Double = 0.1

    /// Every straight segment of the page, in extraction order.
    public let segments: [GeometryQuerySegment]
    /// Every cubic of the page, in extraction order.
    public let curves: [GeometryQueryCurve]
    /// One caller unit is this many page points.
    public let pointsPerUnit: Double
    /// `segments[i].lineAngle`, computed once here rather than once per query (IM-235).
    let lineAngles: [Double]
    /// The cubics of each subpath with the circle fitted to them, computed once here:
    /// nothing in the sampling, the Kåsa fit or the sweep depends on the radius or the
    /// fit tolerance a query asks for, only the acceptance does. A user refining the
    /// radius therefore pays a filter per keystroke, not a refit of every chain (IM-235).
    let curveChainFits: [CurveChainFit]

    struct CurveChainFit: Sendable {
        let chain: [GeometryQueryCurve]
        let fit: CircleFit?
    }

    // MARK: - Construction

    /// - Parameters:
    ///   - segments: the straight segments to query.
    ///   - curves: the cubics to query, for ``circles(radius:tolerance:minimumSweepRadians:fitToleranceFraction:minimumFitTolerance:resultLimit:)``.
    ///   - pointsPerUnit: one caller unit in page points. Must be positive and finite.
    public init(
        segments: [GeometryQuerySegment],
        curves: [GeometryQueryCurve] = [],
        pointsPerUnit: Double = 1
    ) throws {
        guard pointsPerUnit > 0, pointsPerUnit.isFinite else {
            throw VectorExtractionError.invalidOption(
                name: "pointsPerUnit",
                reason: "must be a positive finite number, got \(pointsPerUnit)"
            )
        }
        self.segments = segments
        self.curves = curves
        self.pointsPerUnit = pointsPerUnit
        self.lineAngles = segments.map(\.lineAngle)
        self.curveChainFits = Self.curveChains(curves).map {
            CurveChainFit(chain: $0, fit: Self.rawCircleFit($0))
        }
    }

    /// Build an engine over one page's extraction.
    ///
    /// Subpath-level primitives are skipped: their edges are already present as
    /// `.lineSegment` children, and taking both would double every rectangle.
    ///
    /// - Parameters:
    ///   - page: the extracted page. A ``VectorPageExtraction/availability`` of
    ///     `.partial` is not an error here — the query answers over what was extracted,
    ///     and the caller is the one holding the partial reasons to report.
    ///   - pointsPerUnit: one caller unit in page points.
    ///   - layerFilter: which layers take part. Defaults to all of them.
    ///   - minimumConfidence: drop primitives the extractor was less sure about.
    public init(
        page: VectorPageExtraction,
        pointsPerUnit: Double = 1,
        layerFilter: VectorLayerVisibilityFilter = .everythingVisible,
        minimumConfidence: Float = 0
    ) throws {
        var segments: [GeometryQuerySegment] = []
        var curves: [GeometryQueryCurve] = []
        segments.reserveCapacity(page.primitives.count)
        for primitive in page.primitives {
            guard primitive.confidence >= minimumConfidence else { continue }
            guard layerFilter.admits(primitive) else { continue }
            if let segment = GeometryQuerySegment(primitive: primitive) {
                segments.append(segment)
            } else if let curve = GeometryQueryCurve(primitive: primitive) {
                curves.append(curve)
            }
        }
        try self.init(segments: segments, curves: curves, pointsPerUnit: pointsPerUnit)
    }

    // MARK: - Query 1: parallel pairs

    /// Every pair of near-parallel segments a given distance apart — *"every wall 300 mm
    /// apart"*.
    ///
    /// A pair is reported when all three hold:
    ///
    /// 1. the two lines are within `angleToleranceDegrees` of parallel, measured as
    ///    undirected lines so drawing direction does not matter;
    /// 2. their perpendicular separation is within `tolerance` of `gap`, measured at the
    ///    middle of the span they share rather than at an endpoint;
    /// 3. their projected overlap along the first segment's direction is at least
    ///    `minimumOverlap`, and greater than zero. Two collinear-offset segments that
    ///    never face each other are not a wall and are not a pair.
    ///
    /// **These are highlights.** The result says two edges face each other; it does not
    /// say what is between them, does not measure the wall and must never be totalled.
    ///
    /// - Parameters:
    ///   - gap: the separation to look for, in caller units.
    ///   - tolerance: how far from `gap` a separation may sit, in caller units.
    ///   - minimumOverlap: the least facing extent that counts, in caller units.
    ///   - angleToleranceDegrees: how far from parallel is still parallel.
    ///   - resultLimit: the cap. Reaching it sets ``GeometryQueryResult/truncated``.
    /// - Returns: matches ordered by `(firstPrimitiveID, secondPrimitiveID)`;
    ///   ``GeometryQueryResult/examinedCount`` is the number of candidate pairs tested.
    public func parallelPairs(
        gap: Double,
        tolerance: Double,
        minimumOverlap: Double = 0,
        angleToleranceDegrees: Double = GeometryQueryEngine.defaultAngleToleranceDegrees,
        resultLimit: Int = GeometryQueryEngine.defaultResultLimit
    ) -> GeometryQueryResult<GeometryParallelPairHighlight> {
        typealias Result = GeometryQueryResult<GeometryParallelPairHighlight>
        guard gap.isFinite, gap >= 0 else {
            return .rejected(
                name: "gap",
                reason: "must be a finite non-negative distance, got \(gap)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard tolerance.isFinite, tolerance >= 0 else {
            return .rejected(
                name: "tolerance",
                reason: "must be a finite non-negative distance, got \(tolerance)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard minimumOverlap.isFinite, minimumOverlap >= 0 else {
            return .rejected(
                name: "minimumOverlap",
                reason: "must be a finite non-negative distance, got \(minimumOverlap)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard angleToleranceDegrees.isFinite, angleToleranceDegrees >= 0 else {
            return .rejected(
                name: "angleToleranceDegrees",
                reason: "must be a finite non-negative angle, got \(angleToleranceDegrees)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard resultLimit > 0 else {
            return .rejected(
                name: "resultLimit",
                reason: "must be at least 1, got \(resultLimit)",
                pointsPerUnit: pointsPerUnit
            )
        }

        let gapPoints = gap * pointsPerUnit
        let tolerancePoints = tolerance * pointsPerUnit
        let minimumOverlapPoints = minimumOverlap * pointsPerUnit
        let angleTolerance = angleToleranceDegrees * .pi / 180
        let reach = gapPoints + tolerancePoints

        guard segments.count > 1 else {
            return Result(
                matches: [],
                status: .complete,
                examinedCount: 0,
                pointsPerUnit: pointsPerUnit
            )
        }

        let angles = lineAngles

        let grid = GeometrySegmentGrid(
            segments: segments,
            angles: angles,
            reach: Swift.max(reach, 1e-6),
            angleToleranceRadians: angleTolerance
        )

        var matches: [GeometryParallelPairHighlight] = []
        var examined = 0
        var truncated = false
        // Stamped de-duplication: a candidate reached through several cells is tested once.
        var stamp = [Int32](repeating: -1, count: segments.count)
        // Reused rather than rebuilt per segment: three probes, no allocation in the loop.
        var probes = [Int](repeating: 0, count: 3)
        let bucketCount = grid.bucketCount
        let probeCount = Swift.min(3, bucketCount)

        outer: for i in segments.indices {
            let a = segments[i]
            let box = a.bounds
            let firstColumn = grid.column(forX: box.minX - reach)
            let lastColumn = grid.column(forX: box.maxX + reach)
            let firstRow = grid.row(forY: box.minY - reach)
            let lastRow = grid.row(forY: box.maxY + reach)
            let centre = Int(grid.buckets[i])
            probes[0] = centre
            probes[1] = bucketCount >= 2 ? (centre + 1) % bucketCount : centre
            probes[2] = bucketCount >= 3 ? (centre + bucketCount - 1) % bucketCount : centre
            let marker = Int32(i)
            let angleOfA = angles[i]

            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    for probe in 0..<probeCount {
                        let slot = grid.range(column: column, row: row, bucket: probes[probe])
                        for entry in slot {
                            let j = Int(grid.entries[entry])
                            guard j > i, stamp[j] != marker else { continue }
                            stamp[j] = marker
                            examined += 1
                            let difference = GeometryQueryMath.angularDifference(angleOfA, angles[j])
                            guard difference <= angleTolerance else { continue }
                            guard let pair = Self.pair(
                                a,
                                segments[j],
                                gapPoints: gapPoints,
                                tolerancePoints: tolerancePoints,
                                minimumOverlapPoints: minimumOverlapPoints,
                                angleDifferenceDegrees: difference * 180 / .pi
                            ) else { continue }
                            // The flag is raised by the match that does *not* fit, so a
                            // page with exactly `resultLimit` pairs reports a complete
                            // result rather than a truncation that did not happen.
                            if matches.count >= resultLimit {
                                truncated = true
                                break outer
                            }
                            matches.append(pair)
                        }
                    }
                }
            }
        }

        matches.sort {
            $0.firstPrimitiveID == $1.firstPrimitiveID
                ? $0.secondPrimitiveID < $1.secondPrimitiveID
                : $0.firstPrimitiveID < $1.firstPrimitiveID
        }
        return Result(
            matches: matches,
            status: truncated ? .truncated(limit: resultLimit) : .complete,
            examinedCount: examined,
            pointsPerUnit: pointsPerUnit
        )
    }

    /// The separation and overlap rule, in one place so the rule that decides a match is
    /// auditable rather than inlined in a loop.
    static func pair(
        _ a: GeometryQuerySegment,
        _ b: GeometryQuerySegment,
        gapPoints: Double,
        tolerancePoints: Double,
        minimumOverlapPoints: Double,
        angleDifferenceDegrees: Double
    ) -> GeometryParallelPairHighlight? {
        let aLength = a.length
        guard aLength > 0 else { return nil }
        let dx = (a.end.x - a.start.x) / aLength
        let dy = (a.end.y - a.start.y) / aLength
        // Left normal of the first segment's direction.
        let nx = -dy
        let ny = dx

        func projection(_ p: CGPoint) -> Double {
            (p.x - a.start.x) * dx + (p.y - a.start.y) * dy
        }
        func normalOffset(_ p: CGPoint) -> Double {
            (p.x - a.start.x) * nx + (p.y - a.start.y) * ny
        }

        let pb0 = projection(b.start)
        let pb1 = projection(b.end)
        let low = Swift.max(0, Swift.min(pb0, pb1))
        let high = Swift.min(aLength, Swift.max(pb0, pb1))
        let overlap = high - low
        guard overlap > 0, overlap >= minimumOverlapPoints else { return nil }

        let middle = (low + high) / 2
        let span = pb1 - pb0
        let t = abs(span) > 1e-12 ? (middle - pb0) / span : 0.5
        let nb0 = normalOffset(b.start)
        let nb1 = normalOffset(b.end)
        let separation = abs(nb0 + (nb1 - nb0) * t)
        guard abs(separation - gapPoints) <= tolerancePoints else { return nil }

        let aLow = CGPoint(x: a.start.x + dx * low, y: a.start.y + dy * low)
        let aHigh = CGPoint(x: a.start.x + dx * high, y: a.start.y + dy * high)
        func pointOnB(atProjection value: Double) -> CGPoint {
            let u = abs(span) > 1e-12 ? Swift.min(Swift.max((value - pb0) / span, 0), 1) : 0.5
            return CGPoint(
                x: b.start.x + (b.end.x - b.start.x) * u,
                y: b.start.y + (b.end.y - b.start.y) * u
            )
        }
        let bLow = pointOnB(atProjection: low)
        let bHigh = pointOnB(atProjection: high)
        let quad = VectorQuad(c0: aLow, c1: aHigh, c2: bHigh, c3: bLow)

        let first = Swift.min(a.primitiveID, b.primitiveID)
        let second = Swift.max(a.primitiveID, b.primitiveID)
        return GeometryParallelPairHighlight(
            firstPrimitiveID: first,
            secondPrimitiveID: second,
            separationPoints: separation,
            overlapLengthPoints: overlap,
            angleDifferenceDegrees: angleDifferenceDegrees,
            overlapQuad: quad,
            bounds: quad.bounds
        )
    }

    // MARK: - Query 2: segments of a length

    /// Every straight segment whose length matches, within `tolerance`.
    ///
    /// **Curves are not included, and that is deliberate.** A cubic has no length that can
    /// be stated exactly; the length of its ``VectorFlattener`` polyline is an
    /// approximation, and a query that quietly mixed exact lengths with approximated ones
    /// would be reporting two different claims under one name. A caller that wants curve
    /// lengths should ask for them explicitly through the flattener and say what it did.
    ///
    /// **These are highlights.** ``GeometryLengthHighlight/lengthPoints`` is the length of
    /// a drawn line in page points, not a measurement of what the drawing depicts.
    ///
    /// - Returns: matches ordered by primitive identifier;
    ///   ``GeometryQueryResult/examinedCount`` is the number of segments tested.
    public func segments(
        ofLength length: Double,
        tolerance: Double,
        resultLimit: Int = GeometryQueryEngine.defaultResultLimit
    ) -> GeometryQueryResult<GeometryLengthHighlight> {
        typealias Result = GeometryQueryResult<GeometryLengthHighlight>
        guard length.isFinite, length >= 0 else {
            return .rejected(
                name: "length",
                reason: "must be a finite non-negative distance, got \(length)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard tolerance.isFinite, tolerance >= 0 else {
            return .rejected(
                name: "tolerance",
                reason: "must be a finite non-negative distance, got \(tolerance)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard resultLimit > 0 else {
            return .rejected(
                name: "resultLimit",
                reason: "must be at least 1, got \(resultLimit)",
                pointsPerUnit: pointsPerUnit
            )
        }

        let target = length * pointsPerUnit
        let tolerancePoints = tolerance * pointsPerUnit

        var matches: [GeometryLengthHighlight] = []
        var examined = 0
        var truncated = false
        for segment in segments {
            examined += 1
            let segmentLength = segment.length
            guard abs(segmentLength - target) <= tolerancePoints else { continue }
            if matches.count >= resultLimit {
                truncated = true
                break
            }
            matches.append(
                GeometryLengthHighlight(
                    primitiveID: segment.primitiveID,
                    lengthPoints: segmentLength,
                    start: segment.start,
                    end: segment.end,
                    bounds: segment.bounds
                )
            )
        }
        matches.sort { $0.primitiveID < $1.primitiveID }
        return Result(
            matches: matches,
            status: truncated ? .truncated(limit: resultLimit) : .complete,
            examinedCount: examined,
            pointsPerUnit: pointsPerUnit
        )
    }

    // MARK: - Query 3: circles

    /// Every chain of cubics that fits a circle of the given radius.
    ///
    /// **The extraction model carries no circles.** ``VectorPrimitiveKind`` is
    /// `lineSegment`, `cubicCurve`, `rectangle` and `closedSubpath` — there is no arc and
    /// no circle, because PDF has no arc operator either: a producer draws a circle as
    /// cubic Béziers, conventionally four. This query therefore groups the cubics of each
    /// subpath, fits a circle to sampled points of the chain by algebraic least squares,
    /// and accepts the fit only when no sample sits further from it than
    /// `max(minimumFitTolerance, fitToleranceFraction × radius)`. The deviation it
    /// measured is reported on every match, so the approximation is visible rather than
    /// implied.
    ///
    /// Two consequences, stated rather than hidden:
    ///
    /// - **A circle drawn as a polygon is not found.** Some producers emit a many-sided
    ///   polyline instead of Béziers. Those primitives are `.lineSegment`s and this query
    ///   never sees them.
    /// - **A rounded rectangle is not a circle.** Its four corner arcs share a subpath but
    ///   not a centre, so the fit fails and the group is rejected.
    ///
    /// **These are highlights.** A circle found here is not a column, not a pile and not a
    /// count. It is somewhere to look.
    ///
    /// - Parameters:
    ///   - radius: the radius to look for, in caller units.
    ///   - tolerance: how far from `radius` a fitted radius may sit, in caller units.
    ///   - minimumSweepRadians: how much of a turn the chain must cover. The default is
    ///     very nearly `2π`, so only closed circles match; lower it to match arcs.
    ///   - fitToleranceFraction: the fit bar, as a fraction of the fitted radius.
    ///   - minimumFitTolerance: the floor under the fit bar, in page points.
    ///   - resultLimit: the cap. Reaching it sets ``GeometryQueryResult/truncated``.
    /// - Returns: matches ordered by first primitive identifier;
    ///   ``GeometryQueryResult/examinedCount`` is the number of curve chains tested.
    public func circles(
        radius: Double,
        tolerance: Double,
        minimumSweepRadians: Double = GeometryQueryEngine.defaultMinimumSweepRadians,
        fitToleranceFraction: Double = GeometryQueryEngine.defaultFitToleranceFraction,
        minimumFitTolerance: Double = GeometryQueryEngine.defaultMinimumFitTolerance,
        resultLimit: Int = GeometryQueryEngine.defaultResultLimit
    ) -> GeometryQueryResult<GeometryCircleHighlight> {
        typealias Result = GeometryQueryResult<GeometryCircleHighlight>
        guard radius.isFinite, radius > 0 else {
            return .rejected(
                name: "radius",
                reason: "must be a finite positive distance, got \(radius)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard tolerance.isFinite, tolerance >= 0 else {
            return .rejected(
                name: "tolerance",
                reason: "must be a finite non-negative distance, got \(tolerance)",
                pointsPerUnit: pointsPerUnit
            )
        }
        // NaN in any of these made every comparison below false and returned an
        // innocent empty `.complete` — the exact thing `invalidParameter` exists to
        // prevent (BH-863). A negative fit fraction would silently degrade the bar to the
        // floor, so it is refused too.
        guard minimumSweepRadians.isFinite, minimumSweepRadians >= 0 else {
            return .rejected(
                name: "minimumSweepRadians",
                reason: "must be a finite non-negative angle, got \(minimumSweepRadians)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard fitToleranceFraction.isFinite, fitToleranceFraction >= 0 else {
            return .rejected(
                name: "fitToleranceFraction",
                reason: "must be a finite non-negative fraction, got \(fitToleranceFraction)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard minimumFitTolerance.isFinite, minimumFitTolerance >= 0 else {
            return .rejected(
                name: "minimumFitTolerance",
                reason: "must be a finite non-negative distance, got \(minimumFitTolerance)",
                pointsPerUnit: pointsPerUnit
            )
        }
        guard resultLimit > 0 else {
            return .rejected(
                name: "resultLimit",
                reason: "must be at least 1, got \(resultLimit)",
                pointsPerUnit: pointsPerUnit
            )
        }

        let targetRadius = radius * pointsPerUnit
        let tolerancePoints = tolerance * pointsPerUnit

        var matches: [GeometryCircleHighlight] = []
        var examined = 0
        var truncated = false

        for entry in curveChainFits {
            examined += 1
            let chain = entry.chain
            guard let fit = entry.fit,
                  fit.isAccepted(fitToleranceFraction: fitToleranceFraction, minimumFitTolerance: minimumFitTolerance)
            else { continue }
            guard fit.sweepRadians >= minimumSweepRadians else { continue }
            guard abs(fit.radius - targetRadius) <= tolerancePoints else { continue }

            // Truncation is declared only when a match exists that the cap leaves out: a
            // page with exactly `resultLimit` circles is a complete answer, and reporting
            // it as cut short was CR-46. The check therefore runs before the append and
            // never after it, at the cost of examining the chains past the last match.
            if matches.count >= resultLimit {
                truncated = true
                break
            }
            var bounds = chain[0].cubic.bounds
            for curve in chain.dropFirst() { bounds = bounds.union(curve.cubic.bounds) }
            matches.append(
                GeometryCircleHighlight(
                    primitiveIDs: chain.map(\.primitiveID),
                    parentID: chain[0].parentID,
                    center: fit.center,
                    radiusPoints: fit.radius,
                    sweepRadians: fit.sweepRadians,
                    maximumFitDeviationPoints: fit.maximumDeviation,
                    bounds: bounds
                )
            )
        }

        matches.sort { ($0.primitiveIDs.first ?? 0) < ($1.primitiveIDs.first ?? 0) }
        return Result(
            matches: matches,
            status: truncated ? .truncated(limit: resultLimit) : .complete,
            examinedCount: examined,
            pointsPerUnit: pointsPerUnit
        )
    }

    /// The cubics of one subpath, in drawing order. Extraction emits a subpath's segments
    /// contiguously and in order, so grouping on the subpath identity preserves the chain.
    static func curveChains(_ curves: [GeometryQueryCurve]) -> [[GeometryQueryCurve]] {
        struct ChainKey: Hashable {
            var sourceObjectID: UInt64
            var subpathIndex: Int
            var nestingDepth: Int
            var parentID: UInt64?
        }
        var order: [ChainKey] = []
        var groups: [ChainKey: [GeometryQueryCurve]] = [:]
        for curve in curves {
            let key = ChainKey(
                sourceObjectID: curve.sourceObjectID,
                subpathIndex: curve.subpathIndex,
                nestingDepth: curve.nestingDepth,
                parentID: curve.parentID
            )
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]?.append(curve)
        }
        return order.compactMap { groups[$0] }
    }

    struct CircleFit: Sendable {
        var center: CGPoint
        var radius: Double
        var maximumDeviation: Double
        var sweepRadians: Double

        /// The acceptance bar, the one place it is written (W-086): the chain is a circle when
        /// no sampled point sits further from the fitted circle than
        /// `max(minimumFitTolerance, fitToleranceFraction × radius)`.
        func isAccepted(fitToleranceFraction: Double, minimumFitTolerance: Double) -> Bool {
            maximumDeviation <= Swift.max(minimumFitTolerance, fitToleranceFraction * radius)
        }
    }

    /// Kåsa algebraic circle fit over sampled points of the chain, plus the turn the chain
    /// makes about the fitted centre — everything about a chain that does not depend on
    /// what a query asks for, so it is computed once per engine.
    ///
    /// The fit minimises the algebraic residual, which is a linear least-squares problem
    /// and therefore has a closed form — no iteration, no convergence to explain. It
    /// biases slightly towards larger circles on a short arc, which is why the default
    /// sweep requirement is nearly a full turn.
    static func rawCircleFit(_ chain: [GeometryQueryCurve]) -> CircleFit? {
        guard !chain.isEmpty else { return nil }
        let perCurve = Swift.max(2, Swift.min(8, 512 / chain.count))
        var points: [CGPoint] = []
        points.reserveCapacity(chain.count * perCurve + 1)
        for curve in chain {
            for step in 0..<perCurve {
                points.append(curve.cubic.point(at: Double(step) / Double(perCurve)))
            }
        }
        points.append(chain[chain.count - 1].cubic.p3)
        guard points.count >= 4 else { return nil }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }

        let n = Double(points.count)
        var meanX = 0.0
        var meanY = 0.0
        for point in points {
            meanX += point.x
            meanY += point.y
        }
        meanX /= n
        meanY /= n

        var suu = 0.0, suv = 0.0, svv = 0.0
        var suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
        for point in points {
            let u = point.x - meanX
            let v = point.y - meanY
            let uu = u * u
            let vv = v * v
            suu += uu
            suv += u * v
            svv += vv
            suuu += uu * u
            svvv += vv * v
            suvv += u * vv
            svuu += v * uu
        }
        let determinant = suu * svv - suv * suv
        guard abs(determinant) > 1e-12 else { return nil }
        let rhsU = (suuu + suvv) / 2
        let rhsV = (svvv + svuu) / 2
        let a = (rhsU * svv - rhsV * suv) / determinant
        let b = (rhsV * suu - rhsU * suv) / determinant
        let radiusSquared = a * a + b * b + (suu + svv) / n
        guard radiusSquared > 0, radiusSquared.isFinite else { return nil }
        let radius = radiusSquared.squareRoot()
        guard radius > 0, radius.isFinite else { return nil }
        let center = CGPoint(x: meanX + a, y: meanY + b)

        var maximumDeviation = 0.0
        for point in points {
            let distance = (point - center).magnitude
            maximumDeviation = Swift.max(maximumDeviation, abs(distance - radius))
        }

        // The turn the chain makes about the fitted centre, walked in drawing order so it
        // does not depend on how densely the curve was sampled.
        var total = 0.0
        var previous = atan2(points[0].y - center.y, points[0].x - center.x)
        for point in points.dropFirst() {
            let angle = atan2(point.y - center.y, point.x - center.x)
            var delta = angle - previous
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            total += delta
            previous = angle
        }
        return CircleFit(
            center: center,
            radius: radius,
            maximumDeviation: maximumDeviation,
            sweepRadians: abs(total)
        )
    }
}
