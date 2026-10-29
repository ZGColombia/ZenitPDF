import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Quality-loop iteration 2, area "ui-presentation-measure": the scale sheets' words, and
/// calibration off a typeset dimension.
@Suite("Iteration 2 ui-presentation-measure (scale sheets and calibration)")
struct Iter2UIPresentationMeasureTests {

    // MARK: S-092

    private let impact = BulkScaleImpact(pageCount: 4, markupCount: 30, affectedMeasurementCount: 12)

    /// Old output: the counter read "Recalculated: 12" and the preview's spoken value read
    /// "4 pages, 30 markups, 12 measurements would be recalculated." under both choices.
    @Test("S-092: the bulk scale preview follows the decision, on screen and to VoiceOver")
    func previewFollowsTheDecision() {
        #expect(BulkScaleSheet.affectedCounterTitle(for: .recalculate) == "Recalculated")
        #expect(BulkScaleSheet.affectedCounterTitle(for: .keepExisting) == "Flagged")
        #expect(impact.summary(for: .recalculate) == "4 pages, 30 markups, 12 measurements would be recalculated.")
        #expect(impact.summary(for: .keepExisting) == impact.keepValuesSummary)
        #expect(!impact.summary(for: .keepExisting).contains("recalculated"))
        // The Apply button's spoken value reads the same one rule.
        let selection = BulkScaleSelection(kind: .entireDocument)
        #expect(
            BulkScaleSheet.applyAccessibilityValue(selection: selection, pageCount: 4, impact: impact, decision: .keepExisting)
                == impact.summary(for: .keepExisting)
        )
        #expect(
            BulkScaleSheet.applyAccessibilityValue(selection: selection, pageCount: 4, impact: impact, decision: .recalculate)
                == impact.summary(for: .recalculate)
        )
    }

    // MARK: S-093

    /// Old output: "4 sheets: 1 set, 0 proposed, 3 without a scale." — the two sheets still
    /// being read were counted as having no scale, so a freshly opened 40-sheet set read
    /// "40 without a scale" until every proposal landed.
    @Test("S-093: sheets still being read are counted as such, never as without a scale")
    func readingSheetsAreNotMissing() {
        let rows = [
            PageScaleRow(id: UUID(), label: "A-101", sizeText: "A1", status: .set(ratio: "1:100", source: "Preset")),
            PageScaleRow(id: UUID(), label: "A-102", sizeText: "A1", status: .reading),
            PageScaleRow(id: UUID(), label: "A-103", sizeText: "A1", status: .reading),
            PageScaleRow(id: UUID(), label: "A-104", sizeText: "A1", status: .none)
        ]
        #expect(PageScalesPanel.summary(of: rows) == "4 sheets: 1 set, 0 proposed, 1 without a scale, 2 still being read.")
        let opened = (0..<40).map { PageScaleRow(id: UUID(), label: "S-\($0)", sizeText: "A1", status: .reading) }
        #expect(PageScalesPanel.summary(of: opened) == "40 sheets: 0 set, 0 proposed, 0 without a scale, 40 still being read.")
    }

    // MARK: S-094

    private static func feet(_ text: String) -> Double? {
        if case .length(let value) = CalibrationPendingLength.reading(text, unit: .foot) { return value }
        return nil
    }

    /// Old output: `.unusable` for every prime-marked entry — `isUnitless` recognised U+2032 and
    /// U+2033 as unit marks, but `parseInches` folded only the curly quotes, so the whole text
    /// became the inch part and `12′` failed the decimal grammar.
    @Test("S-094: lengths written with prime marks calibrate like the ASCII marks")
    func primeMarksCalibrate() throws {
        // 12 ft 6 1/2 in = 150.5 in = 12.541666… ft.
        let expected = 150.5 / 12
        #expect(abs(try #require(Self.feet("12\u{2032} 6 1/2\u{2033}")) - expected) < 1e-12)
        #expect(abs(try #require(Self.feet("12\u{2032}-6 1/2\u{2033}")) - expected) < 1e-12)
        #expect(abs(try #require(Self.feet("12' 6 1/2\"")) - expected) < 1e-12)
        // Inches alone under feet: 6 1/2 in = 0.541666… ft.
        #expect(abs(try #require(Self.feet("6 1/2\u{2033}")) - 6.5 / 12) < 1e-12)
        // Word-processor quotes, left and right, read the same way.
        #expect(abs(try #require(Self.feet("12\u{2018} 6 1/2\u{201C}")) - expected) < 1e-12)
        #expect(abs(try #require(Self.feet("12\u{2019} 6 1/2\u{201D}")) - expected) < 1e-12)
        // The parser itself, in inches.
        #expect(ImperialLengthFormatter.parseInches("12\u{2032} 6\u{2033}") == 150)
        // A left quote is a unit mark too, so it is never read as a bare number in the popup's unit.
        #expect(!ImperialLengthFormatter.isUnitless("6\u{201C}"))
    }
}
