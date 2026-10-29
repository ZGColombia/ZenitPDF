import Foundation
import ZPDFContracts

/// The identity of a candidate, independent of its score.
///
/// Hysteresis holds a *candidate*, not a score, so it needs a key that survives the cursor
/// moving: the kind, the primitive it came from, the part of the primitive, and — for the
/// derived targets that are fixed points, such as the four quadrants of a circle — the
/// position, quantised so that a point recomputed from a different cursor position still
/// matches. A target that *moves with the cursor* keeps the position out of its identity; see
/// ``identity``.
public struct SnapCandidateKey: Sendable, Hashable, Codable {
    public let kind: SnapKind
    public let primitiveID: UInt64
    public let secondaryPrimitiveID: UInt64
    public let quantizedX: Int64
    public let quantizedY: Int64
    /// The part of the primitive the target came from (``SnapTarget/component``).
    public let component: Int
    /// `true` when the position is a function of the cursor (``SnapTarget/followsCursor``).
    public let followsCursor: Bool

    /// One micro-page-point. Far below any tolerance the engine works at, far above the drift
    /// a re-solve introduces.
    public static let quantum = 1e-6

    public init(
        kind: SnapKind,
        primitiveID: UInt64?,
        secondaryPrimitiveID: UInt64?,
        position: PDFPoint,
        component: Int = 0,
        followsCursor: Bool = false
    ) {
        self.kind = kind
        self.primitiveID = primitiveID ?? 0
        self.secondaryPrimitiveID = secondaryPrimitiveID ?? 0
        self.quantizedX = Self.quantize(position.x)
        self.quantizedY = Self.quantize(position.y)
        self.component = component
        self.followsCursor = followsCursor
    }

    /// The identity of the *point*, ignoring which primitive produced it.
    ///
    /// The same corner is reachable through the closed-subpath primitive and through each of the
    /// two segment primitives that meet there. To the user that is one snap target, so the
    /// ranked list keeps only the best-ranked of them and `Tab` visits it once.
    public var positional: PositionalKey {
        PositionalKey(kind: kind, quantizedX: quantizedX, quantizedY: quantizedY)
    }

    public struct PositionalKey: Sendable, Hashable, Codable {
        public let kind: SnapKind
        public let quantizedX: Int64
        public let quantizedY: Int64
    }

    /// What hysteresis holds and `Tab` cycles over.
    ///
    /// For a fixed target — an endpoint, a midpoint, an intersection — it is the kind, the
    /// primitives, the component and the quantised position. For a cursor-following target
    /// the position is left out: the nearest point on an edge is recomputed at every event, so
    /// an identity that included it never matched its own previous event, hysteresis never
    /// engaged, and a double-line wall flipped between its two lines on every pointer move
    /// (CR-38). The `Tab` signature is built from the same identities, so sub-pixel motion no
    /// longer resets the cycle either (CR-50).
    public var identity: Identity {
        Identity(
            kind: kind,
            primitiveID: primitiveID,
            secondaryPrimitiveID: secondaryPrimitiveID,
            component: component,
            quantizedX: followsCursor ? 0 : quantizedX,
            quantizedY: followsCursor ? 0 : quantizedY
        )
    }

    public struct Identity: Sendable, Hashable, Codable {
        public let kind: SnapKind
        public let primitiveID: UInt64
        public let secondaryPrimitiveID: UInt64
        public let component: Int
        public let quantizedX: Int64
        public let quantizedY: Int64
    }

    private static func quantize(_ value: Double) -> Int64 {
        let scaled = (value / quantum).rounded()
        guard scaled.isFinite,
              scaled >= Double(Int64.min),
              scaled <= Double(Int64.max) else { return 0 }
        return Int64(scaled)
    }
}

/// A candidate plus the parts of it the scorer and the total order need but `SnapCandidate`
/// does not carry.
public struct ScoredSnapCandidate: Sendable, Hashable {
    public let candidate: SnapCandidate
    public let key: SnapCandidateKey
    public let priority: Int
    /// The score before any hysteresis credit. Comparing raw scores is what "clearly better"
    /// means; comparing effective scores would let the held candidate defend itself twice.
    public let rawScore: Double
    public let secondaryPrimitiveID: UInt64?
    public let guide: SnapGuideGeometry
}

/// Applies `SNAP_CONTRACT` 13.7 and produces a total order.
///
/// `QUALITY_BAR` S1 requires the winner to be reproducible by a brute-force scorer and requires
/// ties to have exactly one legal winner, so the comparison is a **total order**, not a score
/// comparison with an arbitrary tie-break:
///
/// `(effective score on the epsilon grid, kind priority, primitive id, secondary primitive id,
/// kind raw value, x, y, component)`
///
/// Nothing in that tuple depends on hashing, on insertion order, or on the order the R-tree
/// happened to visit its nodes.
public struct SnapScorer: Sendable {

    public let settings: SnapSettings
    public let weights: SnapScoringWeights

    public init(settings: SnapSettings, weights: SnapScoringWeights) {
        self.settings = settings
        self.weights = weights
    }

    /// Scores one derived target.
    ///
    /// - Parameters:
    ///   - heldCredit: the hysteresis term. Negative for the held candidate, zero for everyone
    ///     else. It is the sixth term of 13.7 and the only one that depends on history.
    public func score(
        _ target: SnapTarget,
        cursorPagePoint: PDFPoint,
        tolerance: SnapTolerance,
        activeLayerID: String?,
        satisfiesDirectionConstraint: Bool,
        heldCredit: Double
    ) -> ScoredSnapCandidate {
        let pageDistance = target.position.distance(to: cursorPagePoint)
        let screenDistance = tolerance.viewPoints(fromPagePoints: pageDistance)
        let priority = settings.priority(of: target.kind)

        // An `activeLayerID` of nil means "no layer filtering in force", so nothing is
        // penalised. A candidate with no layer of its own is treated as being on the active
        // one: unlayered PDF content must not be second-class on a layered drawing.
        let isOnActiveLayer: Bool
        if let activeLayerID {
            isOnActiveLayer = target.layerID == nil || target.layerID == activeLayerID
        } else {
            isOnActiveLayer = true
        }

        let priorityTerm = Double(priority) * weights.typePriority
        let distanceTerm = screenDistance * weights.screenDistancePerViewPoint
        let confidenceTerm = Double(1 - target.confidence) * weights.lowConfidence
        let layerTerm = isOnActiveLayer ? 0 : weights.inactiveLayer
        let directionTerm = satisfiesDirectionConstraint ? 0 : weights.directionConstraintViolation

        let raw = priorityTerm + distanceTerm + confidenceTerm + layerTerm + directionTerm
        let effective = raw + heldCredit

        return ScoredSnapCandidate(
            candidate: SnapCandidate(
                kind: target.kind,
                position: target.position,
                primitiveID: target.primitiveID,
                source: target.source,
                screenDistancePixels: screenDistance,
                confidence: target.confidence,
                isOnActiveLayer: isOnActiveLayer,
                satisfiesDirectionConstraint: satisfiesDirectionConstraint,
                isHeldByHysteresis: heldCredit != 0,
                score: effective
            ),
            key: SnapCandidateKey(
                kind: target.kind,
                primitiveID: target.primitiveID,
                secondaryPrimitiveID: target.secondaryPrimitiveID,
                position: target.position,
                component: target.component,
                followsCursor: target.followsCursor
            ),
            priority: priority,
            rawScore: raw,
            secondaryPrimitiveID: target.secondaryPrimitiveID,
            guide: target.guide
        )
    }

    /// A score on the grid of ``SnapScoringWeights/scoreEqualityEpsilon``.
    ///
    /// Two scores in the same cell of the grid are equal and fall through to the later keys of
    /// the total order. Comparing with `|a - b| <= epsilon` was not transitive — `a ~ b` and
    /// `b ~ c` with `a < c` — so the comparator was not a strict weak ordering and `sort`
    /// could answer differently for different input orders, which is the R-tree's traversal
    /// order in practice (CR-45). The grid keeps the intent — two scores that differ only in
    /// the last bits of a square root compare equal — and is a function of the score alone.
    public func quantizedScore(_ score: Double) -> Double {
        guard weights.scoreEqualityEpsilon > 0 else { return score }
        let scaled = (score / weights.scoreEqualityEpsilon).rounded()
        return scaled.isFinite ? scaled : score
    }

    /// The total order of `QUALITY_BAR` S1. `true` when `a` outranks `b`.
    public func outranks(_ a: ScoredSnapCandidate, _ b: ScoredSnapCandidate) -> Bool {
        Self.precedes(a, quantizedScore(a.candidate.score), b, quantizedScore(b.candidate.score))
    }

    /// The one written-out S1 total order, on scores already put on the epsilon grid by
    /// ``quantizedScore(_:)``: `(score, priority, primitive id, secondary primitive id, kind raw
    /// value, x, y, component)`. ``outranks(_:_:)`` and ``rank(_:limit:)`` both call it, so the
    /// reference ordering and the production ranking cannot drift apart (S-113: each used to
    /// spell the eight keys out on its own).
    static func precedes(
        _ a: ScoredSnapCandidate,
        _ scoreA: Double,
        _ b: ScoredSnapCandidate,
        _ scoreB: Double
    ) -> Bool {
        if scoreA != scoreB { return scoreA < scoreB }
        if a.priority != b.priority { return a.priority < b.priority }
        if a.key.primitiveID != b.key.primitiveID { return a.key.primitiveID < b.key.primitiveID }
        if a.key.secondaryPrimitiveID != b.key.secondaryPrimitiveID {
            return a.key.secondaryPrimitiveID < b.key.secondaryPrimitiveID
        }
        if a.candidate.kind != b.candidate.kind {
            return a.candidate.kind.rawValue < b.candidate.kind.rawValue
        }
        if a.key.quantizedX != b.key.quantizedX { return a.key.quantizedX < b.key.quantizedX }
        if a.key.quantizedY != b.key.quantizedY { return a.key.quantizedY < b.key.quantizedY }
        return a.key.component < b.key.component
    }

    /// Ranks a candidate set and removes duplicates that resolved to the same key.
    ///
    /// Duplicates are real: the midpoint of a rectangle's edge is reachable both through the
    /// rectangle primitive and through the segment primitive of the same painted path. Keeping
    /// the better-ranked one is what stops `Tab` from visiting the same point twice.
    /// The first `limit` entries of ``rank(_:)``, without sorting the whole candidate set.
    ///
    /// The engine keeps `maximumRankedAlternatives + 1` candidates out of up to a couple of
    /// thousand at low zoom, and a full sort through ``outranks(_:_:)`` recomputed both
    /// quantised scores on every comparison (IM-198). Here each score is quantised once, the
    /// `k` best are selected with a bounded heap, sorted, and de-duplicated by position; if
    /// duplicates leave fewer than `limit`, `k` doubles and the selection is repeated. The
    /// de-duplication keeps the first of each position in the total order, and that is
    /// prefix-stable, so the result is exactly `rank(candidates).prefix(limit)`.
    public func rank(_ candidates: [ScoredSnapCandidate], limit: Int) -> [ScoredSnapCandidate] {
        guard limit > 0, !candidates.isEmpty else { return [] }
        let quantized = candidates.map { quantizedScore($0.candidate.score) }

        func precedes(_ i: Int, _ j: Int) -> Bool {
            Self.precedes(candidates[i], quantized[i], candidates[j], quantized[j])
        }

        var k = Swift.min(candidates.count, limit)
        while true {
            // A max-heap on `precedes`: heap[0] is the worst of the k kept.
            var heap: [Int] = []
            heap.reserveCapacity(k + 1)
            func siftUp(_ start: Int) {
                var child = start
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard precedes(heap[parent], heap[child]) else { return }
                    heap.swapAt(parent, child)
                    child = parent
                }
            }
            func siftDown(_ start: Int) {
                var parent = start
                while true {
                    let left = 2 * parent + 1
                    guard left < heap.count else { return }
                    var largest = precedes(heap[parent], heap[left]) ? left : parent
                    let right = left + 1
                    if right < heap.count, precedes(heap[largest], heap[right]) { largest = right }
                    if largest == parent { return }
                    heap.swapAt(parent, largest)
                    parent = largest
                }
            }
            for index in candidates.indices {
                if heap.count < k {
                    heap.append(index)
                    siftUp(heap.count - 1)
                } else if precedes(index, heap[0]) {
                    heap[0] = index
                    siftDown(0)
                }
            }
            heap.sort(by: precedes)

            var seen = Set<SnapCandidateKey.PositionalKey>(minimumCapacity: heap.count)
            var result: [ScoredSnapCandidate] = []
            result.reserveCapacity(Swift.min(limit, heap.count))
            for index in heap where seen.insert(candidates[index].key.positional).inserted {
                result.append(candidates[index])
                if result.count == limit { return result }
            }
            if k == candidates.count { return result }
            k = Swift.min(candidates.count, k * 2)
        }
    }

    public func rank(_ candidates: [ScoredSnapCandidate]) -> [ScoredSnapCandidate] {
        let sorted = candidates.sorted(by: outranks)
        var seen = Set<SnapCandidateKey.PositionalKey>(minimumCapacity: sorted.count)
        var result: [ScoredSnapCandidate] = []
        result.reserveCapacity(sorted.count)
        for candidate in sorted where seen.insert(candidate.key.positional).inserted {
            result.append(candidate)
        }
        return result
    }
}
