import CoreGraphics
import Foundation
import Testing
import ZPDFCompare

/// Manual and automatic alignment.
///
/// The rule under test throughout: a solver either recovers the transform it was given
/// to within a stated tolerance, or it says loudly that it could not. There is no third
/// outcome, and in particular there is no "plausible-looking transform with a residual
/// nobody looked at".
struct AlignmentTests {

    /// An A1 sheet, so that "recovered to within 0.001 pt" is a statement about a real
    /// sheet rather than about a unit square.
    static let sheet = CGRect(x: 0, y: 0, width: 1683.78, height: 2383.94)

    private func correspondences(
        from transform: AlignmentTransform,
        sourcePoints: [CGPoint]
    ) -> [AlignmentCorrespondence] {
        sourcePoints.map { AlignmentCorrespondence(source: $0, target: transform.apply(to: $0)) }
    }

    // MARK: - Two-point

    @Test("Two-point alignment recovers a known translation, rotation and uniform scale")
    func twoPointRecoversKnownSimilarity() throws {
        let truth = AlignmentTransform.similarity(
            scale: 1.041_666_666_666_666_7,
            rotationRadians: 0.031_415_926_535_897_93,
            translation: CGPoint(x: -37.5, y: 112.25)
        )
        let solution = try AlignmentSolver.solveTwoPoint(
            correspondences(
                from: truth,
                sourcePoints: [CGPoint(x: 120, y: 160), CGPoint(x: 1520, y: 2180)]
            )
        )

        #expect(solution.model == .similarity)
        #expect(solution.provenance == .manualTwoPoint)
        #expect(solution.correspondenceCount == 2)
        // Exactly determined, so the residual is zero to floating-point noise.
        #expect(solution.residual.rootMeanSquare < 1e-9)
        #expect(solution.residual.maximum < 1e-9)
        // The stated tolerance: one micrometre of PDF point anywhere on an A1 sheet.
        let deviation = solution.transform.maximumDeviation(from: truth, over: Self.sheet)
        #expect(deviation < 1e-6, "recovered transform deviates by \(deviation) pt")
        #expect(abs(solution.scale - 1.041_666_666_666_666_7) < 1e-12)
        #expect(abs(solution.rotationDegrees - 1.8) < 1e-9)
    }

    @Test("Two-point alignment is exact for a pure translation and a pure rotation")
    func twoPointHandlesDegenerateFamilies() throws {
        let translation = AlignmentTransform.translation(dx: 41.5, dy: -19.25)
        let translationSolution = try AlignmentSolver.solveTwoPoint(
            correspondences(
                from: translation,
                sourcePoints: [CGPoint(x: 10, y: 10), CGPoint(x: 900, y: 1400)]
            )
        )
        #expect(translationSolution.transform.maximumDeviation(from: translation, over: Self.sheet) < 1e-9)
        #expect(abs(translationSolution.scale - 1) < 1e-12)

        let quarterTurn = AlignmentTransform.similarity(
            scale: 1, rotationRadians: .pi / 2, translation: CGPoint(x: 0, y: 0)
        )
        let rotationSolution = try AlignmentSolver.solveTwoPoint(
            correspondences(
                from: quarterTurn,
                sourcePoints: [CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 700)]
            )
        )
        #expect(rotationSolution.transform.maximumDeviation(from: quarterTurn, over: Self.sheet) < 1e-9)
    }

    @Test("Two coincident picks are refused rather than solved")
    func twoPointRefusesCoincidentPicks() {
        let pairs = [
            AlignmentCorrespondence(source: CGPoint(x: 100, y: 100), target: CGPoint(x: 110, y: 100)),
            AlignmentCorrespondence(
                source: CGPoint(x: 100.000_1, y: 100), target: CGPoint(x: 110, y: 100)
            )
        ]
        #expect(throws: AlignmentFault.self) { try AlignmentSolver.solveTwoPoint(pairs) }
    }

    @Test("One point pair is not enough for the similarity model")
    func twoPointNeedsTwoPairs() {
        let pairs = [
            AlignmentCorrespondence(source: CGPoint(x: 1, y: 1), target: CGPoint(x: 2, y: 2))
        ]
        #expect(throws: AlignmentFault.self) { try AlignmentSolver.solveTwoPoint(pairs) }
    }

    // MARK: - Three-point

    @Test("Three-point alignment recovers a known affine map, shear included")
    func threePointRecoversKnownAffine() throws {
        // Non-uniform scale plus shear: nothing the similarity model could represent.
        let truth = AlignmentTransform(a: 1.02, b: 0.014, c: -0.031, d: 0.985, tx: 12.5, ty: -8.25)
        let solution = try AlignmentSolver.solveThreePoint(
            correspondences(
                from: truth,
                sourcePoints: [
                    CGPoint(x: 100, y: 120),
                    CGPoint(x: 1500, y: 180),
                    CGPoint(x: 240, y: 2100)
                ]
            )
        )

        #expect(solution.model == .affine)
        #expect(solution.provenance == .manualThreePoint)
        #expect(solution.residual.maximum < 1e-8)
        let deviation = solution.transform.maximumDeviation(from: truth, over: Self.sheet)
        #expect(deviation < 1e-6, "recovered affine deviates by \(deviation) pt")
    }

    @Test("Three collinear picks are refused: the non-collinear validation of spec 19.2")
    func threePointRefusesCollinearPicks() {
        let pairs = [
            AlignmentCorrespondence(source: CGPoint(x: 100, y: 100), target: CGPoint(x: 100, y: 100)),
            AlignmentCorrespondence(source: CGPoint(x: 400, y: 400), target: CGPoint(x: 400, y: 400)),
            AlignmentCorrespondence(source: CGPoint(x: 900, y: 900), target: CGPoint(x: 900, y: 900))
        ]
        #expect(throws: AlignmentFault.self) { try AlignmentSolver.solveThreePoint(pairs) }
        #expect(AlignmentConditioning.affine(pairs) < AlignmentConditioning.minimum)
    }

    @Test("Conditioning is 1 for two distinct picks and near 0.87 for an equilateral triple")
    func conditioningFormula() {
        let twoPicks = [
            AlignmentCorrespondence(source: CGPoint(x: 0, y: 0), target: .zero),
            AlignmentCorrespondence(source: CGPoint(x: 300, y: 400), target: .zero)
        ]
        #expect(abs(AlignmentConditioning.similarity(twoPicks) - 1) < 1e-12)

        let equilateral = [
            AlignmentCorrespondence(source: CGPoint(x: 0, y: 0), target: .zero),
            AlignmentCorrespondence(source: CGPoint(x: 100, y: 0), target: .zero),
            AlignmentCorrespondence(source: CGPoint(x: 50, y: 86.602_540_378_443_86), target: .zero)
        ]
        #expect(abs(AlignmentConditioning.affine(equilateral) - 0.866_025_403_784_438_6) < 1e-9)
    }

    // MARK: - Residual on mismatched pages

    @Test("Genuinely mismatched pages produce a large residual, not a quiet bad transform")
    func mismatchedPagesReportLargeResidual() throws {
        // Four picks that no similarity and no affine map can satisfy: the fourth target
        // is 300 pt away from where the first three force it to be. This is what picking
        // features on two different sheets actually looks like.
        let pairs = [
            AlignmentCorrespondence(source: CGPoint(x: 100, y: 100), target: CGPoint(x: 100, y: 100)),
            AlignmentCorrespondence(source: CGPoint(x: 1100, y: 100), target: CGPoint(x: 1100, y: 100)),
            AlignmentCorrespondence(source: CGPoint(x: 100, y: 1100), target: CGPoint(x: 100, y: 1100)),
            AlignmentCorrespondence(source: CGPoint(x: 1100, y: 1100), target: CGPoint(x: 800, y: 1400))
        ]

        let similarity = try AlignmentSolver.solveTwoPoint(pairs)
        #expect(similarity.residual.rootMeanSquare > 50,
                "similarity RMS was only \(similarity.residual.rootMeanSquare) pt")
        #expect(similarity.residual.perCorrespondence.count == 4)

        let affine = try AlignmentSolver.solveThreePoint(pairs)
        #expect(affine.residual.rootMeanSquare > 50,
                "affine RMS was only \(affine.residual.rootMeanSquare) pt")
        // The affine model has more freedom, so it must fit at least as well.
        #expect(affine.residual.rootMeanSquare <= similarity.residual.rootMeanSquare + 1e-9)
    }

    @Test("A well-matched page with one sloppy pick keeps a small but non-zero residual")
    func sloppyPickIsVisibleInTheResidual() throws {
        let truth = AlignmentTransform.similarity(
            scale: 1, rotationRadians: 0, translation: CGPoint(x: 10, y: -5)
        )
        var pairs = correspondences(
            from: truth,
            sourcePoints: [CGPoint(x: 100, y: 100), CGPoint(x: 1400, y: 100), CGPoint(x: 100, y: 2000)]
        )
        pairs[2].target.x += 3
        let solution = try AlignmentSolver.solveTwoPoint(pairs)
        #expect(solution.residual.rootMeanSquare > 0.3)
        #expect(solution.residual.rootMeanSquare < 3)
        #expect(solution.residual.maximum < 3)
    }

    // MARK: - Page-box path

    @Test("Identical page boxes align to the identity with zero residual")
    func pageBoxIdentity() {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let solution = PageBoxAligner.align(baselineBox: letter, revisedBox: letter)
        #expect(solution.provenance == .pageBox)
        #expect(solution.transform.isIdentity())
        #expect(solution.residual.maximum == 0)
        #expect(solution.conditioning == 1)
    }

    @Test("A page box within half a point of the baseline is still the identity")
    func pageBoxToleratesReserialisationRounding() {
        // A page operation re-serialises 1683.7795275590554 as 1683.78. That must not
        // become a "revision moved by 0.02 pt".
        let exact = CGRect(x: 0, y: 0, width: 1683.779_527_559_055_4, height: 2383.937_007_874_015_7)
        let rounded = CGRect(x: 0, y: 0, width: 1683.78, height: 2383.94)
        let solution = PageBoxAligner.align(baselineBox: exact, revisedBox: rounded)
        #expect(solution.transform.isIdentity())
    }

    @Test("A same-aspect re-plot at a different sheet size is recovered exactly")
    func pageBoxRecoversUniformRescale() {
        let small = CGRect(x: 0, y: 0, width: 612, height: 792)
        let large = CGRect(x: 0, y: 0, width: 1224, height: 1584)
        let solution = PageBoxAligner.align(baselineBox: large, revisedBox: small)
        #expect(abs(solution.scale - 2) < 1e-12)
        #expect(solution.residual.maximum < 1e-9)
        #expect(abs(solution.conditioning - 1) < 1e-9)
        let mapped = solution.transform.apply(to: CGPoint(x: 306, y: 396))
        #expect(abs(mapped.x - 612) < 1e-9)
        #expect(abs(mapped.y - 792) < 1e-9)
    }

    @Test("Two sheets of different aspect ratio get a low conditioning and a real residual")
    func pageBoxRejectsAspectMismatch() {
        let archD = CGRect(x: 0, y: 0, width: 1728, height: 2592)   // 24 x 36 in, 1:1.5
        let a1 = CGRect(x: 0, y: 0, width: 1683.78, height: 2383.94) // 1:1.4158
        let solution = PageBoxAligner.align(baselineBox: archD, revisedBox: a1)
        #expect(solution.conditioning == 0, "conditioning was \(solution.conditioning)")
        #expect(solution.residual.maximum > 1,
                "corner residual was only \(solution.residual.maximum) pt")
    }

    @Test("A degenerate page box yields conditioning 0 rather than a NaN transform")
    func pageBoxHandlesDegenerateBox() {
        let solution = PageBoxAligner.align(
            baselineBox: CGRect(x: 0, y: 0, width: 612, height: 792),
            revisedBox: CGRect(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(solution.conditioning == 0)
        #expect(solution.transform.isFinite)
    }

    // MARK: - Transform algebra

    @Test("Composition, inversion and bounds transformation agree with CGAffineTransform")
    func transformAlgebra() throws {
        let a = AlignmentTransform(a: 1.1, b: 0.2, c: -0.3, d: 0.9, tx: 12, ty: -4)
        let b = AlignmentTransform.similarity(
            scale: 0.75, rotationRadians: 0.4, translation: CGPoint(x: -3, y: 7)
        )
        let composed = a.concatenating(b)
        let reference = a.cgAffineTransform.concatenating(b.cgAffineTransform)
        #expect(abs(composed.a - Double(reference.a)) < 1e-12)
        #expect(abs(composed.d - Double(reference.d)) < 1e-12)
        #expect(abs(composed.tx - Double(reference.tx)) < 1e-12)
        #expect(abs(composed.ty - Double(reference.ty)) < 1e-12)

        let roundTrip = try composed.concatenating(composed.inverted())
        #expect(roundTrip.isIdentity(tolerance: 1e-12))

        let singular = AlignmentTransform(a: 1, b: 1, c: 1, d: 1, tx: 0, ty: 0)
        #expect(throws: AlignmentFault.self) { try singular.inverted() }
    }
}
