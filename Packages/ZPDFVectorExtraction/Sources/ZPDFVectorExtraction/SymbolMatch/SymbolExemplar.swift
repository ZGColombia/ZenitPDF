import CoreGraphics
import Foundation

/// Why an exemplar could not be built from the rectangle the estimator gave.
public enum SymbolExemplarError: Error, Sendable, Hashable {
    /// No usable primitive sits fully inside the given rectangle.
    case noPrimitivesInRegion
    /// Fewer primitives than a matchable symbol needs. A single stroke matches half the
    /// page and would make every "confirmed" instance a guess.
    case tooFewPrimitives(found: Int, required: Int)
    /// Every feature point coincides, so the shape has no size to normalise by.
    case degenerateGeometry
}

/// The one example the estimator confirmed — *"this is D-12"* — reduced to a form the
/// matcher can compare against.
///
/// ## Match by example, never unsupervised
///
/// Nothing in this type or in ``SymbolMatcher`` classifies anything on its own. The
/// exemplar is built from the primitives inside a rectangle a **person** chose (the
/// clicked instance's bounds, padded), and everything the matcher later confirms is
/// confirmed *against this example* — geometry the person has already looked at.
///
/// ## The invariances, and where each one lives
///
/// Invariant: *the same door mirrored, rotated or at another scale is one type.*
///
/// - **Translation** — feature points are stored relative to their centroid
///   (``normalizedPoints``), so where the symbol sits on the page cancels out.
/// - **Scale** — the centred points are divided by the RMS radius (``rmsRadius``), so a
///   2× instance normalises to the same point cloud.
/// - **Rotation and mirror** — nothing here bakes in an orientation; the matcher searches
///   rotations explicitly and tries each hypothesis mirrored, then lets Procrustes
///   alignment (reflection allowed) settle the transform. Invariance by search, not by a
///   signature that could alias two different shapes.
///
/// ## What a feature point is
///
/// Four points along every stroke — both ends and the ⅓ / ⅔ on-curve samples, for lines
/// and cubics alike. The interior samples are not decoration: a diagonal drawn corner to
/// corner across a rectangle shares both endpoints with the rectangle, so a matcher
/// that samples only endpoints literally cannot see the diagonal — a plain rectangle
/// and a rectangle with a cross fill reduce to the same cloud. Subpath-level
/// primitives — rectangles and closed subpaths — contribute nothing directly because
/// the extractor already emits every one of their edges as a `.lineSegment` child (the
/// same double-count rule ``GeometryQuerySegment`` documents); taking both would weight
/// every rectangle corner twice.
public struct SymbolExemplar: Sendable, Hashable, Codable {

    /// The primitives the exemplar was built from, ascending.
    public let primitiveIDs: [UInt64]
    /// The rectangle the estimator gave, exactly as given.
    public let region: VectorBounds
    /// Feature points in page space, in primitive order.
    public let featurePoints: [CGPoint]
    /// Mean of ``featurePoints``.
    public let centroid: CGPoint
    /// Root-mean-square distance of ``featurePoints`` from ``centroid``. The unit of
    /// every residual the matcher reports.
    public let rmsRadius: Double
    /// The tight bounds of the member primitives, not of ``region``.
    public let bounds: VectorBounds
    /// The widest bounds-to-bounds gap on the spanning tree of the member primitives:
    /// how far apart this symbol's own strokes sit. The matcher scales this by the scale
    /// band to decide which page primitives belong to one candidate.
    public let internalGap: Double
    /// ``featurePoints`` translated to the centroid and divided by ``rmsRadius`` — the
    /// cloud every candidate is aligned against.
    public let normalizedPoints: [CGPoint]
    /// How many of ``featurePoints`` each member primitive contributed, aligned with
    /// ``primitiveIDs``. The matcher judges residuals stroke by stroke — contamination
    /// arrives as whole strokes, never as scattered points — and this is the grouping
    /// it judges by.
    public let featurePointCounts: [Int]
    /// The majority style of the member primitives, for a search that requires the same style
    /// (NL-AUTO-13, ``SymbolMatchOptions/styleGate``).
    public let style: SymbolStyle

    /// Builds the exemplar from the primitives fully inside `region`.
    ///
    /// - Parameters:
    ///   - primitives: the page's extraction, as ``VectorPageExtraction/primitives``.
    ///   - region: the clicked instance's bounds, padded by the caller. A primitive
    ///     participates only when its bounds sit **entirely** inside — the estimator
    ///     drew a box around one symbol, and a wall passing through the box is not part
    ///     of the door.
    ///   - minimumPrimitiveCount: the least member primitives an exemplar may have.
    /// - Throws: ``SymbolExemplarError``.
    public init(
        primitives: [VectorPrimitive],
        region: VectorBounds,
        minimumPrimitiveCount: Int = 2
    ) throws {
        let members = primitives
            .filter { SymbolFeatureExtraction.isUsable($0) && region.contains($0.bounds) }
            .sorted { $0.id < $1.id }
        guard !members.isEmpty else { throw SymbolExemplarError.noPrimitivesInRegion }
        let required = Swift.max(1, minimumPrimitiveCount)
        guard members.count >= required else {
            throw SymbolExemplarError.tooFewPrimitives(found: members.count, required: required)
        }

        let points = members.flatMap(SymbolFeatureExtraction.featurePoints)
        guard let shape = SymbolPointCloud(points: points) else {
            throw SymbolExemplarError.degenerateGeometry
        }

        var memberBounds = members[0].bounds
        for member in members.dropFirst() { memberBounds = memberBounds.union(member.bounds) }

        self.primitiveIDs = members.map(\.id)
        self.region = region
        self.featurePoints = points
        self.centroid = shape.centroid
        self.rmsRadius = shape.rmsRadius
        self.bounds = memberBounds
        self.internalGap = SymbolFeatureExtraction.spanningGap(of: members.map(\.bounds))
        self.normalizedPoints = shape.normalizedPoints
        self.featurePointCounts = members.map {
            SymbolFeatureExtraction.featurePoints(of: $0).count
        }
        self.style = SymbolStyle(members: members)
    }
}

/// A point set with its centroid and RMS radius — the normalised form both sides of an
/// alignment are put into. `nil` when the set is empty or has no extent.
struct SymbolPointCloud {
    let centroid: CGPoint
    let rmsRadius: Double
    let normalizedPoints: [CGPoint]

    init?(points: [CGPoint]) {
        guard !points.isEmpty else { return nil }
        var sumX = 0.0
        var sumY = 0.0
        for point in points {
            guard point.x.isFinite, point.y.isFinite else { return nil }
            sumX += point.x
            sumY += point.y
        }
        let n = Double(points.count)
        let centroid = CGPoint(x: sumX / n, y: sumY / n)

        var sumSquares = 0.0
        for point in points {
            let dx = point.x - centroid.x
            let dy = point.y - centroid.y
            sumSquares += dx * dx + dy * dy
        }
        let rms = (sumSquares / n).squareRoot()
        guard rms > 0, rms.isFinite else { return nil }

        self.centroid = centroid
        self.rmsRadius = rms
        self.normalizedPoints = points.map {
            CGPoint(x: ($0.x - centroid.x) / rms, y: ($0.y - centroid.y) / rms)
        }
    }
}

/// The feature-point rule, written once so exemplar and candidate are reduced by the
/// **same** rule — a matcher whose two sides disagree about what a shape is made of
/// reports residuals that mean nothing.
enum SymbolFeatureExtraction {

    /// A primitive the matcher can use: a finite line or cubic. Subpath-level primitives
    /// are excluded because their edges already exist as `.lineSegment` children.
    static func isUsable(_ primitive: VectorPrimitive) -> Bool {
        switch primitive.kind {
        case .lineSegment:
            guard case let .line(line) = primitive.geometry else { return false }
            return !line.isDegenerate
                && line.start.x.isFinite && line.start.y.isFinite
                && line.end.x.isFinite && line.end.y.isFinite
        case .cubicCurve:
            guard case let .cubic(cubic) = primitive.geometry else { return false }
            return [cubic.p0, cubic.p1, cubic.p2, cubic.p3]
                .allSatisfy { $0.x.isFinite && $0.y.isFinite }
        case .rectangle, .closedSubpath:
            return false
        }
    }

    /// The points a primitive contributes to the cloud: both ends and the ⅓ / ⅔
    /// interior samples, for lines and cubics alike. On-curve samples only — control
    /// points are producer bookkeeping, not geometry a person drew. Interior samples on
    /// *lines* are what make a stroke's body count: a diagonal across a rectangle ends
    /// on the rectangle's own corners, and endpoints alone cannot see it.
    static func featurePoints(of primitive: VectorPrimitive) -> [CGPoint] {
        switch primitive.geometry {
        case .line(let line):
            func interpolated(_ t: Double) -> CGPoint {
                CGPoint(
                    x: line.start.x + (line.end.x - line.start.x) * t,
                    y: line.start.y + (line.end.y - line.start.y) * t
                )
            }
            return [
                line.start,
                interpolated(1.0 / 3.0),
                interpolated(2.0 / 3.0),
                line.end
            ]
        case .cubic(let cubic):
            return [
                cubic.point(at: 0),
                cubic.point(at: 1.0 / 3.0),
                cubic.point(at: 2.0 / 3.0),
                cubic.point(at: 1)
            ]
        case .rectangle, .ring:
            return []
        }
    }

    /// The widest gap on a minimum spanning tree over the boxes, where the edge weight
    /// between two boxes is the axis-aligned distance between them (zero when they touch
    /// or overlap). Prim's algorithm, O(k²) — an exemplar is a handful of strokes.
    static func spanningGap(of boxes: [VectorBounds]) -> Double {
        guard boxes.count > 1 else { return 0 }
        var inTree = [Bool](repeating: false, count: boxes.count)
        var bestDistance = [Double](repeating: .infinity, count: boxes.count)
        inTree[0] = true
        for index in 1..<boxes.count {
            bestDistance[index] = gap(boxes[0], boxes[index])
        }
        var widest = 0.0
        for _ in 1..<boxes.count {
            var next = -1
            var nextDistance = Double.infinity
            for index in boxes.indices where !inTree[index] && bestDistance[index] < nextDistance {
                next = index
                nextDistance = bestDistance[index]
            }
            guard next >= 0 else { break }
            inTree[next] = true
            widest = Swift.max(widest, nextDistance)
            for index in boxes.indices where !inTree[index] {
                bestDistance[index] = Swift.min(bestDistance[index], gap(boxes[next], boxes[index]))
            }
        }
        return widest.isFinite ? widest : 0
    }

    /// Axis-aligned distance between two boxes: zero when they touch or overlap.
    static func gap(_ a: VectorBounds, _ b: VectorBounds) -> Double {
        let dx = Swift.max(0, Swift.max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = Swift.max(0, Swift.max(a.minY - b.maxY, b.minY - a.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }
}
