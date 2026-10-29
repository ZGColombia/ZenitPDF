import Foundation
import Testing
@testable import ZPDFContracts

/// Review fixes to the arc-segment arithmetic (ADR-0030 §5.7). Every expected value is
/// hand-derived and held to the arc tolerance, rel ≤ 1e-12.
@Suite("Arc arithmetic review fixes (ADR-0030 §5.7)")
struct ArcReviewFixContractTests {

    /// A 10 × 10 square whose top-right corner is rounded by a quarter circle of r = 4 about
    /// (6, 6): (0,0) → (10,0) → (10,6) ⌒ (6,10) → (0,10), the arc sweeping +π/2 (bulge tan(π/8)).
    /// Area: 100 − 16 (the cut corner square) + π·4²/4 (the quarter disc) = 84 + 4π.
    static func roundedCorner(dx: Double, dy: Double) -> PolygonRing {
        PolygonRing(
            points: [(0.0, 0.0), (10, 0), (10, 6), (6, 10), (0, 10)].map { PDFPoint(x: $0.0 + dx, y: $0.1 + dy) },
            isClosed: true,
            bulges: [0, 0, Foundation.tan(Double.pi / 8), 0, 0]
        )
    }

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    /// QUALITY_BAR §2.2 rule 1: the shoelace must be origin-shifted. The two offsets keep every
    /// coordinate inside one binade (3000.37…3010.37 and 2000.61…2010.61; 14000.37… and
    /// 13000.61…), so adding the integers 0, 6 and 10 is exact and the translated ring is exactly
    /// the ring at the origin: its exact area is still 84 + 4π.
    ///
    /// Old output (raw-coordinate shoelace): rel 4.8e-12 at (3000.37, 2000.61) and 1.5e-10 at
    /// (14000.37, 13000.61).
    @Test("The exact area of a ring with an arc does not drift with its position on the sheet")
    func exactAreaIsTranslationInvariant() {
        let expected = 84 + 4 * Double.pi
        for (dx, dy) in [(0.0, 0.0), (3000.37, 2000.61), (14000.37, 13000.61)] {
            let area = Self.roundedCorner(dx: dx, dy: dy).exactSignedArea
            #expect(Self.rel(area, expected) <= 1e-12, "offset (\(dx), \(dy)): \(area) vs \(expected)")
        }
    }

    /// A nearly straight arc on a chord c = 100. Hand series, from θ = 4·atan b, r = c / (2 sin(θ/2))
    /// and θ − sin θ = θ³/6 − θ⁵/120 + …: the segment is (c²·θ/12)(1 + θ²/30 + O(θ⁴)) =
    /// (c²·b/3)(1 + b²/5 + O(b⁴)) — for b ≤ 1e-4 the omitted term is below 1e-16 relative.
    ///
    /// Old output (r²/2·(θ − sin θ) computed directly, the difference cancelling): rel 2.1e-9 at
    /// b = 1e-4, 3.3253e-4 against 3.3333e-4 at b = 1e-7, +24 % at b = 1e-8, and 0 at b = 5e-9.
    @Test("A nearly straight arc's segment area is exact to the arc bar")
    func nearlyStraightSegment() {
        let a = PDFPoint(x: 0, y: 0), b = PDFPoint(x: 100, y: 0)
        for bulge in [1e-4, 1e-5, 1e-7, 1e-8, 5e-9, 1e-10, 2e-12] {
            let expected = 100.0 * 100.0 * bulge / 3 * (1 + bulge * bulge / 5)
            let forward = BulgeArc.segmentArea(from: a, to: b, bulge: bulge)
            let backward = BulgeArc.segmentArea(from: a, to: b, bulge: -bulge)
            #expect(Self.rel(forward, expected) <= 1e-12, "b = \(bulge): \(forward) vs \(expected)")
            #expect(Self.rel(backward, -expected) <= 1e-12, "b = −\(bulge): \(backward) vs \(-expected)")
        }
    }

    /// Either side of where the stable form hands over to the closed form (θ = 1), the segment
    /// equals the closed form r²/2·(θ − sin θ) written out here, where that difference loses at
    /// most a factor θ/(θ − sin θ) ≈ 6.3 of one rounding.
    @Test("Moderate arcs still equal the closed form r²/2·(θ − sin θ)")
    func moderateSegment() {
        let a = PDFPoint(x: 0, y: 0), b = PDFPoint(x: 100, y: 0)
        for theta in [0.5, 0.99, 1.0, 1.01, 2.0, Double.pi] {
            let bulge = Foundation.tan(theta / 4)
            let radius = 100 / (2 * Foundation.sin(theta / 2))
            let expected = radius * radius / 2 * (theta - Foundation.sin(theta))
            #expect(Self.rel(BulgeArc.segmentArea(from: a, to: b, bulge: bulge), expected) <= 1e-13, "θ = \(theta)")
        }
    }
}
