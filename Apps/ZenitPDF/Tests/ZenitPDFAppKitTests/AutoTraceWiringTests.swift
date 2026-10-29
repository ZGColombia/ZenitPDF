import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Auto-trace, through the window: ⌥-click inside the fixture rectangle with Area armed commits
/// the rectangle as an area — same command, same audit, same undo as a hand-drawn one.
///
/// Auto-trace. The engine's own suite proves the walk; this proves the join: the click
/// reaches the tracer with the extraction the underlay already holds, the ring reaches the
/// measurement presenter, and a refusal is spoken rather than swallowed.
@MainActor
@Suite(.appTierSerialised)
struct AutoTraceWiringTests {

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
        // The standard fixture: a stroked rectangle with corners (72,72)…(372,272).
        let url = try AppTestSupport.writeFixturePDF(named: "autotrace")
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
        // In the application the window controller forwards `onVectorUnderlayReady` into the
        // canvas; the document fires it once, shortly after open — usually before a test can
        // assign the callback. The harness therefore feeds the canvas through the same loader
        // the application uses, deterministically.
        let pages = try #require(document.drawing?.pages)
        let first = try #require(pages.first)
        let loaded = await DocumentSessionLoader.buildSnapIndex(
            for: first,
            documentURL: url,
            session: core.session
        )
        let extraction = try #require(loaded.extraction, "the fixture yielded no vector extraction")
        canvas.prepareVectorUnderlay(page: first, extraction: extraction)
        #expect(canvas.hasUnderlayExtractionForTesting)
        return Harness(
            document: document, core: core, shell: shell,
            canvas: canvas, window: window, directory: url.deletingLastPathComponent()
        )
    }

    @Test("⌥-click inside the rectangle commits it as an area, exactly")
    func optionClickTracesTheRoom() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.shell.perform(.measureArea)
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 150), additive: false, optionHeld: true)
        try? await Task.sleep(for: .milliseconds(500))

        let records = await harness.core.session.orderedMarkups
        #expect(records.count == 1, "the trace committed \(records.count) records")
        let record = try #require(records.first)
        let ring = try #require(record.geometry?.polygons.first?.outer.points)
        #expect(ring.count == 4, "the rectangle traced to \(ring.count) vertices")
        // 300 × 200 pt at 100 pt = 1 m → 3 m × 2 m = 6 m².
        let area = try #require(record.measurement?.values[.planArea])
        #expect(abs(NSDecimalNumber(decimal: area.value).doubleValue - 6) < 0.001,
                Comment(rawValue: "traced area is not 6 m2"))
    }

    @Test("⌥-click outside every boundary refuses out loud and commits nothing")
    func optionClickOutsideRefusesOutLoud() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.shell.perform(.measureArea)
        harness.canvas.handleClick(at: PDFPointValue(x: 500, y: 700), additive: false, optionHeld: true)
        try? await Task.sleep(for: .milliseconds(400))

        let records = await harness.core.session.orderedMarkups
        #expect(records.isEmpty, "a refused trace still committed something")
        let note = harness.core.status.snapshot.activeToolNote ?? ""
        #expect(note.contains("Not traced"), "the refusal was silent: note is \"\(note)\"")
    }
}
