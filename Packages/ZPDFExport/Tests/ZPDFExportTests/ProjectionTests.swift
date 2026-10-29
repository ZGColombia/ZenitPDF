import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

@Suite("Projection", .sharedHeap)
struct ProjectionTests {

    @Test("Every column of the report becomes a column of the projection")
    func columns() throws {
        let report = try ExportFixture.goldenReport()
        let projection = try ExportFixture.projection(report)
        #expect(projection.table.columns.map(\.key) == report.columns.map(\.key))
        #expect(projection.table.rows.count == ExportFixture.goldenValues.count)
    }

    @Test("A requested column set selects and orders the columns")
    func columnSelection() throws {
        let report = try ExportFixture.goldenReport()
        let projection = try ExportProjector().project(
            report,
            options: ExportProjectionOptions(columnKeys: ["golden", "subject"])
        )
        #expect(projection.table.columns.map(\.key) == ["golden", "subject"])
        #expect(projection.table.rows[0].cells.count == 2)
    }

    @Test("A column key the report does not have is a typed error, not a silent omission")
    func unknownColumn() throws {
        let report = try ExportFixture.goldenReport()
        #expect(throws: ExportError.self) {
            try ExportProjector().project(
                report,
                options: ExportProjectionOptions(columnKeys: ["golden", "nope"])
            )
        }
    }

    @Test("The projection converts to the display unit before it rounds")
    func convertsThenRounds() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let index = try #require(projection.table.columns.firstIndex { $0.key == "footprint" })
        let cell = try #require(projection.table.rows[0].cells[index].number)
        // Row 0 stores 10 m2. In ft2 that is 10 / 0.09290304 = 107.6391041670972...
        #expect(cell.raw == 10)
        #expect(cell.unitSymbol == "ft\u{00B2}")
        #expect(cell.display == Decimal(string: "107.64"))
        #expect(cell.text == "107.64")
        // The exact converted value is kept, unrounded, for the XLSX cell and the CSV raw column.
        #expect(cell.convertedRaw > Decimal(string: "107.639")!)
        #expect(cell.convertedRaw < Decimal(string: "107.6392")!)
        #expect(cell.invariantRawText == "10")
    }

    @Test("Golden values render as the single-rounded form")
    func goldenValuesRender() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let index = try #require(projection.table.columns.firstIndex { $0.key == "golden" })
        let rendered = projection.table.rows.map { $0.cells[index].text }
        #expect(rendered == ExportFixture.expectedGoldenText)
    }

    @Test("A mixed-dimension total is a token, never a blank and never a zero")
    func mixedDimensions() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let index = try #require(projection.table.columns.firstIndex { $0.key == "mixed" })
        let total = try #require(projection.table.grandTotals.first { $0.function == "Sum" })
        let cell = total.cells[index]
        #expect(cell.isRefusal)
        #expect(cell.text.hasPrefix(LedgerReport.mixedDimensionsToken))
        #expect(!cell.text.isEmpty)
    }

    @Test("A count aggregate renders as an integer, not as the column's decimal places")
    func countIsAnInteger() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let index = try #require(projection.table.columns.firstIndex { $0.key == "subject" })
        let total = try #require(projection.table.grandTotals.first { $0.function == "Count" })
        #expect(total.cells[index].text == "6")
    }

    @Test("Grouping produces one group per subject with its own subtotals")
    func grouping() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        #expect(projection.table.groups.count == 2)
        #expect(projection.table.rows.isEmpty)
        let labels = Set(projection.table.groups.map(\.label))
        #expect(labels == ["Concrete", "Steel"])
        for group in projection.table.groups {
            #expect(group.rowCount == 3)
            #expect(!group.subtotals.isEmpty)
        }
    }

    @Test("Dates are ISO-8601 UTC everywhere")
    func dates() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let index = try #require(projection.table.columns.firstIndex { $0.key == "created" })
        #expect(projection.table.rows[0].cells[index].text == "2026-05-28T20:26:40Z")
        #expect(projection.table.metadata.generatedAt.iso8601 == "2026-05-28T20:26:40Z")
    }

    @Test("Two projections of the same report are equal")
    func deterministic() throws {
        let report = try ExportFixture.goldenReport(grouped: true)
        #expect(try ExportFixture.projection(report) == (try ExportFixture.projection(report)))
    }
}
