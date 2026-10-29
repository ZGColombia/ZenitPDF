import Foundation

/// Everything extraction knows about one page.
public struct VectorPageExtraction: Sendable, Hashable, Codable {
    public let cacheKey: VectorCacheKey
    public let availability: VectorAvailability
    /// Every reason the result is incomplete, sorted by
    /// ``VectorPartialReason/severityRank`` then by description, so the order is
    /// deterministic. ``availability`` reports the first of them.
    public let partialReasons: [VectorPartialReason]
    /// In deterministic scan order. Never contains a filtered primitive.
    public let primitives: [VectorPrimitive]
    public let rasterRegions: [VectorRasterRegion]
    /// One entry per subpath that was painted but not emitted.
    public let filterDecisions: [VectorFilterDecision]
    public let pageTransform: VectorPageTransform
    public let statistics: VectorExtractionStatistics
    /// Every Form XObject drawing that produced primitives, in scan order (NL-AUTO-12). `nil`
    /// for an extraction decoded from a format written before the table existed.
    public let formInvocations: [VectorFormInvocation]?

    public init(
        cacheKey: VectorCacheKey,
        availability: VectorAvailability,
        partialReasons: [VectorPartialReason],
        primitives: [VectorPrimitive],
        rasterRegions: [VectorRasterRegion],
        filterDecisions: [VectorFilterDecision],
        pageTransform: VectorPageTransform,
        statistics: VectorExtractionStatistics,
        formInvocations: [VectorFormInvocation]? = nil
    ) {
        self.cacheKey = cacheKey
        self.availability = availability
        self.partialReasons = partialReasons
        self.primitives = primitives
        self.rasterRegions = rasterRegions
        self.filterDecisions = filterDecisions
        self.pageTransform = pageTransform
        self.statistics = statistics
        self.formInvocations = formInvocations
    }

    /// The bounds of every emitted primitive, or `nil` when there are none.
    public var geometryBounds: VectorBounds? {
        guard var result = primitives.first?.bounds else { return nil }
        for primitive in primitives.dropFirst() { result = result.union(primitive.bounds) }
        return result
    }

    /// The primitives of one painted path, in order.
    public func primitives(sourceObjectID: UInt64) -> [VectorPrimitive] {
        primitives.filter { $0.sourceObjectID == sourceObjectID }
    }

    /// The subpath-level primitives: rectangles and closed subpaths.
    public var shapePrimitives: [VectorPrimitive] {
        primitives.filter { $0.kind == .rectangle || $0.kind == .closedSubpath }
    }

    /// The segment-level primitives: lines and cubics.
    public var segmentPrimitives: [VectorPrimitive] {
        primitives.filter { $0.kind == .lineSegment || $0.kind == .cubicCurve }
    }
}
