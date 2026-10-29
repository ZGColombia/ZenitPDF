import Foundation

/// The hard budgets of `QUALITY_BAR` 3.6.
///
/// A PDF is hostile data: every loop is bounded, every allocation is capped and every
/// long operation is cancellable. Exceeding any of these marks the page
/// `partial(budgetExceeded:)` — never `available`.
public struct VectorExtractionBudget: Sendable, Hashable, Codable {
    /// Standard PDF operators dispatched before extraction stops. Default 20 000 000.
    public var maximumOperatorCount: Int
    /// Primitives emitted before extraction stops. Default 2 000 000.
    public var maximumPrimitiveCount: Int
    /// Wall-clock nanoseconds. Default 10 s.
    public var wallClockLimitNanoseconds: UInt64
    /// Estimated bytes of primitive storage. Default 512 MiB.
    public var memoryLimitBytes: Int
    /// Form XObject recursion cap. Default 32.
    public var maximumFormNestingDepth: Int
    /// Points accepted in one subpath before the subpath is closed off. A malformed
    /// stream can otherwise append to one subpath forever. Default 1 000 000.
    public var maximumPointsPerSubpath: Int
    /// How often the budgets are re-checked, in operators. Small enough that a runaway
    /// stream is caught promptly, large enough that the check is not the cost.
    public var budgetCheckInterval: Int

    /// The largest ``maximumPrimitiveCount`` any extraction may run with, and the default.
    ///
    /// One number with two readers (S17-10): the extractor, which ``VectorExtractionOptions``
    /// refuses to run above it, and ``VectorExtractionCodec/maximumPrimitives``, which refuses
    /// to decode more. The decoder used to accept 8 000 000 — four times anything an honest
    /// encoder can emit — so a compromised geometry service could make the application
    /// materialise four times the largest legitimate page with every byte passing the caps.
    public static let maximumPrimitiveCountCeiling = 2_000_000
    /// The largest ``maximumPointsPerSubpath`` any extraction may run with, and the default.
    /// A closed subpath becomes one ring, so this is also
    /// ``VectorExtractionCodec/maximumRingVertices`` (S17-10; the decoder used to accept
    /// 4 000 000).
    public static let maximumPointsPerSubpathCeiling = 1_000_000

    public init(
        maximumOperatorCount: Int = 20_000_000,
        maximumPrimitiveCount: Int = VectorExtractionBudget.maximumPrimitiveCountCeiling,
        wallClockLimitNanoseconds: UInt64 = 10_000_000_000,
        memoryLimitBytes: Int = 512 * 1024 * 1024,
        maximumFormNestingDepth: Int = 32,
        maximumPointsPerSubpath: Int = VectorExtractionBudget.maximumPointsPerSubpathCeiling,
        budgetCheckInterval: Int = 512
    ) {
        self.maximumOperatorCount = maximumOperatorCount
        self.maximumPrimitiveCount = maximumPrimitiveCount
        self.wallClockLimitNanoseconds = wallClockLimitNanoseconds
        self.memoryLimitBytes = memoryLimitBytes
        self.maximumFormNestingDepth = maximumFormNestingDepth
        self.maximumPointsPerSubpath = maximumPointsPerSubpath
        self.budgetCheckInterval = Swift.max(1, budgetCheckInterval)
    }

    public static let standard = VectorExtractionBudget()

    func fingerprint(into hash: inout FNVHash) {
        hash.combine(maximumOperatorCount)
        hash.combine(maximumPrimitiveCount)
        hash.combine(wallClockLimitNanoseconds)
        hash.combine(memoryLimitBytes)
        hash.combine(maximumFormNestingDepth)
        hash.combine(maximumPointsPerSubpath)
    }
}

/// The background-rectangle heuristic, stated precisely.
///
/// Three independent rules, each recorded when it fires (``VectorFilterRule``):
///
/// 1. **`pageSizedBackground`** — the subpath is a rectangle or a four-vertex closed
///    subpath, its area covers at least ``minimumCropBoxAreaFraction`` of the crop box,
///    and (when ``filtersFilledOnly`` is on) it was filled and not stroked. A *stroked*
///    page-sized rectangle is a drawn border, which a user may well want to snap to, so
///    by default it survives.
/// 2. **`enclosesCropBox`** — the subpath's bounds contain the crop box grown by
///    ``cropBoxOvershootMargin`` on every side. Geometry strictly larger than the sheet
///    is a backdrop, whatever its paint.
/// 3. **`entirelyOutsideCropBox`** — the subpath's bounds do not meet the crop box at
///    all. Nothing visible, nothing to snap to.
///
/// Deliberately **not** a rule: "the path's bounds exceed the crop box". Geometry that
/// merely runs off the edge of the sheet — a section line continued past the border, a
/// dimension leader — is ordinary drawing content, and filtering it would delete
/// exactly the linework a user reaches for.
public struct VectorBackgroundFilter: Sendable, Hashable, Codable {
    public var isEnabled: Bool
    /// Default `0.95`, from `QUALITY_BAR` 3.6.
    public var minimumCropBoxAreaFraction: Double
    /// Default `0.5` page points.
    public var cropBoxOvershootMargin: Double
    /// Default `true`: only a filled, unstroked rectangle is treated as background.
    public var filtersFilledOnly: Bool
    /// Default `true`: rule 3 discards geometry that misses the sheet entirely.
    public var filtersGeometryOutsideCropBox: Bool

    public init(
        isEnabled: Bool = true,
        minimumCropBoxAreaFraction: Double = 0.95,
        cropBoxOvershootMargin: Double = 0.5,
        filtersFilledOnly: Bool = true,
        filtersGeometryOutsideCropBox: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.minimumCropBoxAreaFraction = minimumCropBoxAreaFraction
        self.cropBoxOvershootMargin = cropBoxOvershootMargin
        self.filtersFilledOnly = filtersFilledOnly
        self.filtersGeometryOutsideCropBox = filtersGeometryOutsideCropBox
    }

    public static let standard = VectorBackgroundFilter()
    /// Every rule off. Nothing is filtered as background; useful when a user reports a
    /// missing snap target and the question is whether the heuristic ate it.
    public static let disabled = VectorBackgroundFilter(isEnabled: false)

    func fingerprint(into hash: inout FNVHash) {
        hash.combine(isEnabled)
        hash.combine(minimumCropBoxAreaFraction)
        hash.combine(cropBoxOvershootMargin)
        hash.combine(filtersFilledOnly)
        hash.combine(filtersGeometryOutsideCropBox)
    }
}

/// How identifiers are handed out.
///
/// Injected rather than generated from `UUID()` so that the same document extracted
/// twice produces the same identifiers — a requirement for both the cache and
/// `QUALITY_BAR` S15.
public struct VectorIdentifierPlan: Sendable, Hashable, Codable {
    public var first: UInt64
    /// Never below 1. A step of 0 hands every primitive the same identifier, and the snap
    /// index then fails to build once a page has more than a few dozen of them. The
    /// clamp used to live in `init` only, so the public setter and the synthesised
    /// `init(from:)` both bypassed it (BH-860); it now holds through every door.
    public var step: UInt64 {
        didSet { if step == 0 { step = 1 } }
    }

    public init(first: UInt64 = 1, step: UInt64 = 1) {
        self.first = first
        self.step = Swift.max(1, step)
    }

    private enum CodingKeys: String, CodingKey {
        case first
        case step
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            first: try container.decode(UInt64.self, forKey: .first),
            step: try container.decode(UInt64.self, forKey: .step)
        )
    }

    public static let standard = VectorIdentifierPlan()

    func fingerprint(into hash: inout FNVHash) {
        hash.combine(first)
        hash.combine(step)
    }
}

/// Everything that changes what extraction emits.
public struct VectorExtractionOptions: Sendable {
    public var budget: VectorExtractionBudget
    public var backgroundFilter: VectorBackgroundFilter
    public var identifierPlan: VectorIdentifierPlan
    public var pageSpaceConvention: VectorPageSpaceConvention
    /// Flatness used by ``VectorFlattener`` for index bounds and hit testing, in page
    /// points. Never affects stored geometry.
    public var flatness: Double
    /// When on, a path that only set the clip is emitted with `paint == .clipDerived`
    /// and confidence `0.5`, instead of being filtered. `QUALITY_BAR` 3.6 allows this
    /// for shading-bounded regions; it is off by default.
    public var emitsClipDerivedPrimitives: Bool
    /// When off, geometry whose bounds miss the clip in force is emitted anyway. On by
    /// default: an invisible edge is not a snap target.
    public var excludesGeometryOutsideClip: Bool
    /// Emit a subpath-level primitive (``VectorPrimitiveKind/rectangle`` or
    /// ``VectorPrimitiveKind/closedSubpath``) alongside the per-segment primitives.
    public var emitsShapePrimitives: Bool
    /// When on, geometry inside a `BDC /OC` section whose optional-content group is
    /// switched off in the document's default configuration is extracted anyway,
    /// still tagged with its ``VectorPrimitive/layerID``. Off by default: an invisible
    /// edge is not a snap target under document defaults. Turn it on when per-project
    /// layer overrides may *show* a default-hidden layer — the primitives are then all
    /// present once, and ``VectorLayerVisibilityFilter`` decides visibility at query
    /// time, with no re-extraction when the user toggles a layer.
    public var includesHiddenOptionalContent: Bool
    /// The clock. ``VectorTimeSource/system`` by default.
    public var timeSource: VectorTimeSource

    public init(
        budget: VectorExtractionBudget = .standard,
        backgroundFilter: VectorBackgroundFilter = .standard,
        identifierPlan: VectorIdentifierPlan = .standard,
        pageSpaceConvention: VectorPageSpaceConvention = .pdfUserSpace,
        flatness: Double = 0.1,
        emitsClipDerivedPrimitives: Bool = false,
        excludesGeometryOutsideClip: Bool = true,
        emitsShapePrimitives: Bool = true,
        includesHiddenOptionalContent: Bool = false,
        timeSource: VectorTimeSource = .system
    ) {
        self.budget = budget
        self.backgroundFilter = backgroundFilter
        self.identifierPlan = identifierPlan
        self.pageSpaceConvention = pageSpaceConvention
        self.flatness = flatness
        self.emitsClipDerivedPrimitives = emitsClipDerivedPrimitives
        self.excludesGeometryOutsideClip = excludesGeometryOutsideClip
        self.emitsShapePrimitives = emitsShapePrimitives
        self.includesHiddenOptionalContent = includesHiddenOptionalContent
        self.timeSource = timeSource
    }

    public static let standard = VectorExtractionOptions()

    /// A process-stable fingerprint of everything that changes the emitted geometry.
    ///
    /// ``timeSource`` is excluded on purpose: the clock changes when a budget fires, and
    /// a budget firing is recorded in the result rather than in the key. Two runs with
    /// different clocks that both finish inside budget produce identical geometry.
    public var fingerprint: UInt64 {
        var hash = FNVHash()
        budget.fingerprint(into: &hash)
        backgroundFilter.fingerprint(into: &hash)
        identifierPlan.fingerprint(into: &hash)
        hash.combine(pageSpaceConvention.rawValue)
        hash.combine(flatness)
        hash.combine(emitsClipDerivedPrimitives)
        hash.combine(excludesGeometryOutsideClip)
        hash.combine(emitsShapePrimitives)
        hash.combine(includesHiddenOptionalContent)
        return hash.value
    }

    func validated() throws -> VectorExtractionOptions {
        guard flatness > 0, flatness.isFinite else {
            throw VectorExtractionError.invalidOption(
                name: "flatness",
                reason: "must be a positive finite number, got \(flatness)"
            )
        }
        guard budget.maximumFormNestingDepth >= 1 else {
            throw VectorExtractionError.invalidOption(
                name: "budget.maximumFormNestingDepth",
                reason: "must be at least 1"
            )
        }
        guard budget.maximumPrimitiveCount >= 0, budget.maximumOperatorCount >= 0 else {
            throw VectorExtractionError.invalidOption(
                name: "budget",
                reason: "counts must not be negative"
            )
        }
        // Above the ceiling the extractor would emit what ``VectorExtractionCodec`` refuses to
        // decode: the service's honest reply would be rejected as hostile, and a cache entry
        // would never read back. The ceiling is the one number both sides check (S17-10).
        guard budget.maximumPrimitiveCount <= VectorExtractionBudget.maximumPrimitiveCountCeiling else {
            throw VectorExtractionError.invalidOption(
                name: "budget.maximumPrimitiveCount",
                reason: "must not exceed \(VectorExtractionBudget.maximumPrimitiveCountCeiling), got \(budget.maximumPrimitiveCount)"
            )
        }
        guard budget.maximumPointsPerSubpath <= VectorExtractionBudget.maximumPointsPerSubpathCeiling else {
            throw VectorExtractionError.invalidOption(
                name: "budget.maximumPointsPerSubpath",
                reason: "must not exceed \(VectorExtractionBudget.maximumPointsPerSubpathCeiling), got \(budget.maximumPointsPerSubpath)"
            )
        }
        // A subpath needs its start point and one more vertex to hold a segment at all.
        // Below 2 every `l`/`c`/`v`/`y` after `m` fails the per-subpath cap and is counted
        // as a malformed operand, so a valid drawing came back empty and `partial` with the
        // file blamed for the caller's budget (BH-861).
        guard budget.maximumPointsPerSubpath >= 2 else {
            throw VectorExtractionError.invalidOption(
                name: "budget.maximumPointsPerSubpath",
                reason: "must be at least 2, got \(budget.maximumPointsPerSubpath)"
            )
        }
        let fraction = backgroundFilter.minimumCropBoxAreaFraction
        guard fraction > 0, fraction <= 1 else {
            throw VectorExtractionError.invalidOption(
                name: "backgroundFilter.minimumCropBoxAreaFraction",
                reason: "must lie in (0, 1], got \(fraction)"
            )
        }
        // The margin grows the crop box; a negative one shrinks it towards its centre
        // and NaN collapses it to the centre point, after which every outline that merely
        // contains the page centre is filtered as `enclosesCropBox` (BH-862).
        let margin = backgroundFilter.cropBoxOvershootMargin
        guard margin.isFinite, margin >= 0 else {
            throw VectorExtractionError.invalidOption(
                name: "backgroundFilter.cropBoxOvershootMargin",
                reason: "must be a finite non-negative distance, got \(margin)"
            )
        }
        return self
    }
}
