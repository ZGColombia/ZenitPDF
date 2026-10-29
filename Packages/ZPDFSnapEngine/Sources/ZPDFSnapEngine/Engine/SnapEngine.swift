import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry

/// The snap engine: one event in, one ``SnapResolution`` out.
///
/// A value type with explicit state, not an actor and not a class. The state is three fields —
/// the held candidate, the `Tab` cursor, and the signature the `Tab` cursor is valid for — and
/// making them a value means the whole engine can be copied, replayed, forked and compared,
/// which is what the determinism suite of `QUALITY_BAR` 3.4 does.
///
/// Nothing here reads a clock, a random number, a `Set`'s iteration order or an event count.
public struct SnapEngine: Sendable {

    // MARK: - Configuration

    public var limits: SnapIndexLimits

    /// Curve pairs one query may hand to the intersection solver
    /// (``SnapTargetGenerator/maximumIntersectionPairs``). Exposed so a test can drive the
    /// budget to its edge; the default is the generator's.
    public var intersectionPairBudget: Int = SnapTargetGenerator().maximumIntersectionPairs

    // MARK: - State

    /// The candidate hysteresis is currently holding (`SNAP_CONTRACT` 13.9).
    public private(set) var heldCandidate: SnapCandidateKey?

    /// Signed `Tab` position. Reset when the candidate set changes shape.
    public private(set) var cycleAdvance: Int

    /// Identity of the ranked candidate list the `Tab` position refers to. When the list
    /// changes, the position is meaningless and starts again at the top.
    public private(set) var cycleSignature: UInt64

    public var modifiers: SnapModifierMachine

    /// Keys reported through ``apply(_:)`` with ``SnapModifierInput/keysChanged(_:)``.
    ///
    /// The machine is rebuilt from the event's own modifiers on every resolve, so keys that a
    /// caller reported through the discrete input used to be forgotten one event later and the
    /// effect `apply` had just returned was a lie (BH-660). They are kept here and joined with
    /// the event's keys until the next `keysChanged` or `reset`.
    private var appliedKeys: SnapModifiers = .none

    /// The ranked identities the current `Tab` cycle walks, in the order they had when the
    /// cycle began. While the user cycles, the ranking is reordered to this so a sub-pixel
    /// move that swaps two equidistant candidates cannot move the cursor to another one
    /// (BH-215).
    private var cycleOrder: [SnapCandidateKey.Identity] = []
    /// Search buffers reused across resolves so the per-event index query allocates nothing
    /// once they have grown (IM-199). Never read across resolves: every query clears them.
    private var queryScratch = SnapQueryScratch()

    public init(
        limits: SnapIndexLimits = .standard,
        modifiers: SnapModifierMachine = SnapModifierMachine()
    ) {
        self.limits = limits
        self.heldCandidate = nil
        self.cycleAdvance = 0
        self.cycleSignature = 0
        self.modifiers = modifiers
    }

    /// Forgets the held candidate and the `Tab` position. Called when a gesture ends.
    public mutating func reset() {
        heldCandidate = nil
        cycleAdvance = 0
        cycleSignature = 0
        cycleOrder = []
        appliedKeys = .none
        modifiers.apply(.reset)
    }

    /// Feeds a discrete modifier input — a `Tab`, an `Option` tap, an `Escape`.
    @discardableResult
    public mutating func apply(_ input: SnapModifierInput) -> SnapModifierEffect {
        let effect = modifiers.apply(input)
        switch input {
        case .cycleForward: cycleAdvance &+= 1
        case .cycleBackward: cycleAdvance &-= 1
        case .optionTapped: cycleAdvance &+= 1
        case .reset:
            cycleAdvance = 0
            heldCandidate = nil
            appliedKeys = .none
        case .keysChanged(let keys):
            appliedKeys = keys
        }
        return effect
    }

    // MARK: - Resolve

    public mutating func resolve(
        _ query: SnapQuery,
        in index: SnapIndex
    ) throws -> SnapResolution {
        try query.weights.validate()
        let event = query.event
        let keys = event.modifiers.union(appliedKeys)
        modifiers = SnapModifierMachine(keys: keys, cycleAdvance: cycleAdvance)

        let tolerance = try SnapTolerance(settings: query.settings, layout: event.layout)
        let converter: PageCoordinateConverter
        do {
            converter = try PageCoordinateConverter(page: index.page, layout: event.layout)
        } catch let error as GeometryError {
            throw SnapEngineError.coordinateConversionFailed(String(describing: error))
        }

        let cursor: PDFPoint
        do {
            cursor = try converter.viewToPage(event.viewPoint)
        } catch {
            throw SnapEngineError.nonFiniteInput(field: "viewPoint")
        }

        let snapEnabled = modifiers.isSnapEnabled(configured: query.settings.isEnabled)
        let constrains = modifiers.constrainsAngle

        // `Option` bypasses the snap entirely, and `Command` can switch it off. Neither is an
        // error state and neither clears the held candidate: releasing the key must put the
        // user back where they were, not somewhere new.
        guard snapEnabled, !modifiers.isBypassing else {
            let resolved = constrains
                ? Self.constrainedPoint(
                    cursor: cursor,
                    anchor: event.anchorPagePoint,
                    incrementDegrees: query.settings.angleIncrementDegrees
                )
                : cursor
            return Self.emptyResolution(
                event: event,
                index: index,
                tolerance: tolerance,
                cursor: cursor,
                resolved: resolved
            )
        }

        // 1. Everything whose bounding box can reach the cursor, including the extra
        //    hysteresis band so a held candidate that has drifted past the plain radius is
        //    still found (`SNAP_CONTRACT` 13.9) — narrowed inside each layer's tree to what the
        //    truncation below can keep, so a 200-page-point radius at 5 % zoom does not copy
        //    tens of thousands of entries per pointer move (IM-009).
        var entries = queryScratch.entries
        queryScratch.entries = []
        index.nearestEntries(
            to: cursor,
            maxDistance: tolerance.heldRadiusPagePoints,
            limit: limits.maximumCandidatePrimitives,
            into: &entries,
            scratch: &queryScratch
        )
        defer { queryScratch.entries = entries }
        let generator = SnapTargetGenerator(
            limits: limits, maximumIntersectionPairs: intersectionPairBudget
        )
        let locals = generator.localPrimitives(
            entries, cursor: cursor, radius: tolerance.heldRadiusPagePoints
        )

        // 2. Derived targets, computed lazily inside the radius and nowhere else.
        var (targets, intersections) = generator.targets(
            from: locals,
            cursor: cursor,
            anchor: event.anchorPagePoint,
            radius: tolerance.heldRadiusPagePoints,
            enabledKinds: query.settings.enabledKinds,
            allowsVectorKinds: index.availability.allowsVectorCandidates
        )

        // 3. Synthetic targets: grid and angle increment, which have no primitives and keep
        //    working on a scanned page.
        if query.settings.enabledKinds.contains(.grid) {
            targets.append(
                contentsOf: SnapSyntheticTargets.grid(
                    cursor: cursor,
                    page: index.page,
                    spacing: query.settings.gridSpacingPoints,
                    radius: tolerance.heldRadiusPagePoints
                )
            )
        }
        if constrains,
           query.settings.enabledKinds.contains(.angleIncrement),
           let anchor = event.anchorPagePoint {
            targets.append(
                contentsOf: SnapSyntheticTargets.angleIncrement(
                    cursor: cursor,
                    anchor: anchor,
                    incrementDegrees: query.settings.angleIncrementDegrees,
                    radius: tolerance.heldRadiusPagePoints
                )
            )
        }

        // 4. Score.
        let scorer = SnapScorer(settings: query.settings, weights: query.weights)
        // `Tab` is an explicit override of the automatic choice, and hysteresis is the
        // automatic choice's stabiliser; letting both act at once would mean the held candidate
        // is promoted to the top of the ranking that `Tab` is stepping through, so `Tab` would
        // alternate between two candidates instead of walking all of them. While the user is
        // cycling, hysteresis stands down. It resumes the moment the cycle resets, which is the
        // moment the candidate list changes.
        let held = cycleAdvance == 0 ? heldCandidate : nil
        let margin = query.weights.clearlyBetterMargin(
            hysteresisViewPoints: tolerance.hysteresisViewPoints
        )

        var scored: [ScoredSnapCandidate] = []
        scored.reserveCapacity(targets.count)
        let heldIdentity = held?.identity
        for target in targets {
            let key = SnapCandidateKey(
                kind: target.kind,
                primitiveID: target.primitiveID,
                secondaryPrimitiveID: target.secondaryPrimitiveID,
                position: target.position,
                component: target.component,
                followsCursor: target.followsCursor
            )
            let distance = target.position.distance(to: cursor)
            // Matched on identity, not on the full key: a cursor-following target has a new
            // position at every event and must still be recognised as the held one (CR-38).
            let isHeld = key.identity == heldIdentity
            // A fresh candidate must be inside the plain tolerance. The held one is allowed the
            // extra hysteresis band, and only it.
            guard distance <= tolerance.radiusPagePoints
                || (isHeld && distance <= tolerance.heldRadiusPagePoints)
            else { continue }

            let satisfies: Bool
            if constrains, let anchor = event.anchorPagePoint {
                satisfies = SnapSyntheticTargets.satisfiesDirection(
                    target.position,
                    anchor: anchor,
                    incrementDegrees: query.settings.angleIncrementDegrees,
                    toleranceViewPoints: tolerance.radiusViewPoints,
                    zoom: tolerance.zoom
                )
            } else {
                satisfies = true
            }

            scored.append(
                scorer.score(
                    target,
                    cursorPagePoint: cursor,
                    tolerance: tolerance,
                    activeLayerID: event.activeLayerID,
                    satisfiesDirectionConstraint: satisfies,
                    heldCredit: isHeld ? -margin : 0
                )
            )
        }

        // 5. Rank, then apply hysteresis and `Tab`.
        var ranked = scorer.rank(scored, limit: limits.maximumRankedAlternatives + 1)

        let signature = Self.signature(of: ranked)
        if signature != cycleSignature {
            cycleSignature = signature
            cycleAdvance = 0
            modifiers = SnapModifierMachine(keys: keys, cycleAdvance: 0)
        }

        // While the user cycles, the list keeps the order the cycle began with: the signature
        // above is order-independent, so an unchanged set with a new order lands here, and
        // `Tab` position `n` keeps meaning the same candidate (BH-215).
        if cycleAdvance != 0, cycleOrder.count == ranked.count {
            var position: [SnapCandidateKey.Identity: Int] = [:]
            position.reserveCapacity(cycleOrder.count)
            for (offset, identity) in cycleOrder.enumerated() where position[identity] == nil {
                position[identity] = offset
            }
            let positions = ranked.map { position[$0.key.identity] }
            if !positions.contains(where: { $0 == nil }) {
                ranked = zip(positions, ranked)
                    .sorted { ($0.0 ?? 0) < ($1.0 ?? 0) }
                    .map(\.1)
            }
        }
        cycleOrder = ranked.map(\.key.identity)

        guard !ranked.isEmpty else {
            heldCandidate = nil
            let resolved = constrains
                ? Self.constrainedPoint(
                    cursor: cursor,
                    anchor: event.anchorPagePoint,
                    incrementDegrees: query.settings.angleIncrementDegrees
                )
                : cursor
            return Self.emptyResolution(
                event: event,
                index: index,
                tolerance: tolerance,
                cursor: cursor,
                resolved: resolved,
                intersections: intersections
            )
        }

        // `Tab` walks the ranked list. The modulo is written to stay non-negative for a
        // backwards cycle, so Shift-Tab from the top lands on the bottom rather than crashing
        // or clamping.
        let count = ranked.count
        let index0 = ((cycleAdvance % count) + count) % count
        var winnerScored = ranked[index0]

        // `isHeldByHysteresis` must mean "this candidate would have lost without the hysteresis
        // credit", not merely "this candidate also won last time". The UI renders the held state
        // differently and the stability suite reads the flag; a flag that is true on every event
        // after the first tells neither of them anything.
        if winnerScored.candidate.isHeldByHysteresis {
            var bestRival = Double.greatestFiniteMagnitude
            for other in ranked where other.key != winnerScored.key {
                bestRival = Swift.min(bestRival, other.rawScore)
            }
            // Held for either of the two reasons `SNAP_CONTRACT` 13.9 gives: the cursor has left
            // the plain tolerance and only the hysteresis band is keeping the candidate alive, or
            // a rival has a better raw score and only the margin is keeping it out.
            let beyondPlainTolerance =
                winnerScored.candidate.screenDistancePixels > tolerance.radiusViewPoints
            let genuinelyHeld = beyondPlainTolerance
                || winnerScored.rawScore > bestRival + query.weights.scoreEqualityEpsilon
            if !genuinelyHeld {
                winnerScored = ScoredSnapCandidate(
                    candidate: SnapCandidate(
                        kind: winnerScored.candidate.kind,
                        position: winnerScored.candidate.position,
                        primitiveID: winnerScored.candidate.primitiveID,
                        source: winnerScored.candidate.source,
                        screenDistancePixels: winnerScored.candidate.screenDistancePixels,
                        confidence: winnerScored.candidate.confidence,
                        isOnActiveLayer: winnerScored.candidate.isOnActiveLayer,
                        satisfiesDirectionConstraint:
                            winnerScored.candidate.satisfiesDirectionConstraint,
                        isHeldByHysteresis: false,
                        score: winnerScored.candidate.score
                    ),
                    key: winnerScored.key,
                    priority: winnerScored.priority,
                    rawScore: winnerScored.rawScore,
                    secondaryPrimitiveID: winnerScored.secondaryPrimitiveID,
                    guide: winnerScored.guide
                )
            }
        }

        heldCandidate = winnerScored.key

        // Only the winner can be held. A held candidate that a clearly better rival beat is
        // still in the list, and still scored with its credit, but nothing is holding it; the
        // flag said otherwise (BH-661).
        var alternatives: [SnapCandidate] = []
        alternatives.reserveCapacity(count - 1)
        for offset in 1..<Swift.max(1, count) {
            let candidate = ranked[(index0 + offset) % count].candidate
            alternatives.append(candidate.isHeldByHysteresis ? Self.released(candidate) : candidate)
        }

        let primary = Self.primitive(id: winnerScored.key.primitiveID, in: locals)
        let secondary = winnerScored.secondaryPrimitiveID.flatMap {
            Self.primitive(id: $0, in: locals)
        }

        let feedback = SnapFeedback(
            kind: winnerScored.candidate.kind,
            point: winnerScored.candidate.position,
            sourcePrimitive: primary,
            secondaryPrimitive: secondary,
            guide: winnerScored.guide,
            isHeldByHysteresis: winnerScored.candidate.isHeldByHysteresis
        )

        let decision = SnapDecision(
            sequence: event.sequence,
            kind: winnerScored.candidate.kind,
            primitiveID: winnerScored.key.primitiveID,
            secondaryPrimitiveID: winnerScored.key.secondaryPrimitiveID,
            score: winnerScored.candidate.score,
            point: winnerScored.candidate.position,
            candidateCount: count,
            isHeld: winnerScored.candidate.isHeldByHysteresis,
            availabilityKey: index.availability.messageKey,
            isIntersectionSearchTruncated: intersections.isTruncated
        )

        return SnapResolution(
            winner: winnerScored.candidate,
            alternatives: alternatives,
            feedback: feedback,
            availability: index.availability,
            rawPagePoint: cursor,
            resolvedPagePoint: winnerScored.candidate.position,
            tolerancePagePoints: tolerance.radiusPagePoints,
            hysteresisPagePoints: tolerance.hysteresisPagePoints,
            cycleIndex: index0,
            isHeldByHysteresis: winnerScored.candidate.isHeldByHysteresis,
            decision: decision,
            intersections: intersections,
            winnerKey: winnerScored.key
        )
    }

    // MARK: - Helpers

    /// A content hash of the ranked list's identities, so the `Tab` position can be invalidated
    /// when the list changes. FNV-1a, never `Hasher`: a per-process seed here would make the
    /// `Tab` sequence differ between runs.
    ///
    /// Built from ``SnapCandidateKey/identity``, which leaves the position of a
    /// cursor-following candidate out: hashing that position made every sub-pixel move a new
    /// list and reset the `Tab` cycle before the user could finish it (CR-50).
    ///
    /// It is a hash of the *set*, not of the sequence: each identity is hashed on its own, the
    /// per-item hashes are sorted, and the sorted list is hashed. Two equidistant candidates
    /// that swap places on a sub-pixel move are the same list to the user, and hashing them in
    /// ranked order reset the cycle under the very jitter of the hand that pressed `Tab`
    /// (BH-215). Sorting integers is a total order, so no `Hasher` seed can reach the result.
    private static func signature(of ranked: [ScoredSnapCandidate]) -> UInt64 {
        var items: [UInt64] = []
        items.reserveCapacity(ranked.count)
        for item in ranked {
            let identity = item.key.identity
            var hash = SnapFNV1a()
            hash.combine(UInt64(identity.kind.defaultPriority))
            hash.combine(identity.primitiveID)
            hash.combine(identity.secondaryPrimitiveID)
            hash.combine(identity.component)
            hash.combine(UInt64(bitPattern: identity.quantizedX))
            hash.combine(UInt64(bitPattern: identity.quantizedY))
            items.append(hash.value)
        }
        items.sort()
        var hash = SnapFNV1a()
        hash.combine(UInt64(items.count))
        for item in items { hash.combine(item) }
        return hash.value
    }

    /// `candidate` with the held flag cleared and nothing else changed.
    private static func released(_ candidate: SnapCandidate) -> SnapCandidate {
        SnapCandidate(
            kind: candidate.kind,
            position: candidate.position,
            primitiveID: candidate.primitiveID,
            source: candidate.source,
            screenDistancePixels: candidate.screenDistancePixels,
            confidence: candidate.confidence,
            isOnActiveLayer: candidate.isOnActiveLayer,
            satisfiesDirectionConstraint: candidate.satisfiesDirectionConstraint,
            isHeldByHysteresis: false,
            score: candidate.score
        )
    }

    private static func primitive(
        id: UInt64,
        in locals: [SnapTargetGenerator.LocalPrimitive]
    ) -> SnapPrimitive? {
        guard id != 0 else { return nil }
        for local in locals where local.entry.id == id { return local.entry.primitive }
        return nil
    }

    private static func constrainedPoint(
        cursor: PDFPoint,
        anchor: PDFPoint?,
        incrementDegrees: Double
    ) -> PDFPoint {
        guard let anchor,
              let constraint = SnapAngleConstraint(anchor: anchor, incrementDegrees: incrementDegrees),
              let projected = constraint.projection(of: cursor)
        else { return cursor }
        return projected
    }

    private static func emptyResolution(
        event: SnapPointerEvent,
        index: SnapIndex,
        tolerance: SnapTolerance,
        cursor: PDFPoint,
        resolved: PDFPoint,
        intersections: SnapIntersectionReport = .none
    ) -> SnapResolution {
        SnapResolution(
            winner: nil,
            alternatives: [],
            feedback: nil,
            availability: index.availability,
            rawPagePoint: cursor,
            resolvedPagePoint: resolved,
            tolerancePagePoints: tolerance.radiusPagePoints,
            hysteresisPagePoints: tolerance.hysteresisPagePoints,
            cycleIndex: 0,
            isHeldByHysteresis: false,
            decision: SnapDecision(
                sequence: event.sequence,
                kind: nil,
                primitiveID: 0,
                secondaryPrimitiveID: 0,
                score: 0,
                point: resolved,
                candidateCount: 0,
                isHeld: false,
                availabilityKey: index.availability.messageKey,
                isIntersectionSearchTruncated: intersections.isTruncated
            ),
            intersections: intersections,
            winnerKey: nil
        )
    }
}
