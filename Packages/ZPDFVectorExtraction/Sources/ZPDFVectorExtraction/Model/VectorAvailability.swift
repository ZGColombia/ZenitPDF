import Foundation

/// Which budget stopped an extraction.
public enum VectorBudgetKind: UInt8, Sendable, Hashable, Codable, CaseIterable {
    case operatorCount = 0
    case primitiveCount = 1
    case wallClock = 2
    case memory = 3

    public var name: String {
        switch self {
        case .operatorCount: return "operatorCount"
        case .primitiveCount: return "primitiveCount"
        case .wallClock: return "wallClock"
        case .memory: return "memory"
        }
    }
}

/// Why an extraction is incomplete.
///
/// Every case corresponds to a row of the degradation table in `QUALITY_BAR` 3.6. The
/// rule behind all of them is the same: degrade to fewer candidates, never to wrong
/// candidates, and always say so.
public enum VectorPartialReason: Sendable, Hashable, Codable {
    /// A hard budget was hit. `consumedFraction` is a **lower bound** on the fraction of
    /// the page's content streams that was scanned: a stream abandoned part-way counts
    /// as not consumed, because a content stream gives no cheap byte cursor.
    case budgetExceeded(VectorBudgetKind, consumedFraction: Double)
    /// `sh`, or a pattern colour space, produced visible edges that no path operator
    /// describes. Nothing is synthesised from them.
    case shadingGeometryNotExtracted
    /// The page draws linework with Type 3 glyph procedures. Text is never a snap
    /// source, so that linework is missing and the user is told.
    case type3GlyphGeometryNotExtracted
    /// Form XObject nesting reached ``VectorExtractionBudget/maximumFormNestingDepth``.
    case formNestingDepthExceeded(limit: Int)
    /// A form XObject referenced itself, directly or through a cycle. The recursion was
    /// cut at the repeat.
    case cyclicFormReference
    /// A soft mask or transparency group is in force; the visible geometry depends on
    /// compositing this extractor does not perform.
    case softMaskNotComposited
    /// The content stream contained operators with missing or non-numeric operands.
    case malformedContentStream(operandFailures: Int)
    /// The page carries annotations, whose appearance streams are out of scope for
    /// Vector Snap 1.0 and are stated rather than silently omitted.
    case annotationAppearanceStreamsNotExtracted
    /// An inline image was present. Its binary payload is skipped, never parsed.
    case inlineImageSkipped(count: Int)
    /// Optional-content groups that are switched off were excluded.
    case hiddenOptionalContentExcluded(count: Int)

    /// `true` when the reason means **geometry the page contains was not extracted**.
    ///
    /// Such a reason outranks `unavailable`: reporting "no vector content" about a page
    /// whose forms were too deeply nested, or whose stream was abandoned at a budget,
    /// would be a claim about content the extractor never reached. The two informational
    /// reasons — annotation appearance streams, which are out of scope by design, and a
    /// skipped inline image, which is raster and never geometry — do not, because
    /// neither means a path was missed.
    public var meansGeometryWasMissed: Bool {
        switch self {
        case .budgetExceeded, .formNestingDepthExceeded, .cyclicFormReference,
             .type3GlyphGeometryNotExtracted, .shadingGeometryNotExtracted,
             .softMaskNotComposited, .malformedContentStream,
             .hiddenOptionalContentExcluded:
            return true
        case .annotationAppearanceStreamsNotExtracted, .inlineImageSkipped:
            return false
        }
    }

    /// A total order used to pick the single reason reported by
    /// ``VectorAvailability/partial(reason:)`` when several apply. Lower sorts first,
    /// and the first reason is the most consequential one.
    public var severityRank: Int {
        switch self {
        case .budgetExceeded: return 0
        case .formNestingDepthExceeded: return 1
        case .cyclicFormReference: return 2
        case .type3GlyphGeometryNotExtracted: return 3
        case .shadingGeometryNotExtracted: return 4
        case .softMaskNotComposited: return 5
        case .malformedContentStream: return 6
        case .hiddenOptionalContentExcluded: return 7
        case .annotationAppearanceStreamsNotExtracted: return 8
        case .inlineImageSkipped: return 9
        }
    }
}

/// Why a page has no Vector Snap at all.
public enum VectorUnavailableReason: Sendable, Hashable, Codable {
    /// The content stream painted no path geometry: a scanned page.
    case noVectorContent
    /// Every path on the page was filtered. A page whose only path is a background or
    /// border rectangle resolves here rather than to `available` with one useless
    /// primitive (`QUALITY_BAR` 3.6).
    case onlyFilteredGeometry(filteredCount: Int)
    /// The page has no content stream at all.
    case emptyContentStream
}

/// The three-state availability contract of `QUALITY_BAR` 3.6.
///
/// These are part of the contract, not UI decoration. `partial` is never presented as
/// `available`: a truncated index reported as complete is the failure mode that produces
/// a confidently wrong snap.
public enum VectorAvailability: Sendable, Hashable, Codable {
    /// Extraction completed within budget and yielded at least one primitive.
    case available
    /// Extraction hit a budget or a known limitation. Vector Snap works on what was
    /// extracted, and the UI must state that it is incomplete.
    case partial(reason: VectorPartialReason)
    /// Zero primitives after filtering. Grid and markup snap continue to work.
    case unavailable(reason: VectorUnavailableReason)

    public var isAvailable: Bool { if case .available = self { return true } else { return false } }
    public var isPartial: Bool { if case .partial = self { return true } else { return false } }
    public var isUnavailable: Bool { if case .unavailable = self { return true } else { return false } }
    /// `true` when a caller may query vector candidates at all.
    public var hasUsableGeometry: Bool { !isUnavailable }
}
