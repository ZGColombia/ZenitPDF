import CoreText
import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Regression tests for the code-review findings on the export layer
/// (CR-53 … CR-70). Every test names, in its own
/// comment, what the code under review produced before the fix — the string a reader would
/// have found in the file.
@Suite("Code-review regressions: export", .sharedHeap)
struct ExportCodeReviewRegressionTests {

    // MARK: - Fixtures

    private static func store(
        columns: LedgerColumnSet,
        rows: [[ColumnID: LedgerCellValue]]
    ) throws -> LedgerStore {
        let markups = rows.enumerated().map { index, cells in
            MarkupRecord(
                id: MarkupID(ExportFixture.uuid(index)),
                documentID: DocumentID(ExportFixture.uuid(-1)),
                pageID: PageID(ExportFixture.uuid(-2)),
                kind: .measurement,
                subject: index % 2 == 0 ? "Concrete" : "Steel",
                customValues: cells,
                createdAt: ExportFixture.epoch,
                modifiedAt: ExportFixture.epoch
            )
        }
        return try LedgerStore(markups: markups, columns: columns)
    }

    private static func report(
        _ store: LedgerStore,
        spec: LedgerViewSpec,
        title: String = "Regression"
    ) -> LedgerReport {
        LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(spec), title: title)
    }

    private static func csv(
        _ projection: ExportProjection,
        options: CSVExportOptions = CSVExportOptions()
    ) throws -> [[String]] {
        let data = try CSVExporter().export(projection, options: options)
        return CSVReader.records(String(decoding: data, as: UTF8.self), delimiter: options.delimiter)
    }

    private static func columnIndex(_ projection: ExportProjection, key: String) throws -> Int {
        try #require(projection.table.columns.firstIndex { $0.key == key })
    }

    // MARK: - CR-53

    @Test("A screen that pre-rounds with the display rule prints the projector's digits")
    func screenAndExportAgreeOnGoldens() throws {
        // Old output, the screen's side: the formatter below — the one the application's
        // `decimalText` used — fed the unrounded golden values printed 0.44, 1.00, 2.68, -0.00,
        // 1234567.89 and 8.12 against the projector's 0.44, 1.01, 2.68, 0.00, 1234567.89 and
        // 8.13: two cells a digit apart and one carrying a sign the export did not. This is
        // the package half of the screen-versus-export string test; the application half
        // asserts `QuantityBridge.text` against the same rule.
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let golden = try Self.columnIndex(projection, key: "golden")
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfEven

        var unrounded: [String] = []
        for (row, value) in ExportFixture.goldenValues.enumerated() {
            let exported = projection.table.rows[row].cells[golden].text
            let screen = formatter.string(
                from: NSDecimalNumber(decimal: LedgerDisplayRounding.round(value, places: 2))
            )
            #expect(screen == exported, "row \(row): \(value)")
            unrounded.append(formatter.string(from: NSDecimalNumber(decimal: value)) ?? "")
        }
        #expect(projection.table.rows.map { $0.cells[golden].text } == ExportFixture.expectedGoldenText)
        // The disagreement being retired, spelled out.
        #expect(unrounded == ["0.44", "1.00", "2.68", "-0.00", "1234567.89", "8.12"])
    }

    // MARK: - CR-57

    @Test("The CSV formula guard leaves numeric fields alone")
    func formulaGuardSkipsNumbers() throws {
        // Old output: `'-0.004` in the Golden (raw) field and `'-0.40` in the Cost field of the
        // -0.004 row — the guard ran over every field — so a spreadsheet imported both as
        // text, and a locale whose minus is U+2212 got the guard on some rows and not others.
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let records = try Self.csv(projection)
        let header = records[0]
        let goldenRaw = try #require(header.firstIndex(of: "Golden (raw)"))
        let cost = try #require(header.firstIndex(of: "Cost"))
        let comment = try #require(header.firstIndex(of: "comment"))

        let minusFourThousandths = try #require(Decimal(string: "-0.004"))
        let negative = try #require(ExportFixture.goldenValues.firstIndex(of: minusFourThousandths)) + 1
        #expect(records[negative][goldenRaw] == "-0.004")
        #expect(records[negative][cost] == "-0.40")
        // The guard still does its one job, on text.
        let injected = try #require(ExportFixture.hostileComments.firstIndex(of: "=1+1")) + 1
        #expect(records[injected][comment] == "'=1+1")
        // And nothing numeric anywhere in the file starts with it.
        for record in records.dropFirst() {
            #expect(!record[goldenRaw].hasPrefix("'"), Comment(rawValue: record.joined(separator: "|")))
            #expect(!record[cost].hasPrefix("'"), Comment(rawValue: record.joined(separator: "|")))
        }
    }

    // MARK: - CR-59

    @Test("A group keyed on a numeric column is labelled in the column's display unit")
    func numericGroupLabelsReadLikeTheirCells() throws {
        // Old output: labels "10", "20", "30", "40", "50", "60" — the raw square-metre
        // magnitudes of a column whose every cell reads in square feet ("107.64").
        let store = try ExportFixture.goldenStore()
        let report = Self.report(
            store,
            spec: LedgerViewSpec(
                grouping: [LedgerGroupingField(column: ExportFixture.footprintID)],
                aggregation: ExportFixture.plan
            )
        )
        let projection = try ExportFixture.projection(report)
        let footprint = try Self.columnIndex(projection, key: "footprint")
        let symbol = AnyDisplayUnit.area(.squareFoot).symbol
        #expect(projection.table.groups.count == ExportFixture.goldenValues.count)
        for group in projection.table.groups {
            let cell = try #require(group.rows.first?.cells[footprint].text)
            #expect(group.label == "\(cell) \(symbol)", Comment(rawValue: group.token))
        }
        #expect(projection.table.groups.first?.label == "107.64 \(symbol)")
        #expect(!projection.table.groups.map(\.label).contains("10"))

        // A currency key reads as its cells do, with the code.
        let byCost = try ExportFixture.projection(Self.report(
            store,
            spec: LedgerViewSpec(
                grouping: [LedgerGroupingField(column: ExportFixture.costID)],
                aggregation: ExportFixture.plan
            )
        ))
        let cost = try Self.columnIndex(byCost, key: "cost")
        for group in byCost.table.groups {
            let cell = try #require(group.rows.first?.cells[cost].text)
            #expect(group.label == "\(cell) \(ExportFixture.currencyCode)", Comment(rawValue: group.token))
        }

        // A label the caller supplies still wins.
        let supplied = try ExportProjector().project(
            report,
            options: ExportProjectionOptions(groupLabels: [report.groups[0].key.token: "Small"])
        )
        #expect(supplied.table.groups.first?.label == "Small")
    }

    // MARK: - CR-60

    @Test("Column widths make room for a refusal token on a total line")
    func columnWidthsMeasureTotalLines() throws {
        // Old output: the Mixed column was sized from its header and its two data cells
        // ("2.00", "3.00") — about 40 pt — so the grand total's `#MIXED_UNITS[m|m²]` was
        // ellipsised on the page.
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let options = PDFReportOptions()
        let bold = CTFontCreateWithName(options.boldFontName as CFString, options.bodyFontSize, nil)
        let body = CTFontCreateWithName(options.fontName as CFString, options.bodyFontSize, nil)
        let widths = PDFReportRenderer.columnWidths(
            table: projection.table, options: options, font: bold, bodyFont: body
        )

        let mixed = try Self.columnIndex(projection, key: "mixed")
        let total = try #require(projection.table.grandTotals.first { $0.function == "Sum" })
        let token = total.cells[mixed].text
        #expect(token.hasPrefix(LedgerReport.mixedDimensionsToken))
        let needed = TextMeasure.width(token, font: bold) + options.columnPadding * 2
        #expect(needed < options.maximumColumnWidth,
                "the token must fit under the cap for this test to mean anything")
        #expect(widths[mixed] >= needed)
        // The data cells alone would not have needed it.
        let widestData = projection.table.allRows()
            .map { TextMeasure.width($0.cells[mixed].printedText, font: body) }
            .max() ?? 0
        #expect(widestData + options.columnPadding * 2 < needed)

        // The identity column fits the widest total label as well — CR-61 draws it there. Since
        // L-46 a Count line prints no count under a text column, so the Subject cell of the
        // Count line is the label alone (it was "Count: Concrete  3").
        let subject = try Self.columnIndex(projection, key: "subject")
        let label = PDFReportRenderer.totalCellText(
            label: PDFReportRenderer.subtotalLabel(function: "Count", groupLabel: "Concrete"),
            cellText: ""
        )
        let labelWidth = TextMeasure.width(label, font: bold) + options.columnPadding * 2
        #expect(widths[subject] >= min(labelWidth, options.maximumColumnWidth))
    }

    // MARK: - CR-61

    @Test("Every subtotal and grand-total line carries its label, Count lines included")
    func totalLabelsAreAlwaysDrawn() throws {
        // Old output: a label was drawn only on a line whose identity cell was blank. The
        // Subject cell of every Count line holds the count, so "Count: Concrete",
        // "Count: Steel" and "Count (all rows)" never reached the page; only the Sum lines
        // were named. (`drawnLabels` did not exist; the trace is the fixed painter's.)
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(
            projection,
            to: url,
            options: PDFReportOptions(
                pageSize: .a4.landscape, includeCoverPage: false,
                recordsDrawnText: true, maximumColumnWidth: 70
            )
        )
        #expect(result.bandCount == 1)
        #expect(result.drawnLabels.contains("Count: Concrete"))
        #expect(result.drawnLabels.contains("Count: Steel"))
        #expect(result.drawnLabels.contains("Sum: Concrete"))
        #expect(result.drawnLabels.contains("Sum: Steel"))
        #expect(result.drawnLabels.contains("Count (all rows)"))
        #expect(result.drawnLabels.contains("Sum (all rows)"))
        // One label per total line: two groups times two functions, plus two grand totals.
        #expect(result.drawnLabels.count == 6)
        // The cell trace is untouched: one entry per cell, the cell's own text.
        #expect(result.drawnText.count % result.printedColumnCount == 0)
    }

    // MARK: - CR-66

    @Test("A currency cell keeps its own ISO code when it differs from the column's")
    func foreignCurrencyCellKeepsItsCode() throws {
        // Old output: unit symbol "SEK" on the EUR row — the column's symbol — in the
        // projection and therefore in the CSV unit column and the workbook.
        let columns = try ExportFixture.columnSet()
        let store = try Self.store(columns: columns, rows: [
            [ExportFixture.costID: .currency(amount: 10, code: "SEK")],
            [ExportFixture.costID: .currency(amount: 5, code: "EUR")]
        ])
        let projection = try ExportFixture.projection(
            Self.report(store, spec: LedgerViewSpec(aggregation: ExportFixture.plan))
        )
        let cost = try Self.columnIndex(projection, key: "cost")
        #expect(projection.table.rows[0].cells[cost].number?.unitSymbol == "SEK")
        #expect(projection.table.rows[1].cells[cost].number?.unitSymbol == "EUR")
        #expect(projection.table.rows[1].cells[cost].text == "5.00")

        let records = try Self.csv(projection)
        let unit = try #require(records[0].firstIndex(of: "Cost (unit)"))
        #expect(records[1][unit] == "SEK")
        #expect(records[2][unit] == "EUR")
        // The column's own total refuses the mix, exactly as before.
        let total = try #require(projection.table.grandTotals.first { $0.function == "Sum" })
        #expect(total.cells[cost].text.hasPrefix(LedgerReport.mixedDimensionsToken))
    }

    // MARK: - CR-69

    @Test("A raw cell on a bold total row keeps the raw number format")
    func rawTotalCellsKeepTheRawFormat() throws {
        // Old output: the raw cell of every bold total row wore column 0's bold format.
        // Column 0 is Subject, whose number format is nil, so the exact sum was written as
        // General and `numberFormat(of:)` read nil; over a numeric column 0 it would have
        // read that column's "0.000" and shown the sum at three places.
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let options = XLSXExportOptions(includeRawColumns: true)
        try XLSXExporter().export(projection, to: url, options: options)
        let sheet = try XLSXInspector(url: url)

        let rawColumn = try #require(
            sheet.cells.first { $0.row == 0 && $0.value == "Golden (raw)" }?.column
        )
        let subtotalRow = try #require(
            sheet.cells.first { $0.column == 0 && $0.value.hasPrefix("Subtotal: Sum") }?.row
        )
        let totalRow = try #require(
            sheet.cells.first { $0.column == 0 && $0.value.hasPrefix("Total: Sum") }?.row
        )
        for row in [subtotalRow, totalRow] {
            let cell = try #require(sheet.cells.first { $0.row == row && $0.column == rawColumn })
            #expect(cell.type == nil, "a raw total is a number")
            #expect(sheet.numberFormat(of: cell) == options.rawNumberFormat, "row \(row)")
        }
        let data = try #require(sheet.cells.first { $0.row == 1 && $0.column == rawColumn })
        #expect(sheet.numberFormat(of: data) == options.rawNumberFormat)
    }

    // MARK: - CR-70

    @Test("Two weighted totals with different weight columns are two total rows")
    func weightedTotalsKeepTheirWeightColumn() throws {
        // Old output: one grand-total row, "WeightedTotal", holding the second aggregate —
        // the first was overwritten in the projector's per-function dictionary — so
        // Σ value × w1 (40) never reached any format.
        let value = ExportFixture.customID("value")
        let w1 = ExportFixture.customID("w1")
        let w2 = ExportFixture.customID("w2")
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: value, key: "value", title: "Value", kind: .number, dimension: .count, order: 0
            ),
            LedgerColumnDefinition(
                id: w1, key: "w1", title: "W1", kind: .number, dimension: .count, order: 1
            ),
            LedgerColumnDefinition(
                id: w2, key: "w2", title: "W2", kind: .number, dimension: .count, order: 2
            )
        ])
        let store = try Self.store(columns: columns, rows: [
            [value: .number(.count(10)), w1: .number(.count(2)), w2: .number(.count(3))],
            [value: .number(.count(20)), w1: .number(.count(1)), w2: .number(.count(1))]
        ])
        let plan = LedgerAggregationPlan(keys: [
            AggregateKey(column: value, function: .weightedTotal(weight: w1)),
            AggregateKey(column: value, function: .weightedTotal(weight: w2))
        ])
        let projection = try ExportFixture.projection(
            Self.report(store, spec: LedgerViewSpec(aggregation: plan))
        )
        let index = try Self.columnIndex(projection, key: "value")
        #expect(
            projection.table.grandTotals.map(\.function) == ["WeightedTotal[w1]", "WeightedTotal[w2]"]
        )
        #expect(projection.table.grandTotals.map { $0.cells[index].text } == ["40", "50"])

        // Both rows reach the file, labelled.
        let records = try Self.csv(projection)
        #expect(records.contains { $0[0] == "Total: WeightedTotal[w1]" })
        #expect(records.contains { $0[0] == "Total: WeightedTotal[w2]" })
    }
}
