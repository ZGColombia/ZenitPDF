import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Live test 8, L-46 and L-46b: the workbook, the printed report and the export profiles read as
/// the ledger and its CSV do — the ledger's column titles, a page number counted from 1, the
/// ledger's number locale, the Unit column filled, no counts under columns of words, and no
/// contract or grammar versions on the report's cover.
///
/// The ledger here is built on the shipping built-in column set (whose report titles are the
/// keys) and the shipping aggregation plan (a Count of every column), as the application's is.
/// Hand-derived values: the slab is 12.5 m² on sheet A-101, the first page of its PDF (index 0);
/// the wall is 1 234.5 m on sheet A-103, the third page (index 2). Two decimals, Swedish locale:
/// "12,50" and "1 234,50" with a no-break space between the thousands.
@Suite("L-46 — the ledger's words in every projected format", .sharedHeap)
struct L8ExportPresentationTests {

    static let slab = ExportFixture.uuid(801)
    static let wall = ExportFixture.uuid(802)

    static let visible: [StandardLedgerColumn] = [
        .icon, .subject, .comment, .pageLabel, .pageIndex, .planLength, .planArea, .displayUnit, .costCode
    ]

    /// What the application's ledger titles these columns (`LedgerBridge.standardTitle`).
    static let titles: [String: String] = [
        "icon": "Type", "subject": "Subject", "comment": "Comment", "pageLabel": "Page",
        "pageIndex": "Page index", "planLength": "Plan Length", "planArea": "Plan Area",
        "displayUnit": "Unit", "costCode": "Cost Code"
    ]

    static var presentation: LedgerExportPresentation {
        LedgerExportPresentation(
            columnTitles: titles,
            rowUnitTexts: [slab.uuidString: "m²", wall.uuidString: "m"],
            rowTypeTexts: [slab.uuidString: "Area", wall.uuidString: "Length"],
            groupLabels: ["t:area": "Area", "t:length": "Length"],
            numberLocale: .svSE
        )
    }

    static func report(grouped: Bool = false) throws -> LedgerReport {
        let columns = try LedgerColumnSet.standard(displayPolicy: DisplayUnitPolicy(precision: .decimalPlaces(2)))
        let documentID = DocumentID(ExportFixture.uuid(-801))
        let first = PageID(ExportFixture.uuid(-802))
        let third = PageID(ExportFixture.uuid(-803))
        let names = LedgerNameCatalog(pages: [
            first: LedgerPageInfo(label: "A-101", index: 0),
            third: LedgerPageInfo(label: "A-103", index: 2)
        ])
        let stamp = ExportFixture.epoch
        let markups = [
            MarkupRecord(
                id: MarkupID(slab), documentID: documentID, pageID: first, kind: .measurement, tool: .area,
                subject: "Slab", author: "A. Berg",
                measurement: MeasurementResult(values: [.planArea: .area(Decimal(string: "12.5")!), .netArea: .area(Decimal(string: "12.5")!)]),
                createdAt: stamp, modifiedAt: stamp
            ),
            MarkupRecord(
                id: MarkupID(wall), documentID: documentID, pageID: third, kind: .measurement, tool: .length,
                subject: "Wall", author: "A. Berg",
                measurement: MeasurementResult(values: [.planLength: .length(Decimal(string: "1234.5")!)]),
                createdAt: stamp, modifiedAt: stamp
            )
        ]
        let store = try LedgerStore(markups: markups, columns: columns, names: names)
        let spec = LedgerViewSpec(
            grouping: grouped ? [LedgerGroupingField(column: LedgerIdentifiers.columnID(for: .subject))] : [],
            aggregation: LedgerAggregationPlan.standard(for: columns),
            visibleColumns: visible.map { LedgerIdentifiers.columnID(for: $0) }
        )
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(spec), title: "Plan — Quantity Ledger")
    }

    static func projection(grouped: Bool = false, presentation: LedgerExportPresentation = presentation) throws -> ExportProjection {
        try ExportProjector().project(try report(grouped: grouped), options: .ledgerExport(
            documentName: "Plan", scaleDescription: "1:50", preparedBy: "A. Berg", screenDecimalPlaces: 2,
            timeZone: .gmt, presentation: presentation
        ))
    }

    static func index(_ key: String, in table: ExportTable) throws -> Int {
        try #require(table.columns.firstIndex { $0.key == key }, "no column \(key)")
    }

    static func row(_ id: UUID, in table: ExportTable) throws -> ExportRow {
        try #require(table.allRows().first { $0.markupID == id.uuidString })
    }

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("l8-exportio-\(UUID().uuidString).\(ext)")
    }

    // MARK: - The projection

    @Test("The projection carries the ledger's titles, the Unit, a page number from 1 and the ledger's locale")
    func projectionReadsAsTheLedger() throws {
        let table = try Self.projection().table
        // Old output: the titles were the keys — "icon", "pageLabel", "pageIndex", "planArea",
        // "displayUnit", "costCode" — and the workbook headed Plan Area "planArea (m²)".
        #expect(table.columns.map(\.title) == Self.visible.map { Self.titles[$0.rawValue]! })
        let area = try Self.index("planArea", in: table)
        #expect(table.columns[area].heading(sharesUnit: true) == "Plan Area (m²)")

        let unit = try Self.index("displayUnit", in: table)
        let page = try Self.index("pageIndex", in: table)
        let length = try Self.index("planLength", in: table)
        let slab = try Self.row(Self.slab, in: table)
        let wall = try Self.row(Self.wall, in: table)
        // Old output: the Unit cell was blank on every row (L-25 was fixed for the CSV only).
        #expect(slab.cells[unit].text == "m²")
        #expect(wall.cells[unit].text == "m")
        // Old output: "area" and "length" — the tool's token, which the ledger never shows.
        let type = try Self.index("icon", in: table)
        #expect(slab.cells[type].text == "Area")
        #expect(wall.cells[type].text == "Length")
        // Old output: "0" and "2" — the PDF's position of the sheet, counted from 0.
        #expect(slab.cells[page].text == "1")
        #expect(wall.cells[page].text == "3")
        // The stored index is still the exact value the interchange JSON carries.
        #expect(slab.cells[page].number?.raw == 0)
        #expect(wall.cells[page].number?.raw == 2)
        #expect(wall.cells[page].number?.convertedRaw == 3)
        // Old output: "12.50" and "1234.50" under "Number locale invariant".
        #expect(slab.cells[area].text == "12,50")
        #expect(wall.cells[length].text == "1\u{00A0}234,50")
        #expect(table.metadata.numberLocaleIdentifier == "sv-SE")
    }

    @Test("A Type group is headed by the tool's name, as the ledger heads it")
    func typeGroupHeadings() throws {
        let options = ExportProjectionOptions.ledgerExport(
            documentName: "Plan", scaleDescription: nil, preparedBy: "A. Berg", screenDecimalPlaces: 2,
            presentation: Self.presentation
        )
        let projection = try ExportProjector().project(try Self.typeGroupedReport(), options: options)
        // Old output: the headings were the tokens "area" and "length", under "Grouping icon".
        #expect(projection.table.groups.map(\.label) == ["Area", "Length"])
        #expect(projection.table.groups.map(\.printedLabel) == ["Area", "Length"])
        #expect(projection.table.metadata.groupingColumnTitles == ["Type"])
    }

    static func typeGroupedReport() throws -> LedgerReport {
        let columns = try LedgerColumnSet.standard(displayPolicy: DisplayUnitPolicy(precision: .decimalPlaces(2)))
        let documentID = DocumentID(ExportFixture.uuid(-811))
        let page = PageID(ExportFixture.uuid(-812))
        let stamp = ExportFixture.epoch
        let markups = [
            MarkupRecord(
                id: MarkupID(slab), documentID: documentID, pageID: page, kind: .measurement, tool: .area,
                subject: "Slab", author: "A. Berg",
                measurement: MeasurementResult(values: [.planArea: .area(1), .netArea: .area(1)]),
                createdAt: stamp, modifiedAt: stamp
            ),
            MarkupRecord(
                id: MarkupID(wall), documentID: documentID, pageID: page, kind: .measurement, tool: .length,
                subject: "Wall", author: "A. Berg",
                measurement: MeasurementResult(values: [.planLength: .length(1)]),
                createdAt: stamp, modifiedAt: stamp
            )
        ]
        let store = try LedgerStore(markups: markups, columns: columns)
        let spec = LedgerViewSpec(
            grouping: [LedgerGroupingField(column: LedgerIdentifiers.columnID(for: .icon))],
            aggregation: LedgerAggregationPlan.standard(for: columns),
            visibleColumns: visible.map { LedgerIdentifiers.columnID(for: $0) }
        )
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(spec), title: "Plan — Quantity Ledger")
    }

    @Test("Without the ledger's words the projection keeps the report's, as before")
    func withoutPresentationTheReportTitlesStay() throws {
        let table = try Self.projection(presentation: LedgerExportPresentation()).table
        #expect(table.columns.map(\.title) == Self.visible.map(\.rawValue))
        let unit = try Self.index("displayUnit", in: table)
        #expect(try Self.row(Self.slab, in: table).cells[unit] == .blank)
        #expect(table.metadata.numberLocaleIdentifier == "invariant")
    }

    @Test("Two columns the ledger titles alike are told apart by their key")
    func duplicateTitlesAreDisambiguated() throws {
        var presentation = Self.presentation
        presentation.columnTitles["costCode"] = "Subject"
        let table = try Self.projection(presentation: presentation).table
        #expect(table.columns.map(\.title).filter { $0.hasPrefix("Subject") } == ["Subject (subject)", "Subject (costCode)"])
    }

    @Test("A counting total says nothing under a column of words")
    func countLinesSkipTextColumns() throws {
        let table = try Self.projection().table
        let count = try #require(table.grandTotals.first { $0.function == "Count" })
        let printed = table.printedCells(of: count)
        // Old output: the core counts every column, and the report and the workbook printed
        // those counts — "2" under Type, Subject and Page.
        for key in ["icon", "subject", "pageLabel"] {
            #expect(count.cells[try Self.index(key, in: table)].text == "2", "\(key)")
        }
        for key in ["icon", "subject", "comment", "pageLabel", "displayUnit", "costCode"] {
            #expect(printed[try Self.index(key, in: table)] == .blank, "\(key)")
        }
        // A count under a quantity column stays: one row carries a plan area.
        #expect(printed[try Self.index("planArea", in: table)].text == "1")
        // The machine formats keep every aggregate.
        #expect(count.cells[try Self.index("subject", in: table)].text == "2")
    }

    // MARK: - The workbook

    @Test("L-46: the workbook heads its columns as the ledger does and fills Unit")
    func workbookHeadersAndUnit() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try Self.projection(grouped: true)
        try XLSXExporter().export(projection, to: url)
        let sheet = try XLSXInspector(url: url)
        let header = sheet.cells.filter { $0.row == 0 }.sorted { $0.column < $1.column }.map(\.value)
        // Old output: "Group: subject", "icon", "subject", …, "planArea (m²)", "displayUnit", "costCode".
        #expect(header.contains("Group: Subject"))
        #expect(header.contains("Plan Area (m²)"))
        #expect(header.contains("Unit"))
        #expect(header.contains("Page"))
        #expect(!header.contains { ["icon", "pageLabel", "pageIndex", "displayUnit", "costCode"].contains($0) || $0.hasPrefix("planArea") })

        func value(row: Int, header title: String) throws -> String? {
            let column = try #require(sheet.cells.first { $0.row == 0 && $0.value == title }?.column, "no header \(title)")
            return sheet.cells.first { $0.row == row && $0.column == column }?.value
        }
        let subjectColumn = try #require(sheet.cells.first { $0.row == 0 && $0.value == "Subject" }?.column)
        let slabRow = try #require(sheet.cells.first { $0.column == subjectColumn && $0.value == "Slab" }?.row)
        #expect(try value(row: slabRow, header: "Unit") == "m²")
        #expect(try value(row: slabRow, header: "Page index") == "1")
        // The grand Count line writes nothing under Subject (a bold blank cell at most); the old
        // workbook wrote the core's count, 2.
        let record = try #require(sheet.cells.first { $0.row > 0 && $0.value == "Total: Count" }?.row)
        #expect(try value(row: record, header: "Subject") ?? "" == "")
        #expect(try value(row: record, header: "Plan Area (m²)") == "1")
    }

    // MARK: - The printed report

    @Test("L-46: the report's cover names columns as the ledger does and carries no contract versions")
    func reportCover() throws {
        let projection = try Self.projection(grouped: true)
        let entries = Painter.coverEntries(projection.table.metadata)
        let labels = entries.map(\.label)
        // Old output: "Number locale invariant", "Ledger contract v1", "Formula grammar v1",
        // "Grouping subject" and "Filter ALL".
        #expect(!labels.contains("Number locale"))
        #expect(!labels.contains("Ledger contract"))
        #expect(!labels.contains("Formula grammar"))
        #expect(entries.first { $0.label == "Grouping" }?.value == "Subject")
        #expect(entries.first { $0.label == "Filter" }?.value == "(none)")

        // The provenance is in the document information instead.
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(projection, to: url, options: PDFReportOptions(recordsDrawnText: true))
        let document = try #require(CGPDFDocument(url as CFURL))
        let info = try #require(document.info)
        var keywords: CGPDFStringRef?
        #expect(CGPDFDictionaryGetString(info, "Keywords", &keywords))
        let text = try #require(keywords.flatMap { CGPDFStringCopyTextString($0) as String? })
        #expect(text.contains("Ledger contract v\(ContractVersion.ledger)"))
        #expect(text.contains("Number locale sv-SE"))

        // The body: the page numbers from 1, Swedish decimals, the Unit, and no count under Subject.
        #expect(result.drawnText.contains("12,50"))
        #expect(result.drawnText.contains("m²"))
        #expect(result.drawnLabels.contains("Count (all rows)"))
        #expect(result.drawnText.contains("A-103"))
        // The two Page index cells, in the slab's and the wall's row: 1 and 3, not 0 and 2.
        let page = try Self.index("pageIndex", in: projection.table)
        #expect(projection.table.allRows().map { $0.cells[page].printedText } == ["1", "3"])
        let lines = PDFReportRenderer.flatten(table: projection.table, options: PDFReportOptions())
        for line in lines {
            guard case let .grandTotal(function, cells) = line, function == "Count" else { continue }
            #expect(cells[try Self.index("subject", in: projection.table)] == .blank)
        }
    }

    @Test("The sort and the filter read in words on the cover")
    func coverSortInWords() throws {
        let metadata = try Self.projection().table.metadata
        let level = ExportProjector.printedSortLevel("planArea:desc:nullsLast", report: try Self.report(), options: .ledgerExport(
            documentName: "Plan", scaleDescription: nil, preparedBy: "A. Berg", screenDecimalPlaces: 2, presentation: Self.presentation
        ))
        #expect(level == "Plan Area, descending")
        #expect(metadata.printedFilterDescription == "(none)")
    }

    @Test("An interchange file written before L-46 still reconciles: Type and Unit compare across the two spellings")
    func olderInterchangeFileReconciles() throws {
        let older = ZenitJSONExporter().document(from: try Self.projection(presentation: LedgerExportPresentation()))
        let current = ZenitJSONExporter().document(from: try Self.projection())
        let verdict = ZenitLedgerReconciliation.compare(imported: older, against: current)
        // Old output: both rows "differ" — Type "area" against "Area", a blank Unit against "m²".
        #expect(verdict.isExactMatch, "\(verdict.differences)")
        #expect(verdict.rowsIdentical == 2)
        // A real change in Type is still one.
        #expect(!ZenitLedgerReconciliation.agreeAcrossSpellings(.text("area"), .text("Length"), columnKey: "icon"))
        #expect(!ZenitLedgerReconciliation.agreeAcrossSpellings(.text("m"), .text("m²"), columnKey: "displayUnit"))
        #expect(!ZenitLedgerReconciliation.agreeAcrossSpellings(.blank, .text("x"), columnKey: "subject"))
    }

    // MARK: - Export profiles (L-46b)

    @Test("L-46b: a profile made from the ledger's columns heads them as the ledger does and fills Unit")
    func profileHeadersAndUnit() throws {
        let projection = try Self.projection()
        let profile = LedgerExportProfile(
            name: "Office",
            columns: projection.table.columns.map { .init(key: $0.key, header: $0.title) }
        )
        var lineFeed = profile
        lineFeed.encoding = .utf8
        lineFeed.lineEnding = .lf
        let text = String(decoding: try lineFeed.render(projection).data, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        // Old output: "icon;subject;comment;pageLabel;pageIndex;planLength;planArea;displayUnit;costCode",
        // and a blank Unit on every row.
        #expect(lines.first == "Type;Subject;Comment;Page;Page index;Plan Length;Plan Area;Unit;Cost Code")
        let slab = try #require(lines.first { $0.contains("Slab") }).split(separator: ";", omittingEmptySubsequences: false)
        #expect(slab[7] == "m²")
        #expect(slab[4] == "1")
        #expect(slab[6] == "12,50")
    }
}

/// Live test 8, L-47: an area drawn in blue (`#1A55CF`) arrived on the other copy of the drawing
/// grey and without an outline, because the overlay carried its geometry and not its style. The
/// placement now carries the markup's style as the contract's JSON, additively.
@Suite("L-47 — the overlay carries each measurement's style", .sharedHeap)
struct L8OverlayStyleTests {

    static let style = #"{"color":{"alpha":1,"blue":0.8117647058823529,"green":0.3333333333333333,"red":0.10196078431372549},"fill":{"alpha":0.2,"blue":0.8117647058823529,"green":0.3333333333333333,"red":0.10196078431372549},"lineWidth":1,"opacity":1}"#

    static func document(placement: ZenitOverlayDocument.Placement?) throws -> ZenitOverlayDocument {
        let row = ZenitInterchangeDocument.Row(markupID: "M1", index: 0, groupPath: [], cells: [])
        return ZenitOverlayDocument(
            schemaVersion: 1, generatedAt: "2026-10-04T08:00:00Z",
            producer: .init(application: "Zenit PDF", package: "ZPDFExport", ledgerContractVersion: 1, formulaGrammarVersion: 1),
            source: .init(fileName: "A-101.pdf", pageCount: 1, digestSHA256: String(repeating: "cd", count: 32), digestByteCount: 99),
            columns: [],
            numberLocale: .init(identifier: "sv-SE", decimalSeparator: ",", groupingSeparator: nil),
            measurements: [.init(row: row, geometry: nil, placement: placement)]
        )
    }

    @Test("The style is written and read back verbatim; a placement without one is the bytes it was")
    func styleRoundTrips() throws {
        let placement = ZenitOverlayDocument.Placement(pageIndex: 0, tool: "area", parametersJSON: nil, styleJSON: Self.style)
        let written = ZenitOverlayExporter().encode(try Self.document(placement: placement))
        // Old output: no "style" member — the reader handed the importer geometry only.
        #expect(String(decoding: written, as: UTF8.self).contains(#""style""#))
        let read = try ZenitOverlayImporter().document(from: written)
        #expect(read.measurements.first?.placement?.styleJSON == Self.style)
        #expect(read.measurements.first?.placement == placement)

        let plain = ZenitOverlayDocument.Placement(pageIndex: 0, tool: "area", parametersJSON: nil)
        let older = String(decoding: ZenitOverlayExporter().encode(try Self.document(placement: plain)), as: UTF8.self)
        #expect(!older.contains(#""style""#))
        #expect(try ZenitOverlayImporter().document(from: Data(older.utf8)).measurements.first?.placement?.styleJSON == nil)
    }

    @Test("A style that is not a string is refused as a malformed overlay")
    func malformedStyleRefused() throws {
        let placement = ZenitOverlayDocument.Placement(pageIndex: 0, tool: "area", parametersJSON: nil, styleJSON: "x")
        let written = String(decoding: ZenitOverlayExporter().encode(try Self.document(placement: placement)), as: UTF8.self)
        let text = written.replacingOccurrences(
            of: #""style"\s*:\s*"x""#, with: #""style":7"#, options: .regularExpression
        )
        #expect(text != written, "the test must have replaced the style")
        #expect(throws: ExportError.self) { try ZenitOverlayImporter().document(from: Data(text.utf8)) }
    }
}
