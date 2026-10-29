import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Quality-loop iteration 7, area "quantities-core", cycle 2, X-044's presentation half: the
/// engine accepts a cutout lying partly outside its parent, subtracts the part inside and warns
/// `cutoutOutsideParent` (ADR-0015). The presentation showed that warning as blocking, with copy
/// written for the refusal of a cutout that overlaps nothing.
@Suite("Iteration 7 quantities-core (presentation)")
struct Iter7QuantitiesCoreUIPresentationTests {

    /// Old output: `isBlocking` true, the octagon symbol, and "A cutout must overlap the area it
    /// is subtracted from." — on a number the engine had already accepted.
    @Test("X-044 c2: a cutout partly outside its parent informs, with copy that says what was subtracted")
    func partialOverlapWarningInforms() {
        let warning = MeasurementWarningSummary.cutoutOutsideParent
        #expect(!warning.isBlocking)
        #expect(warning.symbolName == "exclamationmark.triangle")
        #expect(warning.message == "Part of a cutout lies outside this area. Only the part inside is subtracted.")
        // What still blocks is what has no number to commit: no extent, no scale, a cutout the
        // engine refuses because it overlaps nothing (X-cutout-ui), or a circle tool on a sheet
        // whose X and Y scales differ, on the sheet or where it is clicked (L-102, live test 8).
        // Finish's refusal (`commitRefusalReason`, `hasBlockingWarning`) reads exactly this set.
        #expect(Set(MeasurementWarningSummary.allCases.filter(\.isBlocking))
            == [.degenerateGeometry, .missingScale, .cutoutDoesNotOverlapParent, .circleNeedsUniformScale, .circleNeedsUniformScaleHere])
    }
}
