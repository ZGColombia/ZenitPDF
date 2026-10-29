import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Iteration 2: a wall takeoff that stopped at its pair limit says
/// so (S-098), and repeated-sheet matching is bounded by the drawing, not the paper (S-099).
@Suite("Iter2 wall takeoff and repeated sheets")
struct Iter2WallAndRepeatTests {

    private static func segment(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> GeometryQuerySegment {
        GeometryQuerySegment(primitiveID: id, sourceObjectID: id, start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1), strokeWidth: 0.5)
    }

    // MARK: S-098

    /// 224 × 224 = 50 176 decoy walls, each two 50 pt faces 20 pt apart (200 mm at 100 pt/m).
    /// Rows are 100 pt apart, so a face's only partner in the 5…60 pt band is its own; columns
    /// 70 pt apart, collinear with each other. Every pair search therefore finds 50 176 pairs,
    /// more than ``WallCentrelineEngine/pairLimit``.
    private static func denseDecoys() -> [GeometryQuerySegment] {
        var segments: [GeometryQuerySegment] = []
        segments.reserveCapacity(224 * 224 * 2)
        var id: UInt64 = 100_000
        for row in 0..<224 {
            for column in 0..<224 {
                let x = 5_000 + Double(column) * 70, y = Double(row) * 100
                id += 1; segments.append(segment(id, x, y, x + 50, y))
                id += 1; segments.append(segment(id, x, y + 20, x + 50, y + 20))
            }
        }
        return segments
    }

    @Test("S-098: a sheet whose parallel pairs pass the search limit reports its walls as possibly incomplete")
    func truncatedTakeoffIsFlagged() throws {
        let segments = WallCentrelineTests.plan() + Self.denseDecoys()
        // Precondition: the thickness search really does stop at the limit (calibrated at
        // 100 pt/m: separations 5…60 pt, i.e. gap 32.5 ± 27.5, overlap at least 10 pt).
        let query = try GeometryQueryEngine(segments: segments)
        let search = query.parallelPairs(gap: 32.5, tolerance: 27.5, minimumOverlap: 10,
                                         resultLimit: WallCentrelineEngine.pairLimit)
        #expect(search.status == .truncated(limit: 50_000))

        let takeoff = WallCentrelineEngine(segments: segments, options: .calibrated(pointsPerMetre: 100)).takeoff()
        // Old output: the classes came back with no truncation signal anywhere, and the
        // review offered them as the sheet's whole wall takeoff.
        #expect(takeoff.isTruncated)
        #expect(!takeoff.classes.isEmpty)
        #expect(takeoff.classes.allSatisfy { $0.isTruncated }, "\(takeoff.classes.map(\.isTruncated))")

        // The plan alone is complete, and says so.
        let clean = WallCentrelineTests.engine.takeoff()
        #expect(!clean.isTruncated)
        #expect(clean.classes.count == 2 && clean.classes.allSatisfy { !$0.isTruncated })
    }

    @Test("S-098: segments shorter than the minimum overlap never enter the pair search, and change nothing")
    func shortSegmentsAreNotPaired() {
        // A thousand 3 pt ticks beside the plan: none can face another for 10 pt.
        var segments = WallCentrelineTests.plan()
        for index in 0..<1_000 {
            let x = 1_100 + Double(index % 40) * 2, y = Double(index / 40) * 2
            segments.append(Self.segment(UInt64(50_000 + index), x, y, x + 3, y))
        }
        let engine = WallCentrelineEngine(segments: segments, options: .calibrated(pointsPerMetre: 100))
        #expect(engine.pairingSegments.count == WallCentrelineTests.plan().count)
        #expect(engine.takeoff() == WallCentrelineTests.engine.takeoff())
    }

    // MARK: S-099

    /// An A1 sheet (2384 × 1684 pt) at 1:100, so 1 m is 1000 mm / 100 = 10 mm on paper = 28.35 pt.
    private static let a1 = CGSize(width: 2384, height: 1684)
    private static let pointsPerMetreAt1to100 = 10 / 25.4 * 72

    private static func storey(partitionAt x: Double, splitOuterWall: Bool = false, extra: [GeometryQuerySegment] = []) -> RepeatedSheetDetector.Signature {
        var segments: [GeometryQuerySegment] = []
        if splitOuterWall {
            segments.append(segment(1, 200, 200, 1_133, 200))
            segments.append(segment(2, 1_133, 200, 2_200, 200))
        } else {
            segments.append(segment(1, 200, 200, 2_200, 200))
        }
        segments.append(segment(3, 2_200, 200, 2_200, 1_500))
        segments.append(segment(4, 2_200, 1_500, 200, 1_500))
        segments.append(segment(5, 200, 1_500, 200, 200))
        segments.append(segment(6, x, 200, x, 1_500))
        return RepeatedSheetDetector.signature(segments: segments + extra, pageSize: a1)
    }

    @Test("S-099: on A1 at 1:100 a partition moved 0.3 m is a different storey")
    func movedPartitionOnA1DoesNotGroup() {
        let moved = 1_000 + 0.3 * Self.pointsPerMetreAt1to100   // 8.50 pt
        #expect(abs(moved - 1_008.504) < 0.001)
        // Old output: [[0, 1]] — the default was 0.5 % of the A1 diagonal, 14.6 pt (0.51 m at 1:100).
        #expect(RepeatedSheetDetector.groups([(0, Self.storey(partitionAt: 1_000)), (1, Self.storey(partitionAt: moved))]).isEmpty)
        // 18 mm (0.51 pt) is already outside the bound; 0.3 pt of re-plot noise is inside it.
        #expect(RepeatedSheetDetector.groups([(0, Self.storey(partitionAt: 1_000)), (1, Self.storey(partitionAt: 1_000.51))]).isEmpty)
        #expect(RepeatedSheetDetector.groups([(0, Self.storey(partitionAt: 1_000)), (1, Self.storey(partitionAt: 1_000.3))]) == [[0, 1]])
    }

    @Test("S-099: the same drawing with its lines split differently still matches, however sparse the sampling")
    func differentlySplitLinesStillMatch() {
        // Two hundred 1900 pt lines bring the linework to about 388 000 pt, so the sampling step
        // grows to about 19 pt (388 000 / 20 000) and the two sheets' sample points fall up to
        // ~10 pt apart along the same lines: only a point-to-line bound holds them to 0.5 pt.
        // (A point-to-point check at 0.5 pt fails here; the old one passed only because its
        // bound was 14.6 pt.)
        let whole = (0..<200).map { index in
            Self.segment(UInt64(1_000 + index), 250, 250 + Double(index) * 6, 2_150, 250 + Double(index) * 6)
        }
        let split = (0..<200).flatMap { index -> [GeometryQuerySegment] in
            let y = 250 + Double(index) * 6, cut = 250 + 1_900 * Double(index % 7 + 1) / 8
            return [Self.segment(UInt64(2_000 + index), 250, y, cut, y), Self.segment(UInt64(3_000 + index), cut, y, 2_150, y)]
        }
        let a = Self.storey(partitionAt: 1_000, extra: whole)
        let b = Self.storey(partitionAt: 1_000, splitOuterWall: true, extra: split)
        #expect(RepeatedSheetDetector.groups([(0, a), (1, b)]) == [[0, 1]])
    }

    // MARK: S-099, second pass — exact per segment, not per sample

    /// 950 shared 2000 pt lines, 1.5 pt apart (three tolerances, so none covers its neighbour):
    /// 1.9 million points of linework, which pushes the signature's sample step to 95 pt — wider
    /// than a 900 mm opening at 1:100 (25.5 pt).
    private static let denseLinework: [GeometryQuerySegment] = (0..<950).map { index in
        Iter2WallAndRepeatTests.segment(UInt64(10_000 + index), 200, 60 + Double(index) * 1.5, 2_200, 60 + Double(index) * 1.5)
    }

    /// A dense storey with an interior wall on y = 1600 that has one plain opening, and a cross
    /// wall at x = 2100 the interior wall runs up to.
    private static func denseStorey(openingAt x: Double, width: Double = 900 / 1_000 * Iter2WallAndRepeatTests.pointsPerMetreAt1to100,
                                    wallEnd: Double = 2_100) -> RepeatedSheetDetector.Signature {
        var segments = Self.denseLinework
        segments.append(Self.segment(1, 200, 1_600, x, 1_600))
        segments.append(Self.segment(2, x + width, 1_600, wallEnd, 1_600))
        segments.append(Self.segment(3, 2_100, 1_550, 2_100, 1_650))
        return RepeatedSheetDetector.signature(segments: segments, pageSize: Self.a1)
    }

    @Test("S-099: on a dense sheet a plain opening moved along a wall is a different storey, at every offset")
    func movedOpeningOnDenseSheetDoesNotGroup() {
        let opening = 900 / 1_000 * Self.pointsPerMetreAt1to100
        #expect(abs(opening - 25.51) < 0.01)
        // The premise: the sample step is wider than the opening, so samples can straddle it.
        let total = Self.denseLinework.reduce(0.0) { $0 + $1.line.length }
        #expect(total / Double(RepeatedSheetDetector.maximumPoints) > 3 * opening)
        let base = Self.denseStorey(openingAt: 1_000)
        var grouped: [Int] = []
        for offset in stride(from: 60, through: 600, by: 20) {
            if !RepeatedSheetDetector.groups([(0, base), (1, Self.denseStorey(openingAt: 1_000 + Double(offset)))]).isEmpty {
                grouped.append(offset)
            }
        }
        // Old output (sampled check, verified by restoring it): grouped at most offsets.
        #expect(grouped.isEmpty, "grouped at offsets \(grouped) pt")
        // The same opening in the same place still groups: the check is not simply stricter.
        #expect(RepeatedSheetDetector.groups([(0, base), (1, Self.denseStorey(openingAt: 1_000))]) == [[0, 1]])
    }

    @Test("S-099: on a dense sheet a wall run on to the cross wall is not the wall stopped 60 pt short of it")
    func wallExtendedInLineDoesNotGroup() {
        // Both sheets' ends are covered — the short wall's end lies on the long wall, the long
        // wall's end on the cross wall — so only the 60 pt between them (2.1 m at 1:100) differs.
        let stopsShort = Self.denseStorey(openingAt: 1_000, wallEnd: 2_040)
        let runsOn = Self.denseStorey(openingAt: 1_000, wallEnd: 2_100)
        // Old output: [[0, 1]] both ways round.
        #expect(RepeatedSheetDetector.groups([(0, stopsShort), (1, runsOn)]).isEmpty)
        #expect(RepeatedSheetDetector.groups([(0, runsOn), (1, stopsShort)]).isEmpty)
        #expect(!RepeatedSheetDetector.matches(stopsShort, runsOn, tolerance: RepeatedSheetDetector.defaultTolerancePoints))
    }

    @Test("S-099: the bound is exact along a line — a gap of 0.9 pt is within 0.5 pt of its ends, 1.1 pt is not")
    func gapInLineIsJudgedExactly() {
        // A gap of width g in a line is covered by the other sheet's whole line from both sides,
        // and its middle is g / 2 from the nearest end: within 0.5 pt exactly when g ≤ 1 pt.
        func split(gap: Double) -> RepeatedSheetDetector.Signature {
            var segments = Self.denseLinework
            segments.append(Self.segment(1, 200, 1_600, 1_000, 1_600))
            segments.append(Self.segment(2, 1_000 + gap, 1_600, 2_100, 1_600))
            return RepeatedSheetDetector.signature(segments: segments, pageSize: Self.a1)
        }
        let whole = RepeatedSheetDetector.signature(
            segments: Self.denseLinework + [Self.segment(1, 200, 1_600, 2_100, 1_600)], pageSize: Self.a1)
        #expect(RepeatedSheetDetector.groups([(0, whole), (1, split(gap: 0.9))]) == [[0, 1]])
        #expect(RepeatedSheetDetector.groups([(0, whole), (1, split(gap: 1.1))]).isEmpty)
    }

    @Test("S-099: the covered stretch of one segment by another is the line's meeting with the stadium around it")
    func coveredIntervalIsTheStadiumChord() throws {
        let line = VectorLine(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        // A collinear segment from 20 to 50 covers 19.5…50.5 of the line (its end discs add 0.5).
        let collinear = try #require(RepeatedSheetDetector.coveredInterval(
            of: line, by: VectorLine(start: CGPoint(x: 20, y: 0), end: CGPoint(x: 50, y: 0)), within: 0.5))
        #expect(abs(collinear.0 - 0.195) < 1e-12 && abs(collinear.1 - 0.505) < 1e-12)
        // A parallel segment 0.3 above: the band reaches 20…50, each disc a further √(0.25 − 0.09) = 0.4.
        let parallel = try #require(RepeatedSheetDetector.coveredInterval(
            of: line, by: VectorLine(start: CGPoint(x: 20, y: 0.3), end: CGPoint(x: 50, y: 0.3)), within: 0.5))
        #expect(abs(parallel.0 - 0.196) < 1e-12 && abs(parallel.1 - 0.504) < 1e-12)
        // A crossing segment covers ±0.5 around the crossing; one 0.6 away covers nothing.
        let crossing = try #require(RepeatedSheetDetector.coveredInterval(
            of: line, by: VectorLine(start: CGPoint(x: 70, y: -5), end: CGPoint(x: 70, y: 5)), within: 0.5))
        #expect(abs(crossing.0 - 0.695) < 1e-12 && abs(crossing.1 - 0.705) < 1e-12)
        #expect(RepeatedSheetDetector.coveredInterval(
            of: line, by: VectorLine(start: CGPoint(x: 0, y: 0.6), end: CGPoint(x: 100, y: 0.6)), within: 0.5) == nil)
        // Coverage of the whole line needs the stretches to meet.
        #expect(RepeatedSheetDetector.intervalsCoverSegment([(0, 0.5), (0.49, 1)], length: 100))
        #expect(!RepeatedSheetDetector.intervalsCoverSegment([(0, 0.5), (0.51, 1)], length: 100))
    }

    @Test("S-099: the exact check agrees with a brute-force search on 400 random layouts (fixed seed)")
    func exactCheckAgreesWithBruteForce() {
        // SplitMix64, so the layouts are the same on every run.
        var state: UInt64 = 42
        func random() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        let tolerance = RepeatedSheetDetector.defaultTolerancePoints
        var covered = 0, uncovered = 0, undecided = 0
        for _ in 0..<400 {
            // Six segments on sheet B — horizontal, vertical or any angle — and three on sheet A cut
            // from them past their ends and jittered by up to ±0.6 pt, so both answers occur.
            let b: [VectorLine] = (0..<6).map { _ in
                let x = random() * 100, y = random() * 100, kind = random(), length = random() * 60
                let angle = kind < 0.4 ? 0 : kind < 0.7 ? Double.pi / 2 : random() * 2 * Double.pi
                return VectorLine(start: CGPoint(x: x, y: y), end: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length))
            }
            let a: [VectorLine] = (0..<3).map { _ in
                let source = b[min(5, Int(random() * 6))]
                func at(_ t: Double) -> CGPoint {
                    CGPoint(x: source.start.x + (source.end.x - source.start.x) * t + (random() - 0.5) * 1.2,
                            y: source.start.y + (source.end.y - source.start.y) * t + (random() - 0.5) * 1.2)
                }
                return VectorLine(start: at(random() * 1.2 - 0.1), end: at(random() * 1.2 - 0.1))
            }
            let exact = RepeatedSheetDetector.SheetIndex(segments: b, tolerance: tolerance).covers(a)
            // Brute force: the farthest of 2001 points per segment from B. Distance to B changes by
            // at most the distance moved, so the true farthest is within half a step of it.
            var farthest = 0.0, halfStep = 0.0
            for line in a {
                halfStep = max(halfStep, line.length / 4_000)
                for index in 0...2_000 {
                    let t = Double(index) / 2_000
                    let p = CGPoint(x: line.start.x + (line.end.x - line.start.x) * t, y: line.start.y + (line.end.y - line.start.y) * t)
                    farthest = max(farthest, b.map { RepeatedSheetDetector.squaredDistance(from: p, to: $0).squareRoot() }.min() ?? .infinity)
                }
            }
            if farthest > tolerance + 1e-9 {
                #expect(!exact, "a point \(farthest) pt from B was accepted: A \(a) B \(b)")
                uncovered += 1
            } else if farthest + halfStep < tolerance - 1e-9 {
                #expect(exact, "every point within \(farthest + halfStep) pt of B, yet refused: A \(a) B \(b)")
                covered += 1
            } else {
                undecided += 1
            }
        }
        // Both answers must be exercised for the comparison to mean anything.
        #expect(covered >= 30 && uncovered >= 30, "covered \(covered), uncovered \(uncovered), undecided \(undecided)")
    }

    @Test("S-099: twenty distinct dense sheets compare without rebuilding a group's grid for every sheet")
    func manyDistinctDenseSheetsStayCheap() {
        // Twenty sheets, each the dense linework with its interior wall's opening somewhere else:
        // no two match, so every sheet is compared with every earlier one (190 comparisons).
        let sheets = (0..<20).map { index in (page: index, signature: Self.denseStorey(openingAt: 400 + Double(index) * 70)) }
        let clock = ContinuousClock()
        let started = clock.now
        #expect(RepeatedSheetDetector.groups(sheets).isEmpty)
        let elapsed = clock.now - started
        // Measured 3.5 s alone in a debug build (0.035 s in release); the ceiling leaves room for a
        // busy machine and guards the per-comparison rebuild, it is not a benchmark.
        #expect(elapsed < .seconds(30), "\(elapsed)")
        print("S-099 twenty distinct dense sheets: \(elapsed)")
    }
}
