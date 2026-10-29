import CoreGraphics
import Foundation
import simd
import Testing
@testable import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFVectorExtraction

/// Bug hunt 2 — low-severity Revision Compare findings, grouped.
struct BugHunt2CompareLowTests {

    /// Old output: `solveThreePoint` returned a finite transform with determinant 0.
    @Test("BH-467: collinear or coincident target picks are refused at solve time")
    func collinearTargetsAreRefused() {
        let sources = [CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 0), CGPoint(x: 0, y: 500)]
        let collinear = [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10), CGPoint(x: 210, y: 10)]
        #expect(throws: AlignmentFault.self) {
            try AlignmentSolver.solveThreePoint(zip(sources, collinear).map { AlignmentCorrespondence(source: $0, target: $1) })
        }
        let coincident = [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 300)]
        do {
            _ = try AlignmentSolver.solveThreePoint(zip(sources, coincident).map { AlignmentCorrespondence(source: $0, target: $1) })
            Issue.record("expected coincidentPoints")
        } catch let AlignmentFault.coincidentPoints(a, b, _) {
            #expect(a == 0 && b == 1)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// Old output: `.rasterTooSmall` for two large rasters of different sizes.
    @Test("BH-468: mismatched raster geometry is named, not reported as too small")
    func mismatchedGeometryIsNamed() throws {
        let a = try GrayImage(width: 200, height: 100, filledWith: 255)
        let b = try GrayImage(width: 201, height: 100, filledWith: 255)
        #expect(VisionAutoAligner.standard.align(moving: a, fixed: b).rejection == .mismatchedGeometry)
    }

    /// Old output: an observation k·H with k = 2 was discarded; the normalised reading left
    /// the off-diagonals unscaled.
    @Test("BH-469: a homography is normalised by H[2][2], and normalised readings rescale the off-diagonals")
    func homographyIsNormalised() {
        var matrix = simd_float3x3(diagonal: SIMD3<Float>(2, 2, 2))
        matrix[2][0] = 20   // tx·k
        matrix[2][1] = -10  // ty·k
        let affine = VisionAutoAligner.affinePart(of: matrix)
        #expect(affine == CGAffineTransform(translationX: 10, y: -5))

        let aligner = VisionAutoAligner(maximumTranslationFraction: 10)
        let observation = CGAffineTransform(a: 1, b: 0.01, c: 0.02, d: 1, tx: 0.001, ty: 0.002)
        let candidates = aligner.screenedInterpretations(of: [observation], width: 600, height: 300).candidates
        #expect(candidates.contains { abs($0.tx - 0.6) < 1e-9 && abs($0.b - 0.005) < 1e-12 && abs($0.c - 0.04) < 1e-12 })
    }

    /// Old output: arithmetic overflow trap in `width * height * 4` / `width * height`.
    @Test("BH-471 / BH-473: overflowing raster sizes throw malformedRaster")
    func overflowingSizesThrow() {
        #expect(throws: CompareFault.self) { try RGBAImage(width: 1 << 40, height: 1 << 40, pixels: []) }
        #expect(throws: CompareFault.self) { try GrayImage(width: 1 << 40, height: 1 << 40, filledWith: 255) }
    }

    /// Old output: plan 600×300 for a sheet the renderer produces as 300×600.
    @Test("BH-472: the plan reports the displayed size of a quarter-turned sheet")
    func planHonoursRotation() throws {
        let box = CGRect(x: 0, y: 0, width: 600, height: 300)
        let upright = try OverlayCompositePlan.fit(pageBox: box, requestedScale: 1, layerCount: 1, maximumPixels: 1_000_000)
        let turned = try OverlayCompositePlan.fit(pageBox: box, requestedScale: 1, layerCount: 1,
                                                  maximumPixels: 1_000_000, rotationDegrees: 90)
        #expect(upright.pixelWidth == 600 && upright.pixelHeight == 300)
        #expect(turned.pixelWidth == 300 && turned.pixelHeight == 600)
        #expect(turned.pixelCount == upright.pixelCount)
    }

    /// Old output: `Int((24 * inf).rounded(.up))` trapped; a decoded margin of −1 indexed the
    /// unsafe buffers at −1.
    @Test("BH-474 / BH-475: tolerances are clamped on construction, decoding and mutation")
    func tolerancesAreClamped() throws {
        #expect(RasterDiffTolerance(strongDifferenceMultiplier: .infinity).strongDifferenceMultiplier == 256)
        let json = #"{"intensityTolerance":-1,"strongDifferenceMultiplier":2,"minimumRegionPixelCount":1,"groupingRadiusPixels":1,"usesEightConnectivity":true,"borderMarginPixels":-1}"#
        let decoded = try JSONDecoder().decode(RasterDiffTolerance.self, from: Data(json.utf8))
        #expect(decoded.borderMarginPixels == 0)
        #expect(decoded.intensityTolerance == 0)

        var mutated = RasterDiffTolerance()
        mutated.borderMarginPixels = -1
        mutated.strongDifferenceMultiplier = .infinity
        let image = try GrayImage(width: 64, height: 64, filledWith: 255)
        let box = CGRect(x: 0, y: 0, width: 64, height: 64)
        let frame = RasterFrame(boxRect: box, renderedRegion: box, rotation: 0, scale: 1, pixelWidth: 64, pixelHeight: 64)
        let outcome = try RasterDiffEngine.diff(
            baseline: image, revised: image, frame: frame, options: RasterDiffOptions(tolerance: mutated)
        )
        #expect(outcome.regions.isEmpty)
    }

    /// Old output: `CompareFault.vectorExtraction(label: "revised", reason: "cancelled")`.
    @Test("BH-477: a cancelled vector extraction surfaces as CompareFault.cancelled")
    func cancelledExtractionIsCancelled() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }
        let source = InProcessRevisionDocumentSource(provider: harness.provider)
        let reference = harness.revised
        let task = Task { () -> (any Error)? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await source.extractGeometry(reference); return nil } catch { return error }
        }
        let error = await task.value
        #expect(error as? CompareFault == .cancelled)
    }
}
