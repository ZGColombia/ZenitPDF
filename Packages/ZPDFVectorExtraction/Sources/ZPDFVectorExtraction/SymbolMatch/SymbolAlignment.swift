import CoreGraphics
import Foundation

/// The geometric core of symbol matching: given two normalised point clouds, find the
/// similarity transform — rotation **or reflection**, small scale correction,
/// translation — that lays one over the other, and say how well it fits.
///
/// ## The algorithm
///
/// 1. **Coarse search.** Both clouds are already centred and RMS-normalised, so only
///    orientation is unknown. Every rotation hypothesis on an even grid over the full
///    turn is tried twice — plain, and mirrored across the x-axis first — and scored by
///    the trimmed mean squared nearest-neighbour distance from the exemplar cloud onto
///    the candidate cloud, the declared contamination share of worst distances set
///    aside so a stray stroke caught in the exemplar's crop cannot outvote the shape.
///    Rotation and mirror invariance therefore come from explicit search, not from a
///    signature that could alias two different shapes.
/// 2. **Refinement.** From the best hypothesis, a fixed number of nearest-neighbour
///    Procrustes steps: pair each exemplar point with its nearest candidate point under
///    the current transform, drop the declared share of worst pairs — contamination
///    has no true counterpart, and a least-squares fit that keeps it is dragged by
///    it — then solve the orthogonal Procrustes problem on the kept pairs **with
///    reflection allowed** — the closed 2×2 form of Kabsch — plus the least-squares
///    scale and translation for those pairs.
/// 3. **Judgement** (``judge``). The residual is judged **stroke by stroke**,
///    both ways. Contamination arrives as whole strokes — a dash, a tick, a leader
///    fragment — never as scattered points, so each primitive's points are scored as
///    one unit: the RMS nearest-neighbour distance of its points into the other cloud.
///    Each side may write off its declared contamination share of worst strokes; the
///    worst *kept* stroke, over both directions, is the residual. Both directions
///    matter for the same reason as ever: a candidate with strokes missing must score
///    badly even when the strokes it shares line up perfectly — one-way residuals are
///    how a matcher convinces itself half a door is a door. A pooled point RMS would
///    instead let twenty perfect strokes wash out the one that is missing, which is
///    how a plain rectangle passes as a crossed one.
///
/// Deterministic throughout: fixed iteration counts, ties in nearest-neighbour search
/// and in every trim broken by index, no randomness, no time.
enum SymbolAlignment {

    /// The outcome of aligning one normalised cloud onto another.
    struct Alignment {
        /// Orthogonal part: `[[r00, r01], [r10, r11]]`, determinant ±1.
        var r00: Double
        var r01: Double
        var r10: Double
        var r11: Double
        /// Scale correction on top of the RMS normalisation. Near 1 for a true instance.
        var scale: Double
        /// Translation in normalised space. Near 0 for a true instance.
        var tx: Double
        var ty: Double
        /// Symmetric RMS nearest-neighbour residual, in normalised units.
        var residual: Double
        /// `true` when the orthogonal part is a reflection.
        var isMirrored: Bool
    }

    /// Aligns `exemplar` onto `candidate`; both must be centred and RMS-normalised.
    /// `trimShare` is the share of worst source points written off as contamination in
    /// the coarse scoring and the refinement pairing; the returned residual is
    /// `.infinity` — judging is ``judge``'s job, stroke by stroke.
    ///
    /// `droppable`, one flag per exemplar point, says which points may be trimmed at all
    /// (`nil` for all of them). Trimming used to be blind: the four worst points of a
    /// rectangle-with-one-diagonal exemplar are the diagonal's own interior samples, so
    /// under a 90° hypothesis — diagonal onto anti-diagonal — they were trimmed away and
    /// the wrong orientation scored as well as the right one (BH-333). Points of strokes
    /// that cannot be contamination are never trimmed.
    ///
    /// Every hypothesis is scored **after** one nearest-neighbour Procrustes step from
    /// it, not as a bare rotation, and the rotation grid is joined by hypotheses read
    /// off stroke correspondences (`exemplarCounts` / `candidateCounts` give the stroke
    /// structure of each cloud): the longest exemplar strokes that cannot be
    /// contamination, each mapped onto each of the candidate's longest strokes, in both
    /// orientations and both families. A pure rotation about the cloud's centroid has no
    /// translation, and a stub the clustering dragged in shifts the candidate's centroid
    /// off the symbol by a few tenths of a normalised unit — enough for every grid
    /// hypothesis to settle in a wrong basin and a true instance to be rejected on
    /// residual (BH-334, BH-335); a chord-to-chord correspondence is exact whatever the
    /// centroid did. Solving scale and translation once per hypothesis costs `O(n)` on
    /// top of the `O(n·m)` search already paid for it.
    static func align(
        exemplar: [CGPoint],
        candidate: [CGPoint],
        rotationSteps: Int,
        refinementIterations: Int,
        maximumPoints: Int,
        trimShare: Double,
        droppable: [Bool]? = nil,
        exemplarCounts: [Int]? = nil,
        candidateCounts: [Int]? = nil
    ) -> Alignment {
        let source = strided(exemplar, to: maximumPoints)
        let target = strided(candidate, to: maximumPoints)
        let sourceDroppable = droppable.map { strided($0, to: maximumPoints) }
        let droppableCount = sourceDroppable?.filter { $0 }.count ?? source.count
        let dropCount = Swift.min(
            Swift.max(Int(Double(source.count) * trimShare), 0),
            Swift.max(source.count - 1, 0),
            droppableCount
        )
        func mayDrop(_ index: Int) -> Bool {
            guard let sourceDroppable, index < sourceDroppable.count else { return true }
            return sourceDroppable[index]
        }

        /// The mean squared nearest-neighbour distance under `alignment`, the worst
        /// `dropCount` droppable points set aside. Which are dropped cannot depend on
        /// visit order: the sum of the kept smallest values is a property of the multiset.
        func trimmedScore(_ alignment: Alignment) -> Double {
            var fixedSum = 0.0
            var droppableDistances: [Double] = []
            droppableDistances.reserveCapacity(droppableCount)
            for index in source.indices {
                let distance = squaredNearestDistance(from: alignment.applied(to: source[index]), to: target)
                if mayDrop(index) {
                    droppableDistances.append(distance)
                } else {
                    fixedSum += distance
                }
            }
            droppableDistances.sort()
            var sum = fixedSum
            for index in 0..<Swift.max(droppableDistances.count - dropCount, 0) {
                sum += droppableDistances[index]
            }
            return sum / Double(Swift.max(source.count - dropCount, 1))
        }

        /// One nearest-neighbour Procrustes step: pairs under `alignment`, the worst
        /// `dropCount` droppable pairs dropped (ties broken by source index, so the kept
        /// set is deterministic), then the closed form on the kept pairs.
        func refined(_ alignment: Alignment) -> Alignment? {
            var scored: [(index: Int, distance: Double, target: CGPoint)] = []
            scored.reserveCapacity(source.count)
            for index in source.indices {
                let moved = alignment.applied(to: source[index])
                let nearest = target[nearestIndex(from: moved, to: target)]
                let dx = nearest.x - moved.x
                let dy = nearest.y - moved.y
                scored.append((index, dx * dx + dy * dy, nearest))
            }
            scored.sort { ($0.distance, $0.index) < ($1.distance, $1.index) }
            var pairs: [(source: CGPoint, target: CGPoint)] = []
            pairs.reserveCapacity(source.count)
            var droppableKept = 0
            let droppableToKeep = droppableCount - dropCount
            for entry in scored {
                if mayDrop(entry.index) {
                    guard droppableKept < droppableToKeep else { continue }
                    droppableKept += 1
                }
                pairs.append((source[entry.index], entry.target))
            }
            guard pairs.count >= 2 else { return nil }
            return procrustes(pairs: pairs)
        }

        guard !source.isEmpty, !target.isEmpty else {
            return Alignment(
                fromOrthogonal: orthogonal(angle: 0, mirrored: false),
                scale: 1, tx: 0, ty: 0, residual: .infinity, isMirrored: false
            )
        }

        // Coarse: every rotation on the grid, plain and mirrored, then the chord
        // correspondences; each taken one Procrustes step and scored there. The first
        // hypothesis to reach a score keeps it on a tie, so the choice is a function of
        // the input alone.
        var hypotheses: [Alignment] = []
        for step in 0..<rotationSteps {
            let angle = 2 * Double.pi * Double(step) / Double(rotationSteps)
            for mirrored in [false, true] {
                hypotheses.append(Alignment(
                    fromOrthogonal: orthogonal(angle: angle, mirrored: mirrored),
                    scale: 1, tx: 0, ty: 0, residual: .infinity, isMirrored: mirrored
                ))
            }
        }
        if let exemplarCounts, let candidateCounts {
            hypotheses += chordHypotheses(
                exemplar: exemplar, exemplarCounts: exemplarCounts, droppable: droppable,
                candidate: candidate, candidateCounts: candidateCounts
            )
        }

        var best: Alignment?
        var bestScore = Double.infinity
        for var hypothesis in hypotheses {
            if let stepped = refined(hypothesis) { hypothesis = stepped }
            let score = trimmedScore(hypothesis)
            if score < bestScore {
                bestScore = score
                best = hypothesis
            }
        }

        var current = best ?? Alignment(
            fromOrthogonal: orthogonal(angle: 0, mirrored: false),
            scale: 1, tx: 0, ty: 0, residual: .infinity, isMirrored: false
        )

        // Refine from the best hypothesis.
        for _ in 0..<refinementIterations {
            guard let solved = refined(current) else { break }
            current = solved
        }

        current.isMirrored = current.determinant < 0
        return current
    }

    // MARK: - Chord hypotheses

    /// Exemplar strokes used as anchors: the longest that cannot be contamination.
    static let anchorStrokeCount = 2
    /// Candidate strokes each anchor is tried against: the longest. Bounded so a
    /// candidate of many strokes cannot make the coarse stage quadratic in them.
    static let candidateAnchorStrokeCount = 16
    /// A chord correspondence implying a scale outside this band, in normalised units,
    /// cannot be an instance of a cloud already RMS-normalised and is not tried.
    static let chordScaleBand: ClosedRange<Double> = 0.2...5

    /// The chord of every stroke — its first and last feature point — with its length.
    static func chords(_ points: [CGPoint], counts: [Int]) -> [(a: CGPoint, b: CGPoint, length: Double)] {
        var result: [(a: CGPoint, b: CGPoint, length: Double)] = []
        result.reserveCapacity(counts.count)
        var start = 0
        for count in counts {
            defer { start += Swift.max(count, 0) }
            guard count > 0, start + count <= points.count else { continue }
            let a = points[start]
            let b = points[start + count - 1]
            result.append((a, b, hypot(b.x - a.x, b.y - a.y)))
        }
        return result
    }

    /// The similarity that maps chord `a→b` onto chord `c→d`, reflecting the source
    /// through the x-axis first for the mirrored family, or `nil` when either chord is
    /// degenerate or the implied scale is outside ``chordScaleBand``.
    static func similarity(
        mapping a: CGPoint, _ b: CGPoint, onto c: CGPoint, _ d: CGPoint, mirrored: Bool
    ) -> Alignment? {
        let ab = CGPoint(x: b.x - a.x, y: mirrored ? -(b.y - a.y) : b.y - a.y)
        let cd = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let abLength = ab.magnitude
        let cdLength = cd.magnitude
        guard abLength > 1e-12, cdLength > 1e-12 else { return nil }
        let scale = cdLength / abLength
        guard chordScaleBand.contains(scale) else { return nil }
        let theta = atan2(cd.y, cd.x) - atan2(ab.y, ab.x)
        // For the mirrored family the orthogonal part is `R(θ)·F`, which is exactly what
        // `orthogonal(angle:mirrored:)` builds.
        let orth = orthogonal(angle: theta, mirrored: mirrored)
        let ra = apply(orth, to: a)
        return Alignment(
            fromOrthogonal: orth, scale: scale,
            tx: c.x - scale * ra.x, ty: c.y - scale * ra.y,
            residual: .infinity, isMirrored: mirrored
        )
    }

    /// Alignment hypotheses read off stroke correspondences: each anchor chord of the
    /// exemplar onto each of the candidate's longest chords, both orientations, both
    /// families. Order is a function of the input (lengths descending, index ascending),
    /// so the coarse stage's tie-breaking stays deterministic.
    static func chordHypotheses(
        exemplar: [CGPoint], exemplarCounts: [Int], droppable: [Bool]?,
        candidate: [CGPoint], candidateCounts: [Int]
    ) -> [Alignment] {
        let exemplarChords = chords(exemplar, counts: exemplarCounts)
        let candidateChords = chords(candidate, counts: candidateCounts)
        guard !exemplarChords.isEmpty, !candidateChords.isEmpty else { return [] }

        func longest(_ indices: [Int], of chords: [(a: CGPoint, b: CGPoint, length: Double)], take count: Int) -> [Int] {
            Array(indices.sorted { (chords[$0].length, $1) > (chords[$1].length, $0) }.prefix(count))
        }
        let structural = exemplarChords.indices.filter { !(droppable?[$0] ?? false) }
        let anchorIndices = longest(
            structural.isEmpty ? Array(exemplarChords.indices) : structural,
            of: exemplarChords, take: anchorStrokeCount
        )
        let targetIndices = longest(
            Array(candidateChords.indices), of: candidateChords, take: candidateAnchorStrokeCount
        )

        var result: [Alignment] = []
        result.reserveCapacity(anchorIndices.count * targetIndices.count * 4)
        for anchor in anchorIndices {
            let e = exemplarChords[anchor]
            for targetIndex in targetIndices {
                let t = candidateChords[targetIndex]
                for mirrored in [false, true] {
                    if let forward = similarity(mapping: e.a, e.b, onto: t.a, t.b, mirrored: mirrored) {
                        result.append(forward)
                    }
                    if let reversed = similarity(mapping: e.a, e.b, onto: t.b, t.a, mirrored: mirrored) {
                        result.append(reversed)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Procrustes

    /// Closed-form 2×2 orthogonal Procrustes over matched pairs, reflection allowed,
    /// with least-squares scale and translation. `nil` when the pairs are degenerate.
    ///
    /// With centred pairs `e'`, `c'`, the orthogonal matrix maximising `Σ c'·(R e')` is,
    /// among rotations, the one at `θ = atan2(M01 − M10, M00 + M11)`, and among
    /// reflections the one at `φ = atan2(M01 + M10, M00 − M11)`, where `M = Σ e' c'ᵀ`.
    /// Whichever family scores higher wins — that is exactly "Kabsch with reflection
    /// allowed" in two dimensions, without a numerical SVD to explain.
    static func procrustes(pairs: [(source: CGPoint, target: CGPoint)]) -> Alignment? {
        guard pairs.count >= 2 else { return nil }
        let n = Double(pairs.count)
        var meanSourceX = 0.0, meanSourceY = 0.0
        var meanTargetX = 0.0, meanTargetY = 0.0
        for pair in pairs {
            meanSourceX += pair.source.x
            meanSourceY += pair.source.y
            meanTargetX += pair.target.x
            meanTargetY += pair.target.y
        }
        meanSourceX /= n
        meanSourceY /= n
        meanTargetX /= n
        meanTargetY /= n

        var m00 = 0.0, m01 = 0.0, m10 = 0.0, m11 = 0.0
        var sourceNorm = 0.0
        for pair in pairs {
            let ex = pair.source.x - meanSourceX
            let ey = pair.source.y - meanSourceY
            let cx = pair.target.x - meanTargetX
            let cy = pair.target.y - meanTargetY
            m00 += ex * cx
            m01 += ex * cy
            m10 += ey * cx
            m11 += ey * cy
            sourceNorm += ex * ex + ey * ey
        }
        guard sourceNorm > 1e-12 else { return nil }

        let rotationScore = hypot(m00 + m11, m01 - m10)
        let reflectionScore = hypot(m00 - m11, m01 + m10)

        let r00: Double, r01: Double, r10: Double, r11: Double
        let score: Double
        if rotationScore >= reflectionScore {
            let theta = atan2(m01 - m10, m00 + m11)
            let c = cos(theta), s = sin(theta)
            // Rotation [[c, −s], [s, c]].
            r00 = c; r01 = -s; r10 = s; r11 = c
            score = rotationScore
        } else {
            let phi = atan2(m01 + m10, m00 - m11)
            let c = cos(phi), s = sin(phi)
            // Reflection [[c, s], [s, −c]].
            r00 = c; r01 = s; r10 = s; r11 = -c
            score = reflectionScore
        }

        let scale = score / sourceNorm
        guard scale.isFinite, scale > 0 else { return nil }

        let tx = meanTargetX - scale * (r00 * meanSourceX + r01 * meanSourceY)
        let ty = meanTargetY - scale * (r10 * meanSourceX + r11 * meanSourceY)
        return Alignment(
            r00: r00, r01: r01, r10: r10, r11: r11,
            scale: scale, tx: tx, ty: ty,
            residual: .infinity,
            isMirrored: r00 * r11 - r01 * r10 < 0
        )
    }

    // MARK: - Residual

    /// What ``judge``
    /// decided.
    struct Judgement {
        /// The worst kept per-stroke residual over both directions, in candidate units.
        var residual: Double
        /// Indices into `candidateCounts` of the candidate strokes whose own residual
        /// exceeded `threshold` — the strokes the candidate side had to write off, which
        /// may be contamination or may be a second instance touching this one (BH-334).
        var unmatchedCandidateStrokes: [Int]
    }

    /// The judged residual: per-stroke, contamination-aware, measured both ways.
    ///
    /// Each primitive's feature points are scored as one unit — the RMS
    /// nearest-neighbour distance of its points into the other cloud, under
    /// `alignment` forward and under its inverse backward. Each direction may write
    /// off its declared number of worst strokes as contamination; the worst **kept**
    /// stroke, over both directions, is the residual. Judged on the full clouds, never
    /// the strided ones: a stroke is a handful of points, and every one of them votes.
    ///
    /// **Units.** Both directions are reported as a fraction of the *candidate's* RMS
    /// radius, the unit ``SymbolMatchOptions/residualThreshold`` is declared in. Forward
    /// distances are measured in candidate-normalised space already; backward distances
    /// are measured in exemplar-normalised space, where one unit is `alignment.scale`
    /// candidate units, so they are multiplied by that scale. Without it the direction
    /// that exists to catch missing strokes was judged against `threshold × scale` —
    /// lenient for a bloated exemplar, strict for a lean one (BH-869).
    ///
    /// **Which exemplar strokes may be written off.** Only those in `exemplarDroppable`
    /// (`nil` for all of them). ``SymbolMatcher`` passes the strokes with a free end —
    /// contamination is a dash, a tick or a leader fragment caught in the crop, and such
    /// a stroke ends somewhere the symbol's own strokes do not — so a stroke that closes
    /// a figure corner to corner can never be excused, and a plain rectangle no longer
    /// passes as a rectangle with one diagonal (BH-333).
    ///
    /// `exemplarCounts` / `candidateCounts` say how many consecutive points of each
    /// cloud belong to each primitive, in cloud order.
    static func judge(
        exemplarPoints: [CGPoint],
        exemplarCounts: [Int],
        exemplarDroppable: [Bool]?,
        candidatePoints: [CGPoint],
        candidateCounts: [Int],
        alignment: Alignment,
        exemplarDropCount: Int,
        candidateDropCount: Int,
        threshold: Double
    ) -> Judgement {
        guard let inverse = alignment.inverted() else {
            return Judgement(residual: .infinity, unmatchedCandidateStrokes: [])
        }

        /// One RMS nearest-neighbour value per stroke, `nil` for a stroke with no points.
        func perStroke(
            _ points: [CGPoint], _ counts: [Int], _ map: Alignment, into target: [CGPoint], scaledBy unit: Double
        ) -> [Double?] {
            var values: [Double?] = []
            values.reserveCapacity(counts.count)
            var start = 0
            for count in counts {
                guard count > 0 else {
                    values.append(nil)
                    continue
                }
                guard !target.isEmpty else {
                    values.append(.infinity)
                    start += count
                    continue
                }
                var sum = 0.0
                for index in start..<(start + count) {
                    sum += squaredNearestDistance(from: map.applied(to: points[index]), to: target)
                }
                start += count
                let value = (sum / Double(count)).squareRoot() * unit
                values.append(value.isFinite ? value : .infinity)
            }
            return values
        }

        /// The worst value after the worst `dropCount` *droppable* strokes are set aside.
        func worstKept(_ values: [Double?], droppable: [Bool]?, dropping dropCount: Int) -> Double {
            var fixed = 0.0
            var candidates: [Double] = []
            var any = false
            for (index, value) in values.enumerated() {
                guard let value else { continue }
                any = true
                if droppable?[index] ?? true {
                    candidates.append(value)
                } else {
                    fixed = Swift.max(fixed, value)
                }
            }
            guard any else { return .infinity }
            candidates.sort()
            let kept = candidates.count - Swift.max(dropCount, 0)
            let keptWorst = kept >= 1 ? candidates[kept - 1] : 0
            return Swift.max(fixed, keptWorst)
        }

        let forwardValues = perStroke(exemplarPoints, exemplarCounts, alignment, into: candidatePoints, scaledBy: 1)
        let backwardValues = perStroke(
            candidatePoints, candidateCounts, inverse, into: exemplarPoints, scaledBy: alignment.scale
        )
        let forward = worstKept(forwardValues, droppable: exemplarDroppable, dropping: exemplarDropCount)
        let backward = worstKept(backwardValues, droppable: nil, dropping: candidateDropCount)
        let unmatched = backwardValues.indices.filter { index in
            guard let value = backwardValues[index] else { return false }
            return value > threshold
        }
        return Judgement(residual: Swift.max(forward, backward), unmatchedCandidateStrokes: unmatched)
    }

    // MARK: - Small pieces

    struct Orthogonal {
        var r00: Double, r01: Double, r10: Double, r11: Double
    }

    static func orthogonal(angle: Double, mirrored: Bool) -> Orthogonal {
        let c = cos(angle), s = sin(angle)
        // Mirror across the x-axis first (y → −y), then rotate.
        if mirrored {
            return Orthogonal(r00: c, r01: s, r10: s, r11: -c)
        }
        return Orthogonal(r00: c, r01: -s, r10: s, r11: c)
    }

    static func apply(_ transform: Orthogonal, to point: CGPoint) -> CGPoint {
        CGPoint(
            x: transform.r00 * point.x + transform.r01 * point.y,
            y: transform.r10 * point.x + transform.r11 * point.y
        )
    }

    /// Index of the nearest point, ties broken by the lower index.
    static func nearestIndex(from point: CGPoint, to points: [CGPoint]) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for index in points.indices {
            let dx = points[index].x - point.x
            let dy = points[index].y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    static func squaredNearestDistance(from point: CGPoint, to points: [CGPoint]) -> Double {
        var best = Double.infinity
        for other in points {
            let dx = other.x - point.x
            let dy = other.y - point.y
            best = Swift.min(best, dx * dx + dy * dy)
        }
        return best
    }

    /// Deterministic stride-downsample to at most `maximum` items, keeping the first
    /// item of every stride window. Order-preserving, so the result is reproducible, and
    /// the same rule for the points and for any per-point flags so they stay aligned.
    static func strided<Item>(_ items: [Item], to maximum: Int) -> [Item] {
        guard items.count > maximum, maximum > 0 else { return items }
        let stride = (items.count + maximum - 1) / maximum
        var result: [Item] = []
        result.reserveCapacity(maximum)
        var index = 0
        while index < items.count {
            result.append(items[index])
            index += stride
        }
        return result
    }
}

extension SymbolAlignment.Alignment {
    init(
        fromOrthogonal transform: SymbolAlignment.Orthogonal,
        scale: Double,
        tx: Double,
        ty: Double,
        residual: Double,
        isMirrored: Bool
    ) {
        self.init(
            r00: transform.r00, r01: transform.r01,
            r10: transform.r10, r11: transform.r11,
            scale: scale, tx: tx, ty: ty,
            residual: residual, isMirrored: isMirrored
        )
    }

    var determinant: Double { r00 * r11 - r01 * r10 }

    func applied(to point: CGPoint) -> CGPoint {
        CGPoint(
            x: scale * (r00 * point.x + r01 * point.y) + tx,
            y: scale * (r10 * point.x + r11 * point.y) + ty
        )
    }

    /// The inverse map, or `nil` when the scale is degenerate. The orthogonal part's
    /// inverse is its transpose; the transpose of a reflection is itself.
    func inverted() -> SymbolAlignment.Alignment? {
        guard scale.isFinite, scale > 1e-12 else { return nil }
        let inverseScale = 1 / scale
        // q = s·R·p + t  ⇒  p = (1/s)·Rᵀ·(q − t).
        let itx = -inverseScale * (r00 * tx + r10 * ty)
        let ity = -inverseScale * (r01 * tx + r11 * ty)
        return SymbolAlignment.Alignment(
            r00: r00, r01: r10, r10: r01, r11: r11,
            scale: inverseScale, tx: itx, ty: ity,
            residual: residual, isMirrored: isMirrored
        )
    }
}
