import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFExtensions
import ZPDFRenderer
import ZPDFSpreadsheet
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Export, import and print regressions (l8-exportio): L-45, L-46, L-46b, L-47, L-48, L-52,
/// L-56, L-62, L-63, L-66, L-67 and L-81, each through the path a person takes. Panels and
/// alerts are answered through `ZenitModalPresenter`; no window reaches the screen.
///
/// Hand-derived quantities: `Fix2Harness` calibrates 100 pt = 1 m, so the 100 × 80 pt slab is
/// 1 m × 0.8 m = 0.8 m² and the 125 pt wall is 1.25 m.
@MainActor
@Suite("Export, import and print", .appTierSerialised)
struct L8ExportIOAppTests {

    // MARK: - Fixtures

    /// A harness with a 0.8 m² slab and a 1.25 m wall.
    private func ledgerHarness(_ name: String) async throws -> Fix2Harness {
        let harness = try await Fix2Harness.make(name)
        _ = try await harness.addMarkup(tool: .area, geometry: { page in
            MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 180), PDFPoint(x: 100, y: 180)
            ], isClosed: true))])
        }, subject: "Slab")
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 300), PDFPoint(x: 225, y: 300)])
        }, subject: "Wall")
        await harness.core.ledger.refresh()
        return harness
    }

    private func ledgerRow(_ harness: Fix2Harness, subject: String) -> LedgerRow? {
        (0..<harness.core.ledger.rowCount).lazy
            .compactMap { harness.core.ledger.row(at: $0) }
            .first { $0.displayValue(.subject) == subject }
    }

    private func projection(_ harness: Fix2Harness) async throws -> ExportProjection {
        try await ProjectWindowController.projection(
            core: harness.core, documentName: "Live 8", scaleDescription: nil, request: harness.core.ledger.request
        )
    }

    // MARK: - L-46: the workbook, the report, the projection

    /// Old output: titles "icon", "pageLabel", "pageIndex", "planArea", "displayUnit"; the Unit
    /// cell blank; the Type cell the tool's token ("area"); the page index 0; the numbers in the
    /// invariant locale whatever the ledger showed.
    @Test("L-46: every projected export reads as the ledger does — titles, Type, Unit, page from 1, the ledger's digits")
    func projectionReadsAsTheLedger() async throws {
        let harness = try await ledgerHarness("L46 projection.pdf")
        defer { harness.tearDown() }
        let table = try await projection(harness).table
        func column(_ key: String) throws -> Int { try #require(table.columns.firstIndex { $0.key == key }, "no \(key)") }
        let titles = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.key, $0.title) })
        #expect(titles["icon"] == "Type")
        #expect(titles["pageLabel"] == "Page")
        #expect(titles["pageIndex"] == "Page index")
        #expect(titles["planArea"] == "Plan Area")
        #expect(titles["displayUnit"] == "Unit")
        #expect(titles["costCode"] == "Cost Code")

        let slabRow = try #require(ledgerRow(harness, subject: "Slab"))
        let wallRow = try #require(ledgerRow(harness, subject: "Wall"))
        let slab = try #require(table.allRows().first { $0.markupID == slabRow.markupID.uuidString })
        let wall = try #require(table.allRows().first { $0.markupID == wallRow.markupID.uuidString })
        #expect(slab.cells[try column("displayUnit")].text == "m²")
        #expect(wall.cells[try column("displayUnit")].text == "m")
        // The Type and the quantities are the ledger's own strings, digit for digit (QUALITY_BAR A29).
        #expect(slab.cells[try column("icon")].text == slabRow.displayValue(.icon))
        #expect(slab.cells[try column("icon")].text == "Area")
        #expect(slab.cells[try column("planArea")].text == slabRow.displayValue(.planArea))
        #expect(wall.cells[try column("planLength")].text == wallRow.displayValue(.planLength))
        #expect(slab.cells[try column("planArea")].number?.raw == Decimal(string: "0.8"))
        #expect(wall.cells[try column("planLength")].number?.raw == Decimal(string: "1.25"))
        #expect(slab.cells[try column("pageIndex")].text == "1")
    }

    @Test("L-46: File ▸ Export… as Excel heads the ledger's columns in the ledger's words and fills Unit")
    func workbookThroughTheExportPath() async throws {
        let harness = try await ledgerHarness("L46 workbook.pdf")
        defer { harness.tearDown() }
        let url = harness.directory.appendingPathComponent("Ledger.xlsx")
        await harness.controller.writeProjectedExport(
            format: .xlsx, for: harness.document, core: harness.core, includeTrail: false, to: url
        ).value
        let reader = try XLSXWorkbookReader(data: Data(contentsOf: url))
        let sheet = try #require(reader.sheet(named: "Ledger"))
        let header = sheet.rows.first?.compactMap { $0 } ?? []
        // Old output: "icon", "pageLabel", "pageIndex", "planArea (m²)", "displayUnit", "costCode".
        #expect(header.contains("Type"))
        #expect(header.contains("Page"))
        #expect(header.contains("Plan Area (m²)"))
        #expect(header.contains("Unit"))
        #expect(!header.contains { ["icon", "pageLabel", "pageIndex", "displayUnit", "costCode", "planArea (m²)"].contains($0) })
        let unit = try #require(sheet.rows.first?.firstIndex { $0 == "Unit" })
        let subject = try #require(sheet.rows.first?.firstIndex { $0 == "Subject" })
        let slab = try #require(sheet.rows.first { $0.indices.contains(subject) && $0[subject] == "Slab" })
        #expect(slab[unit] == "m²")
    }

    @Test("L-46: File ▸ Export… as a PDF report prints the ledger's titles and no contract versions on its cover")
    func reportThroughTheExportPath() async throws {
        let harness = try await ledgerHarness("L46 report.pdf")
        defer { harness.tearDown() }
        let url = harness.directory.appendingPathComponent("Ledger.pdf")
        await harness.controller.writeProjectedExport(
            format: .pdfReport, for: harness.document, core: harness.core, includeTrail: false, to: url
        ).value
        let text = try #require(PDFDocument(url: url)?.string)
        #expect(text.contains("Plan Area (m²)"), "\(text.prefix(600))")
        #expect(text.contains("m²"))
        // Old output: "Ledger contract v1", "Formula grammar v1", "Number locale invariant".
        #expect(!text.contains("Ledger contract"))
        #expect(!text.contains("Formula grammar"))
        #expect(!text.contains("Number locale"))
        #expect(!text.contains("planArea"))
        #expect(!text.contains("displayUnit"))
    }

    @Test("L-46: a report template's own CSV is written in the ledger's locale without a delimiter clash")
    func templateCSVInTheLedgersLocale() async throws {
        let harness = try await ledgerHarness("L46 template csv.pdf")
        defer { harness.tearDown() }
        let url = harness.directory.appendingPathComponent("Ledger.csv")
        ZenitErrorPresenter.reset()
        await harness.controller.writeProjectedExport(
            format: .csv, for: harness.document, core: harness.core, includeTrail: true,
            requestOverride: harness.core.ledger.request, to: url
        ).value
        #expect(ZenitErrorPresenter.recorded.isEmpty, "\(ZenitErrorPresenter.recorded)")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Plan Area"))
        #expect(text.contains("Audit Trail"))
    }

    /// Re-fix (independent check of L-46): the exports counted sheets from 1 and the ledger did
    /// not. Old output: the on-screen Page index cell — and so File ▸ Export CSV, which writes the
    /// cell — read "0" for the first sheet and "2" for the third, while Excel, the report, the
    /// profiles and a template's CSV printed "1" and "3" under the same heading (QUALITY_BAR A29);
    /// a filter typed as the number the cell shows matched the sheet after it.
    @Test("L-46: the Page index cell, its group heading, its filter, the CSV and every projected export count sheets from 1 alike")
    func pageIndexAgreesOnScreenAndInEveryExport() async throws {
        let harness = try await Fix2Harness.make("L46 pages.pdf", pageCount: 3)
        defer { harness.tearDown() }
        let square: (PageID) -> MeasurementGeometry = { page in
            MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 180), PDFPoint(x: 100, y: 180)
            ], isClosed: true))])
        }
        _ = try await harness.addMarkup(tool: .area, geometry: square, subject: "First sheet", pageIndex: 0)
        _ = try await harness.addMarkup(tool: .area, geometry: square, subject: "Third sheet", pageIndex: 2)
        await harness.core.ledger.refresh()
        var request = harness.core.ledger.request
        for column in [LedgerColumnID.subject, .pageIndex] where !request.visibleColumns.contains(column) {
            request.visibleColumns.append(column)
        }

        // The screen: the ledger's own cells.
        let shown = try await harness.core.session.ledgerProjection(request)
        var onScreen: [String: (markup: UUID, page: String)] = [:]
        for index in 0..<shown.rowCount {
            guard let row = shown.row(at: index) else { continue }
            onScreen[row.displayValue(.subject)] = (row.markupID, row.displayValue(.pageIndex))
            // File ▸ Export CSV writes the cell the row shows.
            #expect(LedgerCSVExport.cellText(row, column: .pageIndex) == row.displayValue(.pageIndex))
            // The stored index stays 0-based underneath, for the sort, the filter and the round trip.
            if case let .number(stored) = row.value(.pageIndex) {
                #expect(row.displayValue(.pageIndex) == "\(stored + 1)")
            } else {
                Issue.record("the Page index cell lost its stored number: \(row.value(.pageIndex))")
            }
        }
        #expect(onScreen["First sheet"]?.page == "1", "\(onScreen)")
        #expect(onScreen["Third sheet"]?.page == "3", "\(onScreen)")

        // Every projected export (Excel, the report, the profiles, a template's CSV) prints the
        // cell the ledger shows for the same row, byte for byte.
        let table = try await ProjectWindowController.projection(
            core: harness.core, documentName: "Live 8", scaleDescription: nil, request: request
        ).table
        let column = try #require(table.columns.firstIndex { $0.key == "pageIndex" })
        for (subject, cell) in onScreen {
            let row = try #require(table.allRows().first { $0.markupID == cell.markup.uuidString }, "\(subject)")
            #expect(row.cells[column].text == cell.page, "\(subject): export \(row.cells[column].text), ledger \(cell.page)")
        }

        // A filter typed as the number the cell shows keeps that sheet's rows, and only those.
        var filtered = request
        filtered.filter = LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .pageIndex, comparison: .equals, operand: .number(3))
        ])
        let narrowed = try await harness.core.session.ledgerProjection(filtered)
        #expect(narrowed.rowCount == 1)
        #expect(narrowed.row(at: 0)?.displayValue(.subject) == "Third sheet")
        filtered.filter = LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .pageIndex, comparison: .between, operand: .numberRange(lower: 1, upper: 2))
        ])
        let band = try await harness.core.session.ledgerProjection(filtered)
        #expect(band.rowCount == 1)
        #expect(band.row(at: 0)?.displayValue(.subject) == "First sheet")

        // Grouped by Page index, the headings are the page numbers the cells under them show.
        var grouped = request
        grouped.grouping = [.pageIndex]
        let outline = try await harness.core.session.ledgerProjection(grouped)
        #expect(Set(outline.rootGroups.map(\.title)) == ["1", "3"], "\(outline.rootGroups.map(\.title))")
    }

    // MARK: - L-46b: export profiles

    /// Old output: "Save Columns as Export Profile" wrote headers equal to the keys, and Export
    /// with Profile wrote "icon;subject;label;…;displayUnit" with a blank Unit.
    @Test("L-46b: a profile saved from the ledger's columns heads them as the ledger does, and its CSV fills Unit")
    func profileHeadersAndUnit() async throws {
        let harness = try await ledgerHarness("L46b profile.pdf")
        defer { harness.tearDown() }
        let projection = try await projection(harness)
        var profile = ExportProfiles.profile(from: projection, name: "Office")
        #expect(profile.columns.first { $0.key == "displayUnit" }?.header == "Unit")
        #expect(profile.columns.first { $0.key == "planArea" }?.header == "Plan Area")
        profile.columns = profile.columns.filter { ["subject", "planArea", "displayUnit"].contains($0.key) }
        profile.encoding = .utf8
        profile.lineEnding = .lf
        let url = harness.directory.appendingPathComponent("office.csv")
        #expect(await ExportProfiles.write(profile: profile, document: harness.document, to: url))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == "Subject;Plan Area;Unit")
        // 0.8 m² at the ledger's two places, the profile's decimal comma.
        #expect(lines.contains("Slab;0,80;m²"), "\(lines)")
        #expect(lines.contains("Wall;;m"), "\(lines)")
    }

    // MARK: - L-47: the overlay carries the style

    @Test("L-47: an area exported in blue with a fill imports in blue with that fill, not grey and unoutlined")
    func overlayCarriesTheStyle() async throws {
        let source = try await Fix2Harness.make("L47 Overlay.pdf")
        defer { source.tearDown() }
        let drawing = try #require(source.document.drawing)
        let page = drawing.pages[0]
        let blue = RGBAColor(red: 0x1A / 255.0, green: 0x55 / 255.0, blue: 0xCF / 255.0)
        let style = MarkupStyle(color: blue, fill: RGBAColor(red: blue.red, green: blue.green, blue: blue.blue, alpha: 0.2), lineWidth: 2)
        let area = MarkupRecord(
            id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Slab", style: style,
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 300), PDFPoint(x: 100, y: 300)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date()
        )
        _ = try await source.core.commands.perform(.addMarkup(area))
        await source.settle()
        let stored = try #require(await source.records().first).style
        #expect(stored.color == blue)
        let data = try #require(try await MeasurementOverlayTransfer.overlayData(for: source.document))
        let overlayURL = source.directory.appendingPathComponent("A.zpdfoverlay")
        try data.write(to: overlayURL)

        let copyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("l47-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copyDirectory) }
        let copyURL = copyDirectory.appendingPathComponent("Copy.pdf")
        try FileManager.default.copyItem(at: drawing.url, to: copyURL)
        let target = try await Fix2Harness.make("unused.pdf", fixture: copyURL)
        defer { target.document.close() }
        let plan = try #require(await MeasurementOverlayTransfer.importOverlay(from: overlayURL, into: target.document))
        #expect(plan.records.count == 1)
        await target.settle()
        let imported = try #require(await target.records().first)
        // Old output: `MarkupStyle.default` — black, no fill, width 1.
        #expect(imported.style == stored)
        #expect(imported.style.color == blue)
        #expect(imported.style.fill == style.fill)
        // L-48: one measurement is "1 measurement".
        let note = try #require(target.core.document.warnings.first { $0.id == MeasurementOverlayTransfer.resultNoteID })
        #expect(note.title == "Imported 1 measurement from “A.zpdfoverlay”", "\(note.title)")
    }

    @Test("L-47: an overlay written before styles travelled takes the row's Colour, with the area fill")
    func olderOverlayTakesTheColourCell() throws {
        let row = try #require(try ZenitOverlayImporter().document(from: Data("""
        {"format":"zenit.measurement.overlay","schemaVersion":1,"generatedAt":"2026-09-23T12:00:00Z",
         "producer":{"application":"Zenit PDF","package":"ZPDFExport","ledgerContractVersion":1,"formulaGrammarVersion":1},
         "source":{"fileName":"A.pdf","pageCount":1,"digest":{"algorithm":"SHA-256","sha256":"\(String(repeating: "ab", count: 32))","byteCount":1}},
         "numberLocale":{"identifier":"invariant","decimalSeparator":".","groupingSeparator":null},
         "columns":[], "measurements":[{"row":{"markupID":"M1","index":0,"groupPath":[],"cells":[]},"geometry":null,
         "placement":{"pageIndex":0,"tool":"area","parameters":null}}]}
        """.utf8)).measurements.first)
        let style = MeasurementOverlayTransfer.style(of: row, tool: .area, colorHex: "#1A55CFFF")
        #expect(abs(style.color.red - 0x1A / 255.0) < 1e-9 && abs(style.color.blue - 0xCF / 255.0) < 1e-9)
        #expect(style.fill?.alpha == MarkupFillDefaults.derivedAreaFillAlpha)
        let line = MeasurementOverlayTransfer.style(of: row, tool: .length, colorHex: "")
        #expect(line.fill == nil, "a line has no fill")
        #expect(MeasurementOverlayTransfer.color(hex: "#zz") == nil)
    }

    // MARK: - L-48: singular forms

    @Test("L-48: one is singular — cells, changes, measurements, areas, sheets, files")
    func singularForms() async throws {
        #expect(SpreadsheetRoundTrip.applyButtonTitle(changeCount: 1) == "Apply 1 Change")
        #expect(SpreadsheetRoundTrip.applyButtonTitle(changeCount: 3) == "Apply 3 Changes")
        #expect(SpreadsheetRoundTrip.resultTitle(applied: 1, fileName: "L.xlsx") == "Applied 1 change from “L.xlsx”")
        #expect(SpreadsheetRoundTrip.resultTitle(applied: 2, fileName: "L.xlsx") == "Applied 2 changes from “L.xlsx”")
        #expect(BatchFileCommand.stepsHeadline(fileCount: 1) == "Process 1 PDF file?")
        #expect(BatchFileCommand.stepsHeadline(fileCount: 4) == "Process 4 PDF files?")
        #expect(ZenitPDFProjectDocument.setExportedNote(sheetCount: 1) == "1 sheet exported. No drawing was changed.")
        let menu = ZenitAppCommandTable.menuPath(for: .applyRedactions)
        #expect(RedactionWorkflow.markedNote(areas: 1, sheets: 1) == "1 area marked for redaction on 1 sheet. \(menu) removes it.")
        #expect(RedactionWorkflow.markedNote(areas: 3, sheets: 2) == "3 areas marked for redaction on 2 sheets. \(menu) removes them.")
        let (one, _) = RedactionWorkflow.confirmation(markCount: 1, sheetCount: 1, assessment: nil)
        #expect(one.messageText == "Redact 1 area on 1 sheet into a new file?")
        let (two, _) = RedactionWorkflow.confirmation(markCount: 2, sheetCount: 2, assessment: nil, drawingNames: ["A", "B"])
        #expect(two.messageText == "Redact 2 areas on 2 sheets of 2 drawings into a new file for each drawing?")
        var outcome = RedactionOutcome(redactedPages: [0], markCount: 1, removedWordCount: 1, checks: ["checked"])
        #expect(RedactionWorkflow.resultMessage(outcome).hasPrefix("1 area removed on 1 sheet. Checked: checked."))
        outcome.method = .vector
        outcome.vectorPages = [0]
        #expect(RedactionWorkflow.resultMessage(outcome).contains("1 sheet kept sharp; 0 became pictures."))
    }

    // MARK: - L-63: the redaction status note

    @Test("L-63: the 'checking' note gives way once the confirmation is up, and clearing the marks says so")
    func redactionNoteIsReplaced() async throws {
        let harness = try await Fix2Harness.make("L63 Redaction.pdf")
        defer { harness.tearDown() }
        let page = try #require(harness.document.drawing?.pages.first)
        RedactionWorkflow.add(CGRect(x: 100, y: 100, width: 50, height: 30), onPage: page.id.rawValue, to: harness.document, canvas: nil)
        defer { RedactionWorkflow.clear(harness.document, canvas: nil) }
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in
            request.identifier == RedactionWorkflow.confirmIdentifier ? .button(1) : .dismissed
        }
        defer { ZenitModalPresenter.reset() }
        harness.controller.applyRedactions(for: harness.document)
        #expect(harness.core.status.snapshot.activeToolNote == RedactionWorkflow.checkingNote)
        #expect(await AppTestSupport.wait { ZenitModalPresenter.didRequest(RedactionWorkflow.confirmIdentifier) })
        // Old output: "Checking which marked sheets can stay sharp…" for as long as the window lived.
        #expect(await AppTestSupport.wait { harness.core.status.snapshot.activeToolNote != RedactionWorkflow.checkingNote })
        RedactionWorkflow.clear(harness.document, canvas: nil)
        #expect(harness.core.status.snapshot.activeToolNote == "Redaction marks cleared.")
    }

    @Test("L-63: a written copy replaces the progress note with its result")
    func redactionResultReplacesTheNote() async throws {
        let harness = try await Fix2Harness.make("L63 Written.pdf")
        defer { harness.tearDown() }
        let page = try #require(harness.document.drawing?.pages.first)
        RedactionWorkflow.add(CGRect(x: 100, y: 100, width: 50, height: 30), onPage: page.id.rawValue, to: harness.document, canvas: nil)
        defer { RedactionWorkflow.clear(harness.document, canvas: nil) }
        harness.core.status.setActiveToolNote(RedactionWorkflow.checkingNote)
        let output = harness.directory.appendingPathComponent("L63 — Redacted.pdf")
        let copies = try await RedactionWorkflow.applyAll(document: harness.document, to: .file(output), keepSharp: false)
        #expect(copies.count == 1)
        #expect(harness.core.status.snapshot.activeToolNote == "Redacted copy saved as “L63 — Redacted.pdf”")
    }

    // MARK: - L-52: the searchable copy asks first

    @Test("L-52: with no recognised text the refusal comes first and no save panel is shown")
    func searchableCopyRefusesBeforeThePanel() async throws {
        let harness = try await Fix2Harness.make("L52 Scan.pdf")
        defer { harness.tearDown() }
        ZenitModalPresenter.reset()
        ZenitErrorPresenter.reset()
        defer { ZenitModalPresenter.reset(); ZenitErrorPresenter.reset() }
        #expect(!(await SearchableCopyExport.hasRecognisedText(harness.document)))
        // The menu command's own path: File ▸ Export Drawing ▸ Save Searchable Copy….
        harness.controller.saveSearchableCopy(for: harness.document)
        #expect(await AppTestSupport.wait { !ZenitErrorPresenter.recorded.isEmpty })
        // Old output: the save panel first, and the refusal only after Save.
        #expect(!ZenitModalPresenter.didRequest(SearchableCopyExport.panelIdentifier))
        #expect(ZenitErrorPresenter.lastRecorded as? SearchableCopyExport.Refusal == .nothingRecognised)
    }

    // MARK: - L-56: Export Arranged Set proposes a name of its own

    @Test("L-56: Export Arranged Set proposes “<name> — Arranged Set.pdf”, never the drawing's own name")
    func arrangedSetProposesItsOwnName() async throws {
        let harness = try await Fix2Harness.make("Set-3sheets.pdf", pageCount: 3)
        defer { harness.tearDown() }
        #expect(ZenitPDFProjectDocument.arrangedSetFileName(displayName: "Set-3sheets") == "Set-3sheets — Arranged Set.pdf")
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        defer { ZenitModalPresenter.reset() }
        harness.document.exportArrangedSet(window: nil)
        #expect(await AppTestSupport.wait { ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.exportArrangedSetPanelIdentifier) })
        let request = try #require(ZenitModalPresenter.recorded.last { $0.identifier == ZenitPDFProjectDocument.exportArrangedSetPanelIdentifier })
        let drawingName = try #require(harness.document.drawing?.url.lastPathComponent)
        // Old output: "Set-3sheets.pdf" — the drawing's own name, in its own folder.
        #expect(request.detail != drawingName)
        #expect(request.detail.hasSuffix(" — Arranged Set.pdf"), "\(request.detail)")
    }

    // MARK: - L-62: signature stamps

    @Test("L-62: a signature stamp has a short name, its own category, and the same picture twice is refused")
    func signatureStampNameCategoryAndDuplicate() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "L62 Signature.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("A. Berg.png")
        try NLPDFR2SignatureStampTests.signaturePNG(at: image)
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: directory.appendingPathComponent("L62.zpdfproj"), ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let core = try #require(document.core)
        guard case let .added(presetID) = await SignatureImageStamp.add(imageAt: image, to: document) else {
            Issue.record("the first import was refused"); return
        }
        let preset = try #require(core.toolLibrary.presets.first { $0.id == presetID })
        // Old output: "Signature image — not a digital signature (A. Berg)", cut to
        // "Signature image — not…" in the Tool Library, filed under Review.
        #expect(preset.name == "Signature image (A. Berg)")
        #expect(preset.category == "Signatures")
        #expect(preset.category != DefaultToolSet.reviewCategory)
        let count = core.toolLibrary.presets.count
        // Old output: a second, identical tool, without a word.
        guard case let .refused(reason) = await SignatureImageStamp.add(imageAt: image, to: document) else {
            Issue.record("the same picture was added twice"); return
        }
        #expect(reason.contains("already in the Tool Library as “Signature image (A. Berg)”"), "\(reason)")
        #expect(core.toolLibrary.presets.count == count)
    }

    // MARK: - L-66: the job-template chooser

    /// Not a regression test for L-66: the old extension lookup resolved to the same declared
    /// type, so this passes on the old code too. It pins the chooser to the configuration every
    /// working chooser shares; L-66 itself is open until a live single-click Open reproduces it.
    @Test("L-66 (consistency, not the cause): the job-template chooser asks for the declared template type and chooses one file")
    func jobTemplateChooserType() {
        let panel = ProjectWindowController.jobTemplateOpenPanel()
        let type = ProjectWindowController.jobTemplateType
        #expect(panel.allowedContentTypes == [type])
        #expect(panel.canChooseFiles && !panel.canChooseDirectories && !panel.allowsMultipleSelection)
        #expect(type.conforms(to: .json))
        #expect(type.preferredFilenameExtension == JobTemplateFile.fileExtension)
        // The declared identifier when the bundle exports it — the rule the choosers that work
        // follow — and never a bare extension lookup.
        if let declared = UTType(ProjectWindowController.jobTemplateTypeIdentifier), declared.isDeclared {
            #expect(type == declared)
        }
    }

    // MARK: - L-67: Create Pack

    @Test("L-67: the pack takes the name the person gives the file, proposes “My library”, and names no author unless asked")
    func createPackNameAndAuthor() async throws {
        try await R2PlatformAppTests.withScratchStores { folder in
            #expect(try ExportProfileLibrary.standard().install(LedgerExportProfile(name: "Väster Testmall", columns: [.init(key: "subject")])) == false)
            let destination = folder.appendingPathComponent("Office kit.zpdfpack")
            ZenitModalPresenter.reset()
            ZenitModalPresenter.handler = { request in
                request.identifier == ZenitPackFlow.saveIdentifier ? .urls([destination]) : .dismissed
            }
            defer { ZenitModalPresenter.reset() }
            ZenitPackFlow.createPack(document: nil, window: nil)
            #expect(await AppTestSupport.wait { FileManager.default.fileExists(atPath: destination.path) })
            let request = try #require(ZenitModalPresenter.recorded.last { $0.identifier == ZenitPackFlow.saveIdentifier })
            // Old output: the open document's name ("Form.zpdfpack").
            #expect(request.detail == "My library.zpdfpack")
            let pack = try ZenitPack.read(Data(contentsOf: destination))
            // Old output: pack name "Form" and author the Settings name, unasked.
            #expect(pack.manifest.name == "Office kit")
            #expect(pack.manifest.author == nil)
            #expect(pack.items.map(\.path) == ["profiles/Väster Testmall.zpdfprofile"])
            // Asked: the box writes the author.
            let named = folder.appendingPathComponent("Named.zpdfpack")
            try await ZenitPackFlow.writePack(to: named, author: "A. Berg", document: nil)
            #expect(try ZenitPack.read(Data(contentsOf: named)).manifest.author == "A. Berg")
            #expect(ZenitPackFlow.authorCheckbox(author: "A. Berg").state == .off)
        }
    }

    // MARK: - L-81: an inserted image keeps its resolution

    static func writeJPEG(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(3)
        for x in stride(from: 20, to: width, by: 40) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        context.strokePath()
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(context.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
    }

    @Test("L-81: Edit ▸ Insert Image draws the picture from its full pixels, not its 96-cell mosaic")
    func insertedImageKeepsItsPixels() async throws {
        let harness = try await Fix2Harness.make("L81 Image.pdf", calibrate: false)
        defer { harness.tearDown() }
        _ = try await Iter1ShellGlueTests.saveAsProject(harness, name: "L81.zpdfproj")
        let jpeg = harness.directory.appendingPathComponent("Sketch.jpg")
        try Self.writeJPEG(width: 2_400, height: 1_600, to: jpeg)
        #expect(await MarkupRound2Actions.insertImage(from: jpeg, document: harness.document) == nil)
        await harness.settle()
        let pageView = harness.canvas.pageViewForTesting
        // Old output: no pixels — the canvas drew the stored 96 × 64 mosaic at every zoom.
        #expect(await AppTestSupport.wait { pageView.insertedImagePixels.values.contains { $0.width == 2_400 && $0.height == 1_600 } })
        let rep = try #require(pageView.bitmapImageRepForCachingDisplay(in: pageView.visibleRect))
        pageView.cacheDisplay(in: pageView.visibleRect, to: rep)
        #expect(pageView.insertedImagesDrawnInLastPass == 1)
    }

    @Test("L-81: the pixels are decoded within the import's bounds, and a picture past them is refused undecoded")
    func insertedImageDecodeBounds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l81-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = folder.appendingPathComponent("Big.jpg")
        try Self.writeJPEG(width: 2_400, height: 1_600, to: jpeg)
        let image = try #require(InsertedImagePixels.decode(try Data(contentsOf: jpeg)))
        #expect(image.width == 2_400 && image.height == 1_600, "kept at full resolution")
        #expect(InsertedImagePixels.decode(Data("not an image".utf8)) == nil)
        // Re-fix: a real picture past the bound. 7 000 × 6 000 = 42 MP of 8-bit grey, a readable
        // PNG whose header says so; refused from that header, before a pixel is decoded. (The
        // first version of this test only fed bytes that were no image at all.)
        let width = 7_000, height = 6_000
        let grey = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        grey.setFillColor(gray: 1, alpha: 1)
        grey.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let big = folder.appendingPathComponent("Huge.png")
        let writer = try #require(CGImageDestinationCreateWithURL(big as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(grey.makeImage()), nil)
        #expect(CGImageDestinationFinalize(writer))
        let bytes = try Data(contentsOf: big)
        let declared = try #require(RenderImagePixels.declaredPixelSize(bytes), "the header must be readable")
        #expect(declared.width * declared.height > ArtworkLimits.maximumRasterPixels)
        #expect(InsertedImagePixels.decode(bytes) == nil)
    }

    /// Re-fix (independent check of L-81): the canvas drew the picture from its pixels, and print,
    /// the flattened PDF, the annotated export and the snippet still painted it as its 96-cell
    /// mosaic — sharp on screen, blocks on paper. Old output: no image anywhere in those paths; the
    /// picture was 96 × 64 filled squares.
    @Test("L-81: print, the flattened PDF, the annotated export and the snippet paint the picture from its pixels")
    func insertedImageReachesPaperAtFullResolution() async throws {
        let harness = try await Fix2Harness.make("L81 Paper.pdf", calibrate: false)
        defer { harness.tearDown() }
        _ = try await Iter1ShellGlueTests.saveAsProject(harness, name: "L81 Paper.zpdfproj")
        let jpeg = harness.directory.appendingPathComponent("Sketch.jpg")
        try Self.writeJPEG(width: 2_400, height: 1_600, to: jpeg)
        #expect(await MarkupRound2Actions.insertImage(from: jpeg, document: harness.document) == nil)
        await harness.settle()
        let document = harness.document
        let resolve: (String) async -> ArtworkGeometry? = { [weak document] digest in
            guard let package = document?.projectPackage else { return nil }
            return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
        }
        func pictures(_ markups: [RenderableMarkup]) -> [RenderImage] {
            markups.compactMap { markup in
                if case let .image(image) = markup.shape { return image }
                return nil
            }
        }
        func mosaicCells(_ markups: [RenderableMarkup]) -> Int {
            markups.filter { markup in
                if case .filledPolygon = markup.shape { return true }
                return false
            }.count
        }

        // Print and the flattened PDF: one job, the one painter.
        let job = try await FlattenedDrawingExport.job(for: document, artwork: resolve)
        let sheet = job.pages.flatMap(\.markups)
        #expect(pictures(sheet).count == 1)
        #expect(mosaicCells(sheet) == 0, "the mosaic must not be painted under or instead of the picture")
        let flattened = try FlattenedPDFWriter().data(shape: .flattened, pages: job.pages, content: nil)
        let text = String(decoding: flattened, as: UTF8.self)
        #expect(text.contains("/Subtype /Image") || text.contains("/Subtype/Image"))
        #expect(text.contains("/Width 2400"), "the picture is embedded at its own 2 400 px")
        #expect(text.contains("/Height 1600"))

        // The picture sits where the canvas draws it: the placement's letterboxed box.
        let placed = try #require(pictures(sheet).first)
        let record = try #require(await harness.records().first { $0.kind == .image })
        let box = try #require(record.geometry?.points)
        let corners = placed.corners
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let left = min(box[0].x, box[1].x), right = max(box[0].x, box[1].x)
        let bottom = min(box[0].y, box[1].y), top = max(box[0].y, box[1].y)
        #expect(xs.min()! >= left - 0.01 && xs.max()! <= right + 0.01, "\(corners) in \(box)")
        #expect(ys.min()! >= bottom - 0.01 && ys.max()! <= top + 0.01, "\(corners) in \(box)")
        // 2 400 : 1 600 letterboxed: the drawn box keeps the picture's 3 : 2.
        let drawnWidth = xs.max()! - xs.min()!, drawnHeight = ys.max()! - ys.min()!
        #expect(abs(drawnWidth / drawnHeight - 1.5) < 0.01, "\(drawnWidth) × \(drawnHeight)")

        // The annotated export: the image annotation's appearance is the picture.
        let annotated = try await StandardAnnotationExport.job(for: document, artwork: resolve)
        let appearance = annotated.pages.flatMap(\.annotations).flatMap(\.appearance)
        #expect(pictures(appearance).count == 1)
        #expect(mosaicCells(appearance) == 0)

        // The snippet.
        let page = try #require(document.drawing?.pages.first)
        let snippet = await SnippetExport.renderables(
            core: harness.core, page: page.id.rawValue, artwork: resolve, package: document.projectPackage
        )
        #expect(pictures(snippet).count == 1)
        #expect(mosaicCells(snippet) == 0)
    }

    @Test("L-81: on the canvas a fine picture keeps its lines where its mosaic would merge them")
    func insertedImageDrawsSharperThanTheMosaic() throws {
        // 400 × 400 px of 2-px black and white bars, in a 100-point box at 4×: 400 view pixels
        // across, one per image pixel, so the bars are resolved; the mosaic fallback here is a
        // single block and resolves none.
        let side = 400
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 0, to: side, by: 4) { context.fill(CGRect(x: x, y: 0, width: 2, height: side)) }
        let image = try #require(context.makeImage())
        let block = ArtworkGeometry(kind: .raster, regions: [ArtworkRegion(
            outer: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1), PDFPoint(x: 0, y: 1)],
            color: RGBAColor(red: 0.5, green: 0.5, blue: 0.5)
        )], sourceAspectRatio: 1)
        var placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: 50, y: 50), widthPoints: 100, heightPoints: 100, rotationDegrees: 0,
            artwork: block, artworkKind: .raster
        )
        placement.rasterImageDigest = "digest"
        func transitions(pixels: [String: CGImage]) throws -> Int {
            let view = CanvasPageView()
            view.transform = PageDisplayTransform(pageBox: PDFRectValue(x: 0, y: 0, width: 100, height: 100), rotation: 0, zoom: 4, origin: .zero)
            view.backingScaleOverride = 1
            view.insertedImagePixels = pixels
            view.shapes = [CanvasMarkupShape(
                id: UUID(), pageID: UUID(), color: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1),
                strokes: [], counts: [], stamp: placement, bounds: placement.boundingBox,
                hidden: false, caption: nil, kind: .image
            )]
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            var count = 0
            var previous = false
            let row = rep.pixelsHigh / 2
            for x in 0..<rep.pixelsWide {
                let dark = (rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.3
                if dark != previous { count += 1 }
                previous = dark
            }
            return count
        }
        let sharp = try transitions(pixels: ["digest": image])
        let mosaic = try transitions(pixels: [:])
        // Old output: the mosaic path only — no bar resolved.
        #expect(sharp > 150, "\(sharp)")
        #expect(mosaic < 10, "\(mosaic)")
    }

    // MARK: - L-45: the print panel's section has room

    @Test("L-45: the print panel's Drawing section arrives at the size its controls need, none overlapping")
    func printAccessoryHasItsSize() throws {
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 400, height: 300), crop: PDFRect(x: 0, y: 0, width: 400, height: 300)),
            rotation: .degrees0
        )
        let view = DocumentPrintView(
            sheets: [.init(flatten: FlattenPage(page: page, sourcePageIndex: 0, markups: []))],
            content: nil, slotSize: CGSize(width: 400, height: 300)
        )
        let stamp = Date()
        view.scopeRecords = ["Walls", "Floors"].map { subject in
            MarkupRecord(id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .length,
                         subject: subject, createdAt: stamp, modifiedAt: stamp)
        }
        view.currentPageID = page.id.rawValue
        let accessory = PrintOptionsAccessory(printView: view)
        let root = accessory.view
        // Old output: (0, 0) — the panel gave the section no room, and its controls overlapped
        // each other and "Media & Quality" below.
        #expect(root.frame.width >= root.fittingSize.width - 0.5)
        #expect(root.frame.height >= root.fittingSize.height - 0.5)
        #expect(root.frame.height > 200, "\(root.frame)")
        root.layoutSubtreeIfNeeded()
        // Every checkbox, inside the section and clear of every other.
        func checkboxes(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { sub -> [NSButton] in
                if let button = sub as? NSButton, button.frame.width > 0 { return [button] + checkboxes(in: sub) }
                return checkboxes(in: sub)
            }
        }
        let frames = checkboxes(in: root).map { $0.convert($0.bounds, to: root) }
        #expect(frames.count >= 5, "\(frames.count)")
        for frame in frames {
            #expect(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) outside \(root.bounds)")
        }
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                #expect(!frame.insetBy(dx: 1, dy: 1).intersects(other.insetBy(dx: 1, dy: 1)), "\(frame) overlaps \(other)")
            }
        }
    }
}
