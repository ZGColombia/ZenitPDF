import CXlsxWriter
import Foundation
import Testing
@testable import ZPDFXlsxWriter

/// R-201: the BH-403 C-locale guard covers the constant-memory row flush, which the per-call
/// wrappers missed whenever a row began with a string, a link, a boolean or a blank.
struct Iter1XlsxLocaleTests {

    /// Old output: under a Swedish thread locale, sheet1.xml held `<v>1,5</v>` and `<v>2,25</v>`
    /// — each numeric row was flushed by the *next* row's first cell, a string or a blank, and
    /// neither call ran under the C locale.
    @Test("R-201: numbers flushed by a row that starts with text, a link, a boolean or a blank keep their decimal point")
    func flushUnderTextFirstRows() throws {
        guard let swedish = newlocale(LC_NUMERIC_MASK, "sv_SE.UTF-8", nil) else {
            Issue.record("sv_SE.UTF-8 locale unavailable; cannot exercise R-201")
            return
        }
        defer { freelocale(swedish) }
        let previous = uselocale(swedish)
        defer { uselocale(previous) }
        var probe = [CChar](repeating: 0, count: 16)
        _ = withVaList([1.5]) { vsnprintf(&probe, probe.count, "%.16G", $0) }
        #expect(String(cString: probe) == "1,5", "the locale must really use a decimal comma")

        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url, options: XlsxWorkbookOptions(constantMemory: true)) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            try sheet.writeNumber(row: 0, column: 0, 1.5)
            try sheet.writeString(row: 1, column: 0, "Wall")        // flushes row 0
            try sheet.writeNumber(row: 1, column: 1, 2.25)
            try sheet.writeBlank(row: 2, column: 0)                   // flushes row 1
            try sheet.writeNumber(row: 2, column: 1, 3.125)
            try sheet.writeURL(row: 3, column: 0, url: "zenitpdf://markup/1", text: "Open") // flushes row 2
            try sheet.writeNumber(row: 3, column: 1, 4.5)
            try sheet.writeBoolean(row: 4, column: 0, true)          // flushes row 3
        }
        let xml = try Unzipper.entry("xl/worksheets/sheet1.xml", of: url)
        for value in ["1.5", "2.25", "3.125", "4.5"] {
            #expect(xml.contains("<v>\(value)</v>"), "\(value) missing")
        }
        #expect(!xml.contains("1,5") && !xml.contains("2,25") && !xml.contains("3,125") && !xml.contains("4,5"))
        // The caller's own locale is back afterwards: the scope is the write, nothing more.
        _ = withVaList([1.5]) { vsnprintf(&probe, probe.count, "%.16G", $0) }
        #expect(String(cString: probe) == "1,5")
    }
}
