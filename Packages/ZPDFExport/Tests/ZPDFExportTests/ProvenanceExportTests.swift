import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// ADR-0012 rule 4 — every exporter prints each row's quantity provenance.
///
/// The two tests that matter most are the ends of the see-saw: a ledger that mixes the three
/// claims labels **every** row in every format, and a ledger of nothing but measured rows
/// exports exactly the bytes it always did. Between them sits the refusal: a file claiming a
/// fourth kind of provenance is malformed, not believed.
@Suite("Provenance export (ADR-0012 rule 4)", .sharedHeap)
struct ProvenanceExportTests {

    // MARK: - Fixture

    /// Three rows, one per claim, in store order: measured, derived, read.
    static func mixedStore() throws -> LedgerStore {
        let columns = try ExportFixture.columnSet()
        let documentID = DocumentID(ExportFixture.uuid(-21))
        let pageID = PageID(ExportFixture.uuid(-22))

        func markup(
            _ index: Int,
            subject: String,
            provenance: QuantityProvenance,
            derivation: QuantityDerivation?
        ) -> MarkupRecord {
            MarkupRecord(
                id: MarkupID(ExportFixture.uuid(index)),
                documentID: documentID,
                pageID: pageID,
                kind: .measurement,
                tool: .area,
                subject: subject,
                label: "P\(index)",
                author: "Ada",
                // ADR-0016: the Plan Area column reads the net area; the engine writes both fields.
                measurement: MeasurementResult(values: [
                    .planArea: .area(Decimal(index + 1) / 4),
                    .netArea: .area(Decimal(index + 1) / 4)
                ]),
                provenance: provenance,
                derivation: derivation,
                createdAt: ExportFixture.epoch.addingTimeInterval(Double(index) * 60),
                modifiedAt: ExportFixture.epoch.addingTimeInterval(Double(index) * 60 + 30)
            )
        }

        let markups = [
            markup(0, subject: "Concrete", provenance: .measured, derivation: nil),
            markup(1, subject: "Steel", provenance: .derived, derivation: QuantityDerivation(
                sourceMarkupID: MarkupID(ExportFixture.uuid(0)),
                formulaText: "studs = wall.length / spacing",
                inputs: ["wall.length": "4.5", "spacing": "0.45"],
                originIdentifier: "assembly:wall-studs"
            )),
            markup(2, subject: "Glazing", provenance: .read, derivation: QuantityDerivation(
                formulaText: "Door D-102: 12",
                originIdentifier: "page 1, region (120, 84, 220, 40)"
            ))
        ]
        return try LedgerStore(markups: markups, columns: columns)
    }

    static func mixedProjection(
        rowTraces: [String: ExportRowTrace] = [:]
    ) throws -> ExportProjection {
        let store = try mixedStore()
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(
                store.makeView(LedgerViewSpec(aggregation: ExportFixture.plan)),
                title: "Mixed provenance ledger"
            )
        return try ExportProjector().project(
            report,
            options: ExportProjectionOptions(rowTraces: rowTraces)
        )
    }

    private func records(_ data: Data) -> [[String]] {
        CSVReader.records(String(decoding: data, as: UTF8.self), delimiter: ",")
    }

    // MARK: - CSV

    @Test("The CSV carries a Provenance column with every row's claim, appended last")
    func csvCarriesTheColumn() throws {
        let projection = try Self.mixedProjection()
        #expect(projection.table.carriesProvenanceLabels)

        let rows = records(try CSVExporter().export(projection))
        let header = rows[0]
        let column = try #require(header.firstIndex(of: "Provenance"))
        // Appended after every existing column: with no trace columns it is the last field,
        // so a reader built against the old header reads the old fields at the old indices.
        #expect(column == header.count - 1)

        let kind = try #require(header.firstIndex(of: "Record"))
        let dataRows = rows.dropFirst().filter { $0[kind] == "Row" }
        // Every row is labelled — the measured one included, because in a mixed file an
        // unlabelled row is exactly the ambiguity the ADR forbids.
        #expect(dataRows.map { $0[column] } == ["measured", "derived", "read"])

        // A total aggregates rows whose claims differ; it has no provenance of its own.
        let totals = rows.dropFirst().filter { $0[kind] != "Row" }
        #expect(!totals.isEmpty)
        for total in totals { #expect(total[column].isEmpty) }
        // And no record is ragged for it.
        #expect(Set(rows.map(\.count)).count == 1)
    }

    @Test("With trace columns present, Provenance precedes the trace tail")
    func csvOrderAgainstTraceColumns() throws {
        var traces: [String: ExportRowTrace] = [:]
        for index in 0..<3 {
            traces[MarkupID(ExportFixture.uuid(index)).rawValue.uuidString] = ExportRowTrace(
                sheetLabel: "A-2\(index)",
                scaleAtMeasureTime: "1:50",
                author: "Ada"
            )
        }
        let projection = try Self.mixedProjection(rowTraces: traces)
        let header = records(try CSVExporter().export(projection))[0]
        let column = try #require(header.firstIndex(of: "Provenance"))
        // The trace columns stay the conditional tail (feature 16's contract, asserted by
        // TraceableExportTests); the provenance column joins the always-present columns
        // immediately before them.
        #expect(Array(header.suffix(ExportRowTrace.columnTitles.count)) == ExportRowTrace.columnTitles)
        #expect(column == header.count - ExportRowTrace.columnTitles.count - 1)
    }

    // MARK: - JSON

    @Test("The JSON carries a provenance key on every row and round-trips byte for byte")
    func jsonCarriesTheKey() throws {
        let projection = try Self.mixedProjection()
        let data = ZenitJSONExporter().export(projection)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"provenance\": \"measured\""))
        #expect(text.contains("\"provenance\": \"derived\""))
        #expect(text.contains("\"provenance\": \"read\""))

        let document = try ZenitJSONImporter().document(from: data)
        try ZenitInterchangeImport.validate(document)
        #expect(document.rows.map(\.provenance) == ["measured", "derived", "read"])

        // Export, import, re-export: byte-identical, labels and all.
        #expect(ZenitJSONExporter().encode(document) == data)
    }

    @Test("A file claiming a fourth kind of provenance is refused, not believed")
    func jsonRefusesAFourthClaim() throws {
        let projection = try Self.mixedProjection()
        var text = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        text = text.replacingOccurrences(
            of: "\"provenance\": \"read\"",
            with: "\"provenance\": \"guessed\""
        )
        let document = try ZenitJSONImporter().document(from: Data(text.utf8))
        #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.validate(document)
        }
    }

    // MARK: - XLSX

    @Test("The XLSX carries a Provenance header and a string cell per row, appended last")
    func xlsxCarriesTheColumn() throws {
        let projection = try Self.mixedProjection()
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)

        let sheet = try XLSXInspector(url: url)
        let header = sheet.cells.filter { $0.row == 0 }
        let provenanceColumn = try #require(
            header.first { $0.value == "Provenance" }?.column
        )
        // Appended last: no header cell sits to its right.
        #expect(provenanceColumn == header.map(\.column).max())

        // The claims travel as shared strings — the reader the task names.
        #expect(sheet.sharedStrings.contains("read"))
        #expect(sheet.sharedStrings.contains("derived"))
        #expect(sheet.sharedStrings.contains("measured"))

        // Store order: header row 0, then measured, derived, read.
        for (row, expected) in [(1, "measured"), (2, "derived"), (3, "read")] {
            let cell = try #require(
                sheet.cells.first { $0.row == row && $0.column == provenanceColumn }
            )
            #expect(cell.value == expected)
        }
    }

    // MARK: - PDF

    @Test("The PDF marks derived and read rows and prints the legend")
    func pdfMarksAndLegend() throws {
        let projection = try Self.mixedProjection()
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(
            projection,
            to: url,
            options: PDFReportOptions(recordsDrawnText: true)
        )
        // The legend on the table page, and one mark per non-measured row (rule 5's glyphs).
        // BH-528: the marks are recorded in drawnMarks, not in the one-entry-per-cell drawnText.
        #expect(result.drawnMarks.contains(Painter.provenanceLegend))
        #expect(result.drawnMarks.contains("\u{0192}")) // ƒ — derived
        #expect(result.drawnMarks.contains("\u{2310}")) // ⌐ — read
        #expect(result.drawnText.count % result.printedColumnCount == 0)
    }

    // MARK: - The additive proof

    @Test("A pure-measured ledger exports exactly what it always did, in all four formats")
    func pureMeasuredIsUnchanged() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        #expect(!projection.table.carriesProvenanceLabels)
        for row in projection.table.allRows() {
            #expect(row.makesMeasuredClaim)
        }

        // CSV: no Provenance column.
        #expect(!records(try CSVExporter().export(projection))[0].contains("Provenance"))

        // JSON: no provenance key anywhere, so the round trip stays byte-identical.
        let json = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        #expect(!json.contains("\"provenance\""))

        // XLSX: no Provenance header cell.
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)
        let sheet = try XLSXInspector(url: url)
        #expect(!sheet.cells.contains { $0.row == 0 && $0.value == "Provenance" })

        // PDF: no legend and no mark.
        let pdfURL = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let result = try PDFReportRenderer().render(
            projection, to: pdfURL, options: PDFReportOptions(recordsDrawnText: true)
        )
        #expect(!result.drawnMarks.contains(Painter.provenanceLegend))
        #expect(!result.drawnMarks.contains("\u{0192}"))
        #expect(!result.drawnMarks.contains("\u{2310}"))

        // And a construction site that predates the field still compiles and still means
        // "someone measured this": the default is the old world, verbatim.
        let row = ExportRow(markupID: "m", storeIndex: 0, groupPath: [], cells: [])
        #expect(row.provenance == "measured")
        #expect(row.provenanceGlyph == nil)
    }
}
