import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The viewer gates **Z11–Z14** (NL-PERF-01): a real pinch, replayed headless on the heavy A1
/// roof plan the viewer budgets are measured on (``ViewerZoomGateTests/roofPlan()``), frame by
/// frame.
///
/// ## Why this suite exists
///
/// Z1–Z10 all measure the *settled* frame — a 1:1 blit of a raster made for the current zoom.
/// A zoom gesture never shows a settled frame. Every frame of a pinch went down a different path
/// (relayout, full redraw, CPU resample of yesterday's tiles, and from the second event on no
/// tiles at all), and the gates could not see any of it while a person using the app felt all
/// of it.
///
/// ## What one replay is
///
/// A real `ProjectWindowController` from ``Fix2Harness``, whose window is **never ordered on
/// screen** (a user's screen is not a test rig), sized so the canvas is the
/// benchmark's 1600 × 1000 pt viewport. The A1 is opened from a private copy in the
/// temporary directory. Then a 72-step pinch, geometric from fit to 800 % and back, is sent
/// through ``ZenitCanvasScrollView/handleZoomGesture(factor:windowPoint:phase:)`` — the door a
/// trackpad's `magnify(with:)` and a `⌘`-scroll go through — paced at 120 Hz in real time, so
/// renders and landings interleave with the input as they do on a real display. Per frame:
///
/// - **input**: the wall time of the gesture step plus the display-link tick;
/// - **draw**: if the frame invalidated the page view, the wall time of
///   `cacheDisplay(in: visibleRect)`, which runs the real `draw(_:)` — exactly the main-thread
///   drawing AppKit would do before the next frame;
/// - **coverage**: the fraction of the visible sheet some raster covers on that frame.
///
/// After the gesture ends the suite times the way to a fully sharp viewport, and every render
/// that lands on the main actor is timed by the controller itself.
///
/// | Gate | Budget (release) |
/// |---|---|
/// | Z11 main thread per gesture frame, input + draw | p50 ≤ 2.0 ms, **p99 ≤ 4.0 ms** |
/// | Z12 blank-paper frames (coverage < 99.9 %) | **0** of every replay |
/// | Z13 gesture end → sharp, debounce included | **p50 ≤ 100 ms**, p95 ≤ 200 ms |
/// | Z14 main thread when a render lands (+ the redraw it causes) | **p99 ≤ 2.0 ms** |
///
/// GPU composition itself cannot be measured headless; what this gate owns is every millisecond
/// the main thread spends, and every frame on which there was nothing to composite.
@MainActor
@Suite(.appTierSerialised)
struct ViewerGestureReplayTests {

    // MARK: - The replay

    /// The benchmark's viewport (`ViewerZoomGateTests.viewport`).
    static let viewport = CGSize(width: 1600, height: 1000)
    static let steps = 72
    static let peakZoom = 8.0
    static let frameInterval: Duration = .nanoseconds(8_333_333)
    /// Short gestures after the long one, so Z13 has a distribution rather than one number.
    static let shortGestures = 6
    static let shortGestureSteps = 12

    /// Which frame a sample is (R-005): the replay, the gesture within it, the step within the
    /// gesture and its phase, and the frame's two parts — so the slowest frames can be named
    /// instead of guessed at.
    struct FrameTag: Sendable {
        var replay: String
        var gesture: Int
        var step: Int
        var phase: String
        var input: Double
        var draw: Double
        var total: Double { input + draw }
        /// Whether the frame's gesture step crossed into another pyramid level (the level tiles
        /// shown changed), which queues renders and restacks the level layers.
        var levelChanged: Bool
        /// Whether the frame invalidated the page view, so `draw` ran.
        var redrew: Bool
    }

    struct Replay {
        var input: [Double] = []
        var draw: [Double] = []
        var frames: [Double] = []
        var tags: [FrameTag] = []
        var coverage: [Double] = []
        var settle: [Double] = []
        var landings: [Double] = []
        /// The frame on which the fingers lift: one layout and the page's redraw at the new zoom.
        /// Reported beside Z11 rather than inside it — it is one frame per gesture, not a
        /// gesture frame — so its cost is visible instead of averaged away.
        var endFrames: [Double] = []
        var layoutsDuringGestures = 0
        var layoutsAtEnds = 0

        var blankFrames: Int { coverage.filter { $0 < 0.999 }.count }

        mutating func absorb(_ other: Replay) {
            input += other.input
            draw += other.draw
            frames += other.frames
            tags += other.tags
            coverage += other.coverage
            settle += other.settle
            landings += other.landings
            endFrames += other.endFrames
            layoutsDuringGestures += other.layoutsDuringGestures
            layoutsAtEnds += other.layoutsAtEnds
        }
    }

    /// A scratch copy of the A1 roof plan in a fresh temporary directory, optionally doubled
    /// into a two-page document so page 2 is replayed too (the underlay once existed for page 0
    /// only). ``Fix2Harness/tearDown()`` deletes the fixture's directory, so
    /// the original must never be handed to it.
    static func scratchRoofPlan(pages: Int) throws -> URL {
        let original = try ViewerZoomGateTests.roofPlan()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-gesture-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Roof plan.pdf")
        if pages <= 1 {
            try FileManager.default.copyItem(at: original, to: url)
            return url
        }
        let document = try #require(PDFDocument(url: original))
        let page = try #require(document.page(at: 0))
        for index in 1..<pages {
            let copy = try #require(page.copy() as? PDFPage)
            document.insert(copy, at: index)
        }
        #expect(document.write(to: url))
        return url
    }

    /// Opens the A1 roof plan in a never-shown window whose canvas is the benchmark viewport.
    static func openRoofPlan(pages: Int = 1) async throws -> Fix2Harness {
        let url = try scratchRoofPlan(pages: pages)
        let harness = try await Fix2Harness.make("unused", pageCount: pages, calibrate: true, fixture: url)
        let window = try #require(harness.controller.window)
        #expect(!window.isVisible, "the replay window must never be on screen")
        let scrollView = harness.canvas.scrollViewForTesting
        for _ in 0..<3 {
            let size = scrollView.contentSize
            let dw = viewport.width - size.width
            let dh = viewport.height - size.height
            guard abs(dw) > 0.5 || abs(dh) > 0.5 else { break }
            let content = window.contentRect(forFrameRect: window.frame).size
            window.setContentSize(NSSize(width: content.width + dw, height: content.height + dh))
            window.layoutIfNeeded()
            harness.canvas.view.layoutSubtreeIfNeeded()
        }
        #expect(!window.isVisible, "resizing must not order the window in")
        harness.core.canvas.viewSize = scrollView.contentSize
        harness.core.canvas.zoomToFit()
        harness.canvas.refresh()
        await harness.settle()
        await settleRaster(harness)
        return harness
    }

    /// `count` captioned areas in a grid over the sheet, landed as one batch.
    static func seedAreas(_ harness: Fix2Harness, count: Int, pageIndex: Int = 0) async throws {
        guard count > 0 else { return }
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[pageIndex]
        let columns = 25
        var commands: [DocumentCommand] = []
        for index in 0..<count {
            let column = index % columns
            let row = index / columns
            let x = 60 + Double(column) * 90
            let y = 60 + Double(row % 20) * 78 + Double(row / 20) * 7
            commands.append(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()),
                documentID: drawing.documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .area,
                subject: "",
                geometry: MeasurementGeometry(pageID: page.id, points: [
                    PDFPoint(x: x, y: y), PDFPoint(x: x + 60, y: y),
                    PDFPoint(x: x + 60, y: y + 50), PDFPoint(x: x, y: y + 50)
                ]),
                createdAt: Date(),
                modifiedAt: Date()
            )))
        }
        try await harness.core.commands.performBatch(commands, actionName: "Seed")
        await harness.settle()
        #expect(await AppTestSupport.wait { harness.canvas.canvasShapes.count >= count })
    }

    static func settleRaster(_ harness: Fix2Harness) async {
        for _ in 0..<4 {
            await harness.canvas.settleRasterForTesting()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// One gesture: `factors.count` steps through the scroll view's gesture door at 120 Hz,
    /// each frame measured, then the time to a sharp viewport.
    static func gesture(
        _ harness: Fix2Harness,
        factors: [Double],
        anchor: NSPoint,
        drawRep: NSBitmapImageRep,
        label: String = "",
        gestureIndex: Int = 0
    ) async -> Replay {
        var replay = Replay()
        let canvas = harness.canvas
        let scrollView = canvas.scrollViewForTesting
        let pageView = canvas.pageViewForTesting
        let clock = ContinuousClock()
        let start = clock.now
        let layoutsBefore = canvas.layoutCountForTesting
        for (index, factor) in factors.enumerated() {
            try? await Task.sleep(until: start + frameInterval * index, clock: .continuous)
            let phase: ZenitCanvasScrollView.ZoomGesturePhase = index == 0 ? .began : .changed
            let invalidations = pageView.pageInvalidationCount
            let levelTilesBefore = pageView.levelTileRasters
            let inputStart = clock.now
            scrollView.handleZoomGesture(factor: factor, windowPoint: anchor, phase: phase)
            canvas.displayFrameForTesting()
            let input = milliseconds(clock.now - inputStart)
            let levelChanged = pageView.levelTileRasters != levelTilesBefore
            let redrew = pageView.pageInvalidationCount != invalidations
            var draw = 0.0
            // The page view's own invalidation counter rather than `needsDisplay`: a view in a
            // window that was never ordered in does not report `needsDisplay` reliably, and a
            // frame that invalidated the page is a frame AppKit redraws before it is shown.
            if pageView.pageInvalidationCount != invalidations {
                let drawStart = clock.now
                pageView.cacheDisplay(in: pageView.visibleRect, to: drawRep)
                draw = milliseconds(clock.now - drawStart)
                pageView.needsDisplay = false
                pageView.liveOverlay.needsDisplay = false
            }
            replay.input.append(input)
            replay.draw.append(draw)
            replay.frames.append(input + draw)
            replay.tags.append(FrameTag(
                replay: label, gesture: gestureIndex, step: index,
                phase: index == 0 ? "began" : "changed",
                input: input, draw: draw, levelChanged: levelChanged, redrew: redrew
            ))
            replay.coverage.append(canvas.visiblePageCoverageForTesting())
        }
        replay.layoutsDuringGestures = canvas.layoutCountForTesting - layoutsBefore
        try? await Task.sleep(until: start + frameInterval * factors.count, clock: .continuous)
        // A main thread stalled past the idle timeout (a busy machine) ends the gesture by
        // itself during this wait; that is the product working, and it still lays out once.
        let layoutsAfterSteps = layoutsBefore + replay.layoutsDuringGestures

        // The fingers lift.
        let invalidationsBeforeEnd = pageView.pageInvalidationCount
        let ended = clock.now
        scrollView.handleZoomGesture(factor: 1, windowPoint: anchor, phase: .ended)
        canvas.displayFrameForTesting()
        var endFrame = milliseconds(clock.now - ended)
        replay.layoutsAtEnds = canvas.layoutCountForTesting - layoutsAfterSteps
        if pageView.pageInvalidationCount != invalidationsBeforeEnd {
            let drawStart = clock.now
            pageView.cacheDisplay(in: pageView.visibleRect, to: drawRep)
            endFrame += milliseconds(clock.now - drawStart)
            pageView.needsDisplay = false
            pageView.liveOverlay.needsDisplay = false
        }
        replay.endFrames.append(endFrame)
        let deadline = ended + .seconds(3)
        while !canvas.viewportIsSharpForTesting, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        replay.settle.append(milliseconds(clock.now - ended))
        await settleRaster(harness)
        return replay
    }

    /// The whole programme for one page at one markup load: the long pinch, then the short
    /// gestures, then the landings the controller recorded meanwhile.
    static func replayPage(_ harness: Fix2Harness, label: String) async throws -> Replay {
        let canvas = harness.canvas
        let scrollView = canvas.scrollViewForTesting
        let pageView = canvas.pageViewForTesting
        let drawRep = try #require(pageView.bitmapImageRepForCachingDisplay(in: pageView.visibleRect))
        // A little off centre, so the anchoring is exercised rather than trivially symmetric.
        let local = NSPoint(x: scrollView.contentSize.width * 0.45, y: scrollView.contentSize.height * 0.55)
        let anchor = scrollView.convert(local, to: nil)
        canvas.recordsRenderLandingsForTesting = true
        let landingsBefore = canvas.renderLandingSamplesForTesting.count

        let fit = harness.core.canvas.viewport.zoom
        let half = steps / 2
        let inFactor = pow(peakZoom / fit, 1.0 / Double(half))
        let factors = Array(repeating: inFactor, count: half) + Array(repeating: 1 / inFactor, count: half)
        var replay = await gesture(harness, factors: factors, anchor: anchor, drawRep: drawRep, label: label, gestureIndex: 0)

        for index in 0..<shortGestures {
            let factor = index.isMultiple(of: 2) ? 1.06 : 1 / 1.06
            let short = await gesture(
                harness,
                factors: Array(repeating: factor, count: shortGestureSteps),
                anchor: anchor,
                drawRep: drawRep,
                label: label,
                gestureIndex: index + 1
            )
            replay.absorb(short)
            try? await Task.sleep(for: .milliseconds(60))
        }

        // The redraw a landing causes when it invalidates the page view, measured warm.
        pageView.needsDisplay = true
        let clock = ContinuousClock()
        let redrawStart = clock.now
        pageView.cacheDisplay(in: pageView.visibleRect, to: drawRep)
        let redraw = milliseconds(clock.now - redrawStart)
        pageView.needsDisplay = false
        for sample in canvas.renderLandingSamplesForTesting.dropFirst(landingsBefore) {
            replay.landings.append(sample.milliseconds + (sample.invalidatedPage ? redraw : 0))
        }

        let frames = ViewerLatency(samples: replay.frames)
        let input = ViewerLatency(samples: replay.input)
        let draw = ViewerLatency(samples: replay.draw)
        let settle = ViewerLatency(samples: replay.settle)
        let landing = ViewerLatency(samples: replay.landings)
        let endFrame = ViewerLatency(samples: replay.endFrames)
        print(String(
            format: "  %@  Z11 frames n=%d  p50 %7.3f  p99 %7.3f  max %7.3f  | input p50 %6.3f p99 %6.3f"
                + "  | draw p50 %6.3f p99 %6.3f",
            label, replay.frames.count, frames.p50, frames.p99, frames.max,
            input.p50, input.p99, draw.p50, draw.p99
        ))
        print(String(
            format: "  %@  Z12 blank frames %d of %d  min coverage %.4f",
            label, replay.blankFrames, replay.coverage.count, replay.coverage.min() ?? 0
        ))
        print(String(
            format: "  %@  Z13 settle n=%d  p50 %7.3f  p95 %7.3f  max %7.3f  | samples %@",
            label, replay.settle.count, settle.p50, settle.p95, settle.max,
            replay.settle.map { String(format: "%.1f", $0) }.joined(separator: " ")
        ))
        print(String(
            format: "  %@  Z14 landings n=%d  p50 %7.3f  p99 %7.3f  max %7.3f  (redraw %.3f)",
            label, replay.landings.count, landing.p50, landing.p99, landing.max, redraw
        ))
        print(String(
            format: "  %@  end frames n=%d  p50 %7.3f  max %7.3f  (one layout + the page redraw at the new zoom)",
            label, replay.endFrames.count, endFrame.p50, endFrame.max
        ))
        print("  \(label)  layouts during gestures \(replay.layoutsDuringGestures), at gesture ends \(replay.layoutsAtEnds)")
        printSlowestFrames(replay.tags, label: label, count: 5)
        return replay
    }

    /// The slowest frames with what they were (R-005): which gesture, which step and phase, the
    /// input and draw parts, and whether the step changed pyramid level or redrew the page. The
    /// pooled p99 of 432 frames is the 5th slowest (`ViewerLatency` takes index
    /// round((n − 1) · 0.99)), and a replay's p99 of 144 frames its 2nd slowest, so these lines
    /// are exactly the frames that set the gate.
    static func printSlowestFrames(_ tags: [FrameTag], label: String, count: Int) {
        for tag in tags.sorted(by: { $0.total > $1.total }).prefix(count) {
            print(String(
                format: "  %@  slow frame %6.3f ms  gesture %d step %2d %-7@ input %6.3f draw %6.3f%@%@",
                label.isEmpty ? tag.replay : label, tag.total, tag.gesture, tag.step, tag.phase,
                tag.input, tag.draw, tag.levelChanged ? "  level-changed" : "", tag.redrew ? "  redrew" : ""
            ))
        }
    }

    // MARK: - The gate

    @Test("Z11–Z14: a 72-step pinch on the A1 roof plan, pages 1 and 2, bare and with 500 captioned areas")
    func z11to14_gestureReplay() async throws {
        print("--- Z11-Z14: gesture replay, A1 roof plan, 1600x1000 pt canvas, 120 Hz ---")
        print("  build: \(ViewerTimingBudget.configuration)")
        print("  replay shape: \(Self.steps) steps fit to 800 % and back, then \(Self.shortGestures)"
              + " gestures of \(Self.shortGestureSteps)")
        var all = Replay()

        // Page 1 and page 2 of a two-page copy, bare.
        do {
            let harness = try await Self.openRoofPlan(pages: 2)
            defer { harness.tearDown() }
            let pageView = harness.canvas.pageViewForTesting
            print("  canvas \(harness.canvas.scrollViewForTesting.contentSize)"
                  + " backing \(pageView.effectiveBackingScale)")
            all.absorb(try await Self.replayPage(harness, label: "page 1, 0 markups  "))
            harness.core.document.goToNextPage()
            harness.canvas.refresh()
            harness.core.canvas.zoomToFit()
            harness.canvas.refresh()
            await harness.settle()
            await Self.settleRaster(harness)
            #expect(harness.core.canvas.viewport.pageIndex == 1)
            all.absorb(try await Self.replayPage(harness, label: "page 2, 0 markups  "))
        }
        // Page 1 with 500 captioned areas, so markup drawing is inside the number.
        do {
            let harness = try await Self.openRoofPlan(pages: 1)
            defer { harness.tearDown() }
            try await Self.seedAreas(harness, count: 500)
            harness.core.canvas.zoomToFit()
            harness.canvas.refresh()
            await Self.settleRaster(harness)
            all.absorb(try await Self.replayPage(harness, label: "page 1, 500 areas  "))
        }

        let frames = ViewerLatency(samples: all.frames)
        let settle = ViewerLatency(samples: all.settle)
        let landing = ViewerLatency(samples: all.landings)
        print(String(
            format: "  all  Z11 n=%d p50 %.3f p99 %.3f | Z12 %d blank | Z13 n=%d p50 %.3f p95 %.3f | Z14 n=%d p99 %.3f",
            all.frames.count, frames.p50, frames.p99, all.blankFrames,
            all.settle.count, settle.p50, settle.p95, all.landings.count, landing.p99
        ))
        // R-005: each replay's own p99 beside the pooled figure. Asserted pooled only — a per-replay
        // assertion is a change of the gate's definition and a deliberate decision — but printed, so a
        // replay over budget inside a pooled pass is visible (round 1 had page 1 at 4.043).
        let replays = Dictionary(grouping: all.tags, by: \.replay)
        for name in replays.keys.sorted() {
            let own = ViewerLatency(samples: replays[name, default: []].map(\.total))
            print(String(format: "  %@  Z11 replay p99 %.3f  (pooled %.3f)", name, own.p99, frames.p99))
        }
        Self.printSlowestFrames(all.tags, label: "", count: 10)
        #expect(all.frames.count == 3 * (Self.steps + Self.shortGestures * Self.shortGestureSteps),
                "the replay lost frames")
        #expect(!all.landings.isEmpty, "no render landed: Z14 measured nothing")
        // NL-PERF-04: no layout per event; exactly one per gesture, when it ends.
        #expect(all.layoutsDuringGestures == 0, "\(all.layoutsDuringGestures) layouts during gestures")
        // At most one per gesture end — none for a pinch that came back to the zoom it began at
        // (the long one does: fit, 800 %, fit), which only needs the scroll it moved.
        #expect(all.layoutsAtEnds <= all.settle.count, "\(all.layoutsAtEnds) layouts for \(all.settle.count) gesture ends")
        #expect(all.layoutsAtEnds >= all.settle.count - 3, "gesture ends did not lay the page out")

        let budgets = ViewerGestureBudgets.self
        #expect(budgets.z11FrameP50.met(measured: frames.p50), budgets.z11FrameP50.failure(measured: frames.p50))
        #expect(budgets.z11FrameP99.met(measured: frames.p99), budgets.z11FrameP99.failure(measured: frames.p99))
        let blank = Double(all.blankFrames)
        #expect(budgets.z12BlankFrames.met(measured: blank), budgets.z12BlankFrames.failure(measured: blank))
        #expect(budgets.z13SettleP50.met(measured: settle.p50), budgets.z13SettleP50.failure(measured: settle.p50))
        #expect(budgets.z13SettleP95.met(measured: settle.p95), budgets.z13SettleP95.failure(measured: settle.p95))
        #expect(budgets.z14LandingP99.met(measured: landing.p99), budgets.z14LandingP99.failure(measured: landing.p99))
    }

    // MARK: - The gate on the gate

    @Test("Every gesture budget matches Docs/Execution/quality-thresholds.json")
    func gestureBudgetsMatchTheThresholdFile() throws {
        let url = ViewerZoomGateTests.repositoryRoot
            .appendingPathComponent("Docs/Execution/quality-thresholds.json")
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let viewer = try #require(root["viewer"] as? [String: Any])
        #expect(ViewerGestureBudgets.all.count == 6, "the gesture budget table lost an entry")
        for budget in ViewerGestureBudgets.all {
            #expect(budget.debug >= budget.release, "\(budget.name): debug tighter than release")
            let gate = try #require(viewer[budget.thresholdGate] as? [String: Any],
                                    "no viewer.\(budget.thresholdGate)")
            #expect(gate[budget.thresholdReleaseKey] as? Double == budget.release,
                    "\(budget.name): release \(budget.release) disagrees with the threshold file")
            #expect(gate[budget.thresholdDebugKey] as? Double == budget.debug,
                    "\(budget.name): debug \(budget.debug) disagrees with the threshold file")
        }
    }
}

/// Gates Z11–Z14, each with a release and a debug value, both mirrored in
/// `Docs/Execution/quality-thresholds.json`.
///
/// The debug column follows the rule of `ViewerTimingBudget`: twice the worst figure a debug run
/// on a quiet machine produced, rounded up, never tighter than release. Measured 2026-09-23 over
/// three debug runs of the fixed canvas at a load average under 25: Z11 p99 1.94–2.32 ms, Z13
/// p50 67–94 ms, p95 102–207 ms, Z14 p99 2.98–4.19 ms. Three runs is a thin sample and it is
/// stated as one; runs made while other builds compiled at a load average of 60–80 measured
/// Z11 p99 45 ms, which is a fact about that afternoon and not a budget.
enum ViewerGestureBudgets {

    static let z11FrameP50 = ViewerTimingBudget(
        name: "z11_frame_p50", release: 2.0, debug: 2.0,
        thresholdGate: "Z11", thresholdReleaseKey: "p50Milliseconds", thresholdDebugKey: "debugP50Milliseconds"
    )
    static let z11FrameP99 = ViewerTimingBudget(
        name: "z11_frame_p99", release: 4.0, debug: 5.0,
        thresholdGate: "Z11", thresholdReleaseKey: "p99Milliseconds", thresholdDebugKey: "debugP99Milliseconds"
    )
    static let z12BlankFrames = ViewerTimingBudget(
        name: "z12_blank_frames", release: 0, debug: 0,
        thresholdGate: "Z12", thresholdReleaseKey: "maximumBlankFrames", thresholdDebugKey: "debugMaximumBlankFrames"
    )
    static let z13SettleP50 = ViewerTimingBudget(
        name: "z13_settle_p50", release: 100.0, debug: 190.0,
        thresholdGate: "Z13", thresholdReleaseKey: "p50Milliseconds", thresholdDebugKey: "debugP50Milliseconds"
    )
    static let z13SettleP95 = ViewerTimingBudget(
        name: "z13_settle_p95", release: 200.0, debug: 420.0,
        thresholdGate: "Z13", thresholdReleaseKey: "p95Milliseconds", thresholdDebugKey: "debugP95Milliseconds"
    )
    static let z14LandingP99 = ViewerTimingBudget(
        name: "z14_landing_p99", release: 2.0, debug: 9.0,
        thresholdGate: "Z14", thresholdReleaseKey: "p99Milliseconds", thresholdDebugKey: "debugP99Milliseconds"
    )

    static let all: [ViewerTimingBudget] = [
        z11FrameP50, z11FrameP99, z12BlankFrames, z13SettleP50, z13SettleP95, z14LandingP99
    ]
}
