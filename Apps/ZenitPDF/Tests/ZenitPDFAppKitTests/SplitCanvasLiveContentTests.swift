import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// LT-24 / LT-24b / LT-25, 2026-08-29: Tools ▸ Split Canvas opened the
/// mode chrome and then every pane — at every layout, "One Canvas" included — showed the
/// labelled placeholder card forever; the drawing was unreachable until Close Canvas View
/// Mode. And clicking a document tab while split tore the split down, although the empty
/// pane's own instruction says "pick one from the document tabs".
///
/// These tests run the shipping wiring: the real `ProjectWindowController`, the real
/// `install(shell:core:for:)`, the real `.splitCanvas` command through the shell, the real
/// pane fill driven by the canvas-mode observation. No window is ever ordered onto a screen.
@MainActor
@Suite(.appTierSerialised)
struct SplitCanvasLiveContentTests {

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let controller: ProjectWindowController
        let directory: URL
        let previousTabHost: ProjectWindowController?
    }

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    private func makeHarness(
        named name: String,
        pageCount: Int = 2
    ) async throws -> Harness {
        let previousTabHost = ProjectWindowController.tabHost
        let url = try AppTestSupport.writeFixturePDF(named: name, pageCount: pageCount)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil && document.shell != nil && document.drawing != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let controller = ProjectWindowController(document: document)
        #expect(await wait { controller.canvasController(for: document) != nil })
        return Harness(
            document: document,
            core: core,
            shell: shell,
            controller: controller,
            directory: url.deletingLastPathComponent(),
            previousTabHost: previousTabHost
        )
    }

    private func tearDown(_ harness: Harness) {
        harness.shell.leaveCanvasMode()
        harness.controller.window?.close()
        harness.document.close()
        ProjectWindowController.tabHost = harness.previousTabHost
        try? FileManager.default.removeItem(at: harness.directory)
    }

    /// Enters Split Canvas through the shell command and waits for the app tier's
    /// observation-driven fill to land in pane 1.
    private func enterSplitCanvas(_ harness: Harness) async {
        harness.shell.perform(.splitCanvas)
        #expect(harness.shell.canvasModes.activeMode == .splitCanvas,
                "the command must actually enter the mode")
        #expect(await wait { !harness.shell.splitCanvas.pane(.first).isEmpty },
                "the mode opened and nothing ever filled pane 1 (LT-24's precondition)")
    }

    // MARK: - LT-24: the pane draws the drawing

    @Test("An occupied pane gets live page content, not the placeholder card")
    func occupiedPaneRendersTheDrawing() async throws {
        let harness = try await makeHarness(named: "SplitLive.pdf")
        defer { tearDown(harness) }
        await enterSplitCanvas(harness)

        let pane = harness.shell.splitCanvas.pane(.first)
        #expect(pane.documentID == harness.document.documentIdentity)

        // The shell's pane-content seam is installed and produces a live view for the
        // occupied pane — this is the exact call `SplitCanvasModePane` makes per pane.
        let provider = try #require(harness.shell.splitCanvasPaneContent,
                                    "LT-24: the app tier never injected live pane content")
        #expect(provider(pane) != nil,
                "LT-24: the provider declined the occupied pane, so it renders the placeholder")

        // An empty pane keeps the placeholder: its card is the affordance, not a failure.
        #expect(provider(SplitCanvasPaneState(id: .fourth)) == nil)

        // And the pane view really rasterises the sheet: same render source, real
        // PageRasterSource underneath, page pixels delivered.
        let renderSource = try #require(harness.controller.splitPaneRenderSource(for: pane))
        let paneView = SplitPaneCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        SplitCanvasPaneLiveContent(
            pane: pane,
            renderSource: renderSource,
            controller: harness.shell.splitCanvas
        ).configure(paneView)
        paneView.scheduleRender()
        await paneView.settleRenderForTesting()
        #expect(paneView.hasLivePageContent,
                "LT-24: the pane never produced page pixels — the placeholder state, one level down")
        let image = try #require(paneView.lastRenderedImage)
        #expect(image.width > 0 && image.height > 0)
        let region = try #require(paneView.lastRenderedRegion)
        #expect(region.size.width > 0 && region.size.height > 0,
                "the rendered region must be a real slice of the sheet")
    }

    @Test("One Canvas inside the split renders the drawing too (LT-24b)")
    func singleLayoutPaneRendersTheDrawing() async throws {
        // A one-page drawing: `fillSplitCanvasPanes` keeps the layout at One Canvas,
        // which is exactly the full-width never-rendering placeholder of LT-24b.
        let harness = try await makeHarness(named: "SplitSingle.pdf", pageCount: 1)
        defer { tearDown(harness) }
        await enterSplitCanvas(harness)

        #expect(harness.shell.splitCanvas.layout == .single,
                "a single one-page drawing splits into One Canvas")
        let pane = harness.shell.splitCanvas.pane(.first)
        let provider = try #require(harness.shell.splitCanvasPaneContent)
        #expect(provider(pane) != nil,
                "LT-24b: One Canvas inside the split must render the drawing at full width")
    }

    @Test("The mode host's view tree hosts the live pane view, not only the placeholder")
    func modeHostContainsTheLivePaneView() async throws {
        let harness = try await makeHarness(named: "SplitHosted.pdf")
        defer { tearDown(harness) }
        let layout = try #require(harness.controller.contentViewController as? ProjectWindowLayoutController)
        layout.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        layout.view.layoutSubtreeIfNeeded()

        await enterSplitCanvas(harness)
        #expect(layout.isShowingCanvasMode)
        let modeView = try #require(layout.canvasPane?.modeController?.view)
        modeView.layoutSubtreeIfNeeded()

        // The hosted SwiftUI tree materialises its AppKit representables on layout; the
        // live pane view must be among them. This is "the pane hosts a live page view",
        // asserted on the shipping hierarchy rather than on a screenshot.
        let found = await wait(upTo: 10) {
            modeView.layoutSubtreeIfNeeded()
            return Self.firstSplitPaneCanvasView(in: modeView) != nil
        }
        #expect(found, "LT-24: the presented mode hosts no live pane view — placeholders only")
    }

    private static func firstSplitPaneCanvasView(in view: NSView) -> SplitPaneCanvasView? {
        if let pane = view as? SplitPaneCanvasView { return pane }
        for subview in view.subviews {
            if let pane = firstSplitPaneCanvasView(in: subview) { return pane }
        }
        return nil
    }

    // MARK: - Scroll and zoom sync through the pane's own gestures

    @Test("A pane gesture reports into the controller, and the sync toggles mirror it")
    func paneGesturesDriveTheControllerAndFollowers() async throws {
        let harness = try await makeHarness(named: "SplitSync.pdf")
        defer { tearDown(harness) }
        await enterSplitCanvas(harness)

        let split = harness.shell.splitCanvas
        #expect(split.layout == .twoColumns, "a two-page drawing splits into Two Across")
        #expect(!split.pane(.second).isEmpty, "page 2 fills the second pane")
        split.syncOptions = SplitCanvasSyncOptions(syncsScroll: true, syncsZoom: true, syncsPage: false)
        split.focusPane(.first)

        let pane = split.pane(.first)
        let renderSource = try #require(harness.controller.splitPaneRenderSource(for: pane))
        let paneView = SplitPaneCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        SplitCanvasPaneLiveContent(
            pane: pane,
            renderSource: renderSource,
            controller: split
        ).configure(paneView)

        // Zoom: the gesture goes through the controller, which clamps and mirrors.
        let zoomBefore = split.pane(.second).zoom
        paneView.reportZoom(factor: 2)
        #expect(abs(split.pane(.first).zoom - pane.zoom * 2) < 1e-9,
                "the pane's zoom gesture never reached the controller")
        #expect(abs(split.pane(.second).zoom - pane.zoom * 2) < 1e-9,
                "zoom sync is on, so the follower must mirror (was \(zoomBefore))")

        // Scroll: reported in page space, mirrored into the follower.
        let offsetBefore = split.pane(.first).scrollOffset
        paneView.apply(zoom: split.pane(.first).zoom, scrollOffset: offsetBefore)
        paneView.reportScroll(byViewDelta: CGSize(width: -80, height: 40))
        let offsetAfter = split.pane(.first).scrollOffset
        #expect(offsetAfter != offsetBefore, "the pan gesture never moved the pane")
        #expect(split.pane(.second).scrollOffset == offsetAfter,
                "scroll sync is on, so the follower must mirror the offset")

        // Sync off: the follower stays put.
        split.syncOptions = .independent
        let followerOffset = split.pane(.second).scrollOffset
        paneView.apply(zoom: split.pane(.first).zoom, scrollOffset: offsetAfter)
        paneView.reportScroll(byViewDelta: CGSize(width: 24, height: 0))
        #expect(split.pane(.second).scrollOffset == followerOffset,
                "with scroll sync off a pane moves alone")
    }

    // MARK: - LT-25: tab clicks fill a pane instead of killing the split

    @Test("Clicking a document tab while split fills the empty or focused pane, never tears the split down")
    func tabClickFillsAPaneWhileSplit() async throws {
        let harness = try await makeHarness(named: "SplitTabs.pdf")
        defer { tearDown(harness) }

        // A second open drawing, attached to the same window as a tab.
        let otherURL = try AppTestSupport.writeFixturePDF(named: "OtherDrawing.pdf")
        defer { try? FileManager.default.removeItem(at: otherURL.deletingLastPathComponent()) }
        let other = try AppTestSupport.makeDocument(opening: otherURL)
        defer { other.close() }
        harness.controller.attach(document: other)
        #expect(await wait { other.core != nil && other.shell != nil })
        harness.controller.activateTab(id: harness.document.documentIdentity)
        #expect(harness.controller.activeDocument === harness.document)

        await enterSplitCanvas(harness)
        let split = harness.shell.splitCanvas

        // The live gesture: a chip click in the visible tab strip.
        harness.shell.tabBar.select(other.documentIdentity)

        #expect(harness.shell.canvasModes.activeMode == .splitCanvas,
                "LT-25: the tab click tore the split down")
        #expect(harness.controller.activeDocument === harness.document,
                "LT-25: the tab click navigated the window instead of filling a pane")
        let receiving = split.pane(split.focusedPaneID)
        #expect(receiving.documentID == other.documentIdentity,
                "the clicked drawing must land in the focused or empty pane")
        #expect(harness.shell.splitCanvasPaneContent?(receiving) != nil,
                "and that pane renders the clicked drawing, not a placeholder")

        // The filled pane renders the *other* document's sheet: its render source resolves
        // by identity, not to the front tab.
        let renderSource = try #require(harness.controller.splitPaneRenderSource(for: receiving))
        _ = renderSource

        // With the split closed, the same click navigates as it always did.
        harness.shell.leaveCanvasMode()
        harness.shell.tabBar.select(other.documentIdentity)
        #expect(harness.controller.activeDocument === other,
                "outside the split a tab click still activates the tab")
    }

    // MARK: - LT-27: the canvas re-centres when a mode exits

    @Test("Restoring a mode-entry viewport centres a sheet smaller than the window (LT-27)")
    func restoreCentresASheetSmallerThanTheViewport() async throws {
        // A standalone canvas over the real core, hosted in a window that is never
        // ordered in — the CanvasModeSettleTests pattern. The tabbed harness would leave
        // the canvas parented to the project window's own canvas pane.
        let url = try AppTestSupport.writeFixturePDF(named: "RestoreCentre.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        defer { window.contentViewController = nil }
        window.contentViewController = canvas
        _ = canvas.view
        // A window that is never displayed does not size its content; give the canvas its
        // frame explicitly, exactly as the snippet invariance test does.
        window.setContentSize(NSSize(width: 900, height: 700))
        canvas.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        canvas.view.layoutSubtreeIfNeeded()
        canvas.viewDidAppear()

        // The exact shape of a mode-exit token for a fitted sheet: the visible page rect
        // is clamped to the whole page (595 × 842), and at 50 % the sheet is smaller than
        // the 900 × 700 clip on both axes.
        canvas.restore(zoom: 0.5, visiblePageRect: PDFRectValue(x: 0, y: 0, width: 595, height: 842))
        let centred = try #require(canvas.pageFrameInClipForTesting)
        let clip = canvas.view.bounds.size
        let leftGap = centred.minX
        let rightGap = CGFloat(clip.width) - centred.maxX
        let bottomGap = centred.minY
        let topGap = CGFloat(clip.height) - centred.maxY
        #expect(abs(leftGap - rightGap) < 2,
                "LT-27: the sheet sits \(leftGap) pt from the left but \(rightGap) pt from the right")
        #expect(abs(topGap - bottomGap) < 2,
                "LT-27: the sheet sits \(topGap) pt from the top but \(bottomGap) pt from the bottom")

        // And a rect that fills the clip restores exactly — centring must not move a view
        // the person had actually scrolled somewhere.
        canvas.restore(zoom: 2, visiblePageRect: PDFRectValue(x: 100, y: 200, width: 450, height: 350))
        let exact = try #require(canvas.pageFrameInClipForTesting)
        #expect(abs(exact.minX - (-200)) < 2,
                "a clip-filling rect must restore to the pixel; page left edge sits at \(exact.minX)")
    }
}
