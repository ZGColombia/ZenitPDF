import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Iteration 3: wall midlines on either side of the angle seam merge
/// (T-064), a clipped or partly hidden CAD block drawing is rejected rather than dropped
/// (T-066), and a repeated-sheet signature keeps a sample count, not the samples (T-068).
@Suite("Iter3 walls, exact blocks and sheet signatures")
struct Iter3WallBlockSheetTests {

    private static func segment(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> GeometryQuerySegment {
        GeometryQuerySegment(primitiveID: id, sourceObjectID: id, start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1), strokeWidth: 0.5)
    }

    // MARK: T-064

    /// One horizontal 200 mm wall at 100 pt/m: faces at y = 100 and y = 120, drawn in three
    /// pieces whose coordinates carry CAD noise of a few ten-thousandths of a point.
    ///
    /// - A: x 0…400, rising (slope +1e-6).
    /// - door, 90 pt (0.90 m): wider than 1.5 × 20 = 30 pt, so an opening.
    /// - B: x 490…700, falling (slope −9.5e-7), drawn right to left.
    /// - junction, 20 pt: within 30 pt, so closed.
    /// - C: x 720…1000, rising (slope +1.07e-6).
    ///
    /// Hand takeoff: runs 0…400 and 490…1000, **910 pt = 9.10 m**, one opening of **90 pt**
    /// centred at x = 445.
    private static func noisyWall() -> [GeometryQuerySegment] {
        [
            segment(1, 0, 100, 400, 100.0004), segment(2, 0, 120, 400, 120.0004),
            segment(3, 700, 100.0002, 490, 100.0004), segment(4, 700, 120.0002, 490, 120.0004),
            segment(5, 720, 100.0002, 1_000, 100.0005), segment(6, 720, 120.0002, 1_000, 120.0005),
        ]
    }

    @Test("T-064: a horizontal wall whose pieces tilt either way by 1e-6 is one line: the door is listed and the junction closed")
    func noisyHorizontalWallIsOneLine() throws {
        let takeoff = WallCentrelineEngine(segments: Self.noisyWall(), options: .calibrated(pointsPerMetre: 100)).takeoff()
        #expect(!takeoff.isTruncated)
        #expect(takeoff.classes.count == 1)
        let wall = try #require(takeoff.classes.first)
        #expect(abs(wall.thicknessPoints - 20) < 0.01)
        // Old output: A and C (rising, angle +ε, offset +110) formed one line and B (falling,
        // angle π − ε, offset −110 against its flipped normal) another: three runs of 400, 210
        // and 280 = 890 pt, and one "opening" of 320 pt at x = 560 where the wall is solid.
        #expect(abs(wall.lengthPoints - 910) < 1e-3, "hand takeoff 910 pt, got \(wall.lengthPoints)")
        #expect(wall.centrelines.count == 2, "\(wall.centrelines)")
        #expect(wall.openings.count == 1, "\(wall.openings)")
        let door = try #require(wall.openings.first)
        #expect(abs(door.widthPoints - 90) < 1e-3)
        #expect(abs(door.midpoint.x - 445) < 1e-3 && abs(door.midpoint.y - 110) < 1e-3)
        for run in wall.centrelines {
            #expect(run.allSatisfy { abs($0.y - 110) < 1e-3 }, "on the wall's centreline")
        }
    }

    @Test("T-064: merge() groups midlines across the 0 ≡ π seam and keeps a parallel line one wall away apart")
    func mergeAcrossTheSeam() {
        let engine = WallCentrelineEngine(segments: [], options: .calibrated(pointsPerMetre: 100))
        typealias Piece = WallCentrelineEngine.Piece
        let pieces = [
            Piece(start: CGPoint(x: 0, y: 110), end: CGPoint(x: 400, y: 110.0004)),          // angle +1e-6
            Piece(start: CGPoint(x: 700, y: 110.0002), end: CGPoint(x: 490, y: 110.0004)),   // angle π − 9.5e-7
            Piece(start: CGPoint(x: 720, y: 110.0002), end: CGPoint(x: 1_000, y: 110.0005)), // angle +1.07e-6
            // A wall 30 pt away, parallel: never the same line.
            Piece(start: CGPoint(x: 0, y: 140), end: CGPoint(x: 400, y: 140)),
        ]
        let (merged, openings) = engine.merge(pieces, thickness: 20)
        // Old output: 4 pieces (0…400 with 720…1000 split by a 320 pt "opening", 490…700 alone,
        // and the parallel wall) and openings [320 pt].
        let lengths = merged.map { ($0.length * 1_000).rounded() / 1_000 }.sorted()
        #expect(lengths == [400, 400, 510], "\(lengths)")
        #expect(openings.map { ($0.widthPoints * 1_000).rounded() / 1_000 } == [90])
    }

    // MARK: T-066

    /// The door block of ``ExactBlockTests`` drawn four times at (60, 100), (160, 100),
    /// (260, 100) and (360, 100). The first drawing sits inside a clip `x ≤ 70`, which leaves its
    /// far stop (80,100)–(80,106) wholly outside, so the extractor drops it: that drawing has 2
    /// primitives, the others 3.
    private static let clippedPlacements = [
        "0 0 70 842 re W n 1 0 0 1 60 100", "1 0 0 1 160 100", "1 0 0 1 260 100", "1 0 0 1 360 100",
    ]

    @Test("T-066: a block drawing that lost a primitive to a clip is rejected as partial, never dropped")
    func clippedDrawingIsRejected() async throws {
        let url = try ExactBlockTests.writePDF(placements: Self.clippedPlacements, useForm: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        // Precondition: the clip really removed one primitive from the first drawing.
        let invocations = try #require(extraction.formInvocations)
        #expect(invocations.map(\.primitiveCount) == [2, 3, 3, 3])

        // The exemplar is the second, whole drawing: 160…180 × 100…112.
        let exemplar = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 155, minY: 95, maxX: 185, maxY: 117)
        )
        let report = try #require(ExactBlockMatcher.matches(exemplar: exemplar, extraction: extraction, visible: extraction.primitives))
        #expect(report.confirmed.count == 3)
        // Old output: rejected [] and candidateCount 3 — the clipped door was nowhere in the report.
        #expect(report.rejected.count == 1)
        #expect(report.candidateCount == 4)
        let clipped = try #require(report.rejected.first)
        // A drawing of the block itself, 2 of its 3 strokes showing — not `.partialOverlap`, which
        // the review files among the shapes that did not resemble the symbol (iter3 re-fix).
        #expect(clipped.reason == .partialBlock(visible: 2, total: 3))
        let firstDrawing = extraction.primitives[invocations[0].primitiveRange].map(\.id).sorted()
        #expect(clipped.primitiveIDs == firstDrawing)
        // Where its count marker would sit: the exemplar's centroid carried 100 pt to the left.
        #expect(abs(clipped.position.x - (exemplar.centroid.x - 100)) < 1e-9)
        #expect(abs(clipped.position.y - exemplar.centroid.y) < 1e-9)
        // Its bounds are the two strokes that survived: the sill 60…80 at y 100, the jamb to y 112.
        #expect(clipped.bounds.contains(VectorBounds(minX: 60, minY: 100, maxX: 80, maxY: 112)))
        #expect(clipped.bounds.maxX < 82 && clipped.bounds.minX > 58)
    }

    @Test("T-066: a drawing with one member hidden by the layer filter is rejected with its visible members")
    func hiddenMemberIsRejected() async throws {
        let url = try ExactBlockTests.writePDF(placements: Self.clippedPlacements, useForm: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let invocations = try #require(extraction.formInvocations)
        let exemplar = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 155, minY: 95, maxX: 185, maxY: 117)
        )
        let block = try #require(ExactBlockMatcher.block(of: exemplar, in: extraction))
        // Hide one stroke of the third drawing, as a hidden layer would.
        let thirdDrawing = extraction.primitives[invocations[2].primitiveRange].map(\.id).sorted()
        let hidden = try #require(thirdDrawing.first)
        let visible = extraction.primitives.filter { $0.id != hidden }
        let report = ExactBlockMatcher.instances(of: block, in: extraction, visible: visible)
        // Old output: 2 confirmed, rejected [] — the clipped and the half-hidden drawings both gone.
        #expect(report.confirmed.count == 2)
        #expect(report.rejected.count == 2)
        #expect(report.rejected.allSatisfy { $0.reason == .partialBlock(visible: 2, total: 3) })
        #expect(report.rejected.last?.primitiveIDs == Array(thirdDrawing.dropFirst()))

        // A drawing with nothing visible is not on the sheet and is not reported.
        let noneOfThird = extraction.primitives.filter { !thirdDrawing.contains($0.id) }
        let without = ExactBlockMatcher.instances(of: block, in: extraction, visible: noneOfThird)
        #expect(without.confirmed.count == 2 && without.rejected.count == 1)
    }

    // MARK: U-076 (iteration 4)

    @Test("U-076: boxing the clipped copy keeps the whole door as the reference: 3 confirmed, the boxed copy partial 2 of 3")
    func boxedClippedCopyIsNotTheReference() async throws {
        let url = try ExactBlockTests.writePDF(placements: Self.clippedPlacements, useForm: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let invocations = try #require(extraction.formInvocations)
        #expect(invocations.map(\.primitiveCount) == [2, 3, 3, 3])
        // The box sits around the first, clipped door: the sill 60…80 at y 100 and the jamb to
        // y 112 survive, the far stop at x 80 does not.
        let exemplar = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 55, minY: 95, maxX: 85, maxY: 117)
        )
        #expect(exemplar.primitiveIDs.count == 2)
        let block = try #require(ExactBlockMatcher.block(of: exemplar, in: extraction))
        // The boxed drawing names the form; the whole door (3 strokes) is the measure.
        #expect(block.invocation.primitiveCount == 2)
        #expect(block.primitiveCount == 3 && block.usableCount == 3)
        let report = ExactBlockMatcher.instances(of: block, in: extraction, visible: extraction.primitives)
        // Old output: the clipped copy became the block (2 primitives), so it was the only
        // confirmed instance and the three whole doors came back as
        // partialBlock(visible: 3, total: 2) — "partly hidden — 3 of 2 strokes visible".
        #expect(report.confirmed.count == 3, "\(report.confirmed.map(\.primitiveIDs))")
        #expect(report.rejected.count == 1)
        let clipped = try #require(report.rejected.first)
        #expect(clipped.reason == .partialBlock(visible: 2, total: 3))
        #expect(clipped.primitiveIDs == exemplar.primitiveIDs)
        #expect(report.candidateCount == 4)
        // Each whole door's marker sits where the boxed copy's centroid sits in its own drawing:
        // 100, 200 and 300 pt to the right.
        let xs = report.confirmed.map { ($0.position.x - exemplar.centroid.x).rounded() }
        #expect(xs == [100, 200, 300])
        #expect(report.confirmed.allSatisfy { abs($0.position.y - exemplar.centroid.y) < 1e-9 && $0.residual == 0 })
    }

    @Test("U-076: a page with whole doors, searched for a block boxed where every copy was clipped, confirms them and never reports visible > total")
    func wholerDrawingOnAnotherPageIsTheMeasure() async throws {
        // Exemplar page: one door, clipped (2 primitives), nothing larger to learn the whole from.
        let clippedURL = try ExactBlockTests.writePDF(placements: [Self.clippedPlacements[0]], useForm: true)
        defer { try? FileManager.default.removeItem(at: clippedURL) }
        let clippedPage = try await VectorExtractor().extract(documentAt: clippedURL, pageIndex: 0)
        let exemplar = try SymbolExemplar(
            primitives: clippedPage.primitives, region: VectorBounds(minX: 55, minY: 95, maxX: 85, maxY: 117)
        )
        let block = try #require(ExactBlockMatcher.block(of: exemplar, in: clippedPage))
        #expect(block.usableCount == 2)
        // Next page: the same form, whole four times and clipped once.
        let otherURL = try ExactBlockTests.writePDF(placements: Self.clippedPlacements + ["1 0 0 1 460 100"], useForm: true)
        defer { try? FileManager.default.removeItem(at: otherURL) }
        let otherPage = try await VectorExtractor().extract(documentAt: otherURL, pageIndex: 0)
        let report = ExactBlockMatcher.instances(of: block, in: otherPage, visible: otherPage.primitives, isExemplarPage: false)
        // Before the fix the three-stroke doors were partialBlock(visible: 3, total: 2).
        #expect(report.confirmed.count == 4)
        #expect(report.rejected.map(\.reason) == [.partialBlock(visible: 2, total: 3)])
        for rejection in report.rejected {
            if case let .partialBlock(visible, total) = rejection.reason { #expect(visible <= total) }
        }
    }

    // MARK: T-068

    @Test("T-068: a signature counts max(1, ⌈length / 4⌉) + 1 samples per segment and the 50-sample gate is unchanged")
    func signatureKeepsACountNotPoints() {
        let size = CGSize(width: 842, height: 595)
        // Four 100 pt sides: 25 steps of 4 pt, 26 samples each, 104 in all. A 0.5 pt tick adds
        // max(1, ⌈0.125⌉) + 1 = 2.
        let square = [
            Self.segment(1, 0, 0, 100, 0), Self.segment(2, 100, 0, 100, 100),
            Self.segment(3, 100, 100, 0, 100), Self.segment(4, 0, 100, 0, 0),
            Self.segment(5, 200, 200, 200.5, 200),
        ]
        #expect(RepeatedSheetDetector.signature(segments: square, pageSize: size).sampleCount == 106)
        // One line of 192 pt: ⌈48⌉ + 1 = 49 samples, one short of the gate; 196 pt: 50.
        let short = RepeatedSheetDetector.signature(segments: [Self.segment(1, 10, 10, 202, 10)], pageSize: size)
        let enough = RepeatedSheetDetector.signature(segments: [Self.segment(1, 10, 10, 206, 10)], pageSize: size)
        #expect(short.sampleCount == 49 && enough.sampleCount == 50)
        #expect(!RepeatedSheetDetector.matches(short, short, tolerance: 0.5))
        #expect(RepeatedSheetDetector.matches(enough, enough, tolerance: 0.5))
        // Past the budget the spacing grows: 200 000 pt of line samples every 200 000 / 20 000
        // = 10 pt, 20 000 steps + 1.
        let long = RepeatedSheetDetector.signature(segments: [Self.segment(1, 0, 0, 200_000, 0)], pageSize: size)
        #expect(long.sampleCount == 20_001)
    }
}
