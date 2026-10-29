import CoreGraphics
import Foundation
import ZPDFVectorExtraction

/// How forgiving the geometry comparison is.
public struct VectorDiffOptions: Sendable, Hashable, Codable {
    /// Two vertices this close, in baseline page points, are the same vertex. A tenth
    /// of a point is a 35th of a millimetre: below the coordinate precision most CAD
    /// exporters write, and far below any real edit.
    public var positionTolerancePoints: Double
    /// Stroke widths within this are the same weight.
    public var strokeWidthTolerancePoints: Double
    /// A primitive that moved further than this is reported as one removal and one
    /// addition rather than as a move: past some distance "the same line, moved" stops
    /// being a defensible claim.
    public var movedSearchRadiusPoints: Double
    /// Primitives below this extractor confidence are ignored. Clip-derived geometry
    /// scores 0.5 and is not something a person drew.
    public var minimumPrimitiveConfidence: Float
    /// Refused before any work.
    public var maximumPrimitivesPerPage: Int
    /// The result list is cut here.
    public var maximumDifferences: Int

    public init(
        positionTolerancePoints: Double = 0.1,
        strokeWidthTolerancePoints: Double = 0.05,
        movedSearchRadiusPoints: Double = 144,
        minimumPrimitiveConfidence: Float = 0.9,
        maximumPrimitivesPerPage: Int = 200_000,
        maximumDifferences: Int = 5_000
    ) {
        self.positionTolerancePoints = max(0, positionTolerancePoints)
        self.strokeWidthTolerancePoints = max(0, strokeWidthTolerancePoints)
        self.movedSearchRadiusPoints = max(0, movedSearchRadiusPoints)
        self.minimumPrimitiveConfidence = minimumPrimitiveConfidence
        self.maximumPrimitivesPerPage = max(1, maximumPrimitivesPerPage)
        self.maximumDifferences = max(1, maximumDifferences)
    }

    public static let standard = VectorDiffOptions()
}

/// One geometry-level finding.
public struct VectorDifference: Sendable, Hashable, Codable {
    public let kind: VectorDifferenceKind
    /// Baseline page space.
    public let bounds: CGRect
    public let detail: VectorDifferenceDetail
    public let confidence: Double

    public init(
        kind: VectorDifferenceKind,
        bounds: CGRect,
        detail: VectorDifferenceDetail,
        confidence: Double
    ) {
        self.kind = kind
        self.bounds = bounds
        self.detail = detail
        self.confidence = confidence
    }
}

/// The geometry comparison's answer, including the honest "I could not tell you".
public struct VectorDiffOutcome: Sendable, Hashable, Codable {
    /// `true` only when **both** pages yielded usable vector geometry. When it is
    /// `false` the differences array is empty and the raster signal is all there is:
    /// a scanned revision compared against a CAD original has no geometry to compare.
    public let isMeaningful: Bool
    public let baselineAvailability: VectorAvailability
    public let revisedAvailability: VectorAvailability
    public let differences: [VectorDifference]
    /// The same findings expressed as ``DifferenceRegion`` values, so the UI can list
    /// raster and vector findings in one table without a second code path. Every one is
    /// tagged ``DifferenceSignal/vector``.
    public let regions: [DifferenceRegion]
    /// How many primitives matched exactly. The denominator for "3 of 4 210 lines
    /// changed".
    public let unchangedCount: Int
    public let baselinePrimitiveCount: Int
    public let revisedPrimitiveCount: Int
    public let wasTruncated: Bool
    /// Why the geometry pass did not run, when it was asked for and refused (U-078): a page
    /// over ``VectorDiffOptions/maximumPrimitivesPerPage``, or an extraction that failed. The
    /// outcome is then not meaningful and the comparison stands on its raster signal alone.
    /// `nil` when the pass ran.
    public let refusal: VectorDiffRefusal?

    public init(
        isMeaningful: Bool,
        baselineAvailability: VectorAvailability,
        revisedAvailability: VectorAvailability,
        differences: [VectorDifference],
        regions: [DifferenceRegion],
        unchangedCount: Int,
        baselinePrimitiveCount: Int,
        revisedPrimitiveCount: Int,
        wasTruncated: Bool,
        refusal: VectorDiffRefusal? = nil
    ) {
        self.isMeaningful = isMeaningful
        self.baselineAvailability = baselineAvailability
        self.revisedAvailability = revisedAvailability
        self.differences = differences
        self.regions = regions
        self.unchangedCount = unchangedCount
        self.baselinePrimitiveCount = baselinePrimitiveCount
        self.revisedPrimitiveCount = revisedPrimitiveCount
        self.wasTruncated = wasTruncated
        self.refusal = refusal
    }

    /// The outcome of a geometry pass that was refused: nothing compared, the reason kept.
    ///
    /// A side whose extraction did not complete is reported `unavailable(noVectorContent)` —
    /// there is no geometry to use — and ``refusal`` says why.
    public static func refused(
        _ refusal: VectorDiffRefusal,
        baseline: VectorPageExtraction? = nil,
        revised: VectorPageExtraction? = nil
    ) -> VectorDiffOutcome {
        VectorDiffOutcome(
            isMeaningful: false,
            baselineAvailability: baseline?.availability ?? .unavailable(reason: .noVectorContent),
            revisedAvailability: revised?.availability ?? .unavailable(reason: .noVectorContent),
            differences: [],
            regions: [],
            unchangedCount: 0,
            baselinePrimitiveCount: baseline?.primitives.count ?? 0,
            revisedPrimitiveCount: revised?.primitives.count ?? 0,
            wasTruncated: false,
            refusal: refusal
        )
    }

    public var addedCount: Int { differences.filter { $0.kind == .added }.count }
    public var removedCount: Int { differences.filter { $0.kind == .removed }.count }
    public var movedCount: Int { differences.filter { $0.kind == .moved }.count }
    public var reshapedCount: Int { differences.filter { $0.kind == .reshaped }.count }
}

/// Why a requested geometry pass did not run (U-078).
public enum VectorDiffRefusal: Sendable, Hashable, Codable {
    /// One page held more primitives than the diff may consider.
    case primitiveBudgetExceeded(count: Int, limit: Int)
    /// A page's geometry could not be read.
    case extractionFailed(label: String, reason: String)
    /// Any other refusal, by its description.
    case other(reason: String)

    /// The refusal a vector-side error stands for.
    init(_ error: any Error) {
        switch error as? CompareFault {
        case let .vectorPrimitiveBudgetExceeded(count, limit)?:
            self = .primitiveBudgetExceeded(count: count, limit: limit)
        case let .vectorExtraction(label, reason)?:
            self = .extractionFailed(label: label, reason: reason)
        case let .vectorSourceUnavailable(label)?:
            self = .extractionFailed(label: label, reason: CompareFault.vectorSourceUnavailable(label: label).description)
        default:
            self = .other(reason: String(describing: error))
        }
    }
}

/// Geometry-level revision comparison.
///
/// ### Why this exists next to the raster diff
///
/// On a CAD sheet a pixel difference is a poor proxy for a design change. Re-plotting
/// the *same* drawing through a different driver moves every antialiased edge by a
/// fraction of a pixel; nudging one wall by 3 mm changes a few hundred pixels in two
/// places. The pixel counts do not distinguish those two situations, and a takeoff
/// estimator staking a quantity on the answer needs them distinguished.
///
/// So when both pages carry vector content this engine matches the extracted primitives
/// shape by shape and reports what actually happened to the geometry: this line was
/// added, that one deleted, this one moved by exactly (12.0, 0.0) points. The result is
/// carried in its own field of ``RevisionComparisonResult`` and tagged
/// ``DifferenceSignal/vector``; it is never merged into the raster findings.
///
/// ### The matching rule
///
/// Three passes, each greedy over a deterministic order, each consuming baseline
/// primitives so nothing is matched twice:
///
/// 1. **Identical** — same kind, every key vertex within `positionTolerancePoints`,
///    stroke width within `strokeWidthTolerancePoints`. These are the unchanged ones.
/// 2. **Moved** — same kind, and every key vertex displaced by the *same* vector within
///    tolerance, with that vector no longer than `movedSearchRadiusPoints`. A uniform
///    displacement of every vertex is not something that happens by accident.
/// 3. **Reshaped** — same kind and the same vertex centroid (anchor) within
///    `positionTolerancePoints`, but neither of the above: a primitive anchored in the same
///    place whose shape or stroke width changed. A lengthened line or a polyline with one
///    vertex moved shifts its centroid, and reads as one removal plus one addition.
///
/// Whatever is left over is an addition (revised side) or a removal (baseline side).
public enum VectorDiffEngine {

    /// Compares two extractions.
    ///
    /// - Parameter alignment: maps revised page space onto baseline page space. The
    ///   revised primitives are transformed before matching, so every reported bound is
    ///   in baseline page space.
    public static func diff(
        baseline: VectorPageExtraction,
        revised: VectorPageExtraction,
        alignment: AlignmentTransform,
        options: VectorDiffOptions = .standard
    ) throws -> VectorDiffOutcome {
        try checkCompareCancellation()
        guard baseline.primitives.count <= options.maximumPrimitivesPerPage else {
            throw CompareFault.vectorPrimitiveBudgetExceeded(
                count: baseline.primitives.count, limit: options.maximumPrimitivesPerPage
            )
        }
        guard revised.primitives.count <= options.maximumPrimitivesPerPage else {
            throw CompareFault.vectorPrimitiveBudgetExceeded(
                count: revised.primitives.count, limit: options.maximumPrimitivesPerPage
            )
        }

        let isMeaningful = baseline.availability.hasUsableGeometry
            && revised.availability.hasUsableGeometry
        guard isMeaningful else {
            return VectorDiffOutcome(
                isMeaningful: false,
                baselineAvailability: baseline.availability,
                revisedAvailability: revised.availability,
                differences: [],
                regions: [],
                unchangedCount: 0,
                baselinePrimitiveCount: baseline.primitives.count,
                revisedPrimitiveCount: revised.primitives.count,
                wasTruncated: false
            )
        }

        let baselineShapes = shapes(
            from: baseline.primitives,
            alignment: .identity,
            minimumConfidence: options.minimumPrimitiveConfidence
        )
        let revisedShapes = shapes(
            from: revised.primitives,
            alignment: alignment,
            minimumConfidence: options.minimumPrimitiveConfidence
        )
        try checkCompareCancellation()

        let grids = Self.grids(for: baselineShapes, options: options)
        var consumed = [Bool](repeating: false, count: baselineShapes.count)
        var unchanged = 0
        var matchedRevised = [Bool](repeating: false, count: revisedShapes.count)
        var differences: [VectorDifference] = []

        // Pass 1 — identical.
        for (index, shape) in revisedShapes.enumerated() {
            try checkCompareCancellation()
            let candidates = grids.near.candidates(near: shape.anchor, radius: options.positionTolerancePoints)
            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for candidate in candidates where !consumed[candidate] {
                let other = baselineShapes[candidate]
                guard other.kind == shape.kind, other.vertices.count == shape.vertices.count else {
                    continue
                }
                guard abs(other.strokeWidth - shape.strokeWidth) <= options.strokeWidthTolerancePoints
                else { continue }
                guard let distance = Shape.maximumVertexDistance(other, shape),
                      distance <= options.positionTolerancePoints else { continue }
                if distance < bestDistance || (distance == bestDistance && candidate < (bestIndex ?? Int.max)) {
                    bestDistance = distance
                    bestIndex = candidate
                }
            }
            if let matched = bestIndex {
                consumed[matched] = true
                matchedRevised[index] = true
                unchanged += 1
            }
        }

        // Pass 2 — moved by a single uniform vector.
        for (index, shape) in revisedShapes.enumerated() where !matchedRevised[index] {
            try checkCompareCancellation()
            let candidates = grids.moved.candidates(near: shape.anchor, radius: options.movedSearchRadiusPoints)
            var bestIndex: Int?
            var bestOffset = CGPoint.zero
            var bestMagnitude = Double.greatestFiniteMagnitude
            for candidate in candidates where !consumed[candidate] {
                let other = baselineShapes[candidate]
                guard other.kind == shape.kind, other.vertices.count == shape.vertices.count else {
                    continue
                }
                guard abs(other.strokeWidth - shape.strokeWidth) <= options.strokeWidthTolerancePoints
                else { continue }
                guard let offset = Shape.uniformOffset(
                    from: other, to: shape, tolerance: options.positionTolerancePoints
                ) else { continue }
                let magnitude = hypot(Double(offset.x), Double(offset.y))
                guard magnitude <= options.movedSearchRadiusPoints else { continue }
                if magnitude < bestMagnitude
                    || (magnitude == bestMagnitude && candidate < (bestIndex ?? Int.max)) {
                    bestMagnitude = magnitude
                    bestOffset = offset
                    bestIndex = candidate
                }
            }
            if let matched = bestIndex {
                consumed[matched] = true
                matchedRevised[index] = true
                let other = baselineShapes[matched]
                differences.append(
                    VectorDifference(
                        kind: .moved,
                        bounds: other.bounds.unioned(with: shape.bounds),
                        detail: VectorDifferenceDetail(
                            kind: .moved,
                            baselinePrimitiveIDs: [other.id],
                            revisedPrimitiveIDs: [shape.id],
                            translation: bestOffset,
                            maximumVertexDisplacement: bestMagnitude,
                            strokeWidthDelta: shape.strokeWidth - other.strokeWidth
                        ),
                        confidence: VectorDifferenceConfidence.value(
                            kind: .moved,
                            primitiveConfidence: min(other.confidence, shape.confidence)
                        )
                    )
                )
            }
        }

        // Pass 3 — reshaped: anchored in the same place, different shape.
        for (index, shape) in revisedShapes.enumerated() where !matchedRevised[index] {
            try checkCompareCancellation()
            let candidates = grids.near.candidates(near: shape.anchor, radius: options.positionTolerancePoints)
            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for candidate in candidates where !consumed[candidate] {
                let other = baselineShapes[candidate]
                guard other.kind == shape.kind else { continue }
                let distance = hypot(
                    Double(other.anchor.x - shape.anchor.x),
                    Double(other.anchor.y - shape.anchor.y)
                )
                guard distance <= options.positionTolerancePoints else { continue }
                if distance < bestDistance
                    || (distance == bestDistance && candidate < (bestIndex ?? Int.max)) {
                    bestDistance = distance
                    bestIndex = candidate
                }
            }
            if let matched = bestIndex {
                consumed[matched] = true
                matchedRevised[index] = true
                let other = baselineShapes[matched]
                differences.append(
                    VectorDifference(
                        kind: .reshaped,
                        bounds: other.bounds.unioned(with: shape.bounds),
                        detail: VectorDifferenceDetail(
                            kind: .reshaped,
                            baselinePrimitiveIDs: [other.id],
                            revisedPrimitiveIDs: [shape.id],
                            translation: nil,
                            maximumVertexDisplacement: Shape.maximumVertexDistance(other, shape),
                            strokeWidthDelta: shape.strokeWidth - other.strokeWidth
                        ),
                        confidence: VectorDifferenceConfidence.value(
                            kind: .reshaped,
                            primitiveConfidence: min(other.confidence, shape.confidence)
                        )
                    )
                )
            }
        }

        // Leftovers.
        for (index, shape) in revisedShapes.enumerated() where !matchedRevised[index] {
            differences.append(
                VectorDifference(
                    kind: .added,
                    bounds: shape.bounds,
                    detail: VectorDifferenceDetail(
                        kind: .added,
                        baselinePrimitiveIDs: [],
                        revisedPrimitiveIDs: [shape.id]
                    ),
                    confidence: VectorDifferenceConfidence.value(
                        kind: .added, primitiveConfidence: shape.confidence
                    )
                )
            )
        }
        for (index, shape) in baselineShapes.enumerated() where !consumed[index] {
            differences.append(
                VectorDifference(
                    kind: .removed,
                    bounds: shape.bounds,
                    detail: VectorDifferenceDetail(
                        kind: .removed,
                        baselinePrimitiveIDs: [shape.id],
                        revisedPrimitiveIDs: []
                    ),
                    confidence: VectorDifferenceConfidence.value(
                        kind: .removed, primitiveConfidence: shape.confidence
                    )
                )
            )
        }

        // Deterministic order: top-left first on the page, then by kind, then by id.
        //
        // CR-130: page space is y-up — the origin is the bottom-left corner of the sheet —
        // so ascending `minY` is *bottom* first. The raster engine numbers its components
        // in raster scan order, which is genuinely top first, and the two lists feed one
        // "next difference" button: it walked down the sheet through the raster findings
        // and then back up through the vector ones. Descending `maxY` is top first here,
        // and `maxY` rather than `minY` so that a tall shape is ordered by where it starts
        // on the page rather than by where it ends.
        differences.sort { lhs, rhs in
            if lhs.bounds.maxY != rhs.bounds.maxY { return lhs.bounds.maxY > rhs.bounds.maxY }
            if lhs.bounds.minX != rhs.bounds.minX { return lhs.bounds.minX < rhs.bounds.minX }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            let lhsID = lhs.detail.baselinePrimitiveIDs.first ?? lhs.detail.revisedPrimitiveIDs.first ?? 0
            let rhsID = rhs.detail.baselinePrimitiveIDs.first ?? rhs.detail.revisedPrimitiveIDs.first ?? 0
            return lhsID < rhsID
        }

        let wasTruncated = differences.count > options.maximumDifferences
        if wasTruncated { differences.removeSubrange(options.maximumDifferences...) }

        let regions = differences.enumerated().map { index, difference in
            DifferenceRegion(
                id: index,
                signal: .vector,
                classification: difference.kind.classification,
                pageBounds: difference.bounds,
                pixelBounds: nil,
                changedPixelCount: 0,
                addedPixelCount: 0,
                removedPixelCount: 0,
                confidence: difference.confidence,
                vectorDetail: difference.detail
            )
        }

        return VectorDiffOutcome(
            isMeaningful: true,
            baselineAvailability: baseline.availability,
            revisedAvailability: revised.availability,
            differences: differences,
            regions: regions,
            unchangedCount: unchanged,
            baselinePrimitiveCount: baselineShapes.count,
            revisedPrimitiveCount: revisedShapes.count,
            wasTruncated: wasTruncated
        )
    }

    // MARK: - Shape normalisation

    /// A primitive reduced to what a diff can compare: a kind, a vertex list in baseline
    /// page space (in drawing order), a stroke width and an anchor.
    ///
    /// The same edge drawn in the opposite direction, or a rectangle or closed ring whose
    /// corners were emitted starting from a different corner, must still match. That used
    /// to be done by sorting the vertices lexicographically on a 1e-4 pt grid, which is
    /// *not* stable under a real alignment: a 3e-4 rad hand-alignment rotation moves the far
    /// end of a vertical line by 0.03 pt in x, the sort flips, index-wise distance becomes
    /// the line's full length and an unchanged line was reported as reshaped (BH-016).
    ///
    /// Now the drawing order is kept and correspondence is searched explicitly: an open
    /// shape (line, cubic, open ring) matches forwards or reversed, a closed one (rectangle,
    /// closed ring) under every cyclic start in either direction. Nothing depends on a sort
    /// key, so no rotation or noise can flip it.
    struct Shape: Sendable {
        let id: UInt64
        let kind: VectorPrimitiveKind
        let vertices: [CGPoint]
        let bounds: CGRect
        let anchor: CGPoint
        let strokeWidth: Double
        let confidence: Float
        /// A closed loop: rectangles and closed rings, whose start vertex is arbitrary.
        var isClosedLoop: Bool = false

        /// One allowed vertex correspondence: vertex `i` of one shape corresponds to vertex
        /// `map(i)` of the other.
        struct Correspondence {
            let count: Int
            let shift: Int
            let reversed: Bool
            let closed: Bool

            @inline(__always)
            func map(_ index: Int) -> Int {
                if closed {
                    return reversed ? (shift - index + count) % count : (index + shift) % count
                }
                return reversed ? count - 1 - index : index
            }
        }

        /// How many correspondences are allowed between two shapes of `count` vertices:
        /// forwards and reversed for an open shape, every cyclic start in both directions for
        /// a closed one.
        @inline(__always)
        static func correspondenceCount(count: Int, closed: Bool) -> Int {
            guard count > 1 else { return 1 }
            return closed ? 2 * count : 2
        }

        /// The `variant`-th allowed correspondence, in the order forwards-then-reversed per
        /// cyclic start. Built on the fly: the matcher asks for these once per candidate, and
        /// an array per candidate was an allocation in the innermost loop (R-151).
        @inline(__always)
        static func correspondence(_ variant: Int, count: Int, closed: Bool) -> Correspondence {
            guard count > 1 else { return Correspondence(count: count, shift: 0, reversed: false, closed: false) }
            guard closed else { return Correspondence(count: count, shift: 0, reversed: variant == 1, closed: false) }
            return Correspondence(count: count, shift: variant / 2, reversed: variant % 2 == 1, closed: true)
        }

        /// The largest distance between corresponding vertices under the best allowed
        /// correspondence, or `nil` when the vertex counts differ.
        static func maximumVertexDistance(_ lhs: Shape, _ rhs: Shape) -> Double? {
            let count = lhs.vertices.count
            guard count == rhs.vertices.count else { return nil }
            guard count > 0 else { return 0 }
            var best = Double.greatestFiniteMagnitude
            let closed = lhs.isClosedLoop && rhs.isClosedLoop
            for variant in 0..<correspondenceCount(count: count, closed: closed) {
                let correspondence = correspondence(variant, count: count, closed: closed)
                var worst = 0.0
                for index in 0..<count {
                    let a = lhs.vertices[index]
                    let b = rhs.vertices[correspondence.map(index)]
                    worst = Swift.max(worst, hypot(Double(a.x - b.x), Double(a.y - b.y)))
                    if worst >= best { break }
                }
                if worst < best { best = worst }
                if best == 0 { break }
            }
            return best
        }

        /// The smallest single translation that takes every vertex of `from` to its
        /// corresponding vertex of `to` (under an allowed correspondence), or `nil` when no
        /// single translation does.
        static func uniformOffset(from: Shape, to: Shape, tolerance: Double) -> CGPoint? {
            let count = from.vertices.count
            guard count == to.vertices.count, count > 0 else { return nil }
            var best: CGPoint?
            var bestMagnitude = Double.greatestFiniteMagnitude
            let closed = from.isClosedLoop && to.isClosedLoop
            for variant in 0..<correspondenceCount(count: count, closed: closed) {
                let correspondence = correspondence(variant, count: count, closed: closed)
                let dx = Double(to.vertices[correspondence.map(0)].x - from.vertices[0].x)
                let dy = Double(to.vertices[correspondence.map(0)].y - from.vertices[0].y)
                var fits = true
                for index in 1..<count {
                    let ex = Double(to.vertices[correspondence.map(index)].x - from.vertices[index].x) - dx
                    let ey = Double(to.vertices[correspondence.map(index)].y - from.vertices[index].y) - dy
                    if hypot(ex, ey) > tolerance { fits = false; break }
                }
                guard fits else { continue }
                let magnitude = hypot(dx, dy)
                if magnitude < bestMagnitude {
                    bestMagnitude = magnitude
                    best = CGPoint(x: dx, y: dy)
                }
            }
            return best
        }
    }

    /// One comparable shape per painted subpath.
    ///
    /// A closed subpath is compared once, as its subpath-level parent: its edge children
    /// (``VectorPrimitive/isEdgeOfShape``) are left out. The extractor emits both forms
    /// with one confidence, so keeping both made one moved rectangle five `moved` rows and
    /// counted an unchanged one five times in `unchangedCount` and the page total (X-040).
    /// Open subpaths keep their segments, which have no parent.
    static func shapes(
        from primitives: [VectorPrimitive],
        alignment: AlignmentTransform,
        minimumConfidence: Float
    ) -> [Shape] {
        var result: [Shape] = []
        result.reserveCapacity(primitives.count)
        for primitive in primitives
        where primitive.confidence >= minimumConfidence && !primitive.isEdgeOfShape {
            var vertices = keyVertices(of: primitive.geometry)
            guard !vertices.isEmpty else { continue }
            let closed = isClosedLoop(primitive.geometry)
            // A closed loop that repeats its first vertex at the end would break the
            // cyclic correspondence; the repeat carries no information.
            if closed, vertices.count > 2, let first = vertices.first, let last = vertices.last,
               hypot(Double(first.x - last.x), Double(first.y - last.y)) <= canonicalOrderQuantum {
                vertices.removeLast()
            }
            if !alignment.isIdentity(tolerance: 0) {
                vertices = vertices.map(alignment.apply(to:))
            }
            // Drawing order is kept; `Shape` searches the allowed correspondences instead of
            // relying on a sort key that an alignment rotation can flip (BH-016).
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            var sumX = 0.0, sumY = 0.0
            for vertex in vertices {
                minX = Swift.min(minX, Double(vertex.x)); maxX = Swift.max(maxX, Double(vertex.x))
                minY = Swift.min(minY, Double(vertex.y)); maxY = Swift.max(maxY, Double(vertex.y))
                sumX += Double(vertex.x); sumY += Double(vertex.y)
            }
            let count = Double(vertices.count)
            // The stroke width is a length, so an alignment that rescales the page
            // rescales it too. Using the unscaled width would report every line on a
            // rescaled re-plot as a weight change.
            let scale = alignment.meanScale
            result.append(
                Shape(
                    id: primitive.id,
                    kind: primitive.kind,
                    vertices: vertices,
                    bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                    anchor: CGPoint(x: sumX / count, y: sumY / count),
                    strokeWidth: primitive.strokeWidth * (scale.isFinite && scale > 0 ? scale : 1),
                    confidence: primitive.confidence,
                    isClosedLoop: closed
                )
            )
        }
        return result
    }

    /// How close a closed loop's last vertex must be to its first to count as the repeat
    /// that closes it, in page points.
    static let canonicalOrderQuantum = 1e-4

    /// Rectangles and closed rings have no meaningful start vertex.
    static func isClosedLoop(_ geometry: VectorGeometry) -> Bool {
        switch geometry {
        case .line, .cubic: false
        case .rectangle: true
        case let .ring(ring): ring.isClosed
        }
    }

    static func keyVertices(of geometry: VectorGeometry) -> [CGPoint] {
        switch geometry {
        case let .line(line):
            return [line.start, line.end]
        case let .cubic(cubic):
            return [cubic.p0, cubic.p1, cubic.p2, cubic.p3]
        case let .rectangle(quad):
            return quad.corners
        case let .ring(ring):
            return ring.vertices
        }
    }

    /// The two lookup grids over the baseline shapes: `near` for the identical and reshaped
    /// passes, which look up `positionTolerancePoints` around an anchor, and `moved` for the
    /// moved pass's `movedSearchRadiusPoints`.
    ///
    /// One grid used to serve all three, sized for the moved pass (144 pt), so a 0.1 pt
    /// lookup visited a 432 × 432 pt block — on a dense sheet thousands of candidates per
    /// shape, for a match that has to lie within a tenth of a point (R-151). A query always
    /// visits at least the 3 × 3 cells around its point, and `ceil(radius / cell)` rings in
    /// general, so either grid answers any radius correctly; the cell size only decides how
    /// much it reads.
    static func grids(for shapes: [Shape], options: VectorDiffOptions) -> (near: ShapeGrid, moved: ShapeGrid) {
        let tolerance = options.positionTolerancePoints.isFinite ? max(options.positionTolerancePoints, 0) : 1
        return (
            near: ShapeGrid(shapes: shapes, cellSize: max(4 * tolerance, 1)),
            moved: ShapeGrid(
                shapes: shapes,
                cellSize: max(options.movedSearchRadiusPoints, 4 * max(options.positionTolerancePoints, 1))
            )
        )
    }

    /// A uniform grid over the baseline shapes' anchors.
    ///
    /// Not an R-tree: the query here is "anchors within r of a point" with r fixed for
    /// the whole run, which a uniform grid answers in constant time per query, and the
    /// packed R-tree in `ZPDFGeometry` is built for the different problem of arbitrary
    /// rectangle queries over long-lived data.
    struct ShapeGrid: Sendable {
        private let cellSize: Double
        private let buckets: [GridKey: [Int]]

        struct GridKey: Hashable, Sendable {
            let x: Int
            let y: Int
        }

        init(shapes: [Shape], cellSize: Double) {
            let size = cellSize.isFinite && cellSize > 0 ? cellSize : 1
            self.cellSize = size
            var table: [GridKey: [Int]] = [:]
            table.reserveCapacity(shapes.count)
            for (index, shape) in shapes.enumerated() {
                let key = GridKey(
                    x: Self.cell(Double(shape.anchor.x), size),
                    y: Self.cell(Double(shape.anchor.y), size)
                )
                table[key, default: []].append(index)
            }
            self.buckets = table
        }

        /// The cell coordinate of `value`, clamped. The extractor admits any finite
        /// coordinate, and `Int(1.3e21 / 144)` — or `Int(nan)` — trapped and took the
        /// application down (BH-126). Clamping to ±2^52 keeps `cx + dx` far from overflow.
        static func cell(_ value: Double, _ size: Double) -> Int {
            let limit = 4_503_599_627_370_496.0   // 2^52
            let scaled = (value / size).rounded(.down)
            guard scaled.isFinite else { return scaled.isNaN ? 0 : (scaled < 0 ? -Int(limit) : Int(limit)) }
            return Int(Swift.min(Swift.max(scaled, -limit), limit))
        }

        func candidates(near point: CGPoint, radius: Double) -> [Int] {
            let spanValue = (Swift.max(0, radius.isFinite ? radius : .greatestFiniteMagnitude) / cellSize).rounded(.up)
            let cx = Self.cell(Double(point.x), cellSize)
            let cy = Self.cell(Double(point.y), cellSize)
            var result: [Int] = []
            // A span wider than the table is cheaper to answer by scanning the buckets.
            let side = 2 * spanValue + 1
            if spanValue > 1_000_000 || side * side > Double(buckets.count) * 4 + 64 {
                let span = spanValue > 1e15 ? Int(1e15) : Swift.max(1, Int(spanValue))
                for (key, bucket) in buckets
                where abs(key.x - cx) <= span && abs(key.y - cy) <= span {
                    result.append(contentsOf: bucket)
                }
            } else {
                let span = Swift.max(1, Int(spanValue))
                for dy in -span...span {
                    for dx in -span...span {
                        if let bucket = buckets[GridKey(x: cx + dx, y: cy + dy)] {
                            result.append(contentsOf: bucket)
                        }
                    }
                }
            }
            // Unsorted on purpose: every pass breaks a tie by the lower candidate index itself,
            // so the order of this list cannot change a match (R-151).
            return result
        }
    }
}

private extension CGRect {
    /// Union that treats an empty rectangle as a point rather than as nothing, so a
    /// zero-height horizontal line does not vanish.
    func unioned(with other: CGRect) -> CGRect {
        let minX = Swift.min(self.minX, other.minX)
        let minY = Swift.min(self.minY, other.minY)
        let maxX = Swift.max(self.maxX, other.maxX)
        let maxY = Swift.max(self.maxY, other.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
