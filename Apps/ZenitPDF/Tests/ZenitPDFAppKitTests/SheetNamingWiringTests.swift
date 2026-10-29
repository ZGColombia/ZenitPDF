import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// NL-AUTO-04 through the window: box the number and title on one sheet, every sheet of that
/// size is read, the review lists them, and accepting names the sheets in one undo.
@MainActor
@Suite(.appTierSerialised)
struct SheetNamingWiringTests {

    static func sheet(_ number: String, _ title: String) -> String {
        "BT /F1 14 Tf 1000 50 Td (\(number)) Tj ET BT /F1 12 Tf 1000 100 Td (\(title)) Tj ET 1 w 100 100 m 500 100 l S"
    }

    @Test("Three A3 sheets named from two boxes on the first; accepting names all three in one undo")
    func namesTheSet() async throws {
        let url = try AutomationFixtures.writePages(named: "Set.pdf", mediaBox: "0 0 1191 842", contents: [
            Self.sheet("A-101", "PLAN 1"), Self.sheet("A-102", "PLAN 2"), Self.sheet("A-103", "SEKTION A-A")
        ])
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let canvas = try #require(controller.canvasController(for: document))

        let previous = ProjectWindowController.sheetNameReviewPresenter
        defer { ProjectWindowController.sheetNameReviewPresenter = previous }
        var captured: SheetNameReviewModel?
        ProjectWindowController.sheetNameReviewPresenter = { model, _ in
            captured = model
            return {}
        }

        controller.beginSheetNaming(for: document)
        canvas.onSnippetRegion?(PDFRectValue(x: 990, y: 40, width: 110, height: 35))
        canvas.onSnippetRegion?(PDFRectValue(x: 990, y: 92, width: 180, height: 28))
        #expect(await AppTestSupport.wait(upTo: 20) { captured != nil }, "the review never opened")
        let model = try #require(captured)
        #expect(model.rows.map(\.number) == ["A-101", "A-102", "A-103"])
        #expect(model.rows.map(\.title) == ["PLAN 1", "PLAN 2", "SEKTION A-A"])
        #expect(model.includedPageIndexes == [0, 1, 2])

        // A wrong read is corrected in place before accepting.
        model.rows[2].title = "SECTION A-A"
        model.accept()
        var names: [PageID: SheetIdentity] = [:]
        for _ in 0..<100 {
            names = await core.session.sheetIdentities
            if names.count == 3 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(names.count == 3)
        #expect(Set(names.values.compactMap(\.number)) == ["A-101", "A-102", "A-103"])
        #expect(names.values.contains { $0.title == "SECTION A-A" })
        #expect(names.values.allSatisfy { $0.source == .titleBlockText })

        // One ⌘Z takes every name back.
        document.undoManager?.undo()
        var after = names
        for _ in 0..<100 {
            after = await core.session.sheetIdentities
            if after.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(after.isEmpty)
    }

    @Test("A scanned set with no text layer is named by recognising the boxes on this Mac, flagged for a look when unsure")
    func namesAScannedSet() async throws {
        let url = try AutomationFixtures.writeScannedSheets(named: "Scanned.pdf", sheets: [
            ("A-201", "PLAN 1"), ("A-202", "PLAN 2")
        ])
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let canvas = try #require(controller.canvasController(for: document))
        let previous = ProjectWindowController.sheetNameReviewPresenter
        defer { ProjectWindowController.sheetNameReviewPresenter = previous }
        var captured: SheetNameReviewModel?
        ProjectWindowController.sheetNameReviewPresenter = { model, _ in
            captured = model
            return {}
        }
        controller.beginSheetNaming(for: document)
        canvas.onSnippetRegion?(PDFRectValue(x: 990, y: 40, width: 110, height: 35))
        canvas.onSnippetRegion?(PDFRectValue(x: 990, y: 92, width: 180, height: 28))
        #expect(await AppTestSupport.wait(upTo: 30) { captured != nil }, "the review never opened")
        let model = try #require(captured)
        // Old behaviour: an empty text layer read nothing at all.
        #expect(model.rows.map(\.number) == ["A-201", "A-202"], "\(model.rows.map(\.number))")
        #expect(model.rows.map(\.title) == ["PLAN 1", "PLAN 2"])
        #expect(model.rows.allSatisfy { $0.sourceText.hasPrefix("Recognised in your box") })
    }
}
