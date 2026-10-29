import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// Feature 13's engine: warn when the drawn dimension disagrees, and — the invariant — stay
/// silent on every uncertain path, because a false alarm teaches people to ignore the real one.
@Suite("Dimension check")
struct DimensionCheckTests {

    private func metres(_ string: String) -> Decimal { Decimal(string: string)! }

    // MARK: - Agreement and disagreement

    @Test("A correctly calibrated measurement agrees with its drawn dimension")
    func calibratedSheetIsQuiet() {
        let verdict = DimensionChecker.check(
            measuredMetres: metres("5.3805"),
            candidates: [.init(text: "5 380", confidence: 0.96)]
        )
        #expect(verdict == .agrees(drawnMetres: metres("5.38")))
    }

    @Test("A mis-calibrated sheet produces the warning, carrying the user's own tolerance")
    func miscalibratedSheetWarns() {
        // Four percent of calibration error on a 5 380 mm wall: measured 5.165.
        let verdict = DimensionChecker.check(
            measuredMetres: metres("5.165"),
            candidates: [.init(text: "5 380", confidence: 0.96)]
        )
        #expect(verdict == .disagrees(
            drawnMetres: metres("5.38"),
            measuredMetres: metres("5.165"),
            differenceMetres: metres("0.215"),
            toleranceMetres: metres("0.010")
        ))
    }

    // MARK: - Never accuse on a guess

    @Test("A low-confidence reading says nothing — and the same text confident would warn")
    func lowConfidenceIsSilence() {
        let hesitant = DimensionChecker.check(
            measuredMetres: metres("5.165"),
            candidates: [.init(text: "5 380", confidence: 0.5)]
        )
        #expect(hesitant == .noConfidentDimension)

        // Non-vacuity: confidence is the only thing keeping this quiet.
        let confident = DimensionChecker.check(
            measuredMetres: metres("5.165"),
            candidates: [.init(text: "5 380", confidence: 0.9)]
        )
        guard case .disagrees = confident else {
            Issue.record("the confident twin must warn, or the silence test proves nothing")
            return
        }
    }

    @Test("A stray figure that cannot be this measurement's dimension never accuses")
    func implausiblePairingIsSilence() {
        // A detail note "12" beside a 5.38 m wall: wildly outside the plausibility band.
        let verdict = DimensionChecker.check(
            measuredMetres: metres("5.38"),
            candidates: [.init(text: "12", confidence: 0.99)]
        )
        #expect(verdict == .noConfidentDimension)
    }

    @Test("Text that is not cleanly a dimension is discarded, not guessed at")
    func junkIsSilence() {
        for junk in ["OBS 5400", "5400x", "A5 400", "54 00", "+5.400", "±0.000", "5 4 0 0"] {
            let verdict = DimensionChecker.check(
                measuredMetres: metres("5.4"),
                candidates: [.init(text: junk, confidence: 0.99)]
            )
            #expect(verdict == .noConfidentDimension, "\(junk) must not parse as a dimension")
        }
    }

    @Test("Three decimals with no unit is ambiguous and refused; with a unit it is exact")
    func thousandsSeparatorShapeIsRefusedWithoutAUnit() {
        // `5.400` is 5.4 m on one drawing and 5400 mm on another — no guessing.
        #expect(DimensionChecker.parseDimensionMetres("5.400") == nil)
        #expect(DimensionChecker.parseDimensionMetres("5,400") == nil)
        #expect(DimensionChecker.parseDimensionMetres("5.400 m") == metres("5.4"))
    }

    // MARK: - The grammar

    @Test("Whole numbers are millimetres, decimals are metres, explicit units always win")
    func dimensionGrammar() {
        #expect(DimensionChecker.parseDimensionMetres("5400") == metres("5.4"))
        #expect(DimensionChecker.parseDimensionMetres("5 400") == metres("5.4"))
        #expect(DimensionChecker.parseDimensionMetres("12 345") == metres("12.345"))
        #expect(DimensionChecker.parseDimensionMetres("540") == metres("0.54"))
        #expect(DimensionChecker.parseDimensionMetres("5,4") == metres("5.4"))
        #expect(DimensionChecker.parseDimensionMetres("5.4") == metres("5.4"))
        #expect(DimensionChecker.parseDimensionMetres("5.40") == metres("5.4"))
        #expect(DimensionChecker.parseDimensionMetres("5400 mm") == metres("5.4"))
        #expect(DimensionChecker.parseDimensionMetres("540 cm") == metres("5.4"))
        #expect(DimensionChecker.parseDimensionMetres("5.4 m") == metres("5.4"))
        // OCR's non-breaking and thin spaces group digits too.
        #expect(DimensionChecker.parseDimensionMetres("5\u{00A0}400") == metres("5.4"))
    }

    @Test("In a dimension chain, one agreeing figure outweighs the disagreeing neighbours")
    func chainAgreementWins() {
        let verdict = DimensionChecker.check(
            measuredMetres: metres("5.380"),
            candidates: [
                .init(text: "2 400", confidence: 0.95),
                .init(text: "5 380", confidence: 0.95),
                .init(text: "1 200", confidence: 0.95)
            ]
        )
        #expect(verdict == .agrees(drawnMetres: metres("5.38")))
    }

    @Test("With nothing near the measurement at all, the verdict is silence")
    func noCandidatesIsSilence() {
        #expect(
            DimensionChecker.check(measuredMetres: metres("5.38"), candidates: [])
                == .noConfidentDimension
        )
    }

    @Test("The tolerance is the user's: widening it turns the same disagreement into agreement")
    func toleranceBelongsToTheUser() {
        let candidates = [DimensionChecker.Candidate(text: "5 400", confidence: 0.95)]
        let strict = DimensionChecker.check(
            measuredMetres: metres("5.38"),
            candidates: candidates,
            options: .init(toleranceMetres: metres("0.010"))
        )
        guard case .disagrees(_, _, let difference, let shown) = strict else {
            Issue.record("20 mm off with a 10 mm tolerance must warn")
            return
        }
        #expect(difference == metres("0.02"))
        #expect(shown == metres("0.010"), "the warning must carry the tolerance it applied")

        let relaxed = DimensionChecker.check(
            measuredMetres: metres("5.38"),
            candidates: candidates,
            options: .init(toleranceMetres: metres("0.025"))
        )
        #expect(relaxed == .agrees(drawnMetres: metres("5.4")))
    }
}
