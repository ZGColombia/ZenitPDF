import Foundation
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFVectorExtraction

/// Prepares and runs one-click auto-trace off the main actor (NL-AUTO-01).
///
/// The canvas used to call the unprepared `RegionTracer.trace(primitives:click:)` on the main
/// actor: every ⌥-click flattened and collected every primitive on the page again — up to the
/// 200 000-primitive cap — before the walk even started, and the interface waited for it. This
/// keeps a `PreparedTrace` per page, extraction and filter, builds it on a background task, and
/// walks each click on a background task as well. The main actor only commits the answer.
@MainActor
final class AutoTraceService {

    struct Key: Hashable {
        let pageID: UUID
        let extraction: VectorCacheKey
        let primitiveCount: Int
        let filter: TraceFilter
    }

    /// Prepared pages kept. A person tracing moves between a couple of sheets at most.
    static let capacity = 4

    private var prepared: [Key: PreparedTrace] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: Task<PreparedTrace, Never>] = [:]

    /// How many times a page was prepared — flattened and collected. Test affordance: a second
    /// click on the same page under the same filter must not raise it.
    private(set) var prepareCount = 0

    init() {}

    /// The prepared page for `extraction` under `filter`, built at most once per key.
    func prepared(pageID: UUID, extraction: VectorPageExtraction, filter: TraceFilter) async -> PreparedTrace {
        let key = Key(
            pageID: pageID,
            extraction: extraction.cacheKey,
            primitiveCount: extraction.primitives.count,
            filter: filter
        )
        if let hit = prepared[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return hit
        }
        if let pending = inFlight[key] { return await pending.value }
        prepareCount += 1
        let primitives = extraction.primitives
        let task = Task.detached(priority: .userInitiated) {
            RegionTracer.prepare(primitives: primitives, filter: filter)
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        prepared[key] = value
        order.append(key)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            prepared[oldest] = nil
        }
        return value
    }

    /// Walks one click on a background task.
    nonisolated func trace(
        _ prepared: PreparedTrace,
        click: PDFPoint,
        maximumClosureWidth: Double
    ) async -> OpeningAwareTraceResult {
        await Task.detached(priority: .userInitiated) {
            RegionTracer.traceProposingClosures(
                prepared,
                click: click,
                maximumClosureWidth: maximumClosureWidth
            )
        }.value
    }

    /// The widest opening auto-trace may propose to close, in page points: 2.5 m through the
    /// page's scale, or 72 pt (one inch of paper) on a page nobody has calibrated.
    static let maximumClosureMetres = 2.5
    static let uncalibratedClosurePoints = 72.0

    static func maximumClosureWidth(metresPerPoint: Double?) -> Double {
        guard let metresPerPoint, metresPerPoint.isFinite, metresPerPoint > 0 else {
            return uncalibratedClosurePoints
        }
        return maximumClosureMetres / metresPerPoint
    }
}
