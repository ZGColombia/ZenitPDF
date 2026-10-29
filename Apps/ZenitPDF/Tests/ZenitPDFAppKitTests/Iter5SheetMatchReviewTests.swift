import CoreGraphics
import Foundation
import Testing
import ZPDFCompare
@testable import ZenitPDFAppKit

/// Loop iteration 5, render-extract-search (V-081): the sheet match review corrects a pairing
/// through the engine's own rule — `SheetMatching.overriding` and `unpairing` — instead of a
/// second copy of it in the review model.
@MainActor
@Suite("Sheet match review follows the engine's correction rule (V-081)", .appTierSerialised)
struct Iter5SheetMatchReviewTests {

    private static let a1 = CGSize(width: 1683.78, height: 2383.94)
    private static let a3 = CGSize(width: 841.89, height: 1190.55)

    private static func sheets(_ labels: [(String, CGSize)]) -> [SetSheet] {
        labels.enumerated().map { SetSheet(index: $0.offset, label: $0.element.0, sizeInPoints: $0.element.1) }
    }

    private static func review(set: [(String, CGSize)], revision: [(String, CGSize)]) throws -> (SheetMatchReviewModel, SheetMatching) {
        let matching = try SheetMatcher.standard.match(old: sheets(set), new: sheets(revision))
        let model = SheetMatchReviewModel(
            revisionName: "Rev B",
            setSheets: set.enumerated().map { ("page-\($0.offset)", $0.element.0) },
            revisionLabels: revision.map(\.0),
            matching: matching
        )
        return (model, matching)
    }

    /// The review's rows, as (set index, partner, basis).
    private static func pairs(_ model: SheetMatchReviewModel) -> [String] {
        model.rows.map { "\($0.setIndex)→\($0.partner.map(String.init) ?? "-") \($0.basis?.rawValue ?? "none")" }
    }

    /// The engine's matching, in the same shape.
    private static func pairs(_ matching: SheetMatching, setCount: Int) -> [String] {
        (0..<setCount).map { index in
            let partner = matching.newIndex(forOldIndex: index)
            let basis = partner.flatMap { matching.basis(oldIndex: index, newIndex: $0) }
            return "\(index)→\(partner.map(String.init) ?? "-") \(basis?.rawValue ?? "none")"
        }
    }

    @Test("A correction displaces both former partners exactly as the engine's override does")
    func correctionMatchesTheEngine() throws {
        let (model, matching) = try Self.review(
            set: [("A-101", Self.a1), ("A-102", Self.a1), ("A-103", Self.a1), ("A-900", Self.a3)],
            revision: [("A-101", Self.a1), ("A-102-B", Self.a1), ("A-103", Self.a1), ("A-104", Self.a1)]
        )
        #expect(model.guessedRows.map(\.setIndex) == [1], "A-102 ↔ A-102-B is a guess")

        // Set A-101 is really revision A-102-B.
        model.setPartner(1, forSetIndex: 0)

        let engine = try matching.overriding(pairOldIndex: 0, newIndex: 1)
        #expect(Self.pairs(model) == Self.pairs(engine, setCount: 4))
        // By hand: 0→1 manual; A-102 and A-900 are left without a partner; A-103 keeps its
        // exact pair; revision pages 0 (A-101) and 3 (A-104) are added.
        #expect(Self.pairs(model) == ["0→1 manualOverride", "1→- none", "2→2 exactLabel", "3→- none"])
        #expect(model.addedRevisionPages == [0, 3])
        #expect(model.removedSheets.map(\.setIndex) == [1, 3])
        #expect(model.guessedRows.isEmpty)
        #expect(model.matching == engine)

        // "None" unpairs, as the engine's unpairing does.
        model.setPartner(nil, forSetIndex: 2)
        #expect(model.matching == (try engine.unpairing(oldIndex: 2)))
        #expect(model.addedRevisionPages == [0, 2, 3])
    }

    @Test("A matching the matcher refused to build still takes corrections over the review's sheets")
    func refusedMatchingIsCovered() throws {
        let model = SheetMatchReviewModel(
            revisionName: "Rev B",
            setSheets: [("p0", "A-101"), ("p1", "A-102")],
            revisionLabels: ["A-101", "A-102"],
            matching: .empty
        )
        #expect(model.rows.allSatisfy { $0.partner == nil })
        #expect(model.addedRevisionPages == [0, 1])
        #expect(model.removedSheets.count == 2)

        model.setPartner(1, forSetIndex: 0)
        #expect(Self.pairs(model) == ["0→1 manualOverride", "1→- none"])
        #expect(model.addedRevisionPages == [0])
    }

    /// Old output: the row's partner became 9, a page the revision does not have;
    /// `pairings(revisionID:)` never emits a page past the revision's last, so the set sheet
    /// silently lost the pairing it had.
    @Test("A revision page the review does not list is refused, and the pairing it would replace stays")
    func unknownRevisionPageIsRefused() throws {
        let (model, _) = try Self.review(set: [("A-101", Self.a1)], revision: [("A-101", Self.a1)])
        model.setPartner(9, forSetIndex: 0)
        #expect(Self.pairs(model) == ["0→0 exactLabel"])
        #expect(model.pairings(revisionID: "r").map(\.pageId) == ["page-0"])
    }
}
