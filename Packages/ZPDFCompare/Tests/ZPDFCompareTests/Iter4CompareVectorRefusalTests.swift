import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
import ZPDFVectorExtraction

@testable import ZPDFCompare

/// Iteration 4, U-078: a geometry pass that is refused no longer
/// throws away the raster diff that already succeeded.
@Suite("Iter4 compare: a refused geometry pass keeps the raster result", .serialized)
struct Iter4CompareVectorRefusalTests {

    /// The in-process source for rendering, with a geometry pass that fails as `failure` says.
    struct FailingGeometrySource: RevisionDocumentSourcing {
        let inner: InProcessRevisionDocumentSource
        let failure: any Error & Sendable
        var isolation: RevisionParsingIsolation { inner.isolation }
        func pageBox(of reference: RevisionPageReference) async throws -> CGRect {
            try await inner.pageBox(of: reference)
        }
        func render(_ reference: RevisionPageReference, scale: Double, maximumPixels: Int) async throws -> RenderedRevisionPage {
            try await inner.render(reference, scale: scale, maximumPixels: maximumPixels)
        }
        func extractGeometry(_ reference: RevisionPageReference) async throws -> VectorPageExtraction {
            throw failure
        }
    }

    @Test("U-078: over the per-page primitive limit, the raster regions still come back and the vector outcome says why it is not meaningful")
    func primitiveBudgetKeepsRaster() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        // Old output: compare threw CompareFault.vectorPrimitiveBudgetExceeded(count: …, limit: 1)
        // and the app showed "failed" with no regions.
        let result = try await harness.compare(scale: 2, vector: VectorDiffOptions(maximumPrimitivesPerPage: 1))
        #expect(result.rasterRegions.count == 1)
        #expect(result.differenceCount == 1)
        let vector = try #require(result.vector)
        #expect(vector.isMeaningful == false)
        #expect(vector.regions.isEmpty && vector.differences.isEmpty)
        guard case let .primitiveBudgetExceeded(count, limit)? = vector.refusal else {
            Issue.record("expected a primitive-budget refusal, got \(String(describing: vector.refusal))")
            return
        }
        #expect(limit == 1 && count > 1)
        // Both extractions completed, so their availability is the real one.
        #expect(vector.baselineAvailability.isAvailable && vector.revisedAvailability.isAvailable)
        #expect(vector.baselinePrimitiveCount == count)

        // The same pair within the limit runs the geometry pass as before.
        let full = try await harness.compare(scale: 2)
        #expect(full.vector?.isMeaningful == true && full.vector?.refusal == nil)
    }

    @Test("U-078: a drawing the geometry scanner cannot read still gets a raster comparison")
    func extractionFailureKeepsRaster() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }
        let comparator = RevisionComparator(source: FailingGeometrySource(
            inner: InProcessRevisionDocumentSource(provider: harness.provider),
            failure: CompareFault.vectorExtraction(label: "baseline", reason: "unreadable content stream")
        ))
        let request = RevisionCompareRequest(
            baseline: harness.baseline, revised: harness.revised, renderScale: 2, alignment: .identity,
            raster: RasterDiffOptions(tolerance: .strict)
        )
        // Old output: compare threw CompareFault.vectorExtraction(label: "baseline", …).
        let result = try await comparator.compare(request)
        #expect(result.rasterRegions.count == 1)
        #expect(result.vector?.isMeaningful == false)
        #expect(result.vector?.refusal == .extractionFailed(label: "baseline", reason: "unreadable content stream"))
        #expect(result.vector?.baselineAvailability.isUnavailable == true)
    }

    @Test("U-078: cancellation inside the geometry pass still ends the comparison")
    func cancellationStillThrows() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }
        for failure: any Error & Sendable in [CancellationError(), CompareFault.cancelled] {
            let comparator = RevisionComparator(source: FailingGeometrySource(
                inner: InProcessRevisionDocumentSource(provider: harness.provider), failure: failure
            ))
            let request = RevisionCompareRequest(
                baseline: harness.baseline, revised: harness.revised, renderScale: 2, alignment: .identity
            )
            await #expect(throws: CompareFault.cancelled) { _ = try await comparator.compare(request) }
        }
    }
}
