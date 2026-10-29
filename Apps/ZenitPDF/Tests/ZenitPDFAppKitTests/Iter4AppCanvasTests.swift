import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Iteration-4 app-canvas fixes (iteration-4 findings), against the shipping window
/// and canvas. No window is ordered front and every modal goes through `ZenitModalPresenter`.
@MainActor
@Suite(.appTierSerialised)
struct Iter4AppCanvasTests {

    private static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    private static func settleRaster(_ harness: Fix2Harness) async {
        for _ in 0..<5 {
            await harness.canvas.settleRasterForTesting()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    // MARK: - U-001 a zoom back retires the render for the zoom the view left

    /// ⌘+ then ⌘− before the ⌘+ render landed: the zoom is back where the delivered tiles were
    /// made, so the viewport must be sharp again, and the ⌘+ render must never land over it.
    ///
    /// Old output: the satisfies return left the ⌘+ render live and the delivered tiles in the
    /// stand-in list — `tileRasters` held the 2× cache hits (none), the 2× render started
    /// (`rasterRenderStartCountForTesting` + 1) and landed 2× tiles placed at magnification 0.5,
    /// so `viewportIsSharpForTesting` stayed false until the next scroll.
    @Test("U-001: ⌘+ then ⌘− before the render lands leaves the sheet sharp, and the 2× render never lands")
    func zoomBackBeforeTheRenderLands() async throws {
        let harness = try await Fix2Harness.make("Iter4 Zoom Back.pdf", calibrate: false)
        defer { harness.tearDown() }
        let canvas = harness.canvas
        canvas.refresh()
        await Self.settleRaster(harness)
        #expect(canvas.viewportIsSharpForTesting, "precondition: the fitted sheet settles sharp")
        let delivered = canvas.pageViewForTesting.tileRasters
        #expect(!delivered.isEmpty)
        let zoom = harness.core.canvas.viewport.zoom
        let starts = canvas.rasterRenderStartCountForTesting

        harness.core.canvas.setZoom(zoom * 2)
        canvas.refresh()
        #expect(canvas.pageViewForTesting.staleTileRasters == delivered, "the ⌘+ step keeps the old tiles as stand-ins")
        harness.core.canvas.setZoom(zoom)
        canvas.refresh()
        // At once, not after a render: the delivered tiles are the current ones again.
        #expect(canvas.pageViewForTesting.tileRasters == delivered)
        #expect(canvas.pageViewForTesting.staleTileRasters.isEmpty)

        await Self.settleRaster(harness)
        #expect(canvas.rasterRenderStartCountForTesting == starts, "the render for the zoom the view left still ran")
        #expect(canvas.pageViewForTesting.tileRasters == delivered, "another zoom's tiles replaced the sheet")
        #expect(canvas.viewportIsSharpForTesting, "the round trip left the viewport soft")
    }

    /// The other early return: a zoom whose tiles are all cached is served without a render, and
    /// the render still in flight for the zoom before it must not land on top.
    ///
    /// Zooms below fit, so the whole sheet is in view at each of them and the tiles a zoom needs
    /// do not depend on where a centred scroll lands.
    ///
    /// Old output: the ⅓× render landed after the ½× view was served from the cache, replaced the
    /// ½× tiles with ⅓× ones (magnification 3/2) and `viewportIsSharpForTesting` was false.
    @Test("U-001: a zoom served from the cache retires the render in flight for the previous zoom")
    func cachedZoomRetiresTheRenderInFlight() async throws {
        let harness = try await Fix2Harness.make("Iter4 Cached Zoom.pdf", calibrate: false)
        defer { harness.tearDown() }
        let canvas = harness.canvas
        canvas.refresh()
        await Self.settleRaster(harness)
        let zoom = harness.core.canvas.viewport.zoom
        // Fill the cache at ½×, then move on to ¼×.
        harness.core.canvas.setZoom(zoom / 2)
        canvas.refresh()
        await Self.settleRaster(harness)
        let half = canvas.pageViewForTesting.tileRasters
        #expect(!half.isEmpty)
        #expect(canvas.viewportIsSharpForTesting)
        harness.core.canvas.setZoom(zoom / 4)
        canvas.refresh()
        await Self.settleRaster(harness)

        let starts = canvas.rasterRenderStartCountForTesting
        harness.core.canvas.setZoom(zoom / 3)      // not cached: a render starts
        canvas.refresh()
        harness.core.canvas.setZoom(zoom / 2)      // all cached: served at once
        canvas.refresh()
        #expect(canvas.pageViewForTesting.tileRasters == half)
        await Self.settleRaster(harness)
        #expect(canvas.rasterRenderStartCountForTesting == starts, "the ⅓× render still ran")
        #expect(canvas.pageViewForTesting.tileRasters == half, "the ⅓× render replaced the ½× tiles")
        #expect(canvas.viewportIsSharpForTesting)
    }

    /// The guard on the fix itself: a same-sized next sheet must not "satisfy" the previous
    /// sheet's delivered plan, or the zoom-back path would retire the new sheet's first render.
    /// Two refreshes before the render lands are what every observed change does after a turn.
    @Test("U-001: turning to a same-sized sheet and refreshing before its render lands still renders it")
    func pageTurnKeepsTheNewSheetsRender() async throws {
        let harness = try await Fix2Harness.make("Iter4 Page Turn.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let canvas = harness.canvas
        canvas.refresh()
        await Self.settleRaster(harness)
        let first = canvas.pageViewForTesting.tileRasters
        #expect(!first.isEmpty)
        harness.core.document.goToNextPage()
        canvas.refresh()
        canvas.refresh()
        await Self.settleRaster(harness)
        #expect(harness.core.canvas.viewport.pageIndex == 1)
        let second = canvas.pageViewForTesting.tileRasters
        #expect(!second.isEmpty, "the second sheet's render was retired")
        #expect(Set(second.map { ObjectIdentifier($0.image) }).isDisjoint(with: first.map { ObjectIdentifier($0.image) }))
        #expect(canvas.viewportIsSharpForTesting)
    }

    // MARK: - U-002 the resident base raster honours the layer filter

    /// The three-layer fixture's marked-content names (`LayerRenderingTests`).
    private static let wallsName = "L0"
    private static let gridName = "L2"
    /// On the first Walls rectangle's left edge (x = 100, y 600–700).
    private static let wallsEdge = PDFPointValue(x: 100, y: 650)
    /// On the Grid line (y = 300), which the file ships hidden (`/D /OFF`).
    private static let gridPoint = PDFPointValue(x: 250, y: 300)

    /// Mean darkness (0 white, 1 black) of a 7 × 7 window of a whole-page image around a page
    /// point. The image is redrawn into RGBA8 first, so the surfaced raster's own pixel format
    /// does not matter.
    private static func ink(
        _ image: CGImage, at point: PDFPointValue, page: ZPDFUIPresentation.PageDescriptor
    ) throws -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let unit = PageDisplayTransform(pageBox: page.visibleBox, rotation: page.rotation.rawValue, zoom: 1, origin: .zero)
        let scale = CGFloat(width) / unit.displaySize.width
        let view = PageDisplayTransform(
            pageBox: page.visibleBox, rotation: page.rotation.rawValue, zoom: scale, origin: .zero
        ).viewPoint(from: point)
        var total = 0.0, samples = 0.0
        for dy in -3...3 {
            for dx in -3...3 {
                // Rows in the buffer run top-down, as the flipped view does.
                let x = Int(view.x) + dx, y = Int(view.y) + dy
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let offset = (y * width + x) * 4
                total += 1 - (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / (3 * 255)
                samples += 1
            }
        }
        return samples > 0 ? total / samples : 0
    }

    /// Old output: `setLayerFiltering` put the cached native base straight back — the same image,
    /// walls edge inked (≈ 0.3 darkness) and the Grid line blank — so Walls showed in colour
    /// under the filtered tiles wherever they had not landed, through every pinch and pan.
    @Test("U-002: under a layer filter the base raster hides the hidden layer and shows the shown one")
    func baseRasterHonoursTheLayerFilter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-iter4-layers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ZPDFFixtures.make(.threeLayers, in: directory)
        let harness = try await Fix2Harness.make("unused", calibrate: false, fixture: fixture.url)
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let pageView = canvas.pageViewForTesting
        canvas.refresh()
        await Self.settleRaster(harness)
        let page = try #require(harness.core.document.currentPage)
        let native = try #require(pageView.baseRaster, "the native base raster never landed")
        // Control: the native base draws the file's default layers — Walls on, Grid off.
        #expect(try Self.ink(native.image, at: Self.wallsEdge, page: page) > 0.05)
        #expect(try Self.ink(native.image, at: Self.gridPoint, page: page) < 0.01)

        var options = VectorExtractionOptions.standard
        options.includesHiddenOptionalContent = true
        let extraction = try await VectorExtractor(options: options).extract(documentAt: fixture.url, pageIndex: 0)
        // Hide Walls, show Grid: the state no native renderer can draw.
        canvas.setLayerFiltering(.init(extraction: extraction, hiddenLayerIDs: [Self.wallsName], pageIndex: 0))
        #expect(pageView.baseRaster?.image !== native.image, "the toggle put the native base back under the filter")
        await Self.settleRaster(harness)
        let filtered = try #require(pageView.baseRaster, "no base raster under the filter")
        #expect(filtered.image !== native.image)
        #expect(filtered.coverage == .wholePage)
        #expect(max(filtered.image.width, filtered.image.height) == PDFCanvasViewController.baseRasterPixelSize)
        let wallsInk = try Self.ink(filtered.image, at: Self.wallsEdge, page: page)
        let gridInk = try Self.ink(filtered.image, at: Self.gridPoint, page: page)
        #expect(wallsInk < 0.01, "the hidden Walls layer shows in the base raster (\(wallsInk))")
        #expect(gridInk > 0.05, "the shown Grid layer is missing from the base raster (\(gridInk))")

        // Back to the document default: the native base again, Walls inked.
        canvas.setLayerFiltering(nil)
        await Self.settleRaster(harness)
        let restored = try #require(pageView.baseRaster)
        #expect(try Self.ink(restored.image, at: Self.wallsEdge, page: page) > 0.05)
        #expect(try Self.ink(restored.image, at: Self.gridPoint, page: page) < 0.01)
    }

    // MARK: - U-003 a locked markup's knob is a knob

    /// Old output: `markupRotationHandle` skipped the locked box (nil), the press became a
    /// marquee over empty paper, and its release selected nothing — the box lost its selection,
    /// with no word on the status bar.
    @Test("U-003: dragging a locked text box's knob keeps it selected, leaves it unturned and says it is locked")
    func lockedKnobIsGrabbedAndRefused() async throws {
        let harness = try await Fix2Harness.make("Iter4 Locked Knob.pdf")
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        let text = MarkupRecord(
            id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id, kind: .text,
            caption: "Locked", locked: true,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 400), PDFPoint(x: 300, y: 440)]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        _ = try await harness.core.commands.perform(.addMarkup(text))
        harness.shell.perform(.selectTool)
        await harness.settle()
        harness.core.canvas.select(markupIDs: [text.id.rawValue], additive: false)
        harness.canvas.refresh()
        await harness.canvas.settleScene()
        let canvas = harness.canvas
        let record = try #require(canvas.sceneRecords.first { $0.id == text.id })
        #expect(record.locked)
        let gap = harness.core.canvas.viewport.pageDistance(forViewPoints: Double(CanvasPageView.stampRotationHandleGapViewPoints))
        let knob = try #require(PDFCanvasViewController.rotationKnob(of: record, gap: gap))
        // The knob drawn: 22 view points above the box's top edge, on its centre line.
        #expect(abs(knob.x - 200) < 1e-9 && abs(knob.y - (440 + gap)) < 1e-9)
        #expect(canvas.markupRotationHandle(at: knob) == text.id.rawValue, "the drawn knob of a locked box is not grabbable")

        // Up and to the left, clear of the box, so a marquee would catch nothing.
        let target = PDFPointValue(x: 140, y: 480 + gap)
        canvas.handleDragBegan(at: knob)
        canvas.handleDragMoved(to: target)
        canvas.handleDragEnded(at: target)
        #expect(harness.core.canvas.selectedMarkupIDs == [text.id.rawValue], "the press deselected the locked box")
        #expect(await AppTestSupport.wait { harness.core.status.snapshot.activeToolNote?.contains("locked") == true },
                "no refusal note: \(harness.core.status.snapshot.activeToolNote ?? "nil")")
        await harness.core.commands.settle()
        #expect(await harness.core.session.markup(text.id)?.style.rotationDegrees == nil, "a locked box turned")
    }

    // MARK: - U-006 one rotation box for the drawn knob and the grabbed one

    private static func record(
        _ kind: ZPDFContracts.MarkupKind, points: [PDFPoint], ring: [PDFPoint]? = nil,
        style: MarkupStyle = MarkupStyle(), symbol: MarkupSymbol? = nil, tool: MeasurementTool? = nil
    ) -> MarkupRecord {
        let page = PageID(UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!)
        return MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: kind, tool: tool,
            style: style, caption: kind == .text || kind == .callout ? "Words" : nil,
            geometry: MeasurementGeometry(
                pageID: page, points: points,
                polygons: ring.map { [PolygonGeometry(outer: PolygonRing(points: $0, isClosed: true))] } ?? []
            ),
            symbol: symbol,
            createdAt: stamp, modifiedAt: stamp
        )
    }

    /// Where the page view draws a rotation knob for a scene shape, `gap` page points out: the
    /// box's top centre, turned with the shape (`CanvasPageView.drawStampRotationHandle`).
    private static func drawnKnob(of shape: CanvasMarkupShape, gap: Double) -> PDFPointValue? {
        guard let box = shape.rotationBox else { return nil }
        return CanvasStampPlacement(
            anchor: PDFPointValue(x: box.minX + box.size.width / 2, y: box.minY + box.size.height / 2),
            widthPoints: box.size.width, heightPoints: box.size.height, rotationDegrees: shape.rotationDegrees
        ).rotationHandlePoint(gapPoints: gap)
    }

    /// Old output: the controller rebuilt the box itself and gated an image on its symbol, so an
    /// image without one had a drawn box (100,100)–(220,160) and no grabbable knob (nil).
    @Test("U-006: every turnable kind is grabbed by exactly the knob the scene draws")
    func grabbedKnobIsTheDrawnKnob() throws {
        var turned = MarkupStyle()
        turned.rotationDegrees = 30
        let square = [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)]
        let records = [
            Self.record(.text, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 140)], style: turned),
            Self.record(.callout, points: [PDFPoint(x: 40, y: 40), PDFPoint(x: 100, y: 100), PDFPoint(x: 220, y: 150)], style: turned),
            Self.record(.rectangle, points: [], ring: square, style: turned),
            Self.record(.ellipse, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 180, y: 140)]),
            Self.record(.line, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 260, y: 180)], style: turned),
            Self.record(.image, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 220, y: 160)], style: turned),
            Self.record(.cloud, points: [PDFPoint(x: 40, y: 40), PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 160)], ring: square)
        ]
        let gap = 11.0
        for record in records {
            let shape = try #require(
                CanvasSceneBuilder.build(records: [record], summaries: [], pageID: record.pageID.rawValue).first,
                "\(record.kind) drew nothing"
            )
            let drawn = try #require(Self.drawnKnob(of: shape, gap: gap), "\(record.kind) draws no knob")
            let grabbed = try #require(PDFCanvasViewController.rotationKnob(of: record, gap: gap), "\(record.kind) has no grabbable knob")
            #expect(drawn.distance(to: grabbed) < 1e-9, "\(record.kind): drawn \(drawn), grabbed \(grabbed)")
        }
        // The callout turns about its note box, not its leader.
        let callout = try #require(CanvasSceneBuilder.rotationBox(of: records[1]))
        #expect(callout == PDFRectValue(x: 100, y: 100, width: 120, height: 50))
        // A measurement never turns, so it has neither.
        let length = Self.record(.measurement, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)], tool: .length)
        #expect(CanvasSceneBuilder.rotationBox(of: length) == nil)
        #expect(PDFCanvasViewController.rotationKnob(of: length, gap: gap) == nil)
    }

    @Test("U-006: the bulk edit's rotation rule is the record's own, kind for kind")
    func holdsRotationIsTheRecordsRule() {
        for kind in ZPDFContracts.MarkupKind.allCases {
            for tool in [nil, MeasurementTool.length] {
                let record = Self.record(kind, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10)], tool: tool)
                #expect(MarkupStyleFit.holdsRotation(record) == record.turnsWithStyleRotation, "\(kind), tool \(String(describing: tool))")
                #expect((CanvasSceneBuilder.rotationBox(of: record) != nil) == record.turnsWithStyleRotation, "\(kind)")
            }
        }
    }

    /// Old output: the image knob was drawn from its stamp placement whatever the selection, so
    /// with a second markup selected the stem at (160, 171) was selection ink although
    /// `markupRotationHandle` takes no knob in a multiple selection.
    @Test("U-006: an image's knob is drawn only when a press can take it — alone in the selection")
    func imageKnobFollowsTheGrabRule() throws {
        let image = Self.record(.image, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 220, y: 160)])
        let other = Self.record(.rectangle, points: [], ring: [
            PDFPoint(x: 400, y: 20), PDFPoint(x: 440, y: 20), PDFPoint(x: 440, y: 60), PDFPoint(x: 400, y: 60)
        ])
        let shapes = CanvasSceneBuilder.build(records: [image, other], summaries: [], pageID: image.pageID.rawValue)
        #expect(shapes.count == 2)
        #expect(shapes.first { $0.id == image.id.rawValue }?.stamp != nil, "an image draws through a stamp placement")
        let view = CanvasPageView()
        view.transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 480, height: 240), rotation: 0, zoom: 1, origin: .zero
        )
        view.shapes = shapes
        let size = CGSize(width: 480, height: 240)
        view.frame = CGRect(origin: .zero, size: size)
        // Half-way up the stem: the box's top edge is y = 160, the knob 22 view points above it.
        let stem = PDFPointValue(x: 160, y: 160 + Double(CanvasPageView.stampRotationHandleGapViewPoints) / 2)
        /// The pixel nearest the selection ink in a small window across the stem, and how far
        /// from the ink it is (summed RGB difference, transparent counts as far).
        func nearestInk() throws -> (colour: NSColor, distance: CGFloat) {
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / size.width
            let p = view.transform!.viewPoint(from: stem)
            let ink = CanvasMarkupStyle.selectionInk.usingColorSpace(.sRGB)!
            var best: (colour: NSColor, distance: CGFloat) = (.clear, .greatestFiniteMagnitude)
            for dx in -2...2 {
                for dy in -1...1 {
                    guard let colour = rep.colorAt(x: Int(p.x * scale) + dx, y: Int(p.y * scale) + dy)?
                        .usingColorSpace(.sRGB) else { continue }
                    let distance = colour.alphaComponent < 0.5 ? 3 : abs(colour.redComponent - ink.redComponent)
                        + abs(colour.greenComponent - ink.greenComponent) + abs(colour.blueComponent - ink.blueComponent)
                    if distance < best.distance { best = (colour, distance) }
                }
            }
            return best
        }
        view.selection = [image.id.rawValue]
        let alone = try nearestInk()
        #expect(alone.distance < 0.3, "the image's knob stem is not drawn when it is selected alone: \(alone.colour)")
        view.selection = [image.id.rawValue, other.id.rawValue]
        let together = try nearestInk()
        #expect(together.distance > 0.6, "a knob no press can take is drawn in a multiple selection: \(together.colour)")
    }
}
