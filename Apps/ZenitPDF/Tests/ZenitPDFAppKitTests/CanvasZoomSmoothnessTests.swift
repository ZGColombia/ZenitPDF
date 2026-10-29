import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// The zoom path behind gates Z11–Z14 (NL-PERF-02, -03, -04, -05, -06, -10) and the centring
/// defect LT3-10, as properties rather than milliseconds. Every window here is never ordered on
/// screen.
@MainActor
@Suite(.appTierSerialised)
struct CanvasZoomSmoothnessTests {

    private func settleRaster(_ harness: Fix2Harness) async {
        for _ in 0..<5 {
            await harness.canvas.settleRasterForTesting()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func centreWindowPoint(_ harness: Fix2Harness, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> NSPoint {
        let scrollView = harness.canvas.scrollViewForTesting
        return scrollView.convert(
            NSPoint(x: scrollView.contentSize.width * fx, y: scrollView.contentSize.height * fy),
            to: nil
        )
    }

    // MARK: - NL-PERF-02: never blank

    @Test("NL-PERF-02: the second zoom step keeps yesterday's tiles as the stand-in (the stale wipe)")
    func secondZoomStepKeepsTheStandIn() async throws {
        let harness = try await Fix2Harness.make("NLPERF02.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        let pageView = harness.canvas.pageViewForTesting
        #expect(!pageView.tileRasters.isEmpty, "no tiles were delivered")
        let anchor = centreWindowPoint(harness)
        harness.canvas.zoom(by: 1.1, aboutWindowPoint: anchor)
        #expect(!pageView.staleTileRasters.isEmpty, "the first step lost the stand-in")
        harness.canvas.zoom(by: 1.1, aboutWindowPoint: anchor)
        harness.canvas.zoom(by: 1.1, aboutWindowPoint: anchor)
        // Old: step 2 copied step 1's empty tile list over the stand-in, and the sheet went
        // blank until the render landed.
        #expect(!pageView.staleTileRasters.isEmpty, "a later step wiped the stand-in")
        #expect(harness.canvas.visiblePageCoverageForTesting() >= 0.999)
    }

    @Test("NL-PERF-02: the base raster is resident for the page's life and under everything")
    func baseRasterIsResident() async throws {
        let harness = try await Fix2Harness.make("NLPERF02b.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        let pageView = harness.canvas.pageViewForTesting
        #expect(await AppTestSupport.wait { pageView.baseRaster != nil }, "no base raster")
        #expect(!pageView.tileRasters.isEmpty)
        // Tiles landing do not throw the base away (the IM-045 thumbnail used to go).
        #expect(pageView.baseRaster != nil)
        let longSide = max(pageView.baseRaster?.image.width ?? 0, pageView.baseRaster?.image.height ?? 0)
        #expect(longSide <= PDFCanvasViewController.baseRasterPixelSize && longSide >= 1024)
        let raster = harness.canvas.documentViewForTesting.rasterView
        #expect(raster.displayed.contains { $0.role == .base })
        // A page turn never shows the previous sheet's base.
        let firstBase = pageView.baseRaster?.image
        harness.core.document.goToNextPage()
        harness.canvas.refresh()
        #expect(pageView.baseRaster?.image !== firstBase || pageView.baseRaster == nil)
        #expect(await AppTestSupport.wait { pageView.baseRaster != nil })
    }

    // MARK: - NL-PERF-05: layers, not blits

    @Test("NL-PERF-05: the live canvas draws no raster on the main thread; tiles are 1:1 layers (Z5, Z6)")
    func tilesAreLayersPlacedPixelExact() async throws {
        let harness = try await Fix2Harness.make("NLPERF05.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 1.37)
        harness.canvas.refresh()
        await settleRaster(harness)
        let pageView = harness.canvas.pageViewForTesting
        #expect(pageView.compositesRasters)
        #expect(!pageView.tileRasters.isEmpty)
        let rep = try #require(pageView.bitmapImageRepForCachingDisplay(in: pageView.visibleRect))
        pageView.cacheDisplay(in: pageView.visibleRect, to: rep)
        // Old: every tile was blitted — and every stale one resampled at `.high` — in draw(_:).
        #expect(pageView.tilesDrawnInLastPass == 0, "the page view drew rasters itself")

        let raster = harness.canvas.documentViewForTesting.rasterView
        let current = raster.displayed.filter { $0.role == .current }
        #expect(current.count == pageView.tileRasters.count)
        let backing = pageView.effectiveBackingScale
        for tile in current {
            for value in [tile.frame.minX, tile.frame.minY, tile.frame.width, tile.frame.height] {
                let device = value * backing
                #expect(abs(device - device.rounded()) < 1e-9, "Z6: tile layer frame \(tile.frame)")
            }
            #expect(abs(tile.frame.width * backing - CGFloat(tile.raster.image.width)) < 1e-6, "Z5: 1:1")
        }
        #expect(harness.canvas.viewportIsSharpForTesting)
    }

    @Test("NL-PERF-05: the layer tree puts a tile where the page view would have drawn it")
    func layerPlacementMatchesTheDrawnPlacement() throws {
        // A standalone pair: the legacy page view draws its raster, and the layered pair
        // composites the same raster. Rendered through Core Animation, the two must agree.
        let box = PDFRectValue(x: 0, y: 0, width: 400, height: 300)
        let transform = PageDisplayTransform(pageBox: box, rotation: 0, zoom: 1, origin: CGPoint(x: 20, y: 30))
        let image = try Self.halfRedImage(width: 400, height: 300)
        let raster = PageRaster(image: image, coverage: .region(box), scale: 1)

        let layered = CanvasPageView()
        layered.backingScaleOverride = 1
        let document = CanvasDocumentView(pageView: layered)
        document.frame = CGRect(x: 0, y: 0, width: 440, height: 360)
        layered.transform = transform
        layered.tileRasters = [raster]
        let displayed = document.rasterView.displayed.first { $0.role == .current }
        let expected = raster.placement(in: transform, backingScale: 1).destination
        #expect(displayed?.frame == expected)
        #expect(displayed?.frame == CGRect(x: 20, y: 30, width: 400, height: 300))
    }

    // MARK: - NL-PERF-04: the gesture is one transform, laid out once

    @Test("NL-PERF-04: a gesture lays out nothing until it ends, then once, keeping the anchor")
    func gestureLaysOutOnceAndKeepsTheAnchor() async throws {
        let harness = try await Fix2Harness.make("NLPERF04.pdf", calibrate: false)
        defer { harness.tearDown() }
        // Larger than the view on both axes, so the anchor rule rather than the centring rule
        // of LT3-10 decides where the sheet goes.
        harness.core.canvas.setZoom(2.5)
        harness.canvas.refresh()
        await settleRaster(harness)
        let canvas = harness.canvas
        let scrollView = canvas.scrollViewForTesting
        let pageView = canvas.pageViewForTesting
        let anchor = centreWindowPoint(harness, fx: 0.4, fy: 0.6)
        let transformBefore = try #require(pageView.transform)
        let pageUnderAnchor = transformBefore.pagePoint(from: pageView.convert(anchor, from: nil))
        let zoomBefore = harness.core.canvas.viewport.zoom
        let layouts = canvas.layoutCountForTesting
        let invalidations = pageView.pageInvalidationCount

        for index in 0..<20 {
            scrollView.handleZoomGesture(factor: 1.05, windowPoint: anchor, phase: index == 0 ? .began : .changed)
            canvas.displayFrameForTesting()
        }
        // Mid-gesture: no relayout, no redraw of the page, no zoom published yet — one transform.
        #expect(canvas.layoutCountForTesting == layouts, "a gesture step laid the page out")
        #expect(pageView.pageInvalidationCount == invalidations, "a gesture step redrew the page")
        #expect(harness.core.canvas.viewport.zoom == zoomBefore)
        let live = try #require(canvas.liveZoom)
        #expect(abs(live.scale - pow(1.05, 20)) < 1e-6)
        let sublayer = try #require(canvas.documentViewForTesting.layer?.sublayerTransform)
        #expect(!CATransform3DIsIdentity(sublayer), "the GPU transform was not applied")

        // A pointer that moves mid-gesture lands on the page point under it.
        let probe = harness.mouseEvent(.mouseMoved, atLocal: CGPoint(x: 300, y: 260))
        let local = pageView.convert(probe.locationInWindow, from: nil)
        let expected = transformBefore.pagePoint(from: local.applying(live.transform.inverted()))
        let converted = try #require(pageView.pagePointForTesting(probe))
        #expect(abs(converted.x - expected.x) < 1e-6 && abs(converted.y - expected.y) < 1e-6)

        scrollView.handleZoomGesture(factor: 1, windowPoint: anchor, phase: .ended)
        #expect(canvas.layoutCountForTesting == layouts + 1, "the end must lay out exactly once")
        #expect(abs(harness.core.canvas.viewport.zoom - zoomBefore * pow(1.05, 20)) < 1e-6)
        #expect(CATransform3DIsIdentity(canvas.documentViewForTesting.layer?.sublayerTransform ?? CATransform3DIdentity))
        #expect(pageView.liveDisplayTransform == nil)
        // The page point under the fingers is still under the fingers.
        let transformAfter = try #require(pageView.transform)
        let after = transformAfter.pagePoint(from: pageView.convert(anchor, from: nil))
        let tolerance = 1.0 / Double(transformAfter.zoom)
        #expect(abs(after.x - pageUnderAnchor.x) < tolerance && abs(after.y - pageUnderAnchor.y) < tolerance,
                "anchor moved from \(pageUnderAnchor) to \(after)")
        // And the markups are laid out for the new zoom: crisp, not a GPU-scaled copy.
        #expect(abs(Double(transformAfter.zoom) - harness.core.canvas.viewport.zoom) < 1e-9)
        #expect(pageView.pageInvalidationCount > invalidations)
    }

    @Test("NL-PERF-04: a press during a gesture lays it out first, so hit-testing is exact")
    func pressCommitsTheGestureAndHitTestingIsExact() async throws {
        let harness = try await Fix2Harness.make("NLPERF04b.pdf")
        defer { harness.tearDown() }
        let record = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 200), PDFPoint(x: 300, y: 200)])
        }
        let canvas = harness.canvas
        let anchor = centreWindowPoint(harness)
        for _ in 0..<10 {
            canvas.scrollViewForTesting.handleZoomGesture(factor: 1.07, windowPoint: anchor, phase: .changed)
            canvas.displayFrameForTesting()
        }
        #expect(canvas.liveZoom != nil)
        canvas.pageViewForTesting.onWillBeginInteraction?()
        #expect(canvas.liveZoom == nil, "a press must lay the gesture out before it is handled")
        #expect(canvas.hitTest(PDFPointValue(x: 200, y: 200)) == record.id.rawValue)
        let transform = try #require(canvas.pageViewForTesting.transform)
        let view = transform.viewPoint(from: PDFPointValue(x: 200, y: 200))
        let event = harness.mouseEvent(.leftMouseDown, atLocal: view)
        let point = try #require(canvas.pageViewForTesting.pagePointForTesting(event))
        #expect(abs(point.x - 200) < 1e-6 && abs(point.y - 200) < 1e-6)
    }

    @Test("NL-PERF-04: an idle gesture ends by itself; the end renders without a debounce")
    func idleGestureCommitsAndRendersAtOnce() async throws {
        let harness = try await Fix2Harness.make("NLPERF04c.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        let canvas = harness.canvas
        let anchor = centreWindowPoint(harness)
        canvas.scrollViewForTesting.handleZoomGesture(factor: 1.2, windowPoint: anchor, phase: .changed)
        canvas.displayFrameForTesting()
        #expect(canvas.liveZoom != nil)
        #expect(await AppTestSupport.wait(upTo: 2) { canvas.liveZoom == nil }, "the idle gesture never ended")
        #expect(canvas.lastRasterDebounceForTesting == 0, "a finished gesture waited for a debounce")
        await settleRaster(harness)
        #expect(canvas.viewportIsSharpForTesting)
    }

    @Test("NL-PERF-06: mid-gesture, level tiles render centre-out and are shown above the base")
    func levelTilesFillMidGesture() async throws {
        let harness = try await Fix2Harness.make("NLPERF06.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        let canvas = harness.canvas
        let anchor = centreWindowPoint(harness)
        for _ in 0..<12 {
            canvas.scrollViewForTesting.handleZoomGesture(factor: 1.08, windowPoint: anchor, phase: .changed)
            canvas.displayFrameForTesting()
        }
        #expect(canvas.levelQueue.startedCount + canvas.levelQueue.pendingCount > 0, "no level tile was asked for")
        await canvas.levelQueue.settle()
        let pageView = canvas.pageViewForTesting
        #expect(!pageView.levelTileRasters.isEmpty, "no level tile reached the screen mid-gesture")
        let live = try #require(canvas.liveZoom)
        let deviceScale = CGFloat(harness.core.canvas.viewport.zoom) * live.scale * pageView.effectiveBackingScale
        for tile in pageView.levelTileRasters {
            // A resident level is never more than 2x magnified; the wanted level never at all.
            #expect(deviceScale / tile.scale <= 2.0 + 1e-9, "level tile at \(tile.scale) for \(deviceScale)")
        }
        #expect(canvas.visiblePageCoverageForTesting() >= 0.999)
        canvas.scrollViewForTesting.handleZoomGesture(factor: 1, windowPoint: anchor, phase: .ended)
        await settleRaster(harness)
        #expect(canvas.viewportIsSharpForTesting)
        #expect(pageView.levelTileRasters.isEmpty, "level tiles must leave the screen once the exact pass lands")
    }

    @Test("NL-PERF-06: the level for a scale is the smallest power of two not below it")
    func levelChoice() throws {
        #expect(CanvasLevelGrid.exponent(forDeviceScale: 1.0) == 0)
        #expect(CanvasLevelGrid.exponent(forDeviceScale: 1.01) == 1)
        #expect(CanvasLevelGrid.exponent(forDeviceScale: 2.0) == 1)
        #expect(CanvasLevelGrid.exponent(forDeviceScale: 0.3) == -1)
        #expect(CanvasLevelGrid.exponent(forDeviceScale: 1_000) == 5)
        #expect(CanvasLevelGrid.exponent(forDeviceScale: 0.0001) == -4)
        let level = CanvasLevelGrid(
            pageIndex: 0, exponent: 1,
            pageBox: PDFRectValue(x: 0, y: 0, width: 2383.94, height: 1683.78), rotation: 0, generation: 0
        )
        let plan = try level.plan(column: 2, row: 1)
        #expect(plan.pixelSize.width == 512 && plan.pixelSize.height == 512)
        #expect(plan.scale == 2)
        #expect(plan.deviceRect == CGRect(x: 1024, y: 512, width: 512, height: 512))
    }

    // MARK: - NL-PERF-03 and bug 8

    @Test("NL-PERF-03: tiles are BGRA, the bridge's own format, copied without conversion")
    func tilesAreBGRA() throws {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        let image = try #require(context.makeImage())
        let copy = try #require(CanvasTileCache.copy(image))
        #expect(copy.alphaInfo == .premultipliedFirst)
        #expect(copy.bitmapInfo.contains(.byteOrder32Little))
    }

    @Test("Bug 8: a single Zoom-tool step renders at once; only a burst waits")
    func singleStepHasNoDebounce() async throws {
        let harness = try await Fix2Harness.make("Bug8.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        try await Task.sleep(for: .milliseconds(200))
        let anchor = centreWindowPoint(harness)
        harness.canvas.zoom(by: 1.6, aboutWindowPoint: anchor)
        #expect(harness.canvas.lastRasterDebounceForTesting == 0, "a single step paid the gesture debounce")
        harness.canvas.zoom(by: 1.1, aboutWindowPoint: anchor)
        #expect(harness.canvas.lastRasterDebounceForTesting > 0, "a burst must still coalesce (IM-170)")
        await settleRaster(harness)
    }

    // MARK: - NL-PERF-10

    @Test("NL-PERF-10: a memory warning keeps what is on screen and drops the rest")
    func memoryPressureKeepsTheVisibleTiles() async throws {
        let harness = try await Fix2Harness.make("NLPERF10.pdf", calibrate: false)
        defer { harness.tearDown() }
        let canvas = harness.canvas
        canvas.refresh()
        await settleRaster(harness)
        let zoom = harness.core.canvas.viewport.zoom
        for factor in [1.5, 2.2, 1.0] {
            harness.core.canvas.setZoom(zoom * factor)
            canvas.refresh()
            await settleRaster(harness)
        }
        let cache = canvas.tileCacheForTesting
        let visible = canvas.pageViewForTesting.tileRasters
        #expect(cache.tileCount > visible.count, "the scenario built no off-screen tiles")
        canvas.handleMemoryPressure(critical: false)
        #expect(cache.tileCount == visible.count, "\(cache.tileCount) tiles kept for \(visible.count) on screen")
        #expect(canvas.pageViewForTesting.tileRasters == visible)
        #expect(canvas.pageViewForTesting.baseRaster != nil, "the base keeps the sheet from going blank")
        #expect(CanvasTileCache.machineScaledBudget(physicalMemory: 4 << 30) < CanvasTileCache.byteBudget)
        #expect(CanvasTileCache.machineScaledBudget(physicalMemory: 32 << 30) == CanvasTileCache.byteBudget)
    }

    // MARK: - LT3-10: the sheet is centred and reachable

    /// Resizes the harness window so the canvas has `size`.
    private func resizeCanvas(_ harness: Fix2Harness, to size: CGSize) throws {
        let window = try #require(harness.controller.window)
        let scrollView = harness.canvas.scrollViewForTesting
        for _ in 0..<3 {
            let current = scrollView.contentSize
            let dw = size.width - current.width
            let dh = size.height - current.height
            guard abs(dw) > 0.5 || abs(dh) > 0.5 else { break }
            let content = window.contentRect(forFrameRect: window.frame).size
            window.setContentSize(NSSize(width: content.width + dw, height: content.height + dh))
            window.layoutIfNeeded()
            harness.canvas.view.layoutSubtreeIfNeeded()
        }
        #expect(!window.isVisible)
    }

    /// Every axis on which the sheet fits is centred; every part of the sheet can be scrolled to.
    private func expectCentredAndReachable(_ harness: Fix2Harness, _ context: String) throws {
        let canvas = harness.canvas
        let transform = try #require(canvas.pageViewForTesting.transform)
        let scrollView = canvas.scrollViewForTesting
        let visible = scrollView.documentVisibleRect
        let document = scrollView.contentView.documentRect
        let sheet = transform.pageFrame
        if sheet.width <= visible.width {
            #expect(abs(sheet.midX - visible.midX) <= 1, "\(context): sheet off centre horizontally, \(sheet) in \(visible)")
        }
        if sheet.height <= visible.height {
            #expect(abs(sheet.midY - visible.midY) <= 1, "\(context): sheet off centre vertically, \(sheet) in \(visible)")
        }
        #expect(document.contains(sheet), "\(context): part of the sheet is outside the document \(document)")
        // Reachable: the scroll range lets the visible rect reach each edge of the sheet.
        let maxOriginX = document.maxX - visible.width
        let maxOriginY = document.maxY - visible.height
        #expect(sheet.minX >= document.minX && sheet.maxX - visible.width <= maxOriginX + 0.5, "\(context): x unreachable")
        #expect(sheet.minY >= document.minY && sheet.maxY - visible.height <= maxOriginY + 0.5, "\(context): y unreachable")
    }

    @Test("LT3-10: the sheet is centred when it fits and fully reachable, over viewports and zooms")
    func sheetIsCentredAndReachable() async throws {
        let url = try ViewerGestureReplayTests.scratchRoofPlan(pages: 1)
        let harness = try await Fix2Harness.make("unused", calibrate: false, fixture: url)
        defer { harness.tearDown() }
        for viewport in [CGSize(width: 900, height: 600), CGSize(width: 1600, height: 1000), CGSize(width: 1100, height: 1400)] {
            try resizeCanvas(harness, to: viewport)
            harness.core.canvas.viewSize = harness.canvas.scrollViewForTesting.contentSize
            harness.core.canvas.zoomToFit()
            harness.canvas.refresh()
            try expectCentredAndReachable(harness, "fit at \(viewport)")
            for zoom in [0.19, 0.35, 1.0, 2.5] {
                harness.core.canvas.setZoom(zoom)
                harness.canvas.refresh()
                try expectCentredAndReachable(harness, "zoom \(zoom) at \(viewport)")
            }
        }
    }

    @Test("LT3-10: growing the window at 19 % keeps the A1 centred")
    func resizeKeepsTheSheetCentred() async throws {
        let url = try ViewerGestureReplayTests.scratchRoofPlan(pages: 1)
        let harness = try await Fix2Harness.make("unused", calibrate: false, fixture: url)
        defer { harness.tearDown() }
        try resizeCanvas(harness, to: CGSize(width: 900, height: 600))
        harness.core.canvas.setZoom(0.19)
        harness.canvas.refresh()
        try expectCentredAndReachable(harness, "before the resize")
        // Old: the pan margins grew with the viewport, the sheet moved with them and the scroll
        // origin did not — the sheet sat down and to the right with its far edges cut off.
        try resizeCanvas(harness, to: CGSize(width: 1800, height: 1100))
        try expectCentredAndReachable(harness, "after growing the window")
        try resizeCanvas(harness, to: CGSize(width: 700, height: 500))
        try expectCentredAndReachable(harness, "after shrinking the window")
    }

    @Test("LT3-10: Fit Page centres a sheet that was panned aside")
    func fitPageCentresAPannedSheet() async throws {
        let url = try ViewerGestureReplayTests.scratchRoofPlan(pages: 1)
        let harness = try await Fix2Harness.make("unused", calibrate: false, fixture: url)
        defer { harness.tearDown() }
        try resizeCanvas(harness, to: CGSize(width: 1200, height: 800))
        harness.core.canvas.setZoom(0.9)
        harness.canvas.refresh()
        let pageView = harness.canvas.pageViewForTesting
        let origin = harness.canvas.scrollViewForTesting.documentVisibleRect.origin
        pageView.scroll(NSPoint(x: origin.x + 350, y: origin.y + 240))
        harness.core.canvas.viewSize = harness.canvas.scrollViewForTesting.contentSize
        harness.core.canvas.zoomToFit()
        harness.canvas.refresh()
        try expectCentredAndReachable(harness, "after Fit Page")
        // A gesture that zooms out until the sheet fits lands centred, without a jump at the end.
        harness.core.canvas.setZoom(0.9)
        harness.canvas.refresh()
        let anchor = centreWindowPoint(harness, fx: 0.2, fy: 0.8)
        for _ in 0..<16 {
            harness.canvas.scrollViewForTesting.handleZoomGesture(factor: 0.9, windowPoint: anchor, phase: .changed)
            harness.canvas.displayFrameForTesting()
        }
        harness.canvas.scrollViewForTesting.handleZoomGesture(factor: 1, windowPoint: anchor, phase: .ended)
        try expectCentredAndReachable(harness, "after a zoom-out gesture")
    }

    // MARK: - A style change is not a tool switch

    @Test("A style-only toolbar change restyles the text box being typed; a tool switch still cancels it")
    func styleChangeKeepsTheTextBox() async throws {
        let harness = try await Fix2Harness.make("StyleKeepsText.pdf")
        defer { harness.tearDown() }
        harness.shell.perform(.textTool)
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .markup(.text))
        harness.canvas.handleClick(at: PDFPointValue(x: 120, y: 500), additive: false)
        #expect(harness.canvas.activeTextEntry != nil)
        harness.canvas.typeIntoTextEntry("Rivning")
        let sizeBefore = try #require(harness.canvas.textEditorForTesting?.font?.pointSize)

        // The same tool re-armed with a new style — exactly what `ZenitToolbarModel.setStyle`
        // does — through `arm`, so the persisted tool style that other windows restore is not
        // written: app-tier suites run concurrently, and a doubled text size left in that store
        // made `ToolStyleReachesTheToolTests` start from the wrong ink.
        var selection = harness.shell.toolbar.activeSelection
        var style = selection.style
        style.fontSize *= 2
        selection.style = style
        harness.shell.toolbar.arm(selection)
        harness.canvas.refresh()
        // Old: any change of the toolbar selection cancelled the box and lost the typing.
        #expect(harness.canvas.activeTextEntry != nil, "a style change threw the text box away")
        #expect(harness.core.markup.draftText == "Rivning")
        // L-49: a box typed zoomed out stores its words at the size the tool names on screen, so
        // the new size is applied at the box's creation scale (1 at 100 % and closer).
        let scale = try #require(harness.canvas.activeTextEntry?.textScale)
        #expect(harness.core.markup.style.fontSize == style.fontSize * scale)
        let sizeAfter = try #require(harness.canvas.textEditorForTesting?.font?.pointSize)
        #expect(sizeAfter >= sizeBefore, "the box did not take the new text size")

        harness.shell.perform(.selectTool)
        harness.canvas.refresh()
        #expect(harness.canvas.activeTextEntry == nil, "a tool switch must still end the box")
    }

    // MARK: - nl-ux: the underlay's layer filter belongs to its page

    @Test("The vector underlay takes a layer filter only on the page the filter belongs to")
    func underlayFilterIsPageScoped() async throws {
        let harness = try await Fix2Harness.make("UnderlayScope.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing)
        let extraction = try await ZPDFVectorExtraction.VectorExtractor().extract(documentAt: drawing.url, pageIndex: 1)
        harness.canvas.setLayerFiltering(.init(extraction: extraction, hiddenLayerIDs: ["OC1"], pageIndex: 1))
        #expect(harness.canvas.underlayHiddenLayerIDs(forPageIndex: 1) == ["OC1"])
        #expect(harness.canvas.underlayHiddenLayerIDs(forPageIndex: 0).isEmpty,
                "page 2's hidden layers must not thin page 1's skeleton")
        harness.canvas.setLayerFiltering(nil)
        #expect(harness.canvas.underlayHiddenLayerIDs(forPageIndex: 1).isEmpty)
    }

    // MARK: - Support

    static func halfRedImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return try #require(context.makeImage())
    }
}
