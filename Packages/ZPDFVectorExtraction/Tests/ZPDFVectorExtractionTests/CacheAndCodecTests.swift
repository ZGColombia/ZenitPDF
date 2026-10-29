import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// The page cache and its compact serialisation.
struct CacheAndCodecTests {

    @Test("The cache key is document SHA-256, page, extractor version and option fingerprint")
    func cacheKeyComposition() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.rectangle, in: directory)

        let extractor = VectorExtractor()
        let extraction = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
        let key = extraction.cacheKey

        #expect(key.pageIndex == 0)
        #expect(key.extractorVersion == VectorExtractor.extractorVersion)
        #expect(key.documentDigest.count == 64)
        #expect(key.documentDigest.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        // The digest is the file's SHA-256 and nothing else.
        let expected = try await extractor.documentDigest(for: handle.url)
        #expect(key.documentDigest == expected)

        // Two fixtures differ in the digest, not in anything else.
        let other = try ZPDFFixtures.make(.lShape, in: directory)
        let otherKey = try await extractor.extract(documentAt: other.url, pageIndex: 0).cacheKey
        #expect(otherKey.documentDigest != key.documentDigest)
        #expect(otherKey.configurationFingerprint == key.configurationFingerprint)
    }

    @Test("Changing an option that changes the geometry changes the fingerprint")
    func fingerprintTracksOptions() {
        let base = VectorExtractionOptions.standard
        var convention = base
        convention.pageSpaceConvention = .cropBoxRotated
        var filter = base
        filter.backgroundFilter.minimumCropBoxAreaFraction = 0.9
        var flatness = base
        flatness.flatness = 0.5
        var clock = base
        clock.timeSource = .frozen(at: 1234)

        #expect(convention.fingerprint != base.fingerprint)
        #expect(filter.fingerprint != base.fingerprint)
        #expect(flatness.fingerprint != base.fingerprint)
        // The clock does not change the geometry, so it must not change the key.
        #expect(clock.fingerprint == base.fingerprint)
        // And the fingerprint is stable, not a randomly seeded hash.
        #expect(base.fingerprint == VectorExtractionOptions.standard.fingerprint)
    }

    @Test("A page round-trips through the compact binary form unchanged")
    func codecRoundTrip() async throws {
        for kind in [FixtureKind.rectangle, .bezierCircle, .nestedFormXObjects,
                     .clippedContent, .giantBackgroundRectangle, .scannedLookPage] {
            let result = try await ExtractionTestSupport.extract(kind)
            defer { ExtractionTestSupport.remove(result.directory) }

            let data = VectorExtractionCodec.encode(result.extraction)
            let decoded = try VectorExtractionCodec.decode(data)

            #expect(decoded.cacheKey == result.extraction.cacheKey)
            #expect(decoded.availability == result.extraction.availability)
            #expect(decoded.partialReasons == result.extraction.partialReasons)
            #expect(decoded.primitives == result.extraction.primitives)
            #expect(decoded.rasterRegions == result.extraction.rasterRegions)
            #expect(decoded.filterDecisions == result.extraction.filterDecisions)
            #expect(decoded.pageTransform == result.extraction.pageTransform)
            #expect(decoded.statistics == result.extraction.statistics)
            #expect(decoded == result.extraction)
        }
    }

    @Test("The serialised form is compact and byte-identical for identical input")
    func codecIsCompactAndDeterministic() async throws {
        let result = try await ExtractionTestSupport.extract(.tenThousandSegments)
        defer { ExtractionTestSupport.remove(result.directory) }

        let first = VectorExtractionCodec.encode(result.extraction)
        let second = VectorExtractionCodec.encode(result.extraction)
        #expect(first == second)

        let bytesPerPrimitive = Double(first.count) / Double(result.extraction.primitives.count)
        #expect(bytesPerPrimitive < 120)
        print("codec: \(result.extraction.primitives.count) primitives in \(first.count) bytes (\(String(format: "%.1f", bytesPerPrimitive)) bytes each)")
    }

    @Test("A corrupted or truncated cache entry is rejected, never half-decoded")
    func codecRejectsCorruption() async throws {
        let result = try await ExtractionTestSupport.extract(.rectangle)
        defer { ExtractionTestSupport.remove(result.directory) }
        let data = VectorExtractionCodec.encode(result.extraction)

        // One flipped bit anywhere in the payload must fail the checksum.
        for offset in stride(from: 0, to: data.count - 8, by: max(1, data.count / 24)) {
            var corrupted = data
            corrupted[offset] ^= 0xFF
            #expect(throws: VectorExtractionError.self) {
                _ = try VectorExtractionCodec.decode(corrupted)
            }
        }

        // Truncation at any point fails, and fails typed.
        for length in [0, 1, 8, data.count / 3, data.count - 9] where length < data.count {
            #expect(throws: VectorExtractionError.self) {
                _ = try VectorExtractionCodec.decode(data.prefix(length))
            }
        }

        // A plausible-looking header with a wrong magic is refused.
        var wrongMagic = data
        wrongMagic[0] = 0x00
        #expect(throws: VectorExtractionError.self) {
            _ = try VectorExtractionCodec.decode(wrongMagic)
        }
    }

    @Test("The cache serves a stored page and evicts deterministically")
    func cacheStoresAndEvicts() async throws {
        let result = try await ExtractionTestSupport.extract(.rectangle)
        defer { ExtractionTestSupport.remove(result.directory) }

        let cache = VectorExtractionCache(maximumEntryCount: 2, maximumTotalCostBytes: 1 << 30)
        await cache.store(result.extraction)
        let hit = await cache.value(for: result.extraction.cacheKey)
        #expect(hit == result.extraction)

        // A key with a different extractor version must miss: a stale entry served after
        // an engine change is a silently wrong snap.
        let staleKey = VectorCacheKey(
            documentDigest: result.extraction.cacheKey.documentDigest,
            pageIndex: 0,
            extractorVersion: VectorExtractor.extractorVersion + 1,
            configurationFingerprint: result.extraction.cacheKey.configurationFingerprint
        )
        let miss = await cache.value(for: staleKey)
        #expect(miss == nil)

        // Filling past the entry cap evicts the least recently used entry.
        for index in 1...3 {
            let key = VectorCacheKey(
                documentDigest: String(repeating: "\(index)", count: 64),
                pageIndex: index,
                extractorVersion: VectorExtractor.extractorVersion,
                configurationFingerprint: result.extraction.cacheKey.configurationFingerprint
            )
            await cache.store(
                VectorPageExtraction(
                    cacheKey: key,
                    availability: result.extraction.availability,
                    partialReasons: [],
                    primitives: result.extraction.primitives,
                    rasterRegions: [],
                    filterDecisions: [],
                    pageTransform: result.extraction.pageTransform,
                    statistics: result.extraction.statistics
                )
            )
        }
        let count = await cache.count
        #expect(count == 2)
        let evicted = await cache.value(for: result.extraction.cacheKey)
        #expect(evicted == nil)
    }

    @Test("An extractor with a cache returns the cached page on the second call")
    func extractorUsesItsCache() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.tenThousandSegments, in: directory)

        let cache = VectorExtractionCache()
        let extractor = VectorExtractor(cache: cache)

        let first = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
        let cached = await cache.count
        #expect(cached == 1)

        let second = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
        #expect(second == first)
        #expect(second.primitives.map(\.id) == first.primitives.map(\.id))
    }

    @Test("A wall-clock partial is not cached; the same page extracted in full afterwards is (BH-324)")
    func wallClockPartialIsNotCached() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.tenThousandSegments, in: directory)

        // A clock that jumps a second per reading against a 1 ms limit: the first
        // periodic check fires. The key excludes the clock by design, so this run and a
        // later untroubled one share one cache key.
        var slow = VectorExtractionOptions.standard
        slow.timeSource = .stepping(step: 1_000_000_000)
        slow.budget.wallClockLimitNanoseconds = 1_000_000
        slow.budget.budgetCheckInterval = 1
        var calm = slow
        calm.timeSource = .frozen()
        #expect(slow.fingerprint == calm.fingerprint)

        let cache = VectorExtractionCache()
        let truncated = try await VectorExtractor(options: slow, cache: cache)
            .extract(documentAt: handle.url, pageIndex: 0)
        guard case .partial(.budgetExceeded(.wallClock, _)) = truncated.availability else {
            Issue.record("expected a wall-clock partial, got \(truncated.availability)")
            return
        }
        // Old output: `stored == 1` — the truncated page was cached under the key a
        // complete extraction would use — and `full.availability` below was the same
        // `.partial(budgetExceeded(.wallClock))` served from the cache.
        let stored = await cache.count
        #expect(stored == 0)

        let full = try await VectorExtractor(options: calm, cache: cache)
            .extract(documentAt: handle.url, pageIndex: 0)
        #expect(full.availability == .available)
        #expect(full.primitives.count == 10_000)
        let storedAfter = await cache.count
        #expect(storedAfter == 1)
        let hit = await cache.value(for: full.cacheKey)
        #expect(hit == full)

        // Non-vacuity: the other budgets are deterministic and stay cacheable.
        var capped = VectorExtractionOptions.standard
        capped.budget.maximumPrimitiveCount = 100
        let cappedCache = VectorExtractionCache()
        _ = try await VectorExtractor(options: capped, cache: cappedCache)
            .extract(documentAt: handle.url, pageIndex: 0)
        let cappedStored = await cappedCache.count
        #expect(cappedStored == 1)
    }

    @Test("The storage name is stable, unique per key and filesystem-safe")
    func storageName() {
        let key = VectorCacheKey(
            documentDigest: String(repeating: "a", count: 64),
            pageIndex: 12,
            extractorVersion: 1,
            configurationFingerprint: 0xDEAD_BEEF
        )
        #expect(key.storageName == "\(String(repeating: "a", count: 64))-p12-v1-deadbeef.zvx")
        #expect(!key.storageName.contains("/"))
    }
}
