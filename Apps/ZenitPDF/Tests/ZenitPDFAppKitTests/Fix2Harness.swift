import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The window-level harness the fix-2 suites share: a real fixture PDF, a real document, a
/// real `ProjectWindowController` whose window is never ordered on screen, and the canvas the
/// window built for the document.
@MainActor
struct Fix2Harness {
    let document: ZenitPDFProjectDocument
    let controller: ProjectWindowController
    let core: AppCoreEnvironment
    let shell: ProjectShellEnvironment
    let canvas: PDFCanvasViewController
    let directory: URL

    /// Opens `name` (a stroked-rectangle fixture), attaches it to a window controller, and
    /// optionally calibrates 100 pt = 1 m with snap off, so quantities read straight off the
    /// coordinates.
    static func make(
        _ name: String,
        pageCount: Int = 1,
        calibrate: Bool = true,
        fixture: URL? = nil
    ) async throws -> Fix2Harness {
        let url = try fixture ?? AppTestSupport.writeFixturePDF(named: name, pageCount: pageCount)
        let document = try AppTestSupport.makeDocument(opening: url)
        forgetStoredWindowLayouts()
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let canvas = try #require(controller.canvasController(for: document))
        _ = canvas.view
        controller.window?.layoutIfNeeded()
        canvas.view.layoutSubtreeIfNeeded()
        canvas.viewDidAppear()
        if calibrate {
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
        }
        return Fix2Harness(
            document: document,
            controller: controller,
            core: core,
            shell: shell,
            canvas: canvas,
            directory: url.deletingLastPathComponent()
        )
    }

    /// Every harness window opens at the first-launch layout, whatever ran before it.
    ///
    /// The process layout store (``ZenitProcessDefaults/layout``, memory-only in a test process)
    /// lives as long as the test process, and a window writes its layout there on every panel
    /// change. Without this, a window inherited the previous test's panes: after
    /// `NLUXAppProposalTests.workspaceMenu` recalled a workspace with the Navigator collapsed,
    /// the LT3-09 accessibility guard found no Navigator and failed, and passed alone
    /// (L-04 re-check, iteration 2). Only the two window-layout keys are dropped; the rest of the
    /// store is left to the tests that own it.
    static func forgetStoredWindowLayouts() {
        let store = ProjectWindowLayoutStore(defaults: ZenitProcessDefaults.layout)
        store.reset()
        store.keyed(ProjectWindowController.secondWindowLayoutKey).reset()
    }

    func tearDown() {
        document.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Refreshes the core and the canvas and waits for the scene.
    func settle() async {
        await core.commands.settle()
        await core.refresh()
        canvas.refresh()
        await canvas.settleScene()
    }

    /// Adds one measurement straight through the command bus.
    @discardableResult
    func addMarkup(
        tool: MeasurementTool,
        geometry: (PageID) -> MeasurementGeometry,
        subject: String = "",
        pageIndex: Int = 0
    ) async throws -> MarkupRecord {
        let drawing = try #require(document.drawing)
        let page = drawing.pages[pageIndex]
        let record = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: tool,
            subject: subject,
            geometry: geometry(page.id),
            createdAt: Date(),
            modifiedAt: Date()
        )
        _ = try await core.commands.perform(.addMarkup(record))
        await settle()
        return record
    }

    func records() async -> [MarkupRecord] {
        await core.session.orderedMarkups
    }

    /// A synthetic mouse event at a point in the page view's own coordinates.
    func mouseEvent(_ type: NSEvent.EventType, atLocal point: CGPoint, clickCount: Int = 1) -> NSEvent {
        let pageView = canvas.pageViewForTesting
        let windowPoint = pageView.convert(point, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: pageView.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }
}
