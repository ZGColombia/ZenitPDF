import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Byte-level mutation of the corpus, fed to the extractor.
///
/// The extraction half of snap (C2) fuzzing: byte-level mutation of PDFs and hand-written
/// malformed content streams must cause no crash, no unbounded memory and no `NaN` bounds, and
/// must respect the recursion cap and budgets of `QUALITY_BAR.md` 3.6.
///
/// The seed is fixed, so a failure names the iteration that produced it and that
/// iteration alone reproduces it.
@Suite("Fuzzed extraction")
struct FuzzExtractionTests {

    @Test("500 mutated documents extract or fail typed, and never emit a non-finite bound",
          .timeLimit(.minutes(5)))
    func fuzzExtraction() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let caseURL = directory.appendingPathComponent("case.pdf", isDirectory: false)

        var extracted = 0
        var rejected = 0
        var primitivesSeen = 0

        for iteration in 0..<500 {
            let seed = FuzzCorpus.seed(base: 20260823, iteration: iteration)
            var generator = SplitMix64(seed: seed)
            let base = FuzzCorpus.pick(&generator)
            let mutated = FuzzCorpus.mutate(base, generator: &generator, preserveLength: iteration % 2 == 0)
            try mutated.write(to: caseURL)

            let extractor = VectorExtractor(options: .standard)
            do {
                let pageCount = try await extractor.pageCount(documentAt: caseURL)
                // A mutated page count is attacker-controlled; the loop is bounded here
                // as well as inside the extractor.
                for pageIndex in 0..<min(2, max(0, pageCount)) {
                    let extraction = try await extractor.extract(documentAt: caseURL, pageIndex: pageIndex)
                    primitivesSeen += extraction.primitives.count
                    for primitive in extraction.primitives {
                        let bounds = primitive.bounds
                        #expect(
                            bounds.minX.isFinite && bounds.minY.isFinite
                                && bounds.maxX.isFinite && bounds.maxY.isFinite,
                            "iteration \(iteration) seed \(seed) page \(pageIndex) emitted \(bounds)"
                        )
                        #expect(
                            bounds.maxX >= bounds.minX && bounds.maxY >= bounds.minY,
                            "iteration \(iteration) seed \(seed) emitted an inverted bound \(bounds)"
                        )
                    }
                }
                extracted += 1
            } catch is VectorExtractionError {
                rejected += 1
            } catch is CancellationError {
                rejected += 1
            } catch {
                Issue.record("iteration \(iteration) seed \(seed) produced an untyped error: \(error)")
            }
        }

        #expect(extracted > 0, "no mutated document extracted — the mutator is too destructive")
        #expect(rejected > 0, "no mutated document was refused — the extractor is too permissive")
        #expect(primitivesSeen > 0, "no primitive was produced — the loop proved nothing")
    }

    @Test("Truncating a valid document at every eighth of its length never crashes the extractor")
    func truncationSweep() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let caseURL = directory.appendingPathComponent("truncated.pdf", isDirectory: false)

        let whole = try ZPDFFixtures.data(.nestedFormXObjects).data
        for step in 1...8 {
            let prefix = whole.prefix(whole.count * step / 8)
            try Data(prefix).write(to: caseURL)
            let extractor = VectorExtractor(options: .standard)
            do {
                let pageCount = try await extractor.pageCount(documentAt: caseURL)
                for pageIndex in 0..<min(1, max(0, pageCount)) {
                    _ = try await extractor.extract(documentAt: caseURL, pageIndex: pageIndex)
                }
            } catch is VectorExtractionError {
                continue
            } catch {
                Issue.record("truncation at \(step)/8 produced an untyped error: \(error)")
            }
        }
    }
}

/// The memory budget only binds if the estimate it is compared against is honest.
@Suite("Memory accounting")
struct MemoryAccountingTests {

    /// Ring geometry is the only primitive with heap storage, and it is unbounded up to
    /// `maximumPointsPerSubpath` — a million points, 16 MB, in one primitive.
    @Test("The reported estimate covers the vertices rings actually hold",
          arguments: [FixtureKind.bezierCircle, .polygonThreeHoles, .lShape])
    func estimateCoversRingVertices(_ kind: FixtureKind) async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = try ZPDFFixtures.make(kind, in: directory)

        let extractor = VectorExtractor(options: .standard)
        let extraction = try await extractor.extract(documentAt: handle.url, pageIndex: 0)

        var ringPoints = 0
        for primitive in extraction.primitives {
            if case let .ring(ring) = primitive.geometry { ringPoints += ring.vertices.count }
        }
        let floor = extraction.primitives.count * MemoryLayout<VectorPrimitive>.stride
            + ringPoints * MemoryLayout<CGPoint>.stride

        #expect(ringPoints > 0, "\(kind) emitted no ring, so it does not exercise the accounting")
        let complaint = Comment(
            rawValue: "\(kind): estimate \(extraction.statistics.estimatedMemoryBytes) is below "
                + "the \(floor) bytes its \(extraction.primitives.count) primitives and "
                + "\(ringPoints) ring vertices actually occupy"
        )
        #expect(extraction.statistics.estimatedMemoryBytes >= floor, complaint)
    }

    @Test("A memory budget smaller than the page's geometry stops extraction and says so")
    func memoryBudgetBinds() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = try ZPDFFixtures.make(.tenThousandSegments, in: directory)

        var options = VectorExtractionOptions.standard
        options.budget.memoryLimitBytes = 64 * 1024
        let extraction = try await VectorExtractor(options: options)
            .extract(documentAt: handle.url, pageIndex: 0)

        guard case let .partial(reason) = extraction.availability else {
            Issue.record("a 64 KiB budget produced \(extraction.availability)")
            return
        }
        guard case let .budgetExceeded(kind, _) = reason else {
            Issue.record("wrong partial reason: \(reason)")
            return
        }
        #expect(kind == .memory)
        // The budget is a ceiling that is never crossed, not a line noticed some way
        // past it. This page used to settle at 998 352 bytes against a 65 536-byte
        // budget: 282 primitives (correctly capped) plus 9 718 identical
        // `.primitiveBudgetExhausted` diagnostics recorded *after* the stop, all of them
        // charged to the same budget they had already broken.
        #expect(
            extraction.statistics.estimatedMemoryBytes <= 64 * 1024,
            "estimate \(extraction.statistics.estimatedMemoryBytes): \(extraction.primitives.count) primitives × \(MemoryLayout<VectorPrimitive>.stride) + \(extraction.filterDecisions.count) decisions × \(MemoryLayout<VectorFilterDecision>.stride)"
        )
        #expect(
            extraction.filterDecisions.count <= 8,
            "the stop reason is recorded once, not once per remaining subpath"
        )
    }

    @Test("A page of nothing but degenerate subpaths cannot grow the diagnostics without bound")
    func diagnosticsAreBounded() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Ten thousand painted subpaths, every one of them filtered out.
        let handle = try ZPDFFixtures.make(.tenThousandSegments, in: directory)

        var options = VectorExtractionOptions.standard
        // Nothing survives the filter, so `emit` never reaches its budget guards and the
        // diagnostics are the only thing that grows.
        options.emitsShapePrimitives = false
        let extraction = try await VectorExtractor(options: options)
            .extract(documentAt: handle.url, pageIndex: 0)

        #expect(extraction.filterDecisions.count <= VectorScanState.maximumFilterDecisions)
        // The count stays honest even when the stored decisions are capped.
        #expect(extraction.statistics.filteredCount >= extraction.filterDecisions.count)
    }
}
