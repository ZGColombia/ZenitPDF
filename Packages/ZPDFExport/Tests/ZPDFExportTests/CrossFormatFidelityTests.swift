import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// The test the whole package exists to pass.
///
/// One projection, four formats, and the same string in every cell of every one of them. The
/// fixture includes values engineered so that a `Double` formatter, or a rounding step applied
/// twice, would differ in the last digit — so an implementation that quietly re-derived a value
/// somewhere cannot pass by accident (QUALITY_BAR A25, A29, A30, A31).
///
/// The CSV is read **as the application writes it**: formula guard on and raw columns on
/// (CR-71). An earlier version switched the guard off "because it rewrites one text field",
/// which also meant the test could never notice the guard rewriting a *number* — and it was
/// (CR-57). The guard's one legitimate rewrite is stated as an expectation instead, and the raw
/// field beside every numeric cell is held to the projection's invariant raw text.
@Suite("Cross-format fidelity", .sharedHeap)
struct CrossFormatFidelityTests {

    /// Options chosen so the four files line up column for column: no unit, group or total
    /// columns. The raw column beside each numeric column is mapped out by header, below.
    private static let csvOptions = CSVExportOptions(
        includeRawColumns: true,
        includeUnitColumns: false,
        includeGroupColumns: false,
        includeSubtotalRows: false,
        includeGrandTotalRows: false
    )

    private static let xlsxOptions = XLSXExportOptions(
        metadataSheetName: nil,
        includeRawColumns: false,
        includeUnitColumns: false,
        includeGroupColumns: false,
        includeSubtotalRows: false,
        includeGrandTotalRows: false
    )

    private static let pdfOptions = PDFReportOptions(
        pageSize: .a4.landscape,
        includeCoverPage: false,
        includeGroupHeadings: false,
        includeGroupSubtotals: false,
        includeGrandTotals: false,
        recordsDrawnText: true,
        maximumColumnWidth: 70
    )

    /// A real application picks the delimiter to suit the locale, and so does this test: a comma
    /// file with a comma decimal separator is refused by the exporter, correctly.
    private func csvOptions(for locale: ExportNumberLocale) -> CSVExportOptions {
        var options = Self.csvOptions
        let comma: Character = ","
        if locale.decimalSeparator == String(comma) || locale.groupingSeparator == String(comma) {
            options.delimiter = ";"
        }
        return options
    }

    /// The CSV as the two matrices the assertions need: the display field of every column,
    /// column for column against the other formats, and the raw field beside each numeric one
    /// (`nil` for a column that has no raw field).
    private func csvFields(
        _ projection: ExportProjection
    ) throws -> (display: [[String]], raw: [[String?]]) {
        let options = csvOptions(for: projection.numberLocale)
        let data = try CSVExporter().export(projection, options: options)
        let text = String(decoding: data, as: UTF8.self)
        let records = CSVReader.records(text, delimiter: options.delimiter)

        // The header is the column titles, with a raw column after each numeric one.
        var expectedHeader: [String] = []
        var displayIndex: [Int] = []
        var rawIndex: [Int?] = []
        for column in projection.table.columns {
            displayIndex.append(expectedHeader.count)
            expectedHeader.append(column.title)
            if column.isNumeric {
                rawIndex.append(expectedHeader.count)
                expectedHeader.append(column.title + options.rawColumnSuffix)
            } else {
                rawIndex.append(nil)
            }
        }
        #expect(records[0] == expectedHeader)

        let body = Array(records.dropFirst())
        let display = body.map { record in displayIndex.map { record[$0] } }
        let raw = body.map { record in rawIndex.map { index in index.map { record[$0] } } }
        return (display, raw)
    }

    /// What the CSV writes for a cell with the formula guard on: the one string every format
    /// writes, with an apostrophe in front of a *text* field a spreadsheet would otherwise
    /// evaluate. Only text is guarded — a number, a date, a boolean or a refusal token never is
    /// (CR-57).
    private static func csvText(_ cell: ExportCell) -> String {
        if case .text(let text) = cell, let first = text.first, "=+-@\t\r".contains(first) {
            return "'" + text
        }
        return cell.text
    }

    private func jsonCells(_ projection: ExportProjection) throws -> [[String]] {
        let data = ZenitJSONExporter().export(projection)
        let document = try ZenitJSONImporter().document(from: data)
        return document.rows.map { row in
            row.cells.map { cell in
                switch cell {
                case .blank: ""
                case .text(let value): value
                case .boolean(let flag): flag ? "TRUE" : "FALSE"
                case .date(let iso): iso
                case .refusal(let token): token
                case .number(let number): number.display
                }
            }
        }
    }

    private func xlsxCells(_ projection: ExportProjection, url: URL) throws -> [[String]] {
        try XLSXExporter().export(projection, to: url, options: Self.xlsxOptions)
        let sheet = try XLSXInspector(url: url)
        #expect(
            sheet.cells.filter { $0.row == 0 }.map(\.value)
                == projection.table.columns.map { column in
                    column.unitSymbol.isEmpty ? column.title : "\(column.title) (\(column.unitSymbol))"
                }
        )
        var output: [[String]] = []
        for rowIndex in 0..<projection.table.rows.count {
            var fields: [String] = []
            for columnIndex in 0..<projection.table.columns.count {
                guard let cell = sheet.cells.first(
                    where: { $0.row == rowIndex + 1 && $0.column == columnIndex }
                ) else {
                    fields.append("")
                    continue
                }
                switch projection.table.columns[columnIndex].kind {
                case .date:
                    // A real date cell, so Excel can sort and filter it. Read back through the
                    // serial-number conversion, it must be the same ISO-8601 instant.
                    #expect(sheet.numberFormat(of: cell)?.contains("yyyy") == true)
                    fields.append(try sheet.renderedDate(cell))
                case .number, .currency, .formula where cell.type == nil:
                    fields.append(try sheet.rendered(cell, locale: projection.numberLocale))
                default:
                    fields.append(cell.value)
                }
            }
            output.append(fields)
        }
        return output
    }

    private func pdfCells(_ projection: ExportProjection, url: URL) throws -> [[String]] {
        let result = try PDFReportRenderer().render(projection, to: url, options: Self.pdfOptions)
        #expect(result.bandCount == 1, "the fidelity comparison needs one band")
        // Every column of the golden fixture is filled on some row, so nothing is pruned and the
        // comparison stays column for column against the other three formats (LT-18).
        #expect(result.printedColumnCount == projection.table.columns.count,
                "the fidelity comparison needs every column printed")
        let width = result.printedColumnCount
        return stride(from: 0, to: result.drawnText.count, by: width).map {
            Array(result.drawnText[$0..<min($0 + width, result.drawnText.count)])
        }
    }

    @Test("The same string in the CSV, the JSON, the XLSX cell and the PDF table")
    func fourFormatsAgree() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let xlsxURL = temporaryURL("xlsx")
        let pdfURL = temporaryURL("pdf")
        defer {
            try? FileManager.default.removeItem(at: xlsxURL)
            try? FileManager.default.removeItem(at: pdfURL)
        }

        let onScreen = projection.table.rows.map { $0.cells.map(\.text) }
        // The report spells a date for a reader and the three parsed formats keep ISO-8601
        // (LT-19), so the PDF is held against `printedText` — the same instant, one spelling per
        // audience. Every other cell is the one string all four write, and `printedText` is that
        // string, so this is not a loosened assertion: `datesAreTheOnlyFormatDifference` below
        // pins down exactly which cells the two differ in.
        let printed = projection.table.rows.map { $0.cells.map(\.printedText) }
        let csv = try csvFields(projection)
        let json = try jsonCells(projection)
        let xlsx = try xlsxCells(projection, url: xlsxURL)
        let pdf = try pdfCells(projection, url: pdfURL)

        #expect(csv.display.count == onScreen.count)
        #expect(json.count == onScreen.count)
        #expect(xlsx.count == onScreen.count)
        #expect(pdf.count == onScreen.count)

        for (rowIndex, row) in projection.table.rows.enumerated() {
            for (columnIndex, cell) in row.cells.enumerated() {
                let column = projection.table.columns[columnIndex].key
                let value = cell.text
                #expect(csv.display[rowIndex][columnIndex] == Self.csvText(cell),
                        "CSV \(column) row \(rowIndex)")
                if let number = cell.number {
                    // The raw field is the exact stored value, never the display value and
                    // never guarded.
                    #expect(csv.raw[rowIndex][columnIndex] == number.invariantRawText,
                            "CSV raw \(column) row \(rowIndex)")
                }
                #expect(json[rowIndex][columnIndex] == value, "JSON \(column) row \(rowIndex)")
                #expect(xlsx[rowIndex][columnIndex] == value, "XLSX \(column) row \(rowIndex)")
                #expect(pdf[rowIndex][columnIndex] == printed[rowIndex][columnIndex],
                        "PDF \(column) row \(rowIndex)")
            }
        }

        // The guard fired exactly once — on the injected comment — and on nothing numeric.
        let guarded = csv.display.enumerated().flatMap { rowIndex, fields in
            fields.enumerated().filter { $0.element.hasPrefix("'") }.map { (rowIndex, $0.offset) }
        }
        let comment = try #require(projection.table.columns.firstIndex { $0.key == "comment" })
        let injected = try #require(ExportFixture.hostileComments.firstIndex(of: "=1+1"))
        #expect(guarded.map(\.0) == [injected])
        #expect(guarded.map(\.1) == [comment])
        #expect(csv.display[injected][comment] == "'=1+1")
    }

    /// The one place the four formats are allowed to differ, stated as an assertion rather than
    /// left as a hole in ``fourFormatsAgree``.
    @Test("A date is the only cell the report spells differently from the parsed formats")
    func datesAreTheOnlyFormatDifference() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        var dateColumns: Set<Int> = []
        for row in projection.table.rows {
            for (index, cell) in row.cells.enumerated() {
                if cell.printedText == cell.text { continue }
                dateColumns.insert(index)
                guard case .date(let value) = cell else {
                    Issue.record("column \(index) differs and is not a date")
                    continue
                }
                // Same instant, two spellings — never a different value.
                #expect(cell.printedText == value.humanText)
                #expect(cell.text == value.iso8601)
            }
        }
        let expected = Set(
            projection.table.columns.indices.filter { projection.table.columns[$0].kind == .date }
        )
        #expect(!expected.isEmpty, "the fixture must carry a date column")
        #expect(dateColumns == expected)
    }

    /// The same assertion narrowed to the values that break a careless implementation, so a
    /// failure here names the digit rather than the row.
    @Test("The double-rounding goldens agree in every format")
    func goldensAgree() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let xlsxURL = temporaryURL("xlsx")
        let pdfURL = temporaryURL("pdf")
        defer {
            try? FileManager.default.removeItem(at: xlsxURL)
            try? FileManager.default.removeItem(at: pdfURL)
        }
        let column = try #require(projection.table.columns.firstIndex { $0.key == "golden" })

        #expect(projection.table.rows.map { $0.cells[column].text } == ExportFixture.expectedGoldenText)
        let csv = try csvFields(projection)
        #expect(csv.display.map { $0[column] } == ExportFixture.expectedGoldenText)
        // The raw column carries the stored value the display was rounded from.
        #expect(csv.raw.map { $0[column] } == ExportFixture.goldenValues.map { $0.description })
        #expect(try jsonCells(projection).map { $0[column] } == ExportFixture.expectedGoldenText)
        #expect(try xlsxCells(projection, url: xlsxURL).map { $0[column] } == ExportFixture.expectedGoldenText)
        #expect(try pdfCells(projection, url: pdfURL).map { $0[column] } == ExportFixture.expectedGoldenText)
    }

    /// The unit conversion leg: stored in square metres, displayed in square feet. Converting
    /// after rounding, or rounding twice around the conversion, gives a different last digit.
    @Test("A converted unit agrees in every format")
    func convertedUnitAgrees() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let xlsxURL = temporaryURL("xlsx")
        let pdfURL = temporaryURL("pdf")
        defer {
            try? FileManager.default.removeItem(at: xlsxURL)
            try? FileManager.default.removeItem(at: pdfURL)
        }
        let column = try #require(projection.table.columns.firstIndex { $0.key == "footprint" })
        let expected = projection.table.rows.map { $0.cells[column].text }
        #expect(expected.first == "107.64")
        let csv = try csvFields(projection)
        #expect(csv.display.map { $0[column] } == expected)
        // Raw is the stored square-metre value, unconverted.
        #expect(csv.raw.first?[column] == "10")
        #expect(try jsonCells(projection).map { $0[column] } == expected)
        #expect(try xlsxCells(projection, url: xlsxURL).map { $0[column] } == expected)
        #expect(try pdfCells(projection, url: pdfURL).map { $0[column] } == expected)
    }

    /// XLSX is excluded from the locale sweep on purpose, and the reason is in `XLSXExporter`:
    /// a workbook has no per-cell decimal separator, so Excel renders with the host's. The other
    /// three carry their own digits and must agree exactly, in every locale (QUALITY_BAR A33).
    @Test(
        "CSV, JSON and PDF agree digit for digit in every locale",
        arguments: [
            ExportNumberLocale.invariant,
            ExportNumberLocale.enUS,
            ExportNumberLocale.svSE.withGrouping(nil),
            ExportNumberLocale.arEG.withGrouping(nil)
        ]
    )
    func localeSweep(locale: ExportNumberLocale) throws {
        let projection = try ExportFixture.projection(
            try ExportFixture.goldenReport(), locale: locale
        )
        let pdfURL = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let onScreen = projection.table.rows.map { $0.cells.map(\.text) }
        let asCSV = projection.table.rows.map { $0.cells.map(Self.csvText) }
        // The report's dates are spelled for a reader (LT-19); its *digits* are the projection's,
        // which is what this sweep is about — `datesAreTheOnlyFormatDifference` holds the line on
        // everything else.
        let printed = projection.table.rows.map { $0.cells.map(\.printedText) }
        let csv = try csvFields(projection)
        let json = try jsonCells(projection)
        let pdf = try pdfCells(projection, url: pdfURL)
        #expect(csv.display == asCSV)
        // A localized minus sign is never mistaken for a formula prefix: the negative Cost cell
        // reads exactly as the projection spells it, in every locale.
        let cost = try #require(projection.table.columns.firstIndex { $0.key == "cost" })
        let minusFourThousandths = try #require(Decimal(string: "-0.004"))
        let negative = try #require(ExportFixture.goldenValues.firstIndex(of: minusFourThousandths))
        #expect(csv.display[negative][cost] == onScreen[negative][cost])
        #expect(!csv.display[negative][cost].hasPrefix("'"))
        #expect(json == onScreen)
        #expect(pdf == printed)
    }

    @Test("The mixed-units token is the same string in all four formats")
    func refusalTokenAgrees() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let xlsxURL = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: xlsxURL) }

        let column = try #require(projection.table.columns.firstIndex { $0.key == "mixed" })
        let total = try #require(projection.table.grandTotals.first { $0.function == "Sum" })
        let token = total.cells[column].text
        #expect(token.hasPrefix(LedgerReport.mixedDimensionsToken))

        let csv = String(decoding: try CSVExporter().export(projection), as: UTF8.self)
        #expect(csv.contains(token))

        let json = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        #expect(json.contains(token))

        try XLSXExporter().export(projection, to: xlsxURL)
        let sheet = try XLSXInspector(url: xlsxURL)
        #expect(sheet.cells.contains { $0.value == token })

        let lines = PDFReportRenderer.flatten(
            table: projection.table, options: PDFReportOptions()
        )
        var found = false
        for line in lines {
            if case .grandTotal(_, let cells) = line, cells[column].text == token { found = true }
        }
        #expect(found)
    }
}
