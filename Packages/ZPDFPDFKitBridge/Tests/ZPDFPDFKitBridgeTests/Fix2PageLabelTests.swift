import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// Regression tests for the page-label findings of bug hunt 2 (BH-027, BH-178, BH-169, BH-569).
@Suite("Fix 2 — page labels")
struct Fix2PageLabelTests {

    // MARK: - BH-027 / BH-178

    @Test("BH-027/BH-178: a saturated /St labels the next page instead of trapping")
    func saturatedStartNumberDoesNotTrap() {
        let table = PageLabelTable(
            pageCount: 3,
            ranges: [PageLabelRange(startPageIndex: 0, style: .decimal, prefix: "S-", firstNumber: Int.max)],
            isExplicit: true
        )
        // Old code: `range.firstNumber + 1` overflowed — a Swift arithmetic trap, which killed
        // the process during `pageDescriptors` on open.
        #expect(table.label(forPageIndex: 0) == "S-9223372036854775807")
        #expect(table.label(forPageIndex: 1) == "S-9223372036854775808")
        #expect(table.label(forPageIndex: 2) == "S-9223372036854775809")
        #expect(table.allLabels().count == 3)
        #expect(table.pageIndex(forLabel: "S-9223372036854775809") == 2)
        let letters = PageLabelTable(
            pageCount: 2,
            ranges: [PageLabelRange(startPageIndex: 0, style: .uppercaseLetters, firstNumber: Int.max)],
            isExplicit: true
        )
        #expect(letters.label(forPageIndex: 1) == "9223372036854775808")
    }

    @Test("BH-027/BH-178: a hostile /St 9223372036854775807 PDF opens and labels every page")
    func hostileStartNumberDocumentOpens() async throws {
        let url = try HandBuiltPDF.pages(
            3,
            catalogExtra: "/PageLabels << /Nums [0 << /S /D /St 9223372036854775807 >>] >>",
            label: "saturated-st"
        )
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let descriptors = try await provider.pageDescriptors(of: opened.handle)
        #expect(descriptors.count == 3)
        #expect(descriptors.allSatisfy { !$0.label.isEmpty })
        await provider.close(opened.handle)
    }

    // MARK: - BH-169

    @Test("BH-169: letter labels are bounded in length, so a hostile /St cannot allocate")
    func letterLabelsAreBounded() {
        // Old code: ordinal 980 001 as /S /A was "Q" repeated 37 693 times.
        let label = PageLabelNumbering.string(980_001, style: .uppercaseLetters)
        #expect(label == "980001")
        #expect(PageLabelNumbering.string(26 * 64, style: .uppercaseLetters).count == 64)
        #expect(PageLabelNumbering.string(26 * 64 + 1, style: .uppercaseLetters) == "1665")
        // Roman above the bound is decimal too (old: 900 characters of "M").
        #expect(PageLabelNumbering.string(900_000, style: .uppercaseRoman) == "900000")
        #expect(PageLabelNumbering.string(3999, style: .uppercaseRoman) == "MMMCMXCIX")

        let table = PageLabelTable(
            pageCount: 20_000,
            ranges: [PageLabelRange(startPageIndex: 0, style: .lowercaseLetters, firstNumber: 980_001)],
            isExplicit: true
        )
        let total = table.allLabels().reduce(0) { $0 + $1.utf8.count }
        // Old code: ~740 MB of label strings. Now every label is a decimal of at most 7 digits.
        #expect(total <= 20_000 * 7)
    }

    // MARK: - BH-569

    /// Bytes exactly as the synthesised `Codable` conformance wrote them before this fix.
    static let previouslyEncodedTable = """
    {"pageCount":4,"ranges":[{"startPageIndex":0,"style":"r","prefix":"","firstNumber":1},\
    {"startPageIndex":2,"style":"D","prefix":"A-","firstNumber":101},\
    {"startPageIndex":3,"prefix":"COVER","firstNumber":1}],"isExplicit":true}
    """

    @Test("BH-569: previously encoded page-label tables still decode to the same value")
    func oldBytesStillDecode() throws {
        let decoded = try JSONDecoder().decode(
            PageLabelTable.self, from: Data(Self.previouslyEncodedTable.utf8)
        )
        let expected = PageLabelTable(
            pageCount: 4,
            ranges: [
                PageLabelRange(startPageIndex: 0, style: .lowercaseRoman),
                PageLabelRange(startPageIndex: 2, style: .decimal, prefix: "A-", firstNumber: 101),
                PageLabelRange(startPageIndex: 3, style: nil, prefix: "COVER")
            ],
            isExplicit: true
        )
        #expect(decoded == expected)
        #expect(decoded.allLabels() == ["i", "ii", "A-101", "COVER"])
        // And the encoding is unchanged: re-encoding and decoding round-trips.
        let reencoded = try JSONEncoder().encode(expected)
        #expect(try JSONDecoder().decode(PageLabelTable.self, from: reencoded) == expected)
        let object = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["pageCount", "ranges", "isExplicit"])
    }

    @Test("BH-569: a decoded table is normalised, so its binary search stays correct")
    func decodedTablesAreNormalised() throws {
        // Unsorted, first range not at 0, /St 0 — what a hand-edited cache could hold.
        let json = """
        {"pageCount":4,"ranges":[{"startPageIndex":2,"style":"D","prefix":"B-","firstNumber":0},\
        {"startPageIndex":1,"style":"D","prefix":"A-","firstNumber":-5}],"isExplicit":true}
        """
        let table = try JSONDecoder().decode(PageLabelTable.self, from: Data(json.utf8))
        // Old code kept the ranges as decoded: page 0 fell into "B-" with ordinal -2 → "B-",
        // and the binary search returned the wrong range for page 1.
        #expect(table.ranges.map(\.startPageIndex) == [0, 1, 2])
        #expect(table.allLabels() == ["1", "A-1", "B-1", "B-2"])
    }
}
