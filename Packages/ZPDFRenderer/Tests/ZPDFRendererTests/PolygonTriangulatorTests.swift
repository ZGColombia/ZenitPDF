import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// The triangulator, against an area oracle that shares no code with it.
@Suite("Polygon triangulation")
struct PolygonTriangulatorTests {

    /// An independent shoelace, written here rather than called from the package, so that a bug
    /// in the production one cannot make this test agree with itself. Origin-shifted against the
    /// first vertex per `QUALITY_BAR` 2.2 rule 1.
    private func shoelaceArea(_ contour: [PDFPoint]) -> Double {
        guard contour.count >= 3 else { return 0 }
        let ox = contour[0].x, oy = contour[0].y
        var sum = 0.0
        for index in contour.indices {
            let a = contour[index]
            let b = contour[(index + 1) % contour.count]
            sum += (a.x - ox) * (b.y - oy) - (b.x - ox) * (a.y - oy)
        }
        return abs(sum) / 2
    }

    private func regularPolygon(sides: Int, radius: Double, center: PDFPoint) -> [PDFPoint] {
        (0..<sides).map { step in
            let angle = 2 * Double.pi * Double(step) / Double(sides)
            return PDFPoint(
                x: center.x + radius * Foundation.cos(angle),
                y: center.y + radius * Foundation.sin(angle)
            )
        }
    }

    @Test("Triangle areas sum to the parent's area for a simple polygon")
    func simplePolygonArea() throws {
        for sides in 3...12 {
            let outer = regularPolygon(sides: sides, radius: 120, center: PDFPoint(x: 300, y: 400))
            let triangles = try PolygonTriangulator.triangulate(RenderPolygon(outer: outer))
            let summed = triangles.reduce(0.0) { $0 + $1.area }
            let expected = shoelaceArea(outer)
            #expect(abs(summed - expected) / expected < 1e-9)
            #expect(triangles.count == sides - 2)
        }
    }

    @Test("Triangle areas sum to parent minus holes for one, two and three holes")
    func holesAreSubtracted() throws {
        let outer: [PDFPoint] = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 400, y: 0),
            PDFPoint(x: 400, y: 300), PDFPoint(x: 0, y: 300)
        ]
        let candidates: [[PDFPoint]] = [
            [PDFPoint(x: 40, y: 40), PDFPoint(x: 120, y: 40), PDFPoint(x: 120, y: 120), PDFPoint(x: 40, y: 120)],
            regularPolygon(sides: 7, radius: 40, center: PDFPoint(x: 220, y: 90)),
            [PDFPoint(x: 280, y: 170), PDFPoint(x: 370, y: 180), PDFPoint(x: 320, y: 260)]
        ]
        for holeCount in 1...3 {
            let holes = Array(candidates.prefix(holeCount))
            let triangles = try PolygonTriangulator.triangulate(
                RenderPolygon(outer: outer, holes: holes)
            )
            let summed = triangles.reduce(0.0) { $0 + $1.area }
            let expected = shoelaceArea(outer) - holes.reduce(0.0) { $0 + shoelaceArea($1) }
            #expect(abs(summed - expected) / expected < 1e-9)
        }
    }

    @Test("Winding direction of the input never changes the result")
    func windingIndependence() throws {
        let outer = regularPolygon(sides: 9, radius: 90, center: PDFPoint(x: 200, y: 200))
        let hole = regularPolygon(sides: 5, radius: 30, center: PDFPoint(x: 200, y: 200))
        var areas: Set<Int> = []
        for outerReversed in [false, true] {
            for holeReversed in [false, true] {
                let polygon = RenderPolygon(
                    outer: outerReversed ? outer.reversed() : outer,
                    holes: [holeReversed ? hole.reversed() : hole]
                )
                let summed = try PolygonTriangulator.triangulate(polygon)
                    .reduce(0.0) { $0 + $1.area }
                areas.insert(Int((summed * 1e6).rounded()))
            }
        }
        #expect(areas.count == 1)
    }

    @Test("A self-touching contour terminates and produces the even-odd area")
    func selfTouchingTerminates() throws {
        // A pinched hourglass: the middle vertex appears twice.
        let pinched: [PDFPoint] = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0), PDFPoint(x: 100, y: 120),
            PDFPoint(x: 200, y: 240), PDFPoint(x: 0, y: 240), PDFPoint(x: 100, y: 120)
        ]
        let triangles = try PolygonTriangulator.triangulate(RenderPolygon(outer: pinched))
        #expect(!triangles.isEmpty)
        let summed = triangles.reduce(0.0) { $0 + $1.area }
        // Two mirrored triangles of base 200, height 120: 2 * (200 * 120 / 2).
        #expect(abs(summed - 24_000) / 24_000 < 1e-6)
    }

    @Test("A contour whose edges cross is repaired to its even-odd region, not its hull")
    func crossingContoursAreRepaired() throws {
        // A bowtie. Ear clipping alone fills the convex hull, 40 000 — twice the even-odd area
        // — which is a visible lie about what the markup covers. The repair path exists for this.
        let bowtie: [PDFPoint] = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 200),
            PDFPoint(x: 0, y: 200), PDFPoint(x: 200, y: 0)
        ]
        let bowtieTriangles = try PolygonTriangulator.triangulate(RenderPolygon(outer: bowtie))
        #expect(!bowtieTriangles.isEmpty)
        let bowtieArea = bowtieTriangles.reduce(0.0) { $0 + $1.area }
        // Two lobes meeting at (100, 100): each base 200, height 100.
        #expect(abs(bowtieArea - 20_000) / 20_000 < 1e-6)

        // A figure eight: two unit squares joined at a shared corner, traced as one contour.
        let figureEight: [PDFPoint] = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 100),
            PDFPoint(x: 0, y: 100), PDFPoint(x: 0, y: 0), PDFPoint(x: -100, y: 0),
            PDFPoint(x: -100, y: -100), PDFPoint(x: 0, y: -100)
        ]
        let eightArea = try PolygonTriangulator.triangulate(RenderPolygon(outer: figureEight))
            .reduce(0.0) { $0 + $1.area }
        #expect(abs(eightArea - 20_000) / 20_000 < 1e-6)

        // A hole that pokes out of its parent. Even-odd keeps the part of the hole that lies
        // outside the parent, because that region is enclosed by exactly one contour.
        let parent: [PDFPoint] = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0),
            PDFPoint(x: 100, y: 100), PDFPoint(x: 0, y: 100)
        ]
        let escaping: [PDFPoint] = [
            PDFPoint(x: 50, y: 50), PDFPoint(x: 150, y: 50),
            PDFPoint(x: 150, y: 90), PDFPoint(x: 50, y: 90)
        ]
        let mixedArea = try PolygonTriangulator
            .triangulate(RenderPolygon(outer: parent, holes: [escaping]))
            .reduce(0.0) { $0 + $1.area }
        // 10 000 - (50 x 40 overlap removed) + (50 x 40 protrusion added) = 10 000.
        #expect(abs(mixedArea - 10_000) / 10_000 < 1e-6)
    }

    @Test("Degenerate and hostile input is a typed error, never a hang and never a trap")
    func degenerateInput() {
        #expect(throws: PolygonTriangulator.Failure.fewerThanThreeVertices) {
            try PolygonTriangulator.triangulate(RenderPolygon(outer: []))
        }
        #expect(throws: PolygonTriangulator.Failure.fewerThanThreeVertices) {
            try PolygonTriangulator.triangulate(RenderPolygon(outer: [PDFPoint(x: 1, y: 1)]))
        }
        #expect(throws: PolygonTriangulator.Failure.coordinateOutOfRange) {
            try PolygonTriangulator.triangulate(RenderPolygon(outer: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: .nan, y: 1), PDFPoint(x: 2, y: 2)
            ]))
        }
        #expect(throws: PolygonTriangulator.Failure.coordinateOutOfRange) {
            try PolygonTriangulator.triangulate(RenderPolygon(outer: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 1e9, y: 1), PDFPoint(x: 2, y: 2)
            ]))
        }
        #expect(throws: PolygonTriangulator.Failure.tooManyVertices) {
            let contour = (0..<(RenderLimits.maximumContourVertices + 1)).map {
                PDFPoint(x: Double($0), y: 0)
            }
            return try PolygonTriangulator.triangulate(RenderPolygon(outer: contour))
        }
        #expect(throws: PolygonTriangulator.Failure.tooManyHoles) {
            let hole = [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 0, y: 1)]
            return try PolygonTriangulator.triangulate(RenderPolygon(
                outer: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 0, y: 10)],
                holes: Array(repeating: hole, count: RenderLimits.maximumHoles + 1)
            ))
        }
    }

    @Test("Duplicate and collinear vertices are absorbed rather than producing slivers")
    func duplicatesAndCollinear() throws {
        let square: [PDFPoint] = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 0, y: 0), PDFPoint(x: 50, y: 0),
            PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 100), PDFPoint(x: 0, y: 100),
            PDFPoint(x: 0, y: 0)
        ]
        let triangles = try PolygonTriangulator.triangulate(RenderPolygon(outer: square))
        let summed = triangles.reduce(0.0) { $0 + $1.area }
        #expect(abs(summed - 10_000) / 10_000 < 1e-12)
        #expect(triangles.allSatisfy { $0.area > 0 })
    }

    @Test("A hole sharing a full edge with its parent still leaves the right area")
    func holeSharingParentEdge() throws {
        let outer: [PDFPoint] = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0),
            PDFPoint(x: 200, y: 200), PDFPoint(x: 0, y: 200)
        ]
        let hole: [PDFPoint] = [
            PDFPoint(x: 0, y: 50), PDFPoint(x: 80, y: 50),
            PDFPoint(x: 80, y: 150), PDFPoint(x: 0, y: 150)
        ]
        let triangles = try PolygonTriangulator.triangulate(
            RenderPolygon(outer: outer, holes: [hole])
        )
        let summed = triangles.reduce(0.0) { $0 + $1.area }
        #expect(abs(summed - (40_000 - 8_000)) / 32_000 < 1e-9)
    }

    @Test("A very large but legal polygon triangulates in bounded time")
    func largePolygon() throws {
        let outer = regularPolygon(sides: 2_000, radius: 5_000, center: PDFPoint(x: 0, y: 0))
        let clock = ContinuousClock()
        var triangles: [PolygonTriangulator.Triangle] = []
        let elapsed = clock.measure {
            triangles = (try? PolygonTriangulator.triangulate(RenderPolygon(outer: outer))) ?? []
        }
        #expect(triangles.count == 1_998)
        let summed = triangles.reduce(0.0) { $0 + $1.area }
        #expect(abs(summed - shoelaceArea(outer)) / shoelaceArea(outer) < 1e-9)
        // O(n^2) ear clipping on 2 000 vertices: generous even for a debug build.
        #expect(elapsed < .seconds(30))
    }
}
