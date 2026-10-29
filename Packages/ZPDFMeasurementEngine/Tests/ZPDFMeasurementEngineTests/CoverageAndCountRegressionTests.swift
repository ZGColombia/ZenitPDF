import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFClipper2
@testable import ZPDFMeasurementEngine

/// Coverage, overlap and dimension-check findings: IM-068, BH-562, BH-563.
/// (IM-067 and BH-561 were in `CoverageMap.analyse` and `CountAggregator`, deleted as dead code
/// in iteration 1, R-175 and R-176.)
@Suite("Coverage and count regressions (bug hunt 2)")
struct CoverageAndCountRegressionTests {

    static func square(_ x: Double, _ y: Double, _ side: Double, holes: [[(Double, Double)]] = []) -> PolygonGeometry {
        func ring(_ pairs: [(Double, Double)]) -> PolygonRing {
            PolygonRing(points: pairs.map { PDFPoint(x: $0.0, y: $0.1) }, isClosed: true)
        }
        return PolygonGeometry(
            outer: ring([(x, y), (x + side, y), (x + side, y + side), (x, y + side)]),
            holes: holes.map(ring)
        )
    }

    static func randomLayout(_ generator: inout SplitMix, count: Int, span: Double) -> [PolygonGeometry] {
        (0..<count).map { _ in
            let side = 5 + generator.unit() * 40
            let x = generator.unit() * span
            let y = generator.unit() * span
            if generator.unit() < 0.4 {
                let hole = side / 4
                return square(x, y, side, holes: [[(x + hole, y + hole), (x + 2 * hole, y + hole), (x + 2 * hole, y + 2 * hole), (x + hole, y + 2 * hole)]])
            }
            return square(x, y, side)
        }
    }

    // MARK: - IM-068

    /// Reference: the old i-then-j double loop over the outer-ring boxes.
    static func referencePartners(_ boxes: [PDFRect?]) -> [[Int]] {
        var partners = Array(repeating: [Int](), count: boxes.count)
        for i in 0..<boxes.count {
            guard let left = boxes[i] else { continue }
            for j in (i + 1)..<boxes.count {
                guard let right = boxes[j], left.intersects(right) else { continue }
                partners[i].append(j)
            }
        }
        return partners
    }

    @Test("IM-068: R-tree candidate pairs equal the double loop's, in the same order")
    func rTreePairsMatchDoubleLoop() throws {
        var generator = SplitMix(seed: 0x1D_068)
        for trial in 0..<40 {
            var layout = Self.randomLayout(&generator, count: 60 + trial * 5, span: 200 + Double(trial) * 20)
            // Exact edge and corner contacts: inclusive `intersects` must still pair them.
            layout.append(Self.square(1000, 1000, 10))
            layout.append(Self.square(1010, 1000, 10))
            layout.append(Self.square(1020, 1010, 10))
            let boxes = layout.map { $0.outer.bounds }
            #expect(CoverageMap.intersectingPartners(of: boxes) == Self.referencePartners(boxes))
        }
        // The overlap rule the app runs (OverlapGuard, R-175) finds, through the R-tree, exactly
        // the overlaps an exhaustive pairwise intersection finds, in the same order.
        let layout = Self.randomLayout(&generator, count: 80, span: 150)
        let found = try OverlapGuard.overlaps(of: layout)
        var reference: [(Int, Int, Double)] = []
        let regions = try layout.map { try CoverageRegions.netRegion(of: $0, options: .default) }
        for i in 0..<(layout.count - 1) {
            for j in (i + 1)..<layout.count {
                let shared = try Clipper2.intersection(regions[i], regions[j], fillRule: .nonZero, scale: .pagePoints)
                let area = CoverageRegions.pdfArea(of: shared)
                if area > OverlapGuard.defaultFloor { reference.append((i, j, area)) }
            }
        }
        #expect(!reference.isEmpty, "the layout must contain overlaps for the comparison to mean anything")
        #expect(found.map { [$0.first, $0.second] } == reference.map { [$0.0, $0.1] })
        #expect(zip(found, reference).allSatisfy { $0.0.pageArea == $0.1.2 })
    }

    @Test("IM-068: candidate-pair search on 5 000 disjoint rectangles is sub-quadratic")
    func rTreePairsScale() throws {
        func grid(_ count: Int) -> [PDFRect?] {
            let columns = 100
            return (0..<count).map { index in
                let x = Double(index % columns) * 20
                let y = Double(index / columns) * 20
                return PDFRect(corner: PDFPoint(x: x, y: y), opposite: PDFPoint(x: x + 10, y: y + 10))
            }
        }
        let boxes = grid(5_000)
        let clock = ContinuousClock()
        var treePartners: [[Int]] = []
        let tree = clock.measure { treePartners = CoverageMap.intersectingPartners(of: boxes) }
        var loopPartners: [[Int]] = []
        let loop = clock.measure { loopPartners = Self.referencePartners(boxes) }
        #expect(treePartners == loopPartners)
        #expect(treePartners.allSatisfy { $0.isEmpty }, "disjoint rectangles have no candidate pairs")
        // 12.5 M box tests against 5 000 tree queries; the tree must win clearly.
        #expect(tree < loop / 4, "tree \(tree) vs double loop \(loop)")
    }

    // MARK: - BH-562

    /// Old output: a degenerate (zero-width) extent returned coveredFraction 0, and the
    /// uncovered share (then `CoverageResult.uncoveredFraction`, deleted in U-095 as test-only)
    /// read 1 - 0 = 1 — "the whole sheet is unaccounted for" — while the uncovered area was 0 and
    /// uncoveredPolygons empty in the same result.
    @Test("BH-562: a degenerate extent reports nothing uncovered, not 100 %")
    func degenerateExtentIsNotAFalseAlarm() throws {
        let flat = CoverageExtent.inkBounds(PDFRect(corner: PDFPoint(x: 0, y: 0), opposite: PDFPoint(x: 100, y: 0)))
        let result = try CoverageMap().coverage(of: [Self.square(10, 10, 20)], within: flat)
        #expect(result.coveredFraction == 0)
        #expect(result.coveredPolygons.isEmpty && result.uncoveredPolygons.isEmpty)
        #expect(result.extentPDFArea == 0 && result.coveredPDFArea == 0)
        // A real extent with nothing measured is still 100 % uncovered: all 100 x 100 of it.
        let page = CoverageExtent.pageBox(PDFRect(corner: PDFPoint(x: 0, y: 0), opposite: PDFPoint(x: 100, y: 100)))
        let empty = try CoverageMap().coverage(of: [], within: page)
        #expect(empty.coveredFraction == 0 && empty.extentPDFArea == 10_000 && empty.coveredPDFArea == 0)
        // Half measured: 50 x 100 of 100 x 100 -> 0.5 covered.
        let half = PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 50, y: 0), PDFPoint(x: 50, y: 100), PDFPoint(x: 0, y: 100)
        ], isClosed: true))
        #expect(try CoverageMap().coverage(of: [half], within: page).coveredFraction == 0.5)
    }

    // MARK: - BH-563

    /// Old output: "5,400 mm" parsed as 5.4 mm = 0.0054 m (the three-decimal refusal is skipped
    /// once a unit is present), the plausibility gate dropped it, and a real 20 mm disagreement
    /// went unreported.
    @Test("BH-563: a thousands group with an explicit mm or cm unit is read as thousands")
    func thousandsGroupWithUnit() {
        // 5,400 mm = 5400 mm = 5.4 m; 5.400 mm likewise (dot grouping).
        #expect(DimensionChecker.parseDimensionMetres("5,400 mm") == Decimal(string: "5.4"))
        #expect(DimensionChecker.parseDimensionMetres("5.400 mm") == Decimal(string: "5.4"))
        // 1,250 cm = 1250 cm = 12.5 m.
        #expect(DimensionChecker.parseDimensionMetres("1,250 cm") == Decimal(string: "12.5"))
        // Metres keep three decimals as metres: 5.400 m = 5.4 m.
        #expect(DimensionChecker.parseDimensionMetres("5.400 m") == Decimal(string: "5.4"))
        // Two decimals with mm stay decimal: 5,40 mm = 0.0054 m.
        #expect(DimensionChecker.parseDimensionMetres("5,40 mm") == Decimal(string: "0.0054"))
        // Unitless three-decimal shape is still refused.
        #expect(DimensionChecker.parseDimensionMetres("5,400") == nil)
    }
}

/// IM-193: the outer-box prefilter never changes which outer ring owns a hole.
@Suite("Ring assembly owner prefilter (IM-193)")
struct RingAssemblyPrefilterTests {
    @Test("IM-193: hole owners are identical with and without the box prefilter")
    func prefilterPreservesOwners() throws {
        var generator = SplitMix(seed: 0x1D_193)
        let options = MeasurementEngineOptions.default
        func square(_ x: Double, _ y: Double, _ side: Double) -> ClipperPath {
            [CGPoint(x: x, y: y), CGPoint(x: x + side, y: y), CGPoint(x: x + side, y: y + side), CGPoint(x: x, y: y + side)]
        }
        for _ in 0..<60 {
            // Nested and disjoint outers (a ring soup like a boolean returns), holes anywhere —
            // inside one outer, inside nested outers, straddling, touching, or outside all.
            var outers: [(ring: ClipperPath, area: Double)] = []
            for _ in 0..<8 {
                let side = 10 + generator.unit() * 80
                let x = generator.unit() * 150
                let y = generator.unit() * 150
                outers.append((ring: square(x, y, side), area: side * side))
            }
            for _ in 0..<40 {
                let side = 1 + generator.unit() * 20
                let hole = Array(square(generator.unit() * 200, generator.unit() * 200, side).reversed())
                let boxes = outers.map { RingAssembly.bounds(of: $0.ring, grownBy: 1 / options.clipperScale.value) }
                let reference = try RingAssembly.owner(of: hole, among: outers, options: options)
                let filtered = try RingAssembly.owner(of: hole, among: outers, boxes: boxes, options: options)
                #expect(reference == filtered)
            }
            // A hole touching its outer ring's max edge exactly: the inclusive box keeps it.
            let edgeHole = Array(square(outers[0].ring[1].x - 5, outers[0].ring[1].y, 5).reversed())
            let boxes = outers.map { RingAssembly.bounds(of: $0.ring, grownBy: 1 / options.clipperScale.value) }
            #expect(try RingAssembly.owner(of: edgeHole, among: outers, options: options)
                == RingAssembly.owner(of: edgeHole, among: outers, boxes: boxes, options: options))
        }
    }
}
