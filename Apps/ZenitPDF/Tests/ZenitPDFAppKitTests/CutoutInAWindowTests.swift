import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Cutout, driven the way a person drives it: in a window, with no test-only refresh.
///
/// Reported 2026-08-26: Cutout did not work in the running application.
///
/// `SelectAreaCutoutTests` covers the same tool and passes — but every one of its cases calls
/// `core.refresh()`, `canvas.refresh()` and `settleScene()` by hand between drawing the area and
/// starting the cutout, and its own helper says why: *"In the running application
/// `withObservationTracking` does this on every commit; a controller whose view never appeared
/// has no observation, so the tests ask for it."*
///
/// That is the same shape as the Text defect fixed the day before: the tests drive the layer
/// below the one that is broken. So these put the canvas in a real window — never ordered on
/// screen — let `viewDidAppear` start the observation, and then **do not refresh anything**. If
/// the parent list is stale at the moment the estimator arms Cutout, every cutout is refused as
/// "outside every area" while the pointer is plainly inside one.
@MainActor
@Suite(.appTierSerialised)
struct CutoutInAWindowTests {

    @MainActor
    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let canvas: PDFCanvasViewController
        let window: NSWindow
        let directory: URL

        func tearDown() {
            window.contentViewController = nil
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness() async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: "cutout-window")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        // Snap off, so every coordinate below is the one the test asked for.
        var snap = await core.session.currentSnapSettings
        snap.enabledKinds = []
        try await core.session.setSnapSettings(snap)
        await core.refresh()

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
        canvas.onShellCommand = { command in
            guard command == .finishGeometry else {
                shell.perform(command)
                return
            }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }
        // The observation the running application relies on starts here, and nowhere else.
        canvas.viewDidAppear()

        return Harness(
            document: document,
            core: core,
            shell: shell,
            canvas: canvas,
            window: window,
            directory: url.deletingLastPathComponent()
        )
    }

    /// Draws a closed area and waits only for what the application itself waits for.
    private func drawArea(_ vertices: [PDFPointValue], _ harness: Harness) async {
        harness.shell.perform(.measureArea)
        for vertex in vertices {
            harness.canvas.handleClick(at: vertex, additive: false)
            await harness.core.measurement.settlePlacements()
        }
        harness.canvas.handleClick(at: vertices[0], additive: false)
        await harness.core.measurement.settlePlacements()
    }

    private func records(_ core: AppCoreEnvironment) async -> [MarkupRecord] {
        await core.session.orderedMarkups
    }

    @Test("An area drawn and then cut, with nothing refreshed by hand, produces a child cutout")
    func cutoutWorksWithoutATestOnlyRefresh() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        let square: [PDFPointValue] = [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 400, y: 100),
            PDFPointValue(x: 400, y: 400),
            PDFPointValue(x: 100, y: 400)
        ]
        await drawArea(square, harness)

        // Give the application's own observation the run-loop turns it needs — the same wait a
        // person's hand gives it — but never call refresh.
        #expect(await AppTestSupport.wait(upTo: 10) {
            harness.canvas.cutoutCandidateCountForTesting > 0
        }, """
        The parent list is still empty after an area was committed and the observation had time \\
        to run. Every cutout started inside that area will be refused as "outside every area".
        """)

        harness.shell.perform(.cutoutTool)
        let hole: [PDFPointValue] = [
            PDFPointValue(x: 200, y: 200),
            PDFPointValue(x: 300, y: 200),
            PDFPointValue(x: 300, y: 300),
            PDFPointValue(x: 200, y: 300)
        ]
        for vertex in hole {
            harness.canvas.handleClick(at: vertex, additive: false)
            await harness.core.measurement.settlePlacements()
        }
        harness.canvas.handleClick(at: hole[0], additive: false)
        await harness.core.measurement.settlePlacements()

        // The commit is asynchronous; give it the same moment a hand would.
        try? await Task.sleep(for: .milliseconds(400))

        let all = await records(harness.core)
        let children = all.filter { $0.parentMarkupID != nil }
        #expect(
            children.count == 1,
            "no cutout was created: \\(all.count) markups, \\(children.count) of them children"
        )
    }

    @Test("A cutout started where there is no area is refused, and says so")
    func cutoutOutsideAnAreaIsRefusedWithAReason() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.shell.perform(.cutoutTool)
        harness.canvas.handleClick(at: PDFPointValue(x: 500, y: 500), additive: false)
        await harness.core.measurement.settlePlacements()

        #expect(harness.core.measurement.placedPoints.isEmpty, "a point was placed with no parent")
        let note = harness.core.status.snapshot.activeToolNote
        #expect(
            !(note ?? "").isEmpty,
            "the refusal is silent — the tool does nothing and says nothing, which reads as broken"
        )
    }

    @Test("The canvas settles: an idle window does not refresh in a loop")
    func theCanvasSettlesInsteadOfSpinning() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        await drawArea([
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 400, y: 100),
            PDFPointValue(x: 400, y: 400),
            PDFPointValue(x: 100, y: 400)
        ], harness)
        try? await Task.sleep(for: .milliseconds(500))

        // Measured over a second in which nothing happens at all.
        let before = harness.canvas.refreshCountForTesting
        try? await Task.sleep(for: .seconds(1))
        let during = harness.canvas.refreshCountForTesting - before

        #expect(during < 20, """
        The canvas refreshed \(during) times in one idle second. On 2026-08-27 this was \
        ≈17 000: `refresh()` laid the page out, `reportVisibleRect()` assigned \
        `viewport.visiblePageRect`, and `@Observable` published that assignment whether or not \
        the value had changed — waking the canvas that had just written it.

        The loop was not merely wasteful. Each pass cancelled the scene-building task before \
        `await session.orderedMarkups` returned, so `sceneRecords` never populated and the \
        cutout parent list stayed empty: every cutout was refused as "outside every area" with \
        the pointer inside one. It also spent the main thread, which is what \
        `Scripts/verify-app-launches.sh` measures.

        A number here in the thousands means something assigns an observed property during \
        layout again. Find the assignment and make it conditional, as \
        `AppCanvasPresenter.setVisiblePageRect` is.
        """)
    }
}
