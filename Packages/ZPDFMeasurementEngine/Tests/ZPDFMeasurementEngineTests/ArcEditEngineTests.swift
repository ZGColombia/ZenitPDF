import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// NL-MEASURE-05 remaining parts (ADR-0030 §5.6): splitting, merging and cutting rings with arc
/// edges exactly, and the Bézier drawing form. Every expected value is hand-derived at 1 m/pt and
/// held to rel ≤ 1e-12 (QUALITY_BAR §2.1 M-A1 is 1e-9; the tolerance for arcs is 1e-12).
@Suite("Exact edits of arc segments (NL-MEASURE-05)")
struct ArcEditEngineTests {

    let engine = MeasurementEngine()

    /// The golden ring: a 10 × 5 rectangle, counter-clockwise, whose right side (10,0)→(10,5) is an
    /// outward semicircle (bulge tan(π/4) = 1, centre (10, 2.5), r = 2.5).
    static let golden = PolygonRing(
        points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]),
        isClosed: true,
        bulges: [0, 1, 0, 0]
    )

    /// A 10 × 10 square whose top-right corner is rounded by a quarter circle of r = 4 about (6, 6):
    /// (0,0) → (10,0) → (10,6) ⌒ (6,10) → (0,10). The quarter arc sweeps +π/2 (bulge tan(π/8)).
    static let roundedCorner = PolygonRing(
        points: Fixture.points([(0, 0), (10, 0), (10, 6), (6, 10), (0, 10)]),
        isClosed: true,
        bulges: [0, 0, Foundation.tan(Double.pi / 8), 0, 0]
    )

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    static func rel(_ value: Decimal?, _ expected: Double) -> Double {
        guard let value else { return .infinity }
        return rel(NumericPolicy.double(from: value), expected)
    }

    /// Area and perimeter of one polygon through the production engine, at 1 m/pt.
    func measured(_ polygon: PolygonGeometry) throws -> (area: Double, perimeter: Double) {
        let result = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [polygon]),
            scale: Fixture.unitScale,
            parameters: .default
        )
        return (
            NumericPolicy.double(from: result[.planArea]?.value ?? 0),
            NumericPolicy.double(from: result[.perimeter]?.value ?? 0)
        )
    }

    // MARK: Split along a line

    /// The golden ring cut by the vertical x = 5. Left part: the square [0,5]², area 25, perimeter
    /// 20. Right part: the square [5,10]×[0,5] plus the half disc, area 25 + π·2.5²/2 = 25 + 3.125π,
    /// perimeter 5 + 5 + 5 (bottom, cut, top) + 2.5π. The arc survives whole, bulge 1.
    @Test("Golden ring split at x = 5: 25 and 25 + 3.125π, the semicircle kept whole")
    func splitAcrossStraightEdges() throws {
        let result = try ArcAreaSplitter.split(PolygonGeometry(outer: Self.golden), along: Fixture.points([(5, -1), (5, 6)]))
        guard case let .parts(parts) = result else { Issue.record("expected parts, got \(result)"); return }
        #expect(parts.count == 2)
        let big = try measured(parts[0]), small = try measured(parts[1])
        #expect(Self.rel(big.area, 25 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(big.perimeter, 15 + 2.5 * .pi) <= 1e-12)
        #expect(Self.rel(small.area, 25) <= 1e-12)
        #expect(Self.rel(small.perimeter, 20) <= 1e-12)
        #expect(parts[0].outer.validBulges?.contains(where: { Swift.abs($0 - 1) <= 1e-12 }) == true)
        // The parts sum to the golden whole, 50 + 3.125π.
        #expect(Self.rel(big.area + small.area, 50 + 3.125 * .pi) <= 1e-12)
    }

    /// The golden ring cut by the horizontal y = 2.5, which crosses the semicircle at its apex
    /// (12.5, 2.5). Each half: the 10 × 2.5 rectangle plus a quarter disc, 25 + π·2.5²/4 =
    /// 25 + 1.5625π; perimeter 10 + 12.5 + 2.5 + 2.5·π/2 = 25 + 1.25π. The two quarter arcs each
    /// sweep π/2: bulge tan(π/8).
    @Test("Golden ring split at y = 2.5 through the arc: two quarter arcs, 25 + 1.5625π each")
    func splitThroughTheArc() throws {
        let result = try ArcAreaSplitter.split(PolygonGeometry(outer: Self.golden), along: Fixture.points([(-1, 2.5), (20, 2.5)]))
        guard case let .parts(parts) = result else { Issue.record("expected parts, got \(result)"); return }
        #expect(parts.count == 2)
        for part in parts {
            let value = try measured(part)
            #expect(Self.rel(value.area, 25 + 1.5625 * .pi) <= 1e-12)
            #expect(Self.rel(value.perimeter, 25 + 1.25 * .pi) <= 1e-12)
            let arcs = part.outer.validBulges?.filter { $0 != 0 } ?? []
            #expect(arcs.count == 1)
            #expect(arcs.allSatisfy { Self.rel($0, Foundation.tan(Double.pi / 8)) <= 1e-12 })
        }
    }

    /// The rounded-corner square. Area: the chord pentagon 100 − 8 (the corner triangle cut by the
    /// chord) = 92, plus the quarter circle's segment r²/2·(θ − sin θ) = 8·(π/2 − 1) = 4π − 8:
    /// 84 + 4π. Perimeter 10 + 6 + 2π + 6 + 10 = 32 + 2π. Cut along the diagonal (0,0)–(10,10),
    /// the axis of symmetry, which meets the arc at (6 + 2√2, 6 + 2√2): each half is 42 + 2π, and
    /// each keeps an eighth arc, bulge tan(π/16).
    @Test("Quarter-circle corner: 84 + 4π whole; cut on its diagonal, 42 + 2π each")
    func quarterCircleCorner() throws {
        let whole = try measured(PolygonGeometry(outer: Self.roundedCorner))
        #expect(Self.rel(whole.area, 84 + 4 * .pi) <= 1e-12)
        #expect(Self.rel(whole.perimeter, 32 + 2 * .pi) <= 1e-12)

        let result = try ArcAreaSplitter.split(PolygonGeometry(outer: Self.roundedCorner), along: Fixture.points([(0, 0), (10, 10)]))
        guard case let .parts(parts) = result else { Issue.record("expected parts, got \(result)"); return }
        #expect(parts.count == 2)
        let cutPoint = 6 + 2 * 2.0.squareRoot()
        for part in parts {
            #expect(Self.rel(try measured(part).area, 42 + 2 * .pi) <= 1e-12)
            #expect(part.outer.points.contains { Swift.abs($0.x - cutPoint) <= 1e-12 && Swift.abs($0.y - cutPoint) <= 1e-12 })
            let arcs = part.outer.validBulges?.filter { $0 != 0 } ?? []
            #expect(arcs.count == 1 && arcs.allSatisfy { Self.rel($0, Foundation.tan(Double.pi / 16)) <= 1e-12 })
        }
    }

    @Test("A line that misses, and a sliver, are refused as values")
    func refusals() throws {
        let miss = try ArcAreaSplitter.split(PolygonGeometry(outer: Self.golden), along: Fixture.points([(20, -5), (20, 10)]))
        #expect(miss == .lineMissesPolygon)
        // x = 12.49 shaves 0.01 off the arc's apex: a segment of chord 2·√(2.5² − 2.49²) ≈ 0.447
        // and height 0.01, area ≈ 0.003 pt², below the 0.01 pt² sliver floor.
        let sliver = try ArcAreaSplitter.split(PolygonGeometry(outer: Self.golden), along: Fixture.points([(12.49, -5), (12.49, 10)]))
        guard case let .degenerate(area) = sliver else { Issue.record("expected a sliver refusal, got \(sliver)"); return }
        #expect(area > 0 && area < 0.01)
        #expect(throws: ArcEditRefusal.holes) {
            try ArcAreaSplitter.split(PolygonGeometry(outer: Self.golden, holes: [Fixture.ring([(1, 1), (2, 1), (2, 2)])]), along: Fixture.points([(5, -1), (5, 6)]))
        }
    }

    /// Sixty straight cuts at deterministic angles and offsets through three arc shapes (the golden
    /// ring, the rounded corner, and a ring with an inward arc): whenever the engine splits, the
    /// parts' exact areas sum to the whole's hand-derived area, and no part holds a chord where the
    /// whole had an arc (every part's arc length is a piece of the whole's). The inward case: the
    /// golden rectangle with its right side bulging inward (bulge −1), 50 − 3.125π.
    @Test("Sixty cuts through three arc shapes: parts always sum to the whole")
    func partsAlwaysSum() throws {
        let inward = PolygonRing(points: Self.golden.points, isClosed: true, bulges: [0, -1, 0, 0])
        let shapes: [(PolygonRing, Double, (Double, Double))] = [
            (Self.golden, 50 + 3.125 * .pi, (6, 2.5)),
            (Self.roundedCorner, 84 + 4 * .pi, (5, 5)),
            (inward, 50 - 3.125 * .pi, (4, 2.5))
        ]
        var splits = 0
        for (ring, whole, centre) in shapes {
            for index in 0..<20 {
                let angle = Double(index) * 0.157 + 0.05
                let offset = Double(index % 5) - 2
                let ox = centre.0 - Foundation.sin(angle) * offset, oy = centre.1 + Foundation.cos(angle) * offset
                let cut = [PDFPoint(x: ox - Foundation.cos(angle), y: oy - Foundation.sin(angle)),
                           PDFPoint(x: ox + Foundation.cos(angle), y: oy + Foundation.sin(angle))]
                let result = try ArcAreaSplitter.split(PolygonGeometry(outer: ring), along: cut)
                guard case let .parts(parts) = result else { continue }
                splits += 1
                let sum = try parts.reduce(0.0) { $0 + (try measured($1)).area }
                #expect(Self.rel(sum, whole) <= 1e-12, "angle \(angle) offset \(offset): \(sum) vs \(whole)")
            }
        }
        #expect(splits >= 45, "most of the cuts pass through the shapes")
    }

    // MARK: Merge (union)

    /// The golden ring and the rectangle [0,10]×[5,8] above it share the edge y = 5, walked in
    /// opposite directions, so it drops out. Area 50 + 3.125π + 30 = 80 + 3.125π; perimeter
    /// 10 (bottom) + 2.5π + 3 + 10 + 8 (the left sides 5 + 3 joined) = 31 + 2.5π.
    @Test("Merge along a shared edge keeps the arc: 80 + 3.125π, perimeter 31 + 2.5π")
    func mergeAlongSharedEdge() throws {
        let above = Fixture.ring([(0, 5), (10, 5), (10, 8), (0, 8)])
        let merged = try ArcRingBoolean.union([PolygonGeometry(outer: Self.golden), PolygonGeometry(outer: above)])
        #expect(merged.count == 1)
        let value = try measured(try #require(merged.first))
        #expect(Self.rel(value.area, 80 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(value.perimeter, 31 + 2.5 * .pi) <= 1e-12)
        #expect(merged.first?.outer.validBulges?.filter { $0 != 0 } == [1])
        #expect(merged.first?.outer.points.count == 5, "the collinear left sides join into one edge")
    }

    /// The golden ring and the rectangle [11,20]×[0,5], which cuts the semicircle along x = 11,
    /// d = 1 from the centre. Overlap: the circular segment beyond that chord,
    /// r²·acos(d/r) − d·√(r² − d²) = 6.25·acos(0.4) − √5.25. Union = (50 + 3.125π) + 45 − overlap.
    /// The two surviving arc pieces each sweep π/2 − acos(0.4).
    @Test("Merge across the arc: 95 + 3.125π − (6.25·acos 0.4 − √5.25)")
    func mergeAcrossTheArc() throws {
        let right = Fixture.ring([(11, 0), (20, 0), (20, 5), (11, 5)])
        let merged = try ArcRingBoolean.union([PolygonGeometry(outer: Self.golden), PolygonGeometry(outer: right)])
        #expect(merged.count == 1)
        let expected = 95 + 3.125 * Double.pi - (6.25 * Foundation.acos(0.4) - 5.25.squareRoot())
        #expect(Self.rel(try measured(try #require(merged.first)).area, expected) <= 1e-12)
        let arcs = merged.first?.outer.validBulges?.filter { $0 != 0 } ?? []
        let piece = Foundation.tan((Double.pi / 2 - Foundation.acos(0.4)) / 4)
        #expect(arcs.count == 2 && arcs.allSatisfy { Self.rel($0, piece) <= 1e-12 })
    }

    /// A rectangle [10,20]×[0,5] swallows the whole semicircle: the union is the rectangle
    /// [0,20]×[0,5], area 100, with no arc left and no vertex on its straight sides.
    @Test("Merge that swallows the arc: the 20 × 5 rectangle, 100")
    func mergeSwallowingTheArc() throws {
        let right = Fixture.ring([(10, 0), (20, 0), (20, 5), (10, 5)])
        let merged = try ArcRingBoolean.union([PolygonGeometry(outer: Self.golden), PolygonGeometry(outer: right)])
        #expect(merged.count == 1)
        #expect(Self.rel(try measured(try #require(merged.first)).area, 100) <= 1e-12)
        #expect(merged.first?.outer.validBulges == nil)
        #expect(merged.first?.outer.points.count == 4)
    }

    @Test("Areas apart come back as two polygons, never one")
    func mergeApart() throws {
        let far = Fixture.ring([(30, 0), (40, 0), (40, 5), (30, 5)])
        let merged = try ArcRingBoolean.union([PolygonGeometry(outer: Self.golden), PolygonGeometry(outer: far)])
        #expect(merged.count == 2)
    }

    // MARK: Intersection and difference (the Scale Region cut of an area)

    /// Golden ∩ [5,20]×[−10,20] = the square [5,10]×[0,5] plus the half disc, 25 + 3.125π;
    /// golden − that = the square [0,5]², 25. The two sum to the whole.
    @Test("Intersection and difference: 25 + 3.125π and 25")
    func intersectionAndDifference() throws {
        let region = try #require(ArcRing(Fixture.ring([(5, -10), (20, -10), (20, 20), (5, 20)])))
        let ring = try #require(ArcRing(Self.golden))
        let inside = try ArcRingBoolean.polygons(.intersection, ring, region)
        let outside = try ArcRingBoolean.polygons(.difference, ring, region)
        #expect(inside.count == 1 && outside.count == 1)
        #expect(Self.rel(try measured(inside[0]).area, 25 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(try measured(outside[0]).area, 25) <= 1e-12)
    }

    // MARK: Splitting one arc edge

    /// A semicircle of r = 2.5 cut at 0.3 of its sweep: pieces of 0.3π and 0.7π, bulges tan(0.3π/4)
    /// and tan(0.7π/4); their lengths 0.75π and 1.75π sum to 2.5π. A polylength (0,0) → (10,0) ⌒
    /// (10,5) with the cut point inserted still measures 10 + 2.5π.
    @Test("An arc split in two: the parts sum to the whole, 10 + 2.5π")
    func arcSplitSumsToWhole() throws {
        let start = PDFPoint(x: 10, y: 0), end = PDFPoint(x: 10, y: 5)
        let cut = try #require(BulgeArc.split(from: start, to: end, bulge: 1, at: 0.3))
        #expect(Self.rel(cut.firstBulge, Foundation.tan(0.3 * .pi / 4)) <= 1e-12)
        #expect(Self.rel(cut.secondBulge, Foundation.tan(0.7 * .pi / 4)) <= 1e-12)
        // The cut point is on the circle, at angle −π/2 + 0.3π from the centre (10, 2.5).
        let angle = -Double.pi / 2 + 0.3 * .pi
        #expect(Swift.abs(cut.point.x - (10 + 2.5 * Foundation.cos(angle))) <= 1e-12)
        #expect(Swift.abs(cut.point.y - (2.5 + 2.5 * Foundation.sin(angle))) <= 1e-12)
        let first = ArcEdge(start: start, end: cut.point, bulge: cut.firstBulge)
        let second = ArcEdge(start: cut.point, end: end, bulge: cut.secondBulge)
        #expect(Self.rel(first.length, 0.75 * .pi) <= 1e-12)
        #expect(Self.rel(second.length, 1.75 * .pi) <= 1e-12)

        let chain = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: [PDFPoint(x: 0, y: 0), start, cut.point, end],
            pointBulges: [0, cut.firstBulge, cut.secondBulge, 0]
        )
        let result = try engine.calculate(tool: .polylength, geometry: chain, scale: Fixture.unitScale, parameters: .default)
        #expect(Self.rel(result[.planLength]?.value, 10 + 2.5 * .pi) <= 1e-12)
        // Joined back: one arc, bulge 1 again.
        let joined = try #require(BulgeArc.joined(start, cut.point, end, first: cut.firstBulge, second: cut.secondBulge))
        #expect(Self.rel(joined, 1) <= 1e-12)
    }

    /// A line x = 11 crosses the semicircle (centre (10, 2.5), r = 2.5) where (x − 10)² + (y − 2.5)²
    /// = 6.25, i.e. y = 2.5 ± √5.25.
    @Test("An arc crossed on its circle: y = 2.5 ± √5.25")
    func arcLineCrossing() {
        let arc = ArcEdge(start: PDFPoint(x: 10, y: 0), end: PDFPoint(x: 10, y: 5), bulge: 1)
        let line = ArcEdge(start: PDFPoint(x: 11, y: -10), end: PDFPoint(x: 11, y: 20))
        let hits = arc.crossings(with: line, tolerance: 1e-9)
        #expect(hits.count == 2)
        let ys = hits.map(\.point.y).sorted()
        #expect(Swift.abs(ys[0] - (2.5 - 5.25.squareRoot())) <= 1e-12)
        #expect(Swift.abs(ys[1] - (2.5 + 5.25.squareRoot())) <= 1e-12)
    }

    // MARK: Drawing form

    /// The standard cubic with handles 4/3·tan(φ/4) strays at most about 2.7e-4 of the radius from a
    /// quarter circle (the published figure for this construction is 0.027 %).
    @Test("Bézier form: quarter-turn error ≈ 2.7e-4 r; every piece within the stated tolerance")
    func bezierForm() {
        let quarter = BulgeArc.cubicRelativeError(sweep: .pi / 2)
        #expect(quarter > 2.6e-4 && quarter < 2.8e-4)

        for radius in [2.5, 1000.0] {
            // A semicircle of this radius, from (0, 0) to (0, 2r), bulging right (bulge −1 from a
            // clockwise walk is the same curve; use +1 walking downwards).
            let start = PDFPoint(x: 0, y: 2 * radius), end = PDFPoint(x: 0, y: 0)
            let pieces = BulgeArc.cubicPieces(from: start, to: end, bulge: 1, tolerance: 0.01)
            #expect(pieces.last?.end == end)
            // 2.5: the quarter error 6.8e-4 is inside 0.01, so two pieces; 1000: 0.27 is not, so the
            // pieces halve to eighths (error ≈ 4.2e-6 · 1000 = 0.0042).
            #expect(pieces.count == (radius < 10 ? 2 : 4))
            let centre = PDFPoint(x: 0, y: radius)
            var from = start
            var worst = 0.0
            for piece in pieces {
                for step in 0...200 {
                    let t = Double(step) / 200, u = 1 - t
                    let x = u * u * u * from.x + 3 * u * u * t * piece.control1.x + 3 * u * t * t * piece.control2.x + t * t * t * piece.end.x
                    let y = u * u * u * from.y + 3 * u * u * t * piece.control1.y + 3 * u * t * t * piece.control2.y + t * t * t * piece.end.y
                    worst = Swift.max(worst, Swift.abs(PDFPoint(x: x, y: y).distance(to: centre) - radius))
                }
                from = piece.end
            }
            #expect(worst <= 0.01, "radius \(radius): \(worst)")
        }
    }
}
