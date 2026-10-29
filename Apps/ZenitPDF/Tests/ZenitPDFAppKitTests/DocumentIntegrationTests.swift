import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The assembly test: a real PDF, opened through `NSDocument`, produces a window whose content is
/// the shell composition, and a measurement drawn on it reaches the Quantity Ledger.
///
/// Everything below runs against the shipping objects. Nothing is stubbed, so a regression in the
/// document, the window controller, the presenters or the engine fails here rather than in a
/// screenshot somebody looks at later.
@MainActor
@Suite(.appTierSerialised)
struct DocumentIntegrationTests {

    private func fixtureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Plan A-102.pdf")
        let content = Data("2 w 0 0 0 RG\n72 72 m 372 72 l 372 272 l 72 272 l h S\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>".utf8)
        ]
        var streamData = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        streamData.append(content)
        streamData.append(Data("\nendstream".utf8))
        objects.append(streamData)

        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    /// Polls the main actor until `condition` holds, so the test waits on the document's own async
    /// load rather than on a fixed sleep.
    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("Opening a PDF builds the engine session and the shell environment")
    func openingBuildsTheShell() async throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.shell != nil })

        #expect(document.mode == .quickPDF)
        #expect(document.loadFailure == nil)
        let core = try #require(document.core)
        #expect(core.snapshot.pages.count == 1)
        #expect(core.document.currentPage?.label == "1")
        #expect(core.document.tabs.count == 1)
        #expect(core.document.tabs.first?.mode == .standalonePDF)
        #expect(document.drawing?.pages.first?.boxes.crop.size.height == 842)

        document.close()
    }

    @Test("The window controller installs the shell composition")
    func windowInstallsTheShell() async throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await wait { controller.contentViewController is ProjectWindowLayoutController })

        let layout = try #require(controller.contentViewController as? ProjectWindowLayoutController)
        // Navigator, canvas, Inspector across; content and Quantity Ledger down.
        #expect(layout.contentSplitController.splitViewItems.count == 3)
        #expect(layout.outerSplitController.splitViewItems.count == 2)
        // The canvas pane is the real page renderer, not the shell's stand-in. It sits inside
        // `CanvasPaneContainerViewController`, which owns the canvas for the life of the window
        // so a canvas view mode can be laid *over* it without ever removing it — reaching
        // through the container is the assertion, not a weakening of it.
        let canvasPane = try #require(
            layout.contentSplitController.splitViewItems[1].viewController
                as? CanvasPaneContainerViewController
        )
        #expect(canvasPane.canvasController is PDFCanvasViewController)
        // The toolbar is installed on the window.
        #expect(controller.window?.toolbar != nil)
        #expect(controller.window?.title == "Plan A-102")

        document.close()
    }

    @Test("A committed measurement is undoable through the document's own undo manager")
    func committedMeasurementIsUndoableThroughTheDocument() async throws {
        // CORE_LOOP: one ⌘Z takes the drawn markup back. ⌘Z travels Edit ▸ Undo →
        // `document.undoManager`, so the command bus must register its inverses on that
        // exact instance — a bus on a private UndoManager is undo that looks alive in
        // engine tests and is dead in the menu (found live, 2026-08-24).
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)

        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await core.refresh()
        core.measurement.activate(kind: .length)
        core.measurement.placePoint(PDFPointValue(x: 72, y: 272))
        core.measurement.placePoint(PDFPointValue(x: 372, y: 272))
        await core.measurement.settlePlacements()
        core.measurement.commitActiveMeasurement()
        #expect(await wait { core.ledger.rowCount == 1 })

        let undoManager = try #require(document.undoManager)
        #expect(
            await wait { undoManager.canUndo },
            "the committed measurement must be registered on the document's undo manager"
        )
        undoManager.undo()
        #expect(await wait { core.ledger.rowCount == 0 }, "one undo takes the markup back")

        document.close()
    }

    @Test("The inspector's Subject and Precision control rows are wired to the app tier")
    func inspectorEditingHooksAreWired() async throws {
        // Found live 2026-08-24: the shell rendered the Inspector's Measurement control
        // rows, but `InspectorEditing`'s hooks were never set by the
        // app, so a committed Subject edit changed nothing anywhere. Unwired hooks are
        // deliberately inert in the shell — which is exactly why the wiring needs its own
        // assembly test here.
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        // Seeded from the units actually in force, not the shell's default.
        #expect(shell.inspectorEditing.activePrecision ==
            .decimalPlaces(core.snapshot.units.metricDecimalPlaces))

        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await core.refresh()
        core.measurement.activate(kind: .length)
        core.measurement.placePoint(PDFPointValue(x: 72, y: 272))
        core.measurement.placePoint(PDFPointValue(x: 372, y: 272))
        await core.measurement.settlePlacements()
        core.measurement.commitActiveMeasurement()
        #expect(await wait { core.ledger.rowCount == 1 })
        let markupID = try #require(core.snapshot.markups.first?.id)

        // Subject: through the hook, into the command bus, out through the snapshot the
        // ledger and the canvas caption render from — and undoable like any command.
        let editSubject = try #require(shell.inspectorEditing.onEditSubject)
        editSubject([markupID], "Takfot")
        #expect(await wait { core.snapshot.markups.first?.subject == "Takfot" },
                "the committed subject must reach the snapshot")
        let undoManager = try #require(document.undoManager)
        undoManager.undo()
        #expect(await wait { core.snapshot.markups.first?.subject == "Length" },
                "one undo restores the old subject")

        // Precision: display formatting only — the shown string changes, the SI value
        // stays bit-identical.
        let recordBefore = await core.session.markup(MarkupID(markupID))
        let shownBefore = core.snapshot.markups.first?.primaryField?.displayText
        let setPrecision = try #require(shell.inspectorEditing.onSetDecimalPrecision)
        setPrecision(0)
        #expect(await wait { core.snapshot.units.metricDecimalPlaces == 0 })
        let shownAfter = core.snapshot.markups.first?.primaryField?.displayText
        #expect(shownBefore != shownAfter, "a 20 m length shown to 2 then 0 decimals must change text")
        let recordAfter = await core.session.markup(MarkupID(markupID))
        #expect(recordBefore == recordAfter, "precision must never touch the stored record")

        document.close()
    }

    @Test("Calibrating and drawing a length produces one Quantity Ledger row")
    func measurementReachesTheLedger() async throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)

        // 300 PDF points across is 30 metres in the building: a 1:100 sheet at 72 dpi.
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await core.refresh()

        core.measurement.activate(kind: .length)
        core.measurement.placePoint(PDFPointValue(x: 72, y: 272))
        core.measurement.placePoint(PDFPointValue(x: 372, y: 272))
        // A click is asynchronous because its snap resolve is; the presenter exposes the wait.
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 2)
        #expect(core.measurement.canCommit)
        core.measurement.commitActiveMeasurement()

        #expect(await wait { core.ledger.rowCount == 1 })
        let row = try #require(core.ledger.row(at: 0))
        #expect(row.kind == .measurement)

        // The same 300 points, so the same 30 metres. This is the number that ends up in a tender.
        let csv = LedgerCSVExport.render(presenter: core.ledger)
        #expect(csv.contains("30"), "the ledger row must carry the measured length:\n\(csv)")

        document.close()
    }

    @Test("Ending calibration disarms the toolbar's Calibrate highlight")
    func calibrationHighlightClears() async throws {
        // The toolbar once kept Calibrate highlighted after the flow ended.
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)

        let toolbar = ZenitToolbarModel()
        let canvas = PDFCanvasViewController(core: core, rasterSource: nil, toolbar: toolbar)
        _ = canvas.view
        var calibrationEnded = false
        canvas.onCalibrationEnd = { _ in calibrationEnded = true }

        // The toolbar path: clicking Calibrate arms the tool, then the flow begins.
        toolbar.selectTool(.calibrate)
        canvas.beginCalibration()
        #expect(canvas.isCalibrating)
        #expect(toolbar.activeTool == .calibrate)

        // Escape (or two collected points) leaves calibration; the highlight must follow.
        canvas.endCalibration()
        #expect(!canvas.isCalibrating)
        #expect(toolbar.activeTool == .select, "the Calibrate highlight must not outlive the flow")
        #expect(calibrationEnded, "the window controller's selection-ring sync must be told")

        document.close()
    }

    @Test("Save As from Quick PDF Mode writes a real .zpdfproj and leaves the drawing untouched")
    func createProjectWritesAPackage() async throws {
        let url = try fixtureURL()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalBytes = try Data(contentsOf: url)

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.core != nil })
        #expect(document.mode == .quickPDF)
        // A quick PDF must never autosave into the drawing it was opened from.
        #expect(document.autosavingFileType == nil)

        let destination = directory.appendingPathComponent("Tower.zpdfproj")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("project.sqlite").path))
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("documents/original.pdf").path))
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("documents/working.pdf").path))

        // The original the user opened is byte-for-byte what it was.
        #expect(try Data(contentsOf: url) == originalBytes)
        // And the copy inside the package is the same bytes, read-only.
        let stored = try Data(contentsOf: destination.appendingPathComponent("documents/original.pdf"))
        #expect(stored == originalBytes)
        let permissions = try manager.attributesOfItem(
            atPath: destination.appendingPathComponent("documents/original.pdf").path
        )[.posixPermissions] as? NSNumber
        #expect(((permissions?.uint16Value ?? 0o777) & 0o222) == 0, "the stored original must not be writable")

        #expect(document.mode == .project)
        #expect(document.fileURL == destination)
        #expect(document.autosavingFileType == ZenitAppInfo.projectTypeIdentifier)

        document.close()
    }
}
