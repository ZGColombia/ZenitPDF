import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// ADR-0006 snippet export, **through the application**.
///
/// The engine has been finished and hard-verified since 2026-08-23 and no user could reach any
/// of it — the seventh built-but-unwired capability in this repository. A green test in
/// `ZPDFExportTests` says the compositor works; it says nothing about whether an estimator can
/// get a picture onto the clipboard. So every assertion here starts at a menu item or a canvas
/// gesture and ends at bytes.
///
/// ### The zoom-invariance claim, asserted the way the ADR states it
///
/// *"The same snippet exported at any zoom, window size or scroll position produces the
/// identical image."* `SnippetExportTests` proves that of `SnippetExporter` given a spec. That
/// is the easy half: the exporter has no viewport to be wrong about. The half that can actually
/// regress is the application's — the spec is built somewhere, and the day somebody reaches for
/// `canvas.viewport` to decide a region or a scale, the property is gone and no package test
/// notices. ``sameSelectionAtThreeWindowSizesProducesIdenticalBytes`` drives three real window
/// sizes and three real zoom and scroll positions through the shipping command and compares
/// the exported bytes.
///
/// ### Nothing here touches the machine
///
/// The pasteboard is one object for the whole machine. Every copy below goes to a
/// ``RecordingSnippetPasteboard`` injected on the window controller instance —
/// `NSPasteboard.general` is never written, never cleared and never read, and
/// ``theRealPasteboardIsNeverTouched`` asserts that by construction rather than by care. The
/// same reasoning as the preference leak, applied before the fact instead of after it.
@MainActor
@Suite(.appTierSerialised)
struct SnippetExportWiringTests {

    // MARK: - Harness

    struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let controller: ProjectWindowController
        let canvas: PDFCanvasViewController
        let pasteboard: RecordingSnippetPasteboard
        let directory: URL
        /// The two committed measurements, in the order they were made.
        let markupIDs: [UUID]
        /// `ProjectWindowController.tabHost` as it was before this harness existed.
        let previousTabHost: ProjectWindowController?
    }

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// A loaded document in a real (never-visible) project window, with two committed length
    /// measurements on the page and a calibration so both have values in the ledger.
    private func makeHarness() async throws -> Harness {
        let previousTabHost = ProjectWindowController.tabHost
        let url = try AppTestSupport.writeFixturePDF(named: "Snippet.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil && document.shell != nil && document.drawing != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await core.refresh()

        let controller = ProjectWindowController(document: document)
        let pasteboard = RecordingSnippetPasteboard()
        controller.snippetPasteboard = pasteboard
        let canvas = try #require(controller.canvasController(for: document))
        _ = canvas.view
        canvas.onShellCommand = { command in
            guard command == .finishGeometry else { return shell.perform(command) }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }

        // Two lengths, drawn the way a person draws them: arm the tool, click the ends,
        // finish. Nothing is injected into the session behind the canvas's back, because a
        // snippet of markups the canvas never saw would prove nothing about the canvas.
        let spans: [(PDFPointValue, PDFPointValue)] = [
            (PDFPointValue(x: 120, y: 200), PDFPointValue(x: 320, y: 200)),
            (PDFPointValue(x: 140, y: 320), PDFPointValue(x: 300, y: 420))
        ]
        for span in spans {
            shell.perform(.measureLength)
            canvas.refresh()
            canvas.handleClick(at: span.0, additive: false)
            canvas.handleClick(at: span.1, additive: false)
            await core.measurement.settlePlacements()
            canvas.onShellCommand?(.finishGeometry)
            #expect(await wait { core.measurement.placedPoints.isEmpty })
            await core.commands.settle()
            await core.refresh()
        }
        #expect(await wait { core.ledger.rowCount == 2 },
                "the harness needs two committed measurements to take a snippet of")
        await canvas.settleScene()

        return Harness(
            document: document,
            core: core,
            shell: shell,
            controller: controller,
            canvas: canvas,
            pasteboard: pasteboard,
            directory: url.deletingLastPathComponent(),
            markupIDs: core.canvas.visibleMarkups.map(\.id),
            previousTabHost: previousTabHost
        )
    }

    private func tearDown(_ harness: Harness) {
        harness.controller.window?.close()
        harness.document.close()
        ProjectWindowController.tabHost = harness.previousTabHost
        try? FileManager.default.removeItem(at: harness.directory)
    }

    /// Puts the window and the canvas into one concrete viewing state: window size, zoom and
    /// the page rectangle scrolled to. Everything a snippet must be independent of.
    private func view(
        _ harness: Harness,
        windowSize: NSSize,
        zoom: Double,
        scrolledTo rect: PDFRectValue
    ) async {
        harness.controller.window?.setContentSize(windowSize)
        harness.canvas.view.frame = NSRect(origin: .zero, size: windowSize)
        harness.canvas.view.layoutSubtreeIfNeeded()
        harness.canvas.restore(zoom: zoom, visiblePageRect: rect)
        harness.canvas.refresh()
        await harness.canvas.settleScene()
    }

    /// Runs the Edit ▸ Copy Snippet menu item through the responder-chain action the menu bar
    /// actually targets, and waits for the payload.
    private func copySnippetThroughTheMenu(_ harness: Harness) async -> Bool {
        let item = NSMenuItem()
        item.representedObject = ZenitAppCommand.copySnippet.rawValue
        let before = harness.pasteboard.payloads.count
        harness.controller.performZenitCommand(item)
        return await wait { harness.pasteboard.payloads.count == before + 1 }
    }

    /// A string reduced to its digits and a canonical `.` decimal separator.
    static func digitsOnly(_ text: String) -> String {
        String(text.compactMap { character -> Character? in
            if character.isNumber { return character }
            if character == "," || character == "." { return "." }
            return nil
        })
    }

    /// A short fingerprint of the exported bytes.
    ///
    /// The assertion is byte equality; this exists so a failure reads as two different
    /// fingerprints and a length, rather than as "8 214 bytes != 8 214 bytes". FNV-1a over the
    /// whole payload plus the length — enough to name a difference, and it is never the thing
    /// that decides the verdict, because equal fingerprints of unequal data would still have to
    /// survive the length check.
    private func digest(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx/%d", hash, data.count)
    }

    // MARK: - The caller exists

    @Test("Every snippet command has a menu item, and the menu item carries a real command")
    func theMenuBarCanReachSnippetExport() throws {
        let bar = ZenitMenuBar.make()
        var found: Set<String> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let raw = item.representedObject as? String { found.insert(raw) }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(bar)
        for command in [
            ZenitAppCommand.copySnippet, .exportSnippet, .snippetRegion
        ] {
            #expect(found.contains(command.rawValue),
                    "\(command.rawValue) is built and has no menu item — the eighth unwired feature")
        }
    }

    @Test("Copy Snippet is offered exactly when there is a selection to take a picture of")
    func copySnippetIsValidatedAgainstTheSelection() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        let item = NSMenuItem()
        item.representedObject = ZenitAppCommand.copySnippet.rawValue
        harness.core.canvas.clearSelection()
        #expect(harness.controller.validateMenuItem(item) == false,
                "with nothing selected the command has no region; the menu must say so first")

        harness.core.canvas.select(markupIDs: Set(harness.markupIDs), additive: false)
        #expect(harness.controller.validateMenuItem(item) == true)

        // Region capture needs a drawing, not a selection — it is the door for "I have not
        // selected anything", so gating it on a selection would close the only way in.
        let region = NSMenuItem()
        region.representedObject = ZenitAppCommand.snippetRegion.rawValue
        harness.core.canvas.clearSelection()
        #expect(harness.controller.validateMenuItem(region) == true)
    }

    // MARK: - The ten-second path

    @Test("Select two measurements, one command, a captioned PNG and its text are on the pasteboard")
    func theSelectionPathPutsAPictureOnThePasteboard() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        harness.core.canvas.select(markupIDs: Set(harness.markupIDs), additive: false)
        #expect(await copySnippetThroughTheMenu(harness))

        let payload = try #require(harness.pasteboard.payloads.last)
        #expect(payload.png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "the image must be a PNG")
        #expect(payload.png.count > 1_000, "a 3x snippet of two measurements is not 1 kB of nothing")
        #expect(!payload.plainText.isEmpty,
                "the plain-text fallback is the half that keeps a value true in a text field")

        // The caption is `.compact` and **on** by default (ADR-0006 §2): a dimensioned image
        // travelling without its value is the risk the feature carries, so the default path
        // must never produce an uncaptioned one.
        let ledgerValues = (0..<harness.core.ledger.rowCount).compactMap { index in
            harness.core.ledger.row(at: index)?.displayValue(.planLength)
        }
        #expect(ledgerValues.count == 2)
        let captionDigits = Self.digitsOnly(payload.plainText)
        for value in ledgerValues {
            // Digits, with the decimal separator normalised. The two surfaces spell the
            // separator differently **on purpose**: the ledger table renders in the reader's
            // locale, and every export — CSV, XLSX, the report, and therefore the caption —
            // renders through `ExportNumberLocale`, so an exported file is byte-stable
            // wherever it is produced. What ADR-0006 §2 requires is that the *number* is the
            // ledger's number, and that is what this compares.
            let digits = Self.digitsOnly(value)
            #expect(!digits.isEmpty, "the ledger row has no plan length to compare against")
            let message = "the caption must quote the ledger digit for digit: "
                + "\(digits) (\(value)) missing from \(payload.plainText)"
            #expect(captionDigits.contains(digits), "\(message)")
        }
    }

    @Test("The default caption is compact and on, and .none is reachable but not the default")
    func theCaptionDefaultIsOn() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        let subject = SnippetExport.Subject.selection(Set(harness.markupIDs))
        let captioned = try await harness.controller.snippetInputs(for: harness.document, of: subject)
        #expect(captioned.spec.caption == .compact)
        #expect(captioned.projection != nil,
                "a captioned snippet must carry the projection its digits come from")

        let bare = try await SnippetExport.inputs(
            for: subject, document: harness.document, caption: .none
        )
        #expect(bare.spec.caption == .none)
        #expect(bare.projection == nil)
    }

    // MARK: - Zoom invariance, through the application

    @Test("The same selection at three window sizes and scroll positions is byte-identical")
    func sameSelectionAtThreeWindowSizesProducesIdenticalBytes() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        harness.core.canvas.select(markupIDs: Set(harness.markupIDs), additive: false)

        // Three genuinely different views of the same drawing: a narrow window zoomed out and
        // scrolled to the origin, a wide window at 1:1 scrolled to the middle, and a tall one
        // at 400 % scrolled past the markups entirely — the last so that "what is on screen"
        // and "what the snippet shows" cannot accidentally coincide.
        let views: [(name: String, size: NSSize, zoom: Double, rect: PDFRectValue)] = [
            ("narrow-25%", NSSize(width: 700, height: 500), 0.25,
             PDFRectValue(x: 0, y: 0, width: 595, height: 842)),
            ("wide-100%", NSSize(width: 1_600, height: 900), 1.0,
             PDFRectValue(x: 120, y: 180, width: 400, height: 300)),
            ("tall-400%", NSSize(width: 520, height: 1_100), 4.0,
             PDFRectValue(x: 480, y: 700, width: 100, height: 120))
        ]

        var exports: [(name: String, png: Data)] = []
        var states: [ViewportSnapshot] = []
        for view in views {
            await self.view(harness, windowSize: view.size, zoom: view.zoom, scrolledTo: view.rect)
            // **The control.** An invariance test whose three conditions are secretly one
            // condition passes for the wrong reason, and this repository has already paid for
            // one of those. Record what the canvas actually ended up showing and assert below
            // that the three views really were three views.
            states.append(harness.core.canvas.viewport)
            #expect(await copySnippetThroughTheMenu(harness),
                    "\(view.name): the command produced nothing")
            let payload = try #require(harness.pasteboard.payloads.last)
            exports.append((view.name, payload.png))
        }

        #expect(Set(states.map(\.zoom)).count == 3,
                "the canvas was at one zoom for all three exports: \(states.map(\.zoom))")
        #expect(Set(states.map(\.visiblePageRect)).count == 3,
                "the canvas showed one region for all three exports")
        #expect(Set(views.map(\.size.width)).count == 3, "the window never changed size")

        #expect(exports.count == 3)
        let first = try #require(exports.first)
        for entry in exports.dropFirst() {
            // Byte equality, not a similarity score: ADR-0006 §1 says *identical*.
            let message = "ADR-0006 §1: \(entry.name) produced \(digest(entry.png)), "
                + "\(first.name) produced \(digest(first.png))"
            #expect(entry.png == first.png, "\(message)")
        }
        // And the same three captions, since the caption comes from the ledger and not from
        // anything the window knows.
        let texts = Set(harness.pasteboard.payloads.suffix(3).map(\.plainText))
        #expect(texts.count == 1, "the caption changed with the window: \(texts)")
    }

    // MARK: - The region path

    @Test("Tools ▸ Snippet of Region arms the canvas, and the released rectangle is copied")
    func theRegionPathCopiesTheDraggedRectangle() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        let item = NSMenuItem()
        item.representedObject = ZenitAppCommand.snippetRegion.rawValue
        harness.controller.performZenitCommand(item)
        #expect(harness.canvas.isCapturingSnippetRegion,
                "the command must arm the canvas, or the menu item is decoration")
        // The controller's own flag is a mirror; this is the one `CanvasPageView.mouseDown`
        // branches on. If only the mirror were set the drag would fall through to the Select
        // tool's marquee and no snippet would ever be taken.
        #expect(harness.canvas.isPageViewCapturingRegion)

        let released = try #require(harness.canvas.onSnippetRegion)
        harness.canvas.endSnippetRegion()
        released(PDFRectValue(x: 100, y: 170, width: 260, height: 280))
        #expect(await wait { !harness.pasteboard.payloads.isEmpty })

        let payload = try #require(harness.pasteboard.payloads.last)
        #expect(payload.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(!harness.canvas.isCapturingSnippetRegion,
                "the mode must end on the release; a pointer stuck in an invisible mode is a dead end")
        #expect(!harness.canvas.isPageViewCapturingRegion)

        // A rectangle too small to be a region is refused rather than exported as a smudge.
        await #expect(throws: (any Error).self) {
            _ = try await SnippetExport.inputs(
                for: .region(PDFRectValue(x: 100, y: 100, width: 0.5, height: 0.5)),
                document: harness.document
            )
        }
    }

    // MARK: - Save to file

    @Test("Export Snippet writes a PNG, and the PDF variant of the same region")
    func theFilePathWritesBothVariants() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        harness.core.canvas.select(markupIDs: Set(harness.markupIDs), additive: false)
        let subject = SnippetExport.Subject.selection(Set(harness.markupIDs))
        let png = harness.directory.appendingPathComponent("snippet.png")
        // Not "snippet.pdf": the harness's drawing is Snippet.pdf in the same folder, which is the
        // same file on a case-insensitive volume. Until U-017 this test wrote over its own drawing.
        let pdf = harness.directory.appendingPathComponent("snippet-out.pdf")

        try await harness.controller.writeSnippet(for: harness.document, of: subject, to: png)
        try await harness.controller.writeSnippet(for: harness.document, of: subject, to: pdf)

        let pngBytes = try Data(contentsOf: png)
        let pdfBytes = try Data(contentsOf: pdf)
        #expect(pngBytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(pdfBytes.starts(with: Array("%PDF".utf8)))
    }

    @Test("U-017: Export Snippet refuses the drawing however its name is cased, and leaves its bytes alone")
    func theDrawingIsNeverTheSnippet() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        harness.core.canvas.select(markupIDs: Set(harness.markupIDs), additive: false)
        let subject = SnippetExport.Subject.selection(Set(harness.markupIDs))
        let drawingURL = try #require(harness.document.drawing?.url)
        let before = try Data(contentsOf: drawingURL)

        // The drawing itself, and the lower-case spelling a person types in the save panel.
        for name in [drawingURL.lastPathComponent, drawingURL.lastPathComponent.lowercased()] {
            let destination = harness.directory.appendingPathComponent(name)
            await #expect(throws: DerivedCopyGuard.Refusal.self, "\(name)") {
                try await harness.controller.writeSnippet(for: harness.document, of: subject, to: destination)
            }
        }
        #expect(try Data(contentsOf: drawingURL) == before, "the snippet replaced the drawing it was taken from")
    }

    // MARK: - The machine is left alone

    @Test("Copying a snippet in a test never writes the real pasteboard")
    func theRealPasteboardIsNeverTouched() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        let before = NSPasteboard.general.changeCount
        harness.core.canvas.select(markupIDs: Set(harness.markupIDs), additive: false)
        #expect(await copySnippetThroughTheMenu(harness))
        #expect(!harness.pasteboard.payloads.isEmpty)
        #expect(NSPasteboard.general.changeCount == before,
                "the user's clipboard was written by a test")
    }
}
