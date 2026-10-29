import CoreGraphics
import Foundation
import Testing
import ZPDFCompare
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// The geometry signal.
///
/// What separates this from the raster signal is that it can *name* what happened: not
/// "these 1 888 pixels differ" but "this line moved by exactly (0, 40) points". Every
/// assertion below is about that naming being right.
struct VectorDiffTests {

    private func extract(_ url: URL) async throws -> VectorPageExtraction {
        try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
    }

    @Test("A page compared with itself has no geometry differences and every primitive unchanged")
    func selfComparisonHasNoGeometryDifferences() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let extraction = try await extract(pair.baselineURL)
        let outcome = try VectorDiffEngine.diff(
            baseline: extraction, revised: extraction, alignment: .identity
        )
        #expect(outcome.isMeaningful)
        #expect(outcome.differences.isEmpty)
        #expect(outcome.regions.isEmpty)
        #expect(outcome.unchangedCount == 6)
        #expect(outcome.baselinePrimitiveCount == 6)
        #expect(!outcome.wasTruncated)
    }

    @Test("A moved edge is named a move, with the exact translation, not two pixel clouds")
    func movedEdgeIsNamedAMove() async throws {
        let pair = try RevisionCorpus.make(.movedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let outcome = try VectorDiffEngine.diff(
            baseline: try await extract(pair.baselineURL),
            revised: try await extract(pair.revisedURL),
            alignment: .identity
        )
        #expect(outcome.differences.count == 1)
        #expect(outcome.unchangedCount == 5)
        let difference = try #require(outcome.differences.first)
        #expect(difference.kind == .moved)
        let translation = try #require(difference.detail.translation)
        #expect(abs(Double(translation.x) - RevisionCorpus.moveDelta.dx) < 1e-9)
        #expect(abs(Double(translation.y) - RevisionCorpus.moveDelta.dy) < 1e-9)
        #expect(difference.detail.baselinePrimitiveIDs.count == 1)
        #expect(difference.detail.revisedPrimitiveIDs.count == 1)
        #expect(difference.confidence == 1)
        // A move is reported as one `changed` region spanning both positions, so the UI
        // can frame the whole edit in one jump.
        let region = try #require(outcome.regions.first)
        #expect(region.classification == .changed)
        #expect(region.signal == .vector)
        let edge = try #require(pair.edge(RevisionCorpus.movedEdgeIdentifier))
        #expect(abs(Double(region.pageBounds.minY) - edge.y0) < 1e-9)
        #expect(abs(Double(region.pageBounds.maxY) - (edge.y0 + RevisionCorpus.moveDelta.dy)) < 1e-9)
    }

    @Test("An added edge and a deleted edge are named as such")
    func additionAndDeletionAreNamed() async throws {
        let added = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(added.directory) }
        let additionOutcome = try VectorDiffEngine.diff(
            baseline: try await extract(added.baselineURL),
            revised: try await extract(added.revisedURL),
            alignment: .identity
        )
        #expect(additionOutcome.addedCount == 1)
        #expect(additionOutcome.removedCount == 0)
        #expect(additionOutcome.unchangedCount == 6)
        let addition = try #require(additionOutcome.differences.first)
        #expect(addition.detail.baselinePrimitiveIDs.isEmpty)
        #expect(addition.detail.revisedPrimitiveIDs.count == 1)
        #expect(
            abs(Double(addition.bounds.minX) - RevisionCorpus.addedEdge.x0) < 1e-9,
            "\(describe(addition.bounds))"
        )

        let deleted = try RevisionCorpus.make(.deletedEdge)
        defer { RevisionCorpus.remove(deleted.directory) }
        let deletionOutcome = try VectorDiffEngine.diff(
            baseline: try await extract(deleted.baselineURL),
            revised: try await extract(deleted.revisedURL),
            alignment: .identity
        )
        #expect(deletionOutcome.removedCount == 1)
        #expect(deletionOutcome.addedCount == 0)
        #expect(deletionOutcome.unchangedCount == 5)
        let deletion = try #require(deletionOutcome.differences.first)
        #expect(deletion.detail.revisedPrimitiveIDs.isEmpty)
        #expect(deletion.kind.classification == .removed)
    }

    @Test("All three mutations are separated into one move, one addition and one removal")
    func allMutationsAreSeparated() async throws {
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }
        let outcome = try VectorDiffEngine.diff(
            baseline: try await extract(pair.baselineURL),
            revised: try await extract(pair.revisedURL),
            alignment: .identity
        )
        #expect(outcome.differences.count == 3)
        #expect(outcome.movedCount == 1)
        #expect(outcome.addedCount == 1)
        #expect(outcome.removedCount == 1)
        #expect(outcome.reshapedCount == 0)
        #expect(outcome.unchangedCount == 4)
        // CR-130: top of the sheet first. Page space is y-up, so that is *descending*
        // maxY — the old rule, ascending minY, walked up the sheet while the raster
        // engine's own list walked down it, and one "next difference" button steps
        // through both. This assertion is the CR-130 regression: on the old code it
        // records
        // `Expectation failed: (tops → [250.0, 450.0, 600.0]) == (tops.sorted(by: >) →
        // [600.0, 450.0, 250.0])`.
        let tops = outcome.differences.map { Double($0.bounds.maxY) }
        #expect(tops == tops.sorted(by: >))
    }

    @Test("An alignment is applied to the revised geometry before matching")
    func alignmentIsAppliedBeforeMatching() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let extraction = try await extract(pair.baselineURL)

        // Pretend the revision sits 40 pt higher on its own sheet, and hand the engine
        // the alignment that undoes that. Everything must come back unchanged.
        let shifted = AlignmentTransform.translation(dx: 0, dy: -40)
        let misaligned = try VectorDiffEngine.diff(
            baseline: extraction, revised: extraction, alignment: shifted
        )
        // Every edge moved by the same vector, so every one of them is a move.
        #expect(misaligned.movedCount == 6)
        #expect(misaligned.unchangedCount == 0)

        let corrected = try VectorDiffEngine.diff(
            baseline: extraction, revised: extraction, alignment: .identity
        )
        #expect(corrected.unchangedCount == 6)
        #expect(corrected.differences.isEmpty)
    }

    @Test("A page with no vector content reports isMeaningful false rather than inventing findings")
    func scannedPageIsNotMeaningful() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scan = try ZPDFFixtures.make(.scannedLookPage, in: directory)
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }

        let scanned = try await extract(scan.url)
        #expect(!scanned.availability.hasUsableGeometry)

        let outcome = try VectorDiffEngine.diff(
            baseline: scanned,
            revised: try await extract(pair.revisedURL),
            alignment: .identity
        )
        #expect(!outcome.isMeaningful)
        #expect(outcome.differences.isEmpty)
        #expect(outcome.regions.isEmpty)
        #expect(outcome.baselineAvailability == .unavailable(reason: .noVectorContent))
        #expect(outcome.revisedAvailability.hasUsableGeometry)
    }

    @Test("A page with more primitives than the budget is refused before any matching")
    func primitiveBudgetIsEnforced() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let extraction = try await extract(pair.baselineURL)
        #expect(throws: CompareFault.self) {
            try VectorDiffEngine.diff(
                baseline: extraction,
                revised: extraction,
                alignment: .identity,
                options: VectorDiffOptions(maximumPrimitivesPerPage: 3)
            )
        }
    }

    @Test("The stroke width tolerance separates a redrawn line weight from an unchanged line")
    func strokeWidthChangeIsAReshape() async throws {
        let box = try RevisionCorpus.mediaBox()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-weight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thin = [RevisionEdge("w", from: (100, 400), to: (400, 400), width: 2)]
        let thick = [RevisionEdge("w", from: (100, 400), to: (400, 400), width: 8)]
        let thinURL = directory.appendingPathComponent("thin.pdf")
        let thickURL = directory.appendingPathComponent("thick.pdf")
        try RevisionPDFWriter.data(mediaBox: box, edges: thin).write(to: thinURL)
        try RevisionPDFWriter.data(mediaBox: box, edges: thick).write(to: thickURL)

        let outcome = try VectorDiffEngine.diff(
            baseline: try await extract(thinURL),
            revised: try await extract(thickURL),
            alignment: .identity
        )
        // Same centre line, different weight: not "unchanged", and not a move either.
        #expect(outcome.unchangedCount == 0)
        #expect(outcome.reshapedCount == 1)
        let difference = try #require(outcome.differences.first)
        #expect(abs((difference.detail.strokeWidthDelta ?? 0) - 6) < 1e-9)
        // A judgement call, so it is discounted: 1.0 extractor confidence × 0.8.
        #expect(abs(difference.confidence - 0.8) < 1e-9)
    }
}
