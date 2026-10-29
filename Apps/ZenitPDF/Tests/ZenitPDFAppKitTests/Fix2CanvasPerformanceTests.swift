import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Bug hunt 2, canvas performance: every claim here is a counter, not a feeling. The canvas
/// used to rebuild its scene per pointer move, draw every markup per frame and re-rasterise the
/// whole viewport per pan; these pin each of those shut.
@MainActor
@Suite(.appTierSerialised)
struct Fix2CanvasPerformanceTests {

    /// `count` small lengths spread over the sheet, landed as one batch.
    private func seed(_ harness: Fix2Harness, count: Int, pageIndex: Int = 0) async throws {
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[pageIndex]
        var commands: [DocumentCommand] = []
        for index in 0..<count {
            let x = 60 + Double(index % 40) * 12
            let y = 80 + Double(index / 40) * 9
            commands.append(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()),
                documentID: drawing.documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .length,
                subject: "",
                geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: x, y: y), PDFPoint(x: x + 8, y: y)]),
                createdAt: Date(),
                modifiedAt: Date()
            )))
        }
        try await harness.core.commands.performBatch(commands, actionName: "Seed")
        await harness.settle()
    }

    // MARK: - IM-040 / IM-041: a pointer move neither re-lays the page nor refetches the scene

    @Test("IM-040: 100 pointer moves with a tool armed cost no layout and no scene fetch")
    func pointerMovesAreLiveOnly() async throws {
        let harness = try await Fix2Harness.make("IM040.pdf")
        defer { harness.tearDown() }
        try await seed(harness, count: 400)
        harness.shell.perform(.measureLength)
        await harness.settle()
        try await Task.sleep(for: .milliseconds(200))
        let layouts = harness.canvas.layoutCountForTesting
        let fetches = harness.canvas.sceneFetchCountForTesting
        var last = PDFPointValue(x: 0, y: 0)
        for step in 0..<100 {
            last = PDFPointValue(x: 100 + Double(step), y: 300 + Double(step % 7))
            harness.canvas.handlePointerMove(last)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(300))
        // Old: every observed change ran `refresh()` — a layout and a scene fetch per move,
        // twice (cursor, then snap feedback): ~200 of each here.
        #expect(harness.canvas.layoutCountForTesting - layouts == 0,
                "\(harness.canvas.layoutCountForTesting - layouts) layouts for pointer moves")
        #expect(harness.canvas.sceneFetchCountForTesting - fetches == 0,
                "\(harness.canvas.sceneFetchCountForTesting - fetches) scene fetches for pointer moves")
        #expect(harness.canvas.pageViewForTesting.liveCursorPoint == last, "the live cursor stopped following")
    }

    @Test("IM-041: the scene holds only the current sheet's records")
    func sceneIsPageScoped() async throws {
        let harness = try await Fix2Harness.make("IM041.pdf", pageCount: 2)
        defer { harness.tearDown() }
        try await seed(harness, count: 30, pageIndex: 0)
        try await seed(harness, count: 50, pageIndex: 1)
        await harness.settle()
        // Old: the whole document — 80 records — for a page that shows 30.
        #expect(harness.canvas.sceneRecordCountForTesting == 30)
    }

    // MARK: - IM-042: the scene is incremental

    @Test("IM-042: an unchanged scene recompiles nothing, one edit recompiles one")
    func sceneBuildIsIncremental() async throws {
        let harness = try await Fix2Harness.make("IM042.pdf")
        defer { harness.tearDown() }
        try await seed(harness, count: 300)
        let records = await harness.records()
        let pageID = try #require(harness.document.drawing?.pages.first?.id.rawValue)
        let cache = CanvasShapeCache()
        let first = CanvasSceneBuilder.build(records: records, summaries: [], pageID: pageID, cache: cache)
        #expect(cache.compileCount == 300)
        let second = CanvasSceneBuilder.build(records: records, summaries: [], pageID: pageID, cache: cache)
        // Old: every pass recompiled every record.
        #expect(cache.compileCount == 300, "an identical pass recompiled \(cache.compileCount - 300)")
        #expect(first == second)
        var edited = records
        edited[7].geometry = MeasurementGeometry(
            pageID: edited[7].pageID, points: [PDFPoint(x: 1, y: 1), PDFPoint(x: 50, y: 1)]
        )
        let third = CanvasSceneBuilder.build(records: edited, summaries: [], pageID: pageID, cache: cache)
        #expect(cache.compileCount == 301)
        #expect(third == CanvasSceneBuilder.build(records: edited, summaries: [], pageID: pageID),
                "the cached scene differs from a from-scratch build")
    }

    @Test("IM-042: a 20-frame drag of one markup recompiles about one shape per frame")
    func dragRecompilesOnlyTheDraggedShape() async throws {
        let harness = try await Fix2Harness.make("IM042b.pdf")
        defer { harness.tearDown() }
        try await seed(harness, count: 300)
        harness.shell.perform(.selectTool)
        // The seeds sit 9 pt apart; at a fit zoom of the harness window (about 50 %) the 6-pt
        // hit radius is wider than that, and the grab would land on a neighbour. Zoom in so
        // the grab names exactly one markup whatever size the window's panes leave the canvas.
        harness.core.canvas.setZoom(2)
        harness.canvas.refresh()
        await harness.settle()
        let target = try #require(await harness.records().first)
        let start = try #require(target.geometry?.points.first)
        let grab = PDFPointValue(x: start.x + 4, y: start.y)
        #expect(harness.canvas.hitTest(grab) == target.id.rawValue)
        let before = harness.canvas.shapeCompileCountForTesting
        harness.canvas.handleDragBegan(at: grab)
        for step in 1...20 {
            harness.canvas.handleDragMoved(to: PDFPointValue(x: grab.x + Double(step), y: grab.y + Double(step)))
        }
        let during = harness.canvas.shapeCompileCountForTesting - before
        // Old: 300 records × 20 frames = 6 000 compiles (plus a refetch per frame).
        #expect(during <= 25, "\(during) compiles for a 20-frame drag of one markup")
        harness.canvas.cancelSelectDrag()
    }

    // MARK: - IM-038 / IM-039: culling and the live overlay

    @Test("IM-038: a small invalidation strokes only the shapes it can reach, pixel for pixel")
    func drawIsCulledToTheDirtyRect() async throws {
        let harness = try await Fix2Harness.make("IM038.pdf")
        defer { harness.tearDown() }
        // Four hundred short lengths spread over the whole sheet, drawn zoomed in.
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        var commands: [DocumentCommand] = []
        for index in 0..<400 {
            let x = 20 + Double(index % 20) * 27
            let y = 20 + Double(index / 20) * 38
            commands.append(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id,
                kind: .measurement, tool: .length, subject: "",
                geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: x, y: y), PDFPoint(x: x + 8, y: y)]),
                createdAt: Date(), modifiedAt: Date()
            )))
        }
        try await harness.core.commands.performBatch(commands, actionName: "Seed")
        harness.core.canvas.setZoom(3)
        await harness.settle()
        let pageView = harness.canvas.pageViewForTesting
        pageView.backingScaleOverride = 1
        let transform = try #require(pageView.transform)
        let total = pageView.shapes.count
        #expect(total == 400)
        let corner = transform.viewPoint(from: PDFPointValue(x: 200, y: 400))
        let small = CGRect(x: corner.x - 60, y: corner.y - 60, width: 120, height: 120).integral

        let culled = pageView.bitmapImageRepForCachingDisplay(in: small)!
        pageView.cacheDisplay(in: small, to: culled)
        let drawnSmall = pageView.shapesDrawnInLastPass
        pageView.cullsToDirtyRect = false
        let unculled = pageView.bitmapImageRepForCachingDisplay(in: small)!
        pageView.cacheDisplay(in: small, to: unculled)
        let drawnAll = pageView.shapesDrawnInLastPass
        pageView.cullsToDirtyRect = true

        // Old: every one of the 400 was stroked for any dirty rect.
        #expect(drawnAll == 400)
        #expect(drawnSmall > 0 && drawnSmall < total / 8,
                "\(drawnSmall) of \(total) shapes stroked for a 120-pt invalidation at 300 %")
        let a = Data(bytes: culled.bitmapData!, count: culled.bytesPerPlane)
        let b = Data(bytes: unculled.bitmapData!, count: unculled.bytesPerPlane)
        #expect(a == b, "culling changed the pixels")
    }

    @Test("IM-038 / IM-039: identical assignments do not invalidate; live changes touch only the overlay")
    func liveStateInvalidatesOnlyTheOverlay() async throws {
        let harness = try await Fix2Harness.make("IM039.pdf")
        defer { harness.tearDown() }
        try await seed(harness, count: 20)
        let pageView = harness.canvas.pageViewForTesting
        let invalidations = pageView.pageInvalidationCount
        let liveChanges = pageView.liveChangeCount
        // The same values again, as every refresh pass assigns them.
        let shapes = pageView.shapes
        let transform = pageView.transform
        let selection = pageView.selection
        pageView.shapes = shapes
        pageView.transform = transform
        pageView.selection = selection
        #expect(pageView.pageInvalidationCount == invalidations, "re-assigning identical values repainted the page")
        // A pointer-rate change.
        pageView.liveCursorPoint = PDFPointValue(x: 123, y: 456)
        pageView.snapPoint = PDFPointValue(x: 124, y: 456)
        // Old: every live property set `needsDisplay` on the page view itself — the raster and
        // every committed markup repainted per pointer move.
        #expect(pageView.pageInvalidationCount == invalidations, "a live change repainted the page view")
        #expect(pageView.liveChangeCount == liveChanges + 2, "the overlay did not hear the live change")
        #expect(pageView.liveOverlay.superview === pageView && pageView.liveOverlay.frame == pageView.bounds)
        #expect(pageView.liveOverlay.hitTest(NSPoint(x: 10, y: 10)) == nil, "the overlay must not take events")
    }

    // MARK: - IM-044 / IM-045 / BH-884 / IM-170 / IM-241: the tiled raster

    private func settleRaster(_ harness: Fix2Harness) async {
        for _ in 0..<5 {
            await harness.canvas.settleRasterForTesting()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    @Test("IM-044: a zoom back to the previous zoom is served from tiles, with no render")
    func zoomBackIsServedFromTiles() async throws {
        let harness = try await Fix2Harness.make("IM044.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        let cache = harness.canvas.tileCacheForTesting
        #expect(await AppTestSupport.wait { cache.tileCount > 0 }, "no tiles were ever rendered")
        let zoom = harness.core.canvas.viewport.zoom
        let firstPixels = cache.renderedPixelCount
        harness.core.canvas.setZoom(zoom * 2)
        harness.canvas.refresh()
        await settleRaster(harness)
        #expect(cache.renderedPixelCount > firstPixels, "the new zoom rendered nothing")
        let afterZoomIn = cache.renderedPixelCount
        harness.core.canvas.setZoom(zoom)
        harness.canvas.refresh()
        await settleRaster(harness)
        // Old: the viewport was re-rasterised from scratch — every pixel again.
        #expect(cache.renderedPixelCount == afterZoomIn,
                "zooming back rendered \(cache.renderedPixelCount - afterZoomIn) pixels already cached")
        #expect(!harness.canvas.pageViewForTesting.tileRasters.isEmpty)
        #expect(cache.byteCount <= CanvasTileCache.byteBudget)
    }

    @Test("IM-044 / BH-890: every tile raster is bounded far under the 32 MiB viewport ceiling")
    func tilesAreBounded() async throws {
        let harness = try await Fix2Harness.make("BH890.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 3)
        harness.canvas.refresh()
        await settleRaster(harness)
        let tiles = harness.canvas.pageViewForTesting.tileRasters
        #expect(!tiles.isEmpty)
        for tile in tiles {
            #expect(tile.image.width <= 512 && tile.image.height <= 512)
            #expect(tile.image.bytesPerRow * tile.image.height <= ViewportRasterPlanner.maximumViewportRasterBytes / 32)
        }
    }

    @Test("IM-045: turning the page drops the old sheet's pixels at once")
    func pageTurnDropsTheOldSheet() async throws {
        let harness = try await Fix2Harness.make("IM045.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        #expect(!harness.canvas.pageViewForTesting.tileRasters.isEmpty)
        harness.core.document.goToNextPage()
        harness.canvas.refresh()
        // Old: the previous sheet's raster stayed on screen, fitted to the new sheet's frame,
        // until the new render landed.
        #expect(harness.canvas.pageViewForTesting.tileRasters.isEmpty)
        #expect(harness.canvas.pageViewForTesting.staleTileRasters.isEmpty)
    }

    @Test("BH-884: a failed render does not leave its plan pending against every retry")
    func failedRenderIsRetried() async throws {
        let harness = try await Fix2Harness.make("BH884.pdf", calibrate: false)
        defer { harness.tearDown() }
        let source = try #require(harness.document.drawing?.rasterSource)
        await source.close()
        harness.canvas.invalidateRasterTiles()
        harness.canvas.refresh()
        await settleRaster(harness)
        let failures = harness.canvas.rasterFailureCountForTesting
        #expect(failures >= 1)
        harness.canvas.refresh()
        await settleRaster(harness)
        // Old: `pendingPlan == plan` swallowed the retry for as long as the viewport held still.
        #expect(harness.canvas.rasterFailureCountForTesting > failures, "the retry never ran")
    }

    @Test("IM-170: a burst of zoom steps renders once, not once per step")
    func zoomBurstIsCoalesced() async throws {
        let harness = try await Fix2Harness.make("IM170.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        let before = harness.canvas.rasterRenderStartCountForTesting
        for _ in 0..<8 {
            harness.canvas.zoom(by: 1.08, aboutWindowPoint: NSPoint(x: 100, y: 100))
            harness.canvas.refresh()
        }
        await settleRaster(harness)
        let renders = harness.canvas.rasterRenderStartCountForTesting - before
        // Old: one render started per step (each cancelled by the next).
        #expect(renders <= 2, "\(renders) renders for one 8-step gesture")
    }

    @Test("IM-241: a canvas that leaves the screen gives its raster back")
    func offscreenCanvasReleasesRasters() async throws {
        let harness = try await Fix2Harness.make("IM241.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        #expect(harness.canvas.tileCacheForTesting.byteCount > 0)
        harness.canvas.viewDidDisappear()
        #expect(harness.canvas.tileCacheForTesting.byteCount == 0)
        #expect(harness.canvas.pageViewForTesting.tileRasters.isEmpty)
        #expect(harness.canvas.pageViewForTesting.pageRaster == nil)
    }

    // MARK: - IM-171 / BH-883: the layer-filtered render

    @Test("IM-171 / BH-883: the filtered render culls, cancels, and never inks a clip path")
    func filteredRenderCullsAndCancels() async throws {
        let harness = try await Fix2Harness.make("IM171.pdf", calibrate: false)
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing)
        let extraction = try await VectorExtractor().extract(documentAt: drawing.url, pageIndex: 0)
        #expect(!extraction.primitives.isEmpty)
        let page = try #require(harness.core.document.currentPage)
        let whole = LayerRenderingTests.wholePagePlan(page: page, scale: 1)
        let filtering = LayerFilteredPageRenderer.Filtering(extraction: extraction, hiddenLayerIDs: [])

        // Cancellation: two thousand primitives, cancelled from the start → no image.
        func copy(_ p: VectorPrimitive, paint: VectorPaintRole? = nil, id: UInt64? = nil) -> VectorPrimitive {
            VectorPrimitive(
                id: id ?? p.id, parentID: p.parentID, kind: p.kind, geometry: p.geometry, bounds: p.bounds,
                sourceObjectID: p.sourceObjectID, subpathIndex: p.subpathIndex, nestingDepth: p.nestingDepth,
                paint: paint ?? p.paint, strokeWidth: p.strokeWidth, strokeIsDashed: p.strokeIsDashed,
                clipRelation: p.clipRelation, clipBounds: p.clipBounds, confidence: p.confidence, layerID: p.layerID
            )
        }
        func extractionWith(_ primitives: [VectorPrimitive]) -> VectorPageExtraction {
            VectorPageExtraction(
                cacheKey: extraction.cacheKey, availability: extraction.availability,
                partialReasons: extraction.partialReasons, primitives: primitives,
                rasterRegions: extraction.rasterRegions, filterDecisions: extraction.filterDecisions,
                pageTransform: extraction.pageTransform, statistics: extraction.statistics
            )
        }
        let base = extraction.primitives[0]
        let many = (0..<2000).map { copy(base, id: UInt64(100_000 + $0)) }
        let cancelled = LayerFilteredPageRenderer.render(
            filtering: .init(extraction: extractionWith(many), hiddenLayerIDs: []),
            page: page, plan: whole, isCancelled: { true }
        )
        // Old: the detached render ran to the end whatever happened to its task.
        #expect(cancelled == nil)

        // A clip-only primitive is never ink.
        let clipOnly = extractionWith(extraction.primitives.map { copy($0, paint: [.clipDerived]) })
        let blank = try #require(LayerFilteredPageRenderer.render(
            filtering: .init(extraction: clipOnly, hiddenLayerIDs: []), page: page, plan: whole
        ))
        let painted = try #require(LayerFilteredPageRenderer.render(filtering: filtering, page: page, plan: whole))
        #expect(Self.inkPixelCount(blank) == 0, "a clip path was stroked as linework")
        #expect(Self.inkPixelCount(painted) > 0)
    }

    private static func inkPixelCount(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        let bytesPerPixel = image.bitsPerPixel / 8
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * bytesPerPixel
                if data[offset] < 200 { count += 1 }
            }
        }
        return count
    }
}
