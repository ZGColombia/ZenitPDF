import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
@testable import ZPDFMeasurementEngine

/// The boolean branch of the cutout
/// pipeline measured against the drawn rings (S-108, QUALITY_BAR P11), and the formula-version
/// bump for S-105 to S-108 and S-110 (ADR-0035 §8).
///
/// Every expected number is derived by hand in the comment beside it (QUALITY_BAR §2.6). Each test
/// states the output the old code produced.
@Suite("Iteration 2 re-fix — quantities core, engine")
struct Iter2RQuantitiesCoreTests {

    let engine = MeasurementEngine()

    static func area(_ ring: PolygonRing, holes: [PolygonRing] = []) -> MeasurementGeometry {
        MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: ring, holes: holes)])
    }

    /// Parent (0.3000004, 0.2000004)–(1000.3000006, 1000.2000006): every coordinate half a
    /// lattice step off, so the 1e-6 pt lattice rounds it to 1000.000001² = 1000000.002000000001
    /// while its drawn area is 1000.0000002² = 1000000.00040000000004 — the lattice copy is
    /// 1.6e-3 pt² larger.
    static let parent = PolygonRing(
        points: Fixture.points([(0.3000004, 0.2000004), (1000.3000006, 0.2000004), (1000.3000006, 1000.2000006), (0.3000004, 1000.2000006)]),
        isClosed: true
    )
    static let parentArea = 1000.0000002 * 1000.0000002

    /// A 10 × 10 cutout on the lattice.
    static let big = Fixture.ring([(100, 100), (110, 100), (110, 110), (100, 110)])

    func net(_ holes: [PolygonRing], parent: PolygonRing = Self.parent) throws -> (Decimal, MeasurementResult) {
        let result = try engine.calculate(tool: .area, geometry: Self.area(parent, holes: holes), scale: Fixture.unitScale)
        return (try #require(result[.netArea]).value, result)
    }

    // MARK: - S-108 P11 on the boolean branch

    /// The checker's first probe. One cutout takes the exact path: 1000000.0004 − 100 =
    /// 999900.0004. A 0.01 × 0.01 cutout straddling that cutout's right edge x = 110
    /// (109.995…110.005, 105…105.01) meets it, so the pair goes through the union and the
    /// difference; the part it adds outside the first cutout is 0.005 × 0.01 = 5e-5, so the net
    /// must fall by exactly that: 999900.00035.
    /// Old output: 999900.00195 — the difference's lattice outer (1.6e-3 pt² larger) was stored,
    /// so the net ROSE by 1.55e-3 pt².
    @Test("S-108: a tiny cutout straddling an existing cutout's edge lowers the net by what it adds (P11)")
    func tinyCutoutMeetingACutout() throws {
        let straddle = Fixture.ring([(109.995, 105), (110.005, 105), (110.005, 105.01), (109.995, 105.01)])
        let (one, _) = try net([Self.big])
        let (two, result) = try net([Self.big, straddle])
        #expect(two < one)
        #expect(abs(Fixture.double(one) - (Self.parentArea - 100)) <= 2e-9)
        #expect(abs(Fixture.double(two) - (Self.parentArea - 100.00005)) <= 2e-9)
        #expect(abs(Fixture.double(one - two) - 5e-5) <= 2e-9)
        // P6 for the same pair: the cutout area is plan − net, the union's 100.00005.
        #expect(abs(Fixture.double(try #require(result[.cutoutArea]).value) - 100.00005) <= 2e-9)
    }

    /// The checker's second probe. A 1.3 × 0.0001 cutout whose right edge is the parent's right
    /// edge x = 1000.3000006 (it touches the outer boundary from inside, so the strict-inside
    /// shortcut declines and the boolean runs). It is wholly inside, so it removes its whole
    /// 1.3e-4: 999900.0004 → 999900.00027, and it is not flagged as outside.
    /// Old output: the net rose by 1.47e-3 pt², with no warning.
    @Test("S-108: a tiny cutout touching the outer edge from inside lowers the net by its area (P11)")
    func tinyCutoutTouchingTheOuterEdge() throws {
        let touching = Fixture.ring([(999.0000006, 500), (1000.3000006, 500), (1000.3000006, 500.0001), (999.0000006, 500.0001)])
        let (one, _) = try net([Self.big])
        let (two, result) = try net([Self.big, touching])
        #expect(two < one)
        #expect(abs(Fixture.double(one - two) - 1.3e-4) <= 2e-9)
        #expect(abs(Fixture.double(two) - (Self.parentArea - 100.00013)) <= 2e-9)
        #expect(!result.warnings.contains { $0.code == .cutoutOutsideParent })
    }

    /// The same step with the existing cutout itself off the lattice:
    /// (99.9999996, 99.9999996)–(110.0000004, 110.0000004), drawn area 10.0000008² =
    /// 100.00001600000064, lattice copy 100..110 = 100 (1.6e-5 pt² smaller). A 0.001 × 0.001
    /// cutout (109.9995…110.0005, 105…105.001) straddles its right edge; the part outside it is
    /// (110.0005 − 110.0000004) × 0.001 = 4.996e-7, and that is the drop (the drawn-ring lattice
    /// formula alone would give 0.0005 × 0.001 = 5e-7, the lattice measure of the overlap strip;
    /// the drawn-coordinate area replaces it).
    /// Old output: the net rose by about 1.6e-3 pt² (lattice outer and lattice cutout both
    /// stored). With only the outer ring's rounding removed it would still rise by
    /// 1.6e-5 − 5e-7 ≈ 1.55e-5 pt², because the first cutout would switch from its drawn area to
    /// its lattice copy.
    @Test("S-108: an off-lattice cutout keeps its drawn area when a tiny cutout comes to meet it (P11)")
    func offLatticeCutoutKeepsItsDrawnArea() throws {
        let offLattice = Fixture.ring([(99.9999996, 99.9999996), (110.0000004, 99.9999996), (110.0000004, 110.0000004), (99.9999996, 110.0000004)])
        let straddle = Fixture.ring([(109.9995, 105), (110.0005, 105), (110.0005, 105.001), (109.9995, 105.001)])
        let drawnArea = 10.0000008 * 10.0000008
        let (one, _) = try net([offLattice])
        let (two, _) = try net([offLattice, straddle])
        #expect(two < one)
        #expect(abs(Fixture.double(one) - (Self.parentArea - drawnArea)) <= 2e-9)
        #expect(abs(Fixture.double(one - two) - 4.996e-7) <= 1.5e-9)
    }

    /// A chain of additions, each checked against the one before (P11), and each removal the
    /// reverse (it never lowers the net). The cutouts cover the three branches: apart and
    /// strictly inside (exact path), meeting one another, and touching the outer edge.
    @Test("S-108: adding cutouts one by one never raises the net, removing never lowers it")
    func monotoneChain() throws {
        let cutouts = [
            Fixture.ring([(99.9999996, 99.9999996), (110.0000004, 99.9999996), (110.0000004, 110.0000004), (99.9999996, 110.0000004)]),
            Fixture.ring([(300.1234567, 300.7654321), (340.9876543, 301.1111111), (339.2222222, 350.3333333), (301.4444444, 349.5555555)]),
            Fixture.ring([(109.9995, 105), (110.0005, 105), (110.0005, 105.001), (109.9995, 105.001)]),
            Fixture.ring([(999.0000006, 500), (1000.3000006, 500), (1000.3000006, 500.0001), (999.0000006, 500.0001)]),
            Fixture.ring([(339.9, 320.1), (339.95, 320.1), (339.95, 320.15), (339.9, 320.15)]),
            Fixture.ring([(0.3000004, 700.0000004), (0.3000014, 700.0000004), (0.3000014, 700.0000014), (0.3000004, 700.0000014)])
        ]
        var previous = try net([]).0
        for count in 1...cutouts.count {
            let current = try net(Array(cutouts.prefix(count))).0
            #expect(current <= previous, "adding cutout \(count - 1) raised the net from \(previous) to \(current)")
            #expect(current >= 0)
            previous = current
        }
    }

    /// QUALITY_BAR §2.5: a cutout equal to, or containing, an off-lattice parent leaves net area
    /// exactly 0 — never the outer ring's ±1.6e-3 pt² rounding residue the drawn-ring formula
    /// would otherwise leave behind.
    @Test("S-108: a cutout equal to or larger than an off-lattice parent leaves exactly 0")
    func fullCutoutIsExactlyZero() throws {
        let (equal, equalResult) = try net([Self.parent])
        #expect(equal == 0)
        #expect(equalResult.warnings.contains { $0.code == .degenerateArea })
        let larger = Fixture.ring([(-5.5000003, -5.5000003), (1010.2000007, -5.5000003), (1010.2000007, 1010.2000007), (-5.5000003, 1010.2000007)])
        let (containing, _) = try net([larger, Self.big])
        #expect(containing == 0)
    }

    /// P5 on the boolean branch with the new corrections: two meeting off-lattice cutouts, one
    /// touching the outer edge and one apart, in all 24 drawn orders give one stored Decimal.
    @Test("S-108: the drawn-ring net area is the same for every drawn order (P5)")
    func booleanBranchOrderFree() throws {
        let cutouts = [
            Fixture.ring([(99.9999996, 99.9999996), (110.0000004, 99.9999996), (110.0000004, 110.0000004), (99.9999996, 110.0000004)]),
            Fixture.ring([(109.9995, 105), (110.0005, 105), (110.0005, 105.001), (109.9995, 105.001)]),
            Fixture.ring([(999.0000006, 500), (1000.3000006, 500), (1000.3000006, 500.0001), (999.0000006, 500.0001)]),
            Fixture.ring([(300.1234567, 300.7654321), (340.9876543, 301.1111111), (339.2222222, 350.3333333), (301.4444444, 349.5555555)])
        ]
        var nets: Set<Decimal> = []
        for a in 0..<4 { for b in 0..<4 where b != a { for c in 0..<4 where c != a && c != b {
            let d = 6 - a - b - c
            nets.insert(try net([a, b, c, d].map { cutouts[$0] }).0)
        } } }
        #expect(nets.count == 1)
    }

    // MARK: - S-108 drawn-coordinate net area (crossing points off the lattice)

    static func rotated(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, _ angle: Double) -> [PDFPoint] {
        let c = cos(angle)
        let s = sin(angle)
        return [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
            .map { PDFPoint(x: cx + $0.0 * c - $0.1 * s, y: cy + $0.0 * s + $0.1 * c) }
    }

    static func square(at centre: PDFPoint, side: Double) -> [PDFPoint] {
        [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { PDFPoint(x: centre.x + $0.0 * side / 2, y: centre.y + $0.1 * side / 2) }
    }

    /// The residual the drawn-ring lattice formula still had. Rotated 10 × 10 and 500 × 20
    /// cutouts, off the lattice, at 11 angles; a 1e-3 or 1e-4 pt square cutout straddles one long
    /// edge at three positions along it. Every addition must lower the net (P11).
    /// Old output (lattice formula with the outer and wholly-inside cutouts corrected): 89 of the
    /// 132 additions raised the stored net, by up to 8.2e-6 pt² — the rounded crossing points on
    /// the long edge moved it by more than the tiny cutout removed (½ · 65 pt · 3.5e-7 pt ≈ 1e-5).
    /// Before the iteration-2 re-fix the raises were about 1.6e-3 pt².
    @Test("S-108: a tiny cutout straddling a rotated cutout's edge always lowers the net (P11)")
    func straddlingRotatedEdgesNeverRaise() throws {
        var additions = 0
        for (width, height) in [(10.0, 10.0), (500.0, 20.0)] {
            for angle in stride(from: 0.1, to: 1.5, by: 0.13) {
                let hole = Self.rotated(500.1234567, 500.7654321, width, height, angle)
                let (one, _) = try net([PolygonRing(points: hole, isClosed: true)])
                for fraction in [0.13, 0.5, 0.77] {
                    let centre = PDFPoint(
                        x: hole[1].x + fraction * (hole[2].x - hole[1].x),
                        y: hole[1].y + fraction * (hole[2].y - hole[1].y)
                    )
                    for side in [1e-3, 1e-4] {
                        let tiny = PolygonRing(points: Self.square(at: centre, side: side), isClosed: true)
                        let (two, _) = try net([PolygonRing(points: hole, isClosed: true), tiny])
                        additions += 1
                        #expect(two < one, "w=\(width) angle=\(angle) t=\(fraction) side=\(side): \(one) -> \(two)")
                    }
                }
            }
        }
        #expect(additions == 132)
    }

    /// An exact oracle for axis-aligned rectangles: cut the plane at every rectangle edge; each
    /// grid cell is wholly in or out of every rectangle, so the net area is the sum of the cells
    /// inside the outer rectangle and outside every cutout.
    static func gridNetArea(outer: (Double, Double, Double, Double), holes: [(Double, Double, Double, Double)]) -> Double {
        let xs = Array(Set([outer.0, outer.2] + holes.flatMap { [$0.0, $0.2] })).sorted()
        let ys = Array(Set([outer.1, outer.3] + holes.flatMap { [$0.1, $0.3] })).sorted()
        var cells: [Double] = []
        for i in 0..<(xs.count - 1) {
            for j in 0..<(ys.count - 1) {
                let x = (xs[i] + xs[i + 1]) / 2
                let y = (ys[j] + ys[j + 1]) / 2
                func inside(_ r: (Double, Double, Double, Double)) -> Bool { x > r.0 && x < r.2 && y > r.1 && y < r.3 }
                if inside(outer) && !holes.contains(where: inside) {
                    cells.append((xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j]))
                }
            }
        }
        return EngineNumerics.sum(cells)
    }

    /// ExactNetArea against the grid oracle on 400 random off-lattice rectangle families that
    /// overlap, nest, repeat, share edges with each other and run along or across the outer edge
    /// (edges are copied exactly from the outer or from an earlier cutout a third of the time).
    @Test("S-108: the drawn-coordinate net area matches an exact grid oracle on rectangles")
    func exactNetAreaMatchesGridOracle() throws {
        var state: UInt64 = 0x5108_2025
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var worst = 0.0
        for _ in 0..<400 {
            let outer = (10.3 + next(), 20.7 + next(), 150.1 + 50 * next(), 160.9 + 50 * next())
            var holes: [(Double, Double, Double, Double)] = []
            for _ in 0..<(1 + Int(next() * 5)) {
                var x0 = outer.0 - 10 + next() * (outer.2 - outer.0)
                var y0 = outer.1 - 10 + next() * (outer.3 - outer.1)
                var x1 = x0 + 1 + next() * 60
                var y1 = y0 + 1 + next() * 60
                let shared = next()
                if shared < 0.15 { x1 = outer.2 } else if shared < 0.25 { y0 = outer.1 }
                if let earlier = holes.last, next() < 0.35 {
                    if next() < 0.5 { x0 = earlier.2 } else { (x0, y0, x1, y1) = earlier }
                }
                if x1 > x0, y1 > y0 { holes.append((x0, y0, x1, y1)) }
            }
            guard !holes.isEmpty else { continue }
            func ring(_ r: (Double, Double, Double, Double)) -> [PDFPoint] {
                Fixture.points([(r.0, r.1), (r.2, r.1), (r.2, r.3), (r.0, r.3)])
            }
            let exact = try #require(ExactNetArea.netArea(outer: ring(outer), holes: holes.map(ring)))
            let oracle = Self.gridNetArea(outer: outer, holes: holes)
            worst = max(worst, abs(exact - oracle))
        }
        #expect(worst <= 1e-9, "worst \(worst)")
    }

    /// Two convex cutouts crossing at arbitrary angles inside a rotated parent:
    /// |outer| − (|A| + |B| − |A ∩ B|), the intersection of two convex polygons clipped
    /// independently here (Sutherland–Hodgman) from the drawn coordinates.
    @Test("S-108: the drawn-coordinate net area matches a convex-intersection oracle at any angle")
    func exactNetAreaMatchesConvexOracle() throws {
        func clip(_ subject: [PDFPoint], by clipper: [PDFPoint]) -> [PDFPoint] {
            var output = subject
            for index in clipper.indices {
                let a = clipper[index]
                let b = clipper[(index + 1) % clipper.count]
                func side(_ p: PDFPoint) -> Double { (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) }
                let input = output
                output = []
                for k in input.indices {
                    let p = input[k]
                    let q = input[(k + 1) % input.count]
                    let sp = side(p)
                    let sq = side(q)
                    if sp >= 0 { output.append(p) }
                    if (sp >= 0) != (sq >= 0) {
                        let t = sp / (sp - sq)
                        output.append(PDFPoint(x: p.x + t * (q.x - p.x), y: p.y + t * (q.y - p.y)))
                    }
                }
                if output.isEmpty { return [] }
            }
            return output
        }
        var state: UInt64 = 0xC0_4E_C5
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var worst = 0.0
        for _ in 0..<300 {
            let parent = Self.rotated(12_345.678 + next(), 13_579.246 + next(), 900, 700, next())
            let a = Self.rotated(12_345 + 100 * next(), 13_579 + 100 * next(), 50 + 100 * next(), 20 + 80 * next(), 3 * next())
            let b = Self.rotated(12_345 + 100 * next(), 13_579 + 100 * next(), 50 + 100 * next(), 20 + 80 * next(), 3 * next())
            let both = clip(a, by: b)
            let oracle = PolygonMath.area(parent) - (PolygonMath.area(a) + PolygonMath.area(b) - (both.count >= 3 ? PolygonMath.area(both) : 0))
            let exact = try #require(ExactNetArea.netArea(outer: parent, holes: [a, b]))
            worst = max(worst, abs(exact - oracle) / oracle)
        }
        #expect(worst <= 1e-13, "worst rel \(worst)")
    }

    // MARK: - Formula version 6 (S-105, S-106, S-107, S-108, S-110)

    /// Every value S-105 to S-108 and S-110 changed is stamped with the new formula version, so
    /// a value stored under version 5 — the 6.68 pt² bulged bowtie, an arc area a separate X/Y
    /// scale used to refuse, a thin ellipse's 0, the lattice net of two cutouts, a per-segment
    /// rise paired with the wrong pieces — is recognisably from the old formula and is not kept
    /// as current (a kept stale-scale value survives only at the current formula version).
    /// Old output: all stamped 5, the same as before the changes. Iteration 3 (ADR-0037) raised
    /// the version again, to 7, and iteration 7 (ADR-0041) to 8; these results carry the current
    /// version, which is past 5.
    @Test("S-105…S-110: the changed results are stamped a formula version past 5 (now 8)")
    func changedResultsCarryVersionSix() throws {
        #expect(ContractVersion.measurementFormulaVersion == 8)
        let bowtie = PolygonRing(
            points: Fixture.points([(0, 0), (10, 10), (10, 0), (0, 10)]), isClosed: true, bulges: [0.1, 0, 0, 0]
        )
        let arcArea = PolygonRing(
            points: Fixture.points([(0, 0), (20, 0), (20, 10), (0, 10)]), isClosed: true, bulges: [0, 0, 0.5, 0]
        )
        let results = [
            try engine.calculate(tool: .area, geometry: Self.area(bowtie), scale: Fixture.unitScale),
            try engine.calculate(tool: .area, geometry: Self.area(arcArea), scale: Fixture.separateXY(x: 0.02, y: 0.01)),
            try engine.calculate(
                tool: .area,
                geometry: Self.area(Self.parent, holes: [Self.big, Fixture.ring([(109.995, 105), (110.005, 105), (110.005, 105.01), (109.995, 105.01)])]),
                scale: Fixture.unitScale
            )
        ]
        for result in results {
            #expect(result.formulaVersion == 8)
        }
    }
}
