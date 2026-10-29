import CoreGraphics
import Foundation
import Testing
import ZPDFCompare

/// Matching sheets between two whole sets, before a single page is rendered.
///
/// Every expectation below is derived by hand from the rule, not from a run. The feature
/// this supports says a guessed pairing must never be silent, so the assertions are as
/// much about the *basis* of each pair as about the pairing itself: a test that only
/// checked which sheets got paired would pass just as happily on an engine that guessed
/// every one of them.
struct SheetMatcherTests {

    // ARCH sheets are big; ISO A1 and A3 in PDF points, which is what a real set carries.
    private static let a1 = CGSize(width: 1683.78, height: 2383.94)
    private static let a3 = CGSize(width: 841.89, height: 1190.55)

    private func sheet(_ index: Int, _ label: String, _ size: CGSize = a1) -> SetSheet {
        SetSheet(index: index, label: label, sizeInPoints: size)
    }

    // MARK: - The label rules, on their own

    @Test("Canonical folds case, trims and collapses internal whitespace, and nothing else")
    func canonicalRule() {
        #expect(SheetLabel.canonical("  A-101  ") == "a-101")
        #expect(SheetLabel.canonical("A-101") == "a-101")
        #expect(SheetLabel.canonical("A  -  105") == "a - 105")
        #expect(SheetLabel.canonical(" a - 105 ") == "a - 105")
        #expect(SheetLabel.canonical("M-3.02") == "m-3.02")
        // Punctuation survives. Two drawings that differ only by a dot are two drawings.
        #expect(SheetLabel.canonical("A-101") != SheetLabel.canonical("A.101"))
    }

    @Test("A trailing single-letter revision suffix is stripped; a digit is not, and two letters are not")
    func revisionSuffixRule() {
        // The documented case: A-101-B is revision B of A-101.
        #expect(SheetLabel.stem("A-101-B") == "a-101")
        #expect(SheetLabel.stem("A-101-b") == "a-101")
        #expect(SheetLabel.stem("A-102 rev C") == "a-102")
        #expect(SheetLabel.stem("A-102 REV C") == "a-102")
        #expect(SheetLabel.stem(" A-102   rev   c ") == "a-102")

        // The trap this rule has to avoid: A-1013 is a sheet number, not A-101 revision 3.
        #expect(SheetLabel.stem("A-1013") == "a-1013")
        #expect(SheetLabel.stem("A-101") == "a-101")
        // Two letters is not one letter.
        #expect(SheetLabel.stem("A-101-BB") == "a-101-bb")
        #expect(SheetLabel.stem("A-101 rev BB") == "a-101 rev bb")
        // A label that is only a suffix keeps itself: an empty stem would match every
        // other empty stem in the set.
        #expect(SheetLabel.stem("-B") == "-b")
        #expect(SheetLabel.stem("rev B") == "rev b")
        // At most one strip.
        #expect(SheetLabel.stem("A-101-B-C") == "a-101-b")
    }

    // MARK: - Rule 1: exact label

    @Test("Reordering a set does not lose a sheet: every pair is exact, by label not by index")
    func exactMatchAcrossReorderedSets() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-102"), sheet(2, "A-103")]
        let new = [sheet(0, "A-103"), sheet(1, "A-101"), sheet(2, "A-102")]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.pairs.count == 3)
        #expect(matching.pairs.allSatisfy { $0.basis == .exactLabel })
        #expect(matching.newIndex(forOldIndex: 0) == 1)
        #expect(matching.newIndex(forOldIndex: 1) == 2)
        #expect(matching.newIndex(forOldIndex: 2) == 0)
        #expect(matching.addedInNew.isEmpty)
        #expect(matching.removedFromOld.isEmpty)
        #expect(!matching.isAmbiguous)
        #expect(matching.guessedPairs.isEmpty)
        #expect(matching.isWellFormed)
    }

    // MARK: - Rule 2: normalised label

    @Test("A renamed sheet pairs on the normalised label, in each of the rule's three forms")
    func renamedSheetsPairOnNormalisedLabel() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-102"), sheet(2, "A  -  105")]
        let new = [sheet(0, "A-101-B"), sheet(1, "A-102 rev C"), sheet(2, " a - 105 ")]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.pairs.count == 3)
        // -B is revision B of A-101; " rev C" is revision C of A-102; the third is the
        // same label typed differently.
        #expect(matching.basis(oldIndex: 0, newIndex: 0) == .normalisedLabel)
        #expect(matching.basis(oldIndex: 1, newIndex: 1) == .normalisedLabel)
        #expect(matching.basis(oldIndex: 2, newIndex: 2) == .normalisedLabel)
        #expect(matching.addedInNew.isEmpty)
        #expect(matching.removedFromOld.isEmpty)
        #expect(!matching.isAmbiguous)
        // Normalised is still a guess, and says so.
        #expect(matching.guessedPairs.count == 3)
        #expect(matching.isWellFormed)
    }

    @Test("An old set that already has A-101-B keeps it: the exact match wins over the suffix rule")
    func exactMatchBeatsTheSuffixRule() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-101-B")]
        let new = [sheet(0, "A-101-B"), sheet(1, "A-101")]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.basis(oldIndex: 0, newIndex: 1) == .exactLabel)
        #expect(matching.basis(oldIndex: 1, newIndex: 0) == .exactLabel)
        #expect(matching.guessedPairs.isEmpty)
        #expect(matching.isWellFormed)
    }

    @Test("A-1013 is not A-101 revision 3: any pairing between them is a positional guess")
    func trailingDigitIsNotARevisionSuffix() throws {
        // Same paper, so the positional fallback can still reach them — and the point is
        // that it is the *fallback* that does, tagged as a guess, not the label rule.
        let sameSize = try SheetMatcher.match(old: [sheet(0, "A-101")], new: [sheet(0, "A-1013")])
        #expect(sameSize.pairs.count == 1)
        #expect(sameSize.pairs[0].basis == .positionFallback)
        #expect(sameSize.pairs[0].basis != .normalisedLabel)
        #expect(sameSize.pairs[0].basis.isGuess)

        // Different paper, and there is no pairing at all.
        let differentSize = try SheetMatcher.match(
            old: [sheet(0, "A-101", Self.a1)], new: [sheet(0, "A-1013", Self.a3)]
        )
        #expect(differentSize.pairs.isEmpty)
        #expect(differentSize.removedFromOld == [0])
        #expect(differentSize.addedInNew == [0])
    }

    @Test("Two candidate revisions of one sheet are not silently narrowed to the first")
    func competingRevisionSuffixesAreNotPickedFrom() throws {
        let old = [sheet(0, "A-101")]
        let new = [sheet(0, "A-101-B"), sheet(1, "A-101-C")]

        let matching = try SheetMatcher.match(old: old, new: new)

        // Both new stems are "a-101", so the suffix rule refuses. What is left is a
        // positional guess over one old sheet and two new ones.
        #expect(matching.pairs.count == 1)
        #expect(matching.pairs[0].basis == .positionFallback)
        #expect(matching.pairs[0].basis != .normalisedLabel)
        #expect(matching.addedInNew == [1])
        #expect(matching.isWellFormed)
    }

    // MARK: - Rule 3 and ambiguity

    @Test("Duplicate labels are never paired by label: positional fallback, and the whole matching is ambiguous")
    func duplicateLabelsAreAmbiguousAndFallBackToPosition() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-101"), sheet(2, "A-200")]
        let new = [sheet(0, "A-101"), sheet(1, "A-101"), sheet(2, "A-200")]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.isAmbiguous)
        #expect(matching.ambiguousLabels == ["a-101"])
        #expect(matching.pairs.count == 3)
        // The duplicated pair are paired on position and paper size only, even though
        // their labels are byte-identical — identical labels that repeat are evidence of
        // nothing.
        #expect(matching.basis(oldIndex: 0, newIndex: 0) == .positionFallback)
        #expect(matching.basis(oldIndex: 1, newIndex: 1) == .positionFallback)
        // The one label that does not repeat is still an exact match.
        #expect(matching.basis(oldIndex: 2, newIndex: 2) == .exactLabel)
        #expect(matching.guessedPairs.count == 2)
        #expect(matching.isWellFormed)
    }

    @Test("A duplicate on one side alone still makes the matching ambiguous")
    func duplicateOnOneSideIsEnough() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-102")]
        let new = [sheet(0, "A-101"), sheet(1, "A-101")]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.isAmbiguous)
        #expect(matching.ambiguousLabels == ["a-101"])
        // Old A-101 cannot exact-match either new A-101, because neither new sheet is
        // distinct. Both pairs are positional.
        #expect(matching.pairs.count == 2)
        #expect(matching.pairs.allSatisfy { $0.basis == .positionFallback })
        #expect(matching.isWellFormed)
    }

    @Test("Trailing whitespace makes two labels the same label, so the pair is ambiguous, not exact")
    func canonicalDuplicatesCountAsDuplicates() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-101 ")]
        let new = [sheet(0, "A-101"), sheet(1, "A-102")]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.isAmbiguous)
        #expect(matching.ambiguousLabels == ["a-101"])
        // Neither old sheet is distinct, so the exact-label rule is not allowed to claim
        // new A-101 for the one whose string happens to match.
        #expect(matching.pairs.allSatisfy { $0.basis == .positionFallback })
        #expect(matching.isWellFormed)
    }

    @Test("The positional fallback refuses two different paper sizes")
    func positionalFallbackRequiresTheSamePaper() throws {
        let old = [sheet(0, "Site plan", Self.a1)]
        let new = [sheet(0, "Location plan", Self.a3)]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.pairs.isEmpty)
        #expect(matching.removedFromOld == [0])
        #expect(matching.addedInNew == [0])
    }

    @Test("A page box that differs by rounding is the same paper")
    func positionalFallbackAbsorbsRounding() throws {
        let old = [sheet(0, "Site plan", CGSize(width: 841.89, height: 1190.55))]
        let new = [sheet(0, "Location plan", CGSize(width: 841.8898, height: 1190.5512))]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.pairs.count == 1)
        #expect(matching.pairs[0].basis == .positionFallback)
    }

    // MARK: - Added and removed

    @Test("A set with a renamed sheet, an added sheet and a removed sheet is reported as all three")
    func renamedAddedAndRemovedAreAllReported() throws {
        let old = [
            sheet(0, "A-101"),          // unchanged label
            sheet(1, "A-102"),          // renamed to A-102-B
            sheet(2, "A-103"),          // unchanged label
            sheet(3, "A-900", Self.a3)  // removed
        ]
        let new = [
            sheet(0, "A-101"),
            sheet(1, "A-102-B"),
            sheet(2, "A-103"),
            sheet(3, "A-104")           // added
        ]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.pairs.count == 3)
        #expect(matching.basis(oldIndex: 0, newIndex: 0) == .exactLabel)
        #expect(matching.basis(oldIndex: 1, newIndex: 1) == .normalisedLabel)
        #expect(matching.basis(oldIndex: 2, newIndex: 2) == .exactLabel)
        #expect(matching.addedInNew == [3])
        #expect(matching.removedFromOld == [3])
        #expect(!matching.isAmbiguous)
        #expect(matching.isWellFormed)
    }

    @Test("An inserted sheet renumbers the set without breaking the matching")
    func insertedSheetDoesNotShiftTheMatching() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-102"), sheet(2, "A-103")]
        let new = [
            sheet(0, "A-101"), sheet(1, "A-101a"), sheet(2, "A-102"), sheet(3, "A-103")
        ]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.newIndex(forOldIndex: 1) == 2)
        #expect(matching.newIndex(forOldIndex: 2) == 3)
        #expect(matching.pairs.allSatisfy { $0.basis == .exactLabel })
        #expect(matching.addedInNew == [1])
        #expect(matching.removedFromOld.isEmpty)
        #expect(matching.isWellFormed)
    }

    // MARK: - Correcting a guess

    @Test("An override moves a pair and hands both displaced sheets back to added and removed")
    func overrideDisplacesBothFormerPartners() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-102"), sheet(2, "A-103"), sheet(3, "A-900", Self.a3)]
        let new = [sheet(0, "A-101"), sheet(1, "A-102-B"), sheet(2, "A-103"), sheet(3, "A-104")]
        let matching = try SheetMatcher.match(old: old, new: new)

        // Say old A-101 is really new A-102-B. Old A-101's former partner (new 0) and new
        // A-102-B's former partner (old 1) both go back to unmatched — they are not
        // quietly paired with each other.
        let corrected = try matching.overriding(pairOldIndex: 0, newIndex: 1)

        #expect(corrected.pairs.count == 2)
        #expect(corrected.basis(oldIndex: 0, newIndex: 1) == .manualOverride)
        #expect(corrected.basis(oldIndex: 2, newIndex: 2) == .exactLabel)
        #expect(corrected.addedInNew == [0, 3])
        #expect(corrected.removedFromOld == [1, 3])
        #expect(!corrected.pairs[0].basis.isGuess)
        #expect(corrected.isWellFormed)
        // The labels in the two sets have not changed, so neither has the ambiguity flag.
        #expect(corrected.isAmbiguous == matching.isAmbiguous)
    }

    @Test("An override can pair a sheet the engine refused to guess at, emptying added and removed")
    func overrideCanPairWhatTheEngineLeftAlone() throws {
        let old = [sheet(0, "A-101"), sheet(1, "A-900", Self.a3)]
        let new = [sheet(0, "A-101"), sheet(1, "A-104")]
        let matching = try SheetMatcher.match(old: old, new: new)
        #expect(matching.removedFromOld == [1])
        #expect(matching.addedInNew == [1])

        let corrected = try matching.overriding(pairOldIndex: 1, newIndex: 1)

        #expect(corrected.pairs.count == 2)
        #expect(corrected.basis(oldIndex: 1, newIndex: 1) == .manualOverride)
        #expect(corrected.addedInNew.isEmpty)
        #expect(corrected.removedFromOld.isEmpty)
        #expect(corrected.isWellFormed)
    }

    @Test("Confirming a pairing the engine guessed records that a person confirmed it")
    func overrideOfAnExistingPairBecomesManual() throws {
        let matching = try SheetMatcher.match(
            old: [sheet(0, "A-101")], new: [sheet(0, "A-101-B")]
        )
        #expect(matching.pairs[0].basis == .normalisedLabel)

        let confirmed = try matching.overriding(pairOldIndex: 0, newIndex: 0)

        #expect(confirmed.pairs.count == 1)
        #expect(confirmed.pairs[0].basis == .manualOverride)
        #expect(!confirmed.pairs[0].basis.isGuess)
        #expect(confirmed.isWellFormed)
    }

    @Test("Unpairing returns both sheets to unmatched")
    func unpairingReturnsBothSheets() throws {
        let matching = try SheetMatcher.match(
            old: [sheet(0, "A-101")], new: [sheet(0, "A-1013")]
        )
        #expect(matching.pairs.count == 1)

        let split = try matching.unpairing(oldIndex: 0)

        #expect(split.pairs.isEmpty)
        #expect(split.removedFromOld == [0])
        #expect(split.addedInNew == [0])
        #expect(split.isWellFormed)
    }

    @Test("An override naming a sheet the matching does not have is refused, not ignored")
    func overrideRefusesAnUnknownIndex() throws {
        let matching = try SheetMatcher.match(
            old: [sheet(0, "A-101")], new: [sheet(0, "A-101")]
        )

        #expect(!matching.canOverride(pairOldIndex: 9, newIndex: 0))
        #expect(!matching.canOverride(pairOldIndex: 0, newIndex: 9))
        #expect(matching.canOverride(pairOldIndex: 0, newIndex: 0))
        #expect(throws: SheetMatchingFault.unknownOldSheet(index: 9)) {
            try matching.overriding(pairOldIndex: 9, newIndex: 0)
        }
        #expect(throws: SheetMatchingFault.unknownNewSheet(index: 9)) {
            try matching.overriding(pairOldIndex: 0, newIndex: 9)
        }
    }

    // MARK: - Edges

    @Test("Two empty sets produce an empty matching rather than anything at all")
    func emptySetsBehave() throws {
        let both = try SheetMatcher.match(old: [], new: [])
        #expect(both.pairs.isEmpty)
        #expect(both.addedInNew.isEmpty)
        #expect(both.removedFromOld.isEmpty)
        #expect(!both.isAmbiguous)
        #expect(both.ambiguousLabels.isEmpty)
        #expect(both.isWellFormed)
        #expect(both == SheetMatching.empty)

        let firstIssue = try SheetMatcher.match(old: [], new: [sheet(0, "A-101"), sheet(1, "A-102")])
        #expect(firstIssue.pairs.isEmpty)
        #expect(firstIssue.addedInNew == [0, 1])
        #expect(firstIssue.removedFromOld.isEmpty)
        #expect(firstIssue.isWellFormed)

        let withdrawn = try SheetMatcher.match(old: [sheet(0, "A-101")], new: [])
        #expect(withdrawn.pairs.isEmpty)
        #expect(withdrawn.addedInNew.isEmpty)
        #expect(withdrawn.removedFromOld == [0])
        #expect(withdrawn.isWellFormed)
    }

    @Test("Empty labels on both sides are duplicates, not a match")
    func emptyLabelsAreTreatedAsDuplicates() throws {
        let old = [sheet(0, ""), sheet(1, "   ")]
        let new = [sheet(0, ""), sheet(1, "A-101")]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.isAmbiguous)
        #expect(matching.ambiguousLabels == [""])
        #expect(matching.pairs.allSatisfy { $0.basis == .positionFallback })
        #expect(matching.isWellFormed)
    }

    @Test("A set that repeats a page index is refused rather than losing a sheet")
    func duplicateSheetIndexIsRefused() {
        #expect(throws: SheetMatchingFault.duplicateSheetIndex(side: .old, index: 1)) {
            try SheetMatcher.match(
                old: [sheet(0, "A-101"), sheet(1, "A-102"), sheet(1, "A-103")],
                new: [sheet(0, "A-101")]
            )
        }
        #expect(throws: SheetMatchingFault.duplicateSheetIndex(side: .new, index: 0)) {
            try SheetMatcher.match(
                old: [sheet(0, "A-101")],
                new: [sheet(0, "A-101"), sheet(0, "A-102")]
            )
        }
    }

    @Test("Sheet indices need not be contiguous or start at zero")
    func nonContiguousIndicesSurvive() throws {
        // A-101 is A3 and A-103 is A1, so the positional fallback cannot reach across the
        // one sheet that has no label counterpart.
        let old = [sheet(4, "A-101", Self.a3), sheet(9, "A-102")]
        let new = [sheet(11, "A-102"), sheet(12, "A-103")]

        let matching = try SheetMatcher.match(old: old, new: new)

        #expect(matching.pairs == [SheetPair(old: 9, new: 11, basis: .exactLabel)])
        #expect(matching.removedFromOld == [4])
        #expect(matching.addedInNew == [12])
        #expect(matching.oldSheetIndices == [4, 9])
        #expect(matching.newSheetIndices == [11, 12])
        #expect(matching.isWellFormed)
    }
}
