import CoreGraphics
import Foundation
import ImageIO
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Quantities, round 2: the summary matrix as its own sheet and report page
/// (NL-QTY-09), group sheets and formula columns as cell formulas (NL-QTY-13), and the report's
/// logo and company block (NL-QTY-11).
///
/// The ledger is four areas, chosen so every total is obvious by hand:
///
/// | row | Subject  | Label | Area m² | Perimeter m |
/// |-----|----------|-------|---------|-------------|
/// | 0   | Concrete | A     | 2       | 6           |
/// | 1   | Concrete | B     | 3       | 8           |
/// | 2   | Steel    | A     | 5       | 10          |
/// | 3   | Concrete | A     | 4       | 9           |
///
/// Subject × Label: Concrete/A = 2 + 4 = 6, Concrete/B = 3, Steel/A = 5, Steel/B = nothing.
/// Row totals Concrete 9, Steel 5; column totals A 11, B 3; grand 14.
@Suite("NL quantities round 2 — export", .sharedHeap)
struct NLQuantitiesR2ExportTests {

    static let formulaID = ColumnID(LedgerIdentifiers.deterministicUUID(namespace: "test/r2", name: "edge"))

    static func store() throws -> LedgerStore {
        var definitions = try LedgerColumnSet.standard().columns
        // Perimeter squared plus twice the area, in SI m²: row 0 = 6·6 + 2·2 = 40.
        definitions.append(LedgerColumnDefinition(
            id: formulaID, key: "edge", title: "Edge", kind: .formula, dimension: .area,
            formula: FormulaExpression(source: "Perimeter * Perimeter + Area * 2"),
            isEditable: false, order: definitions.count
        ))
        let columns = try LedgerColumnSet(columns: definitions)
        let rows: [(String, String, Decimal, Decimal)] = [
            ("Concrete", "A", 2, 6), ("Concrete", "B", 3, 8), ("Steel", "A", 5, 10), ("Concrete", "A", 4, 9)
        ]
        let markups = rows.enumerated().map { index, row in
            MarkupRecord(
                id: MarkupID(ExportFixture.uuid(100 + index)),
                documentID: DocumentID(ExportFixture.uuid(-100)),
                pageID: PageID(ExportFixture.uuid(-101)),
                kind: .measurement, tool: .area,
                subject: row.0, label: row.1, comment: "", author: "Ada", status: .open,
                measurement: MeasurementResult(values: [
                    .planArea: .area(row.2), .netArea: .area(row.2), .perimeter: .length(row.3)
                ]),
                createdAt: ExportFixture.epoch, modifiedAt: ExportFixture.epoch
            )
        }
        return try LedgerStore(markups: markups, columns: columns)
    }

    static func id(_ standard: StandardLedgerColumn) -> ColumnID { LedgerIdentifiers.columnID(for: standard) }

    static func projection(grouping: [StandardLedgerColumn]) throws -> ExportProjection {
        let store = try store()
        var plan = LedgerAggregationPlan()
        for column in [id(.planArea), id(.perimeter), formulaID] {
            plan.add(AggregateKey(column: column, function: .sum))
        }
        let spec = LedgerViewSpec(
            grouping: grouping.map { LedgerGroupingField(column: id($0)) }, aggregation: plan
        )
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(spec), title: "R2")
        return try ExportProjector().project(
            report,
            options: ExportProjectionOptions(columnKeys: ["subject", "label", "planArea", "perimeter", "edge"])
        )
    }

    static func matrix() throws -> ExportSummaryMatrix {
        try ExportSummaryMatrix.make(
            nested: projection(grouping: [.subject, .label]),
            across: projection(grouping: [.label]),
            columnKeys: ["planArea"]
        )
    }

    static func value(_ cell: ExportCell) -> Decimal? { cell.number?.raw }

    // MARK: - NL-QTY-09

    @Test("The matrix reshapes the ledger's own subtotals: 6/3, 5/–, rows 9 and 5, columns 11 and 3, grand 14")
    func matrixReconciles() throws {
        let matrix = try Self.matrix()
        #expect(matrix.rowTitles == ["Concrete", "Steel"])
        #expect(matrix.columnTitles == ["A", "B"])
        let block = try #require(matrix.blocks.first)
        #expect(block.cells.map { $0.map(Self.value) } == [[6, 3], [5, nil]])
        #expect(block.cells[1][1] == .blank)
        #expect(block.rowTotals.map(Self.value) == [9, 5])
        #expect(block.columnTotals.map(Self.value) == [11, 3])
        #expect(Self.value(block.grandTotal) == 14)
        // Default column choice: every numeric column with a grand Sum — area, perimeter, edge.
        let all = try ExportSummaryMatrix.make(
            nested: Self.projection(grouping: [.subject, .label]), across: Self.projection(grouping: [.label])
        )
        #expect(all.blocks.map(\.column.key) == ["planArea", "perimeter", "edge"])
        // Perimeter: Concrete 6+8+9 = 23, Steel 10. Edge per row: 36+4 = 40, 64+6 = 70,
        // 100+10 = 110, 81+8 = 89; Concrete 40+70+89 = 199, Steel 110.
        #expect(all.blocks[1].rowTotals.map(Self.value) == [23, 10])
        #expect(all.blocks[2].rowTotals.map(Self.value) == [199, 110])
    }

    @Test("A matrix of the wrong groupings is refused, never built")
    func matrixShapeRefused() throws {
        #expect(throws: ExportError.self) {
            try ExportSummaryMatrix.make(
                nested: Self.projection(grouping: [.subject]), across: Self.projection(grouping: [.label])
            )
        }
    }

    @Test("The workbook gains a Summary sheet with numbers, and live SUMs when formulas are on")
    func summarySheet() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try Self.projection(grouping: [.subject]).withSummaryMatrix(Self.matrix())
        try XLSXExporter().export(projection, to: url, options: XLSXExportOptions(includeFormulas: true))
        let workbook = try XLSXInspector.entry("xl/workbook.xml", of: url)
        #expect(workbook.contains("name=\"Ledger\""))
        #expect(workbook.contains("name=\"Summary\""))
        let summary = try XLSXInspector(url: url, sheet: 2)
        let heading = try Self.matrix().blocks[0].heading
        #expect(heading.hasSuffix("(m²)"))
        #expect(summary.cell("A1")?.value == heading)
        #expect(summary.cell("B2")?.value == "A")
        #expect(summary.cell("D2")?.value == "Total")
        #expect(summary.cell("A3")?.value == "Concrete")
        #expect(summary.cell("B3")?.value == "6")
        #expect(summary.cell("C3")?.value == "3")
        #expect(summary.cell("D3")?.value == "9")
        #expect(summary.cell("B4")?.value == "5")
        #expect(summary.cell("D5")?.value == "14")
        #expect(Self.formula("D3", in: summary.sheetXML) == "SUM(B3:C3)")
        #expect(Self.formula("B5", in: summary.sheetXML) == "SUM(B3:B4)")
        #expect(Self.formula("D5", in: summary.sheetXML) == "SUM(D3:D4)")
        // Without a matrix there is no Summary sheet.
        let plain = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: plain) }
        try XLSXExporter().export(Self.projection(grouping: [.subject]), to: plain)
        #expect(!(try XLSXInspector.entry("xl/workbook.xml", of: plain)).contains("name=\"Summary\""))
    }

    @Test("The report prints the matrix on its own page with the same text")
    func summaryPage() throws {
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try Self.projection(grouping: [.subject]).withSummaryMatrix(Self.matrix())
        let result = try PDFReportRenderer().render(
            projection, to: url, options: PDFReportOptions(recordsDrawnText: true)
        )
        let plain = try PDFReportRenderer().render(
            Self.projection(grouping: [.subject]), to: temporaryURL("pdf"), options: PDFReportOptions()
        )
        #expect(result.matrixPageCount == 1)
        #expect(result.pageCount == plain.pageCount + 1)
        let text = result.drawnMatrixText
        // Header, then each line: title, cells, total — the projection's own text.
        let heading = try Self.matrix().blocks[0].heading
        #expect(text.contains("\(heading) — subject × label"))
        let concrete = try #require(text.firstIndex(of: "Concrete"))
        #expect(Array(text[concrete...concrete + 3]) == ["Concrete", "6.000", "3.000", "9.000"])
        let steel = try #require(text.firstIndex(of: "Steel"))
        #expect(Array(text[steel...steel + 3]) == ["Steel", "5.000", "", "5.000"])
        #expect(Array(text.suffix(4)) == ["Total", "11.000", "3.000", "14.000"])
    }

    // MARK: - NL-QTY-13

    @Test("A formula column over exported columns is a cell formula with the engine's result cached")
    func formulaColumnAsCellFormula() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(
            Self.projection(grouping: []), to: url,
            options: XLSXExportOptions(includeUnitColumns: false, includeSubtotalRows: false, includeGrandTotalRows: false, includeFormulas: true)
        )
        let sheet = try XLSXInspector(url: url)
        // Columns without the record and unit columns: A Subject, B Label, C Plan Area,
        // D Perimeter, E Edge.
        #expect(sheet.cell("E1")?.value == "Edge (m)" || sheet.cell("E1")?.value.hasPrefix("Edge") == true)
        #expect(Self.formula("E2", in: sheet.sheetXML) == "((D2*D2)+(C2*2))")
        #expect(sheet.cell("E2")?.value == "40")   // 6·6 + 2·2
        #expect(Self.formula("E5", in: sheet.sheetXML) == "((D5*D5)+(C5*2))")
        #expect(sheet.cell("E5")?.value == "89")   // 9·9 + 4·2
        // Off: no formula anywhere.
        let off = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: off) }
        try XLSXExporter().export(Self.projection(grouping: []), to: off)
        #expect(!(try XLSXInspector(url: off)).sheetXML.contains("<f>"))
    }

    @Test("Translation refuses what a spreadsheet would compute differently")
    func translationRefusals() throws {
        let columns = try Self.projection(grouping: []).table.columns
        #expect(XLSXRowFormula.translate("Perimeter % 2", columns: columns) == nil)
        #expect(XLSXRowFormula.translate("COALESCE(Perimeter, 0)", columns: columns) == nil)
        #expect(XLSXRowFormula.translate("Volume * 2", columns: columns) == nil) // not exported
        let ceiling = try #require(XLSXRowFormula.translate("CEILING(Area / 2)", columns: columns))
        #expect(ceiling.render(row: 2) { [0, 1, 2, 3, 4][$0] }
            == "IF((C2/2)<0,ROUNDDOWN((C2/2),0),ROUNDUP((C2/2),0))")
        let negative = try #require(XLSXRowFormula.translate("-Area ^ 2", columns: columns))
        // The engine binds `-` and `^` at the same power; every operator is parenthesised.
        #expect(negative.render(row: 3) { $0 }.contains("C3"))
    }

    @Test("Group sheets: one sheet per top-level group, named after it, with its rows and subtotal")
    func groupSheets() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = XLSXExportOptions(includeUnitColumns: false)
        options.includeGroupSheets = true
        try XLSXExporter().export(Self.projection(grouping: [.subject]), to: url, options: options)
        let workbook = try XLSXInspector.entry("xl/workbook.xml", of: url)
        #expect(workbook.contains("name=\"Concrete\""))
        #expect(workbook.contains("name=\"Steel\""))
        let concrete = try XLSXInspector(url: url, sheet: 2)
        let records = concrete.cells.filter { $0.column == 0 }.map(\.value)
        #expect(records == ["Record", "Row", "Row", "Row", "Subtotal: Sum"])
        let steel = try XLSXInspector(url: url, sheet: 3)
        #expect(steel.cells.filter { $0.column == 0 }.map(\.value) == ["Record", "Row", "Subtotal: Sum"])
        // Plan Area is column D (Record, Group: subject, Subject, Label, Plan Area): Concrete 9.
        let subtotal = try #require(concrete.cells.first { $0.row == 4 && $0.column == 4 })
        #expect(subtotal.value == "9")
    }

    @Test("Sheet names are sanitised and unique")
    func sheetNames() {
        var names = XLSXExporter.SheetNames()
        #expect(names.claim("Ledger") == "Ledger")
        #expect(names.claim("ledger") == "ledger (2)")
        #expect(names.claim("A/B: [x]?") == "A_B_ _x__")
        #expect(names.claim("History") == "Sheet")
        #expect(names.claim(String(repeating: "x", count: 40)).count == 31)
    }

    // MARK: - NL-QTY-11

    @Test("The cover draws the logo and every company-block line")
    func logoAndCompanyBlock() throws {
        var options = PDFReportOptions(recordsDrawnText: true)
        options.logoImageData = try Self.png(width: 280, height: 56)
        options.companyBlock = "Zenit Group S.A.S.\n  Calle 1 # 2-3  \n\nBogotá"
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(Self.projection(grouping: []), to: url, options: options)
        #expect(result.drewLogo)
        #expect(result.drawnCompanyLines == ["Zenit Group S.A.S.", "Calle 1 # 2-3", "Bogotá"])
        // Unreadable bytes draw nothing and fail nothing.
        options.logoImageData = Data([1, 2, 3])
        let broken = try PDFReportRenderer().render(Self.projection(grouping: []), to: url, options: options)
        #expect(!broken.drewLogo)
    }

    @Test("Page images: each sheet through the flatten sequence, sized to fit, titled with its label")
    func pageImages() throws {
        // 400 × 300 pt at a 2 000 px longest side would be 5 px/pt; capped at 2 px/pt: 800 × 600.
        #expect(PDFReportSheetImages.pixelSize(paper: CGSize(width: 400, height: 300))! == (800, 600))
        // An A1 sheet, 2 384 × 1 684 pt: longest side 2 000, the other 1 684·2000/2384 = 1 412.75 → 1 413.
        #expect(PDFReportSheetImages.pixelSize(paper: CGSize(width: 2384, height: 1684))! == (2000, 1413))
        #expect(PDFReportSheetImages.pixelSize(paper: .zero) == nil)
        let sheet = FlattenPage(
            page: FlattenedPDFWriterTests.page(index: 0),
            sourcePageIndex: 0,
            markups: [FlattenedPDFWriterTests.polyline(from: PDFPoint(x: 20, y: 30), to: PDFPoint(x: 300, y: 200))]
        )
        let result = PDFReportSheetImages.render(pages: [sheet], content: nil)
        #expect(result.skipped.isEmpty)
        let page = try #require(result.pages.first)
        #expect(page.title == "1")
        #expect(page.caption == "1 markup")
        #expect(page.image.width == 800 && page.image.height == 600)
        // The appendix page lands in the report.
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try PDFReportRenderer().render(Self.projection(grouping: []), to: url)
        let withImages = try PDFReportRenderer().render(Self.projection(grouping: []), to: url, appendix: result.pages)
        #expect(withImages.pageCount == plain.pageCount + 1)
        // Through bytes and back — how the app hands them to the background writer.
        let encoded = PDFReportSheetImages.encode(result.pages)
        #expect(encoded.failed.isEmpty)
        let decoded = PDFReportSheetImages.decode(encoded.images)
        #expect(decoded.map(\.title) == ["1"])
        #expect(decoded.first?.image.width == 800 && decoded.first?.image.height == 600)
    }

    // MARK: - NL-COLLAB-16

    @Test("A text table workbook: guarded formula text, a snapshot per row, rows sized to it")
    func textTableWithSnapshots() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try Self.png(width: 480, height: 120)
        try XLSXTextTableExporter.export(XLSXTextTable(
            sheetName: "Review",
            header: ["Page", "Note"],
            rows: [["A-101", "=HYPERLINK(\"x\")"], ["A-102", "plain"]],
            images: [snapshot, nil]
        ), to: url)
        let sheet = try XLSXInspector(url: url)
        #expect(sheet.cell("A1")?.value == "Page")
        #expect(sheet.cell("C1")?.value == "Snapshot")
        #expect(sheet.cell("B2")?.value == "=HYPERLINK(\"x\")", "text, not a formula")
        #expect(!sheet.sheetXML.contains("<f>"))
        #expect(try XLSXInspector.entry("xl/styles.xml", of: url).contains("quotePrefix=\"1\""))
        // One picture, the first row's.
        #expect(!(try XLSXInspector.entry("xl/media/image1.png", of: url)).isEmpty)
        #expect((try XLSXInspector.entry("xl/media/image2.png", of: url)).isEmpty)
        // 480 × 120 px fits the 240 × 120 box at half size: 60 px tall → 45 pt + 4.
        #expect(XLSXTextTableExporter.imageScale(width: 480, height: 120) == 0.5)
        #expect(sheet.sheetXML.contains("ht=\"49\""))
        #expect(XLSXTextTableExporter.imageScale(width: 10, height: 10) == 1, "never enlarged")
    }

    // MARK: - NL-QTY-15 phase 2

    @Test("The batch workbook: Combined, one sheet per project, Not Included; totals are numbers")
    func subjectSummaryWorkbook() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXSubjectSummaryWorkbook(
            title: "Batch",
            combined: [.init(subject: "Slab", unit: "m²", rowCount: 2, value: 14, decimalPlaces: 2)],
            projects: [
                .init(name: "North", lines: [.init(subject: "Slab", unit: "m²", rowCount: 1, value: 12, decimalPlaces: 2)]),
                .init(name: "South", lines: [.init(subject: "Slab", unit: "m²", rowCount: 1, value: 2, decimalPlaces: 2)])
            ],
            notIncluded: [["Bogus", "not a project"]]
        ).export(to: url)
        let workbook = try XLSXInspector.entry("xl/workbook.xml", of: url)
        for name in ["Combined", "North", "South", "Not Included"] {
            #expect(workbook.contains("name=\"\(name)\""), "\(name)")
        }
        let combined = try XLSXInspector(url: url, sheet: 1)
        #expect(combined.cell("A2")?.value == "Slab")
        #expect(combined.cell("D2")?.type == nil, "a number, not text")
        #expect(combined.cell("D2")?.value == "14")
        #expect(try combined.rendered(try #require(combined.cell("D2")), locale: .invariant) == "14.00")
        let refused = try XLSXInspector(url: url, sheet: 4)
        #expect(refused.cell("A2")?.value == "Bogus")
    }

    // MARK: - Helpers

    static func formula(_ reference: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<c r=\"\(reference)\""),
              let close = xml.range(of: "</c>", range: open.upperBound..<xml.endIndex) else { return nil }
        let body = xml[open.upperBound..<close.lowerBound]
        guard let f = body.range(of: "<f>"), let end = body.range(of: "</f>") else { return nil }
        return String(body[f.upperBound..<end.lowerBound])
    }

    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
