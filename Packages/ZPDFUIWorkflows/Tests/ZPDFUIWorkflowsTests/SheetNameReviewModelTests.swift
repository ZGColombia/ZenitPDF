import Foundation
import Testing
@testable import ZPDFUIWorkflows

/// NL-AUTO-04: the sheet-name review, windowless.
@MainActor
@Suite(.workflowsTierSerialised)
struct SheetNameReviewModelTests {

    static func row(_ page: Int, _ number: String, confidence: Double = 1) -> SheetNameReviewRow {
        SheetNameReviewRow(pageIndex: page, pageLabel: "Page \(page + 1)", number: number, title: "PLAN \(page)",
                           sourceText: "Read in your box", confidence: confidence)
    }

    @Test("Confident readings start ticked, weak or empty ones are flagged and unticked")
    func defaults() {
        let model = SheetNameReviewModel(rows: [Self.row(0, "A-101"), Self.row(1, "A-102", confidence: 0.4), Self.row(2, "")],
                                         onAccept: { _ in }, onCancel: {})
        #expect(model.includedPageIndexes == [0])
        #expect(model.summaryText.contains("1 of 3 sheets named; 2 need a look"))
    }

    @Test("A wrong read is corrected in place and lands as typed")
    func editAndAccept() {
        var outcome: SheetNameReviewOutcome?
        let model = SheetNameReviewModel(rows: [Self.row(0, "A-1O1"), Self.row(1, "A-102")], onAccept: { outcome = $0 }, onCancel: {})
        model.rows[0].number = "A-101"
        model.rows[1].title = "  "
        model.accept()
        #expect(outcome?.names[0] == .init(number: "A-101", title: "PLAN 0"))
        #expect(outcome?.names[1] == .init(number: "A-102", title: nil))
    }

    @Test("Two included pages with one number block acceptance until one is fixed or unticked")
    func duplicatesBlock() {
        var accepted = false
        let model = SheetNameReviewModel(rows: [Self.row(0, "A-101"), Self.row(1, "a-101")], onAccept: { _ in accepted = true }, onCancel: {})
        #expect(model.duplicatePageIndexes == [0, 1])
        #expect(!model.canAccept)
        model.accept()
        #expect(!accepted)
        model.setIncluded(false, pageIndex: 1)
        #expect(model.canAccept)
        model.accept()
        #expect(accepted)
    }
}
