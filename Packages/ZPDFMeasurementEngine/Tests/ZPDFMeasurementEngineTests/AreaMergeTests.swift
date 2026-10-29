import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// NL-MEASURE-06 merge: hand-derived unions.
@Suite("Area merge (NL-MEASURE-06)")
struct AreaMergeTests {
    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PolygonGeometry {
        PolygonGeometry(outer: Fixture.ring([(x, y), (x + w, y), (x + w, y + h), (x, y + h)]))
    }

    @Test("Two squares sharing an edge become one 20 × 10 rectangle of 200")
    func sharedEdge() throws {
        let merged = try AreaMerge.union([Self.rect(0, 0, 10, 10), Self.rect(10, 0, 10, 10)])
        #expect(merged.count == 1)
        #expect(abs(CoverageRegions.pdfArea(of: merged[0]) - 200) < 1e-9)
    }

    @Test("Overlapping squares union to 150, never 200")
    func overlapCountedOnce() throws {
        let merged = try AreaMerge.union([Self.rect(0, 0, 10, 10), Self.rect(5, 0, 10, 10)])
        #expect(merged.count == 1)
        #expect(abs(CoverageRegions.pdfArea(of: merged[0]) - 150) < 1e-9)
    }

    @Test("Areas apart stay two polygons, which the caller refuses to store as one")
    func apart() throws {
        #expect(try AreaMerge.union([Self.rect(0, 0, 10, 10), Self.rect(50, 0, 10, 10)]).count == 2)
    }
}
