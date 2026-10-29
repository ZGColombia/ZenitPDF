import CoreGraphics
import Foundation

// MARK: - Inputs

/// One point the user picked on the revised sheet and its match on the baseline sheet.
///
/// Both points are in **page space**: PDF points, y up, in the coordinates of the page
/// box the comparison is running on.
public struct AlignmentCorrespondence: Sendable, Hashable, Codable {
    /// The point on the revised page — the page that will be moved.
    public var source: CGPoint
    /// The matching point on the baseline page — the page that stays put.
    public var target: CGPoint

    public init(source: CGPoint, target: CGPoint) {
        self.source = source
        self.target = target
    }
}

/// Which family of transforms a solve is restricted to.
public enum AlignmentModel: String, Sendable, Hashable, Codable, CaseIterable {
    /// Translation only. One point pair is enough.
    case translation
    /// Translation, rotation and one uniform scale — the two-point mode.
    /// Angles and aspect ratio are preserved, which is what a re-plot
    /// of the same drawing at a different sheet size actually does to it.
    case similarity
    /// The full six-parameter affine map — the three-point mode. Non-uniform scale and
    /// shear are allowed, which handles a sheet that was scanned crooked or stretched.
    case affine

    public var minimumCorrespondences: Int {
        switch self {
        case .translation: return 1
        case .similarity: return 2
        case .affine: return 3
        }
    }
}

/// Where an alignment came from. Carried in the result so the UI never has to guess
/// whether the user placed the points or the machine did.
public enum AlignmentProvenance: String, Sendable, Hashable, Codable, CaseIterable {
    /// The two pages were declared to be in the same coordinate system.
    case identity
    /// Solved by matching the two page boxes.
    case pageBox
    /// Solved from user-placed point pairs under the similarity model.
    case manualTwoPoint
    /// Solved from user-placed point pairs under the affine model.
    case manualThreePoint
    /// Solved from user-placed point pairs as a pure translation (CR-139).
    ///
    /// Additive: the three manual cases used to be two, and a translation solve reported
    /// itself as ``manualTwoPoint``. That is the wrong answer to "how was this alignment
    /// obtained" — a translation from one pair carries no rotation and no scale evidence
    /// at all, and a reader deciding whether to trust the alignment, or an export
    /// recording how it was made, was told a similarity had been fitted to two points.
    case manualTranslation
    /// Returned by Vision's image registration and verified against the pixels.
    case automaticVision
    /// Supplied by the caller as a finished transform.
    case explicit
}

// MARK: - Outputs

/// How badly the solved transform misses the correspondences it was solved from.
///
/// A two-point similarity solve and a three-point affine solve are exactly determined,
/// so both come back with a zero residual by construction — the number only becomes
/// informative when the caller supplies more pairs than the model needs, or when the
/// alignment came from page-box matching or from Vision. It is reported in every case
/// so that the caller has one field to look at rather than three rules to remember.
public struct AlignmentResidual: Sendable, Hashable, Codable {
    /// Root-mean-square of the per-pair Euclidean distances, in page points.
    public let rootMeanSquare: Double
    /// The worst single pair, in page points.
    public let maximum: Double
    /// One distance per correspondence, in the order they were supplied.
    public let perCorrespondence: [Double]

    public init(rootMeanSquare: Double, maximum: Double, perCorrespondence: [Double]) {
        self.rootMeanSquare = rootMeanSquare
        self.maximum = maximum
        self.perCorrespondence = perCorrespondence
    }

    public static let zero = AlignmentResidual(rootMeanSquare: 0, maximum: 0, perCorrespondence: [])

    /// Measures `transform` against `correspondences`.
    public static func measure(
        of transform: AlignmentTransform,
        against correspondences: [AlignmentCorrespondence]
    ) -> AlignmentResidual {
        guard !correspondences.isEmpty else { return .zero }
        var distances: [Double] = []
        distances.reserveCapacity(correspondences.count)
        var sumOfSquares = 0.0
        var worst = 0.0
        for pair in correspondences {
            let mapped = transform.apply(to: pair.source)
            let distance = Double(hypot(mapped.x - pair.target.x, mapped.y - pair.target.y))
            distances.append(distance)
            sumOfSquares += distance * distance
            worst = Swift.max(worst, distance)
        }
        return AlignmentResidual(
            rootMeanSquare: (sumOfSquares / Double(correspondences.count)).squareRoot(),
            maximum: worst,
            perCorrespondence: distances
        )
    }
}

/// A solved alignment, with everything needed to decide whether to trust it.
public struct AlignmentSolution: Sendable, Hashable, Codable {
    /// Maps revised page space onto baseline page space.
    public let transform: AlignmentTransform
    public let model: AlignmentModel
    public let provenance: AlignmentProvenance
    public let residual: AlignmentResidual
    public let correspondenceCount: Int
    /// `0…1`. How far the point configuration is from the degenerate one for this model:
    /// coincident points for a similarity, collinear points for an affine map. See
    /// ``AlignmentConditioning`` for the exact formula.
    public let conditioning: Double
    /// Mean absolute gray-level difference between the two rasters after the transform
    /// was applied, on the `0…255` scale of an 8-bit gray image. `nil` for every
    /// alignment that was not measured against pixels (CR-131).
    ///
    /// Its own field because it is its own quantity. ``residual`` is in **page points**
    /// and says how far the solved map misses the correspondences it was fitted to;
    /// ``AlignmentSolver/solveTwoPoint(_:)`` writes it, `AlignmentResidual.measure`
    /// computes it, and every reader — a tolerance, a "residual too large" warning, an
    /// export — treats it as a distance. The automatic aligner had nothing in page points
    /// to report, so it put a gray level there instead: an alignment that matched the
    /// pixels almost perfectly reported a residual of, say, 4, and one that matched
    /// exactly reported 0, and the units happened to look plausible either way.
    public let pixelDissimilarity: Double?

    public init(
        transform: AlignmentTransform,
        model: AlignmentModel,
        provenance: AlignmentProvenance,
        residual: AlignmentResidual,
        correspondenceCount: Int,
        conditioning: Double,
        pixelDissimilarity: Double? = nil
    ) {
        self.transform = transform
        self.model = model
        self.provenance = provenance
        self.residual = residual
        self.correspondenceCount = correspondenceCount
        self.conditioning = conditioning
        self.pixelDissimilarity = pixelDissimilarity
    }

    /// The identity alignment: the two pages are declared to share a coordinate system.
    public static let identity = AlignmentSolution(
        transform: .identity,
        model: .translation,
        provenance: .identity,
        residual: .zero,
        correspondenceCount: 0,
        conditioning: 1
    )

    /// The uniform scale the transform carries, for display.
    public var scale: Double { transform.meanScale }
    /// The rotation the transform carries, in degrees, for display.
    public var rotationDegrees: Double { transform.rotationRadians * 180 / .pi }
}

/// The conditioning rule, written once so it is auditable rather than scattered.
///
/// | Model | Formula | Degenerate at |
/// |---|---|---|
/// | translation | `1` always | never — one point is always enough |
/// | similarity | `min(1, spread / diagonal)` where `spread` is the largest distance between two source points and `diagonal` the bounding-box diagonal of the source points | coincident points |
/// | affine | `\|sin θ\| · min(\|v₁\|,\|v₂\|) / max(\|v₁\|,\|v₂\|)` for the two legs `v₁`, `v₂` of the widest-angled triple | collinear points |
///
/// For the similarity model with exactly two points the formula evaluates to `1`
/// whenever the points differ, which is correct: two distinct points determine a
/// similarity exactly, however close together they are. Closeness costs *precision*,
/// not solvability, and precision is reported as the residual of the pixels, not here.
public enum AlignmentConditioning {
    /// Solves refuse anything below this.
    public static let minimum = 1e-6

    public static func similarity(_ correspondences: [AlignmentCorrespondence]) -> Double {
        guard correspondences.count >= 2 else { return 1 }
        var spread = 0.0
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for pair in correspondences {
            minX = Swift.min(minX, Double(pair.source.x))
            maxX = Swift.max(maxX, Double(pair.source.x))
            minY = Swift.min(minY, Double(pair.source.y))
            maxY = Swift.max(maxY, Double(pair.source.y))
        }
        for i in 0..<correspondences.count {
            for j in (i + 1)..<correspondences.count {
                let a = correspondences[i].source
                let b = correspondences[j].source
                spread = Swift.max(spread, Double(hypot(a.x - b.x, a.y - b.y)))
            }
        }
        let diagonal = hypot(maxX - minX, maxY - minY)
        guard diagonal > 0 else { return 0 }
        return Swift.min(1, spread / diagonal)
    }

    public static func affine(_ correspondences: [AlignmentCorrespondence]) -> Double {
        guard correspondences.count >= 3 else { return 0 }
        var best = 0.0
        let count = correspondences.count
        // Bounded: the caller-facing solver caps the correspondence count, and three
        // nested loops over that cap is a fixed, small amount of work.
        for i in 0..<count {
            for j in 0..<count where j != i {
                for k in (j + 1)..<count where k != i {
                    let o = correspondences[i].source
                    let p = correspondences[j].source
                    let q = correspondences[k].source
                    let v1 = (x: Double(p.x - o.x), y: Double(p.y - o.y))
                    let v2 = (x: Double(q.x - o.x), y: Double(q.y - o.y))
                    let l1 = hypot(v1.x, v1.y)
                    let l2 = hypot(v2.x, v2.y)
                    guard l1 > 0, l2 > 0 else { continue }
                    let sine = abs(v1.x * v2.y - v1.y * v2.x) / (l1 * l2)
                    let balance = Swift.min(l1, l2) / Swift.max(l1, l2)
                    best = Swift.max(best, sine * balance)
                }
            }
        }
        return Swift.min(1, best)
    }
}

// MARK: - Solver

/// Closed-form least-squares alignment.
///
/// Nothing here iterates and nothing here converges: the similarity solve is the 2-D
/// Umeyama form and the affine solve is one 3×3 normal-equation system per output
/// coordinate, both written out. That matters for a takeoff tool — a user who nudges a
/// control point must get the same answer every time, and an iterative solver seeded
/// differently would not guarantee that.
public enum AlignmentSolver {

    /// The most point pairs a single solve will look at. Above this the caller is not
    /// aligning two drawings, and the cubic term in ``AlignmentConditioning/affine(_:)``
    /// would stop being free.
    public static let maximumCorrespondences = 64

    // MARK: Two-point (translation + rotation + uniform scale)

    /// The two-point mode.
    ///
    /// With exactly two pairs the solution is exact and the residual is zero. With more
    /// than two it is the least-squares similarity: the transform that minimises the sum
    /// of squared distances between the mapped source points and the target points, and
    /// the residual then says how well the user's picks actually agree.
    public static func solveTwoPoint(
        _ correspondences: [AlignmentCorrespondence]
    ) throws -> AlignmentSolution {
        try validate(correspondences, model: .similarity)
        let conditioning = AlignmentConditioning.similarity(correspondences)
        guard conditioning >= AlignmentConditioning.minimum else {
            throw AlignmentFault.degenerateConfiguration(
                model: .similarity,
                conditioning: conditioning,
                minimum: AlignmentConditioning.minimum
            )
        }

        let n = Double(correspondences.count)
        var sourceMeanX = 0.0, sourceMeanY = 0.0, targetMeanX = 0.0, targetMeanY = 0.0
        for pair in correspondences {
            sourceMeanX += Double(pair.source.x)
            sourceMeanY += Double(pair.source.y)
            targetMeanX += Double(pair.target.x)
            targetMeanY += Double(pair.target.y)
        }
        sourceMeanX /= n; sourceMeanY /= n; targetMeanX /= n; targetMeanY /= n

        // Σ p·q gives the cosine term, Σ p×q the sine term, Σ |p|² the scale denominator.
        var dot = 0.0, cross = 0.0, sourceEnergy = 0.0
        for pair in correspondences {
            let px = Double(pair.source.x) - sourceMeanX
            let py = Double(pair.source.y) - sourceMeanY
            let qx = Double(pair.target.x) - targetMeanX
            let qy = Double(pair.target.y) - targetMeanY
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            sourceEnergy += px * px + py * py
        }
        guard sourceEnergy > 0 else {
            throw AlignmentFault.degenerateConfiguration(
                model: .similarity, conditioning: 0, minimum: AlignmentConditioning.minimum
            )
        }
        let magnitude = hypot(dot, cross)
        guard magnitude > 0 else {
            // Every target point is the same point: no rotation is recoverable.
            throw AlignmentFault.degenerateConfiguration(
                model: .similarity, conditioning: 0, minimum: AlignmentConditioning.minimum
            )
        }
        let scale = magnitude / sourceEnergy
        let cosine = scale * dot / magnitude
        let sine = scale * cross / magnitude
        let transform = AlignmentTransform(
            a: cosine,
            b: sine,
            c: -sine,
            d: cosine,
            tx: targetMeanX - (cosine * sourceMeanX - sine * sourceMeanY),
            ty: targetMeanY - (sine * sourceMeanX + cosine * sourceMeanY)
        )
        guard transform.isFinite else { throw AlignmentFault.singularSystem(model: .similarity) }

        return AlignmentSolution(
            transform: transform,
            model: .similarity,
            provenance: .manualTwoPoint,
            residual: AlignmentResidual.measure(of: transform, against: correspondences),
            correspondenceCount: correspondences.count,
            conditioning: conditioning
        )
    }

    // MARK: Three-point (full affine)

    /// The three-point mode, with validation that the three points are not collinear.
    ///
    /// Three non-collinear pairs determine the affine map exactly; more pairs give the
    /// least-squares fit and a residual the user can be shown before confirming.
    public static func solveThreePoint(
        _ correspondences: [AlignmentCorrespondence]
    ) throws -> AlignmentSolution {
        try validate(correspondences, model: .affine)
        let conditioning = AlignmentConditioning.affine(correspondences)
        guard conditioning >= AlignmentConditioning.minimum else {
            throw AlignmentFault.degenerateConfiguration(
                model: .affine,
                conditioning: conditioning,
                minimum: AlignmentConditioning.minimum
            )
        }

        // Normal equations. Design row for pair i is [xᵢ, yᵢ, 1]; the same 3×3 Gram
        // matrix serves both output coordinates, so it is built once.
        var gram = [Double](repeating: 0, count: 9)
        var rhsX = [Double](repeating: 0, count: 3)
        var rhsY = [Double](repeating: 0, count: 3)
        for pair in correspondences {
            let row = [Double(pair.source.x), Double(pair.source.y), 1.0]
            for r in 0..<3 {
                for c in 0..<3 {
                    gram[r * 3 + c] += row[r] * row[c]
                }
                rhsX[r] += row[r] * Double(pair.target.x)
                rhsY[r] += row[r] * Double(pair.target.y)
            }
        }

        guard let solutionX = solve3x3(gram, rhsX), let solutionY = solve3x3(gram, rhsY) else {
            // CR-146. `singularSystem` means "a bug in us"; this is not that. The
            // conditioning test above already passed, so the caller was told the points
            // were usable, and then the 3×3 pivot failed anyway — which happens when the
            // configuration is degenerate to within the arithmetic rather than to within
            // the conditioning measure (three points a hair off collinear, or so far
            // apart that the Gram matrix loses the difference). That is a statement about
            // the *points*, and the caller's response is to move one of them, so it is
            // reported as the degenerate configuration it is, carrying the conditioning
            // that was not enough to catch it.
            throw AlignmentFault.degenerateConfiguration(
                model: .affine,
                conditioning: conditioning,
                minimum: AlignmentConditioning.minimum
            )
        }
        let transform = AlignmentTransform(
            a: solutionX[0], b: solutionY[0],
            c: solutionX[1], d: solutionY[1],
            tx: solutionX[2], ty: solutionY[2]
        )
        guard transform.isFinite else { throw AlignmentFault.singularSystem(model: .affine) }
        // Well-spread sources with collinear *targets* solve to a finite transform with
        // determinant 0, which used to be returned and failed only later in the warp as
        // "not invertible" (BH-467). It is a statement about the picks, so say so here.
        let linearScale = Swift.max(abs(transform.a), abs(transform.b), abs(transform.c), abs(transform.d), 1e-300)
        guard abs(transform.determinant) > 1e-9 * linearScale * linearScale else {
            throw AlignmentFault.degenerateConfiguration(
                model: .affine,
                conditioning: 0,
                minimum: AlignmentConditioning.minimum
            )
        }

        return AlignmentSolution(
            transform: transform,
            model: .affine,
            provenance: .manualThreePoint,
            residual: AlignmentResidual.measure(of: transform, against: correspondences),
            correspondenceCount: correspondences.count,
            conditioning: conditioning
        )
    }

    // MARK: Translation only

    /// Translation from the centroid offset. One pair is enough; more pairs average.
    public static func solveTranslation(
        _ correspondences: [AlignmentCorrespondence]
    ) throws -> AlignmentSolution {
        try validate(correspondences, model: .translation)
        let n = Double(correspondences.count)
        var dx = 0.0, dy = 0.0
        for pair in correspondences {
            dx += Double(pair.target.x - pair.source.x)
            dy += Double(pair.target.y - pair.source.y)
        }
        let transform = AlignmentTransform.translation(dx: dx / n, dy: dy / n)
        return AlignmentSolution(
            transform: transform,
            model: .translation,
            provenance: .manualTranslation,
            residual: AlignmentResidual.measure(of: transform, against: correspondences),
            correspondenceCount: correspondences.count,
            conditioning: 1
        )
    }

    /// Dispatches to the solver for `model`.
    public static func solve(
        _ correspondences: [AlignmentCorrespondence],
        model: AlignmentModel
    ) throws -> AlignmentSolution {
        switch model {
        case .translation: return try solveTranslation(correspondences)
        case .similarity: return try solveTwoPoint(correspondences)
        case .affine: return try solveThreePoint(correspondences)
        }
    }

    // MARK: - Internals

    private static func validate(
        _ correspondences: [AlignmentCorrespondence],
        model: AlignmentModel
    ) throws {
        let required = model.minimumCorrespondences
        guard correspondences.count >= required else {
            throw AlignmentFault.insufficientCorrespondences(
                model: model, required: required, given: correspondences.count
            )
        }
        guard correspondences.count <= maximumCorrespondences else {
            throw AlignmentFault.tooManyCorrespondences(
                given: correspondences.count, limit: maximumCorrespondences
            )
        }
        for (index, pair) in correspondences.enumerated() {
            guard pair.source.x.isFinite, pair.source.y.isFinite,
                  pair.target.x.isFinite, pair.target.y.isFinite else {
                throw AlignmentFault.nonFiniteInput(index: index)
            }
        }
        // Coincident source points make the model unsolvable for anything above a
        // translation, and are much more likely to be a double-click than an intent.
        guard model != .translation else { return }
        // `coincidentPoints` is documented as two source *or two target* points; only the
        // sources used to be checked (BH-467).
        for i in 0..<correspondences.count {
            for j in (i + 1)..<correspondences.count {
                for side in [\AlignmentCorrespondence.source, \AlignmentCorrespondence.target] {
                    let a = correspondences[i][keyPath: side]
                    let b = correspondences[j][keyPath: side]
                    let separation = Double(hypot(a.x - b.x, a.y - b.y))
                    if separation < coincidenceThreshold {
                        throw AlignmentFault.coincidentPoints(indexA: i, indexB: j, separation: separation)
                    }
                }
            }
        }
    }

    /// Two picks closer than a thousandth of a PDF point are the same pick.
    static let coincidenceThreshold = 1e-3

    /// Gaussian elimination with partial pivoting on a 3×3 system, row-major.
    static func solve3x3(_ matrix: [Double], _ rhs: [Double]) -> [Double]? {
        guard matrix.count == 9, rhs.count == 3 else { return nil }
        var m = matrix
        var v = rhs
        var scaleReference = 0.0
        for value in m { scaleReference = Swift.max(scaleReference, abs(value)) }
        guard scaleReference > 0, scaleReference.isFinite else { return nil }
        let tolerance = scaleReference * 1e-12

        for column in 0..<3 {
            var pivotRow = column
            var pivotValue = abs(m[column * 3 + column])
            for row in (column + 1)..<3 where abs(m[row * 3 + column]) > pivotValue {
                pivotValue = abs(m[row * 3 + column])
                pivotRow = row
            }
            guard pivotValue > tolerance else { return nil }
            if pivotRow != column {
                for k in 0..<3 { m.swapAt(column * 3 + k, pivotRow * 3 + k) }
                v.swapAt(column, pivotRow)
            }
            let pivot = m[column * 3 + column]
            for row in (column + 1)..<3 {
                let factor = m[row * 3 + column] / pivot
                guard factor.isFinite else { return nil }
                for k in column..<3 { m[row * 3 + k] -= factor * m[column * 3 + k] }
                v[row] -= factor * v[column]
            }
        }

        var result = [Double](repeating: 0, count: 3)
        for row in stride(from: 2, through: 0, by: -1) {
            var accumulator = v[row]
            for k in (row + 1)..<3 { accumulator -= m[row * 3 + k] * result[k] }
            let pivot = m[row * 3 + row]
            guard abs(pivot) > tolerance else { return nil }
            result[row] = accumulator / pivot
        }
        for value in result where !value.isFinite { return nil }
        return result
    }
}
