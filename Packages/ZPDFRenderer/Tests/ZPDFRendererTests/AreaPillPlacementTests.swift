import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer

/// The area-pill anchoring maths: inside the fill at the
/// centroid, or edge-anchored on a leader when the centroid leaves a concave outline or
/// the pill cannot fit. Pure geometry; the app canvas mirrors these numbers in
/// `AreaPillLayout` and its own suite asserts the same values.
struct AreaPillPlacementTests {

    /// The golden scenes' C-shape, so the suite and the goldens agree about the case.
    private let concaveC = [
        PDFPoint(x: 200, y: 260), PDFPoint(x: 440, y: 260), PDFPoint(x: 440, y: 320),
        PDFPoint(x: 260, y: 320), PDFPoint(x: 260, y: 540), PDFPoint(x: 440, y: 540),
        PDFPoint(x: 440, y: 600), PDFPoint(x: 200, y: 600)
    ]

    @Test("A convex polygon takes the pill at its centroid, no leader")
    func convexPolygonAnchorsAtTheCentroid() throws {
        let square = [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100),
            PDFPoint(x: 300, y: 260), PDFPoint(x: 100, y: 260)
        ]
        let placement = try #require(AreaPillPlacement.placement(
            polygon: square, pillHalfWidth: 40, pillHalfHeight: 10
        ))
        #expect(placement.isInterior)
        #expect(abs(placement.center.x - 200) < 1e-9)
        #expect(abs(placement.center.y - 180) < 1e-9)
        #expect(placement.leaderStart == nil && placement.leaderEnd == nil)
    }

    @Test("The concave C's centroid is in the notch, so the pill steps out on a leader")
    func concaveCentroidFallsBackToTheLeader() throws {
        let centroid = try #require(AreaPillPlacement.centroid(of: concaveC))
        #expect(!AreaPillPlacement.contains(concaveC, point: centroid),
                "this scene exists because the centroid must be outside the fill")

        let placement = try #require(AreaPillPlacement.placement(
            polygon: concaveC, pillHalfWidth: 50, pillHalfHeight: 9
        ))
        #expect(!placement.isInterior)
        // The anchor is the bottom vertex (min y, ties on min x): (200, 260).
        #expect(placement.leaderStart == PDFPoint(x: 200, y: 260))
        // The leader runs straight down for its view length…
        let end = try #require(placement.leaderEnd)
        #expect(end.x == 200)
        #expect(abs(end.y - (260 - AreaPillPlacement.leaderLengthViewPoints)) < 1e-9)
        // …and the pill hangs just below it, clear of the leader.
        #expect(placement.center.x == 200)
        #expect(abs(placement.center.y
            - (end.y - AreaPillPlacement.leaderClearanceViewPoints - 9)) < 1e-9)
    }

    @Test("A pill too big for its polygon steps out even when the centroid is inside")
    func oversizedPillFallsBack() throws {
        let smallTriangle = [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 140, y: 100), PDFPoint(x: 120, y: 130)
        ]
        let placement = try #require(AreaPillPlacement.placement(
            polygon: smallTriangle, pillHalfWidth: 60, pillHalfHeight: 12
        ))
        #expect(!placement.isInterior, "a pill wider than the fill must not pretend to sit inside it")
        #expect(placement.leaderStart == PDFPoint(x: 100, y: 100))
    }

    @Test("Degenerate input places nothing rather than NaN")
    func degenerateInputIsRefused() {
        #expect(AreaPillPlacement.placement(
            polygon: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)],
            pillHalfWidth: 10, pillHalfHeight: 5
        ) == nil)
        #expect(AreaPillPlacement.placement(
            polygon: [
                PDFPoint(x: .nan, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1)
            ],
            pillHalfWidth: 10, pillHalfHeight: 5
        ) == nil)
        #expect(AreaPillPlacement.placement(
            polygon: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)
            ],
            pillHalfWidth: 0, pillHalfHeight: 5
        ) == nil)
    }

    @Test("The golden fallback scene really carries a leader and an exterior pill")
    func goldenSceneExercisesTheFallback() throws {
        // The scene builder in ZPDFRendererScenario constructs from this same helper;
        // this pins the input so a polygon edit cannot silently turn the scene convex.
        let placement = try #require(AreaPillPlacement.placement(
            polygon: concaveC, pillHalfWidth: 52.65, pillHalfHeight: 9.25
        ))
        #expect(!placement.isInterior)
    }
}
