import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFPDFKitBridge
import ZPDFTestingSupport
import ZPDFUIPresentation

/// L-21: on a real A1 roof plan the scale proposal offered "Apply 1:10" while the
/// title block's SKALA field said 1:50. The 1:10 was the area field's property designation
/// written after "KV" (block 1, unit 10), not a scale.
///
/// Why 1:10 won, measured through the repository's own text extraction
/// (`PDFKitDocumentProvider.pageTextLines`, the call the app makes on open): the title block hands
/// over "SKALA" as its own line above "1:50", and the area field as the two runs "KV" and
/// "1:10 …". Read one line at a time both ratios were bare — confidence 0.70, no paper hint, both
/// in the title-block corner — so they tied, and reading order (top to bottom) put the area field
/// first. The "best match for the sheet size" wording was only the generic several-ratios
/// message: no sheet-size judgement took part.
///
/// The Synthetic Roof Plan (`ZPDFTestingSupport`) lays its fictional title block out the same way:
/// "SKALA" (6.5 pt) over "1:50" (13 pt) in the bottom row, and the area field's "KV" and
/// "1:10 EXEMPELPARK" as two 13 pt runs 32.66 pt apart — wider than the bridge's column-gutter
/// split, narrower than the proposer's left-neighbour reach — 350 pt higher on the sheet.
@Suite("Scale proposal on a roof plan's title block (L-21)")
struct ScaleProposalRoofPlanTests {

    /// Page 0's positioned text and crop box, read exactly as the app's proposal reads them.
    static func roofPlanPage() async throws -> (lines: [RecognisedTextLine], box: PDFRectValue) {
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(fileAt: try ZPDFFixtures.shared(.syntheticRoofPlan).url)
        let descriptors = try await provider.pageDescriptors(of: opened.handle, range: nil)
        let raw = try await provider.pageTextLines(of: opened.handle, pageIndex: 0)
        await provider.close(opened.handle)
        let crop = descriptors[0].boxes.crop
        let lines = raw.map {
            RecognisedTextLine(text: $0.text, boundsInPageSpace: PDFRectValue(
                x: $0.boundsInPageSpace.origin.x, y: $0.boundsInPageSpace.origin.y,
                width: $0.boundsInPageSpace.width, height: $0.boundsInPageSpace.height
            ))
        }
        return (lines, PDFRectValue(x: crop.origin.x, y: crop.origin.y, width: crop.size.width, height: crop.size.height))
    }

    @Test("The roof plan proposes the SKALA field's 1:50, alone, at 0.0254 × 50 / 72 m per point")
    func roofPlanProposesTheTitleBlockScale() async throws {
        let page = try await Self.roofPlanPage()
        // The sheet is A1 landscape: 841 × 594 mm = 2383.94 × 1683.78 pt.
        #expect(ISOPaperSize.matching(boxSizeInPoints: page.box.size) == .a1)

        let proposal = try #require(SheetScaleProposer().proposal(lines: page.lines, pageBox: page.box))
        // Old output on the original sheet: "1:10", read from the area field, with "1:50" second
        // and needsUserChoice true — the "More than one scale is printed on this sheet" offer.
        #expect(proposal.displayString == "1:50")
        #expect(proposal.evidence.matchedText == "1:50")
        #expect(proposal.evidence.hasExplicitPrefix, "the SKALA caption over the value labels it")
        #expect(proposal.evidence.sourceText == "SKALA 1:50")
        #expect(proposal.notationConfidence == 1.0)
        // The area field's designation is no candidate at all, so the sheet states one scale.
        #expect(proposal.distinctRatios.map(\.denominator) == [50])
        #expect(proposal.needsUserChoice == false)

        // Hand-derived: one PDF point is 1/72 in = 0.0254/72 m of paper; at 1:50 it stands for
        // 50 × 0.0254 / 72 = 1.27 / 72 = 0.0176388… m of roof.
        let expected = try #require(Decimal(string: "1.27", locale: nil)) / 72
        #expect(proposal.metresPerPointExact == expected)
        #expect(abs(proposal.metresPerPoint - 1.27 / 72) < 1e-15)
    }

    @Test("The engine's line entry point, which Measure > Page Scales calls, proposes the roof plan's 1:50 too")
    func pageScalesEntryPointProposesTheTitleBlockScale() async throws {
        let page = try await Self.roofPlanPage()
        let engine = ScaleProposalEngine()

        // The call PageScalesCoordinator makes: the sheet's raw text lines and the crop box's size.
        let proposal = try #require(engine.proposal(forRecognisedLines: page.lines, pageBoxSizeInPoints: page.box.size))
        // Old output: "1:10" with needsUserChoice true, ranked [1:10 0.70, 1:50 0.70] — this entry
        // point still parsed one line at a time after the first L-21 fix, so the Page Scales row
        // said "proposed 1:10" and Apply Proposed Scales applied it in one press.
        #expect(proposal.displayString == "1:50")
        #expect(proposal.evidence.sourceText == "SKALA 1:50")
        #expect(proposal.evidence.hasExplicitPrefix)
        #expect(proposal.distinctRatios.map(\.denominator) == [50])
        #expect(proposal.needsUserChoice == false)
        #expect(abs(proposal.metresPerPoint - 1.27 / 72) < 1e-15)

        // The control: the old one-line-at-a-time reading of the same lines still gives 1:10 first,
        // so this fixture tells the two readings apart.
        let old = try #require(engine.proposal(from: ScaleNotationParser().candidates(in: page.lines), pageBoxSizeInPoints: page.box.size))
        #expect(old.displayString == "1:10")
        #expect(old.needsUserChoice)
        #expect(old.ranked.map(\.candidate.ratio.denominator) == [10, 50])
        #expect(old.ranked.map(\.score) == [0.7, 0.7])

        // One reading for every surface: the warning-tray offer, the takeoff assistant (both
        // SheetScaleProposer) and the engine with the full crop box all give the same proposal.
        let sheet = try #require(SheetScaleProposer().proposal(lines: page.lines, pageBox: page.box))
        #expect(engine.proposal(forRecognisedLines: page.lines, pageBox: page.box) == sheet)
        #expect(sheet.displayString == "1:50")
    }

    @Test("Read with each value's caption and left neighbour, the roof plan has one scale candidate")
    func oneCandidateOnTheRoofPlan() async throws {
        let page = try await Self.roofPlanPage()
        // The same candidates the proposal, the takeoff assistant and the per-sheet offer rank.
        // Old output: [10, 50], both bare. The text layer splits "KV" from "1:10 EXEMPELPARK" and
        // "SKALA" from "1:50"; only the page geometry joins them.
        let candidates = SheetScaleProposer.candidates(in: BaselineLineMerger.merge(page.lines))
        #expect(candidates.map(\.ratio.denominator) == [50])
        #expect(candidates.map(\.hasExplicitPrefix) == [true])
    }
}

/// The two rules L-21 adds, on small hand-built inputs.
@Suite("Scale field label and designation rules (L-21)")
struct ScaleFieldRuleTests {

    private let parser = ScaleNotationParser()
    static let a1 = PDFRectValue(x: 0, y: 0, width: 2383.94, height: 1683.78)

    static func line(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: width, height: height))
    }

    // MARK: Designations

    @Test("A ratio right after a property or block word is no scale; the same ratio elsewhere is")
    func designationIsNotAScale() {
        // Old output: one bare 1:10 candidate for each.
        #expect(parser.candidates(inLine: "KV 1:10 EXEMPELPARK").isEmpty)
        #expect(parser.candidates(inLine: "Kv. 1:10").isEmpty)
        #expect(parser.candidates(inLine: "kvarter 1:10").isEmpty)
        #expect(parser.candidates(inLine: "FASTIGHET: 1:10").isEmpty)
        #expect(parser.candidates(inLine: "Fastighetsbeteckning - 1:10").isEmpty)

        // Contrast: a ratio with any word or number between it and the designation word keeps
        // its reading, and a longer word that only starts like one is not one.
        #expect(parser.candidates(inLine: "KV EXEMPLET SITUATIONSPLAN 1:500").map(\.ratio.denominator) == [500])
        #expect(parser.candidates(inLine: "KVM 1:10").map(\.ratio.denominator) == [10])
        #expect(parser.candidates(inLine: "BLOCK PLAN 1:500").map(\.ratio.denominator) == [500])
        #expect(parser.candidates(inLine: "1:10").map(\.ratio.denominator) == [10])
    }

    @Test("On one line the scale survives and the designation beside it does not")
    func designationBesideAScale() throws {
        let found = parser.candidates(inLine: "SKALA 1:50  KV 1:10 EXEMPELPARK")
        // Old output: [50, 10], so the sheet needed the user's choice.
        #expect(found.map(\.ratio.denominator) == [50])
        #expect(try #require(found.first).hasExplicitPrefix)
    }

    // MARK: Captions

    @Test("Only a line of scale words and paper tokens is a caption")
    func captionRecognition() {
        for caption in ["SKALA", "Skala:", "SKALA/SCALE", "Scale (A1)", "Maßstab", "ÉCHELLE"] {
            #expect(ScaleNotationParser.isScaleLabel(caption), "\(caption) is a caption")
        }
        for text in ["SKALA 1:50", "DETALJ 3 SKALA", "FORMAT", "A1", "", "SKALAN ÄR FEL"] {
            #expect(!ScaleNotationParser.isScaleLabel(text), "\(text) is not a caption")
        }
    }

    @Test("Read after its caption a bare value is labelled; the caption's own ratio is never returned")
    func contextEntryPoint() throws {
        let labelled = parser.candidates(inLine: "1:50", after: "SKALA")
        #expect(labelled.map(\.ratio.denominator) == [50])
        let only = try #require(labelled.first)
        #expect(only.hasExplicitPrefix)
        #expect(only.confidence == 1.0)
        #expect(only.matchedText == "1:50")
        #expect(only.sourceText == "SKALA 1:50")

        #expect(parser.candidates(inLine: "1:10 EXEMPELPARK", after: "KV").isEmpty)
        #expect(parser.candidates(inLine: "1:200 (A3)", after: "SKALA 1:100").map(\.ratio.denominator) == [200])
        #expect(parser.candidates(inLine: "1:50", after: "") == parser.candidates(inLine: "1:50"))

        // The context never changes which notations the value holds: a neighbour ending in a
        // small number is not read as the whole inches of an imperial value's fraction.
        let imperial = "1/8\" = 1'-0\""
        #expect(parser.candidates(inLine: imperial, after: "PLAN 2").map(\.ratio.denominator) == [96])
        #expect(parser.candidates(inLine: imperial, after: "PLAN 2").first?.hasExplicitPrefix == false)
        #expect(parser.candidates(inLine: imperial, after: "SCALE:").first?.hasExplicitPrefix == true)
    }

    @Test("A caption over the value labels it and outranks a bare ratio read first")
    func captionAbove() throws {
        let lines = [
            // Read first, also in the title-block corner, also bare.
            Self.line("1:20 SEKTION", 2130, 300, 60, 8.5),
            // A title block's geometry: caption 4.7 pt tall, 7.6 pt over a value 9.4 pt tall.
            Self.line("SKALA", 2196, 101, 19, 4.7),
            Self.line("1:50", 2196, 84, 24, 9.4)
        ]
        // Old output: 1:20 — two bare 0.70 notations, tie, reading order.
        let proposal = try #require(SheetScaleProposer().proposal(lines: lines, pageBox: Self.a1))
        #expect(proposal.displayString == "1:50")
        #expect(proposal.evidence.hasExplicitPrefix)
        #expect(proposal.needsUserChoice, "the bare 1:20 is still said")
    }

    @Test("A caption left of the value, past the baseline merge, labels it")
    func captionLeft() throws {
        // 15 pt apart: past BaselineLineMerger's 1.5 heights (9 pt), within 4 heights (24 pt).
        let lines = [Self.line("SKALA", 2100, 80, 25, 6), Self.line("1:50", 2140, 80, 20, 6)]
        let candidates = SheetScaleProposer.candidates(in: BaselineLineMerger.merge(lines))
        #expect(candidates.count == 1)
        #expect(try #require(candidates.first).hasExplicitPrefix)
        // Too far right: another cell, so the value stays bare.
        let far = [Self.line("SKALA", 2100, 80, 25, 6), Self.line("1:50", 2160, 80, 20, 6)]
        #expect(SheetScaleProposer.candidates(in: BaselineLineMerger.merge(far)).first?.hasExplicitPrefix == false)
    }

    @Test("A caption labels only the nearest value under it, and not across a gap")
    func captionReach() throws {
        let stacked = [
            Self.line("SKALA", 2235, 101, 19, 4.3),
            Self.line("1:50", 2235, 88, 21, 8.5),
            Self.line("1:20", 2235, 75, 21, 8.5)
        ]
        let candidates = SheetScaleProposer.candidates(in: stacked)
        #expect(candidates.map(\.ratio.denominator) == [50, 20])
        #expect(candidates.map(\.hasExplicitPrefix) == [true, false])

        // 30 pt under the caption: past two value heights (17 pt), so not its field.
        let distant = [Self.line("SKALA", 2235, 126.5, 19, 4.3), Self.line("1:50", 2235, 88, 21, 8.5)]
        #expect(SheetScaleProposer.candidates(in: distant).first?.hasExplicitPrefix == false)

        // A line that states its own scale is no caption for the value under it.
        let detail = [Self.line("DETALJ 3 SKALA 1:20", 2200, 101, 90, 4.3), Self.line("1:50", 2235, 88, 21, 8.5)]
        #expect(SheetScaleProposer.candidates(in: detail).map(\.hasExplicitPrefix) == [true, false])
    }

    @Test("A designation word in its own run left of the ratio removes it")
    func designationRunToTheLeft() {
        // A text layer can report a run with a box far taller than its glyphs: "KV" 9.4 pt tall,
        // and its value reported 86.4 pt tall, sharing KV's top edge at y = 443.4.
        let lines = [Self.line("KV", 2056, 434, 17.3, 9.4), Self.line("1:10 EXEMPELPARK", 2106, 357, 140, 86.4)]
        // Old output: a 1:10 proposal.
        #expect(SheetScaleProposer.candidates(in: BaselineLineMerger.merge(lines)).isEmpty)
        #expect(SheetScaleProposer().proposal(lines: lines, pageBox: Self.a1) == nil)
    }

    // MARK: One reading for every entry point

    @Test("The size-only engine entry point reads captions, designations and the title block as the sheet proposer does")
    func engineLineEntryPointReadsTheGeometry() throws {
        let engine = ScaleProposalEngine()
        // A title block's geometry, hand-built: area field "KV" + "1:10 EXEMPELPARK", caption over
        // value "SKALA" / "1:50".
        let lines = [
            Self.line("KV", 2056, 434, 17.3, 9.4), Self.line("1:10 EXEMPELPARK", 2106, 357, 140, 86.4),
            Self.line("SKALA", 2196, 101, 19, 4.7), Self.line("1:50", 2196, 84, 24, 9.4)
        ]
        let proposal = try #require(engine.proposal(forRecognisedLines: lines, pageBoxSizeInPoints: Self.a1.size))
        // Old output: none of the four lines alone holds "KV 1:10", so 1:10 stayed a candidate
        // and, read first, won: "1:10" with needsUserChoice true.
        #expect(proposal.displayString == "1:50")
        #expect(proposal.needsUserChoice == false)
        #expect(proposal == SheetScaleProposer().proposal(lines: lines, pageBox: Self.a1))

        // Lines without bounds are still read one at a time, exactly as before.
        let bare = [RecognisedTextLine(text: "1:20"), RecognisedTextLine(text: "SKALA 1:100 (A1)")]
        let unpositioned = try #require(engine.proposal(forRecognisedLines: bare, pageBoxSizeInPoints: Self.a1.size))
        #expect(unpositioned.ranked.map(\.candidate) == engine.rank(parser.candidates(in: bare), pageBoxSizeInPoints: Self.a1.size).map(\.candidate))
        #expect(unpositioned.displayString == "1:100")
    }

    @Test("A shifted crop box moves the title-block corner when the caller passes the box itself")
    func shiftedCropBox() throws {
        let engine = ScaleProposalEngine()
        // An A1 crop box whose origin is (1000, 1000), as a cropped plot carries it.
        let box = PDFRectValue(x: 1000, y: 1000, width: 2383.94, height: 1683.78)
        let lines = [
            Self.line("DETALJ 3 SKALA 1:20", 1200, 2500, 160, 14),
            Self.line("SKALA 1:100", 3150, 1060, 160, 14)
        ]
        // Both are labelled and score alike; the title-block corner decides.
        let placed = try #require(engine.proposal(forRecognisedLines: lines, pageBox: box))
        #expect(placed.displayString == "1:100")
        #expect(placed == SheetScaleProposer().proposal(lines: lines, pageBox: box))
        // With only the size the corner is assumed at the origin, where neither line sits, and
        // reading order (top first) decides: the reason a caller holding the box passes it.
        let sized = try #require(engine.proposal(forRecognisedLines: lines, pageBoxSizeInPoints: box.size))
        #expect(sized.displayString == "1:20")
        #expect(sized.needsUserChoice && placed.needsUserChoice, "both ratios are still said")
    }

    // MARK: Ranking

    @Test("A labelled ratio outranks a bare one even off the standard series")
    func labelOutranksSeries() throws {
        let engine = ScaleProposalEngine()
        let odd = PDFSizeValue(width: 900, height: 1300)
        let candidates = parser.candidates(in: [RecognisedTextLine(text: "1:100"), RecognisedTextLine(text: "SKALA 1:150")])
        // Old output: 1:100 — bare series 0.70 over labelled off-series 0.65.
        let proposal = try #require(engine.proposal(from: candidates, pageBoxSizeInPoints: odd))
        #expect(proposal.displayString == "1:150")
        #expect(proposal.ranked.map(\.score) == [0.65, 0.7], "the scores are unchanged; the label orders them")

        // A bare ratio whose paper hint matches the sheet does not beat a labelled one either.
        let a1 = PDFSizeValue(width: 2383.94, height: 1683.78)
        let hinted = parser.candidates(in: [RecognisedTextLine(text: "1:20 (A1)"), RecognisedTextLine(text: "SKALA 1:50")])
        #expect(engine.proposal(from: hinted, pageBoxSizeInPoints: a1)?.displayString == "1:50")
    }

    @Test("A labelled ratio stated for another paper size competes on score, as before")
    func labelForAnotherPaperSize() throws {
        // The dual notation split over two lines: on an A3 print the second line is the scale.
        let a3 = PDFSizeValue(width: 1190.55, height: 841.89)
        let candidates = parser.candidates(in: [
            RecognisedTextLine(text: "SKALA 1:100 (A1)"), RecognisedTextLine(text: "1:200 (A3)")
        ])
        let proposal = try #require(ScaleProposalEngine().proposal(from: candidates, pageBoxSizeInPoints: a3))
        #expect(proposal.displayString == "1:200")
        #expect(proposal.ranked.map(\.paperSizeAgreement) == [.agrees, .disagrees])
    }
}
