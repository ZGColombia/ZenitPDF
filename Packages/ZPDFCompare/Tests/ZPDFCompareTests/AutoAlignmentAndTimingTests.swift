import CoreGraphics
import Foundation
import Testing
@testable import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// The optional automatic alignment path, and the measured cost of a full-page diff.
struct AutoAlignmentAndTimingTests {

    // MARK: - Vision

    @Test("Vision registration never throws: a failure is a value the caller can act on")
    func visionFailureIsAValue() throws {
        let aligner = VisionAutoAligner.standard
        // Two rasters that share no structure at all. Whatever Vision does with them,
        // the outcome must be one of the documented values.
        let blank = try GrayImage(width: 64, height: 64, filledWith: 255)
        let noisy = try GrayImage(
            width: 64,
            height: 64,
            pixels: (0..<(64 * 64)).map { UInt8(($0 &* 37) % 256) }
        )
        let outcome = aligner.align(moving: noisy, fixed: blank)
        switch outcome {
        case let .accepted(solution, metrics):
            #expect(solution.transform.isFinite)
            #expect(metrics.improvement >= aligner.minimumImprovement)
        case let .rejected(reason, _):
            #expect(AutoAlignmentRejection.allCases.contains(reason))
        }
    }

    @Test("A raster below the minimum edge size is rejected without touching Vision")
    func tooSmallIsRejected() throws {
        let tiny = try GrayImage(width: 8, height: 8, filledWith: 255)
        let outcome = VisionAutoAligner.standard.align(moving: tiny, fixed: tiny)
        #expect(outcome.rejection == .rasterTooSmall)
        #expect(outcome.solution == nil)
    }

    @Test("Two identical rasters cannot be improved, so the candidate is rejected")
    func identicalRastersYieldNoImprovement() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let page = try await harness.comparator.render(harness.baseline, scale: 1)
        let outcome = VisionAutoAligner.standard.align(moving: page.image, fixed: page.image)
        // Nothing to gain: the mean absolute difference is already zero, so no candidate
        // can clear the improvement threshold and manual alignment stays available.
        #expect(outcome.solution == nil)
        if let metrics = outcome.metrics {
            #expect(metrics.meanAbsoluteDifferenceBefore == 0)
        }
    }

    @Test("Every candidate interpretation of an observation is finite and plausibly bounded")
    func candidateInterpretationsAreBounded() {
        let aligner = VisionAutoAligner(maximumTranslationFraction: 0.1)
        let observations = [
            CGAffineTransform(translationX: 12, y: -8),
            CGAffineTransform(translationX: 10_000, y: 0),      // implausible: dropped
            CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0) // singular: dropped
        ]
        let candidates = aligner.screenedInterpretations(of: observations, width: 600, height: 800).candidates
        let diagonal = hypot(600.0, 800.0)
        #expect(!candidates.isEmpty)
        for candidate in candidates {
            #expect(candidate.isFinite)
            #expect(hypot(candidate.tx, candidate.ty) <= diagonal * 0.1 + 1e-9)
        }
        // The implausible and the singular observation contributed nothing.
        #expect(candidates.count <= 4)
    }

    @Test("The automatic plan runs page-box matching first and reports its provenance")
    func automaticPlanUsesPageBoxFirst() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline,
                revised: harness.revised,
                renderScale: 2,
                alignment: .automatic(AutoAlignmentPlan(usesVisionRegistration: false)),
                raster: RasterDiffOptions(tolerance: .strict)
            )
        )
        #expect(result.alignment.provenance == .pageBox)
        #expect(result.alignment.transform.isIdentity())
        #expect(result.autoAlignmentMetrics == nil)
        #expect(result.autoAlignmentRejection == nil)
        #expect(result.rasterRegions.count == 1)
    }

    @Test("Enabling Vision on an already-aligned pair changes nothing it should not")
    func visionRefinementIsHarmlessWhenAlreadyAligned() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline,
                revised: harness.revised,
                renderScale: 1,
                alignment: .automatic(AutoAlignmentPlan(usesVisionRegistration: true)),
                raster: RasterDiffOptions(tolerance: .strict)
            )
        )
        // Either Vision was rejected — the normal outcome on two already-aligned
        // sheets — or it was accepted after measurably improving the match. Either way
        // the one real difference is still found and still in the right place.
        #expect(result.autoAlignmentMetrics != nil)
        #expect(result.rasterRegions.count >= 1)
        let added = try #require(result.rasterRegions.first { $0.classification == .added })
        #expect(
            rectsAreEqual(added.pageBounds, RevisionCorpus.addedEdge.inkRect, tolerance: 1),
            "added region was \(describe(added.pageBounds))"
        )
        if result.autoAlignmentRejection == nil {
            #expect(result.alignment.provenance == .automaticVision)
            // CR-131 follow-up: the page-space re-wrap used to drop the gray-level
            // dissimilarity Vision measured, so every accepted Vision alignment reported
            // `nil` here (old output: `pixelDissimilarity → nil`).
            #expect(result.alignment.pixelDissimilarity != nil,
                    "an accepted Vision alignment carries the dissimilarity it was accepted on")
            #expect(result.alignment.pixelDissimilarity == result.autoAlignmentMetrics?.meanAbsoluteDifferenceAfter)
        }
    }

    // MARK: - Timing

    @Test("Full-page diff timing, printed")
    func fullPageDiffTiming() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-timing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ZPDFFixtures.make(.titleBlockSheet, in: directory)

        let provider = PDFKitDocumentProvider()
        defer { Task { await provider.closeAll() } }
        let document = try await provider.open(fileAt: fixture.url)
        let comparator = RevisionComparator(source: InProcessRevisionDocumentSource(provider: provider))
        let reference = RevisionPageReference(
            document: document.handle, pageIndex: 0, box: .crop,
            fileURL: fixture.url, label: "timing"
        )

        // Warm the caches so the number is the diff, not the first-touch cost.
        _ = try await comparator.compare(
            RevisionCompareRequest(
                baseline: reference, revised: reference, renderScale: 2, alignment: .identity
            )
        )

        for scale in [1.0, 2.0, 3.0] {
            let result = try await comparator.compare(
                RevisionCompareRequest(
                    baseline: reference,
                    revised: reference,
                    renderScale: scale,
                    alignment: .identity,
                    raster: RasterDiffOptions(tolerance: .strict)
                )
            )
            let megapixels = Double(result.frame.pixelCount) / 1_000_000
            print(
                String(
                    format:
                        "ZPDFCompare timing — %@ at scale %.0f: %d x %d px (%.2f Mpx), "
                        + "render + align + raster diff + vector diff in %.1f ms (%.1f Mpx/s), "
                        + "%d differences",
                    fixture.manifest.fileName,
                    scale,
                    result.frame.pixelWidth,
                    result.frame.pixelHeight,
                    megapixels,
                    result.elapsedSeconds * 1000,
                    megapixels / max(result.elapsedSeconds, 1e-9),
                    result.differenceCount
                )
            )
            #expect(result.elapsedNanoseconds > 0)
            #expect(result.differenceCount == 0)
        }
    }

    @Test("Raster diff throughput on a 4 megapixel page, printed")
    func rasterDiffThroughput() throws {
        let width = 2000
        let height = 2000
        var baselinePixels = [UInt8](repeating: 255, count: width * height)
        var revisedPixels = baselinePixels
        // A drawing-like sheet: 200 horizontal rules, one of which moves.
        for line in 0..<200 {
            let y = line * 10 + 4
            for x in 100..<1900 {
                baselinePixels[y * width + x] = 0
                revisedPixels[(line == 100 ? y + 3 : y) * width + x] = 0
            }
        }
        let baseline = try GrayImage(width: width, height: height, pixels: baselinePixels)
        let revised = try GrayImage(width: width, height: height, pixels: revisedPixels)
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            renderedRegion: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            rotation: 0, scale: 2, pixelWidth: width, pixelHeight: height
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let outcome = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame,
            options: RasterDiffOptions(tolerance: .standard)
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        print(
            String(
                format: "ZPDFCompare timing — raster diff of %d x %d px (%.1f Mpx) in %.1f ms "
                    + "(%.1f Mpx/s), %d regions",
                width, height, Double(width * height) / 1_000_000,
                elapsed * 1000,
                Double(width * height) / 1_000_000 / max(elapsed, 1e-9),
                outcome.regions.count
            )
        )
        // One line moved by 3 px: the two differing strips are adjacent, so the grouping
        // dilation reports them as a single changed region.
        #expect(outcome.regions.count == 1)
        #expect(outcome.regions.first?.classification == .changed)
    }
}
