import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// NL-MEASURE-17: imperial scale notations, and a detail title never outranking the title block.
/// Every expected ratio is hand-derived: real inches ÷ paper inches.
@Suite("Scale notation: imperial grammars (NL-MEASURE-17)")
struct NLMeasureScaleNotationTests {

    func ratios(_ text: String) -> [Int] {
        ScaleNotationParser().candidates(inLine: text).map(\.ratio.denominator)
    }

    @Test("Architectural: 1/8\" = 1'-0\" is 1:96 (12 ÷ 0.125), 1/4\" is 1:48, 3/16\" is 1:64, 1-1/2\" is 1:8")
    func architectural() {
        #expect(ratios("SCALE: 1/8\" = 1'-0\"") == [96])
        #expect(ratios("1/4\"=1'-0\"") == [48])
        #expect(ratios("3/16\" = 1'-0\"") == [64])
        #expect(ratios("1-1/2\" = 1'-0\"") == [8])
        #expect(ratios("3\" = 1'-0\"") == [4])
        // Typographic marks as a PDF text layer gives them: ″ and ′.
        #expect(ratios("SCALE 1/8\u{2033} = 1\u{2032}-0\u{2033}") == [96])
        // Two apostrophes for the inch mark.
        #expect(ratios("1/4'' = 1'-0''") == [48])
    }

    @Test("Engineering: 1\" = 20'-0\" is 1:240, 1\" = 50' is 1:600, 1\" = 10' is 1:120")
    func engineering() {
        #expect(ratios("1\" = 20'-0\"") == [240])
        #expect(ratios("SCALE 1\" = 50'") == [600])
        #expect(ratios("1\"=10'") == [120])
    }

    @Test("A notation that does not reduce to 1:d, or a sheet number before it, is not misread")
    func refusals() {
        // 5/16" = 1'-0" is 12 ÷ 0.3125 = 38.4: not a whole ratio, left out rather than rounded.
        #expect(ratios("5/16\" = 1'-0\"").isEmpty)
        // A drawing number before the fraction must not become a mixed number (101 1/8").
        #expect(ratios("A-101 1/8\" = 1'-0\"") == [96])
        #expect(ratios("WALL 12\" THICK").isEmpty)
    }

    @Test("An explicit imperial scale is proposed with full confidence")
    func confidence() throws {
        let candidate = try #require(ScaleNotationParser().candidates(inLine: "SCALE: 1/8\" = 1'-0\"").first)
        #expect(candidate.hasExplicitPrefix)
        #expect(candidate.matchedText == "1/8\" = 1'-0\"")
        let metric = try #require(ScaleNotationParser().candidates(inLine: "SCALE 1:100").first)
        #expect(candidate.confidence == metric.confidence)
    }

    /// A detail title "1:20" sits mid-sheet; the title block "SCALE 1:100" sits bottom right.
    /// The title block wins however the detail is written.
    @Test("A detail title never outranks the title block")
    func titleBlockWins() throws {
        let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        let lines = [
            RecognisedTextLine(text: "DETAIL 3 SCALE 1:20", boundsInPageSpace: PDFRectValue(x: 400, y: 900, width: 200, height: 12)),
            RecognisedTextLine(text: "SCALE 1:100", boundsInPageSpace: PDFRectValue(x: 2100, y: 80, width: 120, height: 12))
        ]
        let proposal = try #require(SheetScaleProposer().proposal(lines: lines, pageBox: a1))
        #expect(proposal.ratio.denominator == 100)
        let imperial = [
            RecognisedTextLine(text: "DETAIL SCALE: 3\" = 1'-0\"", boundsInPageSpace: PDFRectValue(x: 400, y: 900, width: 200, height: 12)),
            RecognisedTextLine(text: "SCALE: 1/8\" = 1'-0\"", boundsInPageSpace: PDFRectValue(x: 2100, y: 80, width: 120, height: 12))
        ]
        #expect(try #require(SheetScaleProposer().proposal(lines: imperial, pageBox: a1)).ratio.denominator == 96)
    }
}
