import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// ADR-0018 through the exporters: the CSV, the XLSX and the snippet caption show the same net
/// number the ledger shows, a cutout row contributes nothing to any total, and the two new
/// columns (Gross Area, Cutout Area) carry the outline and the removed area.
///
/// Hand-derived fixture (every number written before the code ran):
///
/// ```text
/// Slab (Volume tool)  10 x 10 m, cutouts A [1,5]² and B [3,7]² overlapping on [3,5]² = 4 m²
///   gross 100, union 16 + 16 - 4 = 28, net 72, perimeter 40, depth 0.25 → volume 72 * 0.25 = 18
///   under ignore: net 100, volume 100 * 0.25 = 25
/// Roof (True Sloped Area) 20 x 10 m at 1:2, one 4 x 5 m cutout C
///   gross 200, cutout 20, net 180, perimeter 60, true area 180 * sqrt(1.25) = 201.246117974981
///   under ignore: net 200, true area 200 * sqrt(1.25) = 223.606797749979
/// Totals (subtract / report): Plan Area 72 + 180 = 252, Gross 300, Perimeter 100, Volume 18
/// Totals (ignore):            Plan Area 100 + 200 = 300, Gross 300, Perimeter 100, Volume 25
/// ```
@Suite("Fix 3 — cutouts in the exports (ADR-0018)", .sharedHeap, .serialized)
struct Fix3CutoutExportTests {

    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)
    static let slabID = MarkupID(ExportFixture.uuid(7_001))
    static let cutoutAID = MarkupID(ExportFixture.uuid(7_002))
    static let cutoutBID = MarkupID(ExportFixture.uuid(7_003))
    static let roofID = MarkupID(ExportFixture.uuid(7_004))
    static let cutoutCID = MarkupID(ExportFixture.uuid(7_005))

    static let shownColumns: [StandardLedgerColumn] = [
        .subject, .planArea, .grossArea, .cutoutArea, .perimeter, .volume, .trueArea
    ]

    static func columns() throws -> LedgerColumnSet {
        let standard = try LedgerColumnSet.standard()
        let definitions = try shownColumns.enumerated().map { order, column in
            var definition = try #require(standard.column(standard: column))
            definition.order = order
            return definition
        }
        return try LedgerColumnSet(columns: definitions)
    }

    static func record(
        _ id: MarkupID,
        subject: String,
        tool: MeasurementTool,
        policy: CutoutPolicy? = nil,
        values: [MeasurementField: DecimalQuantity],
        parent: MarkupID? = nil,
        cutouts: [MarkupID] = []
    ) -> MarkupRecord {
        MarkupRecord(
            id: id,
            documentID: DocumentID(ExportFixture.uuid(-21)),
            pageID: PageID(ExportFixture.uuid(-22)),
            kind: .measurement,
            tool: tool,
            subject: subject,
            parameters: policy.map { MeasurementParameters(cutoutPolicy: $0) },
            measurement: MeasurementResult(values: values),
            parentMarkupID: parent,
            cutoutMarkupIDs: cutouts,
            createdAt: epoch,
            modifiedAt: epoch
        )
    }

    static func cutout(_ id: MarkupID, subject: String, area: Decimal, perimeter: Decimal, parent: MarkupID) -> MarkupRecord {
        record(
            id, subject: subject, tool: .polygonCutout,
            values: [.planArea: .area(area), .cutoutArea: .area(area), .perimeter: .length(perimeter)],
            parent: parent
        )
    }

    static func store(_ policy: CutoutPolicy) throws -> LedgerStore {
        let ignore = policy == .ignore
        var slab: [MeasurementField: DecimalQuantity] = [
            .planArea: .area(100), .netArea: .area(ignore ? 100 : 72), .perimeter: .length(40),
            .depth: .length(Decimal(string: "0.25")!),
            .volume: .volume(ignore ? 25 : 18)
        ]
        var roof: [MeasurementField: DecimalQuantity] = [
            .planArea: .area(200), .netArea: .area(ignore ? 200 : 180), .perimeter: .length(60),
            .trueArea: .area(Decimal(string: ignore ? "223.606797749979" : "201.246117974981")!)
        ]
        if !ignore {
            slab[.cutoutArea] = .area(28)
            roof[.cutoutArea] = .area(20)
        }
        return try LedgerStore(
            markups: [
                record(slabID, subject: "Slab", tool: .volume, policy: policy, values: slab,
                       cutouts: [cutoutAID, cutoutBID]),
                cutout(cutoutAID, subject: "Slab", area: 16, perimeter: 16, parent: slabID),
                cutout(cutoutBID, subject: "Slab", area: 16, perimeter: 16, parent: slabID),
                record(roofID, subject: "Roof", tool: .trueSlopedArea, policy: policy, values: roof,
                       cutouts: [cutoutCID]),
                cutout(cutoutCID, subject: "Roof", area: 20, perimeter: 18, parent: roofID)
            ],
            columns: columns()
        )
    }

    static func projection(_ policy: CutoutPolicy) throws -> ExportProjection {
        let store = try store(policy)
        let spec = LedgerViewSpec(
            grouping: [LedgerGroupingField(column: LedgerIdentifiers.columnID(for: .subject))],
            aggregation: LedgerAggregationPlan.standard(for: store.columns)
        )
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(epoch))
            .makeReport(store.makeView(spec), title: "Cutouts")
        return try ExportFixture.projection(report)
    }

    static func index(_ column: StandardLedgerColumn, in table: ExportTable) throws -> Int {
        try #require(table.columns.firstIndex { $0.key == column.rawValue })
    }

    static func row(_ id: MarkupID, in table: ExportTable) throws -> ExportRow {
        try #require(table.allRows().first { $0.markupID == id.rawValue.uuidString })
    }

    static func raw(_ cell: ExportCell) -> Decimal? { cell.number?.raw }

    @Test("Row cells: net Plan Area on the parent, nothing on a cutout row, under every policy")
    func rowCells() throws {
        for policy in CutoutPolicy.allCases {
            let table = try Self.projection(policy).table
            let ignore = policy == .ignore
            let plan = try Self.index(.planArea, in: table)
            let gross = try Self.index(.grossArea, in: table)
            let cut = try Self.index(.cutoutArea, in: table)
            let perimeter = try Self.index(.perimeter, in: table)
            let volume = try Self.index(.volume, in: table)
            let trueArea = try Self.index(.trueArea, in: table)

            let slab = try Self.row(Self.slabID, in: table)
            #expect(Self.raw(slab.cells[plan]) == (ignore ? 100 : 72), "\(policy)")
            #expect(Self.raw(slab.cells[gross]) == 100, "\(policy)")
            #expect(Self.raw(slab.cells[cut]) == (ignore ? nil : 28), "\(policy)")
            #expect(Self.raw(slab.cells[volume]) == (ignore ? 25 : 18), "\(policy): Volume = net × depth")
            let roof = try Self.row(Self.roofID, in: table)
            #expect(Self.raw(roof.cells[plan]) == (ignore ? 200 : 180), "\(policy)")
            #expect(Self.raw(roof.cells[trueArea]) == Decimal(string: ignore ? "223.606797749979" : "201.246117974981"))

            for id in [Self.cutoutAID, Self.cutoutBID, Self.cutoutCID] {
                let cutout = try Self.row(id, in: table)
                for column in [plan, gross, perimeter, volume, trueArea] {
                    #expect(cutout.cells[column] == .blank, "\(policy): cutout \(table.columns[column].key)")
                }
                let reported: Decimal? = policy == .subtractAndReportSeparately ? (id == Self.cutoutCID ? 20 : 16) : nil
                #expect(Self.raw(cutout.cells[cut]) == reported, "\(policy): Cutout Area")
            }
        }
    }

    @Test("Subtotals and grand totals ignore cutout rows; Cutout Area is never totalled")
    func totals() throws {
        for policy in CutoutPolicy.allCases {
            let table = try Self.projection(policy).table
            let ignore = policy == .ignore
            let sum = try #require(table.grandTotals.first { $0.function == "Sum" })
            #expect(Self.raw(sum.cells[try Self.index(.planArea, in: table)]) == (ignore ? 300 : 252), "\(policy)")
            #expect(Self.raw(sum.cells[try Self.index(.grossArea, in: table)]) == 300, "\(policy)")
            // Old output: 40 + 16 + 16 + 60 + 18 = 150 — every cutout's own perimeter added.
            #expect(Self.raw(sum.cells[try Self.index(.perimeter, in: table)]) == 100, "\(policy)")
            #expect(Self.raw(sum.cells[try Self.index(.volume, in: table)]) == (ignore ? 25 : 18), "\(policy)")
            #expect(Self.raw(sum.cells[try Self.index(.cutoutArea, in: table)]) == nil, "\(policy)")

            let slabGroup = try #require(table.groups.first { $0.label == "Slab" })
            let slabSum = try #require(slabGroup.subtotals.first { $0.function == "Sum" })
            #expect(slabGroup.rowCount == 3, "\(policy): the parent and its two cutout rows are listed")
            #expect(Self.raw(slabSum.cells[try Self.index(.planArea, in: table)]) == (ignore ? 100 : 72), "\(policy)")
            #expect(Self.raw(slabSum.cells[try Self.index(.perimeter, in: table)]) == 40, "\(policy)")
            let roofGroup = try #require(table.groups.first { $0.label == "Roof" })
            let roofSum = try #require(roofGroup.subtotals.first { $0.function == "Sum" })
            #expect(Self.raw(roofSum.cells[try Self.index(.planArea, in: table)]) == (ignore ? 200 : 180), "\(policy)")
        }
    }

    @Test("CSV and XLSX carry the same values, cell for cell, as the projection the ledger built")
    func csvAndXLSXAgree() throws {
        let csvOptions = CSVExportOptions(
            includeRawColumns: true, includeUnitColumns: false, includeGroupColumns: false,
            includeSubtotalRows: false, includeGrandTotalRows: false
        )
        let xlsxOptions = XLSXExportOptions(
            metadataSheetName: nil, includeRawColumns: false, includeUnitColumns: false,
            includeGroupColumns: false, includeSubtotalRows: false, includeGrandTotalRows: false
        )
        for policy in CutoutPolicy.allCases {
            let projection = try Self.projection(policy)
            let table = projection.table
            let rows = table.allRows()

            // CSV: header, then one record per row; the raw field follows each numeric column.
            let csvText = String(decoding: try CSVExporter().export(projection, options: csvOptions), as: UTF8.self)
            let records = Array(CSVReader.records(csvText, delimiter: csvOptions.delimiter).dropFirst())
            #expect(records.count == rows.count, "\(policy)")
            var csvIndex: [Int] = []
            var csvRawIndex: [Int?] = []
            var position = 0
            for column in table.columns {
                csvIndex.append(position)
                position += 1
                if column.isNumeric { csvRawIndex.append(position); position += 1 } else { csvRawIndex.append(nil) }
            }

            // XLSX, read back from the written file.
            let url = temporaryURL("xlsx")
            defer { try? FileManager.default.removeItem(at: url) }
            try XLSXExporter().export(projection, to: url, options: xlsxOptions)
            let sheet = try XLSXInspector(url: url)

            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, cell) in row.cells.enumerated() {
                    let csvDisplay = records[rowIndex][csvIndex[columnIndex]]
                    #expect(csvDisplay == cell.text, "\(policy) CSV r\(rowIndex) \(table.columns[columnIndex].key)")
                    if let rawIndex = csvRawIndex[columnIndex] {
                        #expect(records[rowIndex][rawIndex] == (cell.number?.invariantRawText ?? ""),
                                "\(policy) CSV raw r\(rowIndex) \(table.columns[columnIndex].key)")
                    }
                    let xlsxCell = sheet.cells.first { $0.row == rowIndex + 1 && $0.column == columnIndex }
                    if cell.number != nil {
                        let written = try #require(xlsxCell, "\(policy) XLSX r\(rowIndex) c\(columnIndex)")
                        #expect(try sheet.rendered(written, locale: projection.numberLocale) == cell.text,
                                "\(policy) XLSX r\(rowIndex) \(table.columns[columnIndex].key)")
                    } else if cell == .blank {
                        #expect(xlsxCell == nil || xlsxCell?.value == "", "\(policy) XLSX blank r\(rowIndex) c\(columnIndex)")
                    } else {
                        #expect(xlsxCell?.value == cell.text, "\(policy) XLSX r\(rowIndex) c\(columnIndex)")
                    }
                }
            }
            // Non-vacuity: the parent's net number really is in both files.
            let slabRow = try #require(rows.firstIndex { $0.markupID == Self.slabID.rawValue.uuidString })
            let planColumn = try Self.index(.planArea, in: table)
            #expect(records[slabRow][csvRawIndex[planColumn]!] == (policy == .ignore ? "100" : "72"))
        }
    }

    @Test("The snippet caption quotes the ledger's net Plan Area")
    func snippetCaptionQuotesNet() throws {
        let projection = try Self.projection(.subtractAndReportSeparately)
        let table = projection.table
        let roof = try Self.row(Self.roofID, in: table)
        let planCell = try #require(roof.cells[try Self.index(.planArea, in: table)].number)
        #expect(planCell.raw == 180)
        let caption = SnippetCaptionBuilder.build(
            detail: .compact,
            markupIDs: [Self.roofID],
            projection: projection,
            source: SnippetSource(documentName: "A-101.pdf", pageIndex: 0)
        )
        let line = try #require(caption.lines.first)
        #expect(line.contains(planCell.text), "\(line) must quote \(planCell.text)")
        #expect(!line.contains("200"), "the gross outline is never the caption's number: \(line)")
    }
}
