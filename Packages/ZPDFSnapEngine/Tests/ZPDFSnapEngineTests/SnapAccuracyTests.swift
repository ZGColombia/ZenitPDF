import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// `QUALITY_BAR` S2-S5: the snapped point must equal the closed-form point of the named
/// feature, and an ill-conditioned intersection must be refused rather than guessed.
@Suite("Snap point accuracy (QUALITY_BAR S2-S5)")
struct SnapAccuracyTests {

    /// S2's threshold.
    static let pointTolerance = 1e-9
    /// S4's threshold for a shallow crossing.
    static let shallowTolerance = 1e-7

    static func resolve(
        _ scene: SnapScene,
        at cursor: PDFPoint,
        kinds: Set<SnapKind>,
        anchor: PDFPoint? = nil,
        zoom: Double = 1.0
    ) throws -> SnapResolution {
        var settings = SnapSettings.default
        settings.enabledKinds = kinds
        let layout = SnapReplay.layout(zoom: zoom)
        var engine = SnapEngine()
        return try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(
                        cursor, page: scene.page, layout: layout
                    ),
                    layout: layout,
                    anchorPagePoint: anchor
                ),
                settings: settings
            ),
            in: scene.index
        )
    }

    @Test("Endpoint and midpoint of a segment are exact")
    func segmentFeatures() throws {
        let page = try SnapScene.letterPage()
        let start = PDFPoint(x: 137.25, y: 211.5)
        let end = PDFPoint(x: 401.75, y: 388.5)
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: [SnapScene.segment(id: 1, start, end)]
        )

        let atStart = try Self.resolve(
            scene, at: PDFPoint(x: start.x + 0.5, y: start.y + 0.5), kinds: [.endpoint]
        )
        #expect(atStart.winner?.kind == .endpoint)
        #expect(try #require(atStart.winner).position.distance(to: start) <= Self.pointTolerance)

        let midpoint = PDFPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let atMid = try Self.resolve(
            scene, at: PDFPoint(x: midpoint.x + 0.25, y: midpoint.y - 0.25), kinds: [.midpoint]
        )
        #expect(atMid.winner?.kind == .midpoint)
        #expect(try #require(atMid.winner).position.distance(to: midpoint) <= Self.pointTolerance)
    }

    @Test("Nearest point on a segment is the closed-form projection")
    func nearestPointOnSegment() throws {
        let page = try SnapScene.letterPage()
        // A 3-4-5 segment so the projection has an exact closed form.
        let start = PDFPoint(x: 100, y: 100)
        let end = PDFPoint(x: 400, y: 500)
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: [SnapScene.segment(id: 1, start, end)]
        )
        // Direction (0.6, 0.8). Cursor offset from (250, 300) by 4 along the normal (-0.8, 0.6).
        let base = PDFPoint(x: 250, y: 300)
        let cursor = PDFPoint(x: base.x - 0.8 * 4, y: base.y + 0.6 * 4)
        let resolution = try Self.resolve(scene, at: cursor, kinds: [.nearestPointOnSegment])
        #expect(resolution.winner?.kind == .nearestPointOnSegment)
        #expect(
            try #require(resolution.winner).position.distance(to: base) <= Self.pointTolerance
        )
    }

    @Test("Centre and quadrants of a circle are exact")
    func circleFeatures() throws {
        let page = try SnapScene.letterPage()
        let centre = PDFPoint(x: 300, y: 400)
        let radius = 123.5
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: [SnapScene.circle(id: 1, center: centre, radius: radius)]
        )

        let atCentre = try Self.resolve(
            scene, at: PDFPoint(x: centre.x + 1, y: centre.y - 1), kinds: [.center]
        )
        #expect(try #require(atCentre.winner).position.distance(to: centre) <= Self.pointTolerance)

        let east = PDFPoint(x: centre.x + radius, y: centre.y)
        let atEast = try Self.resolve(
            scene, at: PDFPoint(x: east.x + 1, y: east.y + 1), kinds: [.quadrant]
        )
        #expect(try #require(atEast.winner).position.distance(to: east) <= Self.pointTolerance)

        let north = PDFPoint(x: centre.x, y: centre.y + radius)
        let atNorth = try Self.resolve(
            scene, at: PDFPoint(x: north.x - 1, y: north.y + 1), kinds: [.quadrant]
        )
        #expect(try #require(atNorth.winner).position.distance(to: north) <= Self.pointTolerance)
    }

    @Test("The foot of a perpendicular from the in-progress point is exact")
    func perpendicularFoot() throws {
        let page = try SnapScene.letterPage()
        // Horizontal segment: the foot of a perpendicular from (250, 400) is (250, 200).
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.segment(id: 1, PDFPoint(x: 100, y: 200), PDFPoint(x: 400, y: 200))
            ]
        )
        let foot = PDFPoint(x: 250, y: 200)
        let resolution = try Self.resolve(
            scene,
            at: PDFPoint(x: 252, y: 201),
            kinds: [.perpendicularProjection],
            anchor: PDFPoint(x: 250, y: 400)
        )
        #expect(resolution.winner?.kind == .perpendicularProjection)
        #expect(try #require(resolution.winner).position.distance(to: foot) <= Self.pointTolerance)
    }

    @Test("A tangent point from the in-progress point is exact")
    func tangentPoint() throws {
        let page = try SnapScene.letterPage()
        let centre = PDFPoint(x: 300, y: 300)
        let radius = 60.0
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: [SnapScene.circle(id: 1, center: centre, radius: radius)]
        )
        // Anchor at distance 100 along +x. Closed form: the tangent point is at angle
        // +/- acos(r/d) from the anchor direction, i.e. r*(r/d) along x and r*sqrt(1-(r/d)^2)
        // along y from the centre.
        let distance = 100.0
        let anchor = PDFPoint(x: centre.x + distance, y: centre.y)
        let cosine = radius / distance
        let sine = (1 - cosine * cosine).squareRoot()
        let expected = PDFPoint(
            x: centre.x + radius * cosine,
            y: centre.y + radius * sine
        )
        let resolution = try Self.resolve(
            scene,
            at: PDFPoint(x: expected.x + 0.5, y: expected.y + 0.5),
            kinds: [.tangent],
            anchor: anchor
        )
        #expect(resolution.winner?.kind == .tangent)
        #expect(
            try #require(resolution.winner).position.distance(to: expected) <= Self.pointTolerance
        )
    }

    // MARK: - Intersections

    @Test("Line-line intersection matches the closed form (S3)")
    func lineLineIntersection() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.segment(id: 1, PDFPoint(x: 100, y: 100), PDFPoint(x: 400, y: 400)),
                SnapScene.segment(id: 2, PDFPoint(x: 100, y: 400), PDFPoint(x: 400, y: 100))
            ]
        )
        let expected = PDFPoint(x: 250, y: 250)
        let resolution = try Self.resolve(
            scene, at: PDFPoint(x: 251, y: 249), kinds: [.intersection]
        )
        #expect(resolution.winner?.kind == .intersection)
        #expect(
            try #require(resolution.winner).position.distance(to: expected) <= Self.pointTolerance
        )
    }

    @Test("Line-circle intersection matches the closed form (S3)")
    func lineCircleIntersection() throws {
        let page = try SnapScene.letterPage()
        let centre = PDFPoint(x: 300, y: 300)
        let radius = 100.0
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.circle(id: 1, center: centre, radius: radius),
                // A horizontal line at y = 360: x = 300 +/- sqrt(100^2 - 60^2) = 300 +/- 80.
                SnapScene.segment(id: 2, PDFPoint(x: 150, y: 360), PDFPoint(x: 450, y: 360))
            ]
        )
        let expected = PDFPoint(x: 380, y: 360)
        let resolution = try Self.resolve(
            scene, at: PDFPoint(x: 381, y: 361), kinds: [.intersection]
        )
        #expect(resolution.winner?.kind == .intersection)
        #expect(
            try #require(resolution.winner).position.distance(to: expected) <= Self.pointTolerance
        )
    }

    @Test("Circle-circle intersection matches the closed form (S3)")
    func circleCircleIntersection() throws {
        let page = try SnapScene.letterPage()
        // Two unit-style circles of radius 100 whose centres are 120 apart: the crossings are
        // at x = 60 from the first centre and y = +/- sqrt(100^2 - 60^2) = +/- 80.
        let a = PDFPoint(x: 240, y: 300)
        let b = PDFPoint(x: 360, y: 300)
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.circle(id: 1, center: a, radius: 100),
                SnapScene.circle(id: 2, center: b, radius: 100)
            ]
        )
        let expected = PDFPoint(x: 300, y: 380)
        let resolution = try Self.resolve(
            scene, at: PDFPoint(x: 301, y: 381), kinds: [.intersection]
        )
        #expect(resolution.winner?.kind == .intersection)
        #expect(
            try #require(resolution.winner).position.distance(to: expected) <= Self.pointTolerance
        )
    }

    @Test("Line-cubic intersection matches the closed form (S3)")
    func lineCubicIntersection() throws {
        let page = try SnapScene.letterPage()
        // A symmetric cubic from (100,200) to (400,200) with controls pulling it to a peak at
        // t = 0.5. Its value at t = 0.5 is the average of the Bernstein weights:
        // (p0 + 3p1 + 3p2 + p3) / 8.
        let p0 = PDFPoint(x: 100, y: 200)
        let p1 = PDFPoint(x: 200, y: 400)
        let p2 = PDFPoint(x: 300, y: 400)
        let p3 = PDFPoint(x: 400, y: 200)
        let peak = PDFPoint(
            x: (p0.x + 3 * p1.x + 3 * p2.x + p3.x) / 8,
            y: (p0.y + 3 * p1.y + 3 * p2.y + p3.y) / 8
        )
        let curve = try #require(SnapScene.cubic(id: 1, p0, p1, p2, p3))
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                curve,
                // A vertical line through the peak's x, so the intersection is the peak itself.
                SnapScene.segment(
                    id: 2, PDFPoint(x: peak.x, y: 150), PDFPoint(x: peak.x, y: 450)
                )
            ]
        )
        let resolution = try Self.resolve(
            scene, at: PDFPoint(x: peak.x + 0.5, y: peak.y + 0.5), kinds: [.intersection]
        )
        #expect(resolution.winner?.kind == .intersection)
        #expect(try #require(resolution.winner).position.distance(to: peak) <= Self.pointTolerance)
    }

    @Test("Cubic-cubic intersection lands on both curves (S3)")
    func cubicCubicIntersection() throws {
        let page = try SnapScene.letterPage()
        let first = try #require(
            SnapScene.cubic(
                id: 1,
                PDFPoint(x: 100, y: 200), PDFPoint(x: 200, y: 400),
                PDFPoint(x: 300, y: 400), PDFPoint(x: 400, y: 200)
            )
        )
        let second = try #require(
            SnapScene.cubic(
                id: 2,
                PDFPoint(x: 250, y: 150), PDFPoint(x: 200, y: 250),
                PDFPoint(x: 300, y: 350), PDFPoint(x: 250, y: 450)
            )
        )
        let scene = try SnapScene.withVectorContent(page: page, primitives: [first, second])

        // The crossing has no closed form worth writing down, so the test locates it with a
        // wide search first and then asserts the defining property at a realistic cursor
        // distance: the returned point lies on both curves.
        let curveA = SnapCurve.cubic(
            p0: PDFPoint(x: 100, y: 200), p1: PDFPoint(x: 200, y: 400),
            p2: PDFPoint(x: 300, y: 400), p3: PDFPoint(x: 400, y: 200)
        )
        let curveB = SnapCurve.cubic(
            p0: PDFPoint(x: 250, y: 150), p1: PDFPoint(x: 200, y: 250),
            p2: PDFPoint(x: 300, y: 350), p3: PDFPoint(x: 250, y: 450)
        )
        let located = try #require(
            SnapIntersectionSolver.intersections(
                curveA, curveB, near: PDFPoint(x: 250, y: 300), within: 200
            ).first
        )
        let resolution = try Self.resolve(
            scene,
            at: PDFPoint(x: located.point.x + 1, y: located.point.y + 1),
            kinds: [.intersection]
        )
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .intersection)
        #expect(try #require(curveA.nearestPoint(to: winner.position)).distance <= Self.shallowTolerance)
        #expect(try #require(curveB.nearestPoint(to: winner.position)).distance <= Self.shallowTolerance)
    }

    @Test("A shallow crossing lands on both primitives (S4)")
    func shallowCrossing() throws {
        // Two lines crossing at 1 degree: the point is ill-conditioned, so the assertion is
        // proximity to both lines rather than to a hand-computed coordinate.
        let angle = 1.0 * Double.pi / 180
        let a = SnapCurve.line(
            SegmentGeometry(start: PDFPoint(x: 0, y: 300), end: PDFPoint(x: 600, y: 300))
        )
        let b = SnapCurve.line(
            SegmentGeometry(
                start: PDFPoint(x: 0, y: 300 - 300 * Foundation.tan(angle)),
                end: PDFPoint(x: 600, y: 300 + 300 * Foundation.tan(angle))
            )
        )
        let hits = SnapIntersectionSolver.intersections(
            a, b, near: PDFPoint(x: 300, y: 300), within: 10
        )
        let hit = try #require(hits.first)
        #expect(try #require(a.nearestPoint(to: hit.point)).distance <= Self.shallowTolerance)
        #expect(try #require(b.nearestPoint(to: hit.point)).distance <= Self.shallowTolerance)
        #expect(Swift.abs(hit.crossingAngle - angle) < 1e-9)
    }

    @Test("A crossing below half a degree, and an exactly parallel pair, emit nothing (S5)")
    func nearParallelRefusal() throws {
        let horizontal = SnapCurve.line(
            SegmentGeometry(start: PDFPoint(x: 0, y: 300), end: PDFPoint(x: 600, y: 300))
        )

        for degrees in [0.0, 0.1, 0.4, 0.49] {
            let slope = Foundation.tan(degrees * Double.pi / 180)
            let shallow = SnapCurve.line(
                SegmentGeometry(
                    start: PDFPoint(x: 0, y: 300 - 300 * slope),
                    end: PDFPoint(x: 600, y: 300 + 300 * slope)
                )
            )
            let hits = SnapIntersectionSolver.intersections(
                horizontal, shallow, near: PDFPoint(x: 300, y: 300), within: 50
            )
            #expect(hits.isEmpty, "a \(degrees) degree crossing must emit no candidate")
        }

        // Exactly parallel, and exactly collinear.
        let parallel = SnapCurve.line(
            SegmentGeometry(start: PDFPoint(x: 0, y: 305), end: PDFPoint(x: 600, y: 305))
        )
        #expect(
            SnapIntersectionSolver.intersections(
                horizontal, parallel, near: PDFPoint(x: 300, y: 302), within: 50
            ).isEmpty
        )
        let collinear = SnapCurve.line(
            SegmentGeometry(start: PDFPoint(x: 100, y: 300), end: PDFPoint(x: 500, y: 300))
        )
        #expect(
            SnapIntersectionSolver.intersections(
                horizontal, collinear, near: PDFPoint(x: 300, y: 300), within: 50
            ).isEmpty
        )
    }

    @Test("A crossing at 5 degrees is well-conditioned and matches the closed form (S3)")
    func fiveDegreeCrossing() throws {
        let slope = Foundation.tan(5.0 * Double.pi / 180)
        let a = SnapCurve.line(
            SegmentGeometry(start: PDFPoint(x: 0, y: 300), end: PDFPoint(x: 600, y: 300))
        )
        let b = SnapCurve.line(
            SegmentGeometry(
                start: PDFPoint(x: 0, y: 300 - 300 * slope),
                end: PDFPoint(x: 600, y: 300 + 300 * slope)
            )
        )
        let hits = SnapIntersectionSolver.intersections(
            a, b, near: PDFPoint(x: 300, y: 300), within: 10
        )
        let hit = try #require(hits.first)
        #expect(hit.point.distance(to: PDFPoint(x: 300, y: 300)) <= Self.pointTolerance)
    }
}
