import Foundation
import Testing
@testable import ZPDFXlsxWriter

/// CR-133. `XlsxWorksheet` held its workbook `unowned`, so a worksheet that escaped the `write`
/// closure and was used afterwards read a dead reference and trapped the whole process instead
/// of throwing the typed ``XlsxError/workbookAlreadyClosed`` that the API promises.
@Suite("Worksheet lifetime")
struct XlsxWorksheetLifetimeTests {

    // Fails on the old code by crashing the test process, not by a failed assertion:
    //   Fatal error: Attempted to read an unowned reference but object 0xc0306c3e0 was already
    //   destroyed
    //   error: Process '…/swiftpm-testing-helper --test-bundle-path …/LibXlsxWriterBridgePackageTests
    //   --filter worksheetOutlivesItsWorkbook … --testing-library swift-testing' exited with
    //   unexpected signal code 6
    @Test("A worksheet kept past write() throws workbookAlreadyClosed instead of trapping")
    func worksheetOutlivesItsWorkbook() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var escaped: XlsxWorksheet?
        try XlsxWriter.write(to: url) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            try sheet.writeString(row: 0, column: 0, "kept")
            escaped = sheet
        }
        // `write` has returned: the workbook is closed, written and released. The sheet must
        // notice on every entry point, before it touches its (now freed) C pointer.
        let sheet = try #require(escaped)
        #expect(throws: XlsxError.workbookAlreadyClosed) {
            try sheet.writeNumber(row: 1, column: 0, 1)
        }
        #expect(throws: XlsxError.workbookAlreadyClosed) {
            try sheet.writeString(row: 1, column: 0, "late")
        }
        #expect(throws: XlsxError.workbookAlreadyClosed) {
            try sheet.setColumnWidth(first: 0, last: 0, width: 10)
        }
        #expect(throws: XlsxError.workbookAlreadyClosed) {
            try sheet.freezePanes(row: 1, column: 0)
        }
        #expect(throws: XlsxError.workbookAlreadyClosed) {
            try sheet.autofilter(firstRow: 0, firstColumn: 0, lastRow: 0, lastColumn: 0)
        }
        // The file written before the escape is still a valid workbook.
        #expect(try Unzipper.entry("xl/worksheets/sheet1.xml", of: url).contains("<c r=\"A1\""))
    }
}
