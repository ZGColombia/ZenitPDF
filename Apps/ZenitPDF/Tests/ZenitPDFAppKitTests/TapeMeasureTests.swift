import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The tape measure: a reading, not a row — and visible while it is held.
///
/// `temporaryMeasure` existed with full presenter support, ledger exclusion included, and one
/// hole: nothing drew the committed tape. The second click landed and the measurement vanished,
/// kept faithfully in a list no view read. Its acceptance is asserted here:
/// it appears nowhere permanent, and the one thing it must never do — look like a committed
/// measurement — is what the ink flag carries.
@MainActor
@Suite(.appTierSerialised)
struct TapeMeasureTests {

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
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

    private func makeHarness() async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: "tape")
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
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = canvas
        _ = canvas.view
        canvas.viewDidAppear()
        return Harness(
            document: document, core: core, shell: shell,
            canvas: canvas, window: window, directory: url.deletingLastPathComponent()
        )
    }

    @Test("A committed tape is drawn — dashed, flagged, and on screen")
    func theTapeIsDrawn() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.core.measurement.activate(kind: .temporaryMeasure)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.canvas.handleClick(at: PDFPointValue(x: 300, y: 100), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.core.measurement.commitActiveMeasurement()

        #expect(await AppTestSupport.wait(upTo: 10) {
            harness.canvas.canvasShapes.contains { $0.isTemporary }
        }, """
        The tape was committed and nothing on screen shows it. It sits in \
        `temporaryOverlayRecords` with no view reading the list — the exact hole this feature \
        closed.
        """)
        let tape = try #require(harness.canvas.canvasShapes.first { $0.isTemporary })
        #expect(tape.strokes.first?.points.count == 2)
    }

    @Test("The tape reaches no row, no history, and no saved record")
    func theTapeIsNotARecord() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.core.measurement.activate(kind: .temporaryMeasure)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 200), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.canvas.handleClick(at: PDFPointValue(x: 250, y: 200), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.core.measurement.commitActiveMeasurement()
        try? await Task.sleep(for: .milliseconds(300))

        let records = await harness.core.session.orderedMarkups
        #expect(records.isEmpty, "a tape became a stored markup")
        await harness.core.ledger.refresh()
        #expect(harness.core.ledger.rowCount == 0, "a tape became a ledger row")
    }

    @Test("The tape survives a tool switch — spec 12.14 — and Clear removes it from the screen")
    func theTapeFollowsSpec1214() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.core.measurement.activate(kind: .temporaryMeasure)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 300), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.canvas.handleClick(at: PDFPointValue(x: 220, y: 300), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.core.measurement.commitActiveMeasurement()
        #expect(await AppTestSupport.wait(upTo: 10) {
            harness.canvas.canvasShapes.contains { $0.isTemporary }
        })

        // Spec 12.14: the tape is kept until the user promotes or clears it. A tool switch is
        // neither — the estimator checks a dimension, picks up Length, and the reading stays
        // on screen for reference.
        harness.shell.perform(.selectTool)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(
            harness.canvas.canvasShapes.contains { $0.isTemporary },
            "a tool switch destroyed the tape; spec 12.14 keeps it until promote or clear"
        )

        // Clear is the documented way out, and the screen must follow it.
        harness.core.measurement.clearTemporaryMeasurements()
        #expect(await AppTestSupport.wait(upTo: 10) {
            !harness.canvas.canvasShapes.contains { $0.isTemporary }
        }, "Clear removed the records and the screen kept drawing the tape")
    }
}
