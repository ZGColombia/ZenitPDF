import CoreGraphics
import Foundation
import Testing
import ZPDFCompare

/// Manual alignment through the whole pipeline: solve from picked points, warp the
/// revision, and check that the difference the misalignment was creating is gone.
///
/// A solver test proves the arithmetic. This proves the *plumbing* — that the transform
/// is applied in the right direction, in the right space, to the right raster. Getting
/// that wrong produces a plausible-looking list of differences that is entirely
/// fictional, which is the failure this package exists to avoid.
struct ManualAlignmentPipelineTests {

    static let offset = (dx: 24.0, dy: -16.0)

    @Test("An unaligned revision is a page full of differences")
    func misalignmentIsVisible() async throws {
        let pair = try RevisionCorpus.makeTranslated(dx: Self.offset.dx, dy: Self.offset.dy)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.compare(scale: 2)
        // Six edges, each shifted clear of its own ink. The pixel signal sees a crowd
        // of strips — some of which the grouping dilation merges, because a shifted
        // edge can land near its neighbour — and cannot tell any of them apart from a
        // real edit. That is precisely why the geometry signal exists beside it.
        #expect(result.rasterRegions.count >= 8)
        #expect(result.rasterRegions.allSatisfy { $0.signal == .raster })
        let vector = try #require(result.vector)
        #expect(vector.movedCount == 6)
    }

    @Test("Two picked point pairs recover the offset and the raster difference goes to zero")
    func twoPointAlignmentRemovesTheDifference() async throws {
        let pair = try RevisionCorpus.makeTranslated(dx: Self.offset.dx, dy: Self.offset.dy)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        // Two features a user would pick: the start of the first edge and the start of
        // the fourth, on the revision, matched to where they sit on the baseline.
        let picks = ["e0", "e3"].compactMap { identifier -> AlignmentCorrespondence? in
            guard let baselineEdge = pair.edge(identifier),
                  let revisedEdge = pair.edge(identifier, inBaseline: false) else { return nil }
            return AlignmentCorrespondence(
                source: CGPoint(x: revisedEdge.x0, y: revisedEdge.y0),
                target: CGPoint(x: baselineEdge.x0, y: baselineEdge.y0)
            )
        }
        #expect(picks.count == 2)

        let result = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline,
                revised: harness.revised,
                renderScale: 2,
                alignment: .manualTwoPoint(picks),
                raster: RasterDiffOptions(tolerance: .strict)
            )
        )
        #expect(result.alignment.provenance == .manualTwoPoint)
        #expect(result.alignment.residual.maximum < 1e-9)
        #expect(abs(result.alignment.transform.tx + Self.offset.dx) < 1e-9)
        #expect(abs(result.alignment.transform.ty + Self.offset.dy) < 1e-9)
        #expect(abs(result.alignment.scale - 1) < 1e-12)

        // The whole point: once aligned, the two sheets are the same drawing.
        #expect(result.rasterRegions.isEmpty, "\(result.rasterRegions.count) regions remained")
        #expect(result.rasterStatistics.differingPixelCount == 0)
        let vector = try #require(result.vector)
        #expect(vector.differences.isEmpty)
        #expect(vector.unchangedCount == 6)
    }

    @Test("Three picked point pairs do the same job through the affine solver")
    func threePointAlignmentRemovesTheDifference() async throws {
        let pair = try RevisionCorpus.makeTranslated(dx: Self.offset.dx, dy: Self.offset.dy)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let picks = ["e0", "e2", "e4"].compactMap { identifier -> AlignmentCorrespondence? in
            guard let baselineEdge = pair.edge(identifier),
                  let revisedEdge = pair.edge(identifier, inBaseline: false) else { return nil }
            return AlignmentCorrespondence(
                source: CGPoint(x: revisedEdge.x0, y: revisedEdge.y0),
                target: CGPoint(x: baselineEdge.x0, y: baselineEdge.y0)
            )
        }
        #expect(picks.count == 3)

        let result = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline,
                revised: harness.revised,
                renderScale: 2,
                alignment: .manualThreePoint(picks),
                raster: RasterDiffOptions(tolerance: .strict)
            )
        )
        #expect(result.alignment.provenance == .manualThreePoint)
        #expect(result.alignment.model == .affine)
        #expect(result.alignment.residual.maximum < 1e-9)
        #expect(result.rasterRegions.isEmpty, "\(result.rasterRegions.count) regions remained")
        let vector = try #require(result.vector)
        #expect(vector.differences.isEmpty)
    }

    @Test("An explicit transform is honoured, and a degenerate one is refused before rendering")
    func explicitAndDegenerateAlignments() async throws {
        let pair = try RevisionCorpus.makeTranslated(dx: Self.offset.dx, dy: Self.offset.dy)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline,
                revised: harness.revised,
                renderScale: 2,
                alignment: .explicit(
                    .translation(dx: -Self.offset.dx, dy: -Self.offset.dy)
                ),
                raster: RasterDiffOptions(tolerance: .strict)
            )
        )
        #expect(result.alignment.provenance == .explicit)
        #expect(result.rasterRegions.isEmpty)

        // A transform with a zero determinant cannot be inverted, so the revision cannot
        // be resampled into the baseline frame. That is a typed refusal, not a crash and
        // not a page of imaginary differences.
        await #expect(throws: CompareFault.self) {
            try await harness.comparator.compare(
                RevisionCompareRequest(
                    baseline: harness.baseline,
                    revised: harness.revised,
                    renderScale: 2,
                    alignment: .explicit(
                        AlignmentTransform(a: 1, b: 1, c: 1, d: 1, tx: 0, ty: 0)
                    )
                )
            )
        }
    }

    @Test("Two picks that are the same point are refused before anything is rendered")
    func degenerateManualPicksAreRefused() async throws {
        let pair = try RevisionCorpus.makeTranslated(dx: Self.offset.dx, dy: Self.offset.dy)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let duplicate = AlignmentCorrespondence(
            source: CGPoint(x: 100, y: 100), target: CGPoint(x: 76, y: 116)
        )
        await #expect(throws: CompareFault.self) {
            try await harness.comparator.compare(
                RevisionCompareRequest(
                    baseline: harness.baseline,
                    revised: harness.revised,
                    renderScale: 2,
                    alignment: .manualTwoPoint([duplicate, duplicate])
                )
            )
        }
    }
}
