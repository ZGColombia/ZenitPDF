import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

/// The live `ScaleRegionResolver`, case by case (R-174 follow-up).
///
/// These cases used to sit in `ScaleApplicationTests.swift`, which was deleted with the dead
/// `ScaleApplication` type in iteration 1. They never touched `ScaleApplication`: they called the
/// resolver directly, and the resolver is what the app resolves every committed markup through.
/// `GeometryRegressionTests` keeps the bug-hunt cases (BH-161/162/552/553, IM-065); this suite
/// keeps the plain behaviour — one region, no region, overlap, crossing, an empty geometry — and
/// the `MeasurementGeometry` overload for circles and count points, whose sampler R-170 rewrote.
///
/// Layout, in page points: A = [0, 100] × [0, 100], B = [200, 300] × [0, 100] (apart from A),
/// C = [50, 150] × [50, 150] (overlapping A over [50, 100]²). All priority 0 unless stated.
@Suite("ScaleRegionResolver")
struct ScaleRegionResolverTests {

    private static let a = Fixture.regionID(1)
    private static let b = Fixture.regionID(2)
    private static let c = Fixture.regionID(3)

    private func region(_ id: ScaleRegionID, scale: Int, x: Double, y: Double, size: Double = 100, priority: Int = 0) -> ScaleRegion {
        ScaleRegion(
            id: id,
            pageID: Fixture.pageID(0),
            scaleID: Fixture.scaleID(scale),
            boundary: Fixture.rectRing(x: x, y: y, width: size, height: size),
            priority: priority
        )
    }

    /// A and B, apart.
    private func apart() throws -> ScaleRegionResolver {
        try ScaleRegionResolver(pageID: Fixture.pageID(0), regions: [
            region(Self.a, scale: 1, x: 0, y: 0),
            region(Self.b, scale: 2, x: 200, y: 0)
        ])
    }

    /// A and C, overlapping, with the given priorities.
    private func overlapping(priorityA: Int = 0, priorityC: Int = 0) throws -> ScaleRegionResolver {
        try ScaleRegionResolver(pageID: Fixture.pageID(0), regions: [
            region(Self.a, scale: 1, x: 0, y: 0, priority: priorityA),
            region(Self.c, scale: 3, x: 50, y: 50, priority: priorityC)
        ])
    }

    private func points(_ pairs: [(Double, Double)]) -> [PDFPoint] {
        pairs.map { PDFPoint(x: $0.0, y: $0.1) }
    }

    private func count(_ n: Int, at x: Double, _ y: Double) -> CountPoint {
        CountPoint(id: CountPointID(Fixture.uuid(900 + n)), position: PDFPoint(x: x, y: y))
    }

    // MARK: - Points

    @Test("A point inside one region resolves to that region")
    func pointInOneRegion() throws {
        let r = try apart()
        #expect(r.resolve(point: PDFPoint(x: 50, y: 50)) == .region(Self.a))
        #expect(r.resolve(point: PDFPoint(x: 250, y: 50)) == .region(Self.b))
    }

    @Test("A point outside every region takes the page default")
    func pointOutsideEveryRegion() throws {
        let r = try apart()
        #expect(r.resolve(point: PDFPoint(x: 150, y: 50)) == .pageDefault)
        #expect(r.resolve(point: PDFPoint(x: 50, y: 500)) == .pageDefault)
    }

    @Test("A point in two overlapping regions is ambiguous under .strict, naming both")
    func pointInOverlappingRegions() throws {
        let r = try overlapping()
        #expect(r.resolve(point: PDFPoint(x: 75, y: 75)) == .ambiguous(ScaleRegionAmbiguity(
            candidates: [Self.a, Self.c],
            includesPageDefault: false,
            reason: .pointInOverlappingRegions
        )))
        // Outside the overlap each region answers for itself.
        #expect(r.resolve(point: PDFPoint(x: 25, y: 25)) == .region(Self.a))
        #expect(r.resolve(point: PDFPoint(x: 125, y: 125)) == .region(Self.c))
    }

    @Test("highestPriorityWins breaks a point overlap by priority and reports a tie as a tie")
    func pointPriorityPolicy() throws {
        let cOnTop = try overlapping(priorityA: 0, priorityC: 1)
        #expect(cOnTop.resolve(point: PDFPoint(x: 75, y: 75), policy: .highestPriorityWins) == .region(Self.c))
        // .strict ignores the priorities.
        #expect(cOnTop.resolve(point: PDFPoint(x: 75, y: 75)).isAmbiguous)

        let tied = try overlapping(priorityA: 2, priorityC: 2)
        guard case .ambiguous(let tie) = tied.resolve(point: PDFPoint(x: 75, y: 75), policy: .highestPriorityWins) else {
            Issue.record("a tie at one point must stay ambiguous")
            return
        }
        #expect(tie.reason == .tiedPriorities)
        #expect(Set(tie.candidates) == [Self.a, Self.c])
    }

    // MARK: - Point sets

    @Test("Geometry whose every vertex is inside one region resolves to it")
    func geometryInsideOneRegion() throws {
        let r = try apart()
        #expect(try r.resolve(geometry: points([(10, 10), (90, 10), (90, 90)])) == .region(Self.a))
        #expect(try r.resolve(geometry: points([(210, 10), (290, 90)])) == .region(Self.b))
        #expect(try r.resolve(geometry: points([(120, 10), (180, 90)])) == .pageDefault)
    }

    @Test("Geometry crossing from one region into another is ambiguous under .strict")
    func geometryCrossesTwoRegions() throws {
        let r = try apart()
        // (50, 50) in A, (250, 50) in B — no vertex outside both, so the page default is not a
        // candidate and the reason is the crossing.
        #expect(try r.resolve(geometry: points([(50, 50), (250, 50)])) == .ambiguous(ScaleRegionAmbiguity(
            candidates: [Self.a, Self.b],
            includesPageDefault: false,
            reason: .geometryCrossesRegionBoundary
        )))
        // Priority never resolves a crossing either.
        #expect(try r.resolve(geometry: points([(50, 50), (250, 50)]), policy: .highestPriorityWins).isAmbiguous)
    }

    @Test("Geometry partly outside every region is ambiguous and offers the page default")
    func geometryPartlyOutside() throws {
        let r = try apart()
        #expect(try r.resolve(geometry: points([(50, 50), (150, 50)])) == .ambiguous(ScaleRegionAmbiguity(
            candidates: [Self.a],
            includesPageDefault: true,
            reason: .geometryPartlyOutsideAnyRegion
        )))
    }

    @Test("Resolving an empty point set throws emptyGeometry, on both overloads")
    func emptyGeometry() throws {
        let r = try apart()
        #expect(throws: ScaleApplicationError.emptyGeometry) {
            try r.resolve(geometry: [PDFPoint]())
        }
        // A MeasurementGeometry with nothing in it samples no points and is refused the same way,
        // rather than quietly taking the page default.
        #expect(throws: ScaleApplicationError.emptyGeometry) {
            try r.resolve(geometry: MeasurementGeometry(pageID: Fixture.pageID(0)))
        }
    }

    // MARK: - MeasurementGeometry: circles and count points

    /// The sampler gives a circle its centre and the four extremes of its bounding box.
    /// A circle centred at (50, 50), the middle of A:
    /// - radius 30 reaches x, y in [20, 80] — inside A — so it is A's;
    /// - radius 70 reaches (120, 50), (−20, 50), (50, 120) and (50, −20), all outside A and
    ///   outside B, while its centre is inside A. That is the case the ambiguity prompt exists
    ///   for, and it must never resolve to A on the strength of the centre alone.
    @Test("A circle whose centre is inside a region and whose rim is outside is ambiguous")
    func circleRimOutside() throws {
        let r = try apart()
        let inside = MeasurementGeometry(pageID: Fixture.pageID(0), circles: [CircleGeometry(center: PDFPoint(x: 50, y: 50), radius: 30)])
        #expect(try r.resolve(geometry: inside) == .region(Self.a))

        let circle = CircleGeometry(center: PDFPoint(x: 50, y: 50), radius: 70)
        let rimOutside = MeasurementGeometry(pageID: Fixture.pageID(0), circles: [circle])
        let samples = ScaleRegionResolver.samplePoints(of: rimOutside)
        #expect(samples == points([(50, 50), (120, 50), (-20, 50), (50, 120), (50, -20)]))
        #expect(r.resolve(point: circle.center) == .region(Self.a), "the centre alone would say A")
        #expect(try r.resolve(geometry: rimOutside) == .ambiguous(ScaleRegionAmbiguity(
            candidates: [Self.a],
            includesPageDefault: true,
            reason: .geometryPartlyOutsideAnyRegion
        )))

        // A circle in A whose rim reaches into B: centre (90, 50), radius 120 → (210, 50) is in
        // B, the other extremes outside both. Still ambiguous, now naming both regions.
        let reaching = MeasurementGeometry(pageID: Fixture.pageID(0), circles: [CircleGeometry(center: PDFPoint(x: 90, y: 50), radius: 120)])
        guard case .ambiguous(let crossing) = try r.resolve(geometry: reaching) else {
            Issue.record("a circle reaching into a second region must be ambiguous")
            return
        }
        #expect(crossing.candidates == [Self.a, Self.b])
        #expect(crossing.includesPageDefault)
    }

    @Test("Count points resolve by their symbol positions")
    func countPoints() throws {
        let r = try apart()
        let allInA = MeasurementGeometry(pageID: Fixture.pageID(0), countPoints: [count(1, at: 10, 10), count(2, at: 90, 90)])
        #expect(ScaleRegionResolver.samplePoints(of: allInA) == points([(10, 10), (90, 90)]))
        #expect(try r.resolve(geometry: allInA) == .region(Self.a))

        let acrossAB = MeasurementGeometry(pageID: Fixture.pageID(0), countPoints: [count(1, at: 10, 10), count(2, at: 250, 50)])
        #expect(try r.resolve(geometry: acrossAB) == .ambiguous(ScaleRegionAmbiguity(
            candidates: [Self.a, Self.b],
            includesPageDefault: false,
            reason: .geometryCrossesRegionBoundary
        )))

        let offRegion = MeasurementGeometry(pageID: Fixture.pageID(0), countPoints: [count(1, at: 150, 50)])
        #expect(try r.resolve(geometry: offRegion) == .pageDefault)
    }

    // MARK: - Overlap validation and scale lookup

    @Test("Overlapping and nested regions are refused by validateNoOverlap")
    func overlapIsRejected() throws {
        #expect(throws: ScaleApplicationError.overlappingRegions(Self.a, Self.c)) {
            try overlapping().validateNoOverlap()
        }
        // Nested: no edges cross, but C's vertices are strictly inside A.
        let nested = try ScaleRegionResolver(pageID: Fixture.pageID(0), regions: [
            region(Self.a, scale: 1, x: 0, y: 0),
            region(Self.c, scale: 3, x: 25, y: 25, size: 50)
        ])
        #expect(throws: ScaleApplicationError.overlappingRegions(Self.a, Self.c)) {
            try nested.validateNoOverlap()
        }
        try apart().validateNoOverlap()
    }

    @Test("scale(for:) maps each resolution to its scale, and never guesses for ambiguity")
    func scaleLookup() throws {
        let r = try apart()
        let pageDefault = try Fixture.uniformScale(0)
        let scaleA = try Fixture.uniformScale(1, metresPerPoint: Decimal(string: "0.02")!)
        let scales = [scaleA.id: scaleA]
        #expect(try r.scale(for: .pageDefault, pageDefault: pageDefault, scales: scales) == pageDefault)
        #expect(try r.scale(for: .region(Self.a), pageDefault: pageDefault, scales: scales) == scaleA)
        // B names scale 2, which the table does not hold.
        #expect(throws: ScaleApplicationError.unknownScale(Fixture.scaleID(2), region: Self.b)) {
            try r.scale(for: .region(Self.b), pageDefault: pageDefault, scales: scales)
        }
        // A region this resolver does not hold, and an ambiguous answer: no scale.
        #expect(try r.scale(for: .region(Fixture.regionID(99)), pageDefault: pageDefault, scales: scales) == nil)
        let ambiguous = try r.resolve(geometry: points([(50, 50), (250, 50)]))
        #expect(try r.scale(for: ambiguous, pageDefault: pageDefault, scales: scales) == nil)
    }
}
