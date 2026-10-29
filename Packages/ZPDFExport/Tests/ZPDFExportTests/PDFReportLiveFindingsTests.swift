import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// The two live-test findings the printed report was opened on, LT-18 and LT-19.
///
/// Both are about what a person holding the paper reads, so every assertion here is made against
/// what the renderer actually drew — ``PDFReportOptions/recordsDrawnText`` — or against the pure
/// function that builds the title page, never against what the code was supposed to do.
///
/// Each test also states the **old** output and asserts it can no longer occur. A test that only
/// checks the new string would pass against a report that printed both.
@Suite("PDF report live findings", .sharedHeap)
struct PDFReportLiveFindingsTests {

    // MARK: - The sparse ledger

    /// A three-row takeoff with two columns nothing ever fills — the LT-18 shape, in miniature.
    ///
    /// | column | key | filled? |
    /// |---|---|---|
    /// | Subject | `subject` | every row — and an identity column |
    /// | Label | `label` | every row — and an identity column |
    /// | Status | `status` | every row (a Choice cell: the LT-19 column) |
    /// | Created | `created` | every row (a Date cell: the other half of LT-19) |
    /// | Plan Area | `planArea` | every row |
    /// | Wall Area | `wallArea` | **never** — no row carries a net wall area |
    /// | Volume | `volume` | **never** |
    /// | Unit | `displayUnit` | **never**, and kept anyway: it is an identity column |
    /// | Note | `note` | one row out of three |
    static let epoch = ExportFixture.epoch
    static let noteID = ExportFixture.customID("live-note")

    static func columnSet() throws -> LedgerColumnSet {
        var definitions: [LedgerColumnDefinition] = []
        func append(_ definition: LedgerColumnDefinition) {
            var copy = definition
            copy.order = definitions.count
            definitions.append(copy)
        }
        for standard in [
            StandardLedgerColumn.subject, .label, .status, .created,
            .planArea, .wallArea, .volume, .displayUnit
        ] {
            append(LedgerColumnDefinition(
                id: ExportFixture.standardID(standard),
                key: standard.rawValue,
                title: standard.rawValue,
                kind: standard.kind,
                standard: standard,
                dimension: standard.measurementField == nil ? nil : dimension(of: standard),
                displayUnit: standard.measurementField == nil ? nil : displayUnit(of: standard),
                precision: standard.measurementField == nil ? nil : .decimalPlaces(3),
                choices: standard == .status ? LedgerStatusChoices.options : [],
                defaultChoiceID: standard == .status
                    ? LedgerIdentifiers.choiceOptionID(for: .none)
                    : nil,
                isEditable: standard.isUserEditable
            ))
        }
        append(LedgerColumnDefinition(id: noteID, key: "note", title: "Note", kind: .text))
        return try LedgerColumnSet(columns: definitions)
    }

    private static func dimension(of standard: StandardLedgerColumn) -> QuantityDimension? {
        standard == .volume ? .volume : .area
    }

    private static func displayUnit(of standard: StandardLedgerColumn) -> AnyDisplayUnit? {
        standard == .volume ? .volume(.cubicMetre) : .area(.squareMetre)
    }

    /// The three statuses the rows carry, in row order. `none` first, because "No status" is the
    /// exact cell the live test found a UUID in.
    static let statuses: [MarkupStatus] = [.none, .open, .inProgress]

    static func report() throws -> LedgerReport {
        let columns = try columnSet()
        let documentID = DocumentID(ExportFixture.uuid(-21))
        let pageID = PageID(ExportFixture.uuid(-22))
        let subjects = ["Concrete", "Steel", "Glazing"]
        var markups: [MarkupRecord] = []
        for index in 0..<3 {
            // Plan area only: no net wall area and no volume, so those two columns are blank on
            // every row of the export.
            let area: DecimalQuantity = .area(Decimal(index + 1))
            // ADR-0016: the Plan Area column reads the net area; the engine writes both fields.
            let measurement = MeasurementResult(values: [
                MeasurementField.planArea: area, MeasurementField.netArea: area
            ])
            var custom: [ColumnID: LedgerCellValue] = [:]
            if index == 1 { custom[noteID] = .text("checked on site") }
            let created: Date = epoch.addingTimeInterval(Double(index) * 3600)
            markups.append(MarkupRecord(
                id: MarkupID(ExportFixture.uuid(index)),
                documentID: documentID,
                pageID: pageID,
                kind: .measurement,
                tool: .area,
                subject: subjects[index],
                label: "L\(index)",
                author: "Ada",
                status: statuses[index],
                measurement: measurement,
                customValues: custom,
                createdAt: created,
                modifiedAt: created.addingTimeInterval(60)
            ))
        }
        let store = try LedgerStore(markups: markups, columns: columns)
        let view = store.makeView(LedgerViewSpec(aggregation: LedgerAggregationPlan()))
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(epoch))
            .makeReport(view, title: "Sparse ledger")
    }

    static func projection(
        choiceLabels: [String: String] = [:]
    ) throws -> ExportProjection {
        try ExportProjector().project(
            try report(),
            options: ExportProjectionOptions(
                choiceLabels: choiceLabels,
                document: ExportDocumentContext(documentName: "A-101.pdf")
            )
        )
    }

    private static func options(
        droppingEmptyColumns: Bool = true,
        pageSize: PDFReportPageSize = .a4,
        maximumColumnWidth: Double = 160
    ) -> PDFReportOptions {
        PDFReportOptions(
            pageSize: pageSize,
            includeCoverPage: false,
            recordsDrawnText: true,
            maximumColumnWidth: maximumColumnWidth,
            dropsEmptyColumns: droppingEmptyColumns
        )
    }

    private func render(
        _ projection: ExportProjection,
        options: PDFReportOptions
    ) throws -> PDFReportResult {
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        return try PDFReportRenderer().render(projection, to: url, options: options)
    }

    // MARK: - LT-18: empty columns

    @Test("A column blank on every row is dropped; one filled on a single row survives")
    func emptyColumnsAreDropped() throws {
        let projection = try Self.projection()
        let table = projection.table
        #expect(table.columns.map(\.key) == [
            "subject", "label", "status", "created",
            "planArea", "wallArea", "volume", "displayUnit", "note"
        ])

        let options = Self.options()
        let printed = PDFReportRenderer.printedColumns(table: table, options: options)
        let keys = printed.map { table.columns[$0].key }

        // Blank on every row, and gone.
        #expect(!keys.contains("wallArea"))
        #expect(!keys.contains("volume"))
        // Filled on exactly one row of three, and kept: "empty" means empty everywhere.
        #expect(keys.contains("note"))
        #expect(table.rows.filter { !$0.cells[8].text.isEmpty }.count == 1)
        // Blank on every row and kept anyway, because it is one of the identity columns.
        #expect(keys.contains("displayUnit"))
        #expect(table.rows.allSatisfy { $0.cells[7].text.isEmpty })
        #expect(keys == ["subject", "label", "status", "created", "planArea", "displayUnit", "note"])

        let result = try render(projection, options: options)
        #expect(result.printedColumnCount == 7)
        #expect(result.drawnText.count == 3 * 7, "three rows of seven printed columns")

        // The old report, from the very same projection: nine columns, `wallArea` and `volume`
        // among them. If the pruning stopped working, the assertions above would produce this.
        let old = try render(projection, options: Self.options(droppingEmptyColumns: false))
        #expect(old.printedColumnCount == 9)
        #expect(old.drawnText.count == 3 * 9)
        #expect(old.drawnText.count > result.drawnText.count)
    }

    @Test("Bands cover the printed columns and nothing else")
    func bandsCoverOnlyPrintedColumns() throws {
        // Nine columns, of which the report prints four: 0, 1, 4 and 7.
        let widths = [60.0, 60, 60, 60, 60, 60, 60, 60, 60]
        let printed = [0, 1, 4, 7]
        let bands = try PDFReportRenderer.bands(
            widths: widths, usable: 130, options: PDFReportOptions(), columns: printed
        )
        #expect(bands.count > 1, "130 pt cannot hold four 60 pt columns")

        var covered: [Int] = []
        for (index, band) in bands.enumerated() {
            // No band may reach a dropped column — that would put an empty strip back on the page
            // with no heading to explain it.
            #expect(band.columns.allSatisfy { printed.contains($0) })
            #expect(band.identityColumn == printed[0])
            if index > 0 { #expect(band.columns.first == printed[0]) }
            covered.append(contentsOf: index > 0 ? Array(band.columns.dropFirst()) : band.columns)
        }
        #expect(covered == printed, "every printed column, once, in order")

        // The page header counts the printed columns, not the ledger's whole set: the last band
        // must end at "of 4", never "of 9".
        #expect(bands.last?.lastPrintedOrdinal == printed.count)
        #expect(bands.first?.firstPrintedOrdinal == 1)
    }

    @Test("Dropping the empty columns removes the bands and the pages they cost")
    func prunedReportIsShorter() throws {
        let projection = try Self.projection()
        let narrow = Self.options(pageSize: PDFReportPageSize(width: 260, height: 420),
                                  maximumColumnWidth: 64)
        let wide = Self.options(droppingEmptyColumns: false,
                                pageSize: PDFReportPageSize(width: 260, height: 420),
                                maximumColumnWidth: 64)
        let pruned = try render(projection, options: narrow)
        let all = try render(projection, options: wide)
        #expect(all.bandCount > pruned.bandCount)
        // The LT-18 symptom, measured: the extra bands are extra pages, and they were blank.
        #expect(all.pageCount > pruned.pageCount)
    }

    // MARK: - LT-19: the status cell

    @Test("The status cell prints its title, never a raw option UUID")
    func statusPrintsItsTitle() throws {
        let projection = try Self.projection()
        let result = try render(projection, options: Self.options())

        #expect(result.drawnText.contains("No status"))
        #expect(result.drawnText.contains("Open"))
        #expect(result.drawnText.contains("In progress"))

        // The old output: the option's UUID, of which the live test saw the first 29 characters
        // before the cell clipped. Neither the whole id nor its head may appear anywhere.
        for status in MarkupStatus.allCases {
            let id = LedgerIdentifiers.choiceOptionID(for: status).rawValue.uuidString
            #expect(!result.drawnText.contains { $0.contains(id) }, "\(status) printed its id")
            #expect(!result.drawnText.contains { $0.hasPrefix(String(id.prefix(8))) })
        }
        // Nothing the report drew is a UUID at all.
        #expect(result.drawnText.allSatisfy { UUID(uuidString: $0) == nil })
    }

    @Test("Every review status has a title, and it is not the stored token")
    func everyStatusHasATitle() throws {
        #expect(ExportProjector.statusTitle(.none) == "No status")
        #expect(ExportProjector.statusTitle(.inProgress) == "In progress")
        for status in MarkupStatus.allCases {
            let title = ExportProjector.statusTitle(status)
            #expect(!title.isEmpty)
            #expect(UUID(uuidString: title) == nil)
            let id = LedgerIdentifiers.choiceOptionID(for: status)
            #expect(ExportProjector.choiceLabel(id, options: ExportProjectionOptions()) == title)
        }
    }

    @Test("The report and the CSV print the same status word")
    func statusAgreesWithTheCSV() throws {
        let projection = try Self.projection()
        let statusColumn = try #require(
            projection.table.columns.firstIndex { $0.key == "status" }
        )
        let data = try CSVExporter().export(
            projection,
            options: CSVExportOptions(
                includeRawColumns: false,
                includeUnitColumns: false,
                includeGroupColumns: false,
                includeSubtotalRows: false,
                includeGrandTotalRows: false
            )
        )
        let records = CSVReader.records(String(decoding: data, as: UTF8.self), delimiter: ",")
        let csvStatuses = records.dropFirst().map { $0[statusColumn] }
        #expect(csvStatuses == ["No status", "Open", "In progress"])

        // The same three strings, in the same order, off the printed page.
        let result = try render(projection, options: Self.options())
        let printedStatusSlot = try #require(
            PDFReportRenderer
                .printedColumns(table: projection.table, options: Self.options())
                .firstIndex(of: statusColumn)
        )
        let width = result.printedColumnCount
        let drawnStatuses = stride(from: printedStatusSlot, to: result.drawnText.count, by: width)
            .map { result.drawnText[$0] }
        #expect(drawnStatuses == csvStatuses)
    }

    @Test("A supplied choice label still wins over the built-in title")
    func suppliedLabelsWin() throws {
        let id = LedgerIdentifiers.choiceOptionID(for: .none).rawValue.uuidString
        let projection = try Self.projection(choiceLabels: [id: "Ej granskad"])
        let result = try render(projection, options: Self.options())
        #expect(result.drawnText.contains("Ej granskad"))
        #expect(!result.drawnText.contains("No status"))
    }

    // MARK: - LT-19: the dates

    @Test("A date cell prints a date, not an ISO timestamp")
    func dateCellsAreHumanised() throws {
        let projection = try Self.projection()
        let result = try render(projection, options: Self.options())

        #expect(result.drawnText.contains("28 May 2026"))
        // The old output. `2026-05-28T20:26:40Z` is what the report used to draw here.
        #expect(!result.drawnText.contains { $0.contains("T") && $0.hasSuffix("Z") })
        #expect(!result.drawnText.contains(projection.table.rows[0].cells[3].text))

        // And the parsed formats are untouched: the projection still carries the instant.
        #expect(projection.table.rows[0].cells[3].text == "2026-05-28T20:26:40Z")
        let created = try #require(projection.table.rows[0].cells[3].date)
        #expect(created.humanText == "28 May 2026")
        #expect(created.iso8601 == "2026-05-28T20:26:40Z")
    }

    @Test("The title page's Date line is a date, not an ISO timestamp")
    func coverDateIsHumanised() throws {
        let metadata = try Self.projection().table.metadata
        let entries = Painter.coverEntries(metadata)
        let date = try #require(entries.first { $0.label == "Date" })
        #expect(date.value == "28 May 2026")
        // The old line, verbatim, and it is gone from the whole cover.
        #expect(date.value != metadata.generatedAt.iso8601)
        #expect(!entries.contains { $0.value.contains(metadata.generatedAt.iso8601) })
    }

    @Test("The human date is hermetic: UTC, English months, no leading zero")
    func humanDateIsStable() {
        #expect(ExportProjector.humanDate(Date(timeIntervalSince1970: 0)) == "1 Jan 1970")
        // 2026-12-31T23:59:59Z — the day does not roll over into a local calendar's tomorrow.
        #expect(ExportProjector.humanDate(Date(timeIntervalSince1970: 1_798_761_599))
                == "31 Dec 2026")
        #expect(ExportProjector.humanDate(Self.epoch) == "28 May 2026")
    }
}

private extension ExportCell {
    var date: ExportDate? {
        if case .date(let value) = self { return value }
        return nil
    }
}
