import AppKit
import Foundation
import Observation
import os
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Gate **Z15** (U-005, iteration 4): the pointer-move path, replayed headless, frame by frame.
///
/// Z11 times the zoom door only, so everything a plain pointer move does — the loupe, the hover
/// scan over rotation knobs, vertex handles and markups, the link hover, the cursor readout and
/// the snap request, then the observation refresh they trigger and the overlay redraw — had no
/// number of its own. `Fix2CanvasPerformanceTests.pointerMovesAreLiveOnly` counts layouts and
/// scene fetches and `Iter2AppCanvasTests` S-005 counts exact hit tests; neither had a time.
///
/// ## What one replay is
///
/// The shipping window from ``Fix2Harness`` (never ordered on screen), 400 markups on the sheet,
/// snapping at the defaults a new project starts with, and 240 `.mouseMoved` events at 120 Hz
/// sent to the page view along a path that crosses markups, empty paper, the selected text box,
/// its handles and its rotation knob. Per frame:
///
/// - **input**: the page view's `mouseMoved(with:)` — the controller's whole pointer handler —
///   plus ``PDFCanvasViewController/refreshFromObservation()``, which is exactly what the
///   observation task runs for the change the move made;
/// - **draw**: the redraw the frame requires — the page view if it was invalidated and the live
///   overlay if it was, through `cacheDisplay`, the real `draw(_:)` AppKit runs before the next
///   frame; and, when the loupe is up, its lens's SwiftUI view-graph update and the layer commit
///   that carries its picture (`layoutSubtreeIfNeeded` + `CATransaction.flush()`);
/// - **landing**: the snap the move asked for lands on the main actor a few milliseconds later
///   (`AppCanvasPresenter.applySnap`), and the observation task runs the canvas's live lane
///   again and the overlay redraws. When it lands before the next frame is due, the replay
///   times that refresh (re-run: the observation task has already applied it, so this is the
///   same live lane without the invalidation) and the redraw it caused, and adds both to the
///   frame. A snap still in flight when the next move comes is cancelled by it, in the replay
///   as in the application, and costs the main thread nothing.
///
/// Two replays, each **budgeted on its own**: **Select** with one text box selected (knob,
/// vertex and hit-test scans), and **Length** with the loupe on (the lens follows every move).
/// Pooling them, as the first version of this gate did, put the pooled p50 in the gap between
/// two populations — it swung from 1.07 to 2.29 ms between release runs of one binary — and let
/// a loupe regression hide behind the Select frames.
///
/// | Gate | Budget (release) |
/// |---|---|
/// | Z15 Select, main thread per pointer frame, input + draw + landing | p50 ≤ 2.5 ms, p99 ≤ 4.5 ms |
/// | Z15 Length with the loupe, the same | p50 ≤ 3.0 ms, p99 ≤ 6.5 ms |
extension ViewerGestureReplayTests {

    static let pointerMoves = 240
    static let pointerMarkups = 400

    struct PointerReplay {
        var input: [Double] = []
        var draw: [Double] = []
        /// The part of `draw` that is the loupe's lens (view-graph update and layer commit).
        var lens: [Double] = []
        /// Per frame; 0 when no snap landed before the next frame was due.
        var landing: [Double] = []
        var frames: [Double] = []
        var landings = 0
        var layouts = 0
        var sceneFetches = 0
    }

    /// 300 lengths and 100 areas over the A4 fixture, landed as one batch.
    static func seedPointerMarkups(_ harness: Fix2Harness) async throws {
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        var commands: [DocumentCommand] = []
        for index in 0..<300 {
            let x = 40 + Double(index % 30) * 17, y = 480 + Double(index / 30) * 32
            commands.append(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id,
                kind: .measurement, tool: .length,
                geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: x, y: y), PDFPoint(x: x + 12, y: y + 6)]),
                createdAt: Date(), modifiedAt: Date()
            )))
        }
        for index in 0..<100 {
            let x = 40 + Double(index % 20) * 26, y = 60 + Double(index / 20) * 60
            commands.append(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id,
                kind: .measurement, tool: .area,
                geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: x, y: y), PDFPoint(x: x + 18, y: y),
                    PDFPoint(x: x + 18, y: y + 40), PDFPoint(x: x, y: y + 40)
                ], isClosed: true))]),
                createdAt: Date(), modifiedAt: Date()
            )))
        }
        try await harness.core.commands.performBatch(commands, actionName: "Seed")
        await harness.settle()
        #expect(await AppTestSupport.wait { harness.canvas.canvasShapes.count >= pointerMarkups })
    }

    /// The pointer path in page points: three sweeps across the sheet through the seeded areas,
    /// the text box at (200, 380)–(400, 420) with its corners, and its knob above it, then back
    /// over the lengths.
    static func pointerPath(knob: PDFPointValue) -> [PDFPointValue] {
        (0..<pointerMoves).map { index in
            let t = Double(index) / Double(pointerMoves - 1)
            switch index % 4 {
            case 0:
                // Along the text box's top edge, past its corners, and up to the knob.
                let u = (t * 7).truncatingRemainder(dividingBy: 1)
                return u < 0.8
                    ? PDFPointValue(x: 180 + u / 0.8 * 240, y: 420 + sin(u * 12) * 3)
                    : PDFPointValue(x: knob.x + (u - 0.9) * 40, y: knob.y + (u - 0.9) * 20)
            case 1:
                return PDFPointValue(x: 40 + t * 520, y: 80 + abs(sin(t * .pi * 9)) * 280)
            case 2:
                return PDFPointValue(x: 560 - t * 520, y: 480 + abs(sin(t * .pi * 7)) * 320)
            default:
                return PDFPointValue(x: 300 + cos(t * .pi * 6) * 250, y: 421 + sin(t * .pi * 6) * 380)
            }
        }
    }

    /// One pointer replay: `path.count` moves through the page view at 120 Hz, each frame timed.
    static func pointerReplay(_ harness: Fix2Harness, path: [PDFPointValue], label: String) async throws -> PointerReplay {
        let canvas = harness.canvas
        let pageView = canvas.pageViewForTesting
        let overlay = pageView.liveOverlay
        let transform = try #require(pageView.transform)
        let pageRep = try #require(pageView.bitmapImageRepForCachingDisplay(in: pageView.visibleRect))
        let overlayRep = try #require(overlay.bitmapImageRepForCachingDisplay(in: pageView.visibleRect))
        var replay = PointerReplay()
        let layouts = canvas.layoutCountForTesting
        let fetches = canvas.sceneFetchCountForTesting
        let clock = ContinuousClock()
        /// The redraw the frame requires: the page view if it was invalidated and the live
        /// overlay if it was, through `cacheDisplay` — the real `draw(_:)`.
        func drawFrame(since invalidations: Int, _ liveChanges: Int) -> Double {
            var draw = 0.0
            if pageView.pageInvalidationCount != invalidations {
                let drawStart = clock.now
                pageView.cacheDisplay(in: pageView.visibleRect, to: pageRep)
                draw += milliseconds(clock.now - drawStart)
                pageView.needsDisplay = false
            }
            if pageView.liveChangeCount != liveChanges {
                let drawStart = clock.now
                overlay.cacheDisplay(in: pageView.visibleRect, to: overlayRep)
                draw += milliseconds(clock.now - drawStart)
                overlay.needsDisplay = false
            }
            return draw
        }
        let start = clock.now
        for (index, point) in path.enumerated() {
            try? await Task.sleep(until: start + frameInterval * index, clock: .continuous)
            // The snap this move asks for: `applySnap` writes the feedback when it lands.
            let landed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = harness.core.canvas.snapFeedback
            } onChange: {
                landed.withLock { $0 = true }
            }
            let event = harness.mouseEvent(.mouseMoved, atLocal: transform.viewPoint(from: point))
            var invalidations = pageView.pageInvalidationCount
            var liveChanges = pageView.liveChangeCount
            let inputStart = clock.now
            pageView.mouseMoved(with: event)
            canvas.refreshFromObservation()
            let input = milliseconds(clock.now - inputStart)
            var draw = drawFrame(since: invalidations, liveChanges)
            if let lens = canvas.loupeHost {
                // The lens is SwiftUI chrome over a picture layer: its frame's main-thread work is
                // the view-graph update and the layer commit, not a software render.
                // `cacheDisplay` re-renders the whole hosting view every call — measured 6.05 ms
                // for an unchanged lens against 6.24 for a changed one (debug, 2026-09-27) — so it
                // would time a path the display never takes.
                let drawStart = clock.now
                lens.layoutSubtreeIfNeeded()
                CATransaction.flush()
                let commit = milliseconds(clock.now - drawStart)
                draw += commit
                replay.lens.append(commit)
            }
            // The landing, if it comes before the next frame is due.
            invalidations = pageView.pageInvalidationCount
            liveChanges = pageView.liveChangeCount
            let due = start + frameInterval * (index + 1)
            while !landed.withLock({ $0 }), clock.now < due {
                try? await Task.sleep(for: .microseconds(250))
            }
            var landing = 0.0
            if landed.withLock({ $0 }) {
                let landingStart = clock.now
                canvas.refreshFromObservation()
                landing = milliseconds(clock.now - landingStart) + drawFrame(since: invalidations, liveChanges)
                replay.landings += 1
            }
            replay.input.append(input)
            replay.draw.append(draw)
            replay.landing.append(landing)
            replay.frames.append(input + draw + landing)
        }
        replay.layouts = canvas.layoutCountForTesting - layouts
        replay.sceneFetches = canvas.sceneFetchCountForTesting - fetches
        let frames = ViewerLatency(samples: replay.frames)
        let input = ViewerLatency(samples: replay.input)
        let draw = ViewerLatency(samples: replay.draw)
        let landing = ViewerLatency(samples: replay.landing.filter { $0 > 0 })
        let lens = ViewerLatency(samples: replay.lens)
        print(String(
            format: "  %@  Z15 frames n=%d  p50 %7.3f  p99 %7.3f  max %7.3f  | input p50 %6.3f p99 %6.3f"
                + "  | draw p50 %6.3f p99 %6.3f (lens n=%d p50 %6.3f p99 %6.3f)  | landings %d p50 %6.3f p99 %6.3f"
                + "  | layouts %d scene fetches %d",
            label, replay.frames.count, frames.p50, frames.p99, frames.max,
            input.p50, input.p99, draw.p50, draw.p99, replay.lens.count, lens.p50, lens.p99,
            replay.landings, landing.p50, landing.p99, replay.layouts, replay.sceneFetches
        ))
        return replay
    }

    @Test("Z15: 240 pointer moves at 120 Hz over 400 markups, Select with a text box selected and Length with the loupe, each on its own budget")
    func z15_pointerReplay() async throws {
        print("--- Z15: pointer replay, A4 fixture, \(Self.pointerMarkups) markups, 120 Hz ---")
        print("  build: \(ViewerTimingBudget.configuration)")
        print("  \(Self.pointerReplayShape)")
        let harness = try await Fix2Harness.make("Z15 Pointer.pdf")
        defer { harness.tearDown() }
        #expect(harness.controller.window?.isVisible != true, "the replay window must never be on screen")
        // The harness turns snapping off. The replay runs with the snap a new project starts with
        // (`SnapSettings.default`), so every move's snap request lands, refreshes the canvas and
        // redraws the snap glyph — the landing the first version of this gate never saw.
        try await harness.core.session.setSnapSettings(.default)
        await harness.core.refresh()
        try await Self.seedPointerMarkups(harness)
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        let text = MarkupRecord(
            id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id, kind: .text,
            caption: "Pointer replay",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 200, y: 380), PDFPoint(x: 400, y: 420)]),
            createdAt: Date(), modifiedAt: Date()
        )
        _ = try await harness.core.commands.perform(.addMarkup(text))
        harness.core.canvas.zoomToFit()
        harness.canvas.refresh()
        await harness.settle()
        await Self.settleRaster(harness)

        // Select, the text box selected: every move scans its knob and handles, then hit-tests.
        harness.shell.perform(.selectTool)
        await harness.settle()
        harness.core.canvas.select(markupIDs: [text.id.rawValue], additive: false)
        harness.canvas.refresh()
        await harness.canvas.settleScene()
        let record = try #require(harness.canvas.sceneRecords.first { $0.id == text.id })
        let gap = harness.core.canvas.viewport.pageDistance(forViewPoints: Double(CanvasPageView.stampRotationHandleGapViewPoints))
        let knob = try #require(PDFCanvasViewController.rotationKnob(of: record, gap: gap))
        let path = Self.pointerPath(knob: knob)
        // The path reaches what it is meant to exercise: the knob, a handle, a markup.
        #expect(path.contains { $0.distance(to: knob) < 4 }, "the path never reaches the knob")
        let select = try await Self.pointerReplay(harness, path: path, label: "select, text selected")

        // Length with the loupe on: the lens follows every move. A private defaults suite,
        // empty on entry and on exit (`ScratchDefaults`, whose `with` takes no async body).
        let suite = ScratchDefaults.suiteName(for: "zenit.z15.loupe")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer {
            harness.canvas.loupeDefaults = .standard
            ScratchDefaults.discard(defaults, suiteName: suite)
        }
        harness.canvas.loupeDefaults = defaults
        CanvasLoupe.setEnabled(true, defaults)
        harness.shell.perform(.measureLength)
        await harness.settle()
        try? await Task.sleep(for: .milliseconds(100))
        harness.canvas.handlePointerMove(PDFPointValue(x: 300, y: 300))
        #expect(harness.canvas.loupeHost != nil, "the loupe is not up: the replay would not time it")
        let loupe = try await Self.pointerReplay(harness, path: path, label: "length, loupe on   ")
        harness.canvas.handlePointerMove(nil)

        let budgets = ViewerPointerBudgets.self
        for (replay, p50, p99) in [(select, budgets.z15SelectP50, budgets.z15SelectP99), (loupe, budgets.z15LoupeP50, budgets.z15LoupeP99)] {
            #expect(replay.frames.count == Self.pointerMoves, "the replay lost frames")
            // IM-040 on the timed path: a pointer move neither lays the page out nor refetches the scene.
            #expect(replay.layouts == 0, "\(replay.layouts) layouts for pointer moves")
            #expect(replay.sceneFetches == 0, "\(replay.sceneFetches) scene fetches for pointer moves")
            #expect(replay.landings > 0, "no snap landed within a frame: the landing was not timed")
            let frames = ViewerLatency(samples: replay.frames)
            #expect(p50.met(measured: frames.p50), p50.failure(measured: frames.p50))
            #expect(p99.met(measured: frames.p99), p99.failure(measured: frames.p99))
        }
    }

    /// The shape the budgets are written for; `Scripts/verify-viewer-budgets.sh` requires it.
    static let pointerReplayShape = "Z15 replay shape: 240 moves at 120 Hz over 400 markups, Select with a text box selected, then Length with the loupe"

    @Test("Every pointer budget matches Docs/Execution/quality-thresholds.json")
    func pointerBudgetsMatchTheThresholdFile() throws {
        let url = ViewerZoomGateTests.repositoryRoot
            .appendingPathComponent("Docs/Execution/quality-thresholds.json")
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let viewer = try #require(root["viewer"] as? [String: Any])
        #expect(ViewerPointerBudgets.all.count == 4, "the pointer budget table lost an entry")
        for budget in ViewerPointerBudgets.all {
            #expect(budget.debug >= budget.release, "\(budget.name): debug tighter than release")
            let gate = try #require(viewer[budget.thresholdGate] as? [String: Any], "no viewer.\(budget.thresholdGate)")
            #expect(gate[budget.thresholdReleaseKey] as? Double == budget.release,
                    "\(budget.name): release \(budget.release) disagrees with the threshold file")
            #expect(gate[budget.thresholdDebugKey] as? Double == budget.debug,
                    "\(budget.name): debug \(budget.debug) disagrees with the threshold file")
        }
    }
}

/// Gate Z15, four budgets — p50 and p99 of each replay — each with a release and a debug value,
/// all mirrored in `Docs/Execution/quality-thresholds.json`, where
/// `viewer.Z15.derivation` and `debugDerivation` give the runs they came from.
///
/// Release: 1.5 × the worst of eight settled release runs, rounded up to 0.5 ms — measured,
/// not borrowed from Z11's frame argument. Debug: twice the worst of three quiet debug runs,
/// rounded up, never tighter than release.
enum ViewerPointerBudgets {

    static let z15SelectP50 = ViewerTimingBudget(
        name: "z15_select_frame_p50", release: 2.5, debug: 4.0,
        thresholdGate: "Z15", thresholdReleaseKey: "selectP50Milliseconds", thresholdDebugKey: "debugSelectP50Milliseconds"
    )
    static let z15SelectP99 = ViewerTimingBudget(
        name: "z15_select_frame_p99", release: 4.5, debug: 7.0,
        thresholdGate: "Z15", thresholdReleaseKey: "selectP99Milliseconds", thresholdDebugKey: "debugSelectP99Milliseconds"
    )
    static let z15LoupeP50 = ViewerTimingBudget(
        name: "z15_loupe_frame_p50", release: 3.0, debug: 6.0,
        thresholdGate: "Z15", thresholdReleaseKey: "loupeP50Milliseconds", thresholdDebugKey: "debugLoupeP50Milliseconds"
    )
    static let z15LoupeP99 = ViewerTimingBudget(
        name: "z15_loupe_frame_p99", release: 6.5, debug: 9.0,
        thresholdGate: "Z15", thresholdReleaseKey: "loupeP99Milliseconds", thresholdDebugKey: "debugLoupeP99Milliseconds"
    )

    static let all: [ViewerTimingBudget] = [z15SelectP50, z15SelectP99, z15LoupeP50, z15LoupeP99]
}
