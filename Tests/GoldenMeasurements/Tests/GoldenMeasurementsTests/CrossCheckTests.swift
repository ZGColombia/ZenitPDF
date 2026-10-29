import Foundation
import GoldenMeasurements
import Testing
import ZPDFContracts
import ZPDFMeasurementEngine

/// Independent re-derivations of the harder expectations.
///
/// Nothing in this file calls the shoelace formula, Clipper2, or any part of the geometry core.
/// A Monte-Carlo estimate and a hand-rolled Simpson integrator are slow and imprecise, which is
/// exactly why they are useful here: they can only agree with the engine by both being right.
@Suite("Independent cross-checks")
struct CrossCheckTests {

    /// A deterministic 64-bit LCG. Seeded per case, so a failure is reproducible.
    struct Random {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }

    /// Ray-casting point-in-ring, written from scratch here so the cross-check shares no code
    /// with the engine's containment test.
    static func inside(_ x: Double, _ y: Double, ring: [(Double, Double)]) -> Bool {
        var result = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let (xi, yi) = ring[i]
            let (xj, yj) = ring[j]
            if (yi > y) != (yj > y) {
                let crossing = xi + (y - yi) / (yj - yi) * (xj - xi)
                if x < crossing { result.toggle() }
            }
            j = i
        }
        return result
    }

    /// Estimates the net area of an outer ring minus a set of holes by uniform sampling.
    static func monteCarloArea(
        outer: [(Double, Double)],
        holes: [[(Double, Double)]],
        samples: Int,
        seed: UInt64
    ) -> Double {
        let minX = outer.map(\.0).min() ?? 0
        let maxX = outer.map(\.0).max() ?? 0
        let minY = outer.map(\.1).min() ?? 0
        let maxY = outer.map(\.1).max() ?? 0
        let boxArea = (maxX - minX) * (maxY - minY)

        var random = Random(state: seed)
        var hits = 0
        for _ in 0..<samples {
            let x = minX + random.next() * (maxX - minX)
            let y = minY + random.next() * (maxY - minY)
            guard inside(x, y, ring: outer) else { continue }
            var inHole = false
            for hole in holes where inside(x, y, ring: hole) {
                inHole = true
                break
            }
            if !inHole { hits += 1 }
        }
        return boxArea * Double(hits) / Double(samples)
    }

    struct AreaCase: Sendable, CustomStringConvertible {
        let name: String
        let outer: [(Double, Double)]
        let holes: [[(Double, Double)]]
        let seed: UInt64
        var description: String { name }
    }

    static let areaCases: [AreaCase] = [
        AreaCase(
            name: "L-shape",
            outer: GoldenCorpus.lShape,
            holes: [],
            seed: 0x5EED_0001
        ),
        AreaCase(
            name: "slab with one hole",
            outer: GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
            holes: [GoldenGeometry.rectangle(x: 20, y: 20, width: 20, height: 30)],
            seed: 0x5EED_0002
        ),
        AreaCase(
            name: "slab with two disjoint holes",
            outer: GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
            holes: [
                GoldenGeometry.rectangle(x: 10, y: 10, width: 20, height: 30),
                GoldenGeometry.rectangle(x: 60, y: 60, width: 20, height: 20)
            ],
            seed: 0x5EED_0003
        ),
        AreaCase(
            name: "slab with three holes, two overlapping",
            outer: GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
            holes: [
                GoldenGeometry.rectangle(x: 10, y: 10, width: 30, height: 30),
                GoldenGeometry.rectangle(x: 30, y: 30, width: 30, height: 30),
                GoldenGeometry.rectangle(x: 70, y: 70, width: 20, height: 20)
            ],
            seed: 0x5EED_0004
        ),
        AreaCase(
            name: "concave arrow",
            outer: [(0, 10), (40, 10), (40, 0), (60, 20), (40, 40), (40, 30), (0, 30)],
            holes: [],
            seed: 0x5EED_0005
        ),
        AreaCase(
            name: "50-gon",
            outer: GoldenGeometry.regularPolygon(sides: 50, radius: 100),
            holes: [],
            seed: 0x5EED_0006
        )
    ]

    @Test("Monte-Carlo net area agrees with the engine", arguments: areaCases)
    func monteCarloAgreement(_ areaCase: AreaCase) throws {
        let geometry = GoldenGeometry.polygon(areaCase.outer, holes: areaCase.holes)
        let result = try MeasurementEngine().calculate(
            tool: .area,
            geometry: geometry,
            scale: GoldenScale.unit
        )
        let engineArea = NumericPolicy.double(from: try #require(result[.netArea]).value)
        let estimate = Self.monteCarloArea(
            outer: areaCase.outer,
            holes: areaCase.holes,
            samples: 2_000_000,
            seed: areaCase.seed
        )
        // 2e6 samples give a standard error well under 0.1 % of the box area; 0.5 % is a
        // comfortable band that still catches a doubly-subtracted hole (which would be off by
        // 1 % here) or a missing one.
        let error = abs(estimate - engineArea) / engineArea
        #expect(
            error < 0.005,
            "\(areaCase.name): engine \(engineArea), Monte-Carlo \(estimate), error \(error)"
        )
    }

    /// Simpson's rule on `4 * integral_0^{pi/2} sqrt(a^2 sin^2 t + b^2 cos^2 t) dt`.
    static func ellipsePerimeter(a: Double, b: Double, intervals: Int = 200_000) -> Double {
        let h = (Double.pi / 2) / Double(intervals)
        func f(_ t: Double) -> Double {
            let sa = a * Foundation.sin(t)
            let cb = b * Foundation.cos(t)
            return (sa * sa + cb * cb).squareRoot()
        }
        var sum = f(0) + f(Double.pi / 2)
        for index in 1..<intervals {
            sum += (index % 2 == 1 ? 4 : 2) * f(Double(index) * h)
        }
        return 4 * sum * h / 3
    }

    @Test(
        "Ellipse circumference agrees with an independent arc-length integral",
        arguments: [(10.0, 5.0), (10.0, 7.5), (12.192, 6.096), (3.0, 3.0)]
    )
    func ellipseCircumference(_ axes: (Double, Double)) throws {
        let (a, b) = axes
        let geometry = GoldenGeometry.polyline([(-a, -b), (a, b)])
        let result = try MeasurementEngine().calculate(
            tool: .ellipseArea,
            geometry: geometry,
            scale: GoldenScale.unit
        )
        let engineValue = NumericPolicy.double(from: try #require(result[.circumference]).value)
        let reference = Self.ellipsePerimeter(a: a, b: b)
        let error = abs(engineValue - reference) / reference
        #expect(
            error < GoldenTolerance.length,
            "a=\(a) b=\(b): engine \(engineValue), integral \(reference), error \(error)"
        )
    }

    /// The one place the engine's own subtraction is checked against a subtraction done by hand
    /// on the *union* rather than on the individual holes.
    @Test("Overlapping holes are subtracted once, not twice")
    func overlappingHolesSubtractedOnce() throws {
        let outer = GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100)
        let holes = [
            GoldenGeometry.rectangle(x: 10, y: 10, width: 30, height: 30),
            GoldenGeometry.rectangle(x: 30, y: 30, width: 30, height: 30)
        ]
        let result = try MeasurementEngine().calculate(
            tool: .area,
            geometry: GoldenGeometry.polygon(outer, holes: holes),
            scale: GoldenScale.unit
        )
        let net = NumericPolicy.double(from: try #require(result[.netArea]).value)
        let unionArea = 900.0 + 900.0 - 100.0
        let naiveDoubleSubtraction = 10_000.0 - 900.0 - 900.0
        #expect(abs(net - (10_000 - unionArea)) < 1e-6)
        #expect(abs(net - naiveDoubleSubtraction) > 90)
    }
}
