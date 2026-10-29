import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-AUTO-23: symbols against tags.
struct TagCrossCountTests {

    static func tag(_ text: String, _ x: Double, _ y: Double) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: 20, height: 8))
    }

    @Test("12 D-12 tags against 11 symbols: 11 / 12, and the orphan tag is named")
    func elevenAgainstTwelve() {
        // Tags at x = 0, 50, …, 550 (y 20); symbols under all but the one at x = 300.
        let tags = (0..<12).map { Self.tag("D-12", Double($0) * 50, 20) }
        let symbols = (0..<12).filter { $0 != 6 }.map { PDFPoint(x: Double($0) * 50 + 10, y: 10) }
        let result = TagCrossCount.count(designation: "D-12", lines: tags, symbols: symbols, maximumDistance: 30)
        #expect(result.symbolCount == 11 && result.tagCount == 12)
        #expect(result.orphanTags == [PDFRectValue(x: 300, y: 20, width: 20, height: 8)])
        #expect(result.untaggedSymbols.isEmpty)
        #expect(!result.agrees)
    }

    @Test("Other designations, spelling variants and a tag inside a longer line")
    func matching() {
        let lines = [
            Self.tag("D-13", 0, 20), Self.tag("d‑12", 100, 20), Self.tag("D 12", 200, 20),
            Self.tag("DÖRR D-12 900x2100", 300, 20)
        ]
        let symbols = [PDFPoint(x: 110, y: 10), PDFPoint(x: 210, y: 10), PDFPoint(x: 310, y: 10), PDFPoint(x: 900, y: 900)]
        let result = TagCrossCount.count(designation: "D-12", lines: lines, symbols: symbols, maximumDistance: 30)
        #expect(result.tagCount == 3)
        #expect(result.untaggedSymbols == [PDFPoint(x: 900, y: 900)])
        #expect(result.orphanTags.isEmpty)
    }
}
