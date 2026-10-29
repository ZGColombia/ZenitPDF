import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Quantities report, bugs 5 and 6: the measurement trace and the live-formula workbook were
/// built in the packages and unreachable from the export dialog.
@Suite("Quantities — export wiring", .appTierSerialised)
@MainActor
struct NLQuantitiesExportTests {

    /// One calibrated page labelled "A-101" (0.1 m/pt, i.e. 1:… by the page's ratio) with two
    /// 40 × 30 pt rectangles.
    func makeCore() async throws -> (AppCoreEnvironment, TakeoffSession, [MarkupID], PageID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let core = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await core.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        var ids: [MarkupID] = []
        for index in 0..<2 {
            let id = MarkupID(UUID())
            let stamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            try await core.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
                id: id,
                documentID: documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .area,
                subject: "Slab",
                author: "Tester",
                geometry: MeasurementGeometry(
                    pageID: page.id,
                    polygons: [PolygonGeometry(outer: PolygonRing(points: [
                        PDFPoint(x: 0, y: 0), PDFPoint(x: 40, y: 0),
                        PDFPoint(x: 40, y: 30), PDFPoint(x: 0, y: 30)
                    ], isClosed: true))]
                ),
                createdAt: stamp,
                modifiedAt: stamp
            )))
            ids.append(id)
        }
        await core.ledger.refresh()
        return (core, session, ids, page.id)
    }

    @Test("Asked for, every row carries its sheet, the scale it was measured at, and its author")
    func exportCarriesTheTrace() async throws {
        let (core, session, ids, pageID) = try await makeCore()
        let scale = try #require(await session.pageScale(pageID))
        let expectedScale = scale.label ?? ScaleBridge.ratioText(for: scale)

        // Old code: nothing called the resolver and the options had no `rowTraces`, so the
        // projection's `carriesRowTraces` was false and no format printed a trace column.
        let traces = await ProjectWindowController.exportRowTraces(core: core)
        for id in ids {
            let trace = try #require(traces[id.rawValue.uuidString])
            #expect(trace.sheetLabel == "A-101")
            #expect(trace.scaleAtMeasureTime == expectedScale)
            #expect(trace.author == "Tester")
        }

        let projection = try await ProjectWindowController.projectionWithDiagnostics(
            core: core,
            documentName: "Takeoff",
            scaleDescription: nil,
            request: core.ledger.request,
            rowTraces: traces
        ).projection
        #expect(projection.table.carriesRowTraces)
        for row in projection.table.rows where !row.markupID.isEmpty {
            #expect(row.trace?.scaleText == expectedScale)
        }

        // The CSV the dialog writes from the presenter carries the same six columns.
        let csv = LedgerCSVExport.render(
            presenter: core.ledger,
            traces: Dictionary(uniqueKeysWithValues: traces.compactMap { key, trace in
                UUID(uuidString: key).map { ($0, trace) }
            })
        )
        #expect(csv.contains("Trace: Scale"))
        #expect(csv.contains("A-101"))

        // Not asked for: the plain files are unchanged — no trace columns anywhere.
        let plain = try await ProjectWindowController.projection(
            core: core, documentName: "Takeoff", scaleDescription: nil, request: core.ledger.request
        )
        #expect(!plain.table.carriesRowTraces)
        #expect(!LedgerCSVExport.render(presenter: core.ledger).contains("Trace: Scale"))
    }

    @Test("The export dialog offers the trace and, for a workbook, live formulas")
    func accessoryReachesBothOptions() {
        let panel = NSSavePanel()
        let accessory = ExportAccessoryView(panel: panel)
        accessory.selectForTesting(.xlsx)
        // Old code: `xlsxOptions` never set `includeFormulas`, and no trace checkbox existed.
        #expect(!accessory.liveFormulasCheckbox.isHidden)
        #expect(!accessory.xlsxOptions.includeFormulas)
        accessory.liveFormulasCheckbox.state = .on
        #expect(accessory.xlsxOptions.includeFormulas)

        #expect(!accessory.includesMeasurementTrace)
        accessory.traceCheckbox.state = .on
        #expect(accessory.includesMeasurementTrace)

        accessory.selectForTesting(.csv)
        #expect(accessory.liveFormulasCheckbox.isHidden, "a workbook-only option is not offered for CSV")
        #expect(!accessory.traceCheckbox.accessibilityLabel()!.isEmpty)
    }

    @Test("NL-QTY-14: Selected rows is offered only with a selection, and the CSV says it is a selection")
    func selectedRowsScope() async throws {
        let none = ExportAccessoryView(panel: NSSavePanel(), selectedRowCount: 0)
        #expect(none.scopePopUp.item(at: ExportAccessoryView.Scope.selected.rawValue)?.isEnabled == false)
        #expect(none.scope == .onScreen)
        let some = ExportAccessoryView(panel: NSSavePanel(), selectedRowCount: 7)
        #expect(some.scopePopUp.item(at: ExportAccessoryView.Scope.selected.rawValue)?.isEnabled == true)
        #expect(some.scopePopUp.itemTitles.last?.contains("7") == true)
        some.scopePopUp.selectItem(at: ExportAccessoryView.Scope.selected.rawValue)
        #expect(some.scope == .selected)

        let (core, _, ids, _) = try await makeCore()
        let csv = LedgerCSVExport.render(presenter: core.ledger, onlyMarkups: [ids[0].rawValue])
        #expect(csv.hasPrefix(LedgerCSVExport.selectedBannerKey))
        #expect(csv.contains("1 selected of 2 rows"))
    }

    @Test("NL-QTY-11: a template sets the format, the companions, the page and the footer; saving captures the view")
    func templatesDriveTheAccessory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-accessory-templates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LedgerReportTemplateStore(directory: directory)
        var captured = LedgerRequest(grouping: [.subject])
        captured.visibleColumns = [.subject, .planArea]
        let accessory = ExportAccessoryView(panel: NSSavePanel(), templateStore: store, captureRequest: { captured })
        #expect(accessory.selectedTemplate == nil)

        accessory.selectForTesting(.pdfReport)
        accessory.pageSizePopUp.selectItem(at: 3) // A3 landscape
        accessory.footerField.stringValue = "Zenit Group S.A.S."
        let template = accessory.currentTemplate(named: "Client summary")
        #expect(template.format == .pdfReport)
        #expect(template.pageSize == .a3 && template.landscape)
        #expect(template.grouping == ["subject"])
        #expect(template.columns == ["subject", "planArea"])
        try store.save(template)

        // A fresh dialog: choose the template and every control follows it.
        let again = ExportAccessoryView(panel: NSSavePanel(), templateStore: store, captureRequest: { LedgerRequest() })
        again.selectForTesting(.csv)
        again.templatePopUp.selectItem(at: 1)
        again.apply(try #require(again.selectedTemplate))
        #expect(again.format == .pdfReport)
        let options = again.pdfOptions
        // A3 is 841.89 × 1190.551 pt; landscape puts the long side across.
        #expect(options.pageSize.width == 1190.551 && options.pageSize.height == 841.89)
        #expect(options.footerNote == "Zenit Group S.A.S.")
        #expect(again.selectedTemplate?.request(onScreen: LedgerRequest()).grouping == [.subject])
    }
}
