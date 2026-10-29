import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Regression tests for the projection and number-format findings of bug hunt 2:
/// BH-021, BH-139, BH-140, BH-141, BH-142, BH-143, BH-149, BH-150, BH-531, BH-532, BH-533.
///
/// Every test states the output the old projector or the old workbook writer produced. Each
/// one fails on that code.
@Suite("Fix2 E1 projection and number formats", .sharedHeap)
struct Fix2E1ProjectionTests {

    // MARK: - Fixture

    static let runID = ExportFixture.customID("e1-run-ft")
    static let runInchID = ExportFixture.customID("e1-run-in")
    static let floorID = ExportFixture.customID("e1-floor-sqft")
    static let costID = ExportFixture.customID("e1-cost")
    static let lengthID = ExportFixture.customID("e1-length-m3")
    static let hiddenID = ExportFixture.customID("e1-hidden-mm")
    static let ratioID = ExportFixture.customID("e1-ratio")

    /// 40.8 in, in metres.
    static let fortyPointEightInches = Decimal(string: "1.03632")!

    static func columns() throws -> LedgerColumnSet {
        var definitions: [LedgerColumnDefinition] = []
        func append(_ definition: LedgerColumnDefinition) {
            var copy = definition
            copy.order = definitions.count
            definitions.append(copy)
        }
        for standard in [StandardLedgerColumn.subject, .created] {
            append(LedgerColumnDefinition(
                id: ExportFixture.standardID(standard),
                key: standard.rawValue,
                title: standard.rawValue,
                kind: standard.kind,
                standard: standard,
                isEditable: standard.isUserEditable
            ))
        }
        let sixteenth = PrecisionMode.imperialFraction(.sixteenth)
        append(LedgerColumnDefinition(
            id: runID, key: "run", title: "Run", kind: .number,
            dimension: .length, displayUnit: .length(.foot), precision: sixteenth
        ))
        append(LedgerColumnDefinition(
            id: runInchID, key: "runInches", title: "Run (in)", kind: .number,
            dimension: .length, displayUnit: .length(.inch), precision: sixteenth
        ))
        append(LedgerColumnDefinition(
            id: floorID, key: "floor", title: "Floor", kind: .number,
            dimension: .area, displayUnit: .area(.squareFoot), precision: sixteenth
        ))
        // The built-in Unit cost / Total cost shape: a currency with no declared precision.
        append(LedgerColumnDefinition(
            id: costID, key: "cost", title: "Cost", kind: .currency,
            dimension: .currency("SEK"), displayUnit: .currency("SEK"), precision: nil
        ))
        append(LedgerColumnDefinition(
            id: lengthID, key: "length", title: "Length", kind: .number,
            dimension: .length, displayUnit: .length(.metre), precision: .decimalPlaces(3)
        ))
        append(LedgerColumnDefinition(
            id: hiddenID, key: "hidden", title: "Hidden", kind: .number,
            dimension: .length, displayUnit: .length(.millimetre), precision: .decimalPlaces(0)
        ))
        // The built-in Count column's shape: dimensionless, two decimals from the column set.
        append(LedgerColumnDefinition(
            id: ratioID, key: "ratio", title: "Ratio", kind: .number,
            dimension: .count, displayUnit: .count, precision: .decimalPlaces(2)
        ))
        return try LedgerColumnSet(columns: definitions)
    }

    /// 22:30 UTC on 1 September 2026 — 00:30 on 2 September in Stockholm.
    static let nearMidnight: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = 22
        components.minute = 30
        return ExportProjector.calendar(in: .gmt).date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()

    static func store() throws -> LedgerStore {
        let costs = [Decimal(string: "125.5")!, Decimal(string: "12.3456")!]
        let lengths = [Decimal(string: "1.5")!, Decimal(string: "2.25")!]
        var markups: [MarkupRecord] = []
        for index in 0..<2 {
            markups.append(MarkupRecord(
                id: MarkupID(ExportFixture.uuid(9_000 + index)),
                documentID: DocumentID(ExportFixture.uuid(-901)),
                pageID: PageID(ExportFixture.uuid(-902)),
                kind: .measurement,
                tool: .length,
                subject: index == 0 ? "Concrete" : "Steel",
                label: "E1-\(index)",
                author: "Ada",
                customValues: [
                    runID: .number(.length(fortyPointEightInches)),
                    runInchID: .number(.length(fortyPointEightInches)),
                    floorID: .number(.area(100)),
                    costID: .currency(amount: costs[index], code: "SEK"),
                    lengthID: .number(.length(lengths[index])),
                    hiddenID: .number(.length(Decimal(string: "0.5")!)),
                    ratioID: .number(.count(2))
                ],
                createdAt: nearMidnight,
                modifiedAt: nearMidnight
            ))
        }
        return try LedgerStore(markups: markups, columns: try columns())
    }

    static func report(
        grouping: [ColumnID] = [],
        visible: [ColumnID] = [],
        dayCalendar: Calendar = LedgerViewSpec.defaultDayCalendar
    ) throws -> LedgerReport {
        var plan = LedgerAggregationPlan()
        plan.add(AggregateKey(column: lengthID, function: .sum))
        plan.add(AggregateKey(column: lengthID, function: .count))
        plan.add(AggregateKey(column: costID, function: .sum))
        let spec = LedgerViewSpec(
            grouping: grouping.map { LedgerGroupingField(column: $0) },
            aggregation: plan,
            visibleColumns: visible,
            dayCalendar: dayCalendar
        )
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(try store().makeView(spec), title: "E1")
    }

    static func projection(
        _ report: LedgerReport,
        options: ExportProjectionOptions = ExportProjectionOptions()
    ) throws -> ExportProjection {
        try ExportProjector().project(report, options: options)
    }

    static func index(_ key: String, in table: ExportTable) throws -> Int {
        try #require(table.columns.firstIndex { $0.key == key })
    }

    // MARK: - BH-021

    @Test("BH-021: an imperial-fraction length exports in feet, inches and sixteenths of an inch")
    func imperialLengthIsFeetAndInches() throws {
        let projection = try Self.projection(try Self.report())
        let table = projection.table
        let row = table.rows[0]
        let feet = try #require(row.cells[try Self.index("run", in: table)].number)
        let inches = try #require(row.cells[try Self.index("runInches", in: table)].number)
        // Old: "3.375" — 3.4 ft rounded to a sixteenth of a FOOT (3'-4 1/2", 5/16" off) and
        // written as a decimal, in every format. The screen prints 3'-4 13/16".
        #expect(feet.text == "3'-4 13/16\"")
        // Old: "40.8125". The screen prints inches and a fraction, no feet.
        #expect(inches.text == "40 13/16\"")
        // The one string every format writes: the CSV carries it verbatim.
        let csv = String(decoding: try CSVExporter().export(projection), as: UTF8.self)
        #expect(csv.contains("3'-4 13/16"))
        #expect(!csv.contains("3.375"))
    }

    @Test("BH-021: fractions carry into the next inch and foot, reduce, and say when below 1/16\"")
    func imperialLengthCarries() throws {
        let formatting = LedgerValueFormatting(
            dimension: .length, displayUnit: .length(.foot), precision: .imperialFraction(.sixteenth)
        )
        func text(_ inches: String) -> String? {
            let metres = Decimal(string: inches)! * Decimal(string: "0.0254")!
            return ExportProjector.imperialLength(
                raw: metres, dimension: .length, formatting: formatting, denominator: .sixteenth
            )?.text
        }
        #expect(text("11.99") == "1'-0\"")
        #expect(text("12.5") == "1'-0 1/2\"")
        #expect(text("0.01") == "< 1/16\"")
        #expect(text("-40.8") == "-3'-4 13/16\"")
        // Yards are decimal on screen, never feet and inches.
        let yards = LedgerValueFormatting(
            dimension: .length, displayUnit: .length(.yard), precision: .imperialFraction(.sixteenth)
        )
        #expect(ExportProjector.imperialLength(
            raw: 1, dimension: .length, formatting: yards, denominator: .sixteenth
        ) == nil)
    }

    // MARK: - BH-139, BH-140, BH-141, BH-149, BH-150: the workbook's number formats

    @Test("BH-139/140/149: nil-precision and imperial cells carry the format code their text needs")
    func perCellFormatCodes() throws {
        let projection = try Self.projection(try Self.report())
        let table = projection.table
        let cost = try Self.index("cost", in: table)
        // Old: the column code "0" for every cost cell — Excel showed 126 and 12.
        #expect(table.columns[cost].numberFormatCode == "General")
        #expect(table.rows[0].cells[cost].number?.numberFormatCode == "0.0")
        #expect(table.rows[1].cells[cost].number?.numberFormatCode == "0.0000")
        // Old: "0" — Excel showed 3 for a 3.4 ft run.
        let run = try Self.index("run", in: table)
        #expect(table.rows[0].cells[run].number?.numberFormatCode == "0.0000")
    }

    @Test("BH-139/140/141/149/150: the workbook shows what the CSV and the PDF print")
    func workbookRendersTheCellsOwnDigits() throws {
        let projection = try Self.projection(try Self.report())
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(
            projection, to: url,
            options: XLSXExportOptions(metadataSheetName: nil, includeUnitColumns: false)
        )
        let sheet = try XLSXInspector(url: url)
        let table = projection.table
        // Sheet layout: column A is the record type, then the table's columns in order.
        func sheetCell(row: Int, key: String) throws -> XLSXInspector.Cell {
            let column = try Self.index(key, in: table) + 1
            return try #require(sheet.cells.first { $0.row == row && $0.column == column })
        }
        // Rows 1-2 are data (row 0 is the header).
        let cost0 = try sheetCell(row: 1, key: "cost")
        let cost1 = try sheetCell(row: 2, key: "cost")
        // Old: format "0" — rendered "126" and "12".
        #expect(sheet.numberFormat(of: cost0) == "0.0")
        #expect(try sheet.rendered(cost0, locale: .invariant) == "125.5")
        #expect(try sheet.rendered(cost1, locale: .invariant) == "12.3456")
        // Old: format "0" — rendered "3".
        let run = try sheetCell(row: 1, key: "run")
        #expect(sheet.numberFormat(of: run) == "0.0000")
        #expect(try sheet.rendered(run, locale: .invariant) == "3.4000")

        // Grand totals follow the data: Sum (row 3), Count (row 4).
        let countRow = try #require(table.grandTotals.firstIndex { $0.function == "Count" }) + 3
        let count = try sheetCell(row: countRow, key: "length")
        // Old: the column's bold "0.000" — rendered "2.000" where the CSV and PDF print "2".
        #expect(sheet.numberFormat(of: count) == "0")
        #expect(try sheet.rendered(count, locale: .invariant) == "2")
        let countCell = table.grandTotals[countRow - 3].cells[try Self.index("length", in: table)]
        #expect(countCell.text == "2")
        let sumRow = try #require(table.grandTotals.firstIndex { $0.function == "Sum" }) + 3
        let sum = try sheetCell(row: sumRow, key: "length")
        #expect(sheet.numberFormat(of: sum) == "0.000")
        #expect(try sheet.rendered(sum, locale: .invariant) == "3.750")
    }

    // MARK: - BH-142, BH-143: the screen's digit counts

    @Test("BH-142/143: with the screen's rules, counts print their digits and imperial areas decimals")
    func screenNotationMatchesTheLedger() throws {
        let report = try Self.report()
        let plain = try Self.projection(report).table
        // Without the screen's rules the column precision still decides, as before.
        #expect(plain.rows[0].cells[try Self.index("ratio", in: plain)].text == "2.00")
        #expect(plain.rows[0].cells[try Self.index("floor", in: plain)].text == "1076.375")

        let screen = try Self.projection(
            report,
            options: ExportProjectionOptions(screenNotation: ExportScreenNotation(decimalPlaces: 2))
        ).table
        // Old (no way to ask): "2.00" where the ledger on screen prints "2".
        let ratio = try #require(screen.rows[0].cells[try Self.index("ratio", in: screen)].number)
        #expect(ratio.text == "2")
        #expect(ratio.numberFormatCode == "0")
        // Old: "1076.375" (a sixteenth of a square foot) where the screen prints 1,076.39 ft².
        let floor = try #require(screen.rows[0].cells[try Self.index("floor", in: screen)].number)
        #expect(floor.text == "1076.39")
        #expect(floor.numberFormatCode == "0.00")
        // Lengths keep feet and inches under the screen's rules too.
        #expect(screen.rows[0].cells[try Self.index("run", in: screen)].text == "3'-4 13/16\"")
    }

    // MARK: - BH-531

    @Test("BH-531: a group keyed on a hidden number column names its unit")
    func hiddenGroupingColumnIsLabelledWithAUnit() throws {
        let visible = [ExportFixture.standardID(.subject), Self.lengthID]
        let projection = try Self.projection(try Self.report(grouping: [Self.hiddenID], visible: visible))
        let group = try #require(projection.table.groups.first)
        // Old: "0.5" — the bare SI magnitude over cells that would read "500 mm". The first fix
        // labelled it in SI ("0.5 m"); since the report carries each grouping column's own
        // formatting (LedgerReportMetadata.groupingColumnFormatting) a hidden
        // grouping column reads exactly like its cells would.
        #expect(group.label == "500 mm")
    }

    @Test("BH-531: a visible number grouping column is labelled the way its cells read")
    func visibleGroupingColumnIsLabelledInItsUnit() throws {
        let projection = try Self.projection(try Self.report(grouping: [Self.hiddenID]))
        #expect(projection.table.groups.first?.label == "500 mm")
    }

    // MARK: - BH-532

    @Test("BH-532: the printed report heads a date group with the day, not the ISO instant")
    func dateGroupHeadingIsADay() throws {
        // Grouped in UTC, named so: the ledger's default is the process's zone, which made this
        // test read "2026-09-01T22:00:00Z" on a machine in Stockholm (I-18). The zone-boundary
        // cases are Iter4ExportPDFTests.dateGroupsUseTheBucketZone (C-10).
        let projection = try Self.projection(
            try Self.report(grouping: [ExportFixture.standardID(.created)], dayCalendar: ExportProjector.calendar(in: .gmt))
        )
        let group = try #require(projection.table.groups.first)
        // The parsed formats' label is the day as an ISO-8601 calendar date (C-10); before
        // T-047 it was the instant of the first markup, "2026-09-01T22:30:00Z".
        #expect(group.label == "2026-09-01")
        #expect(group.printedLabel == "1 Sep 2026")
        let lines = PDFReportRenderer.flatten(table: projection.table, options: PDFReportOptions())
        var headings: [String] = []
        var subtotals: [String] = []
        for line in lines {
            if case .groupHeading(let label, _, _) = line { headings.append(label) }
            if case .subtotal(let label, _, _, _) = line { subtotals.append(label) }
        }
        // Old: "2026-09-01T22:30:00Z" above cells that read "1 Sep 2026".
        #expect(headings == ["1 Sep 2026"])
        #expect(!subtotals.isEmpty)
        #expect(subtotals.allSatisfy { $0 == "1 Sep 2026" })
    }

    // MARK: - BH-533

    @Test("BH-533: the report's dates can be taken in the ledger's zone")
    func humanDatesFollowTheSuppliedZone() throws {
        let report = try Self.report()
        let utc = try Self.projection(report).table
        let created = try Self.index("created", in: utc)
        guard case .date(let utcDate) = utc.rows[0].cells[created] else {
            Issue.record("created is not a date cell")
            return
        }
        #expect(utcDate.humanText == "1 Sep 2026")

        let stockholm = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let local = try Self.projection(
            report, options: ExportProjectionOptions(humanDateTimeZone: stockholm)
        ).table
        guard case .date(let localDate) = local.rows[0].cells[created] else {
            Issue.record("created is not a date cell")
            return
        }
        // Old: "1 Sep 2026" whatever the zone — the screen, in Stockholm, says 2 Sep.
        #expect(localDate.humanText == "2 Sep 2026")
        // The parsed formats keep the UTC instant.
        #expect(localDate.iso8601 == "2026-09-01T22:30:00Z")
    }
}
