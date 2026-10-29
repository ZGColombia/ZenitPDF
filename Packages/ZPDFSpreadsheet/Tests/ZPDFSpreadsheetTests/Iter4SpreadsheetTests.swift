import Foundation
import Testing
import ZPDFSpreadsheet

/// Iteration 4: the dense grid's padding is charged against the cell budget (U-099).
@Suite("Iteration 4 — spreadsheet reader", .serialized)
struct Iter4SpreadsheetTests {

    /// `count` rows, each holding one numeric cell in the last column a workbook can have (XFD).
    static func farColumnSheet(rows count: Int) -> String {
        var xml = "<worksheet><sheetData>"
        xml.reserveCapacity(count * 48)
        for row in 1...count {
            xml += "<row r=\"\(row)\"><c r=\"XFD\(row)\"><v>1</v></c></row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    /// Old output: no error. Each row was charged one cell against the 5,000,000 budget while it
    /// padded itself with 16,383 empty `String?` slots, so the reader asked for
    /// 20,000 × 16,384 × 16 bytes ≈ 5 GiB from under a megabyte of XML.
    @Test("U-099: 20,000 rows with one XFD cell each are refused, not padded to 5 GiB", .timeLimit(.minutes(1)))
    func farColumnRowsAreRefused() throws {
        let data = SpreadsheetReaderTests.workbook(sheetXML: Self.farColumnSheet(rows: 20_000), sharedStrings: [])
        #expect(throws: SpreadsheetError.tooManyCells(limit: XLSXWorkbookReader.maximumCells)) {
            _ = try XLSXWorkbookReader(data: data)
        }
    }

    /// Hand-derived boundary. A row holding one XFD cell costs 1 (the cell) + 16,383 (the empty
    /// slots in front of it) = 16,384; consecutive rows skip no row. The fixture's second sheet
    /// costs 1 more (one A1 cell).
    ///   305 rows: 305 × 16,384 + 1 = 4,997,121 ≤ 5,000,000 → read.
    ///   306 rows: 306 × 16,384     = 5,013,504 > 5,000,000 → refused while reading row 306.
    /// Old output for 306 rows: read, with no error.
    @Test("U-099: the padding budget's boundary sits between 305 and 306 far-column rows", .timeLimit(.minutes(1)))
    func paddingBudgetBoundary() throws {
        let fits = try XLSXWorkbookReader(
            data: SpreadsheetReaderTests.workbook(sheetXML: Self.farColumnSheet(rows: 305), sharedStrings: [])
        )
        let ledger = try #require(fits.sheet(named: "Ledger"))
        #expect(ledger.rows.count == 305)
        #expect(ledger.cell(row: 304, column: 16_383) == "1")
        #expect(ledger.cell(row: 304, column: 16_382) == nil)
        #expect(fits.sheet(named: "Zenit")?.cell(row: 0, column: 0) == "Format")

        #expect(throws: SpreadsheetError.tooManyCells(limit: XLSXWorkbookReader.maximumCells)) {
            _ = try XLSXWorkbookReader(
                data: SpreadsheetReaderTests.workbook(sheetXML: Self.farColumnSheet(rows: 306), sharedStrings: [])
            )
        }
    }

    /// Found while writing the test above: the inflater made one `compression_stream_process`
    /// call, and the decoder answers the first call with 393,216 bytes and the rest still inside
    /// it. Old output: `SpreadsheetError.zip(.sizeMismatch(entry: "xl/worksheets/sheet1.xml",
    /// declared: 986728, actual: 393216))` — every sheet part over 384 KiB was refused.
    @Test("A sheet part larger than the decoder's first piece (393,216 bytes) inflates whole")
    func largeSheetInflatesWhole() throws {
        var xml = "<worksheet><sheetData>"
        for row in 1...20_000 {
            xml += "<row r=\"\(row)\"><c r=\"A\(row)\"><v>\(row)</v></c></row>"
        }
        xml += "</sheetData></worksheet>"
        #expect(Data(xml.utf8).count == 986_728, "the fixture must stay past the 393,216-byte first piece")
        let reader = try XLSXWorkbookReader(data: SpreadsheetReaderTests.workbook(sheetXML: xml, sharedStrings: []))
        let ledger = try #require(reader.sheet(named: "Ledger"))
        #expect(ledger.rows.count == 20_000)
        #expect(ledger.cell(row: 0, column: 0) == "1")
        #expect(ledger.cell(row: 9_999, column: 0) == "10000")
        #expect(ledger.cell(row: 19_999, column: 0) == "20000")
    }

    /// U-103: the raw-bytes overload the geometry blob trailer now calls is the same checksum.
    /// Check value from the CRC-32/ISO-HDLC catalogue: "123456789" → 0xCBF43926.
    @Test("U-103: ZipCRC32 over raw bytes, an array slice included, matches the published check value")
    func crc32RawBytes() {
        let bytes = Array("x123456789y".utf8)
        #expect(ZipCRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(bytes[1..<10].withUnsafeBytes { ZipCRC32.checksum($0) } == 0xCBF4_3926)
        #expect(ZipCRC32.checksum(Data()) == 0)
    }

    /// A far-away row is padding too: one value in row 1,048,576 pads 1,048,575 empty rows in
    /// front of it and costs 1,048,576 — well inside the budget, so it still reads.
    @Test("U-099: a lone value in the last row still reads; the skipped rows are charged, not refused")
    func lastRowStillReads() throws {
        let sheet = "<worksheet><sheetData><row r=\"1048576\"><c r=\"B1048576\"><v>7</v></c></row></sheetData></worksheet>"
        let reader = try XLSXWorkbookReader(data: SpreadsheetReaderTests.workbook(sheetXML: sheet, sharedStrings: []))
        let ledger = try #require(reader.sheet(named: "Ledger"))
        #expect(ledger.rows.count == 1_048_576)
        #expect(ledger.cell(row: 1_048_575, column: 1) == "7")
    }
}
