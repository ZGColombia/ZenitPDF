import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine

/// L-73: the banded containment index the island search uses gives the full ring scan's answer.
@Suite("Ring containment index (L-73)")
struct RingContainmentTests {

    /// A deterministic generator, so a failure names a reproducible case.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("Star polygons, rectilinear rings and points on vertex heights: the index agrees with the scan")
    func indexAgreesWithTheScan() {
        var random = SplitMix(state: 73)
        for case_ in 0..<40 {
            // A star-shaped ring of 3…600 vertices round (500, 500), some radii snapped to a grid
            // so several vertices share a height — the case a band edge is most likely to get wrong.
            let count = 3 + Int(random.next() % 598)
            var ring: [PDFPoint] = []
            for index in 0..<count {
                let angle = Double(index) / Double(count) * 2 * Double.pi
                var radius = Double.random(in: 50...400, using: &random)
                if case_ % 3 == 0 { radius = (radius / 25).rounded() * 25 }
                var y = 500 + radius * sin(angle)
                if case_ % 2 == 0 { y = y.rounded() }
                ring.append(PDFPoint(x: 500 + radius * cos(angle), y: y))
            }
            let index = RingContainment(ring)
            for probe in 0..<500 {
                var point = PDFPoint(x: Double.random(in: 0...1000, using: &random), y: Double.random(in: 0...1000, using: &random))
                // A fifth of the probes sit exactly at a vertex's height.
                if probe % 5 == 0 { point.y = ring[Int(random.next() % UInt64(ring.count))].y }
                #expect(index.encloses(point) == RegionTracer.encloses(ring, point), "case \(case_), point \(point)")
            }
        }
    }

    @Test("A zig-zag ring whose every edge spans its height answers as the scan does")
    func zigZagRing() {
        // 200 teeth between y = 0 and y = 100, closed under the comb at y = −10: every tooth edge
        // spans every band, so the index declines to build and the scan answers.
        var ring: [PDFPoint] = (0..<200).map { PDFPoint(x: Double($0), y: $0 % 2 == 0 ? 0 : 100) }
        ring.append(PDFPoint(x: 199, y: -10))
        ring.append(PDFPoint(x: 0, y: -10))
        var random = SplitMix(state: 92)
        let index = RingContainment(ring)
        for _ in 0..<2_000 {
            let point = PDFPoint(x: Double.random(in: -5...205, using: &random), y: Double.random(in: -15...105, using: &random))
            #expect(index.encloses(point) == RegionTracer.encloses(ring, point), "point \(point)")
        }
    }

    @Test("A degenerate ring answers as the scan does")
    func degenerateRings() {
        let flat = [PDFPoint(x: 0, y: 5), PDFPoint(x: 10, y: 5), PDFPoint(x: 20, y: 5)]
        let pair = [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10)]
        for ring in [flat, pair, []] {
            for point in [PDFPoint(x: 5, y: 5), PDFPoint(x: 15, y: 4), PDFPoint(x: -1, y: 5)] {
                #expect(RingContainment(ring).encloses(point) == RegionTracer.encloses(ring, point))
            }
        }
    }
}
