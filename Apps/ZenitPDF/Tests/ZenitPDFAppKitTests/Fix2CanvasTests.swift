import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Bug hunt 2, canvas: regressions for the select drag, rotation, raster reuse, page
/// turns and the Split Canvas pane. Each test names the old output it would have seen.
@MainActor
@Suite(.appTierSerialised)
struct Fix2CanvasTests {

    // MARK: - BH-061 select drag released off the page

    @Test("BH-061: a move released off the sheet still commits, and the drag disarms")
    func selectDragReleasedOffThePageCommits() async throws {
        let harness = try await Fix2Harness.make("BH061.pdf")
        defer { harness.tearDown() }
        let line = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 200, y: 400), PDFPoint(x: 300, y: 400)])
        }
        harness.shell.perform(.selectTool)
        await harness.settle()
        let pageView = harness.canvas.pageViewForTesting
        let transform = try #require(pageView.transform, "the canvas never laid the page out")
        #expect(harness.canvas.hitTest(PDFPointValue(x: 250, y: 400)) == line.id.rawValue)

        let press = transform.viewPoint(from: PDFPointValue(x: 250, y: 400))
        let inside = transform.viewPoint(from: PDFPointValue(x: 260, y: 420))
        // Far outside the sheet, below and to the right of it.
        let outside = CGPoint(x: transform.pageFrame.maxX + 300, y: transform.pageFrame.maxY + 300)

        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: press))
        pageView.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: inside))
        #expect(harness.canvas.isSelectDragArmed, "the press on the line never became a move")
        pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: outside))

        // Old: `onDragEnded` never fired off the page — the drag stayed armed (ghost drawn at
        // the moved position) and no `.moveMarkup` was issued.
        #expect(!harness.canvas.isSelectDragArmed, "the controller's drag stayed armed after the release")
        #expect(await AppTestSupport.wait { harness.core.commands.lastCommandKind == .moveMarkup },
                "releasing off the sheet dropped the move without a command")
        let moved = try #require(await harness.records().first)
        #expect(moved.geometry?.points.first?.x != 200, "the markup never moved")
    }

    @Test("BH-061: losing first responder mid-drag disarms the controller's drag")
    func resigningFirstResponderCancelsTheDrag() async throws {
        let harness = try await Fix2Harness.make("BH061b.pdf")
        defer { harness.tearDown() }
        try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 200, y: 400), PDFPoint(x: 300, y: 400)])
        }
        harness.shell.perform(.selectTool)
        await harness.settle()
        let pageView = harness.canvas.pageViewForTesting
        let transform = try #require(pageView.transform)
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: transform.viewPoint(from: PDFPointValue(x: 250, y: 400))))
        pageView.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: transform.viewPoint(from: PDFPointValue(x: 270, y: 430))))
        #expect(harness.canvas.isSelectDragArmed)
        _ = pageView.resignFirstResponder()
        // Old: the view cleared its own flag and the controller kept drawing the ghost.
        #expect(!harness.canvas.isSelectDragArmed)
    }

    @Test("BH-061: the clamp puts an off-page pointer on the sheet edge")
    func clampPutsThePointerOnTheEdge() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(CanvasPageView.clamp(CGPoint(x: 500, y: -40), into: frame) == CGPoint(x: 110, y: 20))
        #expect(CanvasPageView.clamp(CGPoint(x: 50, y: 30), into: frame) == CGPoint(x: 50, y: 30))
    }

    // MARK: - BH-062 coverage map is per page and ignores hidden records

    @Test("BH-062: coverage unions only this page's visible measurements")
    func coverageIsPerPage() async throws {
        let harness = try await Fix2Harness.make("BH062.pdf", pageCount: 2)
        defer { harness.tearDown() }
        let square = { (page: PageID) in
            MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100),
                PDFPoint(x: 300, y: 300), PDFPoint(x: 100, y: 300)
            ]))])
        }
        let onFirst = try await harness.addMarkup(tool: .area, geometry: square, pageIndex: 0)
        var hidden = try await harness.addMarkup(tool: .area, geometry: square, pageIndex: 1)
        hidden.hidden = true
        let records = await harness.records().map { $0.id == hidden.id ? hidden : $0 }
        let drawing = try #require(harness.document.drawing)
        let second = drawing.pages[1].id.rawValue
        let first = drawing.pages[0].id.rawValue
        // Old: both records, on page 2 as on page 1 — page 1's polygon tinted page 2.
        #expect(PDFCanvasViewController.coverageRecords(records, onPage: second).isEmpty)
        #expect(PDFCanvasViewController.coverageRecords(records, onPage: first).map(\.id) == [onFirst.id])
    }

    // MARK: - BH-063 / BH-067 rotation-aware restore and zoom

    @Test("BH-063: restore lands the rect's on-screen top-left on a /Rotate 90 sheet")
    func restoreHonoursRotation() {
        let transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 100, height: 50),
            rotation: 90, zoom: 1, origin: .zero
        )
        let visible = PDFRectValue(x: 10, y: 10, width: 20, height: 10)
        let rect = PDFCanvasViewController.restoredViewRect(for: visible, transform: transform)
        // Old: viewPoint(minX, maxY) = (20, 10) — the rect's top-RIGHT on screen.
        #expect(rect.origin == CGPoint(x: 10, y: 10))
        // At 90° page x runs down the screen: a 20 × 10 page rect is 10 wide, 20 tall.
        #expect(rect.size == CGSize(width: 10, height: 20))
    }

    @Test("BH-067: ⌘* fits on the page's own axes on a /Rotate 90 sheet")
    func fitHonoursRotation() throws {
        let target = PDFRectValue(x: 0, y: 0, width: 100, height: 10)
        let fit = try #require(ZoomMath.fit(target: target, in: CGSize(width: 1600, height: 1000), rotation: 90))
        // Old: min(1600/124, 1000/12.4) = 12.9, so the 100 pt side was 1290 pt tall on screen.
        #expect(abs(fit.zoom - 1000.0 / 124.0) < 1e-9)
        #expect(ZoomMath.fits(target: target, in: CGSize(width: 1600, height: 1000), zoom: fit.zoom, rotation: 90))
        let centred = try #require(ZoomMath.centred(target: target, in: CGSize(width: 1600, height: 1000), zoom: 2, rotation: 90))
        #expect(centred.size.width == 500 && centred.size.height == 800, "the visible rect was axis-swapped")
    }

    // MARK: - BH-064 / IM-174 the pane honours /Rotate through the shared transform

    @Test("BH-064: a pane region maps through /Rotate onto the right corner of the page")
    func paneGeometryHonoursRotation() {
        let geometry = SplitPaneGeometry(pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400), rotation: 90)
        #expect(geometry.displayBox == PDFRectValue(x: 0, y: 0, width: 400, height: 600))
        // The display's bottom-left corner is the page's (600, 0) corner at 90°.
        let region = geometry.pageRegion(forDisplay: PDFRectValue(x: 0, y: 0, width: 10, height: 10))
        // Old: the pane used page space directly and asked for (0, 0, 10, 10).
        #expect(region == PDFRectValue(x: 590, y: 0, width: 10, height: 10))
        let back = geometry.displayRegion(forPage: region)
        #expect(back == PDFRectValue(x: 0, y: 0, width: 10, height: 10))
        #expect(geometry.pageRegion(forDisplay: geometry.displayBox) == PDFRectValue(x: 0, y: 0, width: 600, height: 400))
    }

    private static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    final class RenderLog { var calls = 0; var hang = false }

    private func paneSource(identity: String, rotation: Int = 0, log: RenderLog, fails: Bool = false) -> SplitPaneRenderSource {
        SplitPaneRenderSource(
            pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400),
            rotation: rotation,
            identity: identity,
            render: { region, _ in
                log.calls += 1
                if fails { return nil }
                if log.hang { try? await Task.sleep(nanoseconds: 30_000_000_000); return nil }
                return Self.image(width: max(1, Int(region.size.width)), height: max(1, Int(region.size.height)))
            }
        )
    }

    @Test("IM-173 / BH-346: the stale pane image moves with a pan before any render lands")
    func paneImageMovesImmediately() async throws {
        let harness = try await Fix2Harness.make("IM173.pdf")
        defer { harness.tearDown() }
        let log = RenderLog()
        let pane = SplitPaneCanvasView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        pane.renderSource = paneSource(identity: "a", log: log)
        pane.apply(zoom: 1, scrollOffset: PDFPointValue(x: 0, y: 0))
        pane.scheduleRender()
        await pane.settleRenderForTesting()
        let before = pane.imageFrameForTesting
        #expect(pane.hasLivePageContent)
        log.hang = true
        pane.apply(zoom: 1, scrollOffset: PDFPointValue(x: 40, y: 10))
        let after = pane.imageFrameForTesting
        // Old: imageLayer.frame only moved when a render landed; during a pan it stood still.
        #expect(abs((after.minX - before.minX) - (-40)) < 1e-6)
        #expect(abs((after.minY - before.minY) - (-10)) < 1e-6)
    }

    @Test("BH-347: a pane zoom keeps the anchor fixed and never strands the view off the sheet")
    func paneZoomIsAnchoredAndClamped() async throws {
        let harness = try await Fix2Harness.make("BH347.pdf")
        defer { harness.tearDown() }
        let pane = SplitPaneCanvasView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        pane.renderSource = paneSource(identity: "a", log: RenderLog())
        var reportedZoom: Double?
        var reportedOffset: PDFPointValue?
        pane.onZoom = { reportedZoom = $0 }
        pane.onPan = { reportedOffset = $0 }
        // The sheet at the pane's right edge: most of the view is blank space left of it.
        let edge = PDFPointValue(x: -276, y: 0)
        pane.apply(zoom: 1, scrollOffset: edge)
        pane.reportZoom(factor: 10, anchor: CGPoint(x: 10, y: 10))
        let zoom = try #require(reportedZoom)
        let offset = try #require(reportedOffset, "the zoom reported no offset: it anchored at the corner")
        pane.apply(zoom: zoom, scrollOffset: offset)
        // Old: offset unchanged → the 30-pt-wide visible region lay wholly left of the sheet.
        #expect(pane.visibleDisplayRegion() != nil, "the zoom stranded the pane over blank space")
        let anchored = SplitPaneCanvasView.anchoredOffset(
            offset: PDFPointValue(x: 0, y: 0), oldZoom: 1, newZoom: 2, anchorInView: CGPoint(x: 100, y: 50)
        )
        #expect(anchored == PDFPointValue(x: 50, y: 25), "the display point under the pointer moved")
    }

    @Test("BH-348: a swapped-in source whose render fails leaves no pixels of the old drawing")
    func paneClearsOnFailedSwap() async throws {
        let harness = try await Fix2Harness.make("BH348.pdf")
        defer { harness.tearDown() }
        let pane = SplitPaneCanvasView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        pane.renderSource = paneSource(identity: "a", log: RenderLog())
        pane.scheduleRender()
        await pane.settleRenderForTesting()
        #expect(pane.hasLivePageContent)
        pane.renderSource = paneSource(identity: "b", log: RenderLog(), fails: true)
        await pane.settleRenderForTesting()
        // Old: drawing A's image stayed, `hasLivePageContent` true, under drawing B's title.
        #expect(!pane.hasLivePageContent)
    }

    @Test("BH-349: re-assigning the same source does not re-render the pane")
    func paneSkipsIdenticalSource() async throws {
        let harness = try await Fix2Harness.make("BH349.pdf")
        defer { harness.tearDown() }
        let log = RenderLog()
        let pane = SplitPaneCanvasView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        pane.renderSource = paneSource(identity: "doc|page", log: log)
        await pane.settleRenderForTesting()
        let rendered = pane.renderStartCount
        for _ in 0..<5 {
            pane.renderSource = paneSource(identity: "doc|page", log: log)
        }
        await pane.settleRenderForTesting()
        // Old: every SwiftUI update rebuilt the source and restarted a full-region render.
        #expect(pane.renderStartCount == rendered, "\(pane.renderStartCount - rendered) redundant renders")
    }

    @Test("BH-887 / IM-245: a wheel notch pans by lines, and ⌘-zoom shares the canvas curve")
    func paneWheelAndZoomCurve() {
        #expect(SplitPaneCanvasView.panDelta(scrollingDeltaX: 0, scrollingDeltaY: 1, precise: false).height == 16)
        #expect(SplitPaneCanvasView.panDelta(scrollingDeltaX: 0, scrollingDeltaY: 1, precise: true).height == 1)
        let natural = ZenitCanvasScrollView.zoomFactor(scrollingDeltaY: -3, precise: false, invertedFromDevice: true)
        let classic = ZenitCanvasScrollView.zoomFactor(scrollingDeltaY: 3, precise: false, invertedFromDevice: false)
        #expect(natural == classic, "the same physical gesture zoomed differently under natural scrolling")
        #expect(ZenitCanvasScrollView.zoomFactor(scrollingDeltaY: 0, precise: true, invertedFromDevice: false) == nil)
    }

    // MARK: - BH-065 / BH-351 raster planning

    @Test("BH-065: an identical plan satisfies itself with a sheet edge on screen")
    func identicalPlanIsReused() throws {
        // An A1 sheet at a fit zoom, its fractional page frame fully on screen.
        let transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 2384, height: 1684),
            rotation: 0, zoom: 0.3, origin: CGPoint(x: 37.3, y: 20.7)
        )
        let visible = CGRect(x: 0, y: 0, width: 800, height: 560)
        let plan = try ViewportRasterPlanner.plan(transform: transform, visibleViewRect: visible, backingScale: 2)
        let again = try ViewportRasterPlanner.plan(transform: transform, visibleViewRect: visible, backingScale: 2)
        // Old: false — the visible region reached past the inward-snapped page edge, so the
        // canvas re-rasterised on every pointer move at fit zoom.
        #expect(ViewportRasterPlanner.satisfies(plan, again))
    }

    @Test("BH-351: a pixel-budget refusal drops the overscan before refusing")
    func budgetRefusalRetriesBare() throws {
        let transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 10_000, height: 10_000),
            rotation: 0, zoom: 1, origin: .zero
        )
        let visible = CGRect(x: 1000, y: 1000, width: 1000, height: 1000)
        // Bare viewport: 2000 × 2000 = 4 MP at 2x; with 64 pt overscan: 2256² ≈ 5.09 MP.
        let plan = try ViewportRasterPlanner.plan(
            transform: transform, visibleViewRect: visible, backingScale: 2, pixelBudget: 4_500_000
        )
        // Old: threw pixelBudgetExceeded and the canvas never rasterised the page.
        #expect(plan.pixelCount <= 4_500_000)
    }

    // MARK: - BH-066 / BH-352 / BH-891 / IM-246 / BH-342 page turns

    @Test("BH-066: the page-turn delta is the content delta, whatever natural scrolling says")
    func pageTurnDeltaIgnoresInversion() {
        // `scrollingDeltaY` already carries the natural-scrolling preference; the old code
        // negated it again when inverted, so under the macOS default a sheet never turned.
        #expect(ZenitCanvasScrollView.pageTurnDelta(scrollingDeltaY: -12, precise: true, lineScroll: 10) == -12)
        #expect(ZenitCanvasScrollView.pageTurnDelta(scrollingDeltaY: -3, precise: false, lineScroll: 10) == -30)
    }

    @Test("BH-352: a mouse wheel sums notches into one page turn")
    func wheelNotchesTurnThePage() async throws {
        let harness = try await Fix2Harness.make("BH352.pdf", pageCount: 2)
        defer { harness.tearDown() }
        let scrollView = harness.canvas.scrollViewForTesting
        var turns: [Bool] = []
        scrollView.onTurnPage = { forward in turns.append(forward); return true }
        let notch = ZenitCanvasScrollView.pageTurnDelta(scrollingDeltaY: -3, precise: false, lineScroll: 10)
        for step in 0..<12 {
            scrollView.noteLegacyWheelEvent(at: 100 + Double(step) * 0.05, atTop: false, atBottom: true)
            scrollView.considerTurningPage(deltaY: notch, wasAtTop: false, wasAtBottom: true)
        }
        // Old: every notch began a new gesture and zeroed the accumulator — never a turn.
        #expect(turns == [true])
    }

    @Test("BH-891: a gesture that begins as a scroll stays a scroll when ⌘ is pressed mid-way")
    func zoomDecisionIsSticky() {
        let began = ZenitCanvasScrollView.zoomDecision(
            phaseBegan: true, isGestureEvent: true, isMomentum: false, commandHeld: false, sequenceWasZoom: false
        )
        let changed = ZenitCanvasScrollView.zoomDecision(
            phaseBegan: false, isGestureEvent: true, isMomentum: false, commandHeld: true,
            sequenceWasZoom: began.sequenceWasZoom
        )
        // Old: `.changed` with ⌘ held zoomed, handing NSScrollView a `.began` with no `.ended`.
        #expect(!changed.zooming)
        let wheel = ZenitCanvasScrollView.zoomDecision(
            phaseBegan: false, isGestureEvent: false, isMomentum: false, commandHeld: true, sequenceWasZoom: false
        )
        #expect(wheel.zooming, "a phase-less ⌘ wheel still zooms per event")
    }

    @Test("IM-246: overscroll progress is exposed and labelled, and cleared when the gesture ends")
    func pageTurnProgressIsShown() async throws {
        let harness = try await Fix2Harness.make("IM246.pdf", pageCount: 2)
        defer { harness.tearDown() }
        let scrollView = harness.canvas.scrollViewForTesting
        scrollView.onTurnPage = { _ in true }
        scrollView.beginScrollGesture(atTop: false, atBottom: true)
        scrollView.considerTurningPage(deltaY: -80, wasAtTop: false, wasAtBottom: true)
        let progress = try #require(scrollView.pageTurnProgress)
        #expect(abs(progress.fraction - 0.5) < 1e-9 && progress.forward)
        #expect(!scrollView.pageTurnHintLabel.isHidden)
        #expect(scrollView.pageTurnHintLabel.stringValue.contains("50"))
        scrollView.endScrollGesture()
        #expect(scrollView.pageTurnProgress == nil)
        #expect(scrollView.pageTurnHintLabel.isHidden)
        #expect(ZenitCanvasScrollView.pageTurnHintText(fraction: 0.1, forward: true) == nil)
    }

    @Test("BH-342: a page turn rests on the sheet's edge, not the backdrop's")
    func pageTurnRestsOnTheSheet() {
        let page = CGRect(x: 900, y: 900, width: 2000, height: 3000)
        let document = CGRect(x: 0, y: 0, width: 3800, height: 4800)
        let top = PDFCanvasViewController.restingScrollY(pageFrame: page, visibleHeight: 1000, documentRect: document, atTop: true)
        // Old: 0 — the top of the 90 % pan margin, a viewport of black.
        #expect(top == 900 - PDFCanvasViewController.pageTurnRestingGap)
        let bottom = PDFCanvasViewController.restingScrollY(pageFrame: page, visibleHeight: 1000, documentRect: document, atTop: false)
        #expect(bottom == 3900 + PDFCanvasViewController.pageTurnRestingGap - 1000)
        let short = CGRect(x: 900, y: 900, width: 500, height: 400)
        #expect(PDFCanvasViewController.restingScrollY(pageFrame: short, visibleHeight: 1000, documentRect: document, atTop: true) == nil,
                "a sheet that fits keeps its centring")
    }

    // MARK: - IM-046 one mapping, two implementations, proven to agree

    @Test("IM-046: the canvas transform agrees with the snap engine's converter at every rotation, crop and zoom")
    func canvasTransformAgreesWithTheGeometryContract() throws {
        var generator = SystemRandomNumberGenerator()
        for rotation in [0, 90, 180, 270] {
            for crop in [
                PDFRect(x: 0, y: 0, width: 595, height: 842),
                PDFRect(x: -120, y: 37.5, width: 2384, height: 1684),
                PDFRect(x: 18, y: -9, width: 300, height: 900)
            ] {
                for zoom in [0.05, 0.3, 1, 3.7, 64] {
                    let page = ZPDFContracts.PageDescriptor(
                        id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
                        boxes: PageBoxes(
                            media: PDFRect(x: crop.origin.x - 50, y: crop.origin.y - 50,
                                           width: crop.size.width + 100, height: crop.size.height + 100),
                            crop: crop
                        ),
                        rotation: try PageRotation.normalizing(degrees: rotation)
                    )
                    let anchor = CGPoint(x: 24, y: 31)
                    let converter = try PageCoordinateConverter(
                        page: page,
                        layout: PageViewLayout(anchor: anchor, zoom: zoom, backingScale: 2, isViewFlipped: true)
                    )
                    let transform = PageDisplayTransform(
                        pageBox: PDFRectValue(x: crop.origin.x, y: crop.origin.y, width: crop.size.width, height: crop.size.height),
                        rotation: rotation, zoom: CGFloat(zoom), origin: anchor
                    )
                    for _ in 0..<20 {
                        let point = PDFPoint(
                            x: crop.origin.x + Double.random(in: 0...crop.size.width, using: &generator),
                            y: crop.origin.y + Double.random(in: 0...crop.size.height, using: &generator)
                        )
                        let expected = try converter.pageToView(point)
                        let actual = transform.viewPoint(from: PDFPointValue(x: point.x, y: point.y))
                        let tolerance = 1e-9 * max(1, zoom * 3000)
                        #expect(abs(actual.x - expected.x) <= tolerance && abs(actual.y - expected.y) <= tolerance,
                                "rotation \(rotation), zoom \(zoom): \(actual) vs \(expected)")
                        let back = transform.pagePoint(from: actual)
                        #expect(abs(back.x - point.x) < 1e-6 && abs(back.y - point.y) < 1e-6)
                    }
                }
            }
        }
    }

    // MARK: - IM-043 hover pre-highlight

    @Test("IM-043: the Select tool shows what a click would pick; a measurement tool never does")
    func selectHoverHighlightsTheTopMarkup() async throws {
        let harness = try await Fix2Harness.make("IM043.pdf")
        defer { harness.tearDown() }
        let under = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 300), PDFPoint(x: 300, y: 300)])
        }
        let over = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 200, y: 400)])
        }
        harness.shell.perform(.selectTool)
        await harness.settle()
        // Old: nothing — the hover fed only the snap engine.
        harness.canvas.handlePointerMove(PDFPointValue(x: 200, y: 300))
        #expect(harness.canvas.pageViewForTesting.hoverTarget == .markup(over.id.rawValue))
        harness.canvas.handlePointerMove(PDFPointValue(x: 120, y: 300))
        #expect(harness.canvas.pageViewForTesting.hoverTarget == .markup(under.id.rawValue))
        #expect(harness.canvas.pageViewForTesting.hoverCursor() == NSCursor.openHand)
        // A selected markup's vertex asks for the crosshair.
        harness.core.canvas.select(markupIDs: [under.id.rawValue], additive: false)
        await harness.settle()
        harness.canvas.handlePointerMove(PDFPointValue(x: 100, y: 300))
        #expect(harness.canvas.pageViewForTesting.hoverTarget == .vertex(under.id.rawValue))
        harness.shell.perform(.measureLength)
        await harness.settle()
        harness.canvas.handlePointerMove(PDFPointValue(x: 200, y: 300))
        #expect(harness.canvas.pageViewForTesting.hoverTarget == nil, "a measurement tool must not pre-highlight")
    }
}
