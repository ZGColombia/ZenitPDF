import Foundation
import Testing
import ZPDFQuantityLedger
@testable import ZPDFExport

@Suite("CSV export", .sharedHeap)
struct CSVExporterTests {

    private func text(_ data: Data, expectingBOM: Bool = false) throws -> String {
        var string = String(decoding: data, as: UTF8.self)
        if expectingBOM {
            #expect(string.hasPrefix("\u{FEFF}"))
            string.removeFirst()
        } else {
            #expect(!string.hasPrefix("\u{FEFF}"))
        }
        return string
    }

    @Test("The header row is derived from the visible column set")
    func header() throws {
        let projection = try ExportProjector().project(
            try ExportFixture.goldenReport(),
            options: ExportProjectionOptions(columnKeys: ["subject", "golden"])
        )
        let data = try CSVExporter().export(
            projection,
            options: CSVExportOptions(includeSubtotalRows: false, includeGrandTotalRows: false)
        )
        let records = CSVReader.records(try text(data), delimiter: ",")
        #expect(records[0] == ["subject", "Golden", "Golden (raw)", "Golden (unit)"])
    }

    @Test("Fields containing the delimiter, quotes or newlines are quoted per RFC 4180")
    func quoting() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let data = try CSVExporter().export(projection)
        let raw = try text(data)

        // Written form: the embedded quote is doubled, the newline stays inside the quotes.
        #expect(raw.contains("\"has \"\"embedded\"\" quotes\""))
        #expect(raw.contains("\"line one\nline two\""))
        #expect(raw.contains("\"has,comma;and semicolon\""))
        #expect(raw.contains("\" leading and trailing \""))

        // Read back: a conforming parser recovers the originals exactly.
        let records = CSVReader.records(raw, delimiter: ",")
        let commentColumn = try #require(records[0].firstIndex(of: "comment"))
        let comments = records.dropFirst().prefix(6).map { $0[commentColumn] }
        #expect(comments == ExportFixture.hostileComments.enumerated().map { index, value in
            // Row 4 is the formula-injection guard's business, checked separately.
            index == 4 ? "'=1+1" : value
        })
    }

    @Test("A leading = is neutralised so Excel does not evaluate it")
    func formulaInjection() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let guarded = try CSVExporter().export(projection)
        #expect(try text(guarded).contains("'=1+1"))

        let unguarded = try CSVExporter().export(
            projection,
            options: CSVExportOptions(formulaInjectionGuard: .none)
        )
        let raw = try text(unguarded)
        #expect(raw.contains("=1+1"))
        #expect(!raw.contains("'=1+1"))
    }

    @Test("Records end with CRLF by default and with LF on request")
    func lineEndings() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let crlf = try text(try CSVExporter().export(projection))
        #expect(crlf.contains("\r\n"))
        #expect(crlf.hasSuffix("\r\n"))

        let lf = try text(try CSVExporter().export(
            projection, options: CSVExportOptions(lineEnding: .lf)
        ))
        // The only CR left is the one inside a quoted field, and there is none in this fixture.
        #expect(!lf.contains("\r"))
        #expect(lf.hasSuffix("\n"))
    }

    @Test("A Swedish Excel gets semicolons, a comma decimal separator and a BOM")
    func swedishExcel() throws {
        let projection = try ExportFixture.projection(
            try ExportFixture.goldenReport(),
            locale: .svSE.withGrouping(nil)
        )
        let data = try CSVExporter().export(projection, options: .excelSwedish)
        let raw = try text(data, expectingBOM: true)
        let records = CSVReader.records(raw, delimiter: ";")
        let goldenColumn = try #require(records[0].firstIndex(of: "Golden"))
        let values = records.dropFirst().prefix(6).map { $0[goldenColumn] }
        #expect(values == ["0,44", "1,01", "2,68", "0,00", "1234567,89", "8,13"])
        // The raw column is invariant on purpose: it is parsed, not read.
        let rawColumn = try #require(records[0].firstIndex(of: "Golden (raw)"))
        #expect(records[1][rawColumn] == "0.4449")
    }

    @Test("A delimiter that is also the decimal separator is refused")
    func delimiterCollision() throws {
        let projection = try ExportFixture.projection(
            try ExportFixture.goldenReport(), locale: .svSE
        )
        #expect(throws: ExportError.self) {
            try CSVExporter().export(projection, options: CSVExportOptions(delimiter: ","))
        }
        // The grouping separator counts too.
        #expect(throws: ExportError.self) {
            try CSVExporter().export(
                projection, options: CSVExportOptions(delimiter: "\u{00A0}")
            )
        }
    }

    @Test("Raw and unit columns carry the exact value and the unit")
    func rawAndUnitColumns() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let records = CSVReader.records(
            try text(try CSVExporter().export(projection)), delimiter: ","
        )
        let display = try #require(records[0].firstIndex(of: "Footprint"))
        let raw = try #require(records[0].firstIndex(of: "Footprint (raw)"))
        let unit = try #require(records[0].firstIndex(of: "Footprint (unit)"))
        #expect(records[1][display] == "107.64")
        #expect(records[1][raw] == "10")
        #expect(records[1][unit] == "ft\u{00B2}")
    }

    @Test("Grouped output carries subtotal and grand total rows, labelled")
    func subtotals() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let records = CSVReader.records(
            try text(try CSVExporter().export(projection)), delimiter: ","
        )
        let kinds = records.dropFirst().map { $0[0] }
        #expect(kinds.filter { $0 == "Row" }.count == 6)
        #expect(kinds.contains("Subtotal: Sum"))
        #expect(kinds.contains("Total: Sum"))
        // Every record has the same field count — a ragged CSV is a broken CSV.
        #expect(Set(records.map(\.count)).count == 1)
    }

    @Test("The mixed-units token appears in the CSV, not an empty field")
    func mixedUnitsToken() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let records = CSVReader.records(
            try text(try CSVExporter().export(projection)), delimiter: ","
        )
        let column = try #require(records[0].firstIndex(of: "Mixed"))
        let totalRow = try #require(records.first { $0[0] == "Total: Sum" })
        #expect(totalRow[column].hasPrefix(LedgerReport.mixedDimensionsToken))
    }

    @Test("Two exports of the same projection are byte-identical")
    func deterministic() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let exporter = CSVExporter()
        #expect(try exporter.export(projection) == (try exporter.export(projection)))
    }

    @Test("10 000 rows export without a ragged record")
    func volume() throws {
        let projection = try ExportFixture.projection(try ExportFixture.syntheticReport(rowCount: 10_000))
        let data = try CSVExporter().export(projection)
        let records = CSVReader.records(try text(data), delimiter: ",")
        #expect(records.count >= 10_001)
        #expect(Set(records.map(\.count)).count == 1)
    }
}
