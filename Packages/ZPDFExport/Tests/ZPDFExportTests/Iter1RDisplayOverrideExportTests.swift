import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// NL-MEASURE-10 (ADR-0035 §1.3), the export half: a markup with display units of its own is
/// exported in them, cell by cell and in its unit column, in CSV and XLSX alike, while every
/// other row and every total stays in the project's units.
///
/// Two 3.81 m walls in an imperial project. 3.81 / 0.3048 = 12.5 ft exactly, so the plain row
/// reads 12'-6" in feet; the second row is set to metres at two decimals and reads 3.81 m. The
/// grand total is 7.62 m = 25 ft = 25'-0" in the project's units.
@Suite("Iteration 1 re-fix quantities-core: per-row display units in exports", .sharedHeap)
struct Iter1RDisplayOverrideExportTests {

    static let documentID = DocumentID(ExportFixture.uuid(-501))
    static let pageID = PageID(ExportFixture.uuid(-502))
    static let metres = DisplayUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre, precision: .decimalPlaces(2))

    static func wall(_ index: Int, override: DisplayUnitPolicy?) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(ExportFixture.uuid(index)),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .length,
            subject: override == nil ? "Wall" : "Rebar",
            author: "Ada",
            parameters: MeasurementParameters(displayOverride: override),
            measurement: MeasurementResult(values: [.planLength: .length(Decimal(string: "3.81")!)]),
            createdAt: ExportFixture.epoch,
            modifiedAt: ExportFixture.epoch
        )
    }

    /// The projection of the two walls, Plan Length summed, project units imperial.
    static func projection(overrideSecond: Bool = true) throws -> ExportProjection {
        let store = try LedgerStore(
            markups: [wall(1, override: nil), wall(2, override: overrideSecond ? metres : nil)],
            columns: try LedgerColumnSet.standard(displayPolicy: .imperial)
        )
        var plan = LedgerAggregationPlan()
        plan.add(AggregateKey(column: ExportFixture.standardID(.planLength), function: .sum))
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(LedgerViewSpec(aggregation: plan)), title: "Walls")
        return try ExportProjector().project(
            report,
            options: ExportProjectionOptions(columnKeys: ["subject", "planLength"])
        )
    }

    /// Old output: both rows `12'-6"` with unit `ft` — the report gave every cell its column's
    /// formatting, so the override reached the screen and nothing else.
    @Test("CSV: the overridden row's cell and unit column are in its own units; the total is not")
    func csvRowUsesItsOwnUnits() throws {
        let data = try CSVExporter().export(try Self.projection())
        let records = CSVReader.records(try #require(String(data: data, encoding: .utf8)), delimiter: ",")
        let header = try #require(records.first)
        let value = try #require(header.firstIndex(of: "planLength"))
        let unit = try #require(header.firstIndex(of: "planLength (unit)"))
        let raw = try #require(header.firstIndex(of: "planLength (raw)"))
        let subject = try #require(header.firstIndex(of: "subject"))

        let wall = try #require(records.first { $0.count > subject && $0[subject] == "Wall" })
        let rebar = try #require(records.first { $0.count > subject && $0[subject] == "Rebar" })
        #expect(wall[value] == "12'-6\"")
        #expect(wall[unit] == "ft")
        #expect(rebar[value] == "3.81")
        #expect(rebar[unit] == "m")
        // The raw column is the stored SI value on both rows.
        #expect(wall[raw] == "3.81")
        #expect(rebar[raw] == "3.81")
        // The grand total sums in SI and prints in the project's units: 7.62 m = 25 ft.
        let total = try #require(records.last { $0.contains { $0.hasSuffix(": Sum") } })
        #expect(total[value] == "25'-0\"")
        #expect(total[unit] == "ft")
    }

    /// Old output: `12.5` in both rows' cells (decimal feet), `ft` in both unit cells, a header
    /// "planLength (ft)" over them, and — with live formulas — a `SUM` that would add the rebar
    /// row's metres to the wall's feet when the sheet recalculates.
    @Test("XLSX: the overridden row's cell and unit are its own; no header unit or live SUM mixes them")
    func xlsxRowUsesItsOwnUnits() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(try Self.projection(), to: url, options: XLSXExportOptions(includeFormulas: true))
        let sheet = try XLSXInspector(url: url)

        // Columns: Record, subject, planLength, planLength (raw), planLength (unit).
        let headers = sheet.cells.filter { $0.row == 0 }.sorted { $0.column < $1.column }.map(\.value)
        #expect(headers.contains("planLength"), "no single unit in the header of a mixed column")
        #expect(!headers.contains("planLength (ft)"))
        let value = try #require(headers.firstIndex(of: "planLength"))
        let unit = try #require(headers.firstIndex(of: "planLength (unit)"))
        let subject = try #require(headers.firstIndex(of: "subject"))

        func row(_ name: String) throws -> Int {
            try #require(sheet.cells.first { $0.column == subject && $0.value == name }).row
        }
        func cell(_ row: Int, _ column: Int) throws -> XLSXInspector.Cell {
            try #require(sheet.cells.first { $0.row == row && $0.column == column })
        }
        let wallRow = try row("Wall"), rebarRow = try row("Rebar")
        // Feet in the wall row (12.5 ft), metres in the rebar row (3.81 m).
        #expect(Decimal(string: try cell(wallRow, value).value) == Decimal(string: "12.5"))
        #expect(try cell(wallRow, unit).value == "ft")
        #expect(Decimal(string: try cell(rebarRow, value).value) == Decimal(string: "3.81"))
        #expect(try cell(rebarRow, unit).value == "m")
        // The grand total is the ledger's own 25 ft, written as a number, not a live SUM of
        // 12.5 + 3.81 = 16.31.
        #expect(!sheet.sheetXML.contains("<f>SUM(C"), "no live SUM over the mixed value column")
        let totalRow = try #require(sheet.cells.filter { $0.column == value }.map(\.row).max())
        #expect(Decimal(string: try cell(totalRow, value).value) == 25)
    }

    /// Without an override nothing changes: the header keeps its unit and the live SUM stays.
    @Test("XLSX without an override keeps its header unit and its live SUM")
    func xlsxWithoutOverrideUnchanged() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(try Self.projection(overrideSecond: false), to: url, options: XLSXExportOptions(includeFormulas: true))
        let sheet = try XLSXInspector(url: url)
        let headers = sheet.cells.filter { $0.row == 0 }.map(\.value)
        #expect(headers.contains("planLength (ft)"))
        #expect(sheet.sheetXML.contains("<f>SUM(C"))
    }
}
