import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Bug hunt 2, the Apply Scale sheet. Driven through its pure rules; no sheet is shown.
@Suite("Bulk scale fixes (bug hunt 2)")
struct BulkScaleFixLaneTests {

    private let impact = BulkScaleImpact(pageCount: 4, markupCount: 30, affectedMeasurementCount: 12)

    /// Old output: the page fields clamped 25 and 30 to 20 and 20, the range passed, and Apply
    /// targeted page 20 alone.
    @Test("BH-261: an out-of-range page number reaches the range check unclamped")
    func outOfRangePagesAreRefused() {
        let start = BulkScaleSheet.pageNumber(from: 25)
        let end = BulkScaleSheet.pageNumber(from: 30)
        #expect(start == 25)
        #expect(end == 30)
        let selection = BulkScaleSelection(kind: .pageRange, rangeStart: start, rangeEnd: end)
        #expect(!selection.isRangeValid(pageCount: 20))
        #expect(selection.rangeIssue(pageCount: 20)?.contains("20") == true)
        #expect(BulkScaleSheet.pageNumber(from: 0) == 0)
        #expect(BulkScaleSheet.pageNumber(from: 1e300) == Int.max, "no trap on a huge value")
        #expect(BulkScaleSheet.pageNumber(from: nil) == nil)
    }

    /// Old output: `canApply == true` with 4 of 4 pages locked.
    @Test("BH-749: Apply is off when every targeted page is locked")
    func allLockedBlocksApply() {
        var locked = impact
        locked.lockedPageCount = 4
        let selection = BulkScaleSelection(kind: .entireDocument)
        #expect(!BulkScaleSheet.canApply(selection: selection, pageCount: 4, impact: locked, decision: .recalculate))
        locked.lockedPageCount = 3
        #expect(BulkScaleSheet.canApply(selection: selection, pageCount: 4, impact: locked, decision: .recalculate))
    }

    /// Old output: "… 12 measurements would be recalculated" under Keep Values.
    @Test("BH-750: the Apply button's spoken value matches the decision")
    func spokenValueMatchesDecision() {
        let selection = BulkScaleSelection(kind: .entireDocument)
        let keep = BulkScaleSheet.applyAccessibilityValue(selection: selection, pageCount: 4, impact: impact, decision: .keepExisting)
        let recalc = BulkScaleSheet.applyAccessibilityValue(selection: selection, pageCount: 4, impact: impact, decision: .recalculate)
        #expect(!keep.contains("recalculated"))
        #expect(keep == impact.keepValuesSummary)
        #expect(recalc == impact.summary)
    }

    @Test("IM-109: the decision control offers two choices, not a second Cancel")
    func decisionChoices() {
        #expect(BulkScaleDecision.offeredChoices == [.recalculate, .keepExisting])
    }
}
