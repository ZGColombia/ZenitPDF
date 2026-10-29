import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation
import ZPDFVectorExtraction
import CoreGraphics

/// Bug `ZenitPDFProjectDocument.swift:1118`: the proposal reads the sheet's own
/// positioned text and prefers the title block over a detail title.
struct SheetScaleProposerTests {

    static let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)

    static func line(_ text: String, _ x: Double, _ y: Double) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: 160, height: 14))
    }

    @Test("A detail's scale read first does not beat the title block's")
    func titleBlockWinsTheTie() throws {
        // The detail title sits top-left and is read first; the title block sits bottom-right.
        let lines = [Self.line("DETALJ 3 SKALA 1:20", 200, 1500), Self.line("SKALA 1:100", 2150, 60)]
        // Old ranking (one line at a time, reading order breaks the tie): 1:20. Until L-21's
        // re-fix the engine's line entry point still read this way.
        let old = try #require(ScaleProposalEngine().proposal(
            from: ScaleNotationParser().candidates(in: lines), pageBoxSizeInPoints: Self.a1.size
        ))
        #expect(old.displayString == "1:20")
        let proposal = try #require(SheetScaleProposer().proposal(lines: lines, pageBox: Self.a1))
        #expect(proposal.displayString == "1:100")
        // Every entry point reads the sheet the same way now, the size-only one included.
        #expect(ScaleProposalEngine().proposal(forRecognisedLines: lines, pageBoxSizeInPoints: Self.a1.size) == proposal)
        #expect(proposal.evidence.boundsInPageSpace != nil, "the bounds are kept for the evidence")
        #expect(proposal.needsUserChoice, "two ratios on the sheet are still said")
    }

    @Test("A boxed title block moves the preference with it")
    func templateZone() throws {
        let lines = [Self.line("SKALA 1:20", 200, 1500), Self.line("SKALA 1:100", 2150, 60)]
        let proposal = try #require(SheetScaleProposer().proposal(
            lines: lines, pageBox: Self.a1, titleBlock: PDFRectValue(x: 100, y: 1400, width: 400, height: 200)
        ))
        #expect(proposal.displayString == "1:20")
    }

    @Test("A cover sheet with no scale proposes nothing")
    func coverSheet() {
        #expect(SheetScaleProposer().proposal(lines: [Self.line("PROJECT EXEMPELVÄGEN 12", 900, 800)], pageBox: Self.a1) == nil)
    }
}

/// The text layer split "Skala" from "1:100" on a measured synthetic title block (NL-AUTO-25).
struct BaselineLineMergerTests {
    static func line(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double = 10) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: width, height: height))
    }

    @Test("A label and its ratio on one baseline become one line; lines above and far away do not")
    func merges() {
        let merged = BaselineLineMerger.merge([
            Self.line("1:100", 945, 30, 25), Self.line("Skala", 910, 30, 30),
            Self.line("Benämning", 910, 140, 50), Self.line("NOTES", 300, 30, 40)
        ])
        #expect(merged.map(\.text) == ["Benämning", "NOTES", "Skala 1:100"])
        #expect(merged.last?.boundsInPageSpace == PDFRectValue(x: 910, y: 30, width: 60, height: 10))
    }

    @Test("A split notation still beats a detail's scale in the title block")
    func splitNotationInTitleBlock() throws {
        let a3 = PDFRectValue(x: 0, y: 0, width: 1191, height: 842)
        let lines = [Self.line("DETALJ 3 SKALA 1:5", 60, 780, 120), Self.line("Skala", 910, 30, 30), Self.line("1:100", 945, 30, 25)]
        // Old output: 1:5 — "1:100" alone had no scale word and lost on confidence.
        let proposal = try #require(SheetScaleProposer().proposal(lines: lines, pageBox: a3))
        #expect(proposal.displayString == "1:100")
    }
}

/// NL-AUTO-19: one scale per viewport, each with the region of the drawing above its title.
struct ViewportScaleDetectorTests {

    static func line(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> VectorPrimitive {
        SymbolCountReviewTests.linePrimitive(id, CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1))
    }

    /// A rectangle of four strokes, the stand-in for a drawing.
    static func box(_ base: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [VectorPrimitive] {
        [line(base, x0, y0, x1, y0), line(base + 1, x1, y0, x1, y1), line(base + 2, x1, y1, x0, y1), line(base + 3, x0, y1, x0, y0)]
    }

    @Test("A 1:100 plan and a 1:20 detail: two region proposals, each around its own drawing")
    func twoViewports() throws {
        let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        // The plan 100…500 × 300…700 (400 pt, under the 30 % furniture limit of 715 pt), the
        // detail 700…900 × 400…600; the sheet frame is furniture.
        var primitives = Self.box(1, 100, 300, 500, 700) + Self.box(10, 700, 400, 900, 600)
        primitives += Self.box(20, 20, 20, 2364, 1664)
        let lines = [
            RecognisedTextLine(text: "PLAN 1:100", boundsInPageSpace: PDFRectValue(x: 250, y: 270, width: 80, height: 12)),
            RecognisedTextLine(text: "DETALJ 3 SKALA 1:20", boundsInPageSpace: PDFRectValue(x: 740, y: 370, width: 120, height: 12)),
            // The title block's own scale is the sheet's, not a viewport's.
            RecognisedTextLine(text: "SKALA 1:100", boundsInPageSpace: PDFRectValue(x: 2100, y: 60, width: 80, height: 12))
        ]
        let proposals = ViewportScaleDetector().proposals(lines: lines, pageBox: a1, primitives: primitives)
        #expect(proposals.count == 2)
        let detail = try #require(proposals.first { $0.ratio.description == "1:20" })
        #expect(detail.region == PDFRectValue(x: 700, y: 400, width: 200, height: 200))
        #expect(detail.evidence.sourceText.contains("DETALJ 3"))
        let plan = try #require(proposals.first { $0.ratio.description == "1:100" })
        #expect(plan.region == PDFRectValue(x: 100, y: 300, width: 400, height: 400))
    }

    @Test("A title with no drawing above it proposes nothing")
    func noDrawing() {
        let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        let lines = [RecognisedTextLine(text: "DETALJ 3 SKALA 1:20", boundsInPageSpace: PDFRectValue(x: 740, y: 370, width: 120, height: 12))]
        #expect(ViewportScaleDetector().proposals(lines: lines, pageBox: a1, primitives: Self.box(1, 100, 900, 300, 1100)).isEmpty)
    }
}
