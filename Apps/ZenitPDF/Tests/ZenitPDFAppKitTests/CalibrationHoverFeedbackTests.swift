import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Calibration must *show* its snap, not merely apply it.
///
/// The click snaps and is gated, and yet calibration's snap still read as broken. The leading
/// candidate is that nothing on screen says so: a point
/// that snaps invisibly is indistinguishable from one that does not — and worse, a pointer
/// hovering three points from a corner shows no ring and no line, so the estimator has no reason
/// to trust the click that follows.
///
/// In a real window, driven through the pointer path, refreshed by nothing.
@MainActor
@Suite(.appTierSerialised)
struct CalibrationHoverFeedbackTests {

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let canvas: PDFCanvasViewController
        let window: NSWindow
        let directory: URL

        @MainActor
        func tearDown() {
            window.contentViewController = nil
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The stroked-rectangle fixture with corners at exactly (72,72)…(372,272), so "did it snap"
    /// is an exact comparison. Same construction as `CalibrationSnapTests`.
    private func makeHarness() async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: "cal-hover")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        #expect(
            await AppTestSupport.wait(upTo: 40) {
                core.status.snapshot.geometryIndexStatus.allowsVectorSnap
            },
            "the vector snap index never became available; this test cannot say anything"
        )

        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = canvas
        _ = canvas.view
        canvas.viewDidAppear()
        return Harness(
            document: document,
            core: core,
            canvas: canvas,
            window: window,
            directory: url.deletingLastPathComponent()
        )
    }

    @Test("Hovering near a corner while calibrating shows the snap ring on the corner")
    func hoverShowsTheSnapRing() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.canvas.beginCalibration()
        #expect(harness.canvas.isCalibrating)

        // The pointer path the tracking area drives in the running application.
        harness.canvas.handlePointerMove(PDFPointValue(x: 75, y: 74))

        #expect(await AppTestSupport.wait(upTo: 10) {
            harness.canvas.snapGlyphForTesting != nil
        }, """
        Hovering three points from a corner during calibration shows no snap ring. The click \
        snaps (CalibrationSnapTests), but nothing on screen says so, which is what reads as \
        broken: a snap you cannot see is a snap that does not exist.
        """)
        let glyph = try #require(harness.canvas.snapGlyphForTesting)
        #expect(glyph.x == 72 && glyph.y == 72, "the ring is at \(glyph), not on the corner")
    }

    @Test("After the first reference point, a live segment follows the pointer")
    func aLiveSegmentFollowsThePointer() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.canvas.beginCalibration()
        harness.canvas.handleClick(at: PDFPointValue(x: 75, y: 74), additive: false)
        await harness.canvas.settleCalibrationPlacements()

        harness.canvas.handlePointerMove(PDFPointValue(x: 300, y: 90))

        #expect(await AppTestSupport.wait(upTo: 10) {
            harness.canvas.calibrationCursorForTesting != nil
        }, """
        After placing the first reference point there is no line following the pointer. Length \
        draws one; calibration drew nothing, so the tool felt dead between the two clicks — the \
        other half of the report that snapping did not work in Calibrate.
        """)
    }
}
