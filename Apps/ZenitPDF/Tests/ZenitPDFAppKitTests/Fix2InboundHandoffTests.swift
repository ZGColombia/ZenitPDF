import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFQuantityLedger
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// The application halves of fixes that landed in other packages (fix round 2): each test pins
/// the app-side wiring of a change shipped elsewhere.
@MainActor
@Suite(.appTierSerialised)
struct Fix2InboundHandoffTests {

    // MARK: - BH-079 (persistence + ledger)

    @Test("BH-079: print and flatten draw the complete appearance first, and name only pages that fell back")
    func appearanceSourceIsPreferred() async throws {
        let harness = try await Fix2Harness.make("BH079.pdf", calibrate: false)
        defer { harness.tearDown() }
        let content = await FlattenedDrawingExport.contentSource(for: harness.document)
        // Old: a CGPDFPageContentSource — the content stream only, no annotation appearances.
        let appearance = try #require(content as? AppearanceContentSource)
        #expect(appearance.fallbackPages.isEmpty)
        let notes = await FlattenedDrawingExport.omissionNotes(for: harness.document, content: content)
        #expect(notes.isEmpty, "a drawing whose every page drew completely carries no omission note")
        let url = harness.directory.appendingPathComponent("Flat.pdf")
        let report = try await harness.controller.writeDrawing(.flattened, for: harness.document, to: url)
        #expect(report.pagesWithoutUnderlay.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - BH-069 (services)

    @Test("BH-069: after the password unlocks a protected drawing, Vector Snap is built, and the password leaves with the document")
    func protectedDrawingGetsVectorSnap() async throws {
        let password = "zenit-bh069"
        let url = try AppTestSupport.writeLockedFixturePDF(password: password)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let previousPrompt = ZenitPDFProjectDocument.passwordPrompt
        ZenitPDFProjectDocument.passwordPrompt = { _ in password }
        defer { ZenitPDFProjectDocument.passwordPrompt = previousPrompt }
        let document = try AppTestSupport.makeDocument(opening: url)
        var closed = false
        defer { if !closed { document.close() } }
        #expect(await AppTestSupport.wait { document.core != nil && !document.isLoading })
        #expect(document.drawingPassword == password, "kept in memory for the extraction requests")
        // Old: the extraction request carried no password, the service refused the encrypted
        // file, and the status bar said Vector Snap is not available on a protected drawing.
        let core = try #require(document.core)
        #expect(await AppTestSupport.wait(upTo: 30) { document.firstPageSnapIndexResult != nil })
        let result = try #require(document.firstPageSnapIndexResult)
        #expect(result.failureReason == nil, "extraction failed: \(result.failureReason ?? "")")
        #expect(result.extraction?.primitives.isEmpty == false, "the drawing's linework was not extracted")
        #expect(result.availability?.allowsVectorCandidates == true)
        #expect(core.status.snapshot.geometryIndexStatus == .ready)
        await document.shutDownStorage()
        #expect(document.drawingPassword == nil, "the password is dropped with the drawing")
        document.close()
        closed = true
    }

    // MARK: - IM-023 (app core)

    @Test("IM-023: Edit ▸ Lock and Hide act on the selection through the bus, each one ⌘Z")
    func lockAndHideFromTheMenu() async throws {
        let harness = try await Fix2Harness.make("IM023.pdf")
        defer { harness.tearDown() }
        let record = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 10)])
        }
        harness.core.canvas.select(markupIDs: [record.id.rawValue], additive: false)
        func item(_ command: ZenitAppCommand) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
            item.representedObject = command.rawValue
            return item
        }
        let lock = item(.toggleLockSelection)
        // Old: no command reached DocumentCommand.setLocked / setHidden from anywhere in the app.
        #expect(harness.controller.validateMenuItem(lock))
        #expect(lock.title == "Lock Selection")
        harness.controller.performZenitCommand(lock)
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.first?.locked == true })
        _ = harness.controller.validateMenuItem(lock)
        #expect(lock.title == "Unlock Selection")
        harness.document.undoManager?.undo()
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.first?.locked == false })

        harness.controller.performZenitCommand(item(.hideSelection))
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.first?.hidden == true })
        // Waited for, not read once: the selection is cleared in the same task after the bus
        // returns, and the snapshot can publish `hidden` a turn earlier (flaked under load).
        #expect(await AppTestSupport.wait { harness.core.canvas.selectedMarkupIDs.isEmpty },
                "a hidden markup does not stay selected")
        let show = item(.showHiddenMarkups)
        #expect(harness.controller.validateMenuItem(show))
        harness.controller.performZenitCommand(show)
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.first?.hidden == false })
    }

    // MARK: - IM-005 (persistence + app core)

    @Test("IM-005: a verified project's working PDF is not hashed again — the verdict's digest is reused")
    func verifiedDigestIsReused() async throws {
        let harness = try await Fix2Harness.make("IM005.pdf", calibrate: false)
        let package = harness.directory.appendingPathComponent("Verified.zpdfproj")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            harness.document.save(to: package, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        await harness.document.shutDownStorage()
        harness.document.close()
        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        defer {
            reopened.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        #expect(await AppTestSupport.wait { reopened.core != nil })
        let working = package.appendingPathComponent("documents/working.pdf")
        let known = try #require(await ZenitPDFProjectDocument.verifiedWorkingDigest(
            of: reopened.projectPackage, workingURL: working
        ))
        // Old: nil was passed and the provider hashed the file a second time.
        #expect(known == reopened.drawing?.digest, "the reused digest is the file's own")
        #expect(await ZenitPDFProjectDocument.verifiedWorkingDigest(of: nil, workingURL: working) == nil)
    }

    // MARK: - BH-092 (app core)

    @Test("BH-092: a Scale Region's summary carries the page's /UserUnit")
    func regionScaleCarriesUserUnit() async throws {
        let harness = try await Fix2Harness.make("BH092.pdf", calibrate: false)
        defer { harness.tearDown() }
        let page = try #require(harness.document.drawing?.pages.first)
        #expect(harness.document.pageUserUnit(for: page.id.rawValue) == page.userUnit)
        #expect(harness.document.pageUserUnit(for: UUID()) == 1)
    }

    // MARK: - IM-073 (persistence)

    @Test("IM-073: the thumbnail disk tier is used by the app bundle only, never by a test process")
    func diskThumbnailsStayOutOfTests() {
        #expect(PageRasterSource.thumbnailDiskCache == nil)
    }

    // MARK: - IM-230 (workflows)

    @Test("IM-230: Revision Compare reads difference areas in the project's unit at the page scale")
    func compareAreaIsInProjectUnits() throws {
        // 1 pt = 0.01 m on both axes → 1 pt² = 0.0001 m².
        let scale = ScaleSummary(
            id: UUID(), name: "1:100", displayString: "1:100", isUniform: true,
            sx: 0.01, sy: 0.01, unit: .metre, version: 1, locked: false
        )
        let format = ProjectWindowController.projectAreaFormatter(scale: scale, unit: .squareMetre, decimals: 2)
        let text = try #require(format(20_000))
        #expect(text.hasSuffix("m²") && text.contains("2"))
        #expect(ProjectWindowController.projectAreaFormatter(scale: nil, unit: .squareMetre, decimals: 2)(100) == nil,
                "an uncalibrated page keeps the pt² reading")
    }

    // MARK: - IM-012 (ledger + app core)

    @Test("IM-012: the ledger screen renders numbers through the aggregation layer's locale")
    func ledgerScreenSharesTheExportFormatter() {
        LedgerNumberComposition.install()
        let locale = Locale(identifier: "sv_SE")
        let value = Decimal(string: "12345.678")!
        let screen = LedgerNumberFormatting.string(value, fractionDigits: 2, locale: locale)
        let export = LedgerNumberLocale.forLocale(locale).string(
            LedgerNumberFormatting.rounded(value, fractionDigits: 2), decimalPlaces: 2
        )
        #expect(screen == export)
    }

    // MARK: - IM-154 (workflows)

    @Test("IM-154: a Tool Library edit is one ⌘Z on the document's undo stack, and ⇧⌘Z redoes it")
    func toolLibraryEditsAreUndoable() throws {
        let preset = ToolPresetSummary(
            id: UUID(), name: "Wall", category: "Walls", panel: .myTools,
            markupKind: .measurement, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1),
            defaultSubject: "Wall"
        )
        let model = ToolLibraryEditingModel(presets: [preset])
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.onUndoableChange = { [weak model] step in
            guard let model else { return }
            WorkflowSheet.registerToolLibraryUndo(step, model: model, undoManager: undoManager)
        }
        undoManager.beginUndoGrouping()
        model.delete(id: preset.id)
        model.clearPendingDeletion()
        undoManager.endUndoGrouping()
        #expect(model.presets.isEmpty)
        #expect(undoManager.canUndo, "old: onUndoableChange had no host and nothing was registered")
        undoManager.undo()
        #expect(model.presets.map { $0.id } == [preset.id])
        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(model.presets.isEmpty)
    }

    // MARK: - IM-152 (workflows)

    @Test("IM-152: a recognition run sent to the background reports its progress in the status bar")
    func backgroundRecognitionIsReported() async throws {
        let harness = try await Fix2Harness.make("IM152.pdf", calibrate: false)
        defer { harness.tearDown() }
        let pages = harness.core.snapshot.pages
        let model = harness.controller.makeOCRRunModel(for: harness.document, pages: pages)
        // Old: nothing installed the hook, so the sheet offered no Continue in Background.
        #expect(model.onContinueInBackground != nil)
        #expect(ProjectWindowController.backgroundRecognitionNote(model).hasPrefix("Reading text in the background"))
    }

    // MARK: - IM-209 (workflows)

    @Test("IM-209: a refused region delete's Show Measurements finds the markups the region measures")
    func regionInUseRevealsItsMarkups() async throws {
        let harness = try await Fix2Harness.make("IM209.pdf")
        defer { harness.tearDown() }
        let region = ScaleRegionID(UUID())
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        var record = MarkupRecord(
            id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id,
            kind: .measurement, tool: .length, subject: "",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 10)]),
            createdAt: Date(), modifiedAt: Date()
        )
        record.scaleRegionID = region
        _ = try? await harness.core.commands.perform(.addMarkup(record))
        await harness.settle()
        let found = await ZenitPDFProjectDocument.markupIDs(measuredBy: region.rawValue, core: harness.core)
        let stored = await harness.records().first { $0.id == record.id }
        #expect(found == (stored?.scaleRegionID == region ? [record.id.rawValue] : []))
        #expect(harness.document.onZoomToSelection != nil, "the reveal has a canvas to fit")
    }

    // MARK: - IM-018 (workflows)

    @Test("IM-018: the calibration prompt reads feet and inches, and refuses zero")
    func calibrationEntryIsValidated() throws {
        let entry = try #require(CalibrationPrompt.parse("12' 6\"", unit: .foot))
        #expect(entry.length == 150 && entry.unit == .inch)
        #expect(CalibrationPrompt.parse("0", unit: .metre) == nil)
        #expect(CalibrationPrompt.parse("-3", unit: .metre) == nil)
    }
}
