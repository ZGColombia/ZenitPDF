import CoreGraphics
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// S-102: a comparison run below the requested
/// resolution is reported. `RevisionComparisonResult.isResolutionReduced` was documented as
/// "something the interface should say" (R-156) and nothing read it.
@MainActor
@Suite("Iter2 Revision Compare resolution note")
struct Iter2CompareResolutionNoteTests {

    /// An empty comparison at `renderScale`, asked for at `requested`.
    private static func result(renderScale: Double, requested: Double) -> RevisionComparisonResult {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        return RevisionComparisonResult(
            baselineLabel: "A",
            revisedLabel: "B",
            alignment: .identity,
            autoAlignmentMetrics: nil,
            autoAlignmentRejection: nil,
            renderScale: renderScale,
            frame: RasterFrame(
                boxRect: box, renderedRegion: box, rotation: 0, scale: renderScale,
                pixelWidth: Int(box.width * renderScale), pixelHeight: Int(box.height * renderScale)
            ),
            rasterRegions: [],
            rasterStatistics: RasterDiffStatistics(
                comparedPixelCount: 0, differingPixelCount: 0, addedPixelCount: 0,
                removedPixelCount: 0, groupedRegionCount: 0, discardedRegionCount: 0
            ),
            vector: nil,
            elapsedNanoseconds: 0,
            wasTruncated: false,
            requestedRenderScale: requested
        )
    }

    private static let reducedNote =
        "Compared at 61% of the requested resolution: this sheet is too large to render in full, so small changes may be missed."

    @Test("S-102: the bridge words a reduced-resolution run and stays silent for a full one")
    func bridgeNote() {
        // Hand-derived: 1.22 / 2 = 0.61 → 61 %.
        #expect(CompareBridge.resolutionNote(of: Self.result(renderScale: 1.22, requested: 2)) == Self.reducedNote)
        #expect(CompareBridge.resolutionNote(of: Self.result(renderScale: 2, requested: 2)) == nil)
    }

    @Test("S-102: the presenter publishes the note with the result and withdraws it with the result")
    func presenterPublishesTheNote() {
        let presenter = AppComparePresenter(comparator: RevisionComparator(
            source: InProcessRevisionDocumentSource(provider: PDFKitDocumentProvider(thumbnailCacheCapacity: 0))
        ))
        #expect(presenter.resultNote == nil)
        presenter.present(Self.result(renderScale: 1.22, requested: 2), pageLabel: "B", minimumArea: 0)
        // Old output: nothing — the presenter built its diffs and alignment and dropped the flag.
        #expect(presenter.resultNote == Self.reducedNote)
        // Read through the protocol the Compare pane is generic over.
        let pane: any ComparePresenting = presenter
        #expect(pane.resultNote == Self.reducedNote)

        presenter.invalidateComparison()
        #expect(presenter.resultNote == nil, "a withdrawn result keeps no note")
        presenter.present(Self.result(renderScale: 2, requested: 2), pageLabel: "B", minimumArea: 0)
        #expect(presenter.resultNote == nil)
    }
}
