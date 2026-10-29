import CoreGraphics
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// U-078: a refused geometry pass keeps the raster
/// result — the review lists its regions and says the geometry was not compared, and Carry
/// Forward reads the one comparison without retrying it.
@MainActor
@Suite("Iter4 Revision Compare: refused geometry pass")
struct Iter4CompareVectorRefusalNoteTests {

    /// A comparison with one raster region and the geometry pass refused as `refusal`.
    private static func result(refusal: VectorDiffRefusal?, renderScale: Double = 2) -> RevisionComparisonResult {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let region = DifferenceRegion(
            id: 1, signal: .raster, classification: .added,
            pageBounds: CGRect(x: 10, y: 10, width: 20, height: 20),
            pixelBounds: CGRect(x: 20, y: 20, width: 40, height: 40),
            changedPixelCount: 400, addedPixelCount: 400, confidence: 1
        )
        return RevisionComparisonResult(
            baselineLabel: "A", revisedLabel: "B", alignment: .identity,
            autoAlignmentMetrics: nil, autoAlignmentRejection: nil, renderScale: renderScale,
            frame: RasterFrame(boxRect: box, renderedRegion: box, rotation: 0, scale: renderScale,
                               pixelWidth: Int(box.width * renderScale), pixelHeight: Int(box.height * renderScale)),
            rasterRegions: [region],
            rasterStatistics: RasterDiffStatistics(
                comparedPixelCount: 40_000, differingPixelCount: 400, addedPixelCount: 400,
                removedPixelCount: 0, groupedRegionCount: 1, discardedRegionCount: 0
            ),
            vector: refusal.map { VectorDiffOutcome.refused($0) },
            elapsedNanoseconds: 0, wasTruncated: false, requestedRenderScale: 2
        )
    }

    private static let budgetNote =
        "Compared as rendered pages only: a sheet has 250000 drawn elements, more than the 200000 the geometry comparison can check."
    private static let unreadableNote = "Compared as rendered pages only: the geometry of a sheet could not be read."

    @Test("U-078: the review lists the raster regions of a comparison whose geometry pass was refused, and says so")
    func presenterListsRasterAndNotes() {
        let presenter = AppComparePresenter(comparator: RevisionComparator(
            source: InProcessRevisionDocumentSource(provider: PDFKitDocumentProvider(thumbnailCacheCapacity: 0))
        ))
        // Old output: compare() threw, so the presenter applied diffs [] and alignment .failed.
        presenter.present(Self.result(refusal: .primitiveBudgetExceeded(count: 250_000, limit: 200_000)), pageLabel: "B", minimumArea: 0)
        #expect(presenter.diffs.count == 1)
        #expect(presenter.resultNote == Self.budgetNote)

        presenter.present(Self.result(refusal: .extractionFailed(label: "A", reason: "unreadable")), pageLabel: "B", minimumArea: 0)
        #expect(presenter.resultNote == Self.unreadableNote)

        // With a reduced resolution as well, both sentences, resolution first (1.22 / 2 → 61 %).
        let both = CompareBridge.note(of: Self.result(refusal: .other(reason: "x"), renderScale: 1.22))
        #expect(both == "Compared at 61% of the requested resolution: this sheet is too large to render in full, so small changes may be missed. " + Self.unreadableNote)

        presenter.present(Self.result(refusal: nil), pageLabel: "B", minimumArea: 0)
        #expect(presenter.resultNote == nil)
    }

    /// Renders through the in-process source; every geometry extraction fails.
    struct UnreadableGeometrySource: RevisionDocumentSourcing {
        let inner: InProcessRevisionDocumentSource
        var isolation: RevisionParsingIsolation { inner.isolation }
        func pageBox(of reference: RevisionPageReference) async throws -> CGRect { try await inner.pageBox(of: reference) }
        func render(_ reference: RevisionPageReference, scale: Double, maximumPixels: Int) async throws -> RenderedRevisionPage {
            try await inner.render(reference, scale: scale, maximumPixels: maximumPixels)
        }
        func extractGeometry(_ reference: RevisionPageReference) async throws -> VectorPageExtraction {
            throw CompareFault.vectorExtraction(label: reference.label, reason: "unreadable")
        }
    }

    @Test("U-078: Carry Forward flags the redrawn line from the raster signal when the geometry cannot be read")
    func carryForwardUsesTheRasterSignal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it4-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.pdf")
        let newURL = directory.appendingPathComponent("new.pdf")
        try Iter1AppCoreCarryCompareTests.writeLinePDF([(100, 100, 200, 100), (400, 400, 500, 400)], to: oldURL)
        try Iter1AppCoreCarryCompareTests.writeLinePDF([(100, 100, 200, 100), (400, 420, 500, 420)], to: newURL)
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let oldDocument = try await provider.open(fileAt: oldURL)
        let newDocument = try await provider.open(fileAt: newURL)
        let comparator = RevisionComparator(source: UnreadableGeometrySource(inner: InProcessRevisionDocumentSource(provider: provider)))
        let pair = await CarryForwardComparison.pair(
            target: PageID(UUID()),
            baseline: RevisionPageReference(document: oldDocument.handle, pageIndex: 0, fileURL: oldURL, label: "A"),
            revised: RevisionPageReference(document: newDocument.handle, pageIndex: 0, fileURL: newURL, label: "B"),
            comparator: comparator
        )
        await provider.closeAll()
        #expect(!pair.reviewsEverything)
        #expect(!pair.changedRegions.isEmpty)
        #expect(pair.changedRegions.allSatisfy { $0.origin.y >= 380 }, "only the redrawn line differs: \(pair.changedRegions)")
    }
}
