import Foundation

/// A bounded, in-memory page cache keyed by ``VectorCacheKey``.
///
/// The index is cached by document SHA, page and engine version. This is the in-memory half; ``VectorExtractionCodec`` is the on-disk half,
/// so the same entry can later be written into the project package.
///
/// Eviction is strict least-recently-used with an explicit access counter rather than a
/// timestamp: `QUALITY_BAR` 3.4 forbids behaviour that depends on wall-clock time, and a
/// cache that evicts differently depending on how fast the machine is would make the
/// snap engine's behaviour depend on the machine.
public actor VectorExtractionCache {

    private struct Entry {
        let extraction: VectorPageExtraction
        let cost: Int
        var lastUse: UInt64
    }

    private var entries: [VectorCacheKey: Entry] = [:]
    private var accessCounter: UInt64 = 0
    private var totalCost = 0

    public let maximumEntryCount: Int
    public let maximumTotalCostBytes: Int

    public init(maximumEntryCount: Int = 64, maximumTotalCostBytes: Int = 256 * 1024 * 1024) {
        self.maximumEntryCount = Swift.max(1, maximumEntryCount)
        self.maximumTotalCostBytes = Swift.max(1, maximumTotalCostBytes)
    }

    public var count: Int { entries.count }

    public func value(for key: VectorCacheKey) -> VectorPageExtraction? {
        guard var entry = entries[key] else { return nil }
        accessCounter &+= 1
        entry.lastUse = accessCounter
        entries[key] = entry
        return entry.extraction
    }

    public func store(_ extraction: VectorPageExtraction) {
        let key = extraction.cacheKey
        let cost = Swift.max(1, extraction.statistics.estimatedMemoryBytes)
        if let existing = entries.removeValue(forKey: key) { totalCost -= existing.cost }
        accessCounter &+= 1
        entries[key] = Entry(extraction: extraction, cost: cost, lastUse: accessCounter)
        totalCost += cost
        evictIfNeeded()
    }

    public func removeValue(for key: VectorCacheKey) {
        guard let existing = entries.removeValue(forKey: key) else { return }
        totalCost -= existing.cost
    }

    public func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    private func evictIfNeeded() {
        while entries.count > maximumEntryCount || totalCost > maximumTotalCostBytes {
            // The victim is chosen by the total order (lastUse, then the key's storage
            // name), so eviction never depends on `Dictionary` iteration order — which
            // is randomly seeded per process and would make the cache non-deterministic.
            guard let victim = entries.min(by: { lhs, rhs in
                if lhs.value.lastUse != rhs.value.lastUse { return lhs.value.lastUse < rhs.value.lastUse }
                return lhs.key.storageName < rhs.key.storageName
            }) else { return }
            entries.removeValue(forKey: victim.key)
            totalCost -= victim.value.cost
        }
    }
}
