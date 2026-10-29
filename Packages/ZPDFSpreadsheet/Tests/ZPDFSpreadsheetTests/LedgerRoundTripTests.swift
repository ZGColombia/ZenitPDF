import Foundation
import Testing
@testable import ZPDFSpreadsheet

/// NL-PLAT-07 acceptance, at the review: change 3 unit costs and 1 cost code in the sheet, and the
/// review lists exactly those 4 cells; an edited measured quantity is refused and named.
@Suite("Ledger round trip review — NL-PLAT-07")
struct LedgerRoundTripTests {

    static func inline(_ ref: String, _ text: String) -> String {
        "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
    }
    static func number(_ ref: String, _ literal: String) -> String { "<c r=\"\(ref)\"><v>\(literal)</v></c>" }

    /// Header: Record | Subject | Cost Code | Plan Area (m²) | Unit Cost (SEK) | Row ID
    static func workbook(rows: [[String]], project: String = "P-1") -> Data {
        var xml = "<worksheet><sheetData><row r=\"1\">"
            + ["Record", "Subject", "Cost Code", "Plan Area (m²)", "Unit Cost (SEK)", "Row ID"].enumerated()
                .map { inline("\(["A", "B", "C", "D", "E", "F"][$0.offset])1", $0.element) }.joined()
            + "</row>"
        for (index, row) in rows.enumerated() {
            let r = index + 2
            xml += "<row r=\"\(r)\">" + inline("A\(r)", "Row") + inline("B\(r)", row[0]) + inline("C\(r)", row[1])
                + number("D\(r)", row[2]) + number("E\(r)", row[3]) + inline("F\(r)", row[4]) + "</row>"
        }
        xml += "</sheetData></worksheet>"
        let meta = "<worksheet><sheetData>"
            + [("Format", "zenit.ledger.roundtrip"), ("Version", "1"), ("Project", project), ("Exported", "2026-09-23T12:00:00Z"),
               ("Sheet", "Ledger"), ("Row ID column", "Row ID")].enumerated()
                .map { "<row r=\"\($0.offset + 1)\">" + inline("A\($0.offset + 1)", $0.element.0) + inline("B\($0.offset + 1)", $0.element.1) + "</row>" }.joined()
            + "<row r=\"8\">" + inline("A8", "Column") + inline("B8", "Key") + inline("C8", "Brought back") + "</row>"
            + [("Subject", "subject", "editable"), ("Cost Code", "costCode", "editable"), ("Plan Area (m²)", "planArea", "read-only"), ("Unit Cost (SEK)", "unitCost", "editable")]
                .enumerated().map { "<row r=\"\($0.offset + 9)\">" + inline("A\($0.offset + 9)", $0.element.0) + inline("B\($0.offset + 9)", $0.element.1) + inline("C\($0.offset + 9)", $0.element.2) + "</row>" }.joined()
            + "</sheetData></worksheet>"
        return SpreadsheetReaderTests.zip([
            .init(name: "xl/workbook.xml", data: Data("""
            <workbook xmlns:r="r"><sheets><sheet name="Ledger" sheetId="1" r:id="rId1"/><sheet name="Zenit" sheetId="2" r:id="rId2"/></sheets></workbook>
            """.utf8)),
            .init(name: "xl/_rels/workbook.xml.rels", data: Data("""
            <Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="worksheets/sheet2.xml"/></Relationships>
            """.utf8)),
            .init(name: "xl/worksheets/sheet1.xml", data: Data(xml.utf8)),
            .init(name: "xl/worksheets/sheet2.xml", data: Data(meta.utf8)),
        ])
    }

    static let current: [String: [String: RoundTripValue]] = [
        "m1": ["subject": .text("Slab"), "costCode": .text("21.1"), "planArea": .number(12.5), "unitCost": .number(100)],
        "m2": ["subject": .text("Slab"), "costCode": .text("21.1"), "planArea": .number(0.1 + 0.2), "unitCost": .number(100)],
        "m3": ["subject": .text("Wall"), "costCode": .text("22.4"), "planArea": .number(7), "unitCost": .number(80)],
        "m4": ["subject": .text("Wall"), "costCode": .text("22.4"), "planArea": .number(3), "unitCost": .empty],
    ]

    @Test("Three unit costs and one cost code changed: exactly those four cells, in file order")
    func fourCells() throws {
        let data = Self.workbook(rows: [
            ["Slab", "21.1", "12.5", "112.5", "m1"],                    // unit cost changed
            ["Slab", "21.9", "0.30000000000000004", "100", "m2"],       // cost code changed
            ["Wall", "22.4", "7", "85.25", "m3"],                       // unit cost changed
            ["Wall", "22.4", "3", "60", "m4"],                          // unit cost set from empty
        ])
        let workbook = try LedgerRoundTripWorkbook(data: data)
        let review = LedgerRoundTrip.review(workbook, current: Self.current, numericKeys: ["planArea", "unitCost"], projectID: "P-1")
        #expect(review.changes.map { "\($0.markupID).\($0.key)=\($0.after)" }
                == ["m1.unitCost=112.5", "m2.costCode=21.9", "m3.unitCost=85.25", "m4.unitCost=60"])
        #expect(review.refusals.isEmpty)
        #expect(review.onlyInFile.isEmpty && review.onlyInLedger.isEmpty)
        #expect(!review.fromAnotherProject)
        #expect(LedgerRoundTrip.decimal("85.25") == Decimal(string: "85.25"))
    }

    @Test("An edited measured quantity is refused, naming the row and the column; text in a money column too")
    func quantityEditRefused() throws {
        let data = Self.workbook(rows: [
            ["Slab", "21.1", "99", "100", "m1"],       // plan area typed over: refused
            ["Slab", "21.1", "0.3", "about 90", "m2"], // 16-digit rounding is not an edit; text in money is refused
        ])
        let review = LedgerRoundTrip.review(try LedgerRoundTripWorkbook(data: data), current: Self.current,
                                            numericKeys: ["planArea", "unitCost"], projectID: "P-1")
        #expect(review.changes.isEmpty)
        #expect(review.refusals.map(\.markupID) == ["m1", "m2"])
        #expect(review.refusals[0].header == "Plan Area (m²)" && review.refusals[0].reason == .readOnlyColumn)
        #expect(review.refusals[1].header == "Unit Cost (SEK)" && review.refusals[1].reason == .notANumber)
        #expect(review.onlyInLedger == ["m3", "m4"])
    }

    @Test("A workbook from another project is flagged; rows the ledger no longer has are listed; a lost Row ID column is refused")
    func identityChecks() throws {
        let other = try LedgerRoundTripWorkbook(data: Self.workbook(rows: [["Slab", "21.1", "12.5", "100", "gone"]], project: "P-2"))
        let review = LedgerRoundTrip.review(other, current: Self.current, numericKeys: ["planArea", "unitCost"], projectID: "P-1")
        #expect(review.fromAnotherProject)
        #expect(review.onlyInFile == ["gone"])
        let duplicate = Self.workbook(rows: [["Slab", "21.1", "12.5", "100", "m1"], ["Slab", "21.1", "12.5", "100", "m1"]])
        #expect(throws: LedgerRoundTripWorkbook.ReadError.duplicateRow("m1")) { try LedgerRoundTripWorkbook(data: duplicate) }
        let plain = SpreadsheetReaderTests.workbook(sheetXML: "<worksheet><sheetData/></worksheet>", sharedStrings: [])
        #expect(throws: LedgerRoundTripWorkbook.ReadError.notARoundTripWorkbook) { try LedgerRoundTripWorkbook(data: plain) }
    }
}
