import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// Page label versus page index.
///
/// The distinction is the whole point: a construction set's sheets are called `A-101`,
/// and the estimator who is told "page 3" and means "sheet A-103" has been given the
/// wrong answer. Every test here is pure arithmetic; no PDF is involved.
@Suite("Page labels")
struct PageLabelTests {

    @Test("Decimal numbering starts at one, not at the index")
    func decimalNumbering() {
        let table = PageLabelTable(pageCount: 5, ranges: [], isExplicit: false)
        #expect(table.allLabels() == ["1", "2", "3", "4", "5"])
        #expect(table.label(forPageIndex: 0) == "1")
        #expect(table.pageIndex(forLabel: "1") == 0)
        #expect(table.pageIndex(forLabel: "0") == nil)
        #expect(table.isExplicit == false)
    }

    @Test("An A-series sheet set labels index 0 as A-101")
    func architecturalSheetSet() {
        let table = PageLabelTable(
            pageCount: 4,
            ranges: [PageLabelRange(startPageIndex: 0, style: .decimal, prefix: "A-", firstNumber: 101)],
            isExplicit: true
        )
        #expect(table.allLabels() == ["A-101", "A-102", "A-103", "A-104"])
        #expect(table.pageIndex(forLabel: "A-102") == 1)
        // The bug this test exists to catch.
        #expect(table.label(forPageIndex: 1) != "2")
        #expect(table.isExplicit)
    }

    @Test("Several ranges partition the document")
    func multipleRanges() {
        let table = PageLabelTable(
            pageCount: 7,
            ranges: [
                PageLabelRange(startPageIndex: 0, style: .lowercaseRoman),
                PageLabelRange(startPageIndex: 2, style: .decimal, prefix: "A-", firstNumber: 101),
                PageLabelRange(startPageIndex: 5, style: .decimal, prefix: "S-", firstNumber: 1)
            ],
            isExplicit: true
        )
        #expect(table.allLabels() == ["i", "ii", "A-101", "A-102", "A-103", "S-1", "S-2"])
        #expect(table.pageIndex(forLabel: "S-2") == 6)
    }

    @Test("A range with a prefix and no style is the prefix alone")
    func prefixOnlyRange() {
        let table = PageLabelTable(
            pageCount: 3,
            ranges: [PageLabelRange(startPageIndex: 0, style: nil, prefix: "COVER")],
            isExplicit: true
        )
        #expect(table.allLabels() == ["COVER", "COVER", "COVER"])
        // Labels are not unique, and the first match wins.
        #expect(table.pageIndex(forLabel: "COVER") == 0)
    }

    @Test("A first range that does not start at page zero gets a decimal one prepended")
    func normalisation() {
        let table = PageLabelTable(
            pageCount: 4,
            ranges: [PageLabelRange(startPageIndex: 2, style: .uppercaseRoman)],
            isExplicit: true
        )
        #expect(table.allLabels() == ["1", "2", "I", "II"])
        #expect(table.ranges.first?.startPageIndex == 0)
    }

    @Test("Ranges are sorted and deduplicated, and ones past the end are dropped")
    func outOfOrderRanges() {
        let table = PageLabelTable(
            pageCount: 3,
            ranges: [
                PageLabelRange(startPageIndex: 2, style: .decimal, firstNumber: 50),
                PageLabelRange(startPageIndex: 0, style: .decimal),
                PageLabelRange(startPageIndex: 2, style: .decimal, firstNumber: 99),
                PageLabelRange(startPageIndex: 900, style: .decimal)
            ],
            isExplicit: true
        )
        #expect(table.ranges.map(\.startPageIndex) == [0, 2])
        #expect(table.allLabels() == ["1", "2", "50"])
    }

    @Test("Out-of-range indices return nil rather than a fabricated label")
    func outOfRange() {
        let table = PageLabelTable(pageCount: 2, ranges: [], isExplicit: false)
        #expect(table.label(forPageIndex: -1) == nil)
        #expect(table.label(forPageIndex: 2) == nil)
        #expect(PageLabelTable(pageCount: 0, ranges: [], isExplicit: false).allLabels().isEmpty)
    }

    @Test(
        "Roman numerals",
        arguments: [
            (1, "i"), (2, "ii"), (3, "iii"), (4, "iv"), (9, "ix"), (14, "xiv"),
            (40, "xl"), (90, "xc"), (400, "cd"), (1987, "mcmlxxxvii"), (3999, "mmmcmxcix")
        ]
    )
    func romanNumbering(ordinal: Int, expected: String) {
        #expect(PageLabelNumbering.string(ordinal, style: .lowercaseRoman) == expected)
        #expect(PageLabelNumbering.string(ordinal, style: .uppercaseRoman) == expected.uppercased())
    }

    @Test(
        "Letter numbering repeats the letter, as the PDF specification requires",
        arguments: [(1, "A"), (26, "Z"), (27, "AA"), (28, "BB"), (52, "ZZ"), (53, "AAA")]
    )
    func letterNumbering(ordinal: Int, expected: String) {
        // Not spreadsheet columns: 27 is AA, not AB.
        #expect(PageLabelNumbering.string(ordinal, style: .uppercaseLetters) == expected)
        #expect(PageLabelNumbering.string(ordinal, style: .lowercaseLetters) == expected.lowercased())
    }

    @Test("An absurd start number falls back to decimal instead of allocating")
    func hostileStartNumber() {
        let label = PageLabelNumbering.string(2_000_000_000, style: .uppercaseLetters)
        #expect(label == "2000000000")
        #expect(label.count < 20)
        let roman = PageLabelNumbering.string(2_000_000_000, style: .uppercaseRoman)
        #expect(roman == "2000000000")
    }

    @Test("A /St below one is clamped, because the specification forbids it")
    func startNumberClamping() {
        let range = PageLabelRange(startPageIndex: -5, style: .decimal, firstNumber: -3)
        #expect(range.firstNumber == 1)
        #expect(range.startPageIndex == 0)
    }

    @Test("Twenty thousand ranges resolve in constant time per lookup")
    func manyRanges() {
        let ranges = (0..<20_000).map {
            PageLabelRange(startPageIndex: $0, style: .decimal, prefix: "P", firstNumber: $0 + 1)
        }
        let table = PageLabelTable(pageCount: 20_000, ranges: ranges, isExplicit: true)
        #expect(table.label(forPageIndex: 0) == "P1")
        #expect(table.label(forPageIndex: 19_999) == "P20000")
        #expect(table.label(forPageIndex: 12_345) == "P12346")
    }
}
