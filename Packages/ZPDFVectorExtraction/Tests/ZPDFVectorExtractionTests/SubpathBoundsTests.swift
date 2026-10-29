import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// IM-236: a subpath's bounds are tracked as segments are appended, not recomputed on
/// every read.
struct SubpathBoundsTests {

    /// A 20 000-segment subpath alternating lines and cubics, seeded so the run repeats.
    static func builder() -> VectorSubpathBuilder {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53) * 1000 - 500
        }
        var builder = VectorSubpathBuilder(startPoint: CGPoint(x: 0, y: 0))
        for index in 0..<20_000 {
            let end = CGPoint(x: next(), y: next())
            if index % 2 == 0 {
                builder.append(.line(VectorLine(start: builder.currentPoint, end: end)))
            } else {
                builder.append(.cubic(VectorCubic(
                    p0: builder.currentPoint,
                    p1: CGPoint(x: next(), y: next()),
                    p2: CGPoint(x: next(), y: next()),
                    p3: end
                )))
            }
            builder.currentPoint = end
        }
        return builder
    }

    static func recomputedBounds(_ builder: VectorSubpathBuilder) -> VectorBounds {
        var result = VectorBounds(point: builder.startPoint)
        for segment in builder.segments { result = result.union(segment.bounds) }
        return result
    }

    @Test("Tracked bounds equal a full recomputation exactly, per segment and overall")
    func trackedBoundsAreExact() {
        let builder = Self.builder()
        #expect(builder.segments.count == 20_000)
        #expect(builder.segmentBounds.count == 20_000)
        #expect(builder.bounds == Self.recomputedBounds(builder))
        for (segment, box) in zip(builder.segments, builder.segmentBounds) {
            #expect(box == segment.bounds)
        }
    }

    @Test("Reading the bounds is O(1): a thousand reads cost less than a hundred recomputations")
    func boundsReadsAreConstantTime() {
        let builder = Self.builder()
        let clock = ContinuousClock()
        var reads = 0.0
        let readTime = clock.measure {
            for _ in 0..<1_000 { reads += builder.bounds.width }
        }
        var recomputed = 0.0
        let recomputeTime = clock.measure {
            for _ in 0..<100 { recomputed += Self.recomputedBounds(builder).width }
        }
        // The same width summed 1 000 and 100 times; equal up to summation rounding.
        #expect(abs(reads - recomputed * 10) <= reads * 1e-9)
        print("IM-236: 1 000 tracked reads \(readTime) vs 100 recomputations \(recomputeTime) over 20 000 segments")
        #expect(readTime < recomputeTime)
    }
}
