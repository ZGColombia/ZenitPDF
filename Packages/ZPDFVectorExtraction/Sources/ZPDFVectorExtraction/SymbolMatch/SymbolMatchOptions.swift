import Foundation

/// Everything ``SymbolMatcher`` is allowed to assume and everything it is allowed to
/// spend. Every cap in here is reported when it fires — ``SymbolMatchReport/wasTruncated``
/// exists because a partial answer must never be presented as complete.
public struct SymbolMatchOptions: Sendable, Hashable {

    /// The residual above which a candidate is rejected, as a **fraction of the
    /// candidate's RMS radius** — a dimensionless number, not page points, so the same
    /// bar applies to a symbol drawn at any size. The residual is judged stroke by
    /// stroke: the worst per-stroke nearest-neighbour distance after the declared
    /// contamination shares are set aside, measured both ways. `0.08` accepts
    /// drawing-software rounding and line-join slop; a genuinely different shape sits
    /// far above it.
    public var residualThreshold: Double

    /// How far from the exemplar's size an instance may sit. The same door
    /// at another scale is one type — but a symbol eight times the size is a different
    /// legend entry, not a door, so the band is closed and every candidate outside it is
    /// reported with the scale that was measured.
    public var scaleBand: ClosedRange<Double>

    /// A candidate must hold at least `ceil(exemplarPrimitiveCount × this)` primitives
    /// before it is worth aligning. Below it the candidate is reported as
    /// ``SymbolRejectionReason/tooFewPrimitives(found:required:)``.
    public var minimumPrimitiveCountRatio: Double

    /// The absolute floor under the rule above, so a one-line "candidate" is never
    /// aligned against a multi-stroke exemplar however small the ratio is set.
    public var minimumCandidatePrimitives: Int

    /// Multiplier on the exemplar's own internal gap (the widest bounds-to-bounds gap on
    /// its spanning tree) when deciding which page primitives belong to one candidate.
    /// The gap is also scaled by ``scaleBand``'s upper bound, because a 2× instance has
    /// 2× the internal gaps.
    public var linkToleranceFactor: Double

    /// The floor under the link tolerance, in page points. An exemplar whose strokes all
    /// touch has an internal gap of zero, and drawn strokes elsewhere on the page still
    /// miss each other by rounding-sized amounts.
    public var minimumLinkTolerance: Double

    /// Candidate clusters examined before the search stops. Reaching it sets
    /// ``SymbolMatchReport/wasTruncated`` — never a silent cap.
    public var maximumCandidates: Int

    /// Full alignments performed before the search stops. Alignment is the expensive
    /// step; reaching this cap sets ``SymbolMatchReport/wasTruncated``.
    public var maximumVerifications: Int

    /// Rotation hypotheses tried in the coarse alignment stage, spread evenly over the
    /// full turn, each tried plain and mirrored. 36 steps is 10° apart, well inside the
    /// basin the refinement iterations converge from.
    public var coarseRotationSteps: Int

    /// Nearest-neighbour Procrustes refinements after the coarse stage.
    public var refinementIterations: Int

    /// Feature points per shape the alignment works on. A set larger than this is
    /// deterministically strided down to at most this many points before aligning; the
    /// residual reported for such a candidate is measured on the strided set. This is a
    /// cost guard against aligning a whole wall network, not a correctness knob — a
    /// candidate that big is rejected either way.
    public var maximumFeaturePoints: Int

    /// A primitive whose bounds are longer than the largest possible in-band instance —
    /// the exemplar's bounds diagonal times ``scaleBand``'s upper bound — times this
    /// factor is **page context**, never candidate material: grid lines, walls,
    /// dimension strings. On a real drawing those cross everything, so without this
    /// filter clustering welds the entire sheet into one page-sized candidate and not
    /// even the exemplar's own instance survives — the LT-15 live failure. The factor
    /// leaves room above the band so an oversized *symbol* still forms a candidate and
    /// is rejected as ``SymbolRejectionReason/scaleOutsideBand(scale:band:)`` with its
    /// measured scale, rather than being dismembered. `.infinity` disables the filter.
    public var contextExtentFactor: Double

    /// The share of the **exemplar's** strokes allowed to find no counterpart in a
    /// candidate before the match fails. The estimator's crop cannot exclude a dash or
    /// stub that sits entirely inside the box, so a real exemplar carries a little
    /// context of its own; instances elsewhere carry *different* context, and those
    /// strokes will never line up. Kept low, because every unmatched exemplar stroke is
    /// also a feature a decoy is excused from having — the plain rectangle passing as a
    /// crossed one is exactly what this must not allow. `0` restores the strict
    /// behaviour: every exemplar stroke must be present.
    public var exemplarContaminationTolerance: Double

    /// The share of a **candidate's** strokes allowed to find no counterpart in the
    /// exemplar before the match fails. Clustering is deliberately promiscuous — a
    /// through-dash, a tick, a leader fragment lands in the same cluster as the symbol
    /// it crosses — and none of that makes the symbol under it less of an instance.
    /// Higher than the exemplar-side share because precision is guarded from the other
    /// direction: whatever rides along, the exemplar's own strokes must still all be
    /// found. Also bounds the rescue of an over-scale cluster: primitives too large for
    /// any in-band instance may be set aside as context, at most this share of the
    /// cluster. `0` restores the strict behaviour: every candidate stroke must belong
    /// to the symbol.
    public var candidateContaminationTolerance: Double

    /// Attributes every candidate primitive must share with the exemplar's majority style
    /// (NL-AUTO-13). Empty — the default — matches on shape alone, as the matcher always has.
    public var styleGate: Set<SymbolStyleAttribute> = []

    public init(
        residualThreshold: Double = 0.08,
        scaleBand: ClosedRange<Double> = 0.25...4.0,
        minimumPrimitiveCountRatio: Double = 0.5,
        minimumCandidatePrimitives: Int = 2,
        linkToleranceFactor: Double = 1.5,
        minimumLinkTolerance: Double = 0.75,
        maximumCandidates: Int = 4096,
        maximumVerifications: Int = 512,
        coarseRotationSteps: Int = 36,
        refinementIterations: Int = 4,
        maximumFeaturePoints: Int = 1024,
        contextExtentFactor: Double = 3.0,
        exemplarContaminationTolerance: Double = 0.2,
        candidateContaminationTolerance: Double = 0.5
    ) {
        self.residualThreshold = residualThreshold
        self.scaleBand = scaleBand
        self.minimumPrimitiveCountRatio = minimumPrimitiveCountRatio
        self.minimumCandidatePrimitives = minimumCandidatePrimitives
        self.linkToleranceFactor = linkToleranceFactor
        self.minimumLinkTolerance = minimumLinkTolerance
        self.maximumCandidates = maximumCandidates
        self.maximumVerifications = maximumVerifications
        self.coarseRotationSteps = coarseRotationSteps
        self.refinementIterations = refinementIterations
        self.maximumFeaturePoints = maximumFeaturePoints
        self.contextExtentFactor = contextExtentFactor
        self.exemplarContaminationTolerance = exemplarContaminationTolerance
        self.candidateContaminationTolerance = candidateContaminationTolerance
    }

    /// The defaults above, under the name callers should reach for.
    public static let standard = SymbolMatchOptions()

    /// Rejects a nonsense configuration with the parameter's name, in the same shape the
    /// rest of this package uses. Called by ``SymbolMatcher`` before any work happens.
    func validate() throws {
        func require(_ condition: Bool, _ name: String, _ reason: String) throws {
            guard condition else {
                throw VectorExtractionError.invalidOption(name: name, reason: reason)
            }
        }
        try require(
            residualThreshold.isFinite && residualThreshold > 0,
            "residualThreshold", "must be a finite positive fraction, got \(residualThreshold)"
        )
        try require(
            scaleBand.lowerBound.isFinite && scaleBand.lowerBound > 0
                && scaleBand.upperBound.isFinite,
            "scaleBand", "bounds must be finite and positive, got \(scaleBand)"
        )
        try require(
            minimumPrimitiveCountRatio.isFinite && minimumPrimitiveCountRatio >= 0,
            "minimumPrimitiveCountRatio",
            "must be a finite non-negative ratio, got \(minimumPrimitiveCountRatio)"
        )
        try require(
            minimumCandidatePrimitives >= 1,
            "minimumCandidatePrimitives", "must be at least 1, got \(minimumCandidatePrimitives)"
        )
        try require(
            linkToleranceFactor.isFinite && linkToleranceFactor >= 1,
            "linkToleranceFactor", "must be a finite factor of at least 1, got \(linkToleranceFactor)"
        )
        try require(
            minimumLinkTolerance.isFinite && minimumLinkTolerance >= 0,
            "minimumLinkTolerance",
            "must be a finite non-negative distance, got \(minimumLinkTolerance)"
        )
        try require(maximumCandidates >= 1, "maximumCandidates", "must be at least 1, got \(maximumCandidates)")
        try require(
            maximumVerifications >= 1,
            "maximumVerifications", "must be at least 1, got \(maximumVerifications)"
        )
        try require(
            coarseRotationSteps >= 4,
            "coarseRotationSteps", "must be at least 4, got \(coarseRotationSteps)"
        )
        try require(
            refinementIterations >= 0,
            "refinementIterations", "must be non-negative, got \(refinementIterations)"
        )
        try require(
            maximumFeaturePoints >= 8,
            "maximumFeaturePoints", "must be at least 8, got \(maximumFeaturePoints)"
        )
        try require(
            contextExtentFactor >= 1,
            "contextExtentFactor",
            "must be at least 1 (may be .infinity to disable), got \(contextExtentFactor)"
        )
        try require(
            scaleBand.upperBound * contextExtentFactor >= 1,
            "contextExtentFactor",
            "scaleBand.upperBound × contextExtentFactor must be at least 1 — below that "
                + "the context filter would remove the exemplar's own strokes, got "
                + "\(scaleBand.upperBound * contextExtentFactor)"
        )
        try require(
            exemplarContaminationTolerance.isFinite
                && exemplarContaminationTolerance >= 0 && exemplarContaminationTolerance < 1,
            "exemplarContaminationTolerance",
            "must be a finite share in [0, 1), got \(exemplarContaminationTolerance)"
        )
        try require(
            candidateContaminationTolerance.isFinite
                && candidateContaminationTolerance >= 0 && candidateContaminationTolerance < 1,
            "candidateContaminationTolerance",
            "must be a finite share in [0, 1), got \(candidateContaminationTolerance)"
        )
    }
}
