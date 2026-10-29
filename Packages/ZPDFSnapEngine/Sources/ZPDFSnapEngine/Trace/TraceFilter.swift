import Foundation
import ZPDFVectorExtraction

/// What the **person** has decided the tracer should not follow (NL-AUTO-01, NL-AUTO-11).
///
/// ``TraceSegmentCollector`` refuses, rightly, to judge what a wall is: a dashed line or a fill
/// boundary may be one, and dropping it silently would come back as a bridged gap somewhere
/// else. The person may judge, and this value is how they do it. It is applied to the
/// primitives **before** ``RegionTracer/prepare(primitives:options:filter:)``, so a filtered
/// primitive is structurally absent from the arrangement rather than skipped at walk time —
/// the same rule the snap index follows for a hidden layer (S23).
///
/// Two sources feed it:
///
/// - **Layer visibility**, which is not a choice about tracing at all but a fact about the
///   sheet: a layer the person switched off, or every layer but the locked one under a measure
///   lock, must not split or close the room they click. ``hiddenLayerIDs`` holds the same
///   marked-content property names the snap index excludes.
/// - **Trace options the person chose**: ignore dashed lines, ignore fill-only paths (hatch
///   and solid fills), ignore strokes thinner than a width, ignore low-confidence geometry.
///   Every active option is stated by ``activeDescriptions`` so the interface can say what the
///   trace is not looking at.
public struct TraceFilter: Sendable, Hashable {

    /// Marked-content property names whose primitives are left out.
    public var hiddenLayerIDs: Set<String>
    /// Leave out stroked paths drawn with a dash pattern.
    public var excludesDashed: Bool
    /// Leave out paths that are filled and not stroked: solid fills and fill-drawn hatch.
    public var excludesFillOnly: Bool
    /// Leave out stroked paths thinner than this, in page points. `0` keeps every width.
    /// A fill-only path has no stroke width and is governed by ``excludesFillOnly`` alone.
    public var minimumStrokeWidth: Double
    /// Leave out primitives whose extraction confidence is under this. `0` keeps everything.
    public var minimumConfidence: Float

    public init(
        hiddenLayerIDs: Set<String> = [],
        excludesDashed: Bool = false,
        excludesFillOnly: Bool = false,
        minimumStrokeWidth: Double = 0,
        minimumConfidence: Float = 0
    ) {
        self.hiddenLayerIDs = hiddenLayerIDs
        self.excludesDashed = excludesDashed
        self.excludesFillOnly = excludesFillOnly
        self.minimumStrokeWidth = minimumStrokeWidth.isFinite ? Swift.max(0, minimumStrokeWidth) : 0
        self.minimumConfidence = minimumConfidence.isFinite ? Swift.min(1, Swift.max(0, minimumConfidence)) : 0
    }

    /// The filter that leaves everything in: the tracer's historical behaviour.
    public static let none = TraceFilter()

    /// `true` when the filter removes anything at all.
    public var isActive: Bool {
        !hiddenLayerIDs.isEmpty || excludesDashed || excludesFillOnly
            || minimumStrokeWidth > 0 || minimumConfidence > 0
    }

    /// `true` when `primitive` stays in the arrangement.
    public func admits(_ primitive: VectorPrimitive) -> Bool {
        if let layer = primitive.layerID, hiddenLayerIDs.contains(layer) { return false }
        let stroked = primitive.paint.contains(.stroked)
        let filled = primitive.paint.contains(.filled)
        if excludesFillOnly, filled, !stroked { return false }
        if excludesDashed, stroked, primitive.strokeIsDashed { return false }
        if minimumStrokeWidth > 0, stroked, !filled, primitive.strokeWidth < minimumStrokeWidth {
            return false
        }
        if minimumConfidence > 0, primitive.confidence < minimumConfidence { return false }
        return true
    }

    /// The primitives this filter admits, in their original deterministic order. Returns the
    /// input unchanged when the filter is inactive, so an unfiltered trace costs nothing extra.
    public func apply(to primitives: [VectorPrimitive]) -> [VectorPrimitive] {
        guard isActive else { return primitives }
        return primitives.filter(admits)
    }

    /// One stable token per active choice, for the status line and for tests. Layer visibility
    /// is reported as a count because the names are the drawing's, not the person's words.
    public var activeDescriptions: [ActiveChoice] {
        var result: [ActiveChoice] = []
        if !hiddenLayerIDs.isEmpty { result.append(.hiddenLayers(count: hiddenLayerIDs.count)) }
        if excludesDashed { result.append(.ignoresDashed) }
        if excludesFillOnly { result.append(.ignoresFills) }
        if minimumStrokeWidth > 0 { result.append(.ignoresThinnerThan(points: minimumStrokeWidth)) }
        if minimumConfidence > 0 { result.append(.ignoresLowConfidence(below: Double(minimumConfidence))) }
        return result
    }

    /// A choice in force, as data; the interface words it.
    public enum ActiveChoice: Sendable, Hashable {
        case hiddenLayers(count: Int)
        case ignoresDashed
        case ignoresFills
        case ignoresThinnerThan(points: Double)
        case ignoresLowConfidence(below: Double)
    }
}
