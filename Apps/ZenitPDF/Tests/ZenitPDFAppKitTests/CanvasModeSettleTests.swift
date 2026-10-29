import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// The settle guard, extended to the canvas modes.
///
/// A refresh loop once cost the product Cutout and its launch performance, and it
/// was invisible to every suite that refreshed by hand. The canvas and the shell carry guards;
/// Split Canvas and Revision Overlay — both of which lay a mode surface over the same canvas —
/// did not, and a loop there would present exactly the same way: everything green, the product
/// unusable. This was the open half of that housekeeping.
///
/// The detached ledger window is still unguarded; it needs its own window host and is recorded
/// as an open item rather than silently skipped here.
@MainActor
@Suite(.appTierSerialised)
struct CanvasModeSettleTests {

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

    private func makeHarness(_ name: String) async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
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
            document: document, core: core, shell: shell,
            canvas: canvas, window: window, directory: url.deletingLastPathComponent()
        )
    }

    @Test("Entering and holding a canvas mode settles", arguments: [
        DismissibleCanvasMode.splitCanvas, .revisionOverlay
    ])
    func aCanvasModeSettles(mode: DismissibleCanvasMode) async throws {
        let harness = try await makeHarness("settle-\(mode)")
        defer { harness.tearDown() }

        _ = harness.shell.enterCanvasMode(mode)
        try? await Task.sleep(for: .milliseconds(400))

        let before = harness.canvas.refreshCountForTesting
        try? await Task.sleep(for: .milliseconds(600))
        let during = harness.canvas.refreshCountForTesting - before

        #expect(during < 20, """
        Holding \(mode) left the canvas refreshing \(during) times in 0.6 idle seconds. \
        An observed property assigned during layout must be assigned only when \
        its value actually changes.
        """)

        // Leaving the mode settles too — exit restores the previous viewport, which is a
        // burst of assignments that must end.
        harness.shell.leaveCanvasMode()
        try? await Task.sleep(for: .milliseconds(400))
        let afterExit = harness.canvas.refreshCountForTesting
        try? await Task.sleep(for: .milliseconds(600))
        #expect(harness.canvas.refreshCountForTesting - afterExit < 20)
    }
}
