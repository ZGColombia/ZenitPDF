import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// The join, not the parts: an artwork a person imports reaches a stamp a person can see, and a
/// stamp a person turns stays turned.
///
/// The stamp-artwork defect survived a change that believed it had shipped artwork, and the reason is in
/// this file's name. The importer was proved. The store was proved. The renderer's scenes were
/// proved. Nothing proved that a placed stamp on the shipping canvas drew any of it — and it did
/// not, for the smallest possible reason: `PDFCanvasViewController.resolveArtwork(for:)` read
/// `record.symbol?.artworkDigest` and never `record.stamp?.artworkDigest`, so the store was
/// never asked for a stamp's picture at all.
///
/// So every test here goes through a shipping object: the real `ZenitPDFProjectDocument`, the
/// real `ProjectWindowController`, the real `PDFCanvasViewController`, the real command bus, and
/// — for the rotation — a real save and a real reopen.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct StampArtworkCanvasWiringTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    private func openWindow(
        on url: URL
    ) async throws -> (document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await wait { document.core != nil && document.shell != nil })
        controller.window?.layoutIfNeeded()
        return (document, controller)
    }

    private func saveAsProject(
        _ document: ZenitPDFProjectDocument,
        to destination: URL,
        operation: NSDocument.SaveOperationType = .saveAsOperation
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: operation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Places one stamp on the first page through the shipping command bus.
    @discardableResult
    private func placeStamp(
        in document: ZenitPDFProjectDocument,
        digest: String?,
        kind: ZPDFContracts.StampArtworkKind,
        rotation: Double = 0,
        at point: PDFPoint = PDFPoint(x: 200, y: 300)
    ) async throws -> MarkupID {
        let core = try #require(document.core)
        let page = try #require(core.snapshot.pages.first)
        let pageID = PageID(page.id)
        let id = MarkupID(UUID())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        _ = try await core.commands.perform(.addMarkup(MarkupRecord(
            id: id,
            documentID: DocumentID(core.snapshot.documentID),
            pageID: pageID,
            kind: .stamp,
            subject: "Review",
            geometry: MeasurementGeometry(pageID: pageID, points: [point]),
            stamp: StampInstance(
                templateID: UUID(),
                templateName: "Approved",
                artworkDigest: digest,
                artworkKind: kind,
                widthPoints: 120,
                heightPoints: 48,
                rotationDegrees: rotation,
                fields: [StampFieldValue(kind: .date, resolvedText: "2026-08-25")],
                resolvedAt: now
            ),
            createdAt: now,
            modifiedAt: now
        )))
        await core.refresh()
        return id
    }

    // MARK: - 1. The artwork reaches the canvas

    @Test("An imported seal is on the canvas's stamp, not only in the artwork store")
    func importedArtworkReachesThePlacedStamp() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Stamp Artwork.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (document, controller) = try await openWindow(on: url)
        defer { document.close() }
        try await saveAsProject(
            document, to: directory.appendingPathComponent("StampArtwork.zpdfproj")
        )

        // The import the preset editor's sheet runs, through the document's own single door.
        let outcome = await document.importPresetArtwork(.pdfPage(url: url, pageIndex: 0))
        guard case let .imported(descriptor) = outcome else {
            Issue.record("the fixture page was refused: \(outcome)")
            return
        }
        #expect(descriptor.kind == .vector)

        try await placeStamp(in: document, digest: descriptor.digest, kind: .vector)

        let canvas = try #require(controller.canvasController(for: document))
        canvas.refresh()
        await canvas.settleScene()

        let shape = try #require(
            canvas.canvasShapes.first { $0.stamp != nil },
            "the placed stamp never reached the canvas scene"
        )
        let stamp = try #require(shape.stamp)
        let artwork = try #require(
            stamp.artwork,
            "the canvas drew the stamp without its artwork — the digest was never resolved"
        )
        #expect(artwork.isEmpty == false)
        #expect(artwork.kind == .vector)
        #expect(artwork.isWellFormed)
        #expect(stamp.artworkKind == .vector)
    }

    @Test("A digest the project no longer has leaves the stamp visible, not blank")
    func aMissingDigestFallsBackVisibly() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Stamp Missing.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (document, controller) = try await openWindow(on: url)
        defer { document.close() }
        try await saveAsProject(
            document, to: directory.appendingPathComponent("StampMissing.zpdfproj")
        )

        try await placeStamp(
            in: document,
            digest: String(repeating: "0", count: 64),
            kind: .vector
        )
        let canvas = try #require(controller.canvasController(for: document))
        canvas.refresh()
        await canvas.settleScene()

        let shape = try #require(canvas.canvasShapes.first { $0.stamp != nil })
        #expect(shape.stamp?.artwork == nil, "there is no row for that digest")
        #expect(shape.strokes.isEmpty == false, "the frame must still be drawn")
        #expect(shape.stamp?.lines == ["2026-08-25"], "and the frozen text with it")
    }

    // MARK: - 2. The rotation handle

    @Test("Dragging the rotation knob on the shipping canvas turns the stamp, and it persists")
    func theRotationHandleTurnsAStampThatSurvivesAReopen() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Stamp Rotation.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("StampRotation.zpdfproj")

        let (document, controller) = try await openWindow(on: url)
        try await saveAsProject(document, to: destination)

        let core = try #require(document.core)
        let markupID = try await placeStamp(
            in: document, digest: nil, kind: .none, at: PDFPoint(x: 200, y: 300)
        )
        let canvas = try #require(controller.canvasController(for: document))
        core.canvas.select(markupIDs: [markupID.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()

        let placement = try #require(canvas.canvasShapes.first { $0.stamp != nil }?.stamp)
        #expect(placement.rotationDegrees == 0)

        // Where the knob actually is, asked of the shipping controller rather than computed
        // here — a test that works out the knob's position for itself proves its own
        // arithmetic and not the canvas's.
        let zoom = core.canvas.viewport.zoom
        let knob = placement.rotationHandlePoint(
            gapPoints: Double(CanvasPageView.stampRotationHandleGapViewPoints) / zoom
        )
        #expect(
            canvas.stampRotationHandle(at: knob) == markupID.rawValue,
            "the knob is not grabbable where it is drawn"
        )
        #expect(
            canvas.stampRotationHandle(at: PDFPointValue(x: 200, y: 300)) == nil,
            "the middle of the stamp is a move, not a turn"
        )

        // Press on the knob, drag to the left of the anchor, release: a quarter turn.
        canvas.beginSelectDrag(at: knob)
        canvas.updateSelectDrag(to: PDFPointValue(x: 100, y: 300))
        canvas.endSelectDrag(at: PDFPointValue(x: 100, y: 300))

        func storedRotation(_ environment: AppCoreEnvironment) async -> Double? {
            await environment.session.markup(markupID)?.stamp?.rotationDegrees
        }

        #expect(await AppTestSupport.wait(upTo: 60) { true })
        var rotated: Double?
        for _ in 0..<600 {
            rotated = await storedRotation(core)
            if let rotated, rotated > 89 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            abs((rotated ?? 0) - 90) < 1e-6,
            "the drag never reached the command bus: \(String(describing: rotated))"
        )

        // One undo puts it back — the rotation is a command, not a write around the session.
        core.commands.undoManager.undo()
        var undone: Double?
        for _ in 0..<600 {
            undone = await storedRotation(core)
            if undone == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(undone == 0, "Rotate Stamp is not undoable: \(String(describing: undone))")
        core.commands.undoManager.redo()
        var redone: Double?
        for _ in 0..<600 {
            redone = await storedRotation(core)
            if let redone, redone > 89 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs((redone ?? 0) - 90) < 1e-6, "redo lost the rotation")

        // Save, close, reopen: the angle is on the record and in the project.
        try await saveAsProject(document, to: destination, operation: .saveOperation)
        document.close()
        // The package's own shutdown is asynchronous, and reopening the same package before it
        // has finished is a second writer on one SQLite file.
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        // **No modal reaches the screen from this test.** Modals must be injectable: an earlier
        // run of this very test crashed with the package open, and its reopen raised
        // "StampRotation.zpdfproj was not closed properly". The crash is
        // fixed above (`drainStorageShutdowns`), and the seam is belt as well as braces: if the
        // marker is ever armed again, the reopen recovers silently instead of asking.
        RecoveryPrompt.decisionOverride = .recover
        defer { RecoveryPrompt.decisionOverride = nil }

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: destination, ofType: ZenitAppInfo.projectTypeIdentifier)
        // No window controllers here on purpose — this is a reopen, not a second window on
        // screen — so the load has to be started by hand, exactly as
        // `AppTestSupport.makeDocument(opening:)` does it.
        reopened.startLoadingIfNeeded()
        defer { reopened.close() }
        #expect(await wait { reopened.core != nil && !reopened.isLoading })
        #expect(reopened.loadFailure == nil)
        let reopenedCore = try #require(reopened.core)
        #expect(await wait { reopenedCore.snapshot.markups.contains { $0.id == markupID.rawValue } })
        let restored = try #require(await reopenedCore.session.markup(markupID))
        #expect(
            abs((restored.stamp?.rotationDegrees ?? 0) - 90) < 1e-6,
            "the rotation did not survive save and reopen: \(String(describing: restored.stamp?.rotationDegrees))"
        )
    }

    // MARK: - 3. The multi-page import chooser

    @Test("A multi-page PDF is inspected before import, and the chosen page is the one compiled")
    func aMultiPagePDFOffersItsPages() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Three Pages.pdf", pageCount: 3)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (document, controller) = try await openWindow(on: url)
        defer { document.close() }
        try await saveAsProject(
            document, to: directory.appendingPathComponent("ThreePages.zpdfproj")
        )

        let sheet = try #require(controller.presentToolLibrary(for: document))
        defer { controller.window?.endSheet(sheet.window) }
        let importArtwork = try #require(sheet.model.onImportArtwork)

        // What the sheet asks first, through the hook the shipping window installs.
        let inspection = await importArtwork(.inspectPDF(url: url))
        guard case let .inspected(summary) = inspection else {
            Issue.record("the shipping handler cannot inspect a PDF: \(inspection)")
            return
        }
        #expect(summary.pageCount == 3, "the import would have taken page 1 and said nothing")
        #expect(summary.offersPageChoice)
        #expect(summary.fileName == url.lastPathComponent)

        // And the coordinator the editor sheet owns turns that into the page the person chose.
        let coordinator = ArtworkImportCoordinator()
        coordinator.importArtwork = importArtwork
        var adopted: StampArtworkDescriptor?
        coordinator.onImported = { adopted = $0 }
        await coordinator.choosePDF(at: url)
        #expect(coordinator.pendingPDF?.summary.pageCount == 3)
        coordinator.pageNumber = 3
        await coordinator.confirm()

        let descriptor = try #require(adopted, "the chosen page was not imported")
        #expect(descriptor.sourcePageIndex == 2, "page 3 of 3 is index 2, not index 0")
    }

    @Test("The bridge's own inspection agrees with the file")
    func theBridgeCountsThePages() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Two Pages.pdf", pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let inspection = try StampArtworkImporter().inspectPDF(at: url)
        #expect(inspection.pageCount == 2)
        #expect(inspection.offersPageChoice)
        #expect(inspection.fileName == "Two Pages.pdf")
    }
}
