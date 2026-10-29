import CoreGraphics
import Foundation
import Testing
@testable import ZPDFCompare

/// One test per finding in the CR-130 … CR-146 block that this package owns.
struct FindingsRegressionTests {

    // MARK: - CR-130 — both engines walk the sheet the same way

    /// The vector list is ordered in page space and the raster list is ordered in pixel
    /// space, and the two spaces disagree about which way is up. One "next difference"
    /// button steps through both.
    ///
    /// Old code: the raster regions came back top-first (as here) and the vector regions
    /// bottom-first, so the walk went down the sheet and then back up it. The vector half
    /// of this assertion is the one that failed —
    /// `Expectation failed: (tops → [290.0, 450.0, 600.0]) == (tops.sorted(by: >) →
    /// [600.0, 450.0, 290.0])` in `VectorDiffTests.allMutationsAreSeparated`.
    @Test("Raster regions are ordered top of the sheet first in page space")
    func rasterRegionsAreTopFirstInPageSpace() throws {
        let frame = RasterDiffTests.letterFrame()
        let width = frame.pixelWidth
        let height = frame.pixelHeight
        let baseline = try RasterDiffTests.canvas(width: width, height: height)
        // Three separate marks down the page, in pixel space: near the top, the middle
        // and the bottom.
        let revised = try RasterDiffTests.canvas(
            width: width, height: height,
            marks: [
                (CGRect(x: 100, y: 80, width: 40, height: 40), 0),
                (CGRect(x: 100, y: 380, width: 40, height: 40), 0),
                (CGRect(x: 100, y: 680, width: 40, height: 40), 0)
            ]
        )
        let outcome = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame, options: .standard
        )
        #expect(outcome.regions.count == 3)
        let tops = outcome.regions.map { Double($0.pageBounds.maxY) }
        #expect(tops == tops.sorted(by: >), "raster order in page space: \(tops)")
    }

    // MARK: - CR-137 — the margin is not compared, so it is not counted

    /// Old code: `comparedPixelCount = width * height` whatever the margin was, so under
    /// the `.scanned` preset — which skips a two-pixel border — the differing fraction
    /// was divided by more pixels than were ever looked at. Measured on this fixture:
    /// `Expectation failed: (outcome.statistics.comparedPixelCount → 10000) == (inside →
    /// 9216)` and `(differingFraction → 0.04) == (… → 0.043402777777777776)`.
    @Test("comparedPixelCount counts the pixels inside the border margin, not the whole page")
    func comparedPixelCountHonoursTheMargin() throws {
        let side = 100
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            renderedRegion: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotation: 0, scale: 1, pixelWidth: side, pixelHeight: side
        )
        let baseline = try RasterDiffTests.canvas(width: side, height: side)
        let revised = try RasterDiffTests.canvas(
            width: side, height: side,
            marks: [(CGRect(x: 20, y: 20, width: 20, height: 20), 0)]
        )
        var options = RasterDiffOptions.standard
        options.tolerance = .scanned
        let margin = options.tolerance.borderMarginPixels
        #expect(margin == 2, "the preset this finding is about")

        let outcome = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame, options: options
        )
        let inside = (side - 2 * margin) * (side - 2 * margin)
        #expect(outcome.statistics.comparedPixelCount == inside)
        #expect(
            outcome.statistics.differingFraction
                == Double(outcome.statistics.differingPixelCount) / Double(inside)
        )
    }

    /// A margin wider than the page compares nothing, and nothing is not "the whole page".
    @Test("A margin that swallows the page reports zero compared pixels")
    func marginWiderThanThePageComparesNothing() throws {
        let side = 8
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            renderedRegion: CGRect(x: 0, y: 0, width: 8, height: 8),
            rotation: 0, scale: 1, pixelWidth: side, pixelHeight: side
        )
        let baseline = try RasterDiffTests.canvas(width: side, height: side)
        let revised = try RasterDiffTests.canvas(
            width: side, height: side, marks: [(CGRect(x: 0, y: 0, width: 8, height: 8), 0)]
        )
        var options = RasterDiffOptions.standard
        options.tolerance = RasterDiffTolerance(borderMarginPixels: 16)
        let outcome = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame, options: options
        )
        #expect(outcome.statistics.comparedPixelCount == 0)
        #expect(outcome.statistics.differingPixelCount == 0)
        #expect(outcome.statistics.differingFraction == 0)
    }

    // MARK: - CR-139 — provenance names the solve that happened

    /// Old code: `provenance: .manualTwoPoint` for a translation solve, so the record of
    /// how an alignment was obtained claimed a similarity had been fitted to two points
    /// when one pair had produced a pure offset. Measured:
    /// `Expectation failed: (solution.provenance → .manualTwoPoint) == .manualTranslation`.
    @Test("A translation solve reports manualTranslation, not manualTwoPoint")
    func translationSolveReportsItsOwnProvenance() throws {
        let solution = try AlignmentSolver.solveTranslation([
            AlignmentCorrespondence(source: CGPoint(x: 10, y: 10), target: CGPoint(x: 40, y: 25))
        ])
        #expect(solution.provenance == .manualTranslation)
        #expect(solution.model == .translation)

        // The similarity solver keeps the case it always had.
        let similarity = try AlignmentSolver.solveTwoPoint([
            AlignmentCorrespondence(source: CGPoint(x: 0, y: 0), target: CGPoint(x: 10, y: 10)),
            AlignmentCorrespondence(source: CGPoint(x: 100, y: 0), target: CGPoint(x: 110, y: 10))
        ])
        #expect(similarity.provenance == .manualTwoPoint)
    }

    // MARK: - CR-131 — page points and gray levels are different fields

    /// Old code: the automatic aligner put its mean absolute gray-level difference into
    /// `AlignmentResidual.rootMeanSquare`, whose documented unit is page points. Every
    /// reader of that field — a tolerance, a warning, an export — read a `0…255`
    /// intensity as a distance on the sheet.
    @Test("A solution carries a pixel dissimilarity separately from its page-point residual")
    func pixelDissimilarityIsItsOwnField() {
        let measured = AlignmentSolution(
            transform: .identity,
            model: .affine,
            provenance: .automaticVision,
            residual: .zero,
            correspondenceCount: 0,
            conditioning: 0.4,
            pixelDissimilarity: 7.5
        )
        #expect(measured.residual.rootMeanSquare == 0, "no correspondences, no page-point residual")
        #expect(measured.pixelDissimilarity == 7.5)

        // A point solve has a page-point residual and no pixel measurement at all.
        #expect(AlignmentSolution.identity.pixelDissimilarity == nil)
    }

    /// And the aligner that produced the confusion now fills the right field.
    ///
    /// Old code: `residual: AlignmentResidual(rootMeanSquare: winner.difference, maximum:
    /// winner.difference, …)` — the gray level, in the field documented in page points.
    /// With the shifted pair below Vision recovers the offset and the remaining
    /// dissimilarity is non-zero, so the old code reported a page-point residual for an
    /// alignment that is in fact good to a pixel. Measured:
    /// `Expectation failed: (solution.residual → AlignmentResidual(rootMeanSquare:
    /// 0.3125, maximum: 0.3125, perCorrespondence: [])) == (.zero → …)` and
    /// `(solution.pixelDissimilarity → nil) == (metrics.meanAbsoluteDifferenceAfter →
    /// 0.3125)`.
    @Test("An accepted Vision alignment reports gray levels as gray levels")
    func visionAlignmentReportsItsMeasurementInTheRightField() throws {
        func canvas(shiftedBy dx: Int) throws -> GrayImage {
            let side = 256
            var pixels = [UInt8](repeating: 245, count: side * side)
            // Strong, asymmetric structure: two bars and a block, so the registration has
            // something to lock on to and only one plausible offset.
            for y in 40..<90 {
                for x in (50 + dx)..<(190 + dx) where x >= 0 && x < side { pixels[y * side + x] = 10 }
            }
            for y in 120..<135 {
                for x in (60 + dx)..<(120 + dx) where x >= 0 && x < side { pixels[y * side + x] = 30 }
            }
            for y in 160..<220 {
                for x in (150 + dx)..<(180 + dx) where x >= 0 && x < side { pixels[y * side + x] = 0 }
            }
            return try GrayImage(width: side, height: side, pixels: pixels)
        }

        let outcome = VisionAutoAligner.standard.align(
            moving: try canvas(shiftedBy: 8), fixed: try canvas(shiftedBy: 0)
        )
        guard case let .accepted(solution, metrics) = outcome else {
            Issue.record("the shifted pair must be alignable: \(outcome)")
            return
        }
        #expect(solution.correspondenceCount == 0)
        #expect(solution.residual == .zero,
                "no correspondences were solved, so there is no page-point residual")
        #expect(solution.pixelDissimilarity == metrics.meanAbsoluteDifferenceAfter,
                "the gray level goes in the field documented in gray levels")
    }

    // MARK: - CR-138 — the base layer's alignment is not silently discarded

    /// Old code: `alignments.count` was validated and `alignments[0]` was then never
    /// read. A caller who supplied a real transform for the bottom layer got a composite
    /// in which that one layer had not moved, with nothing said about it. Measured:
    /// `Issue recorded: a non-identity base alignment cannot be accepted silently` — the
    /// call returned a finished `OverlayComposite`.
    ///
    /// The base page defines the frame every other layer is warped into, so applying a
    /// transform to it would move the target the rest are aimed at. Only the identity is
    /// meaningful, and anything else is refused.
    @Test("A non-identity alignment on the base overlay layer is refused, not ignored")
    func nonIdentityBaseAlignmentIsRefused() async throws {
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let model = RevisionOverlayModel.testStack(labels: ["baseline", "revised"])
        do {
            _ = try await harness.comparator.overlay(
                references: [harness.baseline, harness.revised],
                alignments: [AlignmentTransform.translation(dx: 12, dy: -8), .identity],
                model: model,
                scale: 1.0
            )
            Issue.record("a non-identity base alignment cannot be accepted silently")
        } catch let fault as CompareFault {
            guard case .overlayLayerMismatch(let reason) = fault else {
                Issue.record("expected .overlayLayerMismatch, got \(fault)")
                return
            }
            #expect(reason.contains("base layer"), "the reason names the layer: \(reason)")
        }

        // The identity is still accepted, so the fix refuses a lie rather than the feature.
        let composite = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised],
            alignments: [.identity, .identity],
            model: model,
            scale: 1.0
        )
        #expect(composite.contributingLayerIDs.count == 2)
    }

    // MARK: - CR-146 — a pivot failure after passing conditioning is degenerate input

    /// Old code: `singularSystem`, which this package documents as a bug in us. The
    /// conditioning gate had already passed, so the honest report is that the points are
    /// degenerate to within the arithmetic. Measured:
    /// `Issue recorded: expected .degenerateConfiguration, got singularSystem(model:
    /// ZPDFCompare.AlignmentModel.affine)`.
    @Test("A 3x3 solve that fails after passing conditioning is a degenerate configuration")
    func pivotFailureAfterConditioningIsDegenerate() {
        // A perfect right triangle — conditioning 1, the best score there is — whose
        // coordinates are large enough that the normal equations cannot be solved: the
        // Gram matrix mixes terms of order 1e20 with the constant row, and the third
        // pivot is lost to cancellation long before it reaches the pivot tolerance. The
        // conditioning gate cannot see this, because conditioning is scale-invariant by
        // construction and the arithmetic is not.
        let far = 1e10
        let correspondences = [
            AlignmentCorrespondence(source: CGPoint(x: 0, y: 0), target: CGPoint(x: 0, y: 0)),
            AlignmentCorrespondence(source: CGPoint(x: far, y: 0), target: CGPoint(x: far, y: 0)),
            AlignmentCorrespondence(source: CGPoint(x: 0, y: far), target: CGPoint(x: 0, y: far))
        ]
        #expect(
            AlignmentConditioning.affine(correspondences) >= AlignmentConditioning.minimum,
            "the conditioning gate must pass, or this is not the case the finding is about"
        )
        do {
            _ = try AlignmentSolver.solveThreePoint(correspondences)
            Issue.record("this configuration cannot produce a usable affine map")
        } catch let fault as AlignmentFault {
            guard case .degenerateConfiguration = fault else {
                Issue.record("expected .degenerateConfiguration, got \(fault)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
