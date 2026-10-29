import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Improvements 2, canvas and first-run: accessibility, render notices, pill caches, arrow
/// keys, gesture hints, coalesced visible-rect reporting and the deferred author question.
@MainActor
@Suite(.appTierSerialised)
struct Fix2CanvasImprovementTests {

    private func square(_ page: PageID) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100),
            PDFPoint(x: 300, y: 300), PDFPoint(x: 100, y: 300)
        ]))])
    }

    private func settleRaster(_ harness: Fix2Harness) async {
        for _ in 0..<5 {
            await harness.canvas.settleRasterForTesting()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func firstX(_ harness: Fix2Harness, notEqual old: Double = 100) async -> Double? {
        for _ in 0..<40 {
            await harness.core.commands.settle()
            if let x = await harness.records().first?.geometry?.points.first?.x, x != old { return x }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await harness.records().first?.geometry?.points.first?.x
    }

    // MARK: - IM-160

    @Test("IM-160: the author question is a sheet-ready alert with honest buttons, not a launch blocker")
    func authorQuestionIsDeferred() throws {
        try ScratchDefaults.with(prefix: "zenit-fix2-im160") { scratch, _ in
            let previous = AuthorIdentity.defaults
            AuthorIdentity.defaults = scratch
            AuthorNamePrompt.presentsWithoutABundleForTesting = true
            var asked: ZenitModalRequest?
            ZenitModalPresenter.handler = { request in
                if request.identifier == AuthorNamePrompt.modalIdentifier { asked = request }
                return .button(0)
            }
            defer {
                ZenitModalPresenter.handler = nil
                AuthorNamePrompt.presentsWithoutABundleForTesting = false
                AuthorIdentity.defaults = previous
            }
            #expect(AuthorIdentity.needsFirstRunPrompt)
            AuthorNamePrompt.presentIfNeeded(on: nil)
            // R-044: "Not Now" promised a later asking the prompt never makes (it is asked once).
            #expect(asked?.buttons == ["Use This Name", "Skip"], "old: Keep / Skip, then Use This Name / Not Now")
            #expect(!AuthorIdentity.needsFirstRunPrompt, "answered once, never asked again")
        }
        // Old: `AuthorNamePrompt.presentIfNeeded()` inside applicationDidFinishLaunching.
        let delegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ZenitPDFAppKit/App/ZenitApplicationDelegate.swift"),
            encoding: .utf8
        )
        #expect(!delegate.contains("AuthorNamePrompt.presentIfNeeded("))
    }

    // MARK: - IM-162

    @Test("IM-162: the canvas is a labelled drawing with one element per visible markup, and a commit is announced")
    func canvasIsAccessible() async throws {
        let harness = try await Fix2Harness.make("IM162.pdf")
        defer { harness.tearDown() }
        let pageView = harness.canvas.pageViewForTesting
        // Old: no role, no label, no children.
        #expect(pageView.accessibilityRole() == .layoutArea)
        #expect(pageView.accessibilityLabel() == "Drawing, page 1")
        _ = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100)])
        }
        _ = try await harness.addMarkup(tool: .area, geometry: square)
        #expect(await AppTestSupport.wait { pageView.shapes.count == 2 })
        let elements = pageView.markupAccessibilityElements()
        #expect(elements.count == 2)
        #expect(elements.allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty == false })
        #expect(elements.allSatisfy { $0.accessibilityFrameInParentSpace().width > 0 })
        #expect(pageView.accessibilityAnnouncements.contains { $0.hasPrefix("Added ") },
                "a committed markup must be said, not only drawn")
    }

    // MARK: - IM-164

    @Test("IM-164: a refused render says so on the sheet; a delivered one says nothing")
    func renderRefusalIsShown() async throws {
        let harness = try await Fix2Harness.make("IM164.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.canvas.refresh()
        await settleRaster(harness)
        let pageView = harness.canvas.pageViewForTesting
        #expect(await AppTestSupport.wait { !pageView.tileRasters.isEmpty })
        #expect(pageView.renderNotice == nil)
        let source = try #require(harness.document.drawing?.rasterSource)
        await source.close()
        harness.canvas.invalidateRasterTiles()
        harness.canvas.refresh()
        await settleRaster(harness)
        // Old: the refusal only reached the log; the sheet showed stale or blank paper.
        #expect(await AppTestSupport.wait { pageView.renderNotice == .refused })
        #expect(CanvasPageView.RenderNotice.refused.text == "This area could not be rendered at this zoom")
    }

    // MARK: - IM-165

    @Test("IM-165: redrawing an unchanged page builds no caption layout and places no area pill again")
    func pillLayoutIsCached() async throws {
        let harness = try await Fix2Harness.make("IM165.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .area, geometry: square)
        let pageView = harness.canvas.pageViewForTesting
        #expect(await AppTestSupport.wait { pageView.shapes.contains { $0.caption != nil } })
        pageView.backingScaleOverride = 1
        let rect = pageView.bounds.integral
        let first = try #require(pageView.bitmapImageRepForCachingDisplay(in: rect))
        pageView.cacheDisplay(in: rect, to: first)
        let layouts = pageView.pillLayoutComputeCount
        let placements = pageView.areaPillPlacementComputeCount
        #expect(placements >= 1)
        for _ in 0..<3 {
            let again = try #require(pageView.bitmapImageRepForCachingDisplay(in: rect))
            pageView.cacheDisplay(in: rect, to: again)
        }
        // Old: a new attributed string, size() and five point-in-polygon tests per frame.
        #expect(pageView.pillLayoutComputeCount == layouts)
        #expect(pageView.areaPillPlacementComputeCount == placements)
        // A zoom moves the pill in view space: the placement is computed again.
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 1.5)
        harness.canvas.refresh()
        let zoomedRect = pageView.bounds.integral
        let zoomed = try #require(pageView.bitmapImageRepForCachingDisplay(in: zoomedRect))
        pageView.cacheDisplay(in: zoomedRect, to: zoomed)
        #expect(pageView.areaPillPlacementComputeCount == placements + 1)
    }

    // MARK: - IM-166

    @Test("IM-166: an arrow nudges the selection 1 pt (Shift 10 pt) as one ⌘Z; a held arrow is one move")
    func arrowsNudgeTheSelection() async throws {
        let harness = try await Fix2Harness.make("IM166.pdf")
        defer { harness.tearDown() }
        let record = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100)])
        }
        harness.core.canvas.select(markupIDs: [record.id.rawValue], additive: false)
        // Old: arrows fell through to super.keyDown and did nothing.
        #expect(harness.canvas.handle(key: .nudge(dx: 1, dy: 0, large: false, isRepeat: false)))
        await harness.settle()
        let afterOne = await firstX(harness)
        #expect(afterOne.map { abs($0 - 101) < 1e-6 } ?? false, "x = \(String(describing: afterOne))")
        // A held Shift-arrow: one press and four repeats gather into two moves, not five.
        let before = harness.canvas.nudgeCommitCountForTesting
        _ = harness.canvas.handle(key: .nudge(dx: 1, dy: 0, large: true, isRepeat: false))
        for _ in 0..<4 { _ = harness.canvas.handle(key: .nudge(dx: 1, dy: 0, large: true, isRepeat: true)) }
        harness.canvas.flushNudge()
        await harness.settle()
        #expect(harness.canvas.nudgeCommitCountForTesting - before == 2)
        let afterHold = await firstX(harness, notEqual: 101)
        #expect(afterHold.map { abs($0 - 151) < 1e-6 } ?? false, "x = \(String(describing: afterHold))")
        // Screen up is page +y on an unrotated sheet.
        let transform = try #require(harness.canvas.pageViewForTesting.transform)
        let up = PDFCanvasViewController.nudgePageDelta(dx: 0, dy: -1, points: 1, transform: transform)
        #expect(abs(up.x) < 1e-9 && abs(up.y - 1) < 1e-9)
    }

    // MARK: - IM-168

    @Test("IM-168: the armed tool's modifiers and finish gestures reach the status bar")
    func gestureHintIsShown() async throws {
        let area = ZenitToolMode.measure(.area)
        let hint = try #require(PDFCanvasViewController.gestureHint(gesture: area.gesture, placedCount: 2))
        #expect(hint.contains("⇧ straight") && hint.contains("⌥-click rectangle") && hint.contains("Return"))
        let count = ZenitToolMode.measure(.count)
        let countHint = try #require(PDFCanvasViewController.gestureHint(gesture: count.gesture, placedCount: 3))
        #expect(countHint.contains("⌥-click removes a mark") && countHint.contains("Escape"))
        #expect(PDFCanvasViewController.gestureHint(gesture: ZenitToolMode.select.gesture, placedCount: 0) == nil)

        let harness = try await Fix2Harness.make("IM168.pdf")
        defer { harness.tearDown() }
        harness.core.measurement.activate(kind: .length)
        harness.canvas.refresh()
        // Old: the status bar showed the tool's short help and never a modifier.
        #expect(await AppTestSupport.wait {
            harness.core.status.snapshot.activeToolNote?.contains("⇧ straight") == true
        })
        harness.core.status.setActiveToolNote("Something else")
        harness.core.measurement.placePoint(PDFPointValue(x: 10, y: 10))
        harness.canvas.refresh()
        #expect(harness.core.status.snapshot.activeToolNote == "Something else",
                "a hint never overwrites another note")
        harness.core.measurement.deactivate()
    }

    // MARK: - IM-169

    @Test("IM-169: a burst of scroll notifications reports the visible rect once per run-loop turn")
    func visibleRectReportIsCoalesced() async throws {
        let harness = try await Fix2Harness.make("IM169.pdf")
        defer { harness.tearDown() }
        harness.core.canvas.setZoom(4)
        harness.canvas.refresh()
        await harness.settle()
        let clip = harness.canvas.scrollViewForTesting.contentView
        try? await Task.sleep(for: .milliseconds(50))
        let before = harness.canvas.visibleRectReportCountForTesting
        for step in 1...20 {
            clip.scroll(to: CGPoint(x: 0, y: CGFloat(step) * 3))
        }
        #expect(harness.canvas.visibleRectReportCountForTesting == before, "reported inside the burst")
        try? await Task.sleep(for: .milliseconds(50))
        // Old: twenty reports, each with a full status refresh and a raster plan.
        #expect(harness.canvas.visibleRectReportCountForTesting - before == 1)
    }
}
