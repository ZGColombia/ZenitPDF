import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFExport
@testable import ZenitPDFAppKit

/// NL-PDF-14 in the app: marks are session-only boxes shown on the sheet; Apply asks, writes a
/// checked new file, and leaves the drawing byte for byte. No modal is drawn. Phase 2: the
/// confirmation offers Keep drawings sharp (vector), ticked when every marked sheet qualifies.
@MainActor
@Suite("Redaction workflow (NL-PDF-14)", .appTierSerialised)
struct NLPDFR2RedactionWorkflowTests {

    @Test("Mark → Apply: the confirmation is asked, the copy has no text under the box, marks stay out of the ledger")
    func markAndApply() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-redactapp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Tender.pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        context.textPosition = CGPoint(x: 70, y: 192)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "BIDAMOUNT 4820000", attributes: [.init(kCTFontAttributeName as String): font])), context)
        context.textPosition = CGPoint(x: 70, y: 250)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Tender title", attributes: [.init(kCTFontAttributeName as String): font])), context)
        context.stroke(CGRect(x: 20, y: 20, width: 380, height: 260))
        context.endPDFPage()
        context.closePDF()
        let original = try Data(contentsOf: source)

        let document = try AppTestSupport.makeDocument(opening: source)
        defer { Task { await document.drawing?.rasterSource.close(); document.close() } }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let controller = ProjectWindowController(document: document)

        // Old behaviour: nothing could be redacted.
        RedactionWorkflow.add(RedactionMark(pageIndex: 0, rect: CGRect(x: 60, y: 180, width: 300, height: 40)), to: document, canvas: nil)
        #expect(RedactionWorkflow.marks(for: document).count == 1)
        #expect(core.snapshot.markups.isEmpty, "a redaction mark is never a markup")

        let output = folder.appendingPathComponent("Tender — Redacted.pdf")
        ZenitModalPresenter.reset()
        let previous = ZenitModalPresenter.handler
        defer { ZenitModalPresenter.handler = previous }
        ZenitModalPresenter.handler = { request in
            switch request.identifier {
            case RedactionWorkflow.confirmIdentifier: return .button(0)
            case RedactionWorkflow.panelIdentifier: return .urls([output])
            default: return .dismissed
            }
        }
        controller.applyRedactions(for: document)
        #expect(await AppTestSupport.wait(upTo: 20) { FileManager.default.fileExists(atPath: output.path) })
        let request = try #require(ZenitModalPresenter.recorded.last { $0.identifier == RedactionWorkflow.confirmIdentifier })
        #expect(request.detail.contains("removed for good"))
        #expect(await AppTestSupport.wait { core.document.warnings.contains { $0.id == RedactionWorkflow.resultNoteID } })
        let redacted = try #require(PDFDocument(url: output))
        // Old behaviour: the sheet became a picture and "Tender title" was gone with the figure.
        let text = redacted.page(at: 0)?.string ?? ""
        #expect(!text.contains("4820000") && !text.contains("BIDAMOUNT"))
        #expect(text.contains("Tender title"), "kept sharp by default: text outside the box is still searchable")
        let note = try #require(core.document.warnings.first { $0.id == RedactionWorkflow.resultNoteID })
        // L-48: one sheet is "1 sheet" (it read "1 sheets kept sharp").
        #expect(note.message.contains("1 sheet kept sharp"), "\(note.message)")
        #expect(try Data(contentsOf: source) == original)

        controller.clearRedactionMarks(for: document)
        #expect(RedactionWorkflow.marks(for: document).isEmpty)
    }

    @Test("The confirmation ticks Keep drawings sharp only when every marked sheet qualifies, and names the sheets that fall back")
    func confirmationOffersVector() {
        let all = RedactionAssessment(markedPages: [0, 2], fallbacks: [])
        let (qualifies, sharp) = RedactionWorkflow.confirmation(markCount: 2, sheetCount: 2, assessment: all)
        #expect(sharp.title == "Keep drawings sharp (vector)")
        #expect(sharp.state == .on && sharp.isEnabled, "default when every marked sheet qualifies")
        #expect(qualifies.accessoryView === sharp)
        #expect(!qualifies.informativeText.contains("cannot be cut exactly"))

        let some = RedactionAssessment(markedPages: [0, 2], fallbacks: [RedactionFallback(pageIndex: 2, reason: "the font Helvetica has no width table")])
        let (partial, partialSharp) = RedactionWorkflow.confirmation(markCount: 2, sheetCount: 2, assessment: some)
        #expect(partialSharp.state == .off && partialSharp.isEnabled, "offered, not ticked, when a sheet would fall back")
        #expect(partial.informativeText.contains("Sheets 3 cannot be cut exactly"))
        #expect(partial.informativeText.contains("sheet 3: the font Helvetica has no width table"))

        let none = RedactionAssessment(markedPages: [1], fallbacks: [RedactionFallback(pageIndex: 1, reason: "the drawing is encrypted")])
        let (_, noneSharp) = RedactionWorkflow.confirmation(markCount: 1, sheetCount: 1, assessment: none)
        #expect(noneSharp.state == .off && !noneSharp.isEnabled, "nothing can stay vector")

        var outcome = RedactionOutcome(redactedPages: [0, 2], markCount: 2, removedWordCount: 1, checks: ["checked"])
        outcome.method = .vector
        outcome.vectorPages = [0]
        outcome.rasterFallbacks = some.fallbacks
        let message = RedactionWorkflow.resultMessage(outcome)
        // L-48: it read "1 sheets kept sharp; 1 became pictures".
        #expect(message.contains("1 sheet kept sharp; 1 became a picture"), "\(message)")
        #expect(message.contains("Sheet 3 became a picture: the font Helvetica has no width table"))
    }
}
