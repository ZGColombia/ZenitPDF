import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation

/// Feature 2, engine half: reading the scale a drawing states about itself.
///
/// Every parser rule is asserted twice — once on a string that must produce a candidate and
/// once on a string that must not — because a parser tested only on what it should accept is a
/// parser that accepts everything.
struct ScaleNotationParserTests {

    private let parser = ScaleNotationParser()

    // MARK: - Rule: the numerator must be 1

    @Test("A 1:n notation parses; a ratio with any other numerator does not")
    func numeratorMustBeOne() throws {
        let accepted = parser.candidates(inLine: "1:100")
        #expect(accepted.count == 1)
        #expect(accepted.first?.ratio.denominator == 100)
        #expect(accepted.first?.ratio.numerator == 1)

        #expect(parser.candidates(inLine: "2:1 vote").isEmpty)
        #expect(parser.candidates(inLine: "Beslut 3:2 i nämnden").isEmpty)
    }

    // MARK: - Rule: times are not scales

    @Test("A clock reading is rejected; the same digits as a scale are not")
    func timesAreRejected() throws {
        #expect(parser.candidates(inLine: "13:37").isEmpty)
        #expect(parser.candidates(inLine: "UTSKRIFT 13:00").isEmpty)
        #expect(parser.candidates(inLine: "MÖTE 08:30").isEmpty)

        #expect(parser.candidates(inLine: "1:50").count == 1)
    }

    // MARK: - Rule: no leading zeros

    @Test("1:50 parses; the zero-padded 01:50 does not")
    func leadingZerosAreRejected() throws {
        let accepted = parser.candidates(inLine: "1:50")
        #expect(accepted.first?.ratio.denominator == 50)

        #expect(parser.candidates(inLine: "01:50").isEmpty)
        #expect(parser.candidates(inLine: "1:050").isEmpty)
    }

    // MARK: - Rule: a denominator of zero is not a scale

    @Test("1:1 parses; 1:0 does not")
    func zeroDenominatorRejected() throws {
        #expect(parser.candidates(inLine: "1:1").count == 1)
        #expect(parser.candidates(inLine: "1:0").isEmpty)
    }

    // MARK: - Rule: no colon chains

    @Test("A lone ratio parses; a timestamp or a colon list does not")
    func colonChainsAreRejected() throws {
        #expect(parser.candidates(inLine: "1:2").count == 1)

        #expect(parser.candidates(inLine: "12:34:56").isEmpty)
        #expect(parser.candidates(inLine: "1:2:3").isEmpty)
        // The tail of a timestamp must not restart the scan as its own ratio.
        #expect(parser.candidates(inLine: "Start 09:15:100").isEmpty)
    }

    // MARK: - Rule: no decimal tail

    @Test("1:2 parses; 1:2.5 does not")
    func decimalTailRejected() throws {
        #expect(parser.candidates(inLine: "1:2").count == 1)
        #expect(parser.candidates(inLine: "1:2.5").isEmpty)
    }

    // MARK: - Rule: one space per side of the colon

    @Test("Single-space variants parse; a double-spaced colon does not")
    func whitespaceVariants() throws {
        for line in ["1:100", "1 :100", "1: 100", "1 : 100"] {
            let found = parser.candidates(inLine: line)
            #expect(found.count == 1, "expected one candidate in \(line)")
            #expect(found.first?.ratio.denominator == 100, "wrong ratio in \(line)")
            #expect(found.first?.matchedText == line)
        }

        #expect(parser.candidates(inLine: "1  :  100").isEmpty)
    }

    // MARK: - Rule: the colon may be any of the three glyphs a recogniser emits

    @Test("Ratio and full-width colons parse; a semicolon does not")
    func colonGlyphs() throws {
        #expect(parser.candidates(inLine: "SKALA 1\u{2236}100").count == 1)
        #expect(parser.candidates(inLine: "SKALA 1\u{FF1A}100").count == 1)

        #expect(parser.candidates(inLine: "SKALA 1;100").isEmpty)
    }

    // MARK: - Rule: an explicit scale word raises confidence

    @Test("SKALA outranks a bare ratio of the same denominator")
    func explicitPrefixRaisesConfidence() throws {
        let prefixed = try #require(parser.candidates(inLine: "SKALA 1:100").first)
        #expect(prefixed.hasExplicitPrefix)
        #expect(prefixed.confidence == 1.0)

        let bare = try #require(parser.candidates(inLine: "1:100").first)
        #expect(bare.hasExplicitPrefix == false)
        #expect(bare.confidence == 0.7)
        #expect(prefixed.confidence > bare.confidence)
    }

    @Test("The scale word reaches across ratios and punctuation, but not across other words")
    func explicitPrefixReach() throws {
        let dual = parser.candidates(inLine: "Skala 1:100, 1:200 (A3)")
        #expect(dual.count == 2)
        let bothPrefixed = dual.allSatisfy(\.hasExplicitPrefix)
        #expect(bothPrefixed)

        let split = parser.candidates(inLine: "SKALA 1:100  RITNINGSNR 1:250")
        #expect(split.count == 2)
        #expect(split[0].hasExplicitPrefix)
        #expect(split[1].hasExplicitPrefix == false)
    }

    @Test("European scale words are recognised; an unrelated word is not a prefix")
    func europeanScaleWords() throws {
        for line in ["SKALA 1:100", "Scale 1:100", "Maßstab 1:100", "Échelle 1:100"] {
            let found = try #require(parser.candidates(inLine: line).first)
            #expect(found.hasExplicitPrefix, "expected a prefix in \(line)")
        }

        let notAPrefix = try #require(parser.candidates(inLine: "Rumshöjd 1:100").first)
        #expect(notAPrefix.hasExplicitPrefix == false)
    }

    // MARK: - Rule: the standard series raises confidence, a stray denominator lowers it

    @Test("A series denominator scores above one outside the series")
    func standardSeriesRaisesConfidence() throws {
        let standard = try #require(parser.candidates(inLine: "SKALA 1:100").first)
        #expect(standard.ratio.isStandardSeries)
        #expect(standard.confidence == 1.0)

        let outside = try #require(parser.candidates(inLine: "SKALA 1:150").first)
        #expect(outside.ratio.isStandardSeries == false)
        #expect(outside.confidence == 0.65)
        #expect(outside.confidence < standard.confidence)

        let bareOutside = try #require(parser.candidates(inLine: "1:150").first)
        #expect(bareOutside.confidence == 0.35)
    }

    // MARK: - Rule: paper hints are delimited tokens, not drawing numbers

    @Test("A parenthesised paper size is a hint; a drawing number is not")
    func paperSizeHints() throws {
        let hinted = try #require(parser.candidates(inLine: "Skala 1:100 (A1)").first)
        #expect(hinted.paperSizeHint == .a1)
        #expect(hinted.ratio.denominator == 100)

        let numbered = try #require(parser.candidates(inLine: "SKALA 1:100 A1-101").first)
        #expect(numbered.paperSizeHint == nil)

        let dotted = try #require(parser.candidates(inLine: "SKALA 1:100 A3.02").first)
        #expect(dotted.paperSizeHint == nil)
    }

    // MARK: - Rule: a dual-scale line yields both ratios

    @Test("1:100, 1:200 (A3) is two candidates, and only the second carries the hint")
    func dualScaleLine() throws {
        let found = parser.candidates(inLine: "1:100, 1:200 (A3)")
        #expect(found.count == 2)
        #expect(found[0].ratio.denominator == 100)
        #expect(found[0].paperSizeHint == nil)
        #expect(found[1].ratio.denominator == 200)
        #expect(found[1].paperSizeHint == .a3)

        // A single-scale line must not invent a second candidate.
        #expect(parser.candidates(inLine: "SKALA 1:100 (A1)").count == 1)
    }

    @Test("Each ratio keeps its own hint when both are parenthesised")
    func dualScaleWithTwoHints() throws {
        let found = parser.candidates(inLine: "SKALA 1:100 (A1), 1:200 (A3)")
        #expect(found.count == 2)
        #expect(found[0].paperSizeHint == .a1)
        #expect(found[1].paperSizeHint == .a3)
    }

    // MARK: - Rule: bounds are carried, never interpreted

    @Test("Recognised bounds reach the candidate unchanged; a line without them yields nil")
    func boundsArePassedThrough() throws {
        let bounds = PDFRectValue(x: 1234.5, y: 67.25, width: 88, height: 12)
        let withBounds = try #require(
            parser.candidates(inLine: "SKALA 1:100", boundsInPageSpace: bounds).first
        )
        #expect(withBounds.boundsInPageSpace == bounds)

        let withoutBounds = try #require(parser.candidates(inLine: "SKALA 1:100").first)
        #expect(withoutBounds.boundsInPageSpace == nil)
    }

    // MARK: - Lines are independent

    @Test("A scale word does not leak into the next line")
    func linesAreIndependent() throws {
        let found = parser.candidates(in: [
            RecognisedTextLine(text: "SKALA"),
            RecognisedTextLine(text: "1:100")
        ])
        let single = try #require(found.first)
        #expect(found.count == 1)
        #expect(single.hasExplicitPrefix == false)

        let joined = try #require(parser.candidates(inLine: "SKALA 1:100").first)
        #expect(joined.hasExplicitPrefix)
    }

    @Test("The tuple entry point sees the same candidates as the struct entry point")
    func tupleEntryPoint() throws {
        let bounds = PDFRectValue(x: 10, y: 20, width: 30, height: 40)
        let lines: [(String, boundsInPageSpace: PDFRectValue?)] = [
            ("SKALA 1:100", boundsInPageSpace: bounds),
            ("DATUM 2026-03-14", boundsInPageSpace: nil)
        ]
        let found = parser.candidates(in: lines)
        #expect(found.count == 1)
        #expect(found.first?.boundsInPageSpace == bounds)
    }
}

/// Ratio arithmetic: the only number this feature computes.
struct ScaleRatioTests {

    @Test("metresPerPoint for 1:100 is 0.0254 * 100 / 72")
    func metresPerPointOneHundred() throws {
        let ratio = try #require(ScaleRatio(denominator: 100))
        #expect(abs(ratio.metresPerPoint - 0.0254 * 100 / 72) < 1e-12)
        #expect(ratio.description == "1:100")
    }

    @Test("Other ratios scale with the denominator and are never 1:1 by accident")
    func metresPerPointScales() throws {
        let fifty = try #require(ScaleRatio(denominator: 50))
        let twoHundred = try #require(ScaleRatio(denominator: 200))
        #expect(abs(fifty.metresPerPoint - 0.0254 * 50 / 72) < 1e-12)
        #expect(abs(twoHundred.metresPerPoint - 0.0254 * 200 / 72) < 1e-12)
        #expect(abs(twoHundred.metresPerPoint - 4 * fifty.metresPerPoint) < 1e-12)

        let fullSize = try #require(ScaleRatio(denominator: 1))
        #expect(abs(fullSize.metresPerPoint - 0.0254 / 72) < 1e-12)
        #expect(fifty.metresPerPoint != fullSize.metresPerPoint)
    }

    @Test("The exact Decimal factor agrees with the Double one and is not a float round-trip")
    func metresPerPointExact() throws {
        let ratio = try #require(ScaleRatio(denominator: 100))
        let expected = try #require(Decimal(string: "0.0254", locale: nil)) * 100 / 72
        #expect(ratio.metresPerPointExact == expected)
        #expect(abs(NSDecimalNumber(decimal: ratio.metresPerPointExact).doubleValue
            - ratio.metresPerPoint) < 1e-12)
    }

    @Test("Only 1:n is a ratio, and only within a sane denominator range")
    func construction() throws {
        #expect(ScaleRatio(numerator: 1, denominator: 100) != nil)
        #expect(ScaleRatio(numerator: 2, denominator: 1) == nil)
        #expect(ScaleRatio(numerator: 1, denominator: 0) == nil)
        #expect(ScaleRatio(numerator: 1, denominator: -100) == nil)
        #expect(ScaleRatio(numerator: 1, denominator: 100_001) == nil)
    }

    @Test("The standard series holds the denominators a drawing office prints at")
    func standardSeries() throws {
        for denominator in [1, 2, 5, 10, 20, 25, 50, 75, 100, 125, 200, 250, 400, 500, 1000] {
            let ratio = try #require(ScaleRatio(denominator: denominator))
            #expect(ratio.isStandardSeries, "1:\(denominator) should be in the series")
        }
        for denominator in [3, 7, 60, 150, 333, 900] {
            let ratio = try #require(ScaleRatio(denominator: denominator))
            #expect(ratio.isStandardSeries == false, "1:\(denominator) should not be in the series")
        }
    }
}

/// Ranking and proposal, including the page-size question a dual-scale line asks.
struct ScaleProposalEngineTests {

    private let parser = ScaleNotationParser()
    private let engine = ScaleProposalEngine()

    /// An A1 sheet as a plotter writes it: 594 x 841 mm in points, rounded.
    private let a1Page = PDFSizeValue(width: 1683.78, height: 2383.94)
    /// An A3 reduction of the same sheet.
    private let a3Page = PDFSizeValue(width: 841.89, height: 1190.55)
    /// A trimmed sheet that is no standard paper size at all.
    private let oddPage = PDFSizeValue(width: 900, height: 1300)

    @Test("An explicit SKALA outranks a bare ratio, whichever order they were read in")
    func explicitPrefixWinsTheRanking() throws {
        let forwards = parser.candidates(in: [
            RecognisedTextLine(text: "SKALA 1:100"),
            RecognisedTextLine(text: "1:250")
        ])
        let first = try #require(engine.proposal(from: forwards, pageBoxSizeInPoints: oddPage))
        #expect(first.ratio.denominator == 100)
        #expect(first.displayString == "1:100")
        #expect(first.ranked.count == 2)
        #expect(first.ranked[1].candidate.ratio.denominator == 250)

        // Ranking must be by evidence, not by reading order.
        let backwards = parser.candidates(in: [
            RecognisedTextLine(text: "1:250"),
            RecognisedTextLine(text: "SKALA 1:100")
        ])
        let second = try #require(engine.proposal(from: backwards, pageBoxSizeInPoints: oddPage))
        #expect(second.ratio.denominator == 100)
    }

    @Test("A dual-scale line resolves to the ratio whose paper hint matches the sheet")
    func dualScaleResolvesAgainstThePageBox() throws {
        let candidates = parser.candidates(inLine: "SKALA 1:100 (A1), 1:200 (A3)")
        #expect(candidates.count == 2)

        let onA3 = try #require(engine.proposal(from: candidates, pageBoxSizeInPoints: a3Page))
        #expect(onA3.ratio.denominator == 200)
        #expect(onA3.pagePaperSize == .a3)
        #expect(onA3.ranked[0].paperSizeAgreement == .agrees)
        #expect(onA3.ranked[1].paperSizeAgreement == .disagrees)
        #expect(onA3.distinctRatios.map(\.denominator) == [200, 100])

        // The same line on the sheet it was drawn for must land the other way round.
        let onA1 = try #require(engine.proposal(from: candidates, pageBoxSizeInPoints: a1Page))
        #expect(onA1.ratio.denominator == 100)
        #expect(onA1.pagePaperSize == .a1)
        #expect(onA1.distinctRatios.map(\.denominator) == [100, 200])
    }

    @Test("Two ratios need the user's choice; one does not")
    func disagreementIsDeclared() throws {
        let dual = parser.candidates(inLine: "SKALA 1:100 (A1), 1:200 (A3)")
        let ambiguous = try #require(engine.proposal(from: dual, pageBoxSizeInPoints: a3Page))
        #expect(ambiguous.needsUserChoice)
        #expect(ambiguous.ranked.count == 2)

        let single = parser.candidates(inLine: "SKALA 1:100 (A1)")
        let settled = try #require(engine.proposal(from: single, pageBoxSizeInPoints: a1Page))
        #expect(settled.needsUserChoice == false)
        #expect(settled.distinctRatios.count == 1)
    }

    @Test("An unreadable sheet proposes nothing rather than falling back to 1:1")
    func nothingReadableProposesNothing() throws {
        #expect(engine.proposal(from: [], pageBoxSizeInPoints: a1Page) == nil)

        let noScale = parser.candidates(in: [
            RecognisedTextLine(text: "RITNINGSNUMMER A-40.1-101"),
            RecognisedTextLine(text: "DATUM 2026-03-14   UTSKRIFT 13:37")
        ])
        #expect(noScale.isEmpty)
        #expect(engine.proposal(from: noScale, pageBoxSizeInPoints: a1Page) == nil)

        // Contrast: the same sheet with a scale line does propose.
        let withScale = parser.candidates(in: [
            RecognisedTextLine(text: "RITNINGSNUMMER A-40.1-101"),
            RecognisedTextLine(text: "SKALA 1:100 (A1)")
        ])
        #expect(engine.proposal(from: withScale, pageBoxSizeInPoints: a1Page) != nil)
    }

    @Test("The proposal carries the notation confidence separately from the page-adjusted score")
    func confidenceAndScoreAreSeparate() throws {
        let candidates = parser.candidates(inLine: "SKALA 1:100 (A1), 1:200 (A3)")
        let onA3 = try #require(engine.proposal(from: candidates, pageBoxSizeInPoints: a3Page))
        // Both notations are written equally well; only the sheet separates them.
        #expect(onA3.notationConfidence == 1.0)
        #expect(onA3.ranked[0].candidate.confidence == onA3.ranked[1].candidate.confidence)
        #expect(onA3.ranked[0].score > onA3.ranked[1].score)
        #expect(abs(onA3.ranked[1].score - 0.8) < 1e-12)
    }

    @Test("The proposal's factor is the ratio's, converted once")
    func proposalCarriesTheFactor() throws {
        let candidates = parser.candidates(inLine: "SKALA 1:100")
        let proposal = try #require(engine.proposal(from: candidates, pageBoxSizeInPoints: a1Page))
        let inchInMetres = try #require(Decimal(string: "0.0254", locale: nil))
        #expect(abs(proposal.metresPerPoint - 0.0254 * 100 / 72) < 1e-12)
        #expect(proposal.metresPerPointExact == inchInMetres * 100 / 72)
        #expect(proposal.displayString == "1:100")
        #expect(proposal.evidence.matchedText == "1:100")
    }

    @Test("A page box that is no standard sheet leaves every hint unjudged")
    func unknownPaperLeavesHintsUnjudged() throws {
        let candidates = parser.candidates(inLine: "SKALA 1:100 (A1), 1:200 (A3)")
        let proposal = try #require(engine.proposal(from: candidates, pageBoxSizeInPoints: oddPage))
        #expect(proposal.pagePaperSize == nil)
        let allUnjudged = proposal.ranked.allSatisfy { $0.paperSizeAgreement == .unknown }
        #expect(allUnjudged)
        // With nothing to separate them, reading order decides, and it is stable.
        #expect(proposal.ratio.denominator == 100)
    }

    @Test("ISO sizes are identified in either orientation and not confused with their neighbours")
    func paperSizeIdentification() throws {
        #expect(ISOPaperSize.matching(boxSizeInPoints: a1Page) == .a1)
        #expect(ISOPaperSize.matching(
            boxSizeInPoints: PDFSizeValue(width: 2383.94, height: 1683.78)) == .a1)
        #expect(ISOPaperSize.matching(boxSizeInPoints: a3Page) == .a3)

        #expect(ISOPaperSize.matching(boxSizeInPoints: PDFSizeValue(width: 900, height: 1300)) == nil)
        #expect(ISOPaperSize.matching(boxSizeInPoints: PDFSizeValue(width: 0, height: 0)) == nil)
    }

    // MARK: - Real-world smoke

    @Test("A Swedish A1 general-arrangement title block proposes 1:100 and nothing else")
    func swedishTitleBlockOnA1() throws {
        let sheet = [
            "NYBYGGNAD FLERBOSTADSHUS",
            "KV. EXEMPLET 3, EXEMPELSTAD",
            "PLAN 2 — PLANRITNING",
            "SKALA 1:100 (A1)",
            "RITNINGSNUMMER A-40.1-101",
            "DATUM 2026-03-14   UTSKRIFT 13:37",
            "ANSVARIG: A. BERG",
            "BET  ÄNDRINGEN AVSER  DATUM  SIGN",
            "UPPDRAG 24-118"
        ].map { RecognisedTextLine(text: $0) }

        let candidates = parser.candidates(in: sheet)
        #expect(candidates.count == 1)
        let only = try #require(candidates.first)
        #expect(only.ratio.denominator == 100)
        #expect(only.hasExplicitPrefix)
        #expect(only.paperSizeHint == .a1)
        #expect(only.confidence == 1.0)

        let proposal = try #require(
            engine.proposal(forRecognisedLines: sheet, pageBoxSizeInPoints: a1Page)
        )
        #expect(proposal.displayString == "1:100")
        #expect(proposal.needsUserChoice == false)
        #expect(proposal.ranked[0].paperSizeAgreement == .agrees)
        #expect(abs(proposal.metresPerPoint - 0.0254 * 100 / 72) < 1e-12)
    }

    @Test("The same sheet reduced to A3 proposes 1:200, with 1:100 kept as the alternative")
    func swedishTitleBlockOnA3Reduction() throws {
        let sheet = [
            "SEKTION A-A",
            "KV. EXEMPLET 3, EXEMPELSTAD",
            "SKALA 1:100 (A1), 1:200 (A3)",
            "RITNINGSNUMMER A-41.2-204",
            "DATUM 2026-05-02   REV B",
            "GRANSKAD 2026-05-03 09:15"
        ].map { RecognisedTextLine(text: $0) }

        let proposal = try #require(
            engine.proposal(forRecognisedLines: sheet, pageBoxSizeInPoints: a3Page)
        )
        #expect(proposal.displayString == "1:200")
        #expect(proposal.needsUserChoice)
        #expect(proposal.ranked.count == 2)
        #expect(proposal.ranked[1].candidate.ratio.denominator == 100)
        #expect(abs(proposal.metresPerPoint - 0.0254 * 200 / 72) < 1e-12)
    }

    @Test("A detail sheet with no scale line and plenty of digits proposes nothing")
    func swedishTitleBlockWithoutAScale() throws {
        let sheet = [
            "DETALJ 12 — ANSLUTNING SOCKEL",
            "MÅTT I MM OM EJ ANNAT ANGES",
            "RITNINGSNUMMER K-20.3-014",
            "DATUM 2026-04-11   UTSKRIFT 08:05",
            // 031-390 06 00 to 06 99 is a range the Swedish telecom regulator reserves for fiction.
            "TEL 031-390 06 50",
            "GRANSKNING 2:1 ENLIGT PM"
        ].map { RecognisedTextLine(text: $0) }

        #expect(parser.candidates(in: sheet).isEmpty)
        #expect(engine.proposal(forRecognisedLines: sheet, pageBoxSizeInPoints: a3Page) == nil)
    }
}
