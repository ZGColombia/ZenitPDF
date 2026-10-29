import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFMeasurementEngine
import ZPDFRenderer
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Bug hunt 2, window and workflow: menus, dimension check, table import, symbol
/// schedule, failed opens, printing, calibration entry and the flatten report.
@MainActor
@Suite(.appTierSerialised)
struct Fix2WindowWorkflowTests {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Menus

    private static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    @Test("BH-072: no two menu items share a key equivalent")
    func noShortcutCollisions() async throws {
        let harness = try await Fix2Harness.make("BH072.pdf", calibrate: false)
        defer { harness.tearDown() }
        let items = Self.allItems(ZenitMenuBar.make()).filter { !$0.keyEquivalent.isEmpty }
        var seen: [String: String] = [:]
        var collisions: [String] = []
        for item in items {
            let chord = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent.lowercased())"
            if let other = seen[chord] { collisions.append("\(other) / \(item.title)") }
            seen[chord] = item.title
        }
        // Old: "Hide Toolbar" and "Show Tool Library" both held ⌥⌘T, and the View menu won.
        #expect(collisions.isEmpty, "\(collisions)")
    }

    @Test("BH-896: Cut, Copy and Paste sit directly under Undo/Redo")
    func clipboardBlockIsAnchoredOnRedo() async throws {
        let harness = try await Fix2Harness.make("BH896.pdf", calibrate: false)
        defer { harness.tearDown() }
        let bar = ZenitMenuBar.make()
        let edit = try #require(bar.items.compactMap(\.submenu).first { menu in
            menu.items.contains { $0.action == Selector(("redo:")) }
        })
        let redo = try #require(edit.items.firstIndex { $0.action == Selector(("redo:")) })
        #expect(edit.items[redo + 1].isSeparatorItem)
        #expect(edit.items[redo + 2].action == #selector(NSText.cut(_:)))
        #expect(edit.items[redo + 3].action == #selector(NSText.copy(_:)))
        #expect(edit.items[redo + 4].action == #selector(NSText.paste(_:)))
    }

    // MARK: - Dimension check

    @Test("BH-073: a sloped length is checked against the drawn plan dimension by its plan length")
    func dimensionCheckUsesPlanLength() {
        let page = PageID(UUID())
        var record = MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page,
            kind: .measurement, tool: .length, subject: "",
            geometry: MeasurementGeometry(pageID: page, points: []),
            createdAt: Date(), modifiedAt: Date()
        )
        record.measurement = MeasurementResult(values: [
            .planLength: DecimalQuantity(value: Decimal(string: "5.400")!, dimension: .length),
            .trueLength: DecimalQuantity(value: Decimal(string: "5.419")!, dimension: .length)
        ])
        // Old: trueLength first — "drawn 5.4, measured 5.419, check the calibration".
        #expect(ProjectWindowController.dimensionCheckQuantity(of: record)?.value == Decimal(string: "5.400"))
    }

    @Test("BH-364 / BH-899: silence is not agreement, and one disagreement is singular")
    func dimensionCheckWording() {
        let tolerance = Decimal(string: "0.010")!
        let silent = ProjectWindowController.dimensionCheckOutcome(
            [("A", .noConfidentDimension), ("B", .noConfidentDimension)], toleranceMetres: tolerance
        )
        // Old: "2 measurements agree with the drawn dimensions" — nothing had been checked.
        guard case let .note(text) = silent else { Issue.record("expected a note"); return }
        #expect(!text.contains("agree"))
        let one = ProjectWindowController.dimensionCheckOutcome(
            [("A", .disagrees(drawnMetres: 2.1, measuredMetres: 2, differenceMetres: 0.1, toleranceMetres: tolerance)),
             ("B", .agrees(drawnMetres: 3))],
            toleranceMetres: tolerance
        )
        guard case let .warning(title, _) = one else { Issue.record("expected a warning"); return }
        // Old: "1 measurements disagree with the drawn dimensions."
        #expect(title.hasPrefix("1 measurement disagrees"))
    }

    // MARK: - Symbol schedule and table import

    @Test("BH-074: a landed schedule is a count — count symbols, no dimensioned polyline")
    func scheduleLandsAsCountPoints() {
        let page = PageID(UUID())
        let geometry = ProjectWindowController.scheduleCountGeometry(
            pageID: page,
            positions: [PDFPoint(x: 1, y: 1), PDFPoint(x: 50, y: 1), PDFPoint(x: 90, y: 40), PDFPoint(x: 10, y: 80)]
        )
        // Old: `points:` — CanvasScene drew a length line zig-zagging through the doors.
        #expect(geometry.points.isEmpty)
        #expect(geometry.countPoints.count == 4)
        let record = MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page,
            kind: .measurement, tool: .count, subject: "D-12", geometry: geometry,
            createdAt: Date(), modifiedAt: Date()
        )
        let shape = CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue).first
        #expect(shape?.counts.count == 4)
        #expect(shape?.strokes.contains { $0.dimensioned } == false)
    }

    @Test("BH-365: a Number column lands as a number column unless a read cell is not a number")
    func tableImportHonoursColumnKinds() {
        let page = PageID(UUID())
        let quantity = TableImportAcceptance.ColumnBinding(columnID: ColumnID(UUID()), title: "Qty", index: 0)
        let remarks = TableImportAcceptance.ColumnBinding(columnID: ColumnID(UUID()), title: "Remarks", index: 1)
        func row(_ qty: String, _ note: String) -> MarkupRecord {
            var record = MarkupRecord(
                id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page,
                kind: .measurement, tool: nil, subject: "", geometry: nil,
                createdAt: Date(), modifiedAt: Date()
            )
            record.customValues = [quantity.columnID: .text(qty), remarks.columnID: .text(note)]
            return record
        }
        let clean = ProjectWindowController.tableImportLanding(
            records: [row("12", "a"), row("3,5", "b")],
            bindings: [quantity, remarks],
            outcome: TableImportReviewOutcome(columns: [
                .init(index: 0, title: "Qty", kind: .number, unparsedRowIndexes: []),
                .init(index: 1, title: "Remarks", kind: .text, unparsedRowIndexes: [])
            ], subjectColumnIndex: 1)
        )
        // Old: every column `.text`, whatever the reviewer chose.
        #expect(clean.definitions.first?.kind == .number)
        #expect(clean.records[1].customValues[quantity.columnID] == .number(.count(Decimal(string: "3.5")!)))
        #expect(clean.keptAsText.isEmpty)
        let messy = ProjectWindowController.tableImportLanding(
            records: [row("12", "a"), row("PLAN 2", "b")],
            bindings: [quantity, remarks],
            outcome: TableImportReviewOutcome(columns: [
                .init(index: 0, title: "Qty", kind: .number, unparsedRowIndexes: [1]),
                .init(index: 1, title: "Remarks", kind: .text, unparsedRowIndexes: [])
            ], subjectColumnIndex: 1)
        )
        #expect(messy.definitions.first?.kind == .text, "an unparsable cell must never become a zero")
        #expect(messy.keptAsText == ["Qty"])
    }

    @Test("BH-901 / IM-184: table import and symbol schedule land as one batch, never a loop")
    func importsAreBatched() throws {
        for file in ["ProjectWindowController+TableImport.swift", "ProjectWindowController+SymbolSchedule.swift"] {
            let source = try String(
                contentsOf: Self.repositoryRoot.appendingPathComponent("Apps/ZenitPDF/Sources/ZenitPDFAppKit/Window/\(file)"),
                encoding: .utf8
            )
            // Old: `for command in … { try await core.commands.perform(command) }` — a refusal
            // on row 7 left rows 1–6 and the columns behind, one undo step per row.
            #expect(source.contains("performBatch("), "\(file) does not land through performBatch")
            #expect(!source.contains("commands.perform(command)"), "\(file) still performs row by row")
            #expect(!source.contains("_ = try await core.commands.perform(.addMarkup"), "\(file) still loops addMarkup")
        }
    }

    // MARK: - Failed opens

    @Test("BH-370: a refused open of the window's only drawing says why application-modally, after closing")
    func refusalOnTheOnlyDocumentIsNotSheetedOnADyingWindow() async throws {
        let harness = try await Fix2Harness.make("BH370.pdf", calibrate: false)
        defer { harness.tearDown() }
        var presentedOn: [NSWindow?] = []
        var closedWhenPresented: [Bool] = []
        let previous = ZenitErrorPresenter.handler
        ZenitErrorPresenter.handler = { _, window in
            presentedOn.append(window)
            closedWhenPresented.append(harness.document.isClosed)
        }
        defer { ZenitErrorPresenter.handler = previous }
        harness.controller.presentErrorClosingFailed(
            ZenitDocumentError.passwordRequired("BH370.pdf"), document: harness.document
        )
        // Old: sheeted on `window`, then the window was closed on the next line.
        #expect(presentedOn.count == 1)
        #expect(presentedOn.first ?? nil == nil, "the error was sheeted on the window that closes with the document")
        #expect(closedWhenPresented == [true])
    }

    @Test("BH-371 / BH-076: an unreadable drawing's Cancel closes the dead tab; Grant Access closes it before reopening")
    func unreadableDrawingFlows() async throws {
        // Cancel.
        let cancelURL = try AppTestSupport.writeFixturePDF(named: "Locked371.pdf")
        defer { try? FileManager.default.removeItem(at: cancelURL.deletingLastPathComponent()) }
        let previousHandler = ZenitModalPresenter.handler
        defer { ZenitModalPresenter.handler = previousHandler }
        ZenitModalPresenter.handler = { _ in .dismissed }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cancelURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cancelURL.path) }
        let cancelled = try AppTestSupport.makeDocument(opening: cancelURL)
        // As the document controller does when it opens a file.
        cancelled.fileURL = cancelURL
        let controller = ProjectWindowController(document: cancelled)
        cancelled.addWindowController(controller)
        // Old: Cancel returned and kept the failed document as the active tab with no content.
        #expect(await AppTestSupport.wait { cancelled.isClosed }, "Cancel left the dead tab open")
        #expect(ZenitModalPresenter.didRequest(ProjectWindowController.unreadableDrawingModalIdentifier),
                "the unreadable-drawing offer was never made")

        // Grant Access.
        let grantURL = try AppTestSupport.writeFixturePDF(named: "Locked076.pdf")
        defer { try? FileManager.default.removeItem(at: grantURL.deletingLastPathComponent()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: grantURL.path)
        var openedWhileFailedWasOpen: [Bool] = []
        var failed: ZenitPDFProjectDocument?
        let previousOpener = ProjectWindowController.dropOpener
        ProjectWindowController.dropOpener = { _ in openedWhileFailedWasOpen.append(!(failed?.isClosed ?? true)) }
        defer { ProjectWindowController.dropOpener = previousOpener }
        ZenitModalPresenter.handler = { request in
            if request.identifier == ProjectWindowController.grantAccessModalIdentifier {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: grantURL.path)
                return .urls([grantURL])
            }
            return .button(0)
        }
        let grantDocument = try AppTestSupport.makeDocument(opening: grantURL)
        grantDocument.fileURL = grantURL
        failed = grantDocument
        let grantController = ProjectWindowController(document: grantDocument)
        grantDocument.addWindowController(grantController)
        #expect(await AppTestSupport.wait { !openedWhileFailedWasOpen.isEmpty }, "Grant Access never reopened")
        // Old: opened first — the document controller found the still-registered failed
        // document for that URL, only showed it, and then it was closed: nothing reopened.
        #expect(openedWhileFailedWasOpen == [false])
    }

    // MARK: - Printing

    @Test("BH-363: the print paper is the largest sheet, and a smaller paper fits rather than clips")
    func printPaperFitsTheSheet() async throws {
        let harness = try await Fix2Harness.make("BH363.pdf", calibrate: false)
        defer { harness.tearDown() }
        let archD = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 2592, height: 1728))
        )
        let sheets = [DocumentPrintView.Sheet(flatten: FlattenPage(page: archD, sourcePageIndex: 0, markups: []))]
        let info = DocumentPrintView.printInfo(for: sheets, base: NSPrintInfo())
        // Old: the document's default Letter/A4 paper with margins; the ARCH-D sheet printed
        // its bottom-left corner.
        #expect(abs(info.paperSize.width - 2592) < 2 && abs(info.paperSize.height - 1728) < 2, "\(info.paperSize)")
        #expect(info.leftMargin == 0 && info.topMargin == 0)
        #expect(DocumentPrintLayout.factor(for: .init(size: CGSize(width: 2592, height: 1728), drawnRatio: nil), slot: CGSize(width: 612, height: 792), options: .init(scaleMode: .fitToPaper)) < 0.25)
        #expect(DocumentPrintLayout.factor(for: .init(size: CGSize(width: 500, height: 500), drawnRatio: nil), slot: CGSize(width: 612, height: 792), options: .init(scaleMode: .fitToPaper)) == 1)
    }

    // MARK: - Calibration entry

    @Test("BH-077 / BH-078 / BH-376: a known length parses whole and locale-free, and the unit follows the project")
    func calibrationLengthParsing() throws {
        // Old: en_US NumberFormatter read "12,5" as 125; Decimal(string:) read 10'6" as 10.
        #expect(CalibrationPrompt.parse("12,5", unit: .metre)?.length == Decimal(string: "12.5"))
        #expect(CalibrationPrompt.parse("5.5", unit: .metre)?.length == Decimal(string: "5.5"))
        #expect(CalibrationPrompt.parse("12 500", unit: .millimetre)?.length == 12500)
        let feet = try #require(CalibrationPrompt.parse("10'6\"", unit: .foot))
        #expect(feet.length == 126 && feet.unit == .inch)
        #expect(CalibrationPrompt.parse("10' - 6 1/2\"", unit: .foot)?.length == Decimal(string: "126.5"))
        #expect(CalibrationPrompt.parse("3 1/2", unit: .inch)?.length == Decimal(string: "3.5"))
        #expect(CalibrationPrompt.parse("1.234,5", unit: .metre) == nil, "an ambiguous number must be refused")
        #expect(CalibrationPrompt.parse("12 m and some", unit: .metre) == nil)
        #expect(CalibrationPrompt.parse("-4", unit: .metre) == nil)
        #expect(CalibrationPrompt.promptUnit(for: .foot) == .foot)
        #expect(CalibrationPrompt.promptUnit(for: .millimetre) == .millimetre)
    }

    // MARK: - Flattened export

    @Test("BH-379: a flatten reports markups it could not draw and pages with no underlay")
    func flattenReportsWhatIsMissing() async throws {
        let harness = try await Fix2Harness.make("BH379.pdf")
        defer { harness.tearDown() }
        let good = try await FlattenedDrawingExport.job(for: harness.document)
        var broken = good
        broken.pages[0] = FlattenPage(
            page: good.pages[0].page,
            sourcePageIndex: good.pages[0].sourcePageIndex,
            markups: [RenderableMarkup(
                id: MarkupID(UUID()),
                shape: .polyline(RenderPolyline(points: [PDFPoint(x: .nan, y: 1), PDFPoint(x: 2, y: .infinity)])),
                style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), fill: nil, lineWidth: 1)
            )]
        )
        let url = harness.directory.appendingPathComponent("Flat.pdf")
        let report = try FlattenedDrawingExport.write(shape: .flattened, job: broken, content: nil, to: url)
        // Old: `write` returned success and said nothing about either.
        #expect(report.rejectedMarkupCount == 1)
        #expect(report.pagesWithoutUnderlay == [0])
        #expect(report.warningText?.isEmpty == false)
        let content = await FlattenedDrawingExport.contentSource(for: harness.document)
        let clean = try FlattenedDrawingExport.write(shape: .clean, job: good, content: content, to: url)
        #expect(clean.isComplete)
    }

    @Test("BH-378: the raster fallback keeps sheets on disk and draws them one at a time")
    func diskBackedRasterRoundTrips() throws {
        let source = try #require(DiskBackedRasterContentSource())
        let context = CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        source.store(context.makeImage()!, forPage: 3)
        source.noteFailure(forPage: 4)
        let target = CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        #expect(source.drawPageContent(sourcePageIndex: 3, into: target, rect: CGRect(x: 0, y: 0, width: 20, height: 10)))
        // Old: a failed page was skipped by `try?` and the sheet printed white in silence.
        #expect(!source.drawPageContent(sourcePageIndex: 4, into: target, rect: .zero))
        #expect(source.failedPages == [4])
    }

    @Test("BH-079 / BH-377: a drawing with default layers and no annotations adds no omission note")
    func omissionNotesAreQuietWhenNothingIsOmitted() async throws {
        let harness = try await Fix2Harness.make("BH079.pdf", calibrate: false)
        defer { harness.tearDown() }
        let notes = await FlattenedDrawingExport.omissionNotes(for: harness.document)
        #expect(notes.isEmpty, "\(notes)")
    }

    // MARK: - IM-050 the opening state

    @Test("IM-050: a window names the drawing it is opening, shows progress, and Cancel closes the tab")
    func openingStateNamesTheDrawingAndCancels() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Tower Level 3.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        document.fileURL = url
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        defer { if !document.isClosed { document.close() } }
        // Old: a bare background-coloured view — no name, no progress, no way out.
        let placeholder = try #require(controller.loadingPlaceholder)
        #expect(placeholder.nameLabel.stringValue.contains("Tower Level 3"))
        #expect(placeholder.statusLabel.stringValue == "Opening…")
        #expect(placeholder.progress.isIndeterminate)
        #expect(placeholder.accessibilityLabel()?.contains("Tower Level 3") == true)
        placeholder.cancelButton.performClick(nil)
        #expect(await AppTestSupport.wait { document.isClosed }, "Cancel did not close the tab")
    }

    // MARK: - IM-052 / IM-185 / IM-186 / IM-187 / BH-913 export

    @Test("IM-052 / IM-186: a workbook export is written off the main actor into place, and confirmed with Show in Finder")
    func projectedExportIsConfirmed() async throws {
        let harness = try await Fix2Harness.make("IM052.pdf")
        defer { harness.tearDown() }
        try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }, subject: "Wall")
        let url = harness.directory.appendingPathComponent("Ledger.xlsx")
        try Data("stale".utf8).write(to: url)
        await harness.controller.writeProjectedExport(
            format: .xlsx, for: harness.document, core: harness.core, includeTrail: false, to: url
        ).value
        let bytes = try Data(contentsOf: url)
        #expect(bytes.starts(with: [0x50, 0x4B]), "the destination was not replaced by a complete workbook")
        // Old: nothing on success — a finished export looked like a click that did nothing.
        let confirmation = try #require(harness.core.status.warnings.first { $0.id == ExportCompletion.warningID })
        #expect(confirmation.title.contains("Ledger.xlsx"))
        #expect(confirmation.actionTitle == "Show in Finder")
        var revealed: [URL] = []
        let previous = ExportCompletion.revealer
        ExportCompletion.revealer = { revealed.append($0) }
        defer { ExportCompletion.revealer = previous }
        #expect(ExportCompletion.handleAction(for: ExportCompletion.warningID, document: harness.document))
        #expect(revealed == [url])
    }

    @Test("IM-185 / IM-187 / BH-913: the export proposes a descriptive name, states its scope, and keeps dotted names")
    func exportDefaultsAndScope() async throws {
        let harness = try await Fix2Harness.make("IM185.pdf", calibrate: false)
        defer { harness.tearDown() }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = ProjectWindowController.ledgerExportFileName(document: harness.document, isFiltered: true, date: date)
        // Old: "<name>.csv" — no date, and a filtered subset named like the whole takeoff.
        #expect(name.contains("Quantity Ledger 2026-"))
        #expect(name.hasSuffix("(filtered).csv"))
        #expect(ExportAccessoryView.scopeText(rowCount: 12, totalRows: 412, isFiltered: true).contains("12 of 412"))
        #expect(ExportAccessoryView.scopeText(rowCount: 412, totalRows: 412, isFiltered: false).contains("all 412"))
        // Old: "Level 2.1" → "Level 2.xlsx".
        #expect(ExportAccessoryView.renamed("Level 2.1", to: .xlsx) == "Level 2.1.xlsx")
        #expect(ExportAccessoryView.renamed("Takeoff.csv", to: .pdfReport) == "Takeoff.pdf")
        try ScratchDefaults.with(prefix: "zenit.fix2.exportformat") { defaults, _ in
            let first = ExportAccessoryView(panel: NSSavePanel(), preferences: defaults)
            first.selectForTesting(.xlsx)
            #expect(!first.subtotalCheckbox.isHidden, "the workbook options belong to the Excel format")
            let second = ExportAccessoryView(panel: NSSavePanel(), preferences: defaults)
            #expect(second.format == .xlsx, "the format chosen last time was not remembered")
        }
    }
}
