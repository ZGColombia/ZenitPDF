import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The whole chain a person drives: Inspector write → command bus → snapshot → observation →
/// scene rebuild → the stroke on screen. In a real window, with **nothing refreshed by hand**.
///
/// Line width and line style were reported as still not changing after the rendering fix. Colour works. Colour goes through the *same* write path
/// (`LedgerBulkEditPresenting.applyBulkEdit`) and the *same* redraw path, so if this test passes,
/// candidates 2 (a second draw path) and 3 (no rebuild on style change) are ruled out for width
/// and style exactly as colour already rules them out for colour — leaving candidate 1: the
/// build that was tested predates the fix.
@MainActor
@Suite(.appTierSerialised)
struct InspectorStyleEndToEndTests {

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let canvas: PDFCanvasViewController
        let window: NSWindow
        let directory: URL

        @MainActor
        func tearDown() {
            window.contentViewController = nil
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness() async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: "style-e2e")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        var snap = await core.session.currentSnapSettings
        snap.enabledKinds = []
        try await core.session.setSnapSettings(snap)
        await core.refresh()

        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
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
            shell: shell,
            canvas: canvas,
            window: window,
            directory: url.deletingLastPathComponent()
        )
    }

    @Test("A width and style edit from the Inspector's write path reaches the drawn shape")
    func styleEditReachesTheDrawnShape() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        // Draw an arrow the way a hand does.
        harness.shell.toolbar.activateShape(.arrow)
        #expect(await AppTestSupport.wait(upTo: 5) {
            harness.canvas.armedMode == .markup(.arrow)
        })
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 120, y: 140))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 340, y: 260))

        // Wait for it to land and be drawn, through observation alone.
        #expect(await AppTestSupport.wait(upTo: 10) {
            harness.canvas.canvasShapes.count == 1
        }, "the committed arrow never reached the page view")
        let markupID = try #require(harness.canvas.canvasShapes.first?.id)

        // The Inspector's own write: the same call `InspectorPanel.applyStyle` makes.
        let editor = try #require(harness.core.ledger as? any LedgerBulkEditPresenting)
        let receipt = await editor.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [markupID],
            style: MarkupStyleEdit(lineWidth: 9, lineStyle: .dotted)
        ))
        #expect(!receipt.didFail, "the write was refused: \(receipt.failureDescription ?? "")")

        // No refresh call anywhere. The observation must carry it to the pixels' doorstep.
        #expect(await AppTestSupport.wait(upTo: 10) {
            guard let shape = harness.canvas.canvasShapes.first else { return false }
            return shape.lineWidth == 9 && shape.lineStyle == .dotted
        }, """
        The Inspector wrote 9 pt dotted, the engine accepted it, and the drawn shape still shows \
        \(String(describing: harness.canvas.canvasShapes.first?.lineWidth)) pt \
        \(String(describing: harness.canvas.canvasShapes.first?.lineStyle)). \
        The redraw chain is broken between the snapshot and the scene.
        """)
    }

    @Test("A locked markup refuses the edit, and the receipt says so")
    func lockedMarkupRefusesAndSaysSo() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.shell.toolbar.activateShape(.line)
        #expect(await AppTestSupport.wait(upTo: 5) {
            harness.canvas.armedMode == .markup(.line)
        })
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 100, y: 100))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 300, y: 100))
        #expect(await AppTestSupport.wait(upTo: 10) {
            harness.canvas.canvasShapes.count == 1
        })
        let markupID = try #require(harness.canvas.canvasShapes.first?.id)

        // Lock it. There is no lock command on the bus — locked is a stored field — so the
        // locked state is written the way a template or an import writes it: a fresh record.
        let record = try #require(await harness.core.session.markup(MarkupID(markupID)))
        var locked = record
        locked.locked = true
        try await harness.core.commands.perform(.removeMarkup(record.id))
        try await harness.core.commands.perform(.addMarkup(locked))
        let editor = try #require(harness.core.ledger as? any LedgerBulkEditPresenting)
        let receipt = await editor.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [markupID],
            style: MarkupStyleEdit(lineWidth: 12)
        ))

        // Whichever way the engine answers, it must not be a silent partial success: either the
        // edit is refused and the receipt says so, or nothing changed.
        let after = try #require(await harness.core.session.markup(MarkupID(markupID)))
        #expect(after.style.lineWidth != 12, "a locked markup was restyled")
        #expect(
            receipt.didFail || receipt.changedMarkupIDs.isEmpty,
            "the receipt claims success over a locked markup that did not change"
        )
    }
}
