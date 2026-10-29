import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// NL-MEASURE-13: the double-count guard's engine half. Every expected area is hand-derived.
@Suite("Overlap guard (NL-MEASURE-13)")
struct OverlapGuardTests {

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, holes: [[(Double, Double)]] = []) -> PolygonGeometry {
        PolygonGeometry(
            outer: Fixture.ring([(x, y), (x + w, y), (x + w, y + h), (x, y + h)]),
            holes: holes.map(Fixture.ring)
        )
    }

    /// [0,10]² and [8,18]×[0,10] share [8,10]×[0,10] = 20 pt².
    @Test("Two overlapping rectangles report the shared 20 pt²")
    func overlappingRectangles() throws {
        let found = try OverlapGuard.overlaps(of: [Self.rect(0, 0, 10, 10), Self.rect(8, 0, 10, 10)])
        #expect(found.count == 1)
        #expect(found.first?.first == 0 && found.first?.second == 1)
        #expect(abs((found.first?.pageArea ?? 0) - 20) < 1e-9)
    }

    @Test("Areas that only share an edge, or are apart, report nothing")
    func touchingAndApart() throws {
        #expect(try OverlapGuard.overlaps(of: [Self.rect(0, 0, 10, 10), Self.rect(10, 0, 10, 10)]).isEmpty)
        #expect(try OverlapGuard.overlaps(of: [Self.rect(0, 0, 10, 10), Self.rect(50, 50, 5, 5)]).isEmpty)
    }

    /// A courtyard hole is not covered: [0,20]² with a [5,15]² hole against [5,15]² shares
    /// nothing; against [0,10]² it shares [0,10]² minus [5,10]² = 100 − 25 = 75 pt².
    @Test("Holes are subtracted before the overlap is measured")
    func holesAreRespected() throws {
        let courtyard = Self.rect(0, 0, 20, 20, holes: [[(5, 5), (15, 5), (15, 15), (5, 15)]])
        #expect(try OverlapGuard.overlaps(of: [courtyard, Self.rect(5, 5, 10, 10)]).isEmpty)
        let found = try OverlapGuard.overlaps(of: [courtyard, Self.rect(0, 0, 10, 10)])
        #expect(abs((found.first?.pageArea ?? 0) - 75) < 1e-9)
    }

    /// Three areas: A=[0,10]², B=[5,15]×[0,10], C=[100,110]². A∩B = 5×10 = 50; C touches none.
    @Test("Only the overlapping pairs are named")
    func onlyOverlappingPairs() throws {
        let found = try OverlapGuard.overlaps(of: [Self.rect(0, 0, 10, 10), Self.rect(5, 0, 10, 10), Self.rect(100, 100, 10, 10)])
        #expect(found.map { [$0.first, $0.second] } == [[0, 1]])
        #expect(abs(found[0].pageArea - 50) < 1e-9)
    }

    /// The hatch's region is the shared rectangle itself: [8,10]×[0,10], four corners, area 20.
    @Test("The shared region comes back for the canvas hatch")
    func sharedRegionIsReturned() throws {
        let found = try OverlapGuard.overlaps(of: [Self.rect(0, 0, 10, 10), Self.rect(8, 0, 10, 10)])
        let region = try #require(found.first?.region)
        #expect(region.count == 1)
        let points = Set(region[0].outer.uniquePoints.map { [$0.x, $0.y] })
        #expect(points == [[8, 0], [10, 0], [10, 10], [8, 10]])
        #expect(region[0].holes.isEmpty)
        // The L-shaped overlap of a courtyard: [0,10]² minus [5,10]² — one ring of six corners.
        let courtyard = Self.rect(0, 0, 20, 20, holes: [[(5, 5), (15, 5), (15, 15), (5, 15)]])
        let lShape = try #require(try OverlapGuard.overlaps(of: [courtyard, Self.rect(0, 0, 10, 10)]).first?.region)
        #expect(lShape.count == 1)
        #expect(lShape[0].outer.uniquePoints.count == 6)
    }
}
