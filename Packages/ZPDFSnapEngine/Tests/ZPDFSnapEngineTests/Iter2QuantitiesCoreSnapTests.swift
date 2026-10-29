import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFSnapEngine

/// Quality-loop iteration 2, area "quantities-core": snap finding S-113.
@Suite("Iteration 2 quantities-core (snap)")
struct Iter2QuantitiesCoreSnapTests {

    struct Keys {
        var score = 1.0
        var priority = 1
        var primitiveID: UInt64 = 1
        var secondaryPrimitiveID: UInt64 = 1
        var kind: SnapKind = .endpoint
        var x = 10.0
        var y = 20.0
        var component = 0
    }

    static func candidate(_ keys: Keys) -> ScoredSnapCandidate {
        let position = PDFPoint(x: keys.x, y: keys.y)
        return ScoredSnapCandidate(
            candidate: SnapCandidate(
                kind: keys.kind,
                position: position,
                primitiveID: keys.primitiveID,
                source: .pdfPathObject,
                screenDistancePixels: 0,
                score: keys.score
            ),
            key: SnapCandidateKey(
                kind: keys.kind,
                primitiveID: keys.primitiveID,
                secondaryPrimitiveID: keys.secondaryPrimitiveID,
                position: position,
                component: keys.component
            ),
            priority: keys.priority,
            rawScore: keys.score,
            secondaryPrimitiveID: keys.secondaryPrimitiveID,
            guide: .none
        )
    }

    /// S-113: the eight keys of the S1 total order are written once (`SnapScorer.precedes`) and
    /// both the reference `outranks` and the production `rank(_:limit:)` go through it. Each
    /// pair below ties on every key but one, so a key missing from either path would let the
    /// input order pick the winner. Hand-derived winners: the lower value of the one differing
    /// key; for the kind, `endpoint` < `midpoint` by raw value.
    @Test("S-113: outranks and rank(_:limit:) apply the same eight keys in the same order")
    func oneTotalOrder() {
        let scorer = SnapScorer(settings: .default, weights: .standard)
        var pairs: [(name: String, winner: Keys, loser: Keys)] = []
        let winner = Keys()
        var loser = Keys()
        loser.score = 2
        pairs.append(("score", winner, loser))
        loser = Keys(); loser.priority = 2
        pairs.append(("priority", winner, loser))
        loser = Keys(); loser.primitiveID = 2
        pairs.append(("primitiveID", winner, loser))
        loser = Keys(); loser.secondaryPrimitiveID = 2
        pairs.append(("secondaryPrimitiveID", winner, loser))
        loser = Keys(); loser.kind = .midpoint
        pairs.append(("kind", winner, loser))
        loser = Keys(); loser.x = 11
        pairs.append(("x", winner, loser))
        loser = Keys(); loser.y = 21
        pairs.append(("y", winner, loser))
        loser = Keys(); loser.component = 1
        pairs.append(("component", winner, loser))

        for pair in pairs {
            let a = Self.candidate(pair.winner)
            let b = Self.candidate(pair.loser)
            #expect(scorer.outranks(a, b), "outranks, key \(pair.name)" as Comment)
            #expect(!scorer.outranks(b, a), "outranks reversed, key \(pair.name)" as Comment)
            for input in [[a, b], [b, a]] {
                #expect(scorer.rank(input, limit: 1).first == a, "rank(limit:), key \(pair.name)" as Comment)
                #expect(scorer.rank(input).first == a, "rank, key \(pair.name)" as Comment)
            }
        }
        // Scores inside one epsilon cell tie and fall through to the next key (priority here).
        var nearA = Keys()
        nearA.priority = 1
        var nearB = Keys()
        nearB.score = 1 + 1e-15
        nearB.priority = 0
        let a = Self.candidate(nearA)
        let b = Self.candidate(nearB)
        #expect(scorer.quantizedScore(1) == scorer.quantizedScore(1 + 1e-15))
        #expect(scorer.outranks(b, a))
        #expect(scorer.rank([a, b], limit: 1).first == b)
    }
}
