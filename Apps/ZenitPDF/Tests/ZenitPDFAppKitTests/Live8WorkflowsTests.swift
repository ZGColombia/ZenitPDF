import AppKit
import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Workflow-sheet regressions (l8-workflows): the workflow sheets, driven as a person would — the folder
/// search, Name Sheets, Link Sheet References, Add Revision, Revision Compare, the batch sheets,
/// Snippet of Region, Fill Form Fields, Apply Scale to Pages and the Review List. Every test
/// starts where a person starts (a menu command, the shipping model or the window
/// controller) and no window or sheet reaches the screen: panels are answered by
/// `ZenitModalPresenter`'s injected handler and review sheets by their injectable presenters.
@MainActor
@Suite("Workflow sheets", .appTierSerialised, .serialized)
struct Live8WorkflowsTests {

    // MARK: - L-41 / L-42: Search Indexed Drawings

    @Test("L-41: a folder search hit is selected, and Open, Return and double-click open it")
    func folderSearchHitsOpen() async throws {
        let fixture = try Iter1FolderIndexTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try #require(await fixture.index.rebuild())
        let model = FolderSearchModel(index: fixture.index, folderName: "Drawings")
        var opened: [FolderIndex.Hit] = []
        model.onOpen = { opened.append($0) }
        // Old: nothing selected and nothing to open with — the rows were plain buttons in an
        // unselectable list and there was no Open button, no Return and no double-click.
        #expect(!model.canOpen)
        model.query = "elevation"
        await model.search()
        let hits = model.results.flatMap(\.hits)
        #expect(hits.count == 2)
        // The first hit is selected as soon as the results land, so Open has a target.
        #expect(model.selectedHitID == hits[0].id)
        #expect(model.canOpen)
        model.openSelected()
        #expect(opened.map(\.id) == [hits[0].id])
        // Return or double-click on the second row: the list's primary action on its selection.
        model.open(id: hits[1].id)
        #expect(opened.map(\.id) == [hits[0].id, hits[1].id])
        #expect(model.selectedHitID == hits[1].id)
        #expect(model.selectedHit?.pageLabel == hits[1].pageLabel)
        // A search that no longer lists the selection does not keep it.
        model.query = "foundation"
        await model.search()
        #expect(model.selectedHitID == model.results.first?.hits.first?.id)
    }

    @Test("L-42: the folder search summary is singular for one hit in one drawing")
    func folderSearchSummaryPluralises() {
        // Old: "1 hits in 1 drawings."
        #expect(FolderSearchModel.summary(hits: 1, drawings: 1) == "1 hit in 1 drawing.")
        #expect(FolderSearchModel.summary(hits: 3, drawings: 2) == "3 hits in 2 drawings.")
        #expect(FolderSearchModel.summary(hits: 2, drawings: 1) == "2 hits in 1 drawing.")
    }

    // MARK: - L-53 / L-54: Name Sheets from Title Block

    /// A Swedish title block: the number cell prints its label "DOKUMENTNUMMER" above the number,
    /// and the cell under the title prints "RITNINGSKATEGORI" — both inside the boxes drawn.
    static func labelledSheet(_ number: String, _ title: String) -> String {
        "BT /F1 6 Tf 995 68 Td (DOKUMENTNUMMER) Tj ET BT /F1 14 Tf 1000 48 Td (\(number)) Tj ET "
            + "BT /F1 10 Tf 1000 106 Td (\(title)) Tj ET BT /F1 5 Tf 995 94 Td (RITNINGSKATEGORI) Tj ET "
            + "1 w 100 100 m 500 100 l S"
    }

    @Test("L-53/L-54: reading says so at once, the boxes' printed labels are left out, and the note goes when the review opens")
    func nameSheetsShowsProgressAndStripsLabels() async throws {
        let url = try AutomationFixtures.writePages(named: "L54 Set.pdf", mediaBox: "0 0 1191 842", contents: [
            Self.labelledSheet("A-00-0-001", "VII TAKPLAN DEMO 1"), Self.labelledSheet("A-00-0-002", "VII TAKPLAN DEMO 2")
        ])
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let canvas = try #require(controller.canvasController(for: document))

        let previous = ProjectWindowController.sheetNameReviewPresenter
        defer { ProjectWindowController.sheetNameReviewPresenter = previous }
        var captured: SheetNameReviewModel?
        ProjectWindowController.sheetNameReviewPresenter = { model, _ in
            captured = model
            return {}
        }

        controller.beginSheetNaming(for: document)
        canvas.onSnippetRegion?(PDFRectValue(x: 990, y: 40, width: 110, height: 35))
        #expect(core.status.snapshot.activeToolNote == "Now drag a box around the sheet title, or press Esc to use the number only.")
        canvas.onSnippetRegion?(PDFRectValue(x: 990, y: 92, width: 180, height: 28))
        // Old: the note went on asking for the title box for the whole reading, and the canvas
        // kept the title handler, so later drags looked ignored.
        #expect(core.status.snapshot.activeToolNote == "Reading the sheet names…")
        #expect(canvas.onSnippetRegion == nil && canvas.onSnippetRegionCancelled == nil)
        // A second Name Sheets while the reading runs is answered in words, not started twice.
        controller.beginSheetNaming(for: document)
        #expect(core.status.snapshot.activeToolNote == ProjectWindowController.sheetNamingStartedNote)

        #expect(await AppTestSupport.wait(upTo: 20) { captured != nil }, "the review never opened")
        let model = try #require(captured)
        // Old: "DOKUMENTNUMMER A-00-0-001" and "VII TAKPLAN DEMO 1 RITNINGSKATEGORI".
        #expect(model.rows.map(\.number) == ["A-00-0-001", "A-00-0-002"], "\(model.rows.map(\.number))")
        #expect(model.rows.map(\.title) == ["VII TAKPLAN DEMO 1", "VII TAKPLAN DEMO 2"], "\(model.rows.map(\.title))")
        // The reading is over: the progress note is gone, and the reading can be started again.
        #expect(core.status.snapshot.activeToolNote == nil)
        #expect(!SheetNamingRun.reading.contains(document.documentIdentity))
        #expect(ProjectWindowController.sheetNamingProgressNote(done: 2, total: 12) == "Reading sheet names: page 2 of 12…")
        #expect(ProjectWindowController.sheetsNamedNote(1) == "1 sheet named.")
        #expect(ProjectWindowController.sheetsNamedNote(3) == "3 sheets named.")
    }

    // MARK: - L-55: Link Sheet References

    static func page(_ index: Int, label: String, documentID: DocumentID) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: index, label: label,
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: 842, height: 595),
                crop: PDFRect(x: 0, y: 0, width: 842, height: 595)
            )
        )
    }

    @Test("L-55: a reference on an unnamed sheet names the sheet, and one printed six times is one row")
    func sheetLinkRowsNameTheSheetOnce() {
        let documentID = DocumentID(UUID())
        let named = Self.page(0, label: "1", documentID: documentID)
        let unnamed = Self.page(1, label: "2", documentID: documentID)
        let sheets = [named.id: "A-101"]
        func line(_ text: String, _ y: Double) -> SheetReferenceLinker.TextLine {
            SheetReferenceLinker.TextLine(text: text, bounds: PDFRect(x: 100, y: y, width: 80, height: 10))
        }
        let lines: [PageID: [SheetReferenceLinker.TextLine]] = [
            unnamed.id: (0..<6).map { line("SEE TR-02", 100 + Double($0) * 20) } + [line("IPG-1114", 300)]
        ]
        let result = SheetReferenceLinker.scan(sheets: sheets, lines: lines)
        #expect(result.unresolved.count == 7)
        let model = SheetLinkReviewModel(
            result: result,
            sheetNames: sheets,
            pageNames: ZenitPDFProjectDocument.sheetLinkPageNames(pages: [named, unnamed], sheets: sheets)
        )
        // Old: six rows "TR-02 on" and one "IPG-1114 on", nothing after "on".
        #expect(model.unresolvedGroups.map(model.unresolvedText) == ["TR-02 on Page 2 · 6 times", "IPG-1114 on Page 2"])
        #expect(model.summaryText == "0 links to create · 2 references to sheets not in the set")
        #expect(model.createTitle == "Create 0 Links")
        #expect(ZenitPDFProjectDocument.sheetLinkPageNames(pages: [named, unnamed], sheets: sheets) == [named.id: "A-101", unnamed.id: "Page 2"])
    }

    // MARK: - L-57: Add Revision from the menu

    @Test("L-57: File ▸ Drawing Set ▸ Add Revision… adds the chosen PDF as a revision, and the Set Compare Report can run")
    func addRevisionFromTheMenu() async throws {
        let harness = try await Fix2Harness.make("L57.pdf", calibrate: false)
        defer { harness.tearDown() }
        let revision = try AppTestSupport.writeFixturePDF(named: "L57 Rev B.pdf")
        defer { try? FileManager.default.removeItem(at: revision.deletingLastPathComponent()) }
        let previousMatch = ZenitPDFProjectDocument.sheetMatchReviewPresenter
        ZenitPDFProjectDocument.sheetMatchReviewPresenter = { _, _, _ in {} }
        defer { ZenitPDFProjectDocument.sheetMatchReviewPresenter = previousMatch }

        // Old: no such command — the ⌥ drop from Finder was the only way to add a revision, and
        // the report's refusal named only that.
        #expect(ZenitAppCommandTable.menuPath(for: .addRevision) == "File ▸ Drawing Set ▸ Add Revision…")
        harness.document.exportSetCompareReport(window: nil)
        #expect(harness.core.status.snapshot.activeToolNote
                == "The set has no revision to compare with. Choose File ▸ Drawing Set ▸ Add Revision…, or hold ⌥ and drop the revised PDF on the canvas, to add one first.")
        let state = ZenitAppCommandWindowState(controller: harness.controller)
        #expect(ZenitAppCommandTable.validate(.addRevision, item: nil, state: state))

        let requests = await ZenitModalPresenter.answeringAsync({ request in
            request.identifier == AddRevisionCommand.panelIdentifier ? .urls([revision]) : .dismissed
        }) {
            ZenitAppCommandTable.perform(.addRevision, controller: harness.controller, document: harness.document)
            #expect(await AppTestSupport.wait(upTo: 30) { harness.document.newestRevision != nil }, "no revision was added")
        }
        #expect(requests.map(\.identifier).contains(AddRevisionCommand.panelIdentifier))
        #expect(harness.document.comparePresenter?.revisions.count == 2, "the drawing as baseline, and the revision")
        #expect(harness.core.status.snapshot.activeToolNote == AddRevisionCommand.addedNote(fileName: "L57 Rev B.pdf"))

        // The report now asks where to save rather than refusing.
        let report = await ZenitModalPresenter.answeringAsync({ _ in .dismissed }) {
            harness.document.exportSetCompareReport(window: nil)
        }
        #expect(report.map(\.identifier).contains(ZenitPDFProjectDocument.setCompareReportPanelIdentifier))
    }

    // MARK: - L-93: the toolbar's Compare on a drawing with no revision

    private func openWindow() async throws -> (document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        let url = try AppTestSupport.writeFixturePDF(named: "L93.pdf")
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { controller.contentViewController is ProjectWindowLayoutController })
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        controller.window?.layoutIfNeeded()
        return (document, controller)
    }

    @Test("L-93/L-57: Revision Compare with no revision says so and adds one from the sheet; Revision Overlay offers the same")
    func revisionCompareAddsARevisionFromTheSheet() async throws {
        let opened = try await openWindow()
        defer { opened.document.close() }
        let presenter = try #require(opened.document.comparePresenter)
        let shell = try #require(opened.document.shell)
        let revision = try AppTestSupport.writeFixturePDF(named: "L93 Rev B.pdf")
        defer { try? FileManager.default.removeItem(at: revision.deletingLastPathComponent()) }

        // Revision Overlay's pane offers Add Revision… — old: only the ⌥ drop, named in a note.
        shell.perform(.revisionOverlay)
        #expect(await AppTestSupport.wait(upTo: 20) { shell.revisionOverlay.onAddRevision != nil }, "the overlay offers no Add Revision…")
        #expect(RevisionOverlayCompositing.needsASecondRevision(count: 1)
                == "Revision Overlay stacks two or more revisions of the same sheet, and this drawing has 1 revision. Choose Add Revision… to add the revised PDF, or drop it on the canvas with ⌥ held.")
        shell.perform(.cancelTool)
        #expect(await AppTestSupport.wait { shell.canvasModes.activeMode == nil })

        let sheet = try #require(opened.controller.presentRevisionCompare(for: opened.document))
        defer { opened.controller.window?.endSheet(sheet.window) }
        // Old: "Select two revisions to compare" over two empty "Choose…" pop-ups, and no hook.
        let hook = try #require(sheet.model.onAddRevision, "the sheet offers no way to add a revision")
        let empty = RevisionCompareModel.emptyState(revisionCount: presenter.revisions.count, canAddRevision: true)
        #expect(empty.title == "This drawing has no revision to compare with yet")
        #expect(empty.actionTitle == "Add Revision…")

        let requests = await ZenitModalPresenter.answeringAsync({ request in
            request.identifier == AddRevisionCommand.panelIdentifier ? .urls([revision]) : .dismissed
        }) {
            hook()
            #expect(await AppTestSupport.wait(upTo: 30) { presenter.revisions.count == 2 }, "the revision never arrived: \(presenter.revisions.map(\.name))")
        }
        #expect(requests.map(\.identifier).contains(AddRevisionCommand.panelIdentifier))
        // The pair is chosen, so the sheet leaves its empty state for the comparison.
        #expect(presenter.revisions.filter(\.isBaseline).count == 1, "one baseline, however the pane and the button raced")
        #expect(presenter.baselineRevisionID != nil && presenter.comparisonRevisionID != nil)
        #expect(RevisionCompareModel.emptyState(revisionCount: presenter.revisions.count, canAddRevision: true).actionTitle == nil)
    }

    @Test("L-57: Revision Overlay and Add Revision… registering the baseline at once register one baseline")
    func concurrentBaselineRegistrationRegistersOne() async throws {
        let opened = try await openWindow()
        defer { opened.document.close() }
        let presenter = try #require(opened.document.comparePresenter)
        let document = opened.document
        let first = Task { @MainActor in try await document.registerCurrentDrawingAsBaseline() }
        let second = Task { @MainActor in try await document.registerCurrentDrawingAsBaseline() }
        let registered = [try await first.value, try await second.value]
        // Old: [true, true] and two "Current" baselines — both found the list empty before
        // either had opened the drawing.
        #expect(registered.filter { $0 }.count == 1, "\(registered)")
        #expect(presenter.revisions.count == 1)
        #expect(presenter.revisions.filter(\.isBaseline).count == 1)
    }

    // MARK: - L-58 / L-60: the batch sheets

    static func stampPreset() -> ToolPresetSummary {
        let template = StampTemplate(
            id: UUID(),
            widthPoints: 160,
            heightPoints: 60,
            fields: [StampFieldDefinition(kind: .pageLabel, textPrefix: "Sheet ")]
        )
        return ToolPresetSummary(
            id: UUID(), name: "Checked", category: "Review", panel: .myTools, markupKind: .stamp,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.1, blue: 0.1), defaultSubject: "Review", stamp: template
        )
    }

    @Test("L-58: one dismiss on the batch sheets, the stamp opens clear of the title block, and it names the sheet")
    func batchStampSheetAndLabel() async throws {
        // Old: the chrome added a Done bar under the panel's own Close and Apply.
        #expect(WorkflowSheet.batchApplyChrome.showsDoneButton == false)
        #expect(WorkflowSheet.batchApplyChrome.ownsKeyboardActions)
        #expect(WorkflowSheet.ocrRunChrome.showsDoneButton == false)

        let harness = try await Fix2Harness.make("L58.pdf", calibrate: false)
        defer { harness.tearDown() }
        let preset = Self.stampPreset()
        // Not armed: with nothing armed the batch takes the person's own stamp first.
        harness.core.toolLibrary.setPresets(harness.core.toolLibrary.presets + [preset])
        let pageID = try #require(harness.document.drawing?.pages.first?.id)
        await harness.document.nameSheet(pageID, number: "A-00-0-002", title: nil)
        await harness.core.refresh()

        let wired = try #require(harness.controller.makeBatchApplyModel(for: harness.document))
        // Old: .bottomRight, over the title block's scale and format cells.
        #expect(wired.model.anchorCorner == .topRight)
        wired.model.preview()
        #expect(wired.model.canApply)
        await wired.model.run()
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 1 })
        let stamped = try #require(await harness.core.session.orderedMarkups.first { $0.stamp != nil })
        // Old: "1" — the page label, though the sheet is named A-00-0-002.
        let label = stamped.stamp?.text(for: .pageLabel) ?? ""
        #expect(label.hasSuffix("A-00-0-002"), "\(label)")
        #expect(!label.hasSuffix(" 1"))
    }

    @Test("L-60: the header and footer question is shown whole, and the preview asks for the text, not a scope")
    func headerFooterAsksForText() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "L60.pdf", pageCount: 3)
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let controller = ProjectWindowController(document: document)
        let wired = try #require(controller.makeHeaderFooterModel(for: document))
        let prompt = try #require(wired.model.placementPrompt)
        // Old: the sentence sat in the 92 pt label column and read "Text for each…".
        #expect(BatchApplySheet.promptPlacement(for: prompt) == .above)
        #expect(wired.model.requiresPromptedText)
        wired.model.preview()
        // Old: "Choose a scope to see how many will be placed." with the scope reading All pages.
        #expect(wired.model.previewSentence == "Type the text for each sheet to see how many will be placed.")
        wired.model.promptedText = "Sheet {page}"
        wired.model.preview()
        #expect(wired.model.plan != nil)
        #expect(wired.model.previewSentence != "Type the text for each sheet to see how many will be placed.")
    }

    // MARK: - L-59: Snippet of Region

    @Test("L-59: Snippet of Region says the picture was copied")
    func snippetSaysItWasCopied() async throws {
        let harness = try await Fix2Harness.make("L59.pdf", calibrate: false)
        defer { harness.tearDown() }
        let pasteboard = RecordingSnippetPasteboard()
        harness.controller.snippetPasteboard = pasteboard
        harness.controller.beginSnippetRegion(for: harness.document)
        #expect(harness.core.status.snapshot.activeToolNote == "Drag a box around the part of the drawing to copy. Escape cancels.")
        harness.canvas.onSnippetRegion?(PDFRectValue(x: 72, y: 72, width: 200, height: 150))
        #expect(await AppTestSupport.wait(upTo: 30) { !pasteboard.payloads.isEmpty }, "nothing reached the clipboard")
        // Old: the note kept asking for the box after the picture was on the clipboard.
        #expect(await AppTestSupport.wait { harness.core.status.snapshot.activeToolNote == ProjectWindowController.snippetCopiedNote })
        #expect(ProjectWindowController.snippetCopiedNote == "Picture copied to the clipboard. Paste it into an email, a report or a chat.")
    }

    // MARK: - L-64: Import Table from Drawing

    @Test("L-64: through the review, the printed header names the columns, nothing reads as unread, and Area starts as Number")
    func importTableReviewTypesTheAreaColumn() throws {
        // The room schedule boxed in the regression: rules at x 100, 180, 280, 380, 500 and every
        // 25 pt from y 500 to 625; the header row on top; the title above the frame; the box a
        // little too large on every side.
        let rules = [100.0, 180, 280, 380, 500].map { VectorLine(start: CGPoint(x: $0, y: 500), end: CGPoint(x: $0, y: 625)) }
            + [500.0, 525, 550, 575, 600, 625].map { VectorLine(start: CGPoint(x: 100, y: $0), end: CGPoint(x: 500, y: $0)) }
        func text(_ value: String, _ x: Double, _ y: Double) -> RecognisedTextLine {
            RecognisedTextLine(text: value, boundsInPageSpace: PDFRectValue(x: x, y: y, width: 50, height: 9))
        }
        var lines = [text("ROOM SCHEDULE", 110, 640)]
        for (y, cells) in [(608.0, ["Room", "Area m2", "Floor", "Finish"]), (583, ["Kitchen", "24.5", "1", "Tiles"]),
                           (558, ["Bath", "6", "1", "Tiles"]), (533, ["Bedroom", "14.25", "2", "Oak"]), (508, ["Hall", "9", "1", "Oak"])] {
            for (index, cell) in cells.enumerated() { lines.append(text(cell, [110, 190, 290, 390][index], y)) }
        }
        let proposal = try TableImportEngine().propose(
            region: PDFRectValue(x: 80, y: 495, width: 430, height: 165), recognisedLines: lines, ruleLines: rules
        ).get()
        let table = ProjectWindowController.reviewTable(from: proposal)
        let model = TableImportReviewModel(table: table, onAccept: { _ in }, onCancel: {})
        // Old: "Column 1"…"Column 5" ("no printed header"), "5 cells could not be read", the
        // header as a data row, and Area suggested as Text because "Area m2" did not parse.
        #expect(model.columns.map(\.title) == ["Room", "Area m2", "Floor", "Finish"])
        let everyHeaderPrinted = model.columns.allSatisfy { $0.headerWasPrinted }
        #expect(everyHeaderPrinted)
        #expect(table.unreadCellCount == 0)
        #expect(model.rows.count == 4)
        #expect(model.columnKinds == [.text, .number, .number, .text])
        #expect(model.subjectColumnIndex == 0)
    }

    // MARK: - L-65: Fill Form Fields

    static func lowerCaseForm(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.stroke(CGRect(x: 10, y: 10, width: 380, height: 280)); context.endPDFPage(); context.closePDF()
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        for (index, name) in ["project", "inspector", "approved_by"].enumerated() {
            let field = PDFAnnotation(bounds: CGRect(x: 40, y: 230 - CGFloat(index) * 40, width: 200, height: 22), forType: .widget, withProperties: nil)
            field.widgetFieldType = .text
            field.fieldName = name
            page.addAnnotation(field)
        }
        #expect(document.write(to: url))
    }

    @Test("L-65: form fields are labelled as a person reads them, and the explanation is shown whole")
    func formFillLabelsAndExplanation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-l65-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Form.pdf")
        try Self.lowerCaseForm(at: source)
        let controller = FormFillController(fields: try PDFFormFields.fields(ofFileAt: source))
        _ = controller.view
        // Old: "project", "inspector", "approved_by" — the internal names.
        #expect(controller.labels["project"]?.stringValue == "Project")
        #expect(controller.labels["inspector"]?.stringValue == "Inspector")
        #expect(controller.labels["approved_by"]?.stringValue == "Approved by")
        #expect(controller.labels["project"]?.toolTip == "project")
        #expect(FormFill.displayLabel(forFieldNamed: "form.approvedBy") == "Approved by")
        #expect(FormFill.displayLabel(forFieldNamed: "RFI_no") == "RFI no")
        #expect(FormFill.displayLabel(forFieldNamed: "date") == "Date")

        // Old: no preferred width, so the label's intrinsic height was one line and the
        // sentence was cut — "…field values never enter the led…".
        let note = controller.explanation
        let wrapped = try #require(note.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: FormFillController.contentWidth, height: 10_000)).height
        let oneLine = try #require(note.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).height
        #expect(wrapped > oneLine * 1.5, "the fixture sentence must need more than one line at the sheet's width")
        #expect(note.intrinsicContentSize.height >= wrapped - 0.5, "\(note.intrinsicContentSize.height) < \(wrapped)")
    }

    // MARK: - L-69: Apply Scale to Pages on a one-page drawing

    @Test("L-69: on a one-page drawing the target is the page that already has the scale, and the sheet says so")
    func applyScaleSaysThePageAlreadyHasIt() async throws {
        ZenitModalPresenter.reset()
        let harness = try await Fix2Harness.make("L69.pdf")
        defer {
            ZenitModalPresenter.reset()
            harness.tearDown()
        }
        let sheet = try #require(harness.controller.presentBulkScaleSheet(for: harness.document))
        defer { sheet.finish() }
        sheet.model.selection = BulkScaleSelection(kind: .currentPage)
        sheet.refreshPreview()
        await sheet.settlePreview()
        #expect(sheet.model.impact.pageCount == 0)
        #expect(sheet.model.impact.targetIsSourcePageOnly)
        // Old: "This target matches no pages, so there is nothing to apply."
        #expect(sheet.model.impact.emptyTargetMessage
                == "This page already has this scale — it is the page the scale was taken from. Choose other pages to apply it to.")
        // A target that truly names nothing keeps its own sentence.
        #expect(BulkScaleImpact.none.emptyTargetMessage == "This target matches no pages, so there is nothing to apply.")
    }

    // MARK: - L-83: Review List

    @Test("L-83: the Review List panel opens with room for its list")
    func reviewListOpensWithRoom() async throws {
        let harness = try await Fix2Harness.make("L83.pdf", calibrate: false)
        defer { harness.tearDown() }
        let panel = ReviewListWindow.makePanel(shell: harness.shell, document: harness.document)
        defer { panel.close() }
        let content = panel.contentRect(forFrameRect: panel.frame).size
        // Old, measured live: about 520 × 45 pt — the filter bar and no list.
        #expect(content.width >= ReviewListPane.minimumSize.width, "\(content)")
        #expect(content.height >= ReviewListPane.minimumSize.height, "\(content)")
        #expect(panel.contentMinSize.width >= ReviewListPane.minimumSize.width)
        #expect(panel.contentMinSize.height >= ReviewListPane.minimumSize.height)
    }
}
