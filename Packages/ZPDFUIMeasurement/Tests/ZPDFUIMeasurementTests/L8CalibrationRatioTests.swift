import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Live test 8, L-38, the Calibrate sheet's half. The live separate X / Y picks — X 848.0 pt =
/// 14,8 m, Y 839.6 pt = 15 m — read "1:49,5" and "1:50,6" in the sheet while the rest of the app
/// read "1:49 × 1:51". The sheet now writes its ratio through ``ScaleRatioText``, the rule the
/// status strip and ``ScaleSummary/displayString`` use, in the document's locale.
@Suite("Live test 8 — the Calibrate sheet's ratio is the app's ratio (L-38)")
struct L8CalibrationRatioTests {

    static let swedish = Locale(identifier: "sv_SE")

    static var liveDraft: CalibrationDraft {
        CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 100, y: 100), end: PDFPointValue(x: 948, y: 100), knownLength: 14.8
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 50, y: 1), end: PDFPointValue(x: 50, y: 840.6), knownLength: 15
            ),
            unitIdentifier: LengthUnit.metre.rawValue
        )
    }

    @Test("The live picks read 1:49,5 and 1:50,6, and the scale they make reads 1:49,5 × 1:50,6")
    func livePicks() throws {
        let validation = CalibrationValidator.validate(Self.liveDraft, locale: Self.swedish)
        #expect(validation.canApply)
        let preview = try #require(validation.preview)
        #expect(preview.ratioString == "1:49,5")
        #expect(preview.secondaryRatioString == "1:50,6")
        // The same text the shared rule writes for the committed factors — the status strip's,
        // the Inspector's and the Scale Regions panel's.
        #expect(preview.ratioString == ScaleRatioText.ratio(metresPerPoint: preview.sx, locale: Self.swedish))
        let both = ScaleRatioText.ratio(
            metresPerPointX: preview.sx, metresPerPointY: preview.sy, isUniform: false, locale: Self.swedish
        )
        #expect(both == "1:49,5 × 1:50,6")
        // The summary the sheet hands back carried the X ratio alone ("1:49,5").
        let summary = try #require(CalibrationValidator.makeScaleSummary(from: Self.liveDraft, locale: Self.swedish))
        #expect(summary.displayString == "1:49,5 × 1:50,6")
    }

    @Test("A drawing scale of 1:1000 is written without the locale's grouping space")
    func noGrouping() throws {
        let draft = CalibrationDraft(mode: .drawingScale, drawingScaleDenominator: 1000)
        let preview = try #require(CalibrationValidator.validate(draft, locale: Self.swedish).preview)
        // Old: "1:1 000" in a Swedish locale, grouped where the status strip was not.
        #expect(preview.ratioString == "1:1000")
        #expect(MeasurementValueFormatter.ratioString(metresPerPagePoint: preview.sx, locale: Self.swedish) == "1:1000")
    }
}
