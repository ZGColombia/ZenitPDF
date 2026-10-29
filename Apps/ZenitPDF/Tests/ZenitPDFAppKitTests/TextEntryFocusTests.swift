import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The in-canvas text box has to be typeable.
///
/// Arming Text or Callout and dragging a box drew the box — the dark rectangle with cyan
/// handles *is* `CanvasTextEditor`, whose background is `.elevated` at 92 % — but nothing could
/// be typed into it, and it did not stay.
///
/// Every existing test drives `PDFCanvasViewController.handleClick` directly and passes, so the
/// defect is below that: in the window, the responder chain, or the editor's own configuration.
/// These tests put the canvas in a real `NSWindow` — never ordered on screen — and ask the two
/// questions the harness cannot: **is the editor first responder**, and **does a keystroke reach
/// the markup draft**.
@MainActor
@Suite(.appTierSerialised)
struct TextEntryFocusTests {

    @MainActor
    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let canvas: PDFCanvasViewController
        let window: NSWindow
        let directory: URL

        func tearDown() {
            window.contentViewController = nil
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixtureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-textfocus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Plan A-401.pdf")
        let content = Data("2 w 0 0 0 RG\n72 72 m 372 72 l 372 272 l 72 272 l h S\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>".utf8)
        ]
        var streamData = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        streamData.append(content)
        streamData.append(Data("\nendstream".utf8))
        objects.append(streamData)
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try pdf.write(to: url)
        return url
    }

    /// A canvas inside a real window. The window is **never ordered front**: a test may not put
    /// anything on screen, and `makeFirstResponder` works on an unordered window.
    private func makeHarness() async throws -> Harness {
        let url = try fixtureURL()
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let toolbar = try #require(document.shell?.toolbar)
        let canvas = PDFCanvasViewController(core: core, rasterSource: nil, toolbar: toolbar)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = canvas
        _ = canvas.view
        canvas.viewDidAppear()

        return Harness(
            document: document,
            core: core,
            canvas: canvas,
            window: window,
            directory: url.deletingLastPathComponent()
        )
    }

    @Test("Opening a text box puts the caret in it")
    func theEditorTakesFirstResponder() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.core.markup.activate(kind: .text, style: .zenitInk)
        harness.canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false)

        let entry = try #require(harness.canvas.activeTextEntry, "no text box opened")
        #expect(entry.kind == .text)

        let editor = try #require(harness.canvas.textEditorForTesting, "no editor was installed")
        #expect(editor.superview != nil, "the editor is not in the view hierarchy")
        #expect(editor.isEditable, "the editor refuses text")
        #expect(editor.isSelectable)
        #expect(
            harness.window.firstResponder === editor,
            """
            the text box does not have the caret — first responder is \
            \(String(describing: harness.window.firstResponder)), so nothing typed reaches \
            the box.
            """
        )
    }

    @Test("Typing into the box reaches the markup draft, and the box stays open")
    func typingReachesTheDraft() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.core.markup.activate(kind: .text, style: .zenitInk)
        harness.canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false)
        let editor = try #require(harness.canvas.textEditorForTesting)

        // Through the editor, the way a keystroke arrives — not through the controller's own
        // `typeIntoTextEntry`, which is the seam the passing tests already use and the seam that
        // hid this.
        editor.insertText("Rivning", replacementRange: NSRange(location: 0, length: 0))

        #expect(editor.string == "Rivning")
        #expect(harness.core.markup.draftText == "Rivning", "the keystroke never reached the draft")
        #expect(harness.canvas.activeTextEntry != nil, "the box closed while it was being typed in")
    }
}
