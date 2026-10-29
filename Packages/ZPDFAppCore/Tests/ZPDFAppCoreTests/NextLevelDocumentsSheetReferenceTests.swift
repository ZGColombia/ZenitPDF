import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts

/// NL-DOCS-10: sheet references found, linked by identity, unresolved ones listed.
struct NextLevelDocumentsSheetReferenceTests {

    @Test("SEE S-201 and 3/A-501 link; the sheet's own number does not; A-999 is unresolved; ROOM 12 is nothing")
    func scan() {
        let a101 = PageID(UUID()), a501 = PageID(UUID()), s201 = PageID(UUID())
        let lines: [PageID: [SheetReferenceLinker.TextLine]] = [
            a101: [
                .init(text: "SEE S-201", bounds: PDFRect(x: 200, y: 2200, width: 90, height: 12)),
                .init(text: "3/A-501 DETAIL", bounds: PDFRect(x: 400, y: 900, width: 140, height: 12)),
                .init(text: "A-101", bounds: PDFRect(x: 2400, y: 100, width: 50, height: 20)),
                .init(text: "REFER A-999", bounds: PDFRect(x: 100, y: 100, width: 110, height: 12)),
                .init(text: "ROOM 12", bounds: PDFRect(x: 100, y: 300, width: 70, height: 12))
            ]
        ]
        let result = SheetReferenceLinker.scan(sheets: [a101: "A-101", a501: "A-501", s201: "S-201"], lines: lines)
        #expect(result.proposals.map(\.text).sorted() == ["3/A-501", "S-201"])
        let see = try? #require(result.proposals.first { $0.text == "S-201" })
        #expect(see?.target == s201)
        // "S-201" is characters 4..<9 of 9 over 90 pt from x = 200: x 240, width 50 (hand-derived).
        #expect(see?.bounds == PDFRect(x: 240, y: 2200, width: 50, height: 12))
        #expect(result.proposals.first { $0.text == "3/A-501" }?.target == a501)
        #expect(result.unresolved.map(\.text) == ["A-999"])
    }

    @Test("A proposal becomes a hyperlink markup over its words, targeting the sheet by identity")
    func markups() {
        let page = PageID(UUID()), target = PageID(UUID())
        let proposal = SheetReferenceLinker.Proposal(
            page: page, bounds: PDFRect(x: 240, y: 2200, width: 50, height: 12),
            text: "S-201", target: target, targetNumber: "S-201"
        )
        let record = SheetReferenceLinker.markups(for: [proposal], documentID: DocumentID(UUID()), now: Date(timeIntervalSince1970: 0))[0]
        #expect(record.kind == ZPDFContracts.MarkupKind.hyperlink)
        #expect(record.link?.pageID == target)
        #expect(record.geometry?.points == [PDFPoint(x: 240, y: 2200), PDFPoint(x: 290, y: 2212)])
    }
}
