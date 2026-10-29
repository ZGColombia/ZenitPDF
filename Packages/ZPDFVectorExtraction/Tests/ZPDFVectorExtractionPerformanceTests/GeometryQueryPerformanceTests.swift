import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// The parallel-pair query must not be `O(n²)`.
///
/// A real sheet reaches the extractor's 2 000 000-primitive cap; 50 000 segments is a
/// modest architectural plan, and a quadratic query over it is 1.25 billion pair tests.
/// The grid plus the angle bucket turns that into roughly one million.
///
/// The budget below is deliberately loose. The measurement is printed, and the assertion
/// is at more than twice the observed time, because a shared machine running another
/// build is exactly the condition in which a tight timing assertion fails for no reason.
///
/// This suite is a test target of its own (I-34), so it runs in a process where nothing else
/// is measuring. In the main target, beside the live-test-8 real-drawing suites, the same
/// query read 5.3–6.5 s against 1.2–1.8 s alone and failed the 5 s budget in sweep 15.
struct GeometryQueryPerformanceTests {

    /// SplitMix64. A named, seeded generator so the corpus is the same on every run:
    /// a performance test whose input changes between runs is measuring two things.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in `[0, 1)`, from the top 53 bits.
        mutating func unit() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
        mutating func inRange(_ low: Double, _ high: Double) -> Double {
            low + unit() * (high - low)
        }
    }

    static func randomSegments(count: Int, extent: Double, seed: UInt64) -> [GeometryQuerySegment] {
        var random = SplitMix64(state: seed)
        var segments: [GeometryQuerySegment] = []
        segments.reserveCapacity(count)
        for index in 0..<count {
            let x = random.inRange(0, extent)
            let y = random.inRange(0, extent)
            let angle = random.inRange(0, .pi)
            let length = random.inRange(20, 200)
            segments.append(
                GeometryQuerySegment(
                    primitiveID: UInt64(index + 1),
                    start: CGPoint(x: x, y: y),
                    end: CGPoint(x: x + length * cos(angle), y: y + length * sin(angle))
                )
            )
        }
        return segments
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    @Test("50 000 random segments answer a parallel-pair query well inside the budget")
    func fiftyThousandSegmentsAnswerQuickly() throws {
        let segments = Self.randomSegments(count: 50_000, extent: 5_000, seed: 0x5EED_1234_ABCD_0001)
        let engine = try GeometryQueryEngine(segments: segments)

        // The cap is raised far above the expected match count on purpose: a query that
        // truncated would stop early and the number below would be a measurement of the
        // cap rather than of the query.
        let clock = ContinuousClock()
        var result: GeometryQueryResult<GeometryParallelPairHighlight>?
        let elapsed = clock.measure {
            result = engine.parallelPairs(
                gap: 300,
                tolerance: 1.5,
                minimumOverlap: 10,
                resultLimit: 1_000_000
            )
        }
        let found = try #require(result)
        let taken = Self.seconds(elapsed)

        #expect(!found.truncated)
        #expect(taken < 5.0)

        // The index really did prune: a quadratic query would test 1 249 975 000 pairs.
        #expect(found.examinedCount < 50_000 * 50_000 / 100)

        print(
            """
            fiftyThousandSegmentsAnswerQuickly: 50000 segments, gap 300 +/- 1.5, \
            minimum overlap 10 -> \(found.count) pairs in \
            \(String(format: "%.3f", taken)) s, \(found.examinedCount) candidate pairs tested \
            (quadratic would be 1249975000), truncated \(found.truncated)
            """
        )
    }

    @Test("The grid finds the same pairs a brute-force scan does")
    func gridAgreesWithBruteForce() throws {
        // 3 000 segments is small enough to check exhaustively and large enough that the
        // grid is doing real pruning. The brute-force pass uses the same match rule but
        // no index, so this compares the index against the rule rather than against itself.
        let segments = Self.randomSegments(count: 3_000, extent: 1_200, seed: 0x5EED_1234_ABCD_0002)
        let engine = try GeometryQueryEngine(segments: segments)

        let gap = 40.0
        let tolerance = 2.0
        let angleTolerance = GeometryQueryEngine.defaultAngleToleranceDegrees * .pi / 180
        let indexed = engine.parallelPairs(
            gap: gap,
            tolerance: tolerance,
            minimumOverlap: 5,
            resultLimit: 1_000_000
        )
        #expect(!indexed.truncated)

        var brute: [GeometryParallelPairHighlight] = []
        for i in segments.indices {
            for j in (i + 1)..<segments.count {
                let difference = GeometryQueryMath.angularDifference(
                    segments[i].lineAngle,
                    segments[j].lineAngle
                )
                guard difference <= angleTolerance else { continue }
                guard let pair = GeometryQueryEngine.pair(
                    segments[i],
                    segments[j],
                    gapPoints: gap,
                    tolerancePoints: tolerance,
                    minimumOverlapPoints: 5,
                    angleDifferenceDegrees: difference * 180 / .pi
                ) else { continue }
                brute.append(pair)
            }
        }
        brute.sort {
            $0.firstPrimitiveID == $1.firstPrimitiveID
                ? $0.secondPrimitiveID < $1.secondPrimitiveID
                : $0.firstPrimitiveID < $1.firstPrimitiveID
        }

        #expect(indexed.count == brute.count)
        #expect(indexed.matches == brute)
        #expect(indexed.examinedCount < 3_000 * 2_999 / 2)

        print(
            "gridAgreesWithBruteForce: indexed \(indexed.count) pairs from "
                + "\(indexed.examinedCount) candidates, brute force \(brute.count) pairs from "
                + "\(3_000 * 2_999 / 2) — identical: \(indexed.matches == brute)"
        )
    }
}
