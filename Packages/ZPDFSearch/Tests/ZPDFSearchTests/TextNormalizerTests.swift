import Foundation
import Testing

@testable import ZPDFSearch

@Suite("Text normalisation")
struct TextNormalizerTests {

    @Test("A hyphen at a line break is removed and the word is rejoined")
    func hyphenationAcrossLineBreak() {
        #expect(ZPDFTextNormalizer.indexable("COR-\nRIDOR") == "CORRIDOR")
        #expect(ZPDFTextNormalizer.indexable("cor- \n ridor") == "corridor")
        #expect(ZPDFTextNormalizer.indexable("för-\nråd") == "förråd")
        // Soft hyphen and the Unicode hyphen behave the same as ASCII.
        #expect(ZPDFTextNormalizer.indexable("cor\u{00AD}\nridor") == "corridor")
        #expect(ZPDFTextNormalizer.indexable("cor\u{2010}\nridor") == "corridor")
    }

    @Test("A hyphen that is not a line break survives, so sheet numbers survive")
    func sheetNumbersKeepTheirHyphen() {
        #expect(ZPDFTextNormalizer.indexable("DRAWING A-102") == "DRAWING A-102")
        #expect(ZPDFTextNormalizer.indexable("A-102\nA-103") == "A-102 A-103")
        // A hyphen before a break with a digit after it is not hyphenation.
        #expect(ZPDFTextNormalizer.indexable("EL-\n3") == "EL- 3")
        // A hyphen at the very end of the text has nothing to join to.
        #expect(ZPDFTextNormalizer.indexable("PARTIAL-") == "PARTIAL-")
    }

    @Test("Ligatures and other compatibility forms are expanded")
    func ligatures() {
        // U+FB01 is the *lowercase* fi ligature, and NFKC expands it to lowercase `fi`
        // even in the middle of a run of capitals — which is right: the expansion's job is
        // to produce two letters where there was one glyph, not to guess a case the code
        // point does not carry. FTS5 folds case on both sides of a match, so `profile`,
        // `PROFILE` and `Profile` all find this row; before the expansion, none of them did.
        #expect(ZPDFTextNormalizer.indexable("PRO\u{FB01}LE") == "PROfiLE")
        #expect(ZPDFTextNormalizer.indexable("\u{FB02}OOR") == "flOOR")
        #expect(ZPDFTextNormalizer.folded(ZPDFTextNormalizer.indexable("PRO\u{FB01}LE")) == "profile")
        #expect(ZPDFTextNormalizer.tokens(in: ZPDFTextNormalizer.indexable("PRO\u{FB01}LE")) == ["PROfiLE"])
        // Fullwidth digits are the same digits.
        #expect(ZPDFTextNormalizer.indexable("\u{FF11}\u{FF10}\u{FF11}") == "101")
        // Turning it off leaves the code point alone.
        var options = TextNormalizationOptions.standard
        options.expandsCompatibilityForms = false
        #expect(ZPDFTextNormalizer.indexable("PRO\u{FB01}LE", options: options) == "PRO\u{FB01}LE")
    }

    @Test("Whitespace runs collapse and control characters disappear")
    func whitespace() {
        #expect(ZPDFTextNormalizer.indexable("  ROOM   \t 101 \n\n ") == "ROOM 101")
        #expect(ZPDFTextNormalizer.indexable("A\u{0000}B") == "AB")
        #expect(ZPDFTextNormalizer.indexable("\r\nROOM\r\n") == "ROOM")
    }

    @Test("Folding removes case and diacritics but keeps the letters")
    func folding() {
        #expect(ZPDFTextNormalizer.folded("KÖK") == "kok")
        #expect(ZPDFTextNormalizer.folded("Förråd") == "forrad")
        #expect(ZPDFTextNormalizer.folded("ROOM") == "room")
        // A decomposed o-with-diaeresis folds to the same thing as the precomposed one.
        #expect(ZPDFTextNormalizer.folded("o\u{0308}k") == ZPDFTextNormalizer.folded("ök"))
    }

    @Test("Tokenising splits on non-alphanumerics and keeps combining marks attached")
    func tokenising() {
        #expect(ZPDFTextNormalizer.tokens(in: "ROOM 101") == ["ROOM", "101"])
        #expect(ZPDFTextNormalizer.tokens(in: "A-102") == ["A", "102"])
        #expect(ZPDFTextNormalizer.tokens(in: "NEAR(a, b)") == ["NEAR", "a", "b"])
        #expect(ZPDFTextNormalizer.tokens(in: "((()))").isEmpty)
        #expect(ZPDFTextNormalizer.tokens(in: "\"\"\"").isEmpty)
        // A decomposed accent stays inside its token rather than splitting it.
        #expect(ZPDFTextNormalizer.tokens(in: "KO\u{0308}K") == ["KO\u{0308}K"])
    }

    @Test("A pathological token is truncated rather than carried")
    func tokenLengthIsBounded() {
        let monster = String(repeating: "a", count: 10_000)
        let tokens = ZPDFTextNormalizer.tokens(in: monster, maximumTokenLength: 128)
        #expect(tokens.count == 1)
        #expect(tokens[0].count == 128)
    }
}
