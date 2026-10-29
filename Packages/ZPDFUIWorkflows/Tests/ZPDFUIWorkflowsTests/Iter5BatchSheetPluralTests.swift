import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Iteration 5, ui-presentation-measure, V-075: the Batch Apply sheet's own count line.
@Suite("Iteration 5 batch sheet plurals (V-075)", .workflowsTierSerialised)
struct Iter5BatchSheetPluralTests {

    /// Old output: "1 page(s) selected in the Navigator."
    @Test("The navigator-selection line agrees with its count")
    func navigatorSelectionLine() {
        #expect(BatchApplySheet.navigatorSelectionSentence(count: 1) == "1 page selected in the Navigator.")
        #expect(BatchApplySheet.navigatorSelectionSentence(count: 4) == "4 pages selected in the Navigator.")
        #expect(BatchApplySheet.navigatorSelectionSentence(count: 0).hasPrefix("No page is selected in the Navigator."))
    }
}
