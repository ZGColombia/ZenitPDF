import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge

@testable import ZPDFCompare

/// Iteration 1, render-extract-search: the Compare package's smaller findings.
@Suite("Compare: budget fit, alignment rejection, frames and labels (R-154, R-156, R-160, R-161)", .serialized)
struct CompareIterationOneTests {

    /// A 256 × 256 sheet of dark blocks placed by a fixed linear-congruential rule, and the
    /// same sheet shifted right by `dx` and down by `dy` pixels.
    private static func blockSheets(dx: Int, dy: Int) throws -> (fixed: GrayImage, moving: GrayImage) {
        let side = 256
        var fixed = [UInt8](repeating: 255, count: side * side)
        var moving = fixed
        var state: UInt32 = 0x1234_5678
        func next(_ bound: Int) -> Int {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Int(state >> 8) % bound
        }
        for _ in 0..<60 {
            let x = next(side - 40), y = next(side - 40), w = 6 + next(24), h = 6 + next(24)
            for row in y..<(y + h) {
                for column in x..<(x + w) {
                    fixed[row * side + column] = 0
                    let mx = column + dx, my = row + dy
                    if mx < side, my < side { moving[my * side + mx] = 0 }
                }
            }
        }
        return (try GrayImage(width: side, height: side, pixels: fixed),
                try GrayImage(width: side, height: side, pixels: moving))
    }

    // MARK: - R-160

    /// Old output: `.rejected(.transformUnusable, …)` — documented as a non-finite or
    /// non-invertible coefficient — for a registration whose only fault was a shift beyond
    /// the plausible limit.
    @Test("R-160: a registration dropped only for its shift is rejected as translationImplausible")
    func implausibleShiftIsNamed() throws {
        let sheets = try Self.blockSheets(dx: 24, dy: 16)
        // Control: at the default limit (a quarter of the diagonal) the same pair aligns, so
        // Vision did observe the shift.
        let accepted = VisionAutoAligner.standard.align(moving: sheets.moving, fixed: sheets.fixed)
        #expect(accepted.solution != nil, "\(String(describing: accepted.rejection))")
        // A limit of 1 % of the 362 px diagonal is 3.6 px, far below the 28.8 px shift.
        let strict = VisionAutoAligner(maximumTranslationFraction: 0.01)
        let outcome = strict.align(moving: sheets.moving, fixed: sheets.fixed)
        #expect(outcome.rejection == .translationImplausible)
    }

    @Test("R-160: readings that are unusable for another reason keep transformUnusable")
    func unusableReadingsStayUnusable() {
        let aligner = VisionAutoAligner(maximumTranslationFraction: 0.01)
        let far = aligner.screenedInterpretations(
            of: [CGAffineTransform(translationX: 200, y: 0)], width: 256, height: 256
        )
        #expect(far.candidates.isEmpty && far.implausibleTranslations > 0)
        let singular = aligner.screenedInterpretations(
            of: [CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 1, ty: 1)], width: 256, height: 256
        )
        #expect(singular.candidates.isEmpty && singular.implausibleTranslations == 0)
    }

    // MARK: - R-154

    /// Old output: `labels` was `[Int]`, 8 bytes a pixel — 512 MB at the 64 M-pixel budget.
    @Test("R-154: component labels take 4 bytes a pixel and still separate every component")
    func labelsAreFourBytes() {
        // Two blobs and a lone pixel on an 8 × 4 mask, 4-connected:
        //   1 1 . . . . . .
        //   1 . . . 2 2 . .
        //   . . . . 2 2 . 3
        //   . . . . . . . .
        let width = 8, height = 4
        var mask = [UInt8](repeating: 0, count: width * height)
        for (x, y) in [(0, 0), (1, 0), (0, 1), (4, 1), (5, 1), (4, 2), (5, 2), (7, 2)] { mask[y * width + x] = 1 }
        let labelling = RasterDiffEngine.label(grouping: mask, width: width, height: height, eightConnected: false)
        #expect(MemoryLayout<RasterDiffEngine.ComponentLabelling>.size > 0)
        #expect(MemoryLayout.stride(ofValue: labelling.labels[0]) == 4)
        #expect(labelling.count == 3)
        #expect(labelling.labels[0] == 1 && labelling.labels[1] == 1 && labelling.labels[width] == 1)
        #expect(labelling.labels[width + 4] == 2 && labelling.labels[2 * width + 5] == 2)
        #expect(labelling.labels[2 * width + 7] == 3)
        #expect(RasterDiffEngine.maximumLabelledPixels == Int(Int32.max))
    }

    // MARK: - R-156

    /// Old output: `CompareFault.pixelBudgetExceeded` — `compare()` rendered both pages at the
    /// requested scale with no fit, so a sheet over the budget failed outright while Overlay
    /// fitted the same sheet and succeeded.
    @Test("R-156: a sheet over the raster budget is compared at a stated, reduced resolution")
    func overBudgetSheetIsComparedAtAReducedScale() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }
        let box = try await harness.comparator.pageBox(of: harness.baseline)
        // A budget a quarter of what the page needs at the requested scale.
        let requested = 2.0
        let budget = Int(Double(box.width) * Double(box.height) * requested * requested / 4)

        let result = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline,
                revised: harness.revised,
                renderScale: requested,
                alignment: .identity,
                raster: RasterDiffOptions(tolerance: .strict, maximumPixels: budget)
            )
        )
        #expect(result.requestedRenderScale == requested)
        #expect(result.isResolutionReduced)
        // By hand: a quarter of the pixels is half the scale, less the rounding margin.
        #expect(result.renderScale <= 1.0 && result.renderScale > 0.95, "\(result.renderScale)")
        #expect(result.frame.pixelCount <= budget)
        #expect(result.rasterRegions.count == 1, "the added edge is still found")

        // Within budget nothing changes.
        let full = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline, revised: harness.revised,
                renderScale: requested, alignment: .identity, raster: RasterDiffOptions(tolerance: .strict)
            )
        )
        #expect(full.renderScale == requested)
        #expect(!full.isResolutionReduced)
    }

    // MARK: - R-161

    @Test("R-161: the frame's page-to-display mapping is the renderer's, for every /Rotate")
    func frameMappingIsTheSharedOne() {
        let box = CGRect(x: 10, y: 20, width: 600, height: 400)
        let probes = [CGPoint(x: 10, y: 20), CGPoint(x: 610, y: 20), CGPoint(x: 300, y: 250), CGPoint(x: 610, y: 420)]
        for rotation in [0, 90, 180, 270] {
            let frame = RasterFrame(
                boxRect: box, renderedRegion: box, rotation: rotation, scale: 2,
                pixelWidth: rotation % 180 == 0 ? 1200 : 800, pixelHeight: rotation % 180 == 0 ? 800 : 1200
            )
            let shared = PageDisplayGeometry.pageToDisplay(box: box, rotation: rotation)
            for probe in probes {
                let ours = frame.pageToDisplay.apply(to: probe)
                let theirs = probe.applying(shared)
                #expect(abs(ours.x - theirs.x) < 1e-9 && abs(ours.y - theirs.y) < 1e-9, "\(rotation) \(probe)")
            }
        }
    }
}
