import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Every drawing tool, driven in a real window, with nothing refreshed by hand.
///
/// This sweep exists because two defects in two days were found the same way and missed by the
/// same blind spot: every function in the system has to be checked to really work.
///
/// The blind spot is structural. Every other canvas suite constructs a `PDFCanvasViewController`
/// whose view never appears, then calls `refresh()`, `core.refresh()` and `settleScene()` between
/// steps. Such a controller never starts `withObservationTracking`, so it cannot spin, cannot
/// lose a scene rebuild to task cancellation, and cannot fail to give a text box first responder.
/// All three of those shipped:
///
///   * the Text box held no keystroke — `NSTextView` with no text system;
///   * the canvas refreshed ≈17 000 times a second and Cutout could never find a parent;
///   * and both suites were green throughout.
///
/// So: a real `NSWindow` — never ordered on screen — `viewDidAppear()` to start the observation,
/// and **no manual refresh anywhere below this line**.
@MainActor
@Suite(.appTierSerialised)
struct WindowToolSweepTests {

    // MARK: - Harness

    struct Harness {
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

    func makeHarness(_ name: String) async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: name)
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
        // Snap off: these assert what the tools do with the points they are given, and snap has
        // its own suites. With the grid live a 400 pt click lands at 396.
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

    func records(_ harness: Harness) async -> [MarkupRecord] {
        await harness.core.session.orderedMarkups
    }

    /// Clicks a run of points and waits only for the snap resolve, which is what the application
    /// itself waits for.
    func click(_ points: [PDFPointValue], _ harness: Harness) async {
        for point in points {
            harness.canvas.handleClick(at: point, additive: false)
            await harness.core.measurement.settlePlacements()
        }
    }

    // MARK: - Measurement tools

    @Test("Every measurement tool commits a record with the geometry it was given", arguments: [
        (ZPDFCommandID.measureLength, ZPDFUIPresentation.MeasurementKind.length, 2),
        (ZPDFCommandID.measurePolylength, MeasurementKind.polylength, 3),
        (ZPDFCommandID.measureArea, MeasurementKind.area, 4),
        (ZPDFCommandID.measureCount, MeasurementKind.count, 3)
    ])
    func measurementToolsCommit(
        command: ZPDFCommandID,
        kind: ZPDFUIPresentation.MeasurementKind,
        points: Int
    ) async throws {
        let harness = try await makeHarness("sweep-\(kind.rawValue)")
        defer { harness.tearDown() }

        harness.shell.perform(command)
        #expect(
            harness.canvas.armedMode == .measure(kind),
            "\(command.rawValue) armed \(harness.canvas.armedMode) rather than \(kind)"
        )

        let vertices = (0..<points).map {
            PDFPointValue(x: 120 + Double($0) * 80, y: 150 + Double($0 % 2) * 60)
        }
        await click(vertices, harness)

        // Finish the way the application finishes: an area closes on its first vertex, a count
        // is complete at every mark, everything else takes Return.
        switch kind {
        case .area:
            await click([vertices[0]], harness)
        case .count:
            harness.canvas.onShellCommand?(.finishGeometry)
        default:
            harness.canvas.onShellCommand?(.finishGeometry)
        }
        try? await Task.sleep(for: .milliseconds(400))

        let all = await records(harness)
        #expect(all.count == 1, "\(kind) committed \(all.count) records")
        let record = try #require(all.first)
        #expect(record.tool == Domain.Tool(shown: kind), "committed as \(String(describing: record.tool))")
    }

    // MARK: - Markup tools

    @Test("Every two-point shape commits from a press-drag-release", arguments: [
        ZPDFUIPresentation.MarkupKind.rectangle, .ellipse, .line, .arrow
    ])
    func twoPointShapesCommit(kind: ZPDFUIPresentation.MarkupKind) async throws {
        let harness = try await makeHarness("sweep-\(kind.rawValue)")
        defer { harness.tearDown() }

        harness.shell.toolbar.activateShape(kind)
        // A markup tool is armed on the *toolbar*; the canvas picks it up when the observation
        // fires. A measurement command arms the presenter synchronously, which is why those
        // needed no wait. Waiting here separates "one run-loop turn" from "never".
        #expect(await AppTestSupport.wait(upTo: 5) { harness.canvas.armedMode == .markup(kind) },
                "the canvas never heard the toolbar arm \(kind.rawValue)")
        #expect(
            harness.canvas.armedMode == .markup(kind),
            "\(kind.rawValue) armed in the toolbar and the canvas heard \(harness.canvas.armedMode)"
        )

        harness.canvas.handleDragBegan(at: PDFPointValue(x: 120, y: 140))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 340, y: 260))
        try? await Task.sleep(for: .milliseconds(400))

        let all = await records(harness)
        #expect(all.count == 1, "\(kind.rawValue) committed \(all.count) records")
        #expect(try #require(all.first).kind == ZPDFContracts.MarkupKind(shown: kind))
    }

    @Test("Text and Callout open a box that holds a keystroke and commits what was typed",
          arguments: [ZPDFUIPresentation.MarkupKind.text, ZPDFUIPresentation.MarkupKind.callout])
    func textualToolsCommitTypedText(kind: ZPDFUIPresentation.MarkupKind) async throws {
        let harness = try await makeHarness("sweep-\(kind.rawValue)")
        defer { harness.tearDown() }

        harness.shell.perform(kind == .text ? .textTool : .calloutTool)
        #expect(await AppTestSupport.wait(upTo: 5) { harness.canvas.armedMode == .markup(kind) },
                "the canvas never heard the toolbar arm \(kind.rawValue)")

        // A callout wants its target point first, then the box.
        if kind == .callout {
            await click([PDFPointValue(x: 120, y: 140)], harness)
        }
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 200, y: 200))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 380, y: 260))

        let editor = try #require(
            harness.canvas.textEditorForTesting,
            "\(kind.rawValue) opened no text box"
        )
        #expect(
            harness.window.firstResponder === editor,
            "the box has no caret; first responder is \(String(describing: harness.window.firstResponder))"
        )
        editor.insertText("Rivning", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.string == "Rivning", "the box discarded the keystroke")

        harness.canvas.commitTextEntry()
        try? await Task.sleep(for: .milliseconds(400))

        let all = await records(harness)
        #expect(all.count == 1, "\(kind.rawValue) committed \(all.count) records")
        // NL-COLLAB-18 (nl-collaboration): a text box's words are what it draws — its caption —
        // and its note (comment) starts empty, so a reply thread never reads the drawn text.
        let committed = try #require(all.first)
        #expect(committed.caption == "Rivning", "the typed string did not reach the record")
        #expect(committed.comment.isEmpty, "the drawn words leaked into the note")
    }

    // MARK: - The settle guard, per tool

    @Test("Arming a tool does not put the canvas in a refresh loop", arguments: [
        ZPDFCommandID.selectTool, .panTool, .zoomTool, .textTool, .calloutTool,
        .shapesTool, .cutoutTool, .measureLength, .measureArea, .measureCount
    ])
    func armingAToolDoesNotSpin(command: ZPDFCommandID) async throws {
        let harness = try await makeHarness("settle-\(command.rawValue.replacingOccurrences(of: ".", with: "-"))")
        defer { harness.tearDown() }

        harness.shell.perform(command)
        try? await Task.sleep(for: .milliseconds(300))

        let before = harness.canvas.refreshCountForTesting
        try? await Task.sleep(for: .milliseconds(600))
        let during = harness.canvas.refreshCountForTesting - before

        #expect(during < 20, """
        Arming \(command.rawValue) left the canvas refreshing \(during) times in 0.6 idle \
        seconds. An observed property assigned during layout must be assigned \
        only when its value actually changes, or the canvas wakes the canvas.
        """)
    }
}
