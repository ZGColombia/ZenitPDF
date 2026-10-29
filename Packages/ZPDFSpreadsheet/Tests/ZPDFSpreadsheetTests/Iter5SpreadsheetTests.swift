import Foundation
import Testing
import ZPDFSpreadsheet

/// Iteration 5: every archive entry is inflated at most once, the sheet count and the
/// shared-string table have budgets of their own, and a part over budget stops parsing (V-089).
@Suite("Iteration 5 — spreadsheet reader", .serialized)
struct Iter5SpreadsheetTests {

    typealias Entry = SpreadsheetReaderTests.FixtureEntry

    /// A workbook whose `<sheet>` elements are `sheets` (name, relationship id), whose
    /// relationships are `relationships` (id, target), with the given extra entries.
    static func workbook(
        sheets: [(String, String)], relationships: [(String, String)], entries: [Entry]
    ) -> Data {
        let sheetXML = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(sheet.0)\" sheetId=\"\(index + 1)\" r:id=\"\(sheet.1)\"/>"
        }.joined()
        let relationshipXML = relationships.map {
            "<Relationship Id=\"\($0.0)\" Type=\"worksheet\" Target=\"\($0.1)\"/>"
        }.joined()
        return SpreadsheetReaderTests.zip([
            Entry(name: "[Content_Types].xml", data: Data("<Types/>".utf8)),
            Entry(name: "xl/workbook.xml", data: Data("""
            <?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetXML)</sheets></workbook>
            """.utf8)),
            Entry(name: "xl/_rels/workbook.xml.rels", data: Data("""
            <?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationshipXML)</Relationships>
            """.utf8)),
        ] + entries)
    }

    static let oneCellSheet = Data(
        "<worksheet><sheetData><row r=\"1\"><c r=\"A1\"><v>7</v></c></row></sheetData></worksheet>".utf8
    )

    // MARK: - One inflate per entry

    /// Old output: read, with three sheets — `xl/worksheets/sheet1.xml` inflated, CRC-checked
    /// and parsed three times, while the archive's byte budget had charged it once.
    @Test("V-089: sheets that share a target are refused, not inflated once per sheet")
    func sharedTargetIsRefused() {
        let bySameID = Self.workbook(
            sheets: [("A", "rId1"), ("B", "rId1"), ("C", "rId1")],
            relationships: [("rId1", "worksheets/sheet1.xml")],
            entries: [Entry(name: "xl/worksheets/sheet1.xml", data: Self.oneCellSheet)]
        )
        #expect(throws: SpreadsheetError.partReferencedTwice(part: "xl/worksheets/sheet1.xml")) {
            _ = try XLSXWorkbookReader(data: bySameID)
        }
        // Two relationships, one relative and one absolute, that name the same entry.
        let byTwoIDs = Self.workbook(
            sheets: [("A", "rId1"), ("B", "rId2")],
            relationships: [("rId1", "worksheets/sheet1.xml"), ("rId2", "/xl/worksheets/sheet1.xml")],
            entries: [Entry(name: "xl/worksheets/sheet1.xml", data: Self.oneCellSheet)]
        )
        #expect(throws: SpreadsheetError.partReferencedTwice(part: "xl/worksheets/sheet1.xml")) {
            _ = try XLSXWorkbookReader(data: byTwoIDs)
        }
        // A sheet pointing at the workbook's own part is the same second inflate.
        let atTheWorkbook = Self.workbook(
            sheets: [("A", "rId1")], relationships: [("rId1", "workbook.xml")], entries: []
        )
        #expect(throws: SpreadsheetError.partReferencedTwice(part: "xl/workbook.xml")) {
            _ = try XLSXWorkbookReader(data: atTheWorkbook)
        }
    }

    /// Old output for 257 sheets: read, with no cap on how many parts one workbook may name.
    @Test("V-089: the sheet count is capped at 256")
    func sheetCountIsCapped() throws {
        func workbook(sheetCount: Int) -> Data {
            Self.workbook(
                sheets: (1...sheetCount).map { ("S\($0)", "rId\($0)") },
                relationships: (1...sheetCount).map { ("rId\($0)", "worksheets/sheet\($0).xml") },
                entries: (1...sheetCount).map { Entry(name: "xl/worksheets/sheet\($0).xml", data: Self.oneCellSheet) }
            )
        }
        let atTheCap = try XLSXWorkbookReader(data: workbook(sheetCount: 256))
        #expect(atTheCap.sheets.count == 256)
        #expect(atTheCap.sheet(named: "S256")?.cell(row: 0, column: 0) == "7")
        #expect(throws: SpreadsheetError.tooManySheets(count: 257, limit: 256)) {
            _ = try XLSXWorkbookReader(data: workbook(sheetCount: 257))
        }
    }

    // MARK: - The shared-string table

    /// Old output: read, with 5,000,001 empty strings in memory — the table had no budget, and
    /// about 53 million `<si/>` fit in one 256 MiB part.
    @Test("V-089: a shared-string table past 5,000,000 entries is refused", .timeLimit(.minutes(2)))
    func sharedStringsAreCapped() {
        let limit = XLSXWorkbookReader.maximumSharedStrings
        #expect(limit == 5_000_000)
        let table = "<sst>" + String(repeating: "<si/>", count: limit + 1) + "</sst>"
        let data = Self.workbook(
            sheets: [("A", "rId1")],
            relationships: [("rId1", "worksheets/sheet1.xml")],
            entries: [
                // Stored: 25 MB of one repeated element would read as a zip bomb if deflated.
                Entry(name: "xl/sharedStrings.xml", data: Data(table.utf8), deflate: false),
                Entry(name: "xl/worksheets/sheet1.xml", data: Self.oneCellSheet),
            ]
        )
        #expect(throws: SpreadsheetError.tooManySharedStrings(limit: limit)) {
            _ = try XLSXWorkbookReader(data: data)
        }
    }

    @Test("V-089: shared strings under the budget still resolve, rich-text runs joined")
    func sharedStringsUnderTheBudgetResolve() throws {
        let table = "<sst><si><t>Wall</t></si><si><r><t>Slab </t></r><r><t>edge</t></r></si></sst>"
        let sheet = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>1</v></c><c r=\"B1\" t=\"s\"><v>0</v></c></row></sheetData></worksheet>"
        let reader = try XLSXWorkbookReader(data: Self.workbook(
            sheets: [("A", "rId1")],
            relationships: [("rId1", "worksheets/sheet1.xml")],
            entries: [
                Entry(name: "xl/sharedStrings.xml", data: Data(table.utf8)),
                Entry(name: "xl/worksheets/sheet1.xml", data: Data(sheet.utf8)),
            ]
        ))
        #expect(reader.sheets.first?.rows == [["Slab edge", "Wall"]])
    }

    // MARK: - A part over budget stops

    /// The sheet runs over the cell budget at row 306 (U-099's hand-derived boundary: 306 ×
    /// 16,384 = 5,013,504 > 5,000,000) and is broken XML after that. Stopping at the budget
    /// never reaches the break.
    /// Old output: `SpreadsheetError.malformedXML(part: "xl/worksheets/sheet1.xml")` — the
    /// parser kept reading to the end after the budget ran out.
    @Test("V-089: a sheet over the cell budget stops parsing there", .timeLimit(.minutes(1)))
    func overBudgetSheetStopsParsing() {
        let wellFormed = Iter4SpreadsheetTests.farColumnSheet(rows: 400)
        let broken = String(wellFormed.dropLast("</sheetData></worksheet>".count)) + "<row r=\"401\"><c r=\"A401\">"
        let data = SpreadsheetReaderTests.workbook(sheetXML: broken, sharedStrings: [])
        #expect(throws: SpreadsheetError.tooManyCells(limit: XLSXWorkbookReader.maximumCells)) {
            _ = try XLSXWorkbookReader(data: data)
        }
        // The same break inside the budget is still reported as the damage it is.
        let small = String(Iter4SpreadsheetTests.farColumnSheet(rows: 3).dropLast("</sheetData></worksheet>".count))
            + "<row r=\"4\"><c r=\"A4\">"
        #expect(throws: SpreadsheetError.malformedXML(part: "xl/worksheets/sheet1.xml")) {
            _ = try XLSXWorkbookReader(data: SpreadsheetReaderTests.workbook(sheetXML: small, sharedStrings: []))
        }
    }
}
