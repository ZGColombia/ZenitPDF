import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
import ZPDFTestingSupport

import ZPDFCompare

/// Iteration 5 (V-080): each page of a comparison is fitted to the
/// raster budget on its own box, and the result's reduced-resolution flag read the baseline's
/// scale alone.
@Suite("Compare: a revision fitted to the budget on its own is reported (V-080)", .serialized)
struct Iter5CompareRevisedScaleTests {

    /// The corpus baseline on its own sheet, and the same drawing on a sheet four times as wide
    /// (an extended roll), written side by side.
    private static func longRevisionPair() throws -> RevisionPair {
        let box = try RevisionCorpus.mediaBox()
        let edges = try RevisionCorpus.baselineEdges()
        let long = FixtureRect(llx: box.llx, lly: box.lly, urx: box.llx + (box.urx - box.llx) * 4, ury: box.ury)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baselineURL = directory.appendingPathComponent("baseline.pdf")
        let revisedURL = directory.appendingPathComponent("revised.pdf")
        try RevisionPDFWriter.data(mediaBox: box, edges: edges).write(to: baselineURL, options: .atomic)
        try RevisionPDFWriter.data(mediaBox: long, edges: edges).write(to: revisedURL, options: .atomic)
        return RevisionPair(
            mediaBox: box, baselineEdges: edges, revisedEdges: edges,
            baselineURL: baselineURL, revisedURL: revisedURL, directory: directory
        )
    }

    /// Old output: `renderScale == 2`, `isResolutionReduced == false` — the revision was
    /// rendered at about 1.0 and resampled into the baseline's frame, and nothing said so.
    @Test("V-080: a revision over the budget, with a baseline inside it, marks the comparison reduced")
    func overBudgetRevisionIsReported() async throws {
        let pair = try Self.longRevisionPair()
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair, includeVector: false)
        defer { Task { await harness.close() } }
        let box = try await harness.comparator.pageBox(of: harness.baseline)
        let requested = 2.0
        // The baseline's pixels at the requested scale, with a pixel of slack on each side:
        // the baseline fits as asked.
        let budget = Int((Double(box.width) * requested + 2) * (Double(box.height) * requested + 2))

        let result = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline,
                revised: harness.revised,
                renderScale: requested,
                alignment: .identity,
                raster: RasterDiffOptions(tolerance: .strict, maximumPixels: budget),
                includesVectorSignal: false
            )
        )

        #expect(result.renderScale == requested, "the baseline was rendered as asked")
        // By hand: the revision is four times the baseline's area, so at scale t it needs
        // 4·w·h·t² pixels against a budget of about 4·w·h — t is about 1, half the request.
        #expect(result.revisedRenderScale > 0.95 && result.revisedRenderScale < 1.05, "\(result.revisedRenderScale)")
        #expect(result.effectiveRenderScale == result.revisedRenderScale)
        #expect(result.isResolutionReduced)
    }

    @Test("V-080: two sheets inside the budget are compared as asked, and say so")
    func inBudgetPairIsNotReduced() async throws {
        let pair = try Self.longRevisionPair()
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair, includeVector: false)
        defer { Task { await harness.close() } }

        let result = try await harness.compare(scale: 1, includesVectorSignal: false)

        #expect(result.renderScale == 1)
        #expect(result.revisedRenderScale == 1)
        #expect(!result.isResolutionReduced)
    }
}
