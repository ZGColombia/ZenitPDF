import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Continuous scrolling (ADR-0045): every page in one strip, the current page following the
/// view without anything moving, work in progress holding its page, and the neighbouring
/// sheets drawn by the same classes as the current one. Every window here is never ordered on
/// screen; each test pins the mode itself, so the app-wide preference does not matter.
@MainActor
@Suite(.appTierSerialised)
struct CanvasContinuousScrollTests {

    // MARK: - Helpers

    private func make(_ name: String, pages: Int, calibrate: Bool = false) async throws -> Fix2Harness {
        let harness = try await Fix2Harness.make(name, pageCount: pages, calibrate: calibrate, pageLayout: .continuous)
        harness.canvas.refresh()
        await settle(harness)
        return harness
    }

    private func settle(_ harness: Fix2Harness) async {
        for _ in 0..<5 {
            await harness.canvas.settleRasterForTesting()
            await harness.canvas.settleScene()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func layout(_ harness: Fix2Harness) throws -> PageStripLayout {
        try #require(harness.canvas.stripLayoutForTesting)
    }

    private func pageIDs(_ harness: Fix2Harness) -> [UUID] {
        harness.core.document.pages.map(\.id)
    }

    private func visible(_ harness: Fix2Harness) -> CGRect {
        harness.canvas.scrollViewForTesting.documentVisibleRect
    }

    /// Scrolls the document view to `origin`, and reports the view as a scroll would.
    private func scroll(_ harness: Fix2Harness, to origin: CGPoint, report: Bool = true) {
        let scrollView = harness.canvas.scrollViewForTesting
        harness.canvas.pageViewForTesting.scroll(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if report { harness.canvas.reportVisibleRect() }
    }

    /// Scrolls so page `index`'s top sits a little below the viewport's top: most of the view.
    private func scroll(_ harness: Fix2Harness, toPage index: Int, report: Bool = true) throws {
        let slot = try layout(harness).slotFrame(of: index)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: slot.minY - 10), report: report)
    }

    /// Waits out the hand-off rate limit, so the next scroll may hand off again.
    private func waitOutRateLimit() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func host(_ harness: Fix2Harness, page: UUID) -> CanvasPassivePage? {
        harness.canvas.passivePagesForTesting.first { $0.pageID == page }
    }

    // MARK: - Mode

    @Test("A document of several pages opens as one strip; a one-page document stays exactly as before")
    func multiPageOpensContinuous_onePageStaysSingle() async throws {
        let many = try await make("CS many.pdf", pages: 3)
        defer { many.tearDown() }
        #expect(many.canvas.isContinuousScrollActive)
        #expect(many.canvas.scrollViewForTesting.onTurnPage == nil, "no overscroll page turn in a strip")
        let strip = try layout(many)
        #expect(many.canvas.documentViewForTesting.frame.size == strip.documentSize)
        #expect(many.canvas.passivePagesForTesting.contains { $0.pageID == pageIDs(many)[1] }, "the next sheet is on screen beside the first")

        let one = try await make("CS one.pdf", pages: 1)
        defer { one.tearDown() }
        #expect(!one.canvas.isContinuousScrollActive)
        #expect(one.canvas.stripLayoutForTesting == nil)
        #expect(one.canvas.scrollViewForTesting.onTurnPage != nil)
        #expect(one.canvas.passivePagesForTesting.isEmpty)
        let frame = try #require(one.canvas.pageViewForTesting.transform?.pageFrame)
        let document = one.canvas.documentViewForTesting.frame
        // Single-page layout: the sheet plus the same pan margin on each side.
        #expect(abs((document.height - frame.height) / 2 - frame.minY) < 1e-6)
    }

    // MARK: - Hand-off

    @Test("A hand-off by scrolling moves nothing on screen: the scroll origin and every sheet stay put")
    func handOffMovesNothingOnScreen() async throws {
        let harness = try await make("CS handoff.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        var locked = true
        harness.canvas.externalPageLock = { locked }
        try scroll(harness, toPage: 1)
        #expect(harness.core.document.currentPageID == ids[0], "held by the lock")
        await settle(harness)
        let clipOrigin = visible(harness).origin
        let documentFrame = harness.canvas.documentViewForTesting.frame
        let liveFrame = try #require(harness.canvas.pageViewForTesting.transform?.pageFrame)
        let nextFrame = try #require(host(harness, page: ids[1])?.documentTransform?.pageFrame)

        locked = false
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[1])
        #expect(harness.canvas.stripAdoptionCountForTesting == 1)
        #expect(visible(harness).origin == clipOrigin, "the scroll origin did not move")
        #expect(harness.canvas.documentViewForTesting.frame == documentFrame)
        #expect(harness.canvas.pageViewForTesting.transform?.pageFrame == nextFrame, "the new page is laid out in its own slot")
        #expect(host(harness, page: ids[0])?.documentTransform?.pageFrame == liveFrame, "the old page stays where it was, now passive")
        #expect(host(harness, page: ids[1]) == nil, "the current page has no passive copy")
    }

    @Test("A hand-off renders nothing for cells already cached: the tiles and the stand-in come from the cache")
    func handOffRendersNothingNew() async throws {
        let harness = try await make("CS cache.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        var locked = true
        harness.canvas.externalPageLock = { locked }
        // Page 1's foot and most of page 2 in view, page 1 held current while both render.
        let slot = try layout(harness).slotFrame(of: 1)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: slot.minY - 100))
        await settle(harness)
        let sheet = try #require(host(harness, page: ids[1]))
        #expect(!sheet.pageView.tileRasters.isEmpty, "the neighbour shows exact tiles")
        let cache = harness.canvas.tileCacheForTesting
        let pixels = cache.renderedPixelCount
        let liveRenders = harness.canvas.rasterRenderStartCountForTesting
        let passiveRenders = harness.canvas.passiveRenderStartCountForTesting

        locked = false
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[1])
        let pageView = harness.canvas.pageViewForTesting
        #expect(!pageView.tileRasters.isEmpty, "the new page shows its cached tiles in the same turn")
        #expect(pageView.baseRaster != nil, "the neighbour's stand-in became the page's base")
        #expect(host(harness, page: ids[0]).map { !$0.pageView.tileRasters.isEmpty } == true, "the old page reads its tiles back")
        await settle(harness)
        #expect(cache.renderedPixelCount == pixels, "no pixel was rendered again")
        #expect(harness.canvas.rasterRenderStartCountForTesting == liveRenders)
        #expect(harness.canvas.passiveRenderStartCountForTesting == passiveRenders)
        #expect(harness.canvas.visibleStripCoverageForTesting() >= 0.999)
    }

    // MARK: - Ink

    @Test("A neighbouring sheet draws its own markups, and an edit on it appears")
    func passivePageShowsItsMarkups() async throws {
        let harness = try await make("CS ink.pdf", pages: 3, calibrate: true)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let record = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }, pageIndex: 1)
        await settle(harness)
        let sheet = try #require(host(harness, page: ids[1]))
        #expect(sheet.pageView.shapes.map(\.id) == [record.id.rawValue])
        #expect(!harness.canvas.canvasShapes.contains { $0.id == record.id.rawValue }, "the current page draws only its own")
        #expect(sheet.pageView.isPassive && sheet.pageView.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test("An edit on a neighbouring sheet appears on it without visiting it")
    func editOnPassivePageAppears() async throws {
        let harness = try await make("CS edit.pdf", pages: 3, calibrate: true)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let sheet = try #require(host(harness, page: ids[1]))
        #expect(sheet.pageView.shapes.isEmpty)
        let first = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }, pageIndex: 1)
        await settle(harness)
        #expect(sheet.pageView.shapes.map(\.id) == [first.id.rawValue])
        _ = try await harness.core.commands.perform(.removeMarkup(first.id))
        await harness.settle()
        await settle(harness)
        #expect(sheet.pageView.shapes.isEmpty, "a deletion on the neighbour is drawn too")
    }

    // MARK: - The page lock

    @Test("Placed points hold the page: scrolling to another sheet neither hands off nor cancels them")
    func pageLockedWhilePointsArePlaced() async throws {
        let harness = try await make("CS lock.pdf", pages: 3, calibrate: true)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.shell.perform(.measureLength)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        #expect(await AppTestSupport.wait { harness.core.measurement.placedPoints.count == 1 })
        try scroll(harness, toPage: 2)
        await waitOutRateLimit()
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[0], "the page is held")
        #expect(harness.core.measurement.placedPoints.count == 1, "the work in progress survives")
        #expect(harness.canvas.stripAdoptionCountForTesting == 0)
        // Escape lets go; the next scroll report hands over.
        harness.core.measurement.cancelActiveMeasurement()
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[2])
    }

    @Test("An armed boundary capture survives scrolling across sheets")
    func boundaryCaptureSurvivesScrolling() async throws {
        let harness = try await make("CS boundary.pdf", pages: 3, calibrate: true)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.core.measurement.beginBoundaryCapture(.projectZone)
        #expect(harness.core.measurement.isCapturingBoundary)
        try scroll(harness, toPage: 1)
        try scroll(harness, toPage: 2)
        #expect(harness.core.measurement.isCapturingBoundary, "old: a page change ended the capture")
        #expect(harness.core.document.currentPageID == ids[0])
        harness.core.measurement.cancelActiveMeasurement()
    }

    @Test("An open text box holds the page")
    func textEntryHoldsThePage() async throws {
        let harness = try await make("CS text entry.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.shell.perform(.textTool)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 120, y: 500), additive: false)
        #expect(harness.canvas.activeTextEntry != nil)
        try scroll(harness, toPage: 2)
        #expect(harness.core.document.currentPageID == ids[0])
        #expect(harness.canvas.activeTextEntry != nil, "the box being typed in survives")
        harness.canvas.commitTextEntry()
    }

    @Test("A calibration point holds the page")
    func calibrationPointHoldsThePage() async throws {
        let harness = try await make("CS calibration.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.canvas.beginCalibration()
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        await harness.canvas.settleCalibrationPlacements()
        #expect(harness.canvas.calibrationPointsForTesting.count == 1)
        try scroll(harness, toPage: 2)
        #expect(harness.core.document.currentPageID == ids[0])
        #expect(harness.canvas.calibrationPointsForTesting.count == 1, "the first point survives")
        harness.canvas.endCalibration()
    }

    @Test("A Select drag (a marquee) holds the page until it is released")
    func selectDragHoldsThePage() async throws {
        let harness = try await make("CS marquee.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let slot = try layout(harness).slotFrame(of: 0)
        let pageView = harness.canvas.pageViewForTesting
        let start = CGPoint(x: slot.minX + 30, y: slot.minY + 30)
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: start))
        pageView.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: CGPoint(x: start.x + 60, y: start.y + 60)))
        #expect(harness.canvas.isPageLocked)
        try scroll(harness, toPage: 2)
        #expect(harness.core.document.currentPageID == ids[0], "held while the button is down")
        pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: CGPoint(x: start.x + 60, y: start.y + 60)))
        #expect(!harness.canvas.isPageLocked)
        await waitOutRateLimit()
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[2], "released, the view is followed again")
    }

    @Test("Work outside the canvas holds the page: a Scale Region's calibration destination, through the window's lock")
    func externalLockHoldsThePage() async throws {
        let harness = try await make("CS external.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.document.pendingScaleCalibration = .region(UUID())
        defer { harness.document.pendingScaleCalibration = nil }
        #expect(harness.canvas.isPageLocked)
        try scroll(harness, toPage: 1)
        #expect(harness.core.document.currentPageID == ids[0])
        // A press on the other sheet is refused, and the status bar says why.
        let slot = try layout(harness).slotFrame(of: 1)
        let point = CGPoint(x: slot.midX, y: slot.minY + 40)
        harness.canvas.pageViewForTesting.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: point))
        harness.canvas.pageViewForTesting.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: point))
        #expect(harness.core.document.currentPageID == ids[0])
        #expect(harness.canvas.stripRefusedPressCountForTesting == 1)
        #expect(harness.core.status.snapshot.activeToolNote?.contains("before using another page") == true)
    }

    // MARK: - Press adoption

    @Test("A press on a neighbouring sheet makes it current before the press is interpreted")
    func pressAdoptsThePageBeforeTheClick() async throws {
        let harness = try await make("CS press.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let slot = try layout(harness).slotFrame(of: 1)
        let point = CGPoint(x: slot.midX, y: slot.minY + 40)
        let pageView = harness.canvas.pageViewForTesting
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: point))
        #expect(harness.core.document.currentPageID == ids[1], "adopted at the press")
        #expect(harness.core.canvas.viewport.pageID == ids[1], "the tools act on the pressed sheet")
        #expect(pageView.pagePoint(atWindowLocation: pageView.convert(point, to: nil)) != nil, "the press lands on the current page")
        pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: point))
        #expect(harness.canvas.stripAdoptionCountForTesting == 1)
    }

    @Test("A press on another sheet while work holds the current one is ignored, as a press off the sheet")
    func pressWhileLockedIsIgnored() async throws {
        let harness = try await make("CS refused.pdf", pages: 3, calibrate: true)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.shell.perform(.measureLength)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        #expect(await AppTestSupport.wait { harness.core.measurement.placedPoints.count == 1 })
        let slot = try layout(harness).slotFrame(of: 1)
        let point = CGPoint(x: slot.midX, y: slot.minY + 40)
        let pageView = harness.canvas.pageViewForTesting
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: point))
        pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: point))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.core.document.currentPageID == ids[0])
        #expect(harness.canvas.stripRefusedPressCountForTesting == 1)
        #expect(harness.core.measurement.placedPoints.count == 1, "no point was placed on the other sheet")
        harness.core.measurement.cancelActiveMeasurement()
    }

    // MARK: - Navigation and zoom

    @Test("Navigation rests the page: Navigator, next and previous, first and last, a search hit, a bookmark")
    func navigationRestsThePage() async throws {
        let harness = try await make("CS navigate.pdf", pages: 5)
        defer { harness.tearDown() }
        let document = harness.core.document
        let ids = pageIDs(harness)
        func expectRested(_ index: Int, _ label: String) throws {
            harness.canvas.refresh()
            #expect(document.currentPageID == ids[index], "\(label): current")
            let slot = try layout(harness).slotFrame(of: index)
            let view = visible(harness)
            if slot.height + 2 * PageStripLayout.restingGap > view.height {
                #expect(abs(view.minY - (slot.minY - PageStripLayout.restingGap)) < 1, "\(label): top rested")
            } else {
                #expect(abs(view.midY - slot.midY) < 1, "\(label): centred")
            }
        }
        document.selectPage(id: ids[3], mode: .replace)
        try expectRested(3, "Navigator")
        document.goToNextPage()
        try expectRested(4, "next")
        document.goToPreviousPage()
        try expectRested(3, "previous")
        document.goToFirstPage()
        try expectRested(0, "first")
        document.goToLastPage()
        try expectRested(4, "last")
        // A navigation to the page already current rests it too.
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: try layout(harness).slotFrame(of: 4).minY + 60))
        document.goToPage(id: ids[4])
        try expectRested(4, "same page")
        // A search hit: the page, then the word marked on it.
        document.goToPage(id: ids[1])
        harness.canvas.revealPageRect(PDFRectValue(x: 100, y: 400, width: 60, height: 12), highlight: true)
        #expect(document.currentPageID == ids[1])
        #expect(harness.canvas.searchHighlightsForTesting.count == 1)
        // A bookmark: the page, then its left and top.
        harness.canvas.show(pageID: ids[2], left: 50, top: 700) { document.goToPage(id: $0) }
        harness.canvas.refresh()
        #expect(document.currentPageID == ids[2])
        let place = try #require(harness.canvas.currentPlace())
        #expect(abs((place.top ?? 0) - 700) < 1 && abs((place.left ?? 0) - 50) < 1, "the bookmark's place, not the rest")
    }

    @Test("A zoom about a point on a neighbouring sheet keeps that point under the pointer")
    func zoomKeepsAnAnchorOnANonCurrentPage() async throws {
        let harness = try await make("CS anchor.pdf", pages: 3)
        defer { harness.tearDown() }
        var locked = true
        harness.canvas.externalPageLock = { locked }
        let before = try layout(harness)
        let slot = before.slotFrame(of: 1)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: slot.minY - visible(harness).height / 2))
        let page = harness.core.document.pages[1]
        let anchorDoc = CGPoint(x: slot.midX, y: slot.minY + 50)
        let transformBefore = PageDisplayTransform(pageBox: page.viewBox, rotation: page.displayRotation,
                                                   zoom: before.zoom, origin: before.slotOrigin(of: 1))
        let pagePoint = transformBefore.pagePoint(from: anchorDoc)
        let pageView = harness.canvas.pageViewForTesting
        let window = pageView.convert(anchorDoc, to: nil)
        harness.canvas.zoom(by: 2, aboutWindowPoint: window)
        locked = false
        let after = try layout(harness)
        let transformAfter = PageDisplayTransform(pageBox: page.viewBox, rotation: page.displayRotation,
                                                  zoom: after.zoom, origin: after.slotOrigin(of: 1))
        let landed = pageView.convert(transformAfter.viewPoint(from: pagePoint), to: nil)
        #expect(abs(landed.x - window.x) < 0.5 && abs(landed.y - window.y) < 0.5, "moved to \(landed) from \(window)")
    }

    @Test("A pinch's commit moves no neighbouring sheet from where the gesture showed it")
    func pinchCommitMovesNoNeighbour() async throws {
        let harness = try await make("CS pinch.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let canvas = harness.canvas
        let anchor = canvas.pageViewForTesting.convert(CGPoint(x: visible(harness).midX, y: visible(harness).midY), to: nil)
        let layoutsBefore = canvas.layoutCountForTesting
        canvas.gestureZoom(by: 1.3, aboutWindowPoint: anchor, phase: .began)
        canvas.gestureZoom(by: 1.2, aboutWindowPoint: anchor, phase: .changed)
        canvas.displayFrameForTesting()
        #expect(canvas.layoutCountForTesting == layoutsBefore, "no layout during the pinch")
        let live = canvas.documentViewForTesting.liveTransform
        let shown = try #require(host(harness, page: ids[1])?.documentTransform?.pageFrame).applying(live)
        let originBefore = visible(harness).origin
        let shownInClip = shown.offsetBy(dx: -originBefore.x, dy: -originBefore.y)
        canvas.gestureZoom(by: 1, aboutWindowPoint: anchor, phase: .ended)
        #expect(canvas.layoutCountForTesting == layoutsBefore + 1, "one layout at the gesture's end")
        // The commit's own scroll is reported inside its layout, where the follow rule waits for
        // the gesture: no report is left to run later, so nothing after the commit can hand off
        // or re-base before the person's next scroll. One layout per gesture end, exactly.
        #expect(!canvas.visibleRectReportPendingForTesting, "a report left for later could lay out again")
        let slot = try layout(harness).slotFrame(of: 1)
        let originAfter = visible(harness).origin
        let laidInClip = slot.offsetBy(dx: -originAfter.x, dy: -originAfter.y)
        #expect(abs(laidInClip.minX - shownInClip.minX) < 0.5 && abs(laidInClip.minY - shownInClip.minY) < 0.5)
        #expect(abs(laidInClip.width - shownInClip.width) < 0.5 && abs(laidInClip.height - shownInClip.height) < 0.5)
    }

    @Test("Fit Page centres the current page, not the first")
    func fitPageCentresTheCurrentPage() async throws {
        let harness = try await make("CS fit.pdf", pages: 4)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        try scroll(harness, toPage: 2)
        #expect(harness.core.document.currentPageID == ids[2])
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 2.5)
        harness.canvas.refresh()
        harness.core.canvas.zoomToFit()
        harness.canvas.refresh()
        #expect(harness.core.document.currentPageID == ids[2])
        let slot = try layout(harness).slotFrame(of: 2)
        #expect(abs(visible(harness).midY - slot.midY) < 1)
        #expect(abs(visible(harness).midX - slot.midX) < 1)
    }

    // MARK: - Memory and structure

    @Test("Neighbouring sheets are virtualised: at most twelve, near the view, their stand-ins bounded")
    func hostsAreVirtualised() async throws {
        let harness = try await make("CS many sheets.pdf", pages: 40)
        defer { harness.tearDown() }
        harness.core.canvas.setZoom(0.1)
        harness.canvas.refresh()
        await settle(harness)
        #expect(harness.canvas.passivePagesForTesting.count <= PDFCanvasViewController.passiveHostLimit)
        #expect(harness.canvas.passivePagesForTesting.count >= 4, "a low zoom shows many sheets")
        let strip = try layout(harness)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: strip.slotFrame(of: 25).minY))
        await settle(harness)
        let band = visible(harness).insetBy(dx: 0, dy: -visible(harness).height)
        for sheet in harness.canvas.passivePagesForTesting {
            let frame = try #require(sheet.documentTransform?.pageFrame)
            #expect(frame.intersects(band), "a sheet far from the view is not materialised")
        }
        #expect(harness.canvas.passivePagesForTesting.count <= PDFCanvasViewController.passiveHostLimit)
        #expect(harness.canvas.passiveBaseBytesForTesting <= PDFCanvasViewController.passiveBaseByteBudget)
    }

    /// The structural change the strip must survive without moving the view: the page list
    /// changes above the current page. Exercised by taking a sheet out of the set above it,
    /// which re-lays the strip exactly as an insertion above does.
    @Test("Pages leaving the set above the current page keep the view on what it showed")
    func pagesRemovedAboveKeepTheView() async throws {
        let harness = try await make("CS structure.pdf", pages: 4)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        try scroll(harness, toPage: 2)
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[2])
        let transform = try #require(harness.canvas.pageViewForTesting.transform)
        let centre = transform.pagePoint(from: CGPoint(x: visible(harness).midX, y: visible(harness).midY))
        _ = try await harness.core.commands.perform(.setPagesExcluded([PageID(ids[0])], excluded: true))
        await harness.settle()
        harness.canvas.refresh()
        #expect(harness.core.document.pages.count == 3)
        #expect(harness.core.document.currentPageID == ids[2])
        let moved = try #require(harness.canvas.pageViewForTesting.transform)
        let now = moved.pagePoint(from: CGPoint(x: visible(harness).midX, y: visible(harness).midY))
        #expect(abs(now.x - centre.x) < 1 && abs(now.y - centre.y) < 1, "the view slid from \(centre) to \(now)")
    }

    @Test("A search highlight stays on the sheet it was found on as the view moves on")
    func searchHighlightStaysOnItsPage() async throws {
        let harness = try await make("CS search.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.core.document.goToPage(id: ids[1])
        harness.canvas.refresh()
        let hit = PDFRectValue(x: 100, y: 400, width: 60, height: 12)
        harness.canvas.revealPageRect(hit, highlight: true)
        #expect(harness.canvas.searchHighlightsForTesting == [hit])
        try scroll(harness, toPage: 0)
        #expect(harness.core.document.currentPageID == ids[0])
        #expect(harness.canvas.searchHighlightsForTesting.isEmpty, "not drawn on the wrong sheet")
        #expect(host(harness, page: ids[1])?.pageView.searchHighlights == [hit], "still on its own sheet")
        harness.canvas.clearSearchHighlights()
        #expect(host(harness, page: ids[1])?.pageView.searchHighlights.isEmpty == true)
    }

    @Test("While PDF layers are overridden the canvas shows one page at a time and says why")
    func layerOverrideSuspendsContinuous() async throws {
        let harness = try await make("CS layers.pdf", pages: 3)
        defer { harness.tearDown() }
        var overridden = true
        harness.canvas.layerOverridesActive = { overridden }
        harness.canvas.setLayerFiltering(nil)
        #expect(!harness.canvas.isContinuousScrollActive)
        #expect(harness.canvas.passivePagesForTesting.isEmpty, "no neighbour could show a hidden layer")
        #expect(harness.canvas.scrollViewForTesting.onTurnPage != nil, "the single-page turn is back")
        #expect(harness.core.status.snapshot.activeToolNote?.contains("PDF layers") == true)
        overridden = false
        harness.canvas.setLayerFiltering(nil)
        #expect(harness.canvas.isContinuousScrollActive)
        #expect(harness.canvas.scrollViewForTesting.onTurnPage == nil)
    }

    @Test("Switching the mode keeps the page and the place on it, both ways")
    func modeToggleKeepsThePlace() async throws {
        let harness = try await make("CS toggle.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 3)
        harness.canvas.refresh()
        let slot = try layout(harness).slotFrame(of: 1)
        scroll(harness, to: CGPoint(x: slot.minX + 100, y: slot.minY + 200))
        await waitOutRateLimit()
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[1])
        func centre() throws -> PDFPointValue {
            let transform = try #require(harness.canvas.pageViewForTesting.transform)
            return transform.pagePoint(from: CGPoint(x: visible(harness).midX, y: visible(harness).midY))
        }
        let before = try centre()
        harness.canvas.pageLayoutPreference = { .singlePage }
        #expect(!harness.canvas.isContinuousScrollActive)
        #expect(harness.core.document.currentPageID == ids[1])
        let single = try centre()
        #expect(abs(single.x - before.x) < 1 && abs(single.y - before.y) < 1, "single: \(single) against \(before)")
        harness.canvas.pageLayoutPreference = { .continuous }
        #expect(harness.canvas.isContinuousScrollActive)
        #expect(harness.core.document.currentPageID == ids[1])
        let again = try centre()
        #expect(abs(again.x - before.x) < 1 && abs(again.y - before.y) < 1, "continuous: \(again) against \(before)")
    }

    @Test("A current page scrolled out of view is not a refused render")
    func offscreenLivePageIsNotARefusal() async throws {
        let harness = try await make("CS offscreen.pdf", pages: 4)
        defer { harness.tearDown() }
        harness.canvas.externalPageLock = { true }
        try scroll(harness, toPage: 2)
        await settle(harness)
        #expect(harness.core.document.currentPageID == harness.core.document.pages[0].id)
        #expect(harness.canvas.pageViewForTesting.renderNotice != .refused)
        #expect(harness.canvas.rasterFailureCountForTesting == 0)
        #expect(harness.canvas.visibleStripCoverageForTesting() >= 0.999, "the sheets in view are drawn")
    }

    @Test("Scrolling past sheets builds no snap index before the view rests on one")
    func flingBuildsNoSnapIndexBeforeDwell() async throws {
        let harness = try await make("CS fling.pdf", pages: 5)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        var built: [UUID] = []
        // The dwell is a gate the test opens, not a race against the machine's speed.
        var dwellOpen = false
        harness.core.pageDwellWait = { _ in
            // A superseded dwell is cancelled, and a cancelled sleep returns at once: it leaves.
            while !dwellOpen && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        harness.core.snapIndexSource = { page in
            built.append(page.id.rawValue)
            return AppCoreEnvironment.SnapIndexBuild()
        }
        try? await Task.sleep(for: .milliseconds(50))
        built.removeAll()
        for index in 1...3 {
            try scroll(harness, toPage: index)
            #expect(harness.core.document.currentPageID == ids[index])
            await waitOutRateLimit()
        }
        #expect(!built.contains(ids[1]) && !built.contains(ids[2]) && !built.contains(ids[3]),
                "no extraction for a sheet scrolled past, nor yet for the last before the dwell")
        dwellOpen = true
        #expect(await AppTestSupport.wait { built.contains(ids[3]) }, "the sheet the view rests on is indexed")
        #expect(!built.contains(ids[1]) && !built.contains(ids[2]))
    }

    @Test("A canvas that leaves the screen drops its neighbouring sheets")
    func releaseDropsHosts() async throws {
        let harness = try await make("CS release.pdf", pages: 3)
        defer { harness.tearDown() }
        #expect(!harness.canvas.passivePagesForTesting.isEmpty)
        harness.canvas.viewDidDisappear()
        #expect(harness.canvas.passivePagesForTesting.isEmpty)
    }

    // MARK: - Review fixes

    private static let linework = "2 w 0 0 0 RG 72 72 m 300 300 l S\n"

    /// Sizes the canvas's scroll view, as the viewer gates do, without ordering the window in.
    private func sizeCanvas(_ harness: Fix2Harness, to target: CGSize) throws {
        let window = try #require(harness.controller.window)
        let scrollView = harness.canvas.scrollViewForTesting
        for _ in 0..<3 {
            let size = scrollView.contentSize
            let dw = target.width - size.width, dh = target.height - size.height
            guard abs(dw) > 0.5 || abs(dh) > 0.5 else { break }
            let content = window.contentRect(forFrameRect: window.frame).size
            window.setContentSize(NSSize(width: content.width + dw, height: content.height + dh))
            window.layoutIfNeeded()
            harness.canvas.view.layoutSubtreeIfNeeded()
        }
        #expect(!window.isVisible)
    }

    private func makePages(_ name: String, mediaBox: String, count: Int) async throws -> Fix2Harness {
        let url = try AutomationFixtures.writePages(named: name, mediaBox: mediaBox, contents: Array(repeating: Self.linework, count: count))
        let harness = try await Fix2Harness.make(name, calibrate: false, fixture: url, pageLayout: .continuous)
        harness.canvas.refresh()
        await settle(harness)
        return harness
    }

    private func centrePagePoint(_ harness: Fix2Harness) throws -> PDFPointValue {
        let transform = try #require(harness.canvas.pageViewForTesting.transform)
        return transform.pagePoint(from: CGPoint(x: visible(harness).midX, y: visible(harness).midY))
    }

    @Test("A0 sheets at 6400 %: scrolling moves from one sheet onto the next, and the window's re-base moves nothing on screen")
    func scrollsAcrossOversizedSheets() async throws {
        let harness = try await makePages("CS A0.pdf", mediaBox: "0 0 2384 3370", count: 4)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.core.canvas.setZoom(ViewportSnapshot.maximumZoom)
        harness.canvas.refresh()
        #expect(try layout(harness).isWindowed)
        try scroll(harness, toPage: 1)
        #expect(harness.core.document.currentPageID == ids[1], "onto the second sheet")
        await waitOutRateLimit()
        // Towards the foot of the second sheet, the window's edge: it re-bases onto the third.
        let foot = try layout(harness).slotFrame(of: 1).maxY - visible(harness).height - 200
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: foot), report: false)
        let before = try centrePagePoint(harness)
        let rebases = harness.canvas.stripRebaseCountForTesting
        harness.canvas.reportVisibleRect()
        #expect(harness.canvas.stripRebaseCountForTesting == rebases + 1)
        #expect(try layout(harness).window.contains(2))
        let after = try centrePagePoint(harness)
        #expect(abs(after.x - before.x) < 0.01 && abs(after.y - before.y) < 0.01, "the re-base moved the view: \(before) → \(after)")
        await waitOutRateLimit()
        try scroll(harness, toPage: 2)
        #expect(harness.core.document.currentPageID == ids[2], "onto the third sheet")
    }

    @Test("A0 sheets at 6400 % with work holding the first: the window goes as far as it can keep that sheet, then stops and says why")
    func lockedPageHoldsTheWindowWithANote() async throws {
        let harness = try await makePages("CS A0 locked.pdf", mediaBox: "0 0 2384 3370", count: 4)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.core.canvas.setZoom(ViewportSnapshot.maximumZoom)
        harness.canvas.refresh()
        harness.canvas.externalPageLock = { true }
        // A tool's own note is up: the strip's note waits rather than replace it, and is not
        // counted as said.
        harness.core.status.setActiveToolNote("Placing a pick")
        #expect(try layout(harness).window == 0..<2)
        // The foot of the second sheet: a window around the third would leave out the held first
        // sheet, a window around the second keeps it and lets the view on to the third.
        let rebases = harness.canvas.stripRebaseCountForTesting
        var foot = try layout(harness).slotFrame(of: 1).maxY - visible(harness).height - 200
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: foot))
        #expect(harness.canvas.stripRebaseCountForTesting == rebases + 1, "re-based around the second sheet")
        #expect(try layout(harness).window == 0..<3)
        #expect(harness.core.status.snapshot.activeToolNote == "Placing a pick")
        // The foot of the third sheet: no window keeps the first any more, so the view stops.
        foot = try layout(harness).slotFrame(of: 2).maxY - visible(harness).height - 200
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: foot))
        #expect(harness.canvas.stripRebaseCountForTesting == rebases + 1)
        #expect(harness.core.document.currentPageID == ids[0])
        #expect(harness.core.status.snapshot.activeToolNote == "Placing a pick", "another note is never replaced")
        // Once the status bar is free the stop is explained.
        harness.core.status.setActiveToolNote(nil)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: foot + 20))
        #expect(harness.core.status.snapshot.activeToolNote?.contains("to scroll further") == true)
    }

    @Test("A zoom about a point two sheets from the current one keeps that point under the pointer, and follows it")
    func pointerZoomAcrossTheWindowKeepsItsAnchor() async throws {
        let harness = try await makePages("CS A0 zoom.pdf", mediaBox: "0 0 2384 3370", count: 6)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.core.canvas.setZoom(ViewportSnapshot.minimumZoom)
        harness.canvas.refresh()
        harness.core.document.goToPage(id: ids[0])
        harness.canvas.refresh()
        let strip = try layout(harness)
        let slot = strip.slotFrame(of: 3)
        let page = harness.core.document.pages[3]
        let pointDoc = CGPoint(x: slot.midX, y: slot.minY + slot.height / 3)
        let pointPage = PageDisplayTransform(pageBox: page.viewBox, rotation: page.displayRotation,
                                             zoom: strip.zoom, origin: strip.slotOrigin(of: 3)).pagePoint(from: pointDoc)
        let pageView = harness.canvas.pageViewForTesting
        let window = pageView.convert(pointDoc, to: nil)
        harness.canvas.zoom(by: ViewportSnapshot.maximumZoom / ViewportSnapshot.minimumZoom, aboutWindowPoint: window)
        let after = try layout(harness)
        #expect(after.window.contains(3), "the window is laid out around the pointer's sheet")
        let landed = pageView.convert(PageDisplayTransform(pageBox: page.viewBox, rotation: page.displayRotation,
                                                           zoom: after.zoom, origin: after.slotOrigin(of: 3)).viewPoint(from: pointPage), to: nil)
        #expect(abs(landed.x - window.x) < 0.5 && abs(landed.y - window.y) < 0.5, "moved to \(landed) from \(window)")
        #expect(harness.core.document.currentPageID == ids[3], "the sheet zoomed into becomes current")
    }

    @Test("A hand-off onto an uncached sheet leaves the sheet just left at full sharpness")
    func handOffKeepsTheOutgoingSheetSharp() async throws {
        let harness = try await make("CS outgoing.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        var locked = true
        harness.canvas.externalPageLock = { locked }
        let slot = try layout(harness).slotFrame(of: 1)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: slot.minY - 120))
        await settle(harness)
        // Only the current page's tiles stay cached: the incoming sheet must render.
        harness.canvas.tileCacheForTesting.removeAll(except: Set(harness.canvas.currentTileKeys))
        locked = false
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[1])
        #expect(harness.canvas.pendingPlan != nil, "the incoming sheet's render is in flight")
        let outgoing = try #require(host(harness, page: ids[0]))
        let transform = try #require(outgoing.pageView.transform)
        let origin = outgoing.pageView.frame.origin
        let shown = visible(harness).offsetBy(dx: -origin.x, dy: -origin.y).intersection(transform.pageFrame)
        let scale = outgoing.pageView.effectiveBackingScale
        let exact = outgoing.pageView.tileRasters.map { $0.placement(in: transform, backingScale: scale) }.filter(\.isPixelExact)
        #expect(!exact.isEmpty, "the sheet just left shows its cached tiles at once")
        #expect(CanvasPageView.coveredFraction(of: shown, by: exact.map(\.destination)) >= 0.999)
        await settle(harness)
    }

    /// An A4 between two A1 sheets: at the A1's fit zoom the A4 is the smallest sheet in view.
    private func makeMixedSizes(_ name: String) async throws -> Fix2Harness {
        let url = try AutomationFixtures.writePDF(
            named: name,
            objects: [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2384 1684] /Contents 4 0 R >>", "",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 6 0 R >>", "",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2384 1684] /Contents 8 0 R >>", ""
            ],
            streams: [4: Self.linework, 6: Self.linework, 8: Self.linework]
        )
        let harness = try await Fix2Harness.make(name, calibrate: false, fixture: url, pageLayout: .continuous)
        harness.canvas.refresh()
        await settle(harness)
        return harness
    }

    @Test("A sheet navigated to stays current beside larger neighbours, through a resize and a zoom, until the person scrolls")
    func navigatedPageStaysCurrentUntilAScroll() async throws {
        let harness = try await makeMixedSizes("CS mixed.pdf")
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let strip = try layout(harness)
        #expect(strip.slotFrame(of: 1).midX == strip.slotFrame(of: 0).midX, "mixed sizes share the centre line")
        harness.core.document.goToPage(id: ids[1])
        harness.canvas.refresh()
        #expect(harness.core.document.currentPageID == ids[1])
        let a4 = try layout(harness).slotFrame(of: 1).intersection(visible(harness))
        let a1 = try layout(harness).slotFrame(of: 0).intersection(visible(harness))
        #expect(a1.width * a1.height > a4.width * a4.height, "a neighbour shows more of itself than the A4")
        try sizeCanvas(harness, to: CGSize(width: 1300, height: 900))
        harness.canvas.refresh()
        #expect(harness.core.document.currentPageID == ids[1], "a resize keeps it")
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 1.25)
        harness.canvas.refresh()
        #expect(harness.core.document.currentPageID == ids[1], "a zoom keeps it")
        await waitOutRateLimit()
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: visible(harness).minY + 40))
        #expect(harness.core.document.currentPageID != ids[1], "a scroll lets the view lead again")
    }

    @Test("A press on the smaller sheet keeps it current after the press")
    func pressedSmallPageStaysCurrent() async throws {
        let harness = try await makeMixedSizes("CS mixed press.pdf")
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let slot = try layout(harness).slotFrame(of: 1)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: slot.midY - visible(harness).height / 2))
        await waitOutRateLimit()
        let point = CGPoint(x: slot.midX, y: slot.midY)
        let pageView = harness.canvas.pageViewForTesting
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: point))
        pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: point))
        #expect(harness.core.document.currentPageID == ids[1])
        // Past the hand-off rate limit, so a follow would happen now if the press did not hold.
        await waitOutRateLimit()
        harness.canvas.refresh()
        harness.canvas.reportVisibleRect()
        #expect(harness.core.document.currentPageID == ids[1], "not followed away without a scroll")
    }

    @Test("A page list replaced before its layout is never indexed with the old strip")
    func stalePageListIsLaidOutFirst() async throws {
        let harness = try await make("CS stale.pdf", pages: 4)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let all = try await harness.core.session.snapshot()
        _ = try await harness.core.commands.perform(.setPagesExcluded([PageID(ids[0])], excluded: true))
        await harness.settle()
        let three = try await harness.core.session.snapshot()
        #expect(three.pages.count == 3)
        harness.core.document.adopt(all)
        harness.canvas.refresh()
        #expect(try layout(harness).pageCount == 4)
        try scroll(harness, toPage: 3)
        // The page list shrinks; the layout has not run. A scroll report must not use index 3.
        harness.core.document.adopt(three)
        #expect(try layout(harness).pageCount == 4, "the stale state under test")
        harness.canvas.updatePassiveHosts()
        harness.canvas.reportVisibleRect()
        #expect(try layout(harness).pageCount == 3, "laid out before anything else")
        #expect(harness.canvas.passivePagesForTesting.allSatisfy { sheet in harness.core.document.pages.contains { $0.id == sheet.pageID } })
    }

    @Test("An annotation display change re-renders the neighbouring sheets too")
    func annotationChangeResetsNeighbours() async throws {
        let harness = try await make("CS annotations.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        // The second sheet in view beside the first, which stays current.
        harness.canvas.externalPageLock = { true }
        let slot = try layout(harness).slotFrame(of: 1)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: slot.minY - 120))
        await settle(harness)
        let sheet = try #require(host(harness, page: ids[1]))
        try #require(!sheet.pageView.tileRasters.isEmpty)
        let renders = harness.canvas.passiveRenderStartCountForTesting
        harness.canvas.setLayerFiltering(nil)
        #expect(sheet.deliveredPlan == nil, "the old delivery no longer satisfies")
        #expect(!sheet.pageView.staleTileRasters.isEmpty, "yesterday's pixels stand in meanwhile")
        await settle(harness)
        #expect(harness.canvas.passiveRenderStartCountForTesting > renders, "the neighbour rendered again")
        #expect(!sheet.pageView.tileRasters.isEmpty && sheet.pageView.staleTileRasters.isEmpty)
    }

    @Test("Over the stand-in budget, steady scrolling fetches no stand-in twice")
    func standInBudgetDoesNotThrash() async throws {
        let harness = try await makePages("CS budget.pdf", mediaBox: "0 0 2384 1684", count: 24)
        defer { harness.tearDown() }
        try sizeCanvas(harness, to: CGSize(width: 1600, height: 1400))
        let backing = harness.canvas.pageViewForTesting.effectiveBackingScale
        // Just over the small stand-in's 512 device pixels, so every sheet wants the full one.
        harness.core.canvas.setZoom(Double(530 / (2384 * backing)))
        harness.canvas.refresh()
        await settle(harness)
        harness.canvas.updatePassiveHosts()
        await settle(harness)
        let hosts = harness.canvas.passivePagesForTesting.count
        let fetches = harness.canvas.passiveBaseFetchCountForTesting
        #expect(hosts >= 9, "enough full-size stand-ins to pass the budget: \(hosts)")
        #expect(fetches > hosts, "the budget stepped some stand-ins down")
        for _ in 0..<3 {
            harness.canvas.updatePassiveHosts()
            await settle(harness)
        }
        #expect(harness.canvas.passiveBaseFetchCountForTesting == fetches, "a dropped stand-in was fetched back")
        #expect(harness.canvas.passiveBaseBytesForTesting <= PDFCanvasViewController.passiveBaseByteBudget)
    }

    @Test("The strip's notes never replace a note already in the status bar")
    func stripNotesDoNotOverwrite() async throws {
        let harness = try await make("CS note.pdf", pages: 3)
        defer { harness.tearDown() }
        harness.core.status.setActiveToolNote("Measuring on Walls only")
        harness.canvas.layerOverridesActive = { true }
        harness.canvas.setLayerFiltering(nil)
        #expect(!harness.canvas.isContinuousScrollActive)
        #expect(harness.core.status.snapshot.activeToolNote == "Measuring on Walls only")
    }

    @Test("A preset dropped on another sheet while work holds the current one is refused, not misplaced")
    func dropWhileLockedIsRefused() async throws {
        let harness = try await make("CS drop locked.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        harness.canvas.externalPageLock = { true }
        harness.core.status.setActiveToolNote(nil)
        let slot = try layout(harness).slotFrame(of: 1)
        let window = harness.canvas.pageViewForTesting.convert(CGPoint(x: slot.midX, y: slot.minY + 40), to: nil)
        // A real preset, which would place a count mark wherever the drop lands.
        let original = harness.core.toolLibrary.presets
        defer { harness.document.applyToolPresets(original) }
        let preset = ToolPresetSummary(
            id: UUID(), name: "Dropped Count", category: "Test", panel: .projectTools, markupKind: .count,
            measurementKind: .count, colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1), defaultSubject: "Doors"
        )
        harness.document.applyToolPresets(original + [preset])
        #expect(await AppTestSupport.wait { harness.core.toolLibrary.presets.contains { $0.id == preset.id } })
        let drop = try #require(harness.canvas.scrollViewForTesting.onDropPreset)
        #expect(!drop(preset.id, window))
        #expect(harness.core.document.currentPageID == ids[0])
        #expect(harness.core.status.snapshot.activeToolNote?.contains("before using another page") == true)
        await harness.settle()
        #expect(!harness.core.snapshot.markups.contains { $0.subject == "Doors" }, "nothing was placed on the held page")
    }

    @Test("Drop and right-click adopt the sheet under them")
    func dropAndRightClickAdopt() async throws {
        let harness = try await make("CS adopt.pdf", pages: 3, calibrate: true)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let strip = try layout(harness)
        let pageView = harness.canvas.pageViewForTesting
        // A Tool Library drop (an unknown preset places nothing, the adoption still happens).
        let onSecond = pageView.convert(CGPoint(x: strip.slotFrame(of: 1).midX, y: strip.slotFrame(of: 1).minY + 40), to: nil)
        let drop = try #require(harness.canvas.scrollViewForTesting.onDropPreset)
        _ = drop(UUID(), onSecond)
        #expect(harness.core.document.currentPageID == ids[1])
        // A right-click with Length armed: it finishes the (empty) measurement, no menu opens.
        harness.shell.perform(.measureLength)
        harness.canvas.refresh()
        let third = CGPoint(x: strip.slotFrame(of: 2).midX, y: strip.slotFrame(of: 2).minY + 40)
        pageView.rightMouseDown(with: harness.mouseEvent(.rightMouseDown, atLocal: third))
        #expect(harness.core.document.currentPageID == ids[2])
    }

    @Test("A window resize in the strip keeps the place")
    func resizeKeepsThePlace() async throws {
        let harness = try await make("CS resize.pdf", pages: 3)
        defer { harness.tearDown() }
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 3)
        harness.canvas.refresh()
        let slot = try layout(harness).slotFrame(of: 1)
        scroll(harness, to: CGPoint(x: slot.minX + 80, y: slot.minY + 150))
        let before = try centrePagePoint(harness)
        let page = harness.core.document.currentPageID
        try sizeCanvas(harness, to: CGSize(width: 1100, height: 760))
        #expect(harness.core.document.currentPageID == page)
        let after = try centrePagePoint(harness)
        #expect(abs(after.x - before.x) < 1 && abs(after.y - before.y) < 1, "\(before) → \(after)")
    }

    @Test("A zoom about a point on a neighbouring sheet, nothing held: the point stays under the pointer and its sheet is followed")
    func unlockedZoomOnANeighbourFollows() async throws {
        let harness = try await make("CS zoom follow.pdf", pages: 3)
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        let before = try layout(harness)
        let slot = before.slotFrame(of: 1)
        scroll(harness, to: CGPoint(x: visible(harness).minX, y: slot.minY - visible(harness).height / 2))
        await waitOutRateLimit()
        let page = harness.core.document.pages[1]
        let anchorDoc = CGPoint(x: slot.midX, y: slot.minY + 60)
        let pagePoint = PageDisplayTransform(pageBox: page.viewBox, rotation: page.displayRotation,
                                             zoom: before.zoom, origin: before.slotOrigin(of: 1)).pagePoint(from: anchorDoc)
        let pageView = harness.canvas.pageViewForTesting
        let window = pageView.convert(anchorDoc, to: nil)
        harness.canvas.zoom(by: 4, aboutWindowPoint: window)
        let after = try layout(harness)
        let landed = pageView.convert(PageDisplayTransform(pageBox: page.viewBox, rotation: page.displayRotation,
                                                           zoom: after.zoom, origin: after.slotOrigin(of: 1)).viewPoint(from: pagePoint), to: nil)
        #expect(abs(landed.x - window.x) < 0.5 && abs(landed.y - window.y) < 0.5)
        #expect(harness.core.document.currentPageID == ids[1], "the sheet under the zoom is followed")
    }

    @Test("A canvas off screen does not lay out for a preference change; it does when it appears")
    func offscreenCanvasWaitsForThePreference() async throws {
        let harness = try await make("CS offscreen pref.pdf", pages: 3)
        defer { harness.tearDown() }
        harness.canvas.viewDidDisappear()
        let layouts = harness.canvas.layoutCountForTesting
        harness.canvas.pageLayoutPreference = { .singlePage }
        #expect(harness.canvas.layoutCountForTesting == layouts, "no layout for a canvas nobody sees")
        #expect(harness.canvas.isContinuousScrollActive)
        harness.canvas.viewDidAppear()
        #expect(!harness.canvas.isContinuousScrollActive)
    }

    @Test("A tool drag whose release never comes stops holding the page when the canvas loses the keyboard")
    func lostReleaseDoesNotHoldThePage() async throws {
        let harness = try await make("CS lost release.pdf", pages: 3, calibrate: true)
        defer { harness.tearDown() }
        harness.shell.perform(.measureArea)
        harness.canvas.refresh()
        let slot = try layout(harness).slotFrame(of: 0)
        let pageView = harness.canvas.pageViewForTesting
        let start = CGPoint(x: slot.minX + 40, y: slot.minY + 40)
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: start))
        pageView.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: CGPoint(x: start.x + 50, y: start.y + 50)))
        #expect(pageView.isTrackingPress)
        #expect(harness.canvas.isPageLocked)
        _ = pageView.resignFirstResponder()
        #expect(!pageView.isTrackingPress)
        // The drag is finished where it last was, and nothing holds the page any more.
        #expect(await AppTestSupport.wait { !harness.canvas.isPageLocked }, "the page is still held")
        await harness.settle()
        #expect(await harness.records().count == 1, "the dragged area was finished, not thrown away")
    }

    @Test("A tool drag's release that still arrives after the canvas lost the keyboard ends that drag and nothing more")
    func releaseAfterLosingTheKeyboardEndsTheDrag() async throws {
        let harness = try await make("CS late release.pdf", pages: 3, calibrate: true)
        defer { harness.tearDown() }
        harness.shell.perform(.measureArea)
        harness.canvas.refresh()
        let slot = try layout(harness).slotFrame(of: 0)
        let pageView = harness.canvas.pageViewForTesting
        let start = CGPoint(x: slot.minX + 40, y: slot.minY + 40)
        let end = CGPoint(x: start.x + 50, y: start.y + 50)
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: start))
        pageView.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: end))
        _ = pageView.resignFirstResponder()
        // AppKit still sends the rest of the gesture to the view that took the press.
        pageView.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: CGPoint(x: end.x + 30, y: end.y + 30)))
        pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: CGPoint(x: end.x + 30, y: end.y + 30)))
        #expect(await AppTestSupport.wait { !harness.canvas.isPageLocked })
        await harness.settle()
        #expect(await harness.records().count == 1, "one area, finished once")
        #expect(harness.core.measurement.placedPoints.isEmpty, "the release placed no stray point")
    }

    @Test("A press right after entering the strip, before the first fetch, never hit-tests the previous page's records")
    func pressBeforeTheFirstFetchUsesNoStaleRecords() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "CS early press.pdf", pageCount: 3)
        let harness = try await Fix2Harness.make("CS early press.pdf", calibrate: true, fixture: url, pageLayout: .singlePage)
        defer { harness.tearDown() }
        try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        })
        #expect(harness.canvas.sceneRecordCountForTesting == 1)
        harness.canvas.pageLayoutPreference = { .continuous }
        let slot = try layout(harness).slotFrame(of: 1)
        let point = CGPoint(x: slot.midX, y: slot.minY + 40)
        harness.canvas.pageViewForTesting.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: point))
        #expect(harness.core.document.currentPageID == pageIDs(harness)[1])
        #expect(harness.canvas.sceneRecordCountForTesting == 0, "the first page's record is not the second page's")
        harness.canvas.pageViewForTesting.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: point))
        await settle(harness)
        #expect(harness.canvas.sceneRecordCountForTesting == 0)
    }

    /// Four sheets whose content sits on two PDF layers, Walls and Furniture.
    private func makeLayeredSheets(_ name: String, count: Int) throws -> URL {
        let content = "/OC /W BDC 2 w 0 0 0 RG 72 72 m 400 72 l S EMC\n/OC /F BDC 1 w 0 0 0 RG 72 300 m 400 300 l S EMC\n"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [3 0 R 4 0 R] /D << /Order [3 0 R 4 0 R] /ON [3 0 R 4 0 R] >> >> >>",
            "<< /Type /Pages /Kids [\((0..<count).map { "\(5 + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(count) >>",
            "<< /Type /OCG /Name (Walls) >>",
            "<< /Type /OCG /Name (Furniture) >>"
        ]
        var streams: [Int: String] = [:]
        for index in 0..<count {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents \(6 + 2 * index) 0 R /Resources << /Properties << /W 3 0 R /F 4 0 R >> >> >>")
            objects.append("")
            streams[6 + 2 * index] = content
        }
        return try AutomationFixtures.writePDF(named: name, objects: objects, streams: streams)
    }

    @Test("Under a measure lock, scrolling across sheets keeps every tile and refreshes the layers once, for the sheet it stops on")
    func measureLockScrollingKeepsTilesAndWaits() async throws {
        let url = try makeLayeredSheets("CS measure lock.pdf", count: 5)
        let harness = try await Fix2Harness.make("CS measure lock.pdf", calibrate: false, fixture: url, pageLayout: .continuous)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settle(harness)
        let ids = pageIDs(harness)
        let layers = harness.document.layerVisibility
        #expect(await AppTestSupport.wait { layers.items.count == 2 })
        let walls = try #require(layers.items.first { $0.name == "Walls" })
        layers.setMeasureLock(walls.id)
        await settle(harness)
        #expect(harness.canvas.isContinuousScrollActive, "a lock changes what snaps, never what is drawn")
        var dwellOpen = false
        harness.core.pageDwellWait = { _ in
            while !dwellOpen && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let generation = harness.canvas.tileGeneration
        let refreshes = harness.document.layerRefreshCountForTesting
        let extracted = harness.document.layerAwareExtractionPagesForTesting.count
        for index in 1...3 {
            try scroll(harness, toPage: index)
            #expect(harness.core.document.currentPageID == ids[index])
            await waitOutRateLimit()
        }
        #expect(harness.document.layerRefreshCountForTesting == refreshes, "no layer refresh for a sheet scrolled past")
        dwellOpen = true
        #expect(await AppTestSupport.wait { harness.document.layerRefreshCountForTesting == refreshes + 1 },
                "one refresh, for the sheet the view stops on")
        await settle(harness)
        let since = harness.document.layerAwareExtractionPagesForTesting.dropFirst(extracted)
        #expect(!since.contains(1) && !since.contains(2), "no extraction for a sheet scrolled past: \(Array(since))")
        #expect(since.contains(3), "the sheet the view stopped on was extracted")
        #expect(harness.canvas.tileGeneration == generation, "no tile was thrown away")
    }

    /// The last sheet an A4 below two A1 sheets: rested at the A1's fit zoom, a taller window
    /// makes AppKit pull the scroll origin back inside the document.
    @Test("A resize that pulls the scroll origin back is not a scroll: a sheet navigated to stays current")
    func clampingResizeKeepsTheHeldPage() async throws {
        let url = try AutomationFixtures.writePDF(
            named: "CS clamp.pdf",
            objects: [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2384 1684] /Contents 4 0 R >>", "",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2384 1684] /Contents 6 0 R >>", "",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 8 0 R >>", ""
            ],
            streams: [4: Self.linework, 6: Self.linework, 8: Self.linework]
        )
        let harness = try await Fix2Harness.make("CS clamp.pdf", calibrate: false, fixture: url, pageLayout: .continuous)
        defer { harness.tearDown() }
        try sizeCanvas(harness, to: CGSize(width: 1200, height: 700))
        harness.canvas.refresh()
        let ids = pageIDs(harness)
        harness.core.document.goToPage(id: ids[2])
        harness.canvas.refresh()
        #expect(harness.core.document.currentPageID == ids[2])
        try sizeCanvas(harness, to: CGSize(width: 1200, height: 1400))
        harness.canvas.refresh()
        #expect(harness.core.document.currentPageID == ids[2], "the resize did not let the larger sheet take over")
        let a4 = try layout(harness).slotFrame(of: 2).intersection(visible(harness))
        let a1 = try layout(harness).slotFrame(of: 1).intersection(visible(harness))
        #expect(a1.width * a1.height > a4.width * a4.height, "the larger sheet would win if the hold were released")
    }

    // MARK: - Select Text in the strip

    /// Five sheets: text on every one but the second, which is linework only.
    private func makeTextStrip(_ name: String) async throws -> (Fix2Harness, ScratchMarkupPasteboard) {
        let text = "BT /F1 24 Tf 72 700 Td (\(SelectTextFixture.firstLine)) Tj ET\nBT /F1 24 Tf 72 650 Td (\(SelectTextFixture.secondLine)) Tj ET\n"
        let lines = "2 w 0 0 0 RG 72 72 m 300 300 l S\n"
        let url = try AutomationFixtures.writePages(named: name, contents: [text, lines, text, text, text])
        let harness = try await Fix2Harness.make(name, calibrate: false, fixture: url, pageLayout: .continuous)
        let scratch = ScratchMarkupPasteboard()
        harness.controller.markupPasteboard = scratch
        harness.canvas.refresh()
        await settle(harness)
        harness.shell.perform(.selectTextTool)
        harness.canvas.applyArmedTool()
        await harness.canvas.settleTextSelection()
        return (harness, scratch)
    }

    /// Page `index`'s transform in the document view, from the strip as laid out.
    private func slotTransform(_ harness: Fix2Harness, _ index: Int) throws -> PageDisplayTransform {
        let strip = try layout(harness)
        let page = harness.core.document.pages[index]
        return PageDisplayTransform(pageBox: page.viewBox, rotation: page.displayRotation,
                                    zoom: strip.zoom, origin: strip.slotOrigin(of: index))
    }

    private func textDrag(_ harness: Fix2Harness, onPage index: Int, release: Bool = true) throws {
        let transform = try slotTransform(harness, index)
        let pageView = harness.canvas.pageViewForTesting
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: transform.viewPoint(from: SelectTextFixture.dragStart)))
        pageView.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: transform.viewPoint(from: SelectTextFixture.onSecondLine)))
        pageView.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: transform.viewPoint(from: SelectTextFixture.dragEnd)))
        if release {
            pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: transform.viewPoint(from: SelectTextFixture.dragEnd)))
        }
    }

    private static let copyItem = NSMenuItem(title: "Copy", action: #selector(PDFCanvasViewController.copy(_:)), keyEquivalent: "c")
    private static let selectAllItem = NSMenuItem(
        title: "Select All", action: #selector(PDFCanvasViewController.selectAll(_:)), keyEquivalent: "a"
    )

    @Test("Select Text: a press on another sheet adopts it first, then selects its words")
    func textPressAdoptsThenSelects() async throws {
        let (harness, _) = try await makeTextStrip("CS text press.pdf")
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        try textDrag(harness, onPage: 2)
        #expect(harness.core.document.currentPageID == ids[2], "adopted at the press")
        await harness.canvas.settleTextSelection()
        let selected = try #require(harness.canvas.textSelectionForTesting)
        #expect(selected.pageID == ids[2])
        #expect(selected.text.contains(SelectTextFixture.firstLine) && selected.text.contains(SelectTextFixture.secondLine))
        #expect(harness.canvas.pageViewForTesting.textSelectionHighlights == selected.lineRects)
    }

    @Test("Select Text: a text drag holds the page like any other drag")
    func textDragLocksThePage() async throws {
        let (harness, _) = try await makeTextStrip("CS text lock.pdf")
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        try textDrag(harness, onPage: 0, release: false)
        #expect(harness.canvas.pageViewForTesting.isTrackingPress)
        #expect(harness.canvas.isPageLocked)
        try scroll(harness, toPage: 3)
        #expect(harness.core.document.currentPageID == ids[0], "held while the text drag is under way")
        let end = try slotTransform(harness, 0).viewPoint(from: SelectTextFixture.dragEnd)
        harness.canvas.pageViewForTesting.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: end))
        await harness.canvas.settleTextSelection()
        #expect(!harness.canvas.isPageLocked)
        #expect(harness.canvas.textSelectionForTesting?.pageID == ids[0])
    }

    @Test("Select Text: scrolling keeps a selection while its sheet is on screen — drawn there, copied — and lets go once it is not")
    func textSelectionFollowsItsSheet() async throws {
        let (harness, scratch) = try await makeTextStrip("CS text scroll.pdf")
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        try textDrag(harness, onPage: 0)
        await harness.canvas.settleTextSelection()
        let selected = try #require(harness.canvas.textSelectionForTesting)
        #expect(selected.pageID == ids[0])

        // The view follows to the linework sheet; the first sheet is still on screen above it.
        try scroll(harness, toPage: 1)
        #expect(harness.core.document.currentPageID == ids[1])
        #expect(harness.canvas.textSelectionForTesting == selected, "a scroll does not wipe a selection still on screen")
        #expect(harness.canvas.pageViewForTesting.textSelectionHighlights.isEmpty, "not drawn on the wrong sheet")
        #expect(host(harness, page: ids[0])?.pageView.textSelectionHighlights == selected.lineRects, "drawn on its own sheet")
        // Copy copies it; Select All and the note are the current page's — which has no text.
        #expect(harness.canvas.validateMenuItem(Self.copyItem))
        harness.canvas.copy(nil)
        #expect(scratch.plainText == selected.text)
        await harness.canvas.settleTextSelection()
        #expect(harness.core.status.snapshot.activeToolNote == PDFCanvasViewController.noTextLayerNote)
        #expect(!harness.canvas.validateMenuItem(Self.selectAllItem), "the current sheet has nothing to select")

        // Further on, the first sheet leaves the screen and the selection goes with it.
        await waitOutRateLimit()
        try scroll(harness, toPage: 4)
        #expect(harness.core.document.currentPageID == ids[4])
        #expect(host(harness, page: ids[0]) == nil)
        #expect(harness.canvas.textSelectionForTesting == nil)
        #expect(!harness.canvas.validateMenuItem(Self.copyItem))
    }

    @Test("Select Text: Select All selects the current sheet's words")
    func textSelectAllUsesTheCurrentPage() async throws {
        let (harness, _) = try await makeTextStrip("CS text all.pdf")
        defer { harness.tearDown() }
        let ids = pageIDs(harness)
        try scroll(harness, toPage: 2)
        #expect(harness.core.document.currentPageID == ids[2])
        await harness.canvas.settleTextSelection()
        #expect(harness.canvas.validateMenuItem(Self.selectAllItem))
        harness.canvas.selectAll(nil)
        await harness.canvas.settleTextSelection()
        #expect(harness.canvas.textSelectionForTesting?.pageID == ids[2])
    }

    // MARK: - The setting

    @Test("View ▸ Continuous Scroll and Settings ▸ Canvas flip one app-wide preference, with a checkmark")
    func viewMenuToggleAndSettingsCheckbox() async throws {
        let saved = ZenitCanvasPreferences.current
        defer { ZenitCanvasPreferences.current = saved }
        ZenitCanvasPreferences.current = ZenitCanvasPreferences()
        #expect(ZenitCanvasPreferences.current.pageLayout == .continuous, "continuous by default")
        let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZenitAppCommand.continuousScroll.rawValue
        #expect(ZenitAppCommandTable.validateWithoutWindow(.continuousScroll, item: item), "available with no document")
        #expect(item.state == .on)
        ZenitAppCommandTable.perform(.continuousScroll, controller: nil, document: nil)
        #expect(ZenitCanvasPreferences.current.pageLayout == .singlePage)
        #expect(ZenitAppCommandTable.validateWithoutWindow(.continuousScroll, item: item))
        #expect(item.state == .off)

        let settings = ZenitSettingsWindowController()
        _ = settings.canvasSection()
        let box = settings.continuousScrollCheckbox
        #expect(box.state == .off, "the box shows the menu's choice")
        box.state = .on
        settings.continuousScrollToggled(box)
        #expect(ZenitCanvasPreferences.current.pageLayout == .continuous)
        ZenitAppCommandTable.perform(.continuousScroll, controller: nil, document: nil)
        #expect(box.state == .off, "the box follows the menu while Settings is open")
        // A stored blob from before the preference existed reads as continuous.
        let old = Data(#"{"smartZoomLevel":3,"wheelZooms":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ZenitCanvasPreferences.self, from: old)
        #expect(decoded.pageLayout == .continuous && decoded.wheelZooms)
    }

    @Test("An open canvas follows the preference as it changes")
    func canvasFollowsThePreference() async throws {
        let saved = ZenitCanvasPreferences.current
        defer { ZenitCanvasPreferences.current = saved }
        ZenitCanvasPreferences.current = ZenitCanvasPreferences()
        let harness = try await Fix2Harness.make("CS preference.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        #expect(harness.canvas.isContinuousScrollActive)
        ZenitCanvasPreferences.toggleContinuousScroll()
        #expect(!harness.canvas.isContinuousScrollActive)
        ZenitCanvasPreferences.toggleContinuousScroll()
        #expect(harness.canvas.isContinuousScrollActive)
    }
}
