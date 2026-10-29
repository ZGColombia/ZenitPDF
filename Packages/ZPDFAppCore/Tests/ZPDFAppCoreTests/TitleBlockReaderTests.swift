import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation

/// NL-AUTO-04: the title-block reader. Every line's position is written next to it; the
/// expected names are the text placed in the boxes.
struct TitleBlockReaderTests {

    /// A1 landscape.
    static let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
    static let a3 = PDFRectValue(x: 0, y: 0, width: 1191, height: 842)

    static func line(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double = 20) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: width, height: height))
    }

    /// A title block in the bottom-right corner: number box 2200…2360 × 40…90, title box
    /// 1900…2360 × 110…190.
    static let numberBox = PDFRectValue(x: 2200, y: 40, width: 160, height: 50)
    static let titleBox = PDFRectValue(x: 1900, y: 110, width: 460, height: 80)

    static func sheet(number: String, titleLines: [String]) -> [RecognisedTextLine] {
        var lines = [line(number, 2210, 50, 120, 30)]
        for (index, text) in titleLines.enumerated() {
            // Top line first: y 160, then 130.
            lines.append(line(text, 1910, 160 - Double(index) * 30, 300))
        }
        lines.append(line("GENERAL NOTES", 100, 1600, 200))
        return lines
    }

    @Test("A template read names the page from the text inside its boxes, title lines top to bottom")
    func templateRead() throws {
        let template = TitleBlockTemplate(numberRect: Self.numberBox, titleRect: Self.titleBox, pageBox: Self.a1)
        let proposal = try #require(TitleBlockReader().read(
            template: template, pageIndex: 3, pageBox: Self.a1,
            lines: Self.sheet(number: "A - 104", titleLines: ["FLOOR PLAN", "LEVEL 2"])
        ))
        #expect(proposal.number == "A-104")
        #expect(proposal.title == "FLOOR PLAN LEVEL 2")
        #expect(proposal.source == .template)
        #expect(proposal.confidence == 1)
    }

    @Test("The boxes are anchored to the nearest corner, so a shifted page box reads the same place")
    func anchoredToCorner() {
        let region = TitleBlockAnchoredRegion(rect: Self.numberBox, on: Self.a1)
        #expect(region.corner == .bottomRight)
        // 2384 − 2360 = 24 from the right, 40 from the bottom.
        #expect(region.insetX == 24 && region.insetY == 40)
        // A crop box whose origin is (10, 12) and which is 2 pt wider: the box moves with the corner.
        let shifted = PDFRectValue(x: 10, y: 12, width: 2386, height: 1684)
        let resolved = region.resolved(on: shifted)
        #expect(resolved == PDFRectValue(x: 10 + 2386 - 24 - 160, y: 12 + 40, width: 160, height: 50))
    }

    @Test("A template drawn on A1 does not name an A3 page")
    func otherPaperIsNotRead() {
        let template = TitleBlockTemplate(numberRect: Self.numberBox, titleRect: nil, pageBox: Self.a1)
        #expect(template.applies(to: Self.a1))
        #expect(!template.applies(to: Self.a3))
        #expect(TitleBlockReader().read(template: template, pageIndex: 0, pageBox: Self.a3, lines: []) == nil)
    }

    @Test("An empty box proposes nothing, with zero confidence — never a name from elsewhere")
    func emptyBox() throws {
        let template = TitleBlockTemplate(numberRect: Self.numberBox, titleRect: Self.titleBox, pageBox: Self.a1)
        let proposal = try #require(TitleBlockReader().read(
            template: template, pageIndex: 0, pageBox: Self.a1, lines: [Self.line("GENERAL NOTES", 100, 1600, 200)]
        ))
        #expect(proposal.number == nil)
        #expect(proposal.confidence == 0)
        #expect(proposal.isEmpty)
    }

    @Test("A line only partly inside the box lowers the confidence to the share inside")
    func partialLine() throws {
        let template = TitleBlockTemplate(numberRect: Self.numberBox, titleRect: nil, pageBox: Self.a1)
        // 2300…2400 × 50…70: 60 of 100 pt wide lies inside the box (2300…2360).
        let proposal = try #require(TitleBlockReader().read(
            template: template, pageIndex: 0, pageBox: Self.a1, lines: [Self.line("A-201", 2300, 50, 100)]
        ))
        #expect(proposal.number == "A-201")
        #expect(abs(proposal.confidence - 0.6) < 1e-12)
    }

    @Test("Automatic, Swedish: \"Ritn.nr: A-101\" and a Benämning label with its value below")
    func automaticSwedish() {
        let lines = [
            Self.line("Ritn.nr: A-101", 2000, 60, 200),
            Self.line("Benämning", 2000, 150, 120),
            Self.line("PLAN 1", 2000, 120, 120),
            Self.line("Skala 1:100", 2000, 30, 120)
        ]
        let proposal = TitleBlockReader().readAutomatically(pageIndex: 0, pageBox: Self.a1, lines: lines)
        #expect(proposal.number == "A-101")
        #expect(proposal.title == "PLAN 1")
        #expect(proposal.source == .keywordAnchor)
        #expect(proposal.confidence == TitleBlockReader.anchorConfidence)
    }

    @Test("Automatic, English: the value in the cell below DRAWING NO., and a sheet-title label is not a number")
    func automaticEnglish() {
        let lines = [
            Self.line("DRAWING NO.", 2100, 100, 120),
            Self.line("A-104", 2100, 70, 80),
            Self.line("Sheet title: Floor Plan", 1900, 200, 220)
        ]
        let proposal = TitleBlockReader().readAutomatically(pageIndex: 0, pageBox: Self.a1, lines: lines)
        #expect(proposal.number == "A-104")
        #expect(proposal.title == "Floor Plan")
    }

    @Test("Automatic ignores text away from the corners and labels that only start like one")
    func automaticRefusals() {
        let far = [Self.line("Ritn.nr: A-101", 1200, 800, 200)]
        #expect(TitleBlockReader().readAutomatically(pageIndex: 0, pageBox: Self.a1, lines: far).number == nil)
        let lookalike = [Self.line("Sheets 4", 2100, 60, 100)]
        #expect(TitleBlockReader().readAutomatically(pageIndex: 0, pageBox: Self.a1, lines: lookalike).number == nil)
    }

    @Test("Two pages claiming one number are both flagged, and nothing is renamed")
    func duplicates() {
        let proposals = TitleBlockReader.flaggingDuplicates([
            SheetNameProposal(pageIndex: 0, number: "A-101", title: nil, source: .template, confidence: 1),
            SheetNameProposal(pageIndex: 1, number: "a-101", title: nil, source: .template, confidence: 1),
            SheetNameProposal(pageIndex: 2, number: "A-102", title: nil, source: .template, confidence: 1)
        ])
        #expect(proposals.map(\.isDuplicateNumber) == [true, true, false])
        #expect(proposals.map(\.number) == ["A-101", "a-101", "A-102"])
    }
}
