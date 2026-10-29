import Foundation
import Testing
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Feature 34 — Excel export with the formulas intact, *as an alternative*.
///
/// Two properties, and the second one is a product requirement rather than a nicety: with
/// `includeFormulas` on, the totals are live `SUM` formulas; with it off — the default — the
/// workbook is exactly the workbook this exporter has always written. A recipient who wants
/// numbers gets numbers.
@Suite("XLSX live formulas", .sharedHeap)
struct XLSXFormulaTests {

    private func export(
        grouped: Bool = true,
        formulas: Bool,
        to url: URL
    ) throws {
        let projection = try ExportFixture.projection(
            try ExportFixture.goldenReport(grouped: grouped)
        )
        try XLSXExporter().export(
            projection,
            to: url,
            options: XLSXExportOptions(includeFormulas: formulas)
        )
    }

    /// Every `<f>…</f>` in the sheet, in document order.
    private func formulas(in inspector: XLSXInspector) -> [String] {
        var found: [String] = []
        var rest = Substring(inspector.sheetXML)
        while let open = rest.range(of: "<f>"), let close = rest.range(of: "</f>") {
            found.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return found
    }

    // MARK: - The default path

    @Test("The default export writes no formula at all")
    func defaultModeHasNoFormulas() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try export(formulas: false, to: url)

        let inspector = try XLSXInspector(url: url)
        #expect(formulas(in: inspector).isEmpty)
        #expect(!inspector.sheetXML.contains("<f>"))
        // The option is off unless somebody turns it on.
        #expect(XLSXExportOptions().includeFormulas == false)
    }

    @Test("The default export is byte-for-byte what it was: two runs produce the same parts")
    func defaultModeIsDeterministic() throws {
        let first = temporaryURL("xlsx")
        let second = temporaryURL("xlsx")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try export(formulas: false, to: first)
        try export(formulas: false, to: second)

        // Every part a reader acts on, compared as written. There is no pre-change golden file in
        // this package, so determinism plus "no <f> anywhere" is the strongest available statement
        // that the default path is unchanged by feature 34.
        for part in ["xl/worksheets/sheet1.xml", "xl/styles.xml", "xl/sharedStrings.xml"] {
            #expect(
                try XLSXInspector.entry(part, of: first) == XLSXInspector.entry(part, of: second),
                "\(part) differs between two default exports"
            )
        }

        // And the numbers themselves are still numbers, not formula cells. A cell with no type
        // and no value is a formatted blank, which the exporter writes to carry a total row's
        // top border; everything else untyped is a stored number.
        let inspector = try XLSXInspector(url: first)
        let numeric = inspector.cells.filter { $0.type == nil && !$0.value.isEmpty }
        #expect(!numeric.isEmpty)
        #expect(numeric.allSatisfy { Double($0.value) != nil })
    }

    // MARK: - The formula path

    @Test("With formulas on, every Sum subtotal and grand total is a live SUM")
    func formulaModeWritesSums() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try export(formulas: true, to: url)

        let inspector = try XLSXInspector(url: url)
        let written = formulas(in: inspector)
        #expect(!written.isEmpty)
        #expect(written.allSatisfy { $0.hasPrefix("SUM(") })

        // The golden ledger grouped by subject writes: header (Excel row 1), three Concrete rows
        // (2-4), that group's two subtotal rows (5-6), three Steel rows (7-9), its two subtotals
        // (10-11), then the two grand totals (12-13).
        //
        // So a subtotal sums 2:4 or 7:9, and the grand total sums both runs — and no formula may
        // name row 5, 6, 10, 11, 12 or 13. Summing a range that spans a subtotal is exactly how a
        // takeoff doubles, and it is the reason the exporter tracks data rows instead of taking
        // the first and last row of a group.
        #expect(written.contains("SUM(H2:H4)"))
        #expect(written.contains("SUM(H7:H9)"))
        #expect(written.contains("SUM(H2:H4,H7:H9)"))

        let totalRows = ["5", "6", "10", "11", "12", "13"]
        for formula in written {
            let referenced = formula
                .dropFirst("SUM(".count).dropLast()
                .split(whereSeparator: { $0 == "," || $0 == ":" })
                .map { $0.drop(while: \.isLetter) }
            #expect(
                referenced.allSatisfy { !totalRows.contains(String($0)) },
                "a formula reaches a total row: \(formula)"
            )
        }
    }

    @Test("A formula cell still carries the answer, so a reader that does not recalculate is right")
    func formulaCellsCacheTheResult() throws {
        let plainURL = temporaryURL("xlsx")
        let liveURL = temporaryURL("xlsx")
        defer {
            try? FileManager.default.removeItem(at: plainURL)
            try? FileManager.default.removeItem(at: liveURL)
        }
        try export(formulas: false, to: plainURL)
        try export(formulas: true, to: liveURL)

        let plain = try XLSXInspector(url: plainURL)
        let live = try XLSXInspector(url: liveURL)

        // Same grid, same stored values: turning formulas on changes how a total is expressed,
        // never what it says.
        #expect(plain.cells.count == live.cells.count)
        for cell in plain.cells {
            let other = try #require(live.cell(cell.reference))
            #expect(other.value == cell.value, "cell \(cell.reference) changed value")
            #expect(other.type == cell.type)
        }
    }

    @Test("Only Sum becomes a formula; Count and the other aggregates stay computed values")
    func onlySumBecomesAFormula() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try export(formulas: true, to: url)

        let inspector = try XLSXInspector(url: url)
        let written = formulas(in: inspector)
        // The fixture's plan carries a Count over `subject` beside the five Sums. A COUNT written
        // as SUM would be a wrong number that recalculates itself into looking authoritative.
        #expect(!written.contains { $0.contains("COUNT") || $0.contains("AVERAGE") })

        // Five summed columns in each of the two group subtotals, and four in the grand total:
        // the deliberately mixed-dimension column cannot be summed across the whole ledger, so
        // that cell is the refusal token it always was and gets no formula. A `SUM` written over
        // metres and square metres would be the exact wrong number this ledger refuses to give.
        let sumColumns = Set(written.compactMap { formula -> String? in
            guard let open = formula.firstIndex(of: "("),
                  let digit = formula[open...].firstIndex(where: \.isNumber)
            else { return nil }
            return String(formula[formula.index(after: open)..<digit])
        })
        #expect(sumColumns.count == 5)
        #expect(written.count == 14)

        let mixed = try #require(
            inspector.cells.first { $0.row == 11 && $0.reference.hasPrefix("P") }
        )
        #expect(mixed.type != nil, "the mixed-dimension grand total is a token, not a number")
    }

    // MARK: - The range builder

    @Test("A group whose rows are not contiguous sums the runs, never the gap")
    func nonContiguousRangesAreSplit() throws {
        // A parent group's own rows are written before its subgroups', and each subgroup's
        // subtotal sits between them. Summing 2:10 there would sum the subtotals too.
        #expect(XLSXExporter.sumFormula(column: 2, rows: [1, 2, 3]) == "SUM(C2:C4)")
        #expect(XLSXExporter.sumFormula(column: 2, rows: [1, 2, 5, 6]) == "SUM(C2:C3,C6:C7)")
        #expect(XLSXExporter.sumFormula(column: 0, rows: [4]) == "SUM(A5)")
        #expect(XLSXExporter.sumFormula(column: 0, rows: []) == nil)
        // Out of order in, in order out.
        #expect(XLSXExporter.sumFormula(column: 1, rows: [6, 1, 2]) == "SUM(B2:B3,B7)")
    }

    @Test("Column references pass Z")
    func columnLetters() {
        #expect(XLSXExporter.columnReference(0) == "A")
        #expect(XLSXExporter.columnReference(25) == "Z")
        #expect(XLSXExporter.columnReference(26) == "AA")
        #expect(XLSXExporter.columnReference(27) == "AB")
        #expect(XLSXExporter.columnReference(51) == "AZ")
        #expect(XLSXExporter.columnReference(52) == "BA")
        #expect(XLSXExporter.columnReference(701) == "ZZ")
        #expect(XLSXExporter.columnReference(702) == "AAA")
    }
}
