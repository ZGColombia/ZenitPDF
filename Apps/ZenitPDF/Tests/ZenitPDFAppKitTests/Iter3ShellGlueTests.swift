import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFServiceWire
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Loop iteration 3, area app-shell-glue: T-005 … T-019. Every test states the old output it
/// fails with. Headless throughout: no window is ordered front, every modal is recorded or
/// answered by injection, every store is a temporary one.
@MainActor
@Suite("Iteration 3 — app shell glue", .appTierSerialised)
struct Iter3ShellGlueTests {

    // MARK: - Helpers

    static func eventually(upTo seconds: Double = 15, _ condition: @MainActor () async -> Bool) async -> Bool {
        await Iter2ShellGlueTests.eventually(upTo: seconds, condition)
    }

    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("it3-shell-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A project of two drawings: the harness's drawing saved as a project, then `added`
    /// dropped at the end of the set. Answers the added drawing's member.
    static func addDrawing(_ harness: Fix2Harness, _ added: URL) async throws -> DrawingSet.Member {
        _ = try await Iter1ShellGlueTests.saveAsProject(harness)
        let end = await harness.core.session.pageOrderIDs.count
        #expect(await harness.document.addDrawingToSet(fileAt: added, at: end))
        await harness.core.commands.settle()
        await harness.core.refresh()
        return try #require(harness.document.drawingSet?.members.last)
    }

    static func line(_ page: ZPDFContracts.PageDescriptor, y: Double) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .length,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: y), PDFPoint(x: 400, y: y)]),
            createdAt: Date(), modifiedAt: Date()
        )
    }

    /// A one-page picture of `text` in large letters, with no text layer: a scanned sheet.
    static func scannedSheet(named name: String, text: String) throws -> URL {
        let directory = try scratch("scan")
        let url = directory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 842, height: 595)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let scale: CGFloat = 3
        let width = Int(mediaBox.width * scale), height = Int(mediaBox.height * scale)
        let bitmap = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        (text as NSString).draw(at: CGPoint(x: 100 * scale, y: 300 * scale), withAttributes: [
            .font: NSFont(name: "Helvetica", size: 40 * scale) ?? NSFont.systemFont(ofSize: 40 * scale),
            .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(bitmap.makeImage())
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: mediaBox)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    // MARK: - T-005

    @Test("T-005: Find Repeated Sheets compares the set — a removed sheet is not counted, an added drawing's sheet is")
    func repeatedSheetsWalkTheSet() async throws {
        let plan = "0.5 w 0 0 0 RG 100 100 m 900 100 l 900 600 l 100 600 l h S 500 100 m 500 600 l S"
        let other = "0.5 w 0 0 0 RG 100 100 m 900 100 l 900 600 l 100 600 l h S 300 100 m 300 600 l S 100 350 m 300 350 l S"
        let a = try AutomationFixtures.writePages(named: "Storeys.pdf", mediaBox: "0 0 1000 700", contents: [plan, other, plan])
        let b = try AutomationFixtures.writePages(named: "Annex.pdf", mediaBox: "0 0 1000 700", contents: [plan])
        let harness = try await Fix2Harness.make("Storeys.pdf", calibrate: false, fixture: a)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let annex = try await Self.addDrawing(harness, b)
        let storeys = try #require(harness.document.drawing).pages
        // Sheet 3 of Storeys leaves the set: it is set aside, not deleted.
        _ = try await harness.core.commands.perform(.setPagesExcluded([storeys[2].id], excluded: true))
        await harness.core.commands.settle()
        let annexSheet = try #require(annex.drawing.pages.first)
        #expect(await harness.core.session.pageDescriptors.map(\.id) == [storeys[0].id, storeys[1].id, annexSheet.id])

        let previous = ProjectWindowController.repeatedSheetsDecision
        defer { ProjectWindowController.repeatedSheetsDecision = previous }
        var asked: [ProjectWindowController.RepeatedSheetGroup] = []
        ProjectWindowController.repeatedSheetsDecision = { prompt, _ in asked.append(prompt.group); return false }
        let groups = await harness.controller.runRepeatedSheets(for: harness.document)
        // Old: [[Storeys 1, Storeys 3]] — the removed sheet fingerprinted and offered as ×2, and
        // the Annex sheet (same linework) never compared.
        #expect(groups.map(\.pageIDs) == [[storeys[0].id, annexSheet.id]])
        #expect(asked.first?.multiplier == 2)
        #expect(!groups.flatMap(\.pageIDs).contains(storeys[2].id))
    }

    @Test("T-005: Prepare This Set files proposals for the sheets of the set, added drawings included, in set order")
    func takeoffAssistantWalksTheSet() async throws {
        let sheet = "BT /F1 8 Tf 700 20 Td (SCALE 1:50) Tj ET 0.5 w 0 0 0 RG 72 72 m 300 72 l S"
        let a = try AutomationFixtures.writePages(named: "Assist A.pdf", mediaBox: "0 0 842 595", contents: [sheet, sheet, sheet])
        let b = try AutomationFixtures.writePages(named: "Assist B.pdf", mediaBox: "0 0 842 595", contents: [sheet])
        let harness = try await Fix2Harness.make("Assist A.pdf", calibrate: false, fixture: a)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let added = try await Self.addDrawing(harness, b)
        let sheets = try #require(harness.document.drawing).pages
        _ = try await harness.core.commands.perform(.setPagesExcluded([sheets[2].id], excluded: true))
        await harness.core.commands.settle()
        let addedSheet = try #require(added.drawing.pages.first)

        _ = await harness.controller.runTakeoffAssistant(for: harness.document)
        let proposals = harness.document.automation.inbox.proposals.filter { $0.kind == .scale }
        // Old: A1, A2 and the removed A3 got a scale proposal each, and the added B1 none.
        #expect(Set(proposals.map(\.pageID)) == [sheets[0].id.rawValue, sheets[1].id.rawValue, addedSheet.id.rawValue],
                "\(proposals.map(\.pageID))")
        // The Inbox sorts by `pageIndex`: the set position, so B1 (PDF index 0) sorts last.
        #expect(proposals.first { $0.pageID == addedSheet.id.rawValue }?.pageIndex == 2)
    }

    // MARK: - T-006

    @Test("T-006: a scanned sheet of an added drawing reads its own drawing's recognised words, never the primary's same-index sheet")
    func recognisedWordsComeFromTheSheetsOwnDrawing() async throws {
        let a = try Self.scannedSheet(named: "Scanned A.pdf", text: "SCALE 1:50")
        let b = try AppTestSupport.writeFixturePDF(named: "Plain B.pdf")
        let harness = try await Fix2Harness.make("Scanned A.pdf", calibrate: false, fixture: a)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let added = try await Self.addDrawing(harness, b)
        #expect(await Self.eventually(upTo: 60) { harness.document.searchIndex != nil })
        let index = try #require(harness.document.searchIndex)
        _ = try await index.recognize(pageIndices: [0], languageIDs: [], skipsPagesWithText: false) { _ in }
        let primarySheet = try #require(harness.document.drawing?.pages.first)
        let addedSheet = try #require(added.drawing.pages.first)
        #expect(primarySheet.index == addedSheet.index, "both sheets are page 0 of their own PDF")

        let primaryLines = await PageTextLoader.lines(document: harness.document, page: primarySheet, region: nil, allowRegionOCR: false)
        #expect(primaryLines.contains { $0.text.contains("SCALE") }, "the control: the scanned sheet's own words — got \(primaryLines.map(\.text))")
        // Old: the added sheet got the primary drawing's page-0 words ("SCALE 1:50"), so a scale
        // was offered and dimension checks read from another drawing.
        let addedLines = await PageTextLoader.lines(document: harness.document, page: addedSheet, region: nil, allowRegionOCR: false)
        #expect(addedLines.isEmpty, "\(addedLines.map(\.text))")
        // The helper the scale offer reads too.
        #expect(await harness.document.recognisedWords(onPage: addedSheet).isEmpty)
        #expect(harness.document.searchIndex(forPage: addedSheet) !== index)
        #expect(harness.document.searchIndex(forPage: primarySheet) === index)
    }

    // MARK: - T-007

    @Test("T-007: a snippet of an added drawing's sheet is taken of that sheet, from that drawing's file")
    func snippetUsesTheSheetsOwnDrawing() async throws {
        let b = try AppTestSupport.writeFixturePDF(named: "Snip B.pdf", pageCount: 2)
        let harness = try await Fix2Harness.make("Snip A.pdf", calibrate: false)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let added = try await Self.addDrawing(harness, b)
        let second = added.drawing.pages[1]
        harness.core.document.goToPage(id: second.id.rawValue)
        #expect(harness.core.document.currentPageID == second.id.rawValue)
        // Old: page index 1 was looked up in the one-page primary drawing — PreparationFailure.noPage.
        let inputs = try await harness.controller.snippetInputs(
            for: harness.document, of: .region(PDFRectValue(x: 60, y: 60, width: 340, height: 240))
        )
        #expect(inputs.page.id == second.id)
        #expect(inputs.drawingURL == added.drawing.url)
        let image = try await SnippetExport.render(inputs, pageSource: inputs.pageSource)
        #expect(image.image.width > 0)
    }

    @Test("T-007, C-09: Mark Area for Redaction on an added drawing's sheet marks it, for that drawing's own file")
    func redactionRefusesAnAddedDrawingsSheet() async throws {
        let b = try AppTestSupport.writeFixturePDF(named: "Redact B.pdf")
        let harness = try await Fix2Harness.make("Redact A.pdf", calibrate: false)
        defer {
            RedactionWorkflow.clear(harness.document, canvas: harness.canvas)
            harness.tearDown()
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        let added = try await Self.addDrawing(harness, b)
        let primarySheet = try #require(harness.document.drawing?.pages.first)
        let addedSheet = try #require(added.drawing.pages.first)

        // The control: on the primary drawing's sheet a box is marked.
        harness.core.document.goToPage(id: primarySheet.id.rawValue)
        harness.controller.beginRedactionMark(for: harness.document)
        let armed = try #require(harness.canvas.onSnippetRegion, "the drag is armed on the primary drawing's sheet")
        armed(PDFRectValue(x: 80, y: 80, width: 50, height: 40))
        #expect(RedactionWorkflow.marks(for: harness.document).count == 1)

        harness.canvas.onSnippetRegion = nil
        harness.core.document.goToPage(id: addedSheet.id.rawValue)
        harness.controller.beginRedactionMark(for: harness.document)
        // C-09 (iteration 4): the added drawing's sheet is marked too — kept by the sheet's
        // identity and applied to that drawing's own file. T-007 refused it with a note; before
        // T-007 the drag was armed and its box silently dropped (the sheet is not in the primary
        // drawing).
        let armedOnAdded = try #require(harness.canvas.onSnippetRegion, "the drag is armed on the added drawing's sheet")
        armedOnAdded(PDFRectValue(x: 60, y: 60, width: 30, height: 30))
        #expect(RedactionWorkflow.marks(for: harness.document).count == 2)
        let jobs = RedactionWorkflow.drawingMarks(for: harness.document)
        #expect(jobs.map(\.source) == [try #require(harness.document.drawing).url, added.drawing.url])
        #expect(jobs.map { $0.marks.map(\.pageIndex) } == [[primarySheet.index], [addedSheet.index]])
    }

    // MARK: - T-008

    @Test("T-008: Export with Markups as a PDF Layer writes every drawing of the set, and never onto an added drawing's file")
    func layeredExportWritesTheSet() async throws {
        let b = try AppTestSupport.writeFixturePDF(named: "Layer B.pdf")
        let harness = try await Fix2Harness.make("Layer A.pdf", calibrate: false)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let added = try await Self.addDrawing(harness, b)
        for (position, page) in await harness.core.session.pageDescriptors.enumerated() {
            _ = try await harness.core.commands.perform(.addMarkup(Self.line(page, y: Double(100 * (position + 1)))))
        }
        await harness.core.commands.settle()
        await harness.core.refresh()

        let out = harness.directory.appendingPathComponent("layered.pdf")
        let outcome = try await harness.controller.writeLayeredDrawing(for: harness.document, to: out)
        // Old: 1 page, 1 marked page — the added drawing and its markup dropped, while the note
        // reported success.
        #expect(PDFDocument(url: out)?.pageCount == 2)
        #expect(outcome.pageCount == 2)
        #expect(outcome.markedPageCount == 2)

        // The added drawing's own file is protected like the primary's.
        let addedFile = added.drawing.url
        let before = try Data(contentsOf: addedFile)
        await #expect(throws: DerivedCopyGuard.Refusal.self) {
            _ = try await harness.controller.writeLayeredDrawing(for: harness.document, to: addedFile)
        }
        #expect(try Data(contentsOf: addedFile) == before)
    }

    // MARK: - T-009

    @Test("T-009: with no project window the application delegate answers the document-free commands, and Stop Processing reaches a running batch")
    func documentFreeCommandsWithNoWindow() async throws {
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        defer { ZenitModalPresenter.reset() }
        func row(_ command: ZenitAppCommand) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
            item.representedObject = command.rawValue
            return item
        }
        let delegate = ZenitApplicationDelegate()
        // The responder chain with no project window ends at the delegate. Old: no responder
        // implemented performZenitCommand(_:) there, so AppKit disabled every one of these rows.
        let application = NSApplication.shared
        let previous = application.delegate
        application.delegate = delegate
        defer { application.delegate = previous }
        if application.keyWindow == nil, application.mainWindow == nil {
            let target = application.target(forAction: #selector(ZenitCommandResponding.performZenitCommand(_:)), to: nil, from: row(.importLedgerJSON)) as AnyObject?
            #expect(target === delegate)
        }
        for command in [ZenitAppCommand.importLedgerJSON, .newFromTemplate, .indexDrawingFolder, .searchDrawingFolder, .forgetDrawingFolder,
                        .installPack, .createPack, .processPDFFiles, .createPDFFromDocuments, .setUpPrintToZenit] {
            #expect(delegate.validateMenuItem(row(command)), "\(command) is disabled with no window")
        }
        // Commands that act on a document stay disabled, and so do the shell's.
        #expect(!delegate.validateMenuItem(row(.exportFlattenedPDF)))
        #expect(!delegate.validateMenuItem(row(.reviewList)))
        let shellRow = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        shellRow.representedObject = ZPDFCommandID.closeTab.rawValue
        #expect(!delegate.validateMenuItem(shellRow))
        #expect(!delegate.validateMenuItem(row(.stopProcessingPDFFiles)), "nothing to stop")

        // Import Zenit JSON… runs with no window: its chooser is asked for, app-modally.
        delegate.performZenitCommand(row(.importLedgerJSON))
        #expect(ZenitModalPresenter.recorded.contains { $0.identifier == ZenitJSONImport.chooserModalIdentifier && !$0.sheeted })

        // A batch started with no window can be stopped with no window.
        let input = try AppTestSupport.writeFixturePDF(named: "Batch T009.pdf")
        let output = try Self.scratch("batch-out")
        defer {
            try? FileManager.default.removeItem(at: input.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: output)
        }
        let slow: @Sendable (URL, URL, RepairWireTransform) async throws -> Void = { _, _, _ in try await Task.sleep(for: .seconds(30)) }
        let started = BatchFileCommand.start(
            inputs: [input], steps: BatchFileProcessor.Steps(), folder: output, beside: false, document: nil, window: nil,
            transform: slow
        )
        #expect(started)
        #expect(delegate.validateMenuItem(row(.stopProcessingPDFFiles)))
        delegate.performZenitCommand(row(.stopProcessingPDFFiles))
        #expect(await Self.eventually(upTo: 10) { !BatchFileCommand.isRunning }, "the run was stopped")
        // Its result, with no tray to note it in, is said in an alert.
        #expect(await Self.eventually { ZenitModalPresenter.didRequest(BatchFileCommand.resultIdentifier) })
    }

    // MARK: - T-010

    @Test("T-010: a scripted template on a saved, calibrated project marks it edited and is not told its scale is not set")
    func scriptedTemplateIsTheMenusApplication() async throws {
        try await R2PlatformAppTests.withScratchStores { _ in
            let harness = try await Fix2Harness.make("T010.pdf")
            defer { harness.tearDown() }
            _ = try await Iter1ShellGlueTests.saveAsProject(harness)
            #expect(await Self.eventually { !harness.document.isDocumentEdited })
            let template = try #require(StarterJobTemplates.all.first)
            let result = try await ZenitScripting.applyTemplate(named: template.name, document: harness.document)
            #expect(result.contains(template.name))
            // Old: false — New from Template's copy never counted the change, so the close review
            // did not offer to save the new units.
            #expect(harness.document.isDocumentEdited)
            // Old: "Started from the template …: The scale is not set: calibrate the drawing
            // before you measure. Save to make it a project." on a calibrated, saved project.
            #expect(!harness.core.document.warnings.contains { $0.id == NewFromTemplate.noteID })
            let note = harness.core.status.snapshot.activeToolNote ?? ""
            #expect(note.hasPrefix("Template “\(template.name)” applied:"), "\(note)")
        }
    }

    // MARK: - T-011

    @Test("T-011: a window's Revision Overlay stacks the sheet that window shows, whichever window has focus")
    func overlayFollowsItsOwnWindow() async throws {
        let harness = try await Fix2Harness.make("T011.pdf", pageCount: 3, calibrate: false)
        defer { harness.tearDown() }
        #expect(await Self.eventually { harness.document.comparePresenter != nil })
        _ = try await harness.document.registerCurrentDrawingAsBaseline()
        let second = try await Iter2ShellGlueTests.openSecondWindow(harness)
        defer { Iter2ShellGlueTests.closeWindows(harness, [second]) }
        let secondCore = try #require(second.windowCore(for: harness.document))
        harness.core.document.goToPage(index: 0)
        secondCore.document.goToPage(index: 2)
        harness.canvas.refresh()
        second.canvasController(for: harness.document)?.refresh()
        #expect(await Self.eventually { harness.core.canvas.viewport.pageIndex == 0 && secondCore.canvas.viewport.pageIndex == 2 })
        // The second window has focus: `document.core` answers for it.
        second.focusThisWindow(on: harness.document)
        #expect(harness.document.core === secondCore)

        let firstPages = harness.controller.overlayPages(for: harness.document)
        #expect(!firstPages.isEmpty)
        // Old: the first window's compositor read `document.overlayPages()`, the focused window's
        // sheet — every revision at page 2 under the first window's sheet 1.
        #expect(firstPages.values.allSatisfy { $0.pageIndex == 0 }, "\(firstPages.values.map(\.pageIndex))")
        // What the old closure returned, run here: the focused window's page.
        #expect(harness.document.overlayPages().values.allSatisfy { $0.pageIndex == 2 })
        #expect(second.overlayPages(for: harness.document).values.allSatisfy { $0.pageIndex == 2 })
        // And its zoom is its own window's.
        let backing = Double(harness.controller.window?.screen?.backingScaleFactor ?? harness.controller.window?.backingScaleFactor ?? 2)
        #expect(harness.controller.overlayRequestedScale(for: harness.document)
                == max(0.05, Double(harness.core.canvas.viewport.zoom) * max(1, backing)))
    }

    // MARK: - T-012

    @Test("T-012: Index a Folder of Drawings… during a rebuild is refused before the panel, and the running run keeps its folder")
    func indexAFolderRefusedWhileIndexing() async throws {
        let fixture = try Iter1FolderIndexTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        try Iter1FolderIndexTests.textPDF(at: other.appendingPathComponent("B-101.pdf"), words: ["ROOF PLAN"])
        let previous = FolderIndexCommand.index
        FolderIndexCommand.index = fixture.index
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in
            request.identifier == FolderIndexCommand.chooseFolderIdentifier ? .urls([other]) : .button(0)
        }
        defer {
            FolderIndexCommand.index = previous
            ZenitModalPresenter.reset()
        }
        var attempted = false
        let report = await fixture.index.rebuild { _, _ in
            guard !attempted else { return }
            attempted = true
            FolderIndexCommand.chooseAndIndex(controller: nil, document: nil)
        }
        #expect(attempted)
        // Old: the open panel, then grant(Other) under the running run — its scope stopped, its
        // catalogue saved for Drawings while Other was granted, and Other never indexed.
        #expect(!ZenitModalPresenter.didRequest(FolderIndexCommand.chooseFolderIdentifier))
        #expect(ZenitModalPresenter.didRequest(FolderIndexCommand.refusalIdentifier))
        #expect(fixture.index.folder?.lastPathComponent == "Drawings")
        #expect(report != nil)
        #expect(fixture.index.isCatalogueCurrent)
        #expect(!(await fixture.index.search("FOUNDATION")).isEmpty)
    }

    @Test("T-012: a grant of another folder during a rebuild stops that run, which keeps nothing")
    func grantDuringRebuildStopsIt() async throws {
        let fixture = try Iter1FolderIndexTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        try Iter1FolderIndexTests.textPDF(at: other.appendingPathComponent("B-101.pdf"), words: ["ROOF PLAN"])
        var granted = false
        let report = await fixture.index.rebuild { _, _ in
            guard !granted else { return }
            granted = true
            fixture.index.grant(other)
        }
        #expect(granted)
        // Old: the run finished and saved a catalogue of Drawings — files it could no longer read
        // in the sandbox — and deleted every index it failed to reread.
        #expect(report == nil)
        #expect(fixture.index.loadCatalogue() == nil)
        // The new folder indexes cleanly afterwards.
        _ = try #require(await fixture.index.rebuild())
        #expect(fixture.index.isCatalogueCurrent)
        #expect(await fixture.index.search("ROOF").first?.fileURL.lastPathComponent == "B-101.pdf")
    }

    // MARK: - T-013

    @Test("T-013: rerunning Process PDF Files beside the originals does not process its own outputs or its report")
    func besideRerunSkipsItsOutputs() async throws {
        let plan = try AppTestSupport.writeFixturePDF(named: "Plan.pdf")
        let folder = plan.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy: @Sendable (URL, URL, RepairWireTransform) async throws -> Void = { input, output, _ in
            try FileManager.default.copyItem(at: input, to: output)
        }
        let first = try await BatchFileProcessor.run(
            inputs: [folder], steps: BatchFileProcessor.Steps(), outputFolder: folder, allowBesideInputs: true, transform: copy
        )
        #expect(first.items.map(\.input.lastPathComponent) == ["Plan.pdf"])
        #expect(first.done == 1)

        let second = try await BatchFileProcessor.run(
            inputs: [folder], steps: BatchFileProcessor.Steps(), outputFolder: folder, allowBesideInputs: true, transform: copy
        )
        // Old: three items — Plan.pdf resumed, "Plan — Processed.pdf" processed again into
        // "Plan — Processed — Processed.pdf", and "Processing report.csv" skipped as "not a PDF".
        #expect(second.items.map(\.input.lastPathComponent) == ["Plan.pdf"], "\(second.items.map(\.input.lastPathComponent))")
        #expect(second.items.first?.status == .skipped("already processed in an earlier run"))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") })
        #expect(names == ["Plan.pdf", "Plan — Processed.pdf", "Processing report.csv"], "\(names)")
    }

    // MARK: - T-014

    @Test("T-014: the saved pictures build the first sheet's scene only and render once; both keep their sizes")
    func savedPicturesRenderTheFirstSheetOnce() async throws {
        let harness = try await Fix2Harness.make("T014.pdf", pageCount: 24, calibrate: false)
        defer { harness.tearDown() }
        let sheets = await harness.core.session.pageDescriptors
        // 125 lines on every sheet, 3 000 in all: the scene builds the old path repeated are
        // what this measures.
        var commands: [DocumentCommand] = []
        for page in sheets {
            for row in 0..<125 { commands.append(.addMarkup(Self.line(page, y: Double(100 + row * 5)))) }
        }
        _ = try await harness.core.commands.performBatch(commands, actionName: "T-014")
        await harness.core.commands.settle()
        await harness.core.refresh()
        let clock = ContinuousClock()

        // The old path, measured: the whole-document job twice (a scene per sheet) and two renders.
        let oldStart = clock.now
        for side in [ZenitPDFProjectDocument.packageThumbnailLongestSide, ZenitPDFProjectDocument.quickLookPreviewLongestSide] {
            let whole = try await FlattenedDrawingExport.job(for: harness.document)
            #expect(whole.pages.count == 24)
            let page = try #require(whole.pages.min(by: { $0.page.index < $1.page.index }))
            let content = await FlattenedDrawingExport.contentSource(for: harness.document, rasterFallbackPages: [page.page])
            _ = PDFReportSheetImages.render(pages: [page], content: content, longestSide: side)
        }
        let oldElapsed = clock.now - oldStart

        let newStart = clock.now
        let pictures = try #require(await harness.document.renderSavedPictures())
        let newElapsed = clock.now - newStart
        // One sheet's scene, not twenty-four.
        let job = try #require(await harness.document.packagePicture()?.job)
        #expect(job.pages.map(\.page.id) == [sheets[0].id])
        #expect(!(job.pages.first?.markups.isEmpty ?? true), "the first sheet's markups are in the picture")
        // 595 × 842 pt: the preview 1131 × 1600, the thumbnail scaled from it to 362 × 512.
        #expect(pictures.preview.width == 1_131 && pictures.preview.height == 1_600)
        #expect(pictures.thumbnail?.width == 362 && pictures.thumbnail?.height == 512)
        print("T-014 measurement (24 sheets, 3000 markups): old two-job two-render path \(oldElapsed), new one-sheet one-render path \(newElapsed)")
    }

    // MARK: - T-015

    @Test("T-015: Import XFDF… says when the file brings nothing new and when it imported; Import Review File… says nothing new")
    func reviewImportsAlwaysSaySomething() async throws {
        let fixture = try AppTestSupport.writeFixturePDF(named: "T015 Plan.pdf")
        let a = try await Fix2Harness.make("T015 Plan.pdf", calibrate: false, fixture: fixture)
        let b = try await Fix2Harness.make("T015 Plan.pdf", calibrate: false, fixture: fixture)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("t015-\(UUID().uuidString).xfdf")
        defer {
            ZenitModalPresenter.reset()
            a.tearDown(); b.tearDown()
            try? FileManager.default.removeItem(at: out)
        }
        let page = try #require(a.core.snapshot.pages.first)
        let cloud = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(a.core.snapshot.documentID), pageID: PageID(page.id),
            kind: .cloud, comment: "Revise", author: "Ada",
            geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date()
        )
        try await a.core.commands.perform(.addMarkup(cloud))
        #expect(await ReviewXFDFFlow.write(document: a.document, to: out))
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in
            request.identifier == ReviewAnnotationImportFlow.previewIdentifier ? .button(0) : .dismissed
        }
        // Into the copy it came from: nothing new. Old: .nothingToImport and no note at all.
        #expect(await ReviewXFDFFlow.importFile(out, into: a.document) == .nothingToImport)
        #expect(a.core.document.warnings.contains { $0.title == "Nothing new in “\(out.lastPathComponent)”" },
                "\(a.core.document.warnings.map(\.title))")
        // Into the other copy: imported, and said. Old: imported with no note.
        #expect(await ReviewXFDFFlow.importFile(out, into: b.document) == .imported(markups: 1, replies: 0, statusChanges: 0))
        #expect(b.core.document.warnings.contains { $0.title == "Imported the review from “\(out.lastPathComponent)”" })

        // A review file that brings nothing new. Old: .nothingToImport and silence.
        _ = try await Iter1ShellGlueTests.saveAsProject(a, name: "T015.zpdfproj")
        let reviewFile = a.directory.appendingPathComponent("T015.zpdfreview")
        #expect(await ReviewFileFlow.write(document: a.document, to: reviewFile))
        #expect(await ReviewFileFlow.importFile(reviewFile, into: a.document) == .nothingToImport)
        let note = try #require(a.core.document.warnings.first { $0.id == ReviewFileFlow.noteID })
        #expect(note.title == "Nothing new in “T015.zpdfreview”")
    }

    // MARK: - T-016

    @Test("T-016: View ▸ Tint Markups by Author carries a checkmark while the tint is on")
    func tintRowShowsItsState() async throws {
        let harness = try await Fix2Harness.make("T016.pdf", calibrate: false)
        defer { harness.tearDown() }
        let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZenitAppCommand.tintByAuthor.rawValue
        #expect(harness.controller.validateMenuItem(item))
        #expect(item.state == .off)
        AuthorTint.toggle(document: harness.document)
        #expect(harness.core.canvas.tintsByAuthor)
        #expect(harness.controller.validateMenuItem(item))
        // Old: .off whatever the tint — the row had no state and no state title (LT-12).
        #expect(item.state == .on)
        AuthorTint.toggle(document: harness.document)
        #expect(harness.controller.validateMenuItem(item))
        #expect(item.state == .off)
    }

    // MARK: - T-017

    @Test("T-017: a synced project whose files could not be downloaded is refused in words; a missing history file does not stop it")
    func undownloadedMembersRefuseTheOpen() async throws {
        let package = try Self.scratch("synced").appendingPathComponent("Synced.zpdfproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        for member in ["manifest.json", "project.sqlite", "documents/working.pdf", "versions/latest/manifest.json", "thumbnails/package.png"] {
            let url = package.appendingPathComponent(member)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let previous = SyncedFolderSafety.download
        defer { SyncedFolderSafety.download = previous }
        // This Mac is offline: nothing evicted can be fetched.
        SyncedFolderSafety.download = { _ in false }

        // Old: materialize's failures were dropped and the open went on to read a placeholder.
        do {
            try await SyncedFolderSafety.materializeForOpen(package, isEvicted: { $0.lastPathComponent == "working.pdf" })
            Issue.record("the open was not refused")
        } catch let refusal as SyncedFolderSafety.MembersNotDownloaded {
            #expect(refusal == SyncedFolderSafety.MembersNotDownloaded(projectName: "Synced", memberCount: 1))
            #expect(refusal.localizedDescription == "1 file of “Synced” is not downloaded yet.")
            #expect(refusal.recoverySuggestion?.hasSuffix("Nothing was changed.") == true)
        }
        do {
            try await SyncedFolderSafety.materializeForOpen(package, isEvicted: { ["working.pdf", "project.sqlite"].contains($0.lastPathComponent) })
            Issue.record("the open was not refused")
        } catch let refusal as SyncedFolderSafety.MembersNotDownloaded {
            #expect(refusal.localizedDescription == "2 files of “Synced” are not downloaded yet.")
        }
        // Only the version history and the Finder picture left in the cloud: the open reads
        // neither, and goes ahead.
        try await SyncedFolderSafety.materializeForOpen(package, isEvicted: {
            $0.path.contains("/versions/") || $0.path.contains("/thumbnails/")
        })
    }

    // MARK: - T-018

    @Test("T-018: Review List, Command Palette and Share Last Export are disabled while the drawing is still opening")
    func rowsWaitForTheLoadedTakeoff() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "T018.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        final class Gate { var release: CheckedContinuation<Void, Never>? }
        let gate = Gate()
        document.loadStageHook = { stage, _ in
            guard stage == .started else { return }
            await withCheckedContinuation { gate.release = $0 }
        }
        document.startLoadingIfNeeded()
        Fix2Harness.forgetStoredWindowLayouts()
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        defer {
            // Never leave the load parked at the hook, whatever failed above.
            let parked = gate.release
            gate.release = nil
            parked?.resume()
            document.close()
        }
        #expect(await Self.eventually { gate.release != nil })
        let opening = ZenitAppCommandWindowState(controller: controller)
        #expect(opening.hasActiveDocument && !opening.hasLoadedCore, "the drawing is still opening")
        for command in [ZenitAppCommand.reviewList, .commandPalette, .shareLastExport, .sendProject] {
            // Old: enabled (rule .activeDocument), and choosing it did nothing.
            #expect(!ZenitAppCommandTable.validate(command, item: nil, state: opening), "\(command)")
        }
        #expect(ZenitAppCommandRule.activeDocument.isSatisfied(by: opening), "the old rule, in this state: enabled")
        let parked = gate.release
        gate.release = nil
        parked?.resume()
        #expect(await Self.eventually { document.core != nil })
        let loaded = ZenitAppCommandWindowState(controller: controller)
        for command in [ZenitAppCommand.reviewList, .commandPalette, .shareLastExport, .sendProject] {
            #expect(ZenitAppCommandTable.validate(command, item: nil, state: loaded), "\(command)")
        }
    }

    // MARK: - T-019

    @Test("T-019: the Takeoff Assistant Inbox names a sheet as it is named now, not as when the panel opened")
    func inboxHeadersFollowSheetNames() async throws {
        let harness = try await Fix2Harness.make("T019.pdf", calibrate: false)
        defer {
            AssistantInboxWindow.forget(harness.controller)
            harness.tearDown()
        }
        let page = try #require(harness.document.drawing?.pages.first)
        let panel = AssistantInboxWindow.present(for: harness.controller, document: harness.document)
        let host = try #require(panel.contentViewController as? NSHostingController<AssistantInboxView>)
        let before = host.rootView.pageLabel(page.id.rawValue)
        #expect(before != "A-101")
        _ = try await harness.core.commands.perform(.setSheetIdentities(
            [page.id: SheetIdentity(number: "A-101", title: "Ground floor", source: .titleBlockText)], overwriteManual: false
        ))
        await harness.core.commands.settle()
        await harness.core.refresh()
        // The same panel, reused for the drawing's lifetime. Old: the header captured when the
        // panel was made — "\(before)".
        #expect(AssistantInboxWindow.present(for: harness.controller, document: harness.document) === panel)
        #expect(host.rootView.pageLabel(page.id.rawValue) == "A-101")
    }
}
