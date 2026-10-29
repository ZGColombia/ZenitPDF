import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// CR-45: the total order compared scores with `|a - b| <= epsilon`, which is not transitive,
/// so the comparator was not a strict weak ordering and `sort` could answer differently for
/// different input orders — the R-tree's traversal order, in practice.
@Suite("Snap total order (CR-45)")
struct SnapOrderTests {

    @Test("Scores within epsilon of each other order transitively: every input order ranks the same winner")
    func epsilonTiesAreTransitive() throws {
        let settings = SnapSettings.default
        let weights = SnapScoringWeights.standard
        let scorer = SnapScorer(settings: settings, weights: weights)
        let tolerance = try SnapTolerance(settings: settings, layout: SnapReplay.layout(zoom: 1))
        let cursor = PDFPoint(x: 0, y: 0)

        // Three endpoints along +x at distances 14, 14 + 1.4e-9 and 14 + 2.8e-9: with the
        // default weights (priority 3, half a unit per view point) their scores are 10,
        // 10 + 0.7ε and 10 + 1.4ε for ε = 1e-9. Their identifiers run against the score order.
        func scored(_ id: UInt64, _ distance: Double) -> ScoredSnapCandidate {
            scorer.score(
                SnapTarget(
                    kind: .endpoint, position: PDFPoint(x: distance, y: 0), primitiveID: id,
                    source: .pdfPathObject, confidence: 1, layerID: nil
                ),
                cursorPagePoint: cursor, tolerance: tolerance, activeLayerID: nil,
                satisfiesDirectionConstraint: true, heldCredit: 0
            )
        }
        let a = scored(3, 14)
        let b = scored(2, 14 + 1.4e-9)
        let c = scored(1, 14 + 2.8e-9)

        // Old output: `a ~ b` (0.7ε apart) fell through to identifiers, so b outranked a;
        // `b ~ c` likewise, so c outranked b; but `a` and `c` were 1.4ε apart, so a outranked
        // c — a cycle. Sorting [a, b, c] gave b first and sorting [c, b, a] gave c first.
        let permutations: [[ScoredSnapCandidate]] = [
            [a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]
        ]
        let winners = permutations.map { scorer.rank($0).first?.key.primitiveID }
        #expect(Set(winners.compactMap { $0 }).count == 1, "\(winners)" as Comment)
        // On the epsilon grid `a` sits alone in the lower cell; `b` and `c` share the next one
        // and are decided by identifier, so the order is a ≻ c ≻ b for every permutation.
        // (`rank` also de-duplicates by position, and these three points share one, so the
        // full order is read through the comparator itself.)
        #expect(winners.allSatisfy { $0 == 3 })
        #expect(permutations.allSatisfy {
            $0.sorted(by: scorer.outranks).map(\.key.primitiveID) == [3, 1, 2]
        })

        // Asymmetry and transitivity, spelled out.
        #expect(scorer.outranks(a, b) && !scorer.outranks(b, a))
        #expect(scorer.outranks(c, b) && !scorer.outranks(b, c))
        #expect(scorer.outranks(a, c) && !scorer.outranks(c, a))
    }

    @Test("Equal scores still fall through to the documented later keys")
    func equalScoresUseLaterKeys() throws {
        let settings = SnapSettings.default
        let scorer = SnapScorer(settings: settings, weights: .standard)
        let tolerance = try SnapTolerance(settings: settings, layout: SnapReplay.layout(zoom: 1))
        func scored(_ id: UInt64, _ x: Double) -> ScoredSnapCandidate {
            scorer.score(
                SnapTarget(
                    kind: .endpoint, position: PDFPoint(x: x, y: 0), primitiveID: id,
                    source: .pdfPathObject, confidence: 1, layerID: nil
                ),
                cursorPagePoint: .init(x: 0, y: 0), tolerance: tolerance, activeLayerID: nil,
                satisfiesDirectionConstraint: true, heldCredit: 0
            )
        }
        let left = scored(9, 5)
        let right = scored(4, -5)
        #expect(scorer.outranks(right, left), "same score, lower identifier wins")
        #expect(scorer.rank([left, right]).first?.key.primitiveID == 4)
    }
}
