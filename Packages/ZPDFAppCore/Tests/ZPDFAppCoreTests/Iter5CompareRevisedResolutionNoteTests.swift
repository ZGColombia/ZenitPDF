import CoreGraphics
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFCompare

/// V-080: the Compare pane's reduced-resolution note
/// reads the coarser of the two sheets, since each is fitted to the raster budget on its own.
@MainActor
@Suite("Iter5 Revision Compare note for a reduced revision")
struct Iter5CompareRevisedResolutionNoteTests {

    private static func result(baseline: Double, revised: Double, requested: Double) -> RevisionComparisonResult {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        return RevisionComparisonResult(
            baselineLabel: "A",
            revisedLabel: "B",
            alignment: .identity,
            autoAlignmentMetrics: nil,
            autoAlignmentRejection: nil,
            renderScale: baseline,
            frame: RasterFrame(
                boxRect: box, renderedRegion: box, rotation: 0, scale: baseline,
                pixelWidth: Int(box.width * baseline), pixelHeight: Int(box.height * baseline)
            ),
            rasterRegions: [],
            rasterStatistics: RasterDiffStatistics(
                comparedPixelCount: 0, differingPixelCount: 0, addedPixelCount: 0,
                removedPixelCount: 0, groupedRegionCount: 0, discardedRegionCount: 0
            ),
            vector: nil,
            elapsedNanoseconds: 0,
            wasTruncated: false,
            requestedRenderScale: requested,
            revisedRenderScale: revised
        )
    }

    /// Old output: `nil` — `isResolutionReduced` compared the baseline's 2.0 with the requested
    /// 2.0, and the revision's 1.22 was never looked at.
    @Test("V-080: a revision rendered below the request is worded with its own percentage")
    func revisedSheetReducedIsWorded() {
        // Hand-derived: 1.22 / 2 = 0.61 → 61 %.
        #expect(CompareBridge.resolutionNote(of: Self.result(baseline: 2, revised: 1.22, requested: 2))
            == "Compared at 61% of the requested resolution: this sheet is too large to render in full, so small changes may be missed.")
        // Both reduced: the coarser one is the resolution the comparison saw. 1.0 / 2 = 50 %.
        #expect(CompareBridge.resolutionNote(of: Self.result(baseline: 1.6, revised: 1.0, requested: 2))?
            .hasPrefix("Compared at 50% ") == true)
        // Baseline reduced, revision not: unchanged from S-102. 1.5 / 2 = 75 %.
        #expect(CompareBridge.resolutionNote(of: Self.result(baseline: 1.5, revised: 2, requested: 2))?
            .hasPrefix("Compared at 75% ") == true)
        #expect(CompareBridge.resolutionNote(of: Self.result(baseline: 2, revised: 2, requested: 2)) == nil)
    }

    @Test("V-080: a result built without the revision's scale takes the baseline's, as before")
    func revisedScaleDefaultsToTheBaseline() {
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let legacy = RevisionComparisonResult(
            baselineLabel: "A", revisedLabel: "B", alignment: .identity,
            autoAlignmentMetrics: nil, autoAlignmentRejection: nil, renderScale: 1.5,
            frame: RasterFrame(boxRect: box, renderedRegion: box, rotation: 0, scale: 1.5, pixelWidth: 15, pixelHeight: 15),
            rasterRegions: [],
            rasterStatistics: RasterDiffStatistics(
                comparedPixelCount: 0, differingPixelCount: 0, addedPixelCount: 0,
                removedPixelCount: 0, groupedRegionCount: 0, discardedRegionCount: 0
            ),
            vector: nil, elapsedNanoseconds: 0, wasTruncated: false, requestedRenderScale: 2
        )
        #expect(legacy.revisedRenderScale == 1.5)
        #expect(legacy.effectiveRenderScale == 1.5)
        #expect(legacy.isResolutionReduced)
    }
}
