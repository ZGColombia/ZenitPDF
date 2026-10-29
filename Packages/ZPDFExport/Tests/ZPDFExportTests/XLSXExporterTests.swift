import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

@Suite("XLSX export", .sharedHeap)
struct XLSXExporterTests {

    @Test("Quantities are numeric cells carrying a number format, never strings")
    func numericCells() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)

        let sheet = try XLSXInspector(url: url)
        let header = sheet.cells.filter { $0.row == 0 }
        let goldenColumn = try #require(header.first { $0.value == "Golden" }?.column)
        for row in 1...ExportFixture.goldenValues.count {
            let cell = try #require(sheet.cells.first { $0.row == row && $0.column == goldenColumn })
            #expect(cell.type == nil, "a quantity cell must not be a string cell")
            #expect(sheet.numberFormat(of: cell) == "0.00")
            #expect(Double(cell.value) != nil)
        }
    }

    /// QUALITY_BAR A32 for XLSX, verbatim: the cell holds the full-precision value, and the
    /// string Excel renders under the applied format is the on-screen string.
    @Test("The rendered string under the cell's number format equals the on-screen string")
    func renderedStringsMatch() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)

        let sheet = try XLSXInspector(url: url)
        let header = sheet.cells.filter { $0.row == 0 }
        for (columnIndex, column) in projection.table.columns.enumerated() where column.isNumeric {
            let title = column.unitSymbol.isEmpty
                ? column.title
                : "\(column.title) (\(column.unitSymbol))"
            guard let sheetColumn = header.first(where: { $0.value == title })?.column else { continue }
            for (rowIndex, row) in projection.table.rows.enumerated() {
                guard let expected = row.cells[columnIndex].number else { continue }
                let cell = try #require(
                    sheet.cells.first { $0.row == rowIndex + 1 && $0.column == sheetColumn },
                    "no cell for \(title) row \(rowIndex)"
                )
                #expect(
                    try sheet.rendered(cell, locale: projection.numberLocale) == expected.text,
                    "\(title) row \(rowIndex)"
                )
            }
        }
    }

    /// The one that would fail on a naive implementation: the stored double for `1.005` is
    /// `1.00499999999999989`, and `String(format: "%.2f", …)` of it is `1.00`. Excel — and this
    /// test — display `1.01`, because both go through the 15-significant-digit decimal form.
    @Test("The double-rounding golden values render correctly in the sheet")
    func doubleRoundingGoldens() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)

        let sheet = try XLSXInspector(url: url)
        let goldenColumn = try #require(
            sheet.cells.first { $0.row == 0 && $0.value == "Golden" }?.column
        )
        var rendered: [String] = []
        for row in 1...ExportFixture.goldenValues.count {
            let cell = try #require(sheet.cells.first { $0.row == row && $0.column == goldenColumn })
            rendered.append(try sheet.rendered(cell, locale: .invariant))
        }
        #expect(rendered == ExportFixture.expectedGoldenText)
        #expect(String(format: "%.2f", 1.005) == "1.00")
    }

    @Test("Frozen header, auto-filter and column widths are in the sheet")
    func furniture() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)

        let sheet = try XLSXInspector(url: url)
        #expect(sheet.sheetXML.contains("<pane ySplit=\"1\""))
        #expect(sheet.sheetXML.contains("state=\"frozen\""))
        #expect(sheet.sheetXML.contains("<autoFilter ref=\"A1:"))
        #expect(sheet.sheetXML.contains("<col "))
        #expect(sheet.sheetXML.contains("customWidth=\"1\""))
    }

    @Test("Subtotal and grand total rows are written and labelled")
    func totals() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)

        let sheet = try XLSXInspector(url: url)
        let labels = sheet.cells.filter { $0.column == 0 }.map(\.value)
        #expect(labels.contains { $0.hasPrefix("Subtotal: Sum") })
        #expect(labels.contains { $0.hasPrefix("Total: Sum") })
    }

    @Test("A subtotal in the sheet equals the projection's subtotal for that group")
    func subtotalsReconcile() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)

        let sheet = try XLSXInspector(url: url)
        let goldenIndex = try #require(
            projection.table.columns.firstIndex { $0.key == "golden" }
        )
        let goldenColumn = try #require(
            sheet.cells.first { $0.row == 0 && $0.value == "Golden" }?.column
        )
        var expected: [String] = []
        for group in projection.table.groups {
            for subtotal in group.subtotals where subtotal.function == "Sum" {
                expected.append(subtotal.cells[goldenIndex].text)
            }
        }
        var found: [String] = []
        for cell in sheet.cells where cell.column == 0 && cell.value.hasPrefix("Subtotal: Sum") {
            if let value = sheet.cells.first(where: { $0.row == cell.row && $0.column == goldenColumn }) {
                found.append(try sheet.rendered(value, locale: .invariant))
            }
        }
        #expect(found == expected)
        #expect(!expected.isEmpty)
    }

    @Test("The mixed-units token is a cell, not a blank")
    func mixedUnits() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)
        let sheet = try XLSXInspector(url: url)
        #expect(sheet.cells.contains { $0.value.hasPrefix(LedgerReport.mixedDimensionsToken) })
    }

    @Test("The metadata sheet records the project, the filter and the formula semantics")
    func metadataSheet() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)
        let info = try XLSXInspector(url: url, sheet: 2)
        let values = info.cells.map(\.value)
        #expect(values.contains("Example Quay, Block C"))
        #expect(values.contains("1:100 (calibrated, two-point)"))
        #expect(values.contains("Filter"))
        #expect(values.contains("ALL"))
    }

    @Test("Constant-memory mode writes 10 000 rows and the same numbers")
    func constantMemoryVolume() throws {
        let projection = try ExportFixture.projection(
            try ExportFixture.syntheticReport(rowCount: 10_000)
        )
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(
            projection,
            to: url,
            options: XLSXExportOptions(constantMemory: true)
        )
        let sheet = try XLSXInspector(url: url)
        let lastRow = sheet.cells.map(\.row).max() ?? 0
        #expect(lastRow >= 10_000)
        let goldenColumn = try #require(
            sheet.cells.first { $0.row == 0 && $0.value == "Golden" }?.column
        )
        let firstValue = try #require(sheet.cells.first { $0.row == 1 && $0.column == goldenColumn })
        // Row 1 of the synthetic ledger stores 1/8 = 0.125, which at two places is 0.13.
        #expect(try sheet.rendered(firstValue, locale: .invariant) == "0.13")
    }

    @Test("Raw columns carry the exact stored value at full precision")
    func rawColumns() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(
            projection, to: url, options: XLSXExportOptions(includeRawColumns: true)
        )
        let sheet = try XLSXInspector(url: url)
        let rawColumn = try #require(
            sheet.cells.first { $0.row == 0 && $0.value == "Golden (raw)" }?.column
        )
        let cell = try #require(sheet.cells.first { $0.row == 1 && $0.column == rawColumn })
        #expect(cell.type == nil)
        #expect(Double(cell.value) == 0.4449)
    }
}
