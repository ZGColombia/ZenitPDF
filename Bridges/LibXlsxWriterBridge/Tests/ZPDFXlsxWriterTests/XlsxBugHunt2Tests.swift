import CXlsxWriter
import Foundation
import Testing
@testable import ZPDFXlsxWriter

/// Bug hunt 2 regressions for the XLSX bridge.
@Suite("libxlsxwriter bridge — bug hunt 2")
struct XlsxBugHunt2Tests {

    private func existingFile(_ contents: String) throws -> URL {
        let url = temporaryFile()
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: BH-001 / BH-082 — a failed export must not touch the destination

    /// Old output: `abandon()` ran `workbook_close`, which truncated `url` and wrote a partial
    /// workbook into it, and the catch block then unlinked it — the file was gone
    /// (`fileExists == false`) and its previous bytes lost.
    @Test("BH-001: a body that throws after the workbook exists leaves the previous file byte-identical")
    func failedExportKeepsPreviousFile() throws {
        struct Boom: Error {}
        let url = try existingFile("previous export — must survive")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        #expect(throws: Boom.self) {
            try XlsxWriter.write(to: url) { workbook in
                let sheet = try workbook.addWorksheet(name: "S")
                try sheet.writeNumber(row: 0, column: 0, 1)
                throw Boom()
            }
        }
        #expect(try Data(contentsOf: url) == before)
    }

    /// Old output: a duplicate sheet name threw `worksheetCreationFailed`, and the destination
    /// that existed before the export was deleted.
    @Test("BH-082: a library-level failure does not delete a pre-existing file")
    func libraryFailureKeepsPreviousFile() throws {
        let url = try existingFile("an unrelated file of the same name")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)
        #expect(throws: XlsxError.self) {
            try XlsxWriter.write(to: url) { workbook in
                _ = try workbook.addWorksheet(name: "Same")
                _ = try workbook.addWorksheet(name: "Same")
            }
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("BH-001/082: a successful export replaces an existing file with the workbook")
    func successfulExportReplaces() throws {
        let url = try existingFile("old")
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            try sheet.writeNumber(row: 0, column: 0, 7)
        }
        #expect(try Unzipper.entry("xl/worksheets/sheet1.xml", of: url).contains("<v>7</v>"))
    }

    @Test("BH-001: a failed export into a fresh path leaves nothing behind, staging included")
    func failedExportLeavesNoStaging() throws {
        struct Boom: Error {}
        let url = temporaryFile()
        #expect(throws: Boom.self) {
            try XlsxWriter.write(to: url) { _ in throw Boom() }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    // MARK: BH-081 — non-finite numbers

    /// Old output: the export succeeded and sheet1.xml contained `<v>NAN</v>` / `<v>INF</v>`.
    @Test("BH-081: NaN and infinity are refused by writeNumber and writeFormula", arguments: [
        Double.nan, .infinity, -.infinity,
    ])
    func nonFiniteNumbersThrow(_ value: Double) throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: XlsxError.nonFiniteNumber(row: 0, column: 0)) {
            try XlsxWriter.write(to: url) { workbook in
                try workbook.addWorksheet(name: "S").writeNumber(row: 0, column: 0, value)
            }
        }
        #expect(throws: XlsxError.nonFiniteNumber(row: 1, column: 2)) {
            try XlsxWriter.write(to: url) { workbook in
                try workbook.addWorksheet(name: "S").writeFormula(row: 1, column: 2, "=1/0", result: value)
            }
        }
    }

    // MARK: BH-400 — library error names

    /// Old output: `name == "lxw_error(rawValue: 20)"`.
    @Test("BH-400: libraryError carries the symbolic lxw_error name")
    func libraryErrorName() {
        #expect(lxwErrorName(LXW_ERROR_SHEETNAME_ALREADY_USED) == "LXW_ERROR_SHEETNAME_ALREADY_USED")
        #expect(lxwErrorName(LXW_ERROR_MAX_STRING_LENGTH_EXCEEDED) == "LXW_ERROR_MAX_STRING_LENGTH_EXCEEDED")
        do {
            try check(LXW_ERROR_PARAMETER_VALIDATION)
            Issue.record("check() did not throw")
        } catch let XlsxError.libraryError(_, name, _) {
            #expect(name == "LXW_ERROR_PARAMETER_VALIDATION")
            #expect(!name.contains("rawValue"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: BH-401 — black is not the UNSET sentinel

    /// Old output: styles.xml had a `<patternFill patternType="solid"/>` with no fgColor and the
    /// font used the theme colour; `FF000000` never appeared.
    @Test("BH-401: XlsxColor.black is written as explicit black")
    func blackIsBlack() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            let style = try workbook.format(XlsxFormatSpec(fontColor: .black, backgroundColor: .black))
            try sheet.writeString(row: 0, column: 0, "x", format: style)
        }
        let styles = try Unzipper.entry("xl/styles.xml", of: url)
        #expect(styles.contains("<color rgb=\"FF000000\"/>"))
        #expect(styles.contains("<fgColor rgb=\"FF000000\"/>"))
    }

    // MARK: BH-402 — vertical alignment

    /// Old output: `<alignment horizontal="center"/>` — left was overwritten, no vertical set.
    @Test("BH-402: verticalAlignment .center centres vertically and keeps the horizontal alignment")
    func verticalCenter() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            let style = try workbook.format(XlsxFormatSpec(alignment: .left, verticalAlignment: .center))
            try sheet.writeString(row: 0, column: 0, "x", format: style)
        }
        let styles = try Unzipper.entry("xl/styles.xml", of: url)
        #expect(styles.contains("horizontal=\"left\""))
        #expect(styles.contains("vertical=\"center\""))
        #expect(!styles.contains("horizontal=\"center\""))
    }

    // MARK: BH-403 — numeric locale

    /// Old output: under a Swedish thread locale sheet1.xml held `<v>1,5</v>`.
    @Test("BH-403: numbers are written with a decimal point under a comma-decimal locale",
          arguments: [false, true])
    func numbersIgnoreThreadLocale(constantMemory: Bool) throws {
        guard let swedish = newlocale(LC_NUMERIC_MASK, "sv_SE.UTF-8", nil) else {
            Issue.record("sv_SE.UTF-8 locale unavailable; cannot exercise BH-403")
            return
        }
        defer { freelocale(swedish) }
        var probe = [CChar](repeating: 0, count: 16)
        let previous = uselocale(swedish)
        defer { uselocale(previous) }
        _ = withVaList([1.5]) { vsnprintf(&probe, probe.count, "%.16G", $0) }
        #expect(String(cString: probe) == "1,5", "the locale must really use a decimal comma")

        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url, options: XlsxWorkbookOptions(constantMemory: constantMemory)) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            try sheet.writeNumber(row: 0, column: 0, 1.5)
            try sheet.writeFormula(row: 1, column: 0, "=A1*2", result: 3.25)
            try sheet.writeNumber(row: 2, column: 0, 0)
        }
        let xml = try Unzipper.entry("xl/worksheets/sheet1.xml", of: url)
        #expect(xml.contains("<v>1.5</v>"))
        #expect(xml.contains("<v>3.25</v>"))
        #expect(!xml.contains("1,5"))
    }

    // MARK: BH-404 — dates

    /// Old output: `Int64(1e300)` — a Swift runtime trap, the process died.
    @Test("BH-404: a date outside Int64 Unix time throws instead of trapping")
    func hugeDateThrows() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        for date in [Date(timeIntervalSince1970: 1e300), Date(timeIntervalSince1970: .infinity),
                     Date(timeIntervalSince1970: .nan)] {
            #expect(throws: XlsxError.dateOutOfRange(row: 0, column: 0)) {
                try XlsxWriter.write(to: url) { workbook in
                    try workbook.addWorksheet(name: "S").writeDate(row: 0, column: 0, date)
                }
            }
        }
    }

    // MARK: BH-405 — unchecked column/row conversions

    /// Old output: `lxw_col_t(-1)` / `lxw_col_t(20000)` trapped with "Negative value is not
    /// representable" / "Not enough bits".
    @Test("BH-405: setColumnWidth, freezePanes and autofilter throw cellOutOfRange")
    func uncheckedConversionsThrow() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let cases: [(XlsxWorksheet) throws -> Void] = [
            { try $0.setColumnWidth(first: -1, last: 0, width: 10) },
            { try $0.setColumnWidth(first: 0, last: 70_000, width: 10) },
            { try $0.freezePanes(row: XlsxLimits.maximumRows + 1, column: 0) },
            { try $0.freezePanes(row: 0, column: -1) },
            { try $0.autofilter(firstRow: 0, firstColumn: 0, lastRow: 3, lastColumn: -1) },
            { try $0.autofilter(firstRow: -1, firstColumn: 0, lastRow: 3, lastColumn: 1) },
        ]
        for body in cases {
            do {
                try XlsxWriter.write(to: url) { workbook in try body(try workbook.addWorksheet(name: "S")) }
                Issue.record("expected cellOutOfRange")
            } catch XlsxError.cellOutOfRange {
                // expected
            }
        }
    }
}

/// IM-063: outline levels for grouped ledger rows.
@Suite("libxlsxwriter bridge — row options (IM-063)")
struct XlsxRowOptionsTests {

    @Test("setRowOptions writes outline level, hidden and collapsed",
          arguments: [false, true])
    func rowOptionsReachTheSheet(constantMemory: Bool) throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url, options: XlsxWorkbookOptions(constantMemory: constantMemory)) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            try sheet.setRowOptions(0, level: 2)
            try sheet.writeNumber(row: 0, column: 0, 1)
            try sheet.setRowOptions(1, hidden: true, level: 9)   // clamped to 7
            try sheet.writeNumber(row: 1, column: 0, 2)
            try sheet.setRowOptions(2, height: 20, collapsed: true)
            try sheet.writeNumber(row: 2, column: 0, 3)
        }
        let xml = try Unzipper.entry("xl/worksheets/sheet1.xml", of: url)
        #expect(xml.contains("outlineLevel=\"2\""))
        #expect(xml.contains("outlineLevel=\"7\""))
        #expect(xml.contains("hidden=\"1\""))
        #expect(xml.contains("collapsed=\"1\""))
    }

    @Test("setRowOptions refuses rows outside the grid and non-finite heights")
    func rowOptionsValidate() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: XlsxError.cellOutOfRange(row: -1, column: 0)) {
            try XlsxWriter.write(to: url) { try $0.addWorksheet(name: "S").setRowOptions(-1, level: 1) }
        }
        #expect(throws: XlsxError.nonFiniteNumber(row: 0, column: 0)) {
            try XlsxWriter.write(to: url) { try $0.addWorksheet(name: "S").setRowOptions(0, height: .nan) }
        }
    }
}
