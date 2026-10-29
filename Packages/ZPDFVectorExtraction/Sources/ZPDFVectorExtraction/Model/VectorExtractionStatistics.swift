import Foundation

/// What the extractor actually did, in numbers.
///
/// Present so that a `partial` result can be explained rather than asserted, and so a
/// benchmark can report the shape of the work and not only its duration.
public struct VectorExtractionStatistics: Sendable, Hashable, Codable {
    /// Standard PDF operators dispatched. Tokens that are not PDF operators at all —
    /// `zzq`, say — reach no callback and are not counted; the wall-clock budget is the
    /// backstop for a stream made of those.
    public let operatorCount: Int
    /// Primitives emitted after filtering.
    public let primitiveCount: Int
    /// Subpaths that were filtered out. Each one has a ``VectorFilterDecision``.
    public let filteredCount: Int
    public let paintedPathCount: Int
    public let subpathCount: Int
    public let formInvocationCount: Int
    /// The deepest form nesting actually entered.
    public let maximumNestingDepthReached: Int
    public let rasterRegionCount: Int
    public let inlineImageCount: Int
    /// Operators whose operands were missing or of the wrong type.
    public let malformedOperandCount: Int
    /// Encoded bytes of every content stream the extractor entered and finished.
    public let contentBytesCompleted: Int
    /// Encoded bytes of every content stream the extractor entered.
    public let contentBytesEntered: Int
    /// `contentBytesCompleted / contentBytesEntered`, clamped to `0…1`. A **lower
    /// bound**: a stream abandoned part-way contributes nothing, because a content
    /// stream exposes no cheap byte cursor.
    public let streamFractionConsumed: Double
    /// Wall-clock nanoseconds measured by the injected ``VectorTimeSource``. Excluded
    /// from equality and hashing so that two runs of the same page compare equal.
    public let elapsedNanoseconds: UInt64
    /// Bytes of primitive storage, estimated from the emitted counts.
    public let estimatedMemoryBytes: Int

    public init(
        operatorCount: Int,
        primitiveCount: Int,
        filteredCount: Int,
        paintedPathCount: Int,
        subpathCount: Int,
        formInvocationCount: Int,
        maximumNestingDepthReached: Int,
        rasterRegionCount: Int,
        inlineImageCount: Int,
        malformedOperandCount: Int,
        contentBytesCompleted: Int,
        contentBytesEntered: Int,
        elapsedNanoseconds: UInt64,
        estimatedMemoryBytes: Int
    ) {
        self.operatorCount = operatorCount
        self.primitiveCount = primitiveCount
        self.filteredCount = filteredCount
        self.paintedPathCount = paintedPathCount
        self.subpathCount = subpathCount
        self.formInvocationCount = formInvocationCount
        self.maximumNestingDepthReached = maximumNestingDepthReached
        self.rasterRegionCount = rasterRegionCount
        self.inlineImageCount = inlineImageCount
        self.malformedOperandCount = malformedOperandCount
        self.contentBytesCompleted = contentBytesCompleted
        self.contentBytesEntered = contentBytesEntered
        self.streamFractionConsumed = contentBytesEntered > 0
            ? Swift.min(1.0, Double(contentBytesCompleted) / Double(contentBytesEntered))
            : (contentBytesEntered == 0 ? 1.0 : 0.0)
        self.elapsedNanoseconds = elapsedNanoseconds
        self.estimatedMemoryBytes = estimatedMemoryBytes
    }

    /// Equality ignores ``elapsedNanoseconds``: the same page extracted twice must
    /// compare equal, and a duration never does.
    public static func == (lhs: VectorExtractionStatistics, rhs: VectorExtractionStatistics) -> Bool {
        lhs.operatorCount == rhs.operatorCount
            && lhs.primitiveCount == rhs.primitiveCount
            && lhs.filteredCount == rhs.filteredCount
            && lhs.paintedPathCount == rhs.paintedPathCount
            && lhs.subpathCount == rhs.subpathCount
            && lhs.formInvocationCount == rhs.formInvocationCount
            && lhs.maximumNestingDepthReached == rhs.maximumNestingDepthReached
            && lhs.rasterRegionCount == rhs.rasterRegionCount
            && lhs.inlineImageCount == rhs.inlineImageCount
            && lhs.malformedOperandCount == rhs.malformedOperandCount
            && lhs.contentBytesCompleted == rhs.contentBytesCompleted
            && lhs.contentBytesEntered == rhs.contentBytesEntered
            && lhs.estimatedMemoryBytes == rhs.estimatedMemoryBytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(operatorCount)
        hasher.combine(primitiveCount)
        hasher.combine(filteredCount)
        hasher.combine(subpathCount)
    }
}
