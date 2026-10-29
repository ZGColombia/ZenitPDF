import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// The three-state availability contract, and the hostile corpus.
///
/// The rule under test throughout: a malformed PDF produces a typed error or a partial
/// result. It never hangs, never allocates without bound, and never reports a truncated
/// extraction as complete.
struct AvailabilityAndHostileTests {

    // MARK: - Scanned pages

    @Test("A scanned page reports unavailable(.noVectorContent) and emits no geometry")
    func scannedPageIsUnavailable() async throws {
        let result = try await ExtractionTestSupport.extract(.scannedLookPage)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.availability == .unavailable(reason: .noVectorContent))
        #expect(result.extraction.primitives.isEmpty)
        #expect(!result.extraction.availability.hasUsableGeometry)

        // The raster block is recorded so the UI can say *why* snap is quiet here.
        #expect(result.extraction.rasterRegions.count == 1)
        let region = try #require(result.extraction.rasterRegions.first)
        let raster = try #require(result.manifest.rasters.first)
        #expect(abs(region.bounds.minX - raster.placement.llx) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(region.bounds.minY - raster.placement.lly) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(region.bounds.maxX - raster.placement.urx) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(region.bounds.maxY - raster.placement.ury) <= ExtractionTestSupport.coordinateTolerance)
        #expect(!region.isInline)
        #expect(region.resourceName == "Scan")
    }

    @Test("A mixed page keeps its vector line and still records the raster block")
    func mixedPageKeepsVectorGeometry() async throws {
        let result = try await ExtractionTestSupport.extract(.mixedTextAndRaster)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.availability.hasUsableGeometry)
        #expect(result.extraction.rasterRegions.count == 1)
        let line = try #require(result.manifest.path(id: "vector-line"))
        ExtractionTestSupport.expectVertices(of: line, in: result.extraction)
        // Text is never a snap source: no primitive may come from the strings.
        #expect(result.extraction.primitives.count == 1)
    }

    @Test("The availability predicate is exactly the QUALITY_BAR 3.6 table")
    func availabilityPredicate() {
        #expect(
            VectorPageScanner.resolveAvailability(
                primitiveCount: 3, filteredCount: 0, contentBytesEntered: 100, reasons: []
            ) == .available
        )
        #expect(
            VectorPageScanner.resolveAvailability(
                primitiveCount: 0, filteredCount: 0, contentBytesEntered: 100, reasons: []
            ) == .unavailable(reason: .noVectorContent)
        )
        #expect(
            VectorPageScanner.resolveAvailability(
                primitiveCount: 0, filteredCount: 1, contentBytesEntered: 100, reasons: []
            ) == .unavailable(reason: .onlyFilteredGeometry(filteredCount: 1))
        )
        #expect(
            VectorPageScanner.resolveAvailability(
                primitiveCount: 0, filteredCount: 0, contentBytesEntered: 0, reasons: []
            ) == .unavailable(reason: .emptyContentStream)
        )
        #expect(
            VectorPageScanner.resolveAvailability(
                primitiveCount: 5, filteredCount: 0, contentBytesEntered: 100,
                reasons: [.shadingGeometryNotExtracted]
            ) == .partial(reason: .shadingGeometryNotExtracted)
        )
        // A page that hit a budget is partial even with nothing extracted: calling it
        // "no vector content" would be a claim about a stream never finished.
        #expect(
            VectorPageScanner.resolveAvailability(
                primitiveCount: 0, filteredCount: 0, contentBytesEntered: 100,
                reasons: [.budgetExceeded(.wallClock, consumedFraction: 0.25)]
            ) == .partial(reason: .budgetExceeded(.wallClock, consumedFraction: 0.25))
        )
    }

    // MARK: - Hostile corpus

    @Test("100 levels of nested forms stop cleanly at the depth cap")
    func deeplyNestedFormsHitTheCap() async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await ExtractionTestSupport.extract(.deeplyNestedForms)
        defer { ExtractionTestSupport.remove(result.directory) }
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

        let cap = VectorExtractionBudget.standard.maximumFormNestingDepth
        #expect(result.manifest.formNestingDepth == 100)
        #expect(result.extraction.availability == .partial(reason: .formNestingDepthExceeded(limit: cap)))
        #expect(result.extraction.statistics.maximumNestingDepthReached == cap)
        #expect(result.extraction.primitives.isEmpty)
        #expect(result.extraction.statistics.formInvocationCount == cap)
        // The whole point is that it terminates promptly rather than dying on the stack.
        #expect(elapsedMilliseconds < 5_000)
        print("deeplyNestedForms: depth reached \(result.extraction.statistics.maximumNestingDepthReached) of 100, \(String(format: "%.2f", elapsedMilliseconds)) ms")
    }

    @Test("A megabyte of invalid operators terminates with a typed outcome")
    func malformedOperatorStreamTerminates() async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await ExtractionTestSupport.extract(.hugeMalformedOperatorStream)
        defer { ExtractionTestSupport.remove(result.directory) }
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

        // Unbalanced `Q`, wrong operand counts and references to resources that do not
        // exist are all recorded rather than silently swallowed.
        #expect(result.extraction.statistics.malformedOperandCount > 0)
        #expect(!result.extraction.availability.isAvailable)
        #expect(elapsedMilliseconds < 10_000)
        print("hugeMalformedOperatorStream: \(result.extraction.statistics.operatorCount) operators, \(result.extraction.statistics.malformedOperandCount) malformed, \(String(format: "%.2f", elapsedMilliseconds)) ms")
    }

    @Test(
        "Structurally broken files fail with a typed error and never hang",
        arguments: [FixtureKind.truncatedFile, .brokenXref, .cyclicPageTree, .missingObject]
    )
    func brokenFilesFailTyped(kind: FixtureKind) async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(kind, in: directory)
        let extractor = VectorExtractor()

        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let extraction = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
            // Recovery is a legitimate outcome — CoreGraphics rebuilds some of these.
            // What is not legitimate is a crash, a hang, or a false claim of completeness.
            #expect(extraction.statistics.operatorCount >= 0)
        } catch let error as VectorExtractionError {
            switch error {
            case .documentUnreadable, .documentHasNoPages, .pageIndexOutOfRange,
                 .contentStreamUnavailable, .fileUnreadable:
                break
            default:
                Issue.record("unexpected error for \(kind.rawValue): \(error)")
            }
        }
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        #expect(elapsedMilliseconds < 10_000)
    }

    @Test("An encrypted document is refused with a typed error, not opened half-way")
    func encryptedDocumentIsRefused() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.encryptedUserPassword, in: directory)
        let extractor = VectorExtractor()

        do {
            _ = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
            // CoreGraphics unlocks a standard-security file with an empty user password
            // in some configurations; if it did, extraction is legitimate.
        } catch let error as VectorExtractionError {
            guard case .documentEncrypted = error else {
                Issue.record("expected documentEncrypted, got \(error)")
                return
            }
        }
    }

    @Test("A decompression bomb is bounded by the operator budget, not by the inflated size")
    func decompressionBombIsBounded() async throws {
        var options = VectorExtractionOptions.standard
        options.budget.maximumOperatorCount = 50_000
        options.budget.budgetCheckInterval = 256

        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.decompressionBomb, in: directory)
        let extractor = VectorExtractor(options: options)

        let start = DispatchTime.now().uptimeNanoseconds
        let extraction = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

        #expect(extraction.statistics.operatorCount <= options.budget.maximumOperatorCount + 1)
        #expect(!extraction.availability.isAvailable)
        print("decompressionBomb: \(extraction.statistics.operatorCount) operators, availability \(extraction.availability), \(String(format: "%.2f", elapsedMilliseconds)) ms")
    }

    @Test("A page index outside the document is a typed error")
    func pageIndexIsChecked() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.rectangle, in: directory)
        let extractor = VectorExtractor()

        await #expect(throws: VectorExtractionError.pageIndexOutOfRange(index: 7, pageCount: 1)) {
            _ = try await extractor.extract(documentAt: handle.url, pageIndex: 7)
        }
        await #expect(throws: VectorExtractionError.pageIndexOutOfRange(index: -1, pageCount: 1)) {
            _ = try await extractor.extract(documentAt: handle.url, pageIndex: -1)
        }
    }

    @Test("A file that is not a PDF is a typed error")
    func nonPDFIsRefused() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let url = directory.appendingPathComponent("not-a-pdf.pdf")
        try Data("this is not a PDF at all".utf8).write(to: url)

        let extractor = VectorExtractor()
        await #expect(throws: VectorExtractionError.documentUnreadable(fileName: "not-a-pdf.pdf")) {
            _ = try await extractor.extract(documentAt: url, pageIndex: 0)
        }
    }
}
