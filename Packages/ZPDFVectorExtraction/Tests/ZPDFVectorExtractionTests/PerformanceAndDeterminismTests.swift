import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Throughput on the stress fixture and the determinism rules of `QUALITY_BAR` 3.4.
struct PerformanceAndDeterminismTests {

    @Test("A 10 000-segment page extracts well inside the wall-clock budget")
    func tenThousandSegmentsWithinBudget() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.tenThousandSegments, in: directory)
        let extractor = VectorExtractor()

        // One warm-up pass so the reported number is extraction, not first-touch paging.
        _ = try await extractor.extract(documentAt: handle.url, pageIndex: 0)

        var samples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let extraction = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            #expect(extraction.availability == .available)
            #expect(extraction.primitives.count == 10_000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let worst = samples[samples.count - 1]

        let extraction = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
        let manifestPaths = extraction.primitives.count
        let totalLength = ExtractionTestSupport.totalSegmentLength(of: extraction)

        print(
            """
            tenThousandSegments: \(manifestPaths) primitives, \
            median \(String(format: "%.2f", median)) ms, worst \(String(format: "%.2f", worst)) ms, \
            \(String(format: "%.0f", Double(manifestPaths) / (median / 1000))) primitives/s, \
            total length \(totalLength)
            """
        )

        // The manifest's closed-form total: 10 000 segments of exactly 5.
        #expect(abs(totalLength - 50_000) <= 1e-9)
        // The QUALITY_BAR 3.6 wall-clock budget is 10 s per page; a 10 k page must not be
        // anywhere near it. 1 s is a deliberately loose ceiling so the test does not go
        // red on a loaded CI machine while still catching an order-of-magnitude regression.
        #expect(worst < 1_000, "worst extraction took \(worst) ms")
    }

    @Test("Extraction is byte-for-byte reproducible across repeats")
    func extractionIsDeterministic() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }

        for kind in [FixtureKind.giantBackgroundRectangle, .nestedFormXObjects, .clippedContent] {
            let handle = try ZPDFFixtures.make(kind, in: directory)
            let extractor = VectorExtractor()
            let reference = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
            let referenceBytes = VectorExtractionCodec.encode(reference)

            // 20 repeats in one process. `Hasher` is seeded per process, so anything
            // ordered by a `Set` or a `Dictionary` would already show up here as soon as
            // the collection rehashes — and the encoded form would differ.
            for repeatIndex in 0..<20 {
                let again = try await VectorExtractor().extract(documentAt: handle.url, pageIndex: 0)
                #expect(again == reference, "\(kind.rawValue) differed on repeat \(repeatIndex)")
                #expect(VectorExtractionCodec.encode(again) == referenceBytes)
            }
        }
    }

    @Test("Identifiers are handed out by the injected plan, in scan order")
    func identifiersFollowThePlan() async throws {
        var options = VectorExtractionOptions.standard
        options.identifierPlan = VectorIdentifierPlan(first: 1_000, step: 7)
        let result = try await ExtractionTestSupport.extract(.rectangle, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        let identifiers = result.extraction.primitives.map(\.id)
        #expect(identifiers == [1_000, 1_007, 1_014, 1_021, 1_028])
        // Monotonically increasing in emission order: an index can rely on it.
        #expect(identifiers == identifiers.sorted())
    }

    @Test("Nothing in the result depends on the clock")
    func resultDoesNotDependOnTheClock() async throws {
        var frozen = VectorExtractionOptions.standard
        frozen.timeSource = .frozen(at: 0)
        var late = VectorExtractionOptions.standard
        late.timeSource = .frozen(at: 999_999_999_999)

        let a = try await ExtractionTestSupport.extract(.giantBackgroundRectangle, options: frozen)
        defer { ExtractionTestSupport.remove(a.directory) }
        let b = try await ExtractionTestSupport.extract(.giantBackgroundRectangle, options: late)
        defer { ExtractionTestSupport.remove(b.directory) }

        #expect(a.extraction.primitives == b.extraction.primitives)
        #expect(a.extraction.availability == b.extraction.availability)
        #expect(VectorExtractionCodec.encode(a.extraction) == VectorExtractionCodec.encode(b.extraction))
    }

    @Test("The FNV fingerprint is the same value on every run")
    func fingerprintIsProcessStable() {
        // Hard-coded because the whole point is that it does not change between
        // processes; if this value moves, the cache key moved with it and every stored
        // page must be invalidated by an extractor-version bump.
        var hash = FNVHash()
        hash.combine("ZenitPDF")
        #expect(hash.value == 0x5D3F_20E1_FA06_74DF)
    }
}
