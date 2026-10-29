import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The zoom completion: `⌘*` zoom-to-selection and marquee zoom.
/// The arithmetic is proven here in closed form; the gesture plumbing is proven by the
/// shell tests (the command and the tool) and the canvas wiring below.
@MainActor
@Suite(.appTierSerialised)
struct ZoomCompletionTests {

    @Test("Fitting a rect chooses the axis that binds and pads both sides")
    func fitPicksTheBindingAxis() throws {
        // A wide target in a square viewport: width binds.
        let fit = try #require(ZoomMath.fit(
            target: PDFRectValue(x: 100, y: 200, width: 200, height: 50),
            in: CGSize(width: 500, height: 500)
        ))
        // zoom = 500 / (200 * 1.24) = 2.016…
        #expect(abs(fit.zoom - 500.0 / 248.0) < 1e-9)
        // The visible rect is the viewport at that zoom, centred on the target's centre.
        #expect(abs(fit.visiblePageRect.size.width - 500.0 / fit.zoom) < 1e-9)
        #expect(abs(fit.visiblePageRect.minX + fit.visiblePageRect.size.width / 2 - 200) < 1e-9)
        #expect(abs(fit.visiblePageRect.minY + fit.visiblePageRect.size.height / 2 - 225) < 1e-9)
        // The padded target actually fits at the chosen zoom, both axes.
        #expect(fit.visiblePageRect.size.width >= 200 * 1.24 - 1e-9)
        #expect(fit.visiblePageRect.size.height >= 50 * 1.24 - 1e-9)
    }

    @Test("The zoom clamps to 5%-6400% and the target stays centred when it does")
    func fitClampsToSupportedRange() throws {
        // A microscopic target would want an absurd zoom: the clamp wins.
        let tiny = try #require(ZoomMath.fit(
            target: PDFRectValue(x: 50, y: 50, width: 0.01, height: 0.01),
            in: CGSize(width: 1_000, height: 1_000)
        ))
        #expect(tiny.zoom == ViewportSnapshot.maximumZoom)
        #expect(abs(tiny.visiblePageRect.minX + tiny.visiblePageRect.size.width / 2 - 50.005) < 1e-6)

        // A page-dwarfing target clamps to the minimum instead.
        let huge = try #require(ZoomMath.fit(
            target: PDFRectValue(x: 0, y: 0, width: 1_000_000, height: 1_000_000),
            in: CGSize(width: 500, height: 500)
        ))
        #expect(huge.zoom == ViewportSnapshot.minimumZoom)

        // A zero-size viewport cannot be fitted into; the answer is a refusal, not a crash.
        #expect(ZoomMath.fit(target: PDFRectValue(x: 0, y: 0, width: 10, height: 10), in: .zero) == nil)
    }

    @Test("A degenerate selection — one count point — gets a working span, not infinity")
    func fitWidensDegenerateTargets() throws {
        let fit = try #require(ZoomMath.fit(
            target: PDFRectValue(x: 300, y: 400, width: 0, height: 0),
            in: CGSize(width: 800, height: 600)
        ))
        #expect(fit.zoom.isFinite)
        #expect(fit.zoom <= ViewportSnapshot.maximumZoom)
        #expect(abs(fit.visiblePageRect.minX + fit.visiblePageRect.size.width / 2 - 300) < 1e-9)
    }

    @Test("The selection union is the tight bounds over every selected markup")
    func unionIsTight() throws {
        let union = try #require(ZoomMath.union(of: [
            PDFRectValue(x: 10, y: 20, width: 30, height: 40),
            PDFRectValue(x: 100, y: 5, width: 10, height: 10),
            PDFRectValue(x: 0, y: 50, width: 5, height: 5)
        ]))
        #expect(union.minX == 0)
        #expect(union.minY == 5)
        #expect(abs(union.size.width - 110) < 1e-12)
        #expect(abs(union.size.height - 55) < 1e-12)
        #expect(ZoomMath.union(of: []) == nil, "an empty selection has nothing to fit")
    }

    @Test("Zoom to selection drives the canvas viewport onto the selected markup")
    func zoomToSelectionMovesTheViewport() async throws {
        let url = try AppTestSupport.writeFixturePDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait {
            controller.contentViewController is ProjectWindowLayoutController
        })
        controller.window?.layoutIfNeeded()
        let core = try #require(document.core)

        // Draw one small measurement and select it.
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        core.measurement.activate(kind: .length)
        core.measurement.setPage(PageID(core.canvas.viewport.pageID))
        core.measurement.placePoint(PDFPointValue(x: 100, y: 100))
        core.measurement.placePoint(PDFPointValue(x: 140, y: 100))
        await core.measurement.settlePlacements()
        core.measurement.commitActiveMeasurement()
        #expect(await AppTestSupport.wait { !core.canvas.visibleMarkups.isEmpty })
        let markup = try #require(core.canvas.visibleMarkups.first)
        core.canvas.select(markupIDs: [markup.id], additive: false)

        let layout = try #require(controller.contentViewController as? ProjectWindowLayoutController)
        // The canvas lives inside `CanvasPaneContainerViewController` (the shell never removes
        // it, so a view mode can cover it without disturbing the viewport); the zoom under test
        // is still the real canvas controller's.
        let pane = try #require(
            layout.contentSplitController.splitViewItems[1].viewController
                as? CanvasPaneContainerViewController
        )
        let canvas = try #require(pane.canvasController as? PDFCanvasViewController)
        let zoomBefore = core.canvas.viewport.zoom
        canvas.zoomToSelection()
        let viewport = core.canvas.viewport
        #expect(viewport.zoom != zoomBefore, "fitting a 40 pt markup must change the zoom")
        // The markup's centre is inside the visible page rect after the fit.
        #expect(viewport.visiblePageRect.minX <= 120 && 120 <= viewport.visiblePageRect.minX + viewport.visiblePageRect.size.width)
        #expect(viewport.visiblePageRect.minY <= 100 && 100 <= viewport.visiblePageRect.minY + viewport.visiblePageRect.size.height)

        document.close()
    }

    @Test("The menu enables Zoom to Selection exactly when something is selected")
    func zoomToSelectionValidation() async throws {
        let url = try AppTestSupport.writeFixturePDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { document.core != nil })

        let item = NSMenuItem()
        item.representedObject = "zenit.view.zoomToSelection"
        item.action = #selector(ProjectWindowController.performZenitCommand(_:))
        #expect(!controller.validateMenuItem(item), "nothing selected: the item is disabled")

        document.close()
    }
}
