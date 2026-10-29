import CoreGraphics
import Foundation

/// Finds every instance of one confirmed exemplar on a page, and reports what it did
/// **not** confirm with the same care.
///
/// ## Match by example
///
/// This is not unsupervised recognition. The estimator clicks one placed instance and
/// says *"this is D-12"*; ``SymbolExemplar`` captures that instance; this type finds
/// everything on the page that matches it geometrically — the same door mirrored,
/// rotated or at another scale is one type — and states per candidate what it found,
/// what it skipped, and why.
///
/// ## The pipeline
///
/// 1. **Set page context aside.** A primitive longer than any in-band instance could
///    possibly be — grid lines, walls, dimension strings — is never candidate
///    material (``SymbolMatchOptions/contextExtentFactor``). On a real drawing those
///    cross everything; cluster them and the whole sheet welds into one page-sized
///    candidate, and not even the exemplar's own instance survives. That was LT-15,
///    live, on a real floor plan.
/// 2. **Cluster.** The remaining primitives are grouped into candidates by proximity:
///    two primitives belong to one candidate when their bounds sit within the link
///    tolerance, which is derived from the exemplar's own internal stroke gaps scaled by
///    the scale band. The grouping runs on a uniform spatial grid built the same way as
///    the query engine's — flat counting-sorted arrays, no hashing in the hot loop.
/// 3. **Filter.** Each cluster in ascending primitive-id order passes the cheap typed
///    gates first: whole shape inside the searched region, enough primitives, size
///    inside the scale band. A cluster over the band's ceiling gets one rescue before
///    it is rejected: members too large for any in-band instance — a leader or grid
///    stub the clustering dragged in — are set aside as context, at most the declared
///    candidate contamination share; if what remains sits inside the band, it is the
///    candidate. A cluster that still fails is a ``SymbolRejection`` with the gate
///    that failed and its unpruned measurements — never silently dropped.
/// 4. **Align and judge.** Survivors are aligned against the exemplar
///    (``SymbolAlignment``: coarse rotation/mirror search, then nearest-neighbour
///    Procrustes with reflection allowed, both trimmed by the declared contamination
///    share) and judged stroke by stroke, both ways, each side allowed to write off
///    its declared share of contaminating strokes. At or under the residual
///    threshold → confirmed with its transform, mirror flag, scale factor and
///    residual; over it → rejected with the residual and the threshold it missed.
/// 5. **Second look inside welded clusters** (L-72). A cluster rejected for being too
///    large, for crossing the region's edge or on residual is clustered again one octave
///    of the scale band at a time, each octave with its own link tolerance and member
///    size; every sub-cluster in the band is judged, and one that fails only for detached
///    pieces the alignment could not place is judged again without them. The boxed
///    instance is confirmed by definition wherever it was welded. What is confirmed leaves
///    the parent's rejection; a parent that yields nothing is reported unchanged.
/// 6. **One place, one instance** (L-72 re-fix). Two confirmed instances whose positions lie
///    within ``duplicateRadiusFactor`` × the exemplar's RMS radius of each other are one
///    symbol seen twice — a frame inside a frame, each shaped enough like the boxed one to
///    pass on its own — and are reported once: the example itself first, then the instance
///    whose scale is nearest 1, then the lower residual. The other's strokes join it, so
///    nothing is dropped and nothing is counted twice.
///
/// The cluster whose primitives are exactly the exemplar's own is confirmed with the
/// identity transform without being re-aligned — it *is* the example, not a match. A
/// confirmed cluster that *contains* every exemplar primitive — the clicked instance
/// plus what clustering dragged in — also carries ``SymbolInstance/isExemplar``.
///
/// ## Determinism
///
/// Same input, same report: clusters are formed by connectivity (order-free), walked in
/// ascending primitive-id order, ties in every search are broken by index, and nothing
/// reads the clock or a random source.
public struct SymbolMatcher: Sendable {

    public init() {}

    /// Runs the match.
    ///
    /// - Parameters:
    ///   - exemplar: the confirmed example.
    ///   - primitives: the page's extraction — the same collection the exemplar was
    ///     built from, or another page's.
    ///   - region: where to search. `nil` searches the union of the page's primitive
    ///     bounds. A candidate that crosses the region's edge is rejected as
    ///     ``SymbolRejectionReason/partialOverlap``, never half-judged.
    ///   - options: thresholds and caps. Every cap that fires is reported through
    ///     ``SymbolMatchReport/wasTruncated``.
    /// - Throws: ``VectorExtractionError/invalidOption(name:reason:)`` for a nonsense
    ///   configuration. A page with nothing on it is not an error — it is a report with
    ///   zero candidates.
    public func matches(
        exemplar: SymbolExemplar,
        in primitives: [VectorPrimitive],
        region: VectorBounds? = nil,
        options: SymbolMatchOptions = .standard
    ) throws -> SymbolMatchReport {
        try options.validate()

        // The searched region: as given, or the page's own extent.
        let gate = options.styleGate
        let usable = primitives
            .filter(SymbolFeatureExtraction.isUsable)
            // "The same style" (NL-AUTO-13): primitives of another style are not candidates at
            // all, which also keeps a red door from welding onto the grey one beside it.
            .filter { gate.isEmpty || exemplar.style.admits($0, gate: gate) }
            .sorted { $0.id < $1.id }
        let searchedRegion: VectorBounds
        if let region {
            searchedRegion = region
        } else if let first = usable.first {
            var union = first.bounds
            for primitive in usable.dropFirst() { union = union.union(primitive.bounds) }
            searchedRegion = union
        } else {
            searchedRegion = exemplar.region
        }

        // Only primitives that touch the region take part at all — and of those, only
        // the ones short enough to be part of some in-band instance. A grid line or a
        // wall is page context: it crosses everything, and clustering it welds the
        // sheet into one candidate.
        let exemplarDiagonal = (
            exemplar.bounds.width * exemplar.bounds.width
                + exemplar.bounds.height * exemplar.bounds.height
        ).squareRoot()
        let contextLimit = exemplarDiagonal * options.scaleBand.upperBound
            * options.contextExtentFactor
        let participants = usable.filter { primitive in
            guard primitive.bounds.intersects(searchedRegion) else { return false }
            guard contextLimit.isFinite else { return true }
            return Swift.max(primitive.bounds.width, primitive.bounds.height) <= contextLimit
        }
        guard !participants.isEmpty else {
            return SymbolMatchReport(
                confirmed: [],
                rejected: [],
                searchedRegion: searchedRegion,
                candidateCount: 0,
                wasTruncated: false,
                residualThreshold: options.residualThreshold
            )
        }

        // No member of an in-band instance can outsize the instance itself: the hard
        // ceiling for a single member is the exemplar's diagonal at the band's top,
        // plus rounding slop. Anything above it that clustering drags in is context.
        let memberExtentLimit = exemplarDiagonal * options.scaleBand.upperBound * 1.05

        let linkTolerance = Swift.max(
            exemplar.internalGap * options.scaleBand.upperBound * options.linkToleranceFactor,
            options.minimumLinkTolerance
        )
        var clusters = Self.clusters(of: participants, linkTolerance: linkTolerance)

        var wasTruncated = false
        let candidateCount = clusters.count
        if clusters.count > options.maximumCandidates {
            clusters.removeSubrange(options.maximumCandidates...)
            wasTruncated = true
        }

        // `Int(_:)` of a `Double` past `Int.max` traps, and `validate()` cannot know the
        // exemplar's count; a mistyped ratio is refused here by name instead (BH-870).
        let rawRequired = (Double(exemplar.primitiveIDs.count) * options.minimumPrimitiveCountRatio).rounded(.up)
        guard rawRequired.isFinite, rawRequired < Double(Int.max / 2) else {
            throw VectorExtractionError.invalidOption(
                name: "minimumPrimitiveCountRatio",
                reason: "\(options.minimumPrimitiveCountRatio) × \(exemplar.primitiveIDs.count) exemplar "
                    + "primitives is not a usable count"
            )
        }
        let requiredPrimitives = Swift.max(options.minimumCandidatePrimitives, Int(rawRequired))
        let exemplarIDs = Set(exemplar.primitiveIDs)
        let exemplarDroppable = Self.droppableStrokes(of: exemplar)
        let exemplarDroppablePoints = zip(exemplarDroppable, exemplar.featurePointCounts).flatMap {
            [Bool](repeating: $0, count: Swift.max($1, 0))
        }
        let exemplarDropCount = Int(
            Double(exemplar.primitiveIDs.count) * options.exemplarContaminationTolerance
        )
        // Strokes a confirmed candidate wrote off are re-examined as a candidate of their
        // own only when there are enough of them to be an instance: a full exemplar less
        // its own contamination share, never fewer than the ordinary candidate floor.
        let reexaminationFloor = Swift.max(
            requiredPrimitives, exemplar.primitiveIDs.count - exemplarDropCount
        )

        var confirmed: [SymbolInstance] = []
        var rejected: [SymbolRejection] = []
        var verificationsUsed = 0
        var capReached = false
        // Rejected clusters that are bigger than one instance and so may hold some (L-72):
        // the rejection's place in `rejected`, and the cluster as clustering formed it.
        var welded: [(rejectionIndex: Int, members: [VectorPrimitive])] = []

        // A worklist rather than a plain loop: a confirmed candidate can leave behind the
        // strokes of a second instance that clustering welded to it (BH-334), and those
        // are appended for examination. Every appended cluster is a strict subset of the
        // one it came from, so the list is finite.
        var work = clusters
        var cursor = 0
        while cursor < work.count {
            let cluster = work[cursor]
            cursor += 1
            // Strokes a confirmed candidate left over are already listed in that candidate;
            // only clusters the page itself formed get the second look below.
            let isPageCluster = cursor <= clusters.count
            let ids = cluster.map(\.id)
            var bounds = cluster[0].bounds
            for member in cluster.dropFirst() { bounds = bounds.union(member.bounds) }
            let points = cluster.flatMap(SymbolFeatureExtraction.featurePoints)
            let cloud = SymbolPointCloud(points: points)
            let position = cloud?.centroid ?? bounds.center

            func reject(_ reason: SymbolRejectionReason) {
                rejected.append(SymbolRejection(
                    primitiveIDs: ids, position: position, bounds: bounds, reason: reason
                ))
            }

            // The exemplar's own cluster: it is the example, confirmed by definition —
            // when it *is* the example. Identifiers restart on every page, so ids alone
            // would confirm whatever another page keeps under the same numbers, at the
            // wrong page's coordinates (BH-332); the geometry must agree too.
            if Set(ids) == exemplarIDs, points == exemplar.featurePoints {
                confirmed.append(SymbolInstance(
                    primitiveIDs: ids,
                    position: exemplar.centroid,
                    bounds: bounds,
                    transform: .identity,
                    isMirrored: false,
                    scaleFactor: 1,
                    residual: 0,
                    isExemplar: true
                ))
                continue
            }

            // Past the verification cap nothing else is examined — the by-definition
            // check above still runs, so the clicked instance is never the one lost to
            // the cap because its ids happened to sort late (BH-871). Candidates never
            // reached are not painted as rejections; `wasTruncated` says so.
            if capReached { continue }

            // Cheap typed gates, in a fixed order so the reported reason is stable.
            guard cluster.allSatisfy({ searchedRegion.contains($0.bounds) }) else {
                reject(.partialOverlap)
                if isPageCluster { welded.append((rejectionIndex: rejected.count - 1, members: cluster)) }
                continue
            }
            guard cluster.count >= requiredPrimitives else {
                reject(.tooFewPrimitives(found: cluster.count, required: requiredPrimitives))
                continue
            }
            guard let cloud else {
                // Every feature point coincides: no size, which no instance of a real
                // symbol has. Scale zero states that measurably.
                reject(.scaleOutsideBand(scale: 0, band: options.scaleBand))
                continue
            }
            let scale = cloud.rmsRadius / exemplar.rmsRadius

            // A cluster over the band's ceiling gets one rescue before it is rejected:
            // members too large for any in-band instance — a leader or a grid stub the
            // clustering dragged in — are set aside as context, within the declared
            // contamination share. If what remains sits inside the band, *that* is the
            // candidate; if not, the rejection below reports the unpruned truth.
            var members = cluster
            var activeCloud = cloud
            var activeScale = scale
            if scale > options.scaleBand.upperBound {
                let allowance = Int(
                    Double(cluster.count) * options.candidateContaminationTolerance
                )
                let kept = cluster.filter {
                    Swift.max($0.bounds.width, $0.bounds.height) <= memberExtentLimit
                }
                let oversizedCount = cluster.count - kept.count
                if oversizedCount > 0, oversizedCount <= allowance,
                   kept.count >= requiredPrimitives,
                   let keptCloud = SymbolPointCloud(
                       points: kept.flatMap(SymbolFeatureExtraction.featurePoints)
                   ) {
                    let keptScale = keptCloud.rmsRadius / exemplar.rmsRadius
                    if options.scaleBand.contains(keptScale) {
                        members = kept
                        activeCloud = keptCloud
                        activeScale = keptScale
                    }
                }
            }
            guard options.scaleBand.contains(activeScale) else {
                reject(.scaleOutsideBand(scale: scale, band: options.scaleBand))
                // Only a cluster too *large* for the band can hold an instance inside it.
                if scale > options.scaleBand.upperBound, isPageCluster {
                    welded.append((rejectionIndex: rejected.count - 1, members: cluster))
                }
                continue
            }

            // The expensive step is capped; hitting the cap is declared, never silent.
            guard verificationsUsed < options.maximumVerifications else {
                wasTruncated = true
                capReached = true
                continue
            }
            verificationsUsed += 1

            let (alignment, judgement) = Self.verify(
                members: members, cloud: activeCloud, exemplar: exemplar, options: options,
                exemplarDroppable: exemplarDroppable, exemplarDroppablePoints: exemplarDroppablePoints,
                exemplarDropCount: exemplarDropCount
            )
            guard alignment.residual <= options.residualThreshold else {
                reject(.residualTooHigh(
                    residual: alignment.residual, threshold: options.residualThreshold
                ))
                if isPageCluster { welded.append((rejectionIndex: rejected.count - 1, members: cluster)) }
                continue
            }

            let memberIDs = members.map(\.id)
            var memberBounds = members[0].bounds
            for member in members.dropFirst() {
                memberBounds = memberBounds.union(member.bounds)
            }
            let instance = Self.instance(
                ids: memberIDs,
                bounds: memberBounds,
                exemplar: exemplar,
                candidate: activeCloud,
                alignment: alignment,
                isExemplar: Self.exemplarGeometryIsPresent(in: members, exemplar: exemplar)
            )
            // The band was gated on the raw RMS ratio, which is what the cheap gate can
            // measure; the instance reports the solved linear scale, which the Procrustes
            // correction can carry past the band's edge. The band is closed, so the
            // reported scale must be inside it too (BH-872).
            guard options.scaleBand.contains(instance.scaleFactor) else {
                reject(.scaleOutsideBand(scale: instance.scaleFactor, band: options.scaleBand))
                if isPageCluster { welded.append((rejectionIndex: rejected.count - 1, members: cluster)) }
                continue
            }
            confirmed.append(instance)

            // What this candidate wrote off may be another instance welded to it by
            // clustering — a double door's second leaf (BH-334). Enough of it to be an
            // instance is examined on its own, after the clusters the page produced.
            let leftover = judgement.unmatchedCandidateStrokes.map { members[$0] }
            if leftover.count >= reexaminationFloor, leftover.count < members.count {
                work.append(leftover)
            }
        }

        // Second look inside every rejected cluster that is bigger than one instance (L-72).
        // On a real drawing the link tolerance — the exemplar's own stroke gaps at the top of
        // the scale band — reaches from one drawn thing to the next, and the whole sheet welds
        // into one page-sized candidate: a box round one "TH" symbol on a real roof plan gave
        // one cluster of nearly every stroke on the sheet at over 13× the symbol, and nothing on
        // the page, not even the boxed instance, was confirmed. The same strokes are clustered again one
        // octave of the band at a time, finest first, each octave with the link tolerance and
        // member size of its own scale, and every sub-cluster in the band is judged. What is
        // confirmed is claimed and leaves the parent's rejection; a parent that yields nothing
        // is reported exactly as before.
        var removedRejections = Set<Int>()
        for parent in welded {
            guard !removedRejections.contains(parent.rejectionIndex) else { continue }
            var found: [SymbolInstance] = []
            var claimed = Set<UInt64>()
            // The boxed instance is the example: wherever clustering welded it, its own
            // strokes are confirmed by definition (BH-332's geometry check still applies).
            let own = parent.members.filter { exemplarIDs.contains($0.id) }
            if Self.exemplarGeometryIsPresent(in: parent.members, exemplar: exemplar),
               own.allSatisfy({ searchedRegion.contains($0.bounds) }) {
                var ownBounds = own[0].bounds
                for member in own.dropFirst() { ownBounds = ownBounds.union(member.bounds) }
                found.append(SymbolInstance(
                    primitiveIDs: exemplar.primitiveIDs, position: exemplar.centroid, bounds: ownBounds,
                    transform: .identity, isMirrored: false, scaleFactor: 1, residual: 0, isExemplar: true
                ))
                claimed.formUnion(exemplarIDs)
            }
            var examined: Set<[UInt64]> = [parent.members.map(\.id)]
            octaves: for octave in Self.octaves(of: options.scaleBand) {
                let memberLimit = exemplarDiagonal * octave.upperBound * 1.05
                let pool = parent.members.filter {
                    !claimed.contains($0.id) && Swift.max($0.bounds.width, $0.bounds.height) <= memberLimit
                }
                guard pool.count >= requiredPrimitives else { continue }
                let octaveLink = Swift.max(
                    exemplar.internalGap * octave.upperBound * options.linkToleranceFactor,
                    options.minimumLinkTolerance
                )
                for sub in Self.clusters(of: pool, linkTolerance: octaveLink) {
                    guard !sub.contains(where: { claimed.contains($0.id) }) else { continue }
                    // A sub-cluster is judged as it stands, then — when it fails only for
                    // detached pieces the alignment could not place, such as a post marker
                    // drawn beside a symbol copy — once or twice more without them.
                    var candidate = sub
                    for round in 0...Self.peelRounds {
                        let ids = candidate.map(\.id)
                        guard candidate.count >= requiredPrimitives,
                              candidate.count <= exemplar.primitiveIDs.count * Self.secondLookStrokeFactor,
                              examined.insert(ids).inserted,
                              candidate.allSatisfy({ searchedRegion.contains($0.bounds) }),
                              let cloud = SymbolPointCloud(points: candidate.flatMap(SymbolFeatureExtraction.featurePoints)),
                              options.scaleBand.contains(cloud.rmsRadius / exemplar.rmsRadius)
                        else { break }
                        guard verificationsUsed < options.maximumVerifications else {
                            wasTruncated = true
                            break octaves
                        }
                        verificationsUsed += 1
                        let (alignment, judgement) = Self.verify(
                            members: candidate, cloud: cloud, exemplar: exemplar, options: options,
                            exemplarDroppable: exemplarDroppable, exemplarDroppablePoints: exemplarDroppablePoints,
                            exemplarDropCount: exemplarDropCount
                        )
                        if alignment.residual <= options.residualThreshold {
                            var candidateBounds = candidate[0].bounds
                            for member in candidate.dropFirst() { candidateBounds = candidateBounds.union(member.bounds) }
                            let instance = Self.instance(
                                ids: ids, bounds: candidateBounds, exemplar: exemplar, candidate: cloud, alignment: alignment
                            )
                            if options.scaleBand.contains(instance.scaleFactor) {
                                found.append(instance)
                                claimed.formUnion(ids)
                            }
                            break
                        }
                        guard round < Self.peelRounds,
                              let peeled = Self.peeled(candidate, unmatched: judgement.unmatchedCandidateStrokes, options: options)
                        else { break }
                        candidate = peeled
                    }
                }
            }
            guard !found.isEmpty else { continue }
            confirmed += found
            // The parent keeps what nothing confirmed, measured as it was measured.
            let old = rejected[parent.rejectionIndex]
            let rest = parent.members.filter { !claimed.contains($0.id) }
            if rest.isEmpty {
                removedRejections.insert(parent.rejectionIndex)
            } else {
                var restBounds = rest[0].bounds
                for member in rest.dropFirst() { restBounds = restBounds.union(member.bounds) }
                rejected[parent.rejectionIndex] = SymbolRejection(
                    primitiveIDs: rest.map(\.id),
                    position: SymbolPointCloud(points: rest.flatMap(SymbolFeatureExtraction.featurePoints))?.centroid ?? restBounds.center,
                    bounds: restBounds,
                    reason: old.reason
                )
            }
        }
        if !removedRejections.isEmpty {
            rejected = rejected.enumerated().filter { !removedRejections.contains($0.offset) }.map(\.element)
        }

        // One place, one instance (L-72 re-fix), whichever pass confirmed the two.
        confirmed = Self.onePerPlace(confirmed, radius: exemplar.rmsRadius * Self.duplicateRadiusFactor)

        confirmed.sort { ($0.primitiveIDs.first ?? 0) < ($1.primitiveIDs.first ?? 0) }
        rejected.sort { ($0.primitiveIDs.first ?? 0) < ($1.primitiveIDs.first ?? 0) }
        return SymbolMatchReport(
            confirmed: confirmed,
            rejected: rejected,
            searchedRegion: searchedRegion,
            candidateCount: candidateCount,
            wasTruncated: wasTruncated,
            residualThreshold: options.residualThreshold
        )
    }

    // MARK: - Verification

    /// Aligns one candidate against the exemplar and judges it stroke by stroke; the returned
    /// alignment carries the judged residual. One implementation for the first pass and the
    /// second look inside welded clusters (L-72).
    static func verify(
        members: [VectorPrimitive],
        cloud: SymbolPointCloud,
        exemplar: SymbolExemplar,
        options: SymbolMatchOptions,
        exemplarDroppable: [Bool],
        exemplarDroppablePoints: [Bool],
        exemplarDropCount: Int
    ) -> (alignment: SymbolAlignment.Alignment, judgement: SymbolAlignment.Judgement) {
        let candidateCounts = members.map { SymbolFeatureExtraction.featurePoints(of: $0).count }
        var alignment = SymbolAlignment.align(
            exemplar: exemplar.normalizedPoints,
            candidate: cloud.normalizedPoints,
            rotationSteps: options.coarseRotationSteps,
            refinementIterations: options.refinementIterations,
            maximumPoints: options.maximumFeaturePoints,
            trimShare: options.exemplarContaminationTolerance,
            droppable: exemplarDroppablePoints,
            exemplarCounts: exemplar.featurePointCounts,
            candidateCounts: candidateCounts
        )
        let judgement = SymbolAlignment.judge(
            exemplarPoints: exemplar.normalizedPoints,
            exemplarCounts: exemplar.featurePointCounts,
            exemplarDroppable: exemplarDroppable,
            candidatePoints: cloud.normalizedPoints,
            candidateCounts: candidateCounts,
            alignment: alignment,
            exemplarDropCount: exemplarDropCount,
            candidateDropCount: Int(Double(members.count) * options.candidateContaminationTolerance),
            threshold: options.residualThreshold
        )
        alignment.residual = judgement.residual
        return (alignment, judgement)
    }

    /// How many times a failed sub-cluster is judged again without the detached pieces its
    /// alignment could not place (L-72).
    static let peelRounds = 2

    /// The most strokes a sub-cluster of the second look may have, as a multiple of the
    /// exemplar's (L-72). The judge may excuse at most half a candidate's strokes, so one four
    /// times the symbol's size would need twice the symbol's strokes lying on the symbol;
    /// such sub-clusters are hatching and dense linework, the same strokes a finer octave
    /// already cut into the pieces it judged. Measured on a real roof plan (debug build), they
    /// were about a third of the sub-clusters in the band, up to some forty times the exemplar's
    /// strokes, and nearly all of the second look's time; none held an instance.
    static let secondLookStrokeFactor = 4

    /// `candidate` without the pieces — runs of touching strokes — of which every stroke was
    /// written off as unmatched, ascending by id; `nil` when that removes nothing or
    /// everything. A piece that holds even one matched stroke stays: only whole detached
    /// things are peeled, so a stroke joined to the symbol (the diagonal of BH-333) can never
    /// be peeled away to make a decoy pass.
    static func peeled(
        _ candidate: [VectorPrimitive],
        unmatched: [Int],
        options: SymbolMatchOptions
    ) -> [VectorPrimitive]? {
        guard !unmatched.isEmpty else { return nil }
        let unmatchedIDs = Set(unmatched.compactMap { candidate.indices.contains($0) ? candidate[$0].id : nil })
        let pieces = clusters(of: candidate, linkTolerance: options.minimumLinkTolerance)
        guard pieces.count > 1 else { return nil }
        let kept = pieces
            .filter { !$0.allSatisfy { unmatchedIDs.contains($0.id) } }
            .flatMap { $0 }
            .sorted { $0.id < $1.id }
        guard !kept.isEmpty, kept.count < candidate.count else { return nil }
        return kept
    }

    /// The scale band cut into octaves, finest first: `0.25…4` is `0.25…0.5`, `0.5…1`, `1…2`,
    /// `2…4`. Each octave clusters with its own link tolerance and member size (L-72); the
    /// lowest octave is cut short at the band's floor. A sub-cluster two octaves both form is
    /// judged once.
    static func octaves(of band: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var upper = band.upperBound
        while upper > band.lowerBound, result.count < 32 {
            let lower = Swift.max(band.lowerBound, upper / 2)
            result.append(lower...upper)
            upper = lower
        }
        if result.isEmpty { result = [band] }
        return result.reversed()
    }

    // MARK: - One place, one instance

    /// Two confirmed positions within this multiple of the exemplar's RMS radius are one place
    /// (L-72 re-fix). The same ratio a symbol review uses to treat a confirmed position as a count
    /// point already on the page, and to mint positions accepted twice only once, so the number a
    /// review offers to add is the number of counts that land.
    public static let duplicateRadiusFactor = 0.5

    /// `instances` with every group that sits at one place reported once.
    ///
    /// On a real roof plan a box round the inner frame of a "TH" symbol confirmed each symbol
    /// twice: the inner frame at scale 1, and the outer frame round it — a rectangle of a slightly
    /// different shape, a fraction of a point off centre — at about 1.3× with a residual under the
    /// 0.08 threshold. The review read "6 confirmed" and offered six counts; landing merged them
    /// to three. (The Synthetic Roof Plan's symbols, whose outer frame is the inner one at exactly
    /// 1.25×, reproduce it in `L8SymbolMatchRoofPlanTests`.)
    ///
    /// The instances are taken in priority order — the example itself, then the scale nearest 1
    /// (by `|log scale|`, so ×2 and ×½ weigh alike), then the lower residual, then the lower first
    /// primitive id — and each joins the nearest instance already kept within `radius`, or is kept.
    /// A joined instance gives the one it joins its strokes (ascending, bounds grown to hold them);
    /// position, transform, scale and residual stay the kept instance's own. Deterministic: the
    /// order is total and nothing depends on input order.
    static func onePerPlace(_ instances: [SymbolInstance], radius: Double) -> [SymbolInstance] {
        guard instances.count > 1, radius.isFinite, radius >= 0 else { return instances }
        func scaleDistance(_ instance: SymbolInstance) -> Double {
            abs(Foundation.log(Swift.max(instance.scaleFactor, .leastNormalMagnitude)))
        }
        let order = instances.indices.sorted { first, second in
            let a = instances[first], b = instances[second]
            if a.isExemplar != b.isExemplar { return a.isExemplar }
            let (da, db) = (scaleDistance(a), scaleDistance(b))
            if da != db { return da < db }
            if a.residual != b.residual { return a.residual < b.residual }
            return (a.primitiveIDs.first ?? 0, first) < (b.primitiveIDs.first ?? 0, second)
        }
        var kept: [(instance: SymbolInstance, ids: Set<UInt64>, bounds: VectorBounds)] = []
        for index in order {
            let instance = instances[index]
            let host = kept.indices
                .map { ($0, hypot(kept[$0].instance.position.x - instance.position.x,
                                  kept[$0].instance.position.y - instance.position.y)) }
                .filter { $0.1 <= radius }
                .min { $0.1 < $1.1 }?.0
            if let host {
                kept[host].ids.formUnion(instance.primitiveIDs)
                kept[host].bounds = kept[host].bounds.union(instance.bounds)
            } else {
                kept.append((instance, Set(instance.primitiveIDs), instance.bounds))
            }
        }
        guard kept.count < instances.count else { return instances }
        return kept.map { entry in
            let own = entry.instance
            guard entry.ids.count > own.primitiveIDs.count else { return own }
            return SymbolInstance(
                primitiveIDs: entry.ids.sorted(), position: own.position, bounds: entry.bounds,
                transform: own.transform, isMirrored: own.isMirrored, scaleFactor: own.scaleFactor,
                residual: own.residual, isExemplar: own.isExemplar
            )
        }
    }

    // MARK: - Confirmed instance assembly

    /// Which exemplar strokes may be written off as contamination: those with a free
    /// end — an endpoint that coincides with no other exemplar stroke's endpoint, to
    /// within one per cent of the exemplar's RMS radius. A dash, a tick or a leader
    /// fragment caught in the crop ends where the symbol's own strokes do not; a stroke
    /// drawn corner to corner is structure and can never be excused (BH-333).
    static func droppableStrokes(of exemplar: SymbolExemplar) -> [Bool] {
        let points = exemplar.featurePoints
        var ranges: [Range<Int>] = []
        var start = 0
        for count in exemplar.featurePointCounts {
            ranges.append(start..<(start + Swift.max(count, 0)))
            start += Swift.max(count, 0)
        }
        func endpoints(_ range: Range<Int>) -> [CGPoint] {
            guard !range.isEmpty, range.upperBound <= points.count else { return [] }
            return [points[range.lowerBound], points[range.upperBound - 1]]
        }
        let tolerance = Swift.max(exemplar.rmsRadius * 0.01, 1e-9)
        return ranges.indices.map { index in
            let mine = endpoints(ranges[index])
            guard !mine.isEmpty else { return true }
            return mine.contains { point in
                !ranges.indices.contains { other in
                    other != index && endpoints(ranges[other]).contains { end in
                        hypot(end.x - point.x, end.y - point.y) <= tolerance
                    }
                }
            }
        }
    }

    /// `true` when every exemplar primitive is among `members` with its geometry
    /// unchanged: the clicked instance plus what clustering dragged in, as opposed to a
    /// cluster that merely reuses the exemplar's identifiers (BH-332).
    static func exemplarGeometryIsPresent(in members: [VectorPrimitive], exemplar: SymbolExemplar) -> Bool {
        var start = 0
        for (id, count) in zip(exemplar.primitiveIDs, exemplar.featurePointCounts) {
            defer { start += count }
            guard let member = members.first(where: { $0.id == id }) else { return false }
            let expected = Array(exemplar.featurePoints[start..<(start + count)])
            guard SymbolFeatureExtraction.featurePoints(of: member) == expected else { return false }
        }
        return true
    }

    /// Composes the page-space transform from the normalised-space alignment.
    ///
    /// Normalisation maps an exemplar page point `p` to `(p − ē)/rē`; the alignment maps
    /// that to `s·R·n + t`; de-normalisation maps into the instance as `c̄ + rc·q`. The
    /// composition is a single similarity transform whose linear part is
    /// `(rc·s/rē)·R` — its scale is the reported scale factor, and the sign of its
    /// determinant is the mirror flag.
    ///
    /// The instance's position is the exemplar's centroid carried through that
    /// transform — where the symbol's own strokes put it — and not the centroid of the
    /// cluster's feature points, which a contaminating wall stub written off by the
    /// candidate share pulled off the symbol and onto the wall (BH-335).
    static func instance(
        ids: [UInt64],
        bounds: VectorBounds,
        exemplar: SymbolExemplar,
        candidate: SymbolPointCloud,
        alignment: SymbolAlignment.Alignment,
        isExemplar: Bool = false
    ) -> SymbolInstance {
        let linearScale = candidate.rmsRadius * alignment.scale / exemplar.rmsRadius
        let a = linearScale * alignment.r00
        let c = linearScale * alignment.r01
        let b = linearScale * alignment.r10
        let d = linearScale * alignment.r11
        let tx = candidate.centroid.x + candidate.rmsRadius * alignment.tx
            - (a * exemplar.centroid.x + c * exemplar.centroid.y)
        let ty = candidate.centroid.y + candidate.rmsRadius * alignment.ty
            - (b * exemplar.centroid.x + d * exemplar.centroid.y)
        let transform = SymbolTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
        return SymbolInstance(
            primitiveIDs: ids,
            position: transform.apply(exemplar.centroid),
            bounds: bounds,
            transform: transform,
            isMirrored: alignment.isMirrored,
            scaleFactor: linearScale,
            residual: alignment.residual,
            isExemplar: isExemplar
        )
    }

    // MARK: - Clustering

    /// Groups primitives into candidates: two primitives share a candidate when their
    /// bounds, each grown by half the link tolerance, intersect — directly or through a
    /// chain of others. Union–find over a uniform grid; the components are a property of
    /// the geometry, not of visit order, so the result is deterministic.
    static func clusters(
        of primitives: [VectorPrimitive],
        linkTolerance: Double
    ) -> [[VectorPrimitive]] {
        guard primitives.count > 1 else { return primitives.isEmpty ? [] : [primitives] }

        let halfLink = Swift.max(linkTolerance, 1e-9) / 2
        let inflated = primitives.map { $0.bounds.inset(by: -halfLink) }

        // Cell size on the order of the inflated boxes keeps buckets small; the exact
        // value only affects speed, never which boxes intersect.
        var typicalExtent = 0.0
        for box in inflated {
            typicalExtent = Swift.max(typicalExtent, Swift.max(box.width, box.height))
        }
        let cellSize = Swift.max(halfLink * 4, typicalExtent / 64, 1e-6)

        var union = UnionFind(count: primitives.count)
        var buckets: [Int64: [Int32]] = [:]
        for index in primitives.indices {
            let box = inflated[index]
            let c0 = Self.cell(box.minX, size: cellSize)
            let c1 = Self.cell(box.maxX, size: cellSize)
            let r0 = Self.cell(box.minY, size: cellSize)
            let r1 = Self.cell(box.maxY, size: cellSize)
            for row in r0...r1 {
                for column in c0...c1 {
                    let key = Int64(row) &* 0x1_0000_0000 &+ Int64(Int32(truncatingIfNeeded: column))
                    if let occupants = buckets[key] {
                        for other in occupants where inflated[Int(other)].intersects(box) {
                            union.merge(index, Int(other))
                        }
                    }
                    buckets[key, default: []].append(Int32(index))
                }
            }
        }

        // Components keyed by root, ordered by their lowest member index — which is
        // their lowest primitive id, because the input is sorted ascending.
        var members: [Int: [Int]] = [:]
        for index in primitives.indices {
            members[union.find(index), default: []].append(index)
        }
        return members.values
            .sorted { ($0.first ?? 0) < ($1.first ?? 0) }
            .map { $0.map { primitives[$0] } }
    }

    /// Cell coordinates a bucket key can hold. Wide enough that no page ever clamps, small
    /// enough that a clamped coordinate still fits the key's 32-bit column field.
    static let cellCoordinateLimit = 1 << 30

    /// The grid cell of one coordinate, clamped.
    ///
    /// `isUsable` admits any finite coordinate, and `Int(1e300 / cellSize)` traps
    /// (CR-41). A coordinate past the limit lands in the last cell instead, which only
    /// makes far-apart boxes share a bucket; the exact `intersects` test decides the merge,
    /// so clamping cannot change a component, only the number of pairs examined.
    static func cell(_ coordinate: Double, size: Double) -> Int {
        let scaled = (coordinate / size).rounded(.down)
        guard scaled.isFinite else { return coordinate < 0 ? -cellCoordinateLimit : cellCoordinateLimit }
        return Int(Swift.max(-Double(cellCoordinateLimit), Swift.min(Double(cellCoordinateLimit), scaled)))
    }

    /// Plain union–find with path halving. Merge order cannot change the components.
    struct UnionFind {
        private var parent: [Int]

        init(count: Int) {
            parent = Array(0..<count)
        }

        mutating func find(_ element: Int) -> Int {
            var current = element
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        mutating func merge(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            guard rootA != rootB else { return }
            // Lower root wins, so the representative is deterministic.
            if rootA < rootB {
                parent[rootB] = rootA
            } else {
                parent[rootA] = rootB
            }
        }
    }
}
