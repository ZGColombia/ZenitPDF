import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFTestingSupport

/// End-to-end from fixture bytes: real PDFs, the real `CGPDFScanner` extractor, the real index,
/// the real engine, asserted against the fixture manifest and against a brute-force scorer.
@Suite("Snap golden (QUALITY_BAR S1, S10, S14, S16)")
struct SnapGoldenTests {

    static var settings: SnapSettings {
        var settings = SnapSettings.default
        // Grid stays on: the brute-force reference implements it too, so leaving it out would
        // make the comparison easier than the product is.
        settings.gridSpacingPoints = 36
        return settings
    }

    static func resolve(
        _ built: SnapFixture.Built,
        at cursor: PDFPoint,
        zoom: Double = 1.0,
        settings: SnapSettings = SnapGoldenTests.settings,
        anchor: PDFPoint? = nil
    ) throws -> SnapResolution {
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: zoom)
        return try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(
                        cursor, page: built.page, layout: layout
                    ),
                    layout: layout,
                    anchorPagePoint: anchor
                ),
                settings: settings
            ),
            in: built.index
        )
    }

    // MARK: - L-shape

    @Test("L-shape: the concave corner is an exact endpoint snap")
    func lShapeConcaveCorner() async throws {
        let built = try await SnapFixture.build(.lShape)
        #expect(built.index.availability == .available)

        // The concave corner of the manifest's ring.
        let corner = PDFPoint(x: 250, y: 250)
        let resolution = try Self.resolve(built, at: PDFPoint(x: 252, y: 253))
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .endpoint)
        #expect(winner.position.distance(to: corner) <= 1e-9)
        #expect(resolution.feedback?.labelKey == "snap.kind.endpoint")
        #expect(resolution.feedback?.sourcePrimitive != nil)
    }

    @Test("L-shape: the midpoint of the long bottom edge is exact")
    func lShapeEdgeMidpoint() async throws {
        let built = try await SnapFixture.build(.lShape)
        // Bottom edge (100,100)-(400,100): midpoint (250,100).
        let midpoint = PDFPoint(x: 250, y: 100)
        let resolution = try Self.resolve(built, at: PDFPoint(x: 251, y: 101.5))
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .midpoint)
        #expect(winner.position.distance(to: midpoint) <= 1e-9)
    }

    @Test("L-shape: away from every vertex the nearest point on the edge wins")
    func lShapeEdge() async throws {
        let built = try await SnapFixture.build(.lShape)
        // A point 2 above the bottom edge, far from both its endpoints and its midpoint.
        let resolution = try Self.resolve(built, at: PDFPoint(x: 175, y: 102))
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .nearestPointOnSegment)
        #expect(winner.position.distance(to: PDFPoint(x: 175, y: 100)) <= 1e-9)
    }

    @Test("L-shape: the engine agrees with the brute-force scorer everywhere (S1)")
    func lShapeAgreesWithBruteForce() async throws {
        try await Self.assertAgreesWithBruteForce(.lShape, over: 100...460, and: 60...480)
    }

    // MARK: - Polygon with a hole

    @Test("Polygon with one hole: the hole's corners and edges are snappable")
    func holeCorners() async throws {
        let built = try await SnapFixture.build(.polygonOneHole)
        for corner in [
            PDFPoint(x: 200, y: 200), PDFPoint(x: 200, y: 300),
            PDFPoint(x: 300, y: 300), PDFPoint(x: 300, y: 200)
        ] {
            let resolution = try Self.resolve(
                built, at: PDFPoint(x: corner.x + 1.5, y: corner.y + 1.5)
            )
            let winner = try #require(resolution.winner, "no candidate near \(corner)" as Comment)
            #expect(winner.kind == .endpoint)
            #expect(winner.position.distance(to: corner) <= 1e-9)
        }

        // On the hole's top edge, out of range of both its corners *and* of its midpoint at
        // (250, 300) — which would otherwise win on priority, midpoint being 4 against
        // nearest-point-on-segment's 9.
        let resolution = try Self.resolve(built, at: PDFPoint(x: 215, y: 301))
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .nearestPointOnSegment)
        #expect(winner.position.distance(to: PDFPoint(x: 215, y: 300)) <= 1e-9)
    }

    @Test("Polygon with one hole: a markup diagonal crosses the hole at a closed-form point")
    func intersectionWithMarkup() async throws {
        // The fixture's own rings do not cross each other, so the intersection case is made by
        // adding a Zenit markup: a diagonal through the hole's left edge at x = 200.
        // The diagonal runs from (150, 150) to (350, 350); it meets x = 200 at y = 200, which is
        // the hole's own corner, so it is shifted to (150, 160) -> (350, 360), meeting x = 200
        // at y = 210.
        let markup = SnapMarkupGeometry(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-0000000000AA") ?? UUID()),
            geometry: [
                .segment(
                    SegmentGeometry(
                        start: PDFPoint(x: 150, y: 160), end: PDFPoint(x: 350, y: 360)
                    )
                )
            ],
            layerID: nil
        )
        let built = try await SnapFixture.build(.polygonOneHole, markups: [markup])
        let expected = PDFPoint(x: 200, y: 210)

        var settings = Self.settings
        // Markup vertex is priority 0 and would win from anywhere nearby; the assertion is
        // about the intersection specifically.
        settings.enabledKinds = [.intersection, .markupVertex]
        let resolution = try Self.resolve(
            built, at: PDFPoint(x: 201, y: 211), settings: settings
        )
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .intersection)
        #expect(winner.position.distance(to: expected) <= 1e-9)
        #expect(resolution.feedback?.secondaryPrimitive != nil)
    }

    @Test("Polygon with one hole: the engine agrees with the brute-force scorer (S1)")
    func holeAgreesWithBruteForce() async throws {
        try await Self.assertAgreesWithBruteForce(.polygonOneHole, over: 90...520, and: 90...520)
    }

    // MARK: - Filtered background

    @Test("The giant background rectangle is never a snap target (S16)")
    func backgroundRectangleIsNotSnappable() async throws {
        let built = try await SnapFixture.build(.giantBackgroundRectangle)
        #expect(built.extraction.filterDecisions.count == 1)

        // Nothing in the index covers the whole media box.
        let pageArea = built.page.boxes.media.area
        for entry in built.index.allEntries(in: .vector) {
            #expect(entry.bounds.area < pageArea * 0.5)
        }

        // The four corners of the page: the background rectangle's own vertices. Nothing may
        // snap to them, and the page corner is where a proximity-only scorer would.
        var settings = Self.settings
        settings.enabledKinds = Set(SnapKind.allCases).subtracting([.grid])
        for corner in [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 612, y: 0),
            PDFPoint(x: 612, y: 792), PDFPoint(x: 0, y: 792)
        ] {
            let probe = PDFPoint(
                x: Swift.min(Swift.max(corner.x, 2), 610),
                y: Swift.min(Swift.max(corner.y, 2), 790)
            )
            let resolution = try Self.resolve(built, at: probe, settings: settings)
            #expect(resolution.winner == nil, "snapped to the background near \(corner)" as Comment)
        }

        // The real geometry is still reachable.
        let atLineEnd = try Self.resolve(built, at: PDFPoint(x: 201, y: 201), settings: settings)
        #expect(atLineEnd.winner?.kind == .endpoint)
        #expect(
            try #require(atLineEnd.winner).position.distance(to: PDFPoint(x: 200, y: 200)) <= 1e-9
        )
    }

    // MARK: - Scanned page

    @Test("A scanned page reports unavailable and emits no vector candidate (S14)")
    func scannedPage() async throws {
        let markup = SnapMarkupGeometry(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-0000000000BB") ?? UUID()),
            geometry: [.point(PDFPoint(x: 300, y: 300))],
            layerID: nil
        )
        let built = try await SnapFixture.build(.scannedLookPage, markups: [markup])

        #expect(built.index.availability == .unavailable(.noVectorContent))
        #expect(built.index.vectorPrimitiveCount == 0)
        #expect(built.index.availability.messageKey == "snap.vector.unavailable.noVectorContent")

        // Markup snap works.
        let atMarkup = try Self.resolve(built, at: PDFPoint(x: 301, y: 302))
        #expect(atMarkup.winner?.kind == .markupVertex)

        // Grid snap works.
        var gridSettings = Self.settings
        gridSettings.gridSpacingPoints = 50
        let atGrid = try Self.resolve(
            built, at: PDFPoint(x: 148, y: 452), settings: gridSettings
        )
        #expect(atGrid.winner?.kind == .grid)

        // No vector candidate, anywhere on the page.
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)
        for x in stride(from: 20.0, through: 600.0, by: 37.0) {
            for y in stride(from: 20.0, through: 780.0, by: 53.0) {
                let resolution = try engine.resolve(
                    SnapQuery(
                        event: SnapPointerEvent(
                            viewPoint: try SnapReplay.viewPoint(
                                PDFPoint(x: x, y: y), page: built.page, layout: layout
                            ),
                            layout: layout
                        ),
                        settings: Self.settings
                    ),
                    in: built.index
                )
                let emitted = ([resolution.winner].compactMap { $0 } + resolution.alternatives)
                #expect(emitted.allSatisfy { !$0.kind.requiresVectorContent })
            }
        }
    }

    // MARK: - Rotation and crop (S10)

    @Test(
        "Rotated pages snap to the same unrotated page-space point",
        arguments: [FixtureKind.rotation0, .rotation90, .rotation180, .rotation270]
    )
    func rotatedPages(_ kind: FixtureKind) async throws {
        let built = try await SnapFixture.build(kind)
        // The fixture's marker is (72,72) -> (72,672) -> (172,672) in unrotated page space, and
        // `/Rotate` is a presentation instruction that does not move it.
        let corner = PDFPoint(x: 72, y: 672)

        for zoom in [0.25, 1.0, 4.0] {
            let resolution = try Self.resolve(
                built, at: PDFPoint(x: 73, y: 671), zoom: zoom
            )
            let winner = try #require(resolution.winner, "\(kind.rawValue) at zoom \(zoom)" as Comment)
            #expect(winner.kind == .endpoint)
            #expect(winner.position.distance(to: corner) <= 1e-9)
        }

        // The view -> page -> view round trip is exact.
        let layout = SnapReplay.layout(zoom: 3.0)
        let converter = try PageCoordinateConverter(page: built.page, layout: layout)
        for point in [corner, PDFPoint(x: 72, y: 72), PDFPoint(x: 172, y: 672)] {
            let view = try converter.pageToView(point)
            let back = try converter.viewToPage(view)
            #expect(Swift.abs(back.x - point.x) <= 1e-12 * Swift.max(1, Swift.abs(point.x)))
            #expect(Swift.abs(back.y - point.y) <= 1e-12 * Swift.max(1, Swift.abs(point.y)))
        }
    }

    @Test("A negative media and crop origin does not move the snap")
    func negativeOrigin() async throws {
        let built = try await SnapFixture.build(.cropBoxNegativeOrigin)
        // The fixture's line starts exactly on the media box corner.
        let start = PDFPoint(x: -100, y: -50)
        let end = PDFPoint(x: 140, y: 270)
        let midpoint = PDFPoint(x: 20, y: 110)

        let atStart = try Self.resolve(built, at: PDFPoint(x: -99, y: -49))
        #expect(try #require(atStart.winner).position.distance(to: start) <= 1e-9)

        let atMid = try Self.resolve(built, at: PDFPoint(x: 21, y: 111))
        #expect(try #require(atMid.winner).kind == .midpoint)
        #expect(try #require(atMid.winner).position.distance(to: midpoint) <= 1e-9)

        let atEnd = try Self.resolve(built, at: PDFPoint(x: 139, y: 269))
        #expect(try #require(atEnd.winner).position.distance(to: end) <= 1e-9)

        // The grid is anchored on the visible box, not on (0,0), so a negative crop origin does
        // not shift the lattice off the page.
        var gridSettings = Self.settings
        gridSettings.enabledKinds = [.grid]
        gridSettings.gridSpacingPoints = 25
        let atGrid = try Self.resolve(
            built, at: PDFPoint(x: -49, y: -24), settings: gridSettings
        )
        #expect(try #require(atGrid.winner).position == PDFPoint(x: -50, y: -25))
    }

    // MARK: - Bézier circle (CR-35, CR-43)

    @Test("Bézier circle: the chord midpoint is not a snap target; the centre and the arc are (CR-35)")
    func bezierCircleHasNoChordCandidates() async throws {
        let built = try await SnapFixture.build(.bezierCircle)
        #expect(built.index.availability == .available)
        // Four cubics and the ring's centre; the ring itself is not bridged as chords.
        #expect(built.index.vectorPrimitiveCount == 5)

        // The fixture's closed form: centre (306, 396), radius 144. The midpoint of the chord
        // from the east vertex to the north vertex is (378, 468), 42 pt inside the arc, where
        // nothing is drawn.
        let atChord = try Self.resolve(built, at: PDFPoint(x: 378, y: 468))
        // Old output: winner `.midpoint` at (378, 468) — the ring bridged as a diamond of chords.
        #expect(atChord.winner == nil, "\(String(describing: atChord.winner))" as Comment)

        let centre = PDFPoint(x: 306, y: 396)
        let atCentre = try Self.resolve(built, at: PDFPoint(x: 307, y: 397))
        let centreWinner = try #require(atCentre.winner)
        #expect(centreWinner.kind == .center)
        #expect(centreWinner.position.distance(to: centre) <= 1e-9)

        // At 45° the four-Bézier construction passes exactly through the circle, and that
        // point is the east–north cubic's own midpoint (t = 0.5).
        let on45 = PDFPoint(x: 306 + 144 / 2.0.squareRoot(), y: 396 + 144 / 2.0.squareRoot())
        let atArc = try Self.resolve(built, at: PDFPoint(x: on45.x + 1, y: on45.y + 1))
        let arcWinner = try #require(atArc.winner)
        #expect(arcWinner.kind == .midpoint)
        #expect(arcWinner.position.distance(to: on45) <= 1e-9)
    }

    @Test("Bézier circle: the engine agrees with the brute-force scorer everywhere (S1, CR-43)")
    func bezierCircleAgreesWithBruteForce() async throws {
        let built = try await SnapFixture.build(.bezierCircle)
        try Self.assertAgreesWithBruteForce(
            name: FixtureKind.bezierCircle.rawValue, page: built.page, index: built.index,
            over: 150...460, and: 245...550
        )
    }

    @Test("Circle, arc, cubic and a rotated parallelogram: the engine agrees with the brute-force scorer (S1, CR-43)")
    func curvedSceneAgreesWithBruteForce() throws {
        let page = try SnapScene.letterPage()
        var primitives: [SnapPrimitive] = [
            SnapScene.circle(id: 1, center: PDFPoint(x: 300, y: 300), radius: 100),
            // Two chords through the circle, crossing each other at its centre.
            SnapScene.segment(id: 2, PDFPoint(x: 150, y: 250), PDFPoint(x: 450, y: 350)),
            SnapScene.segment(id: 3, PDFPoint(x: 300, y: 150), PDFPoint(x: 300, y: 450)),
            // The lower-left quarter of a circle at (520, 520), radius 60.
            SnapPrimitive(
                id: 4,
                bounds: PDFRect(x: 460, y: 460, width: 120, height: 120),
                kind: .ellipticalArc,
                geometry: .ellipticalArc(
                    ArcGeometry(center: PDFPoint(x: 520, y: 520), radius: 60,
                                startAngle: Double.pi, sweepAngle: Double.pi / 2)
                ),
                sourceObjectID: 4, confidence: 1, layerID: nil
            ),
            // A diagonal through the arc's 225° point.
            SnapScene.segment(id: 7, PDFPoint(x: 440, y: 440), PDFPoint(x: 560, y: 560))
        ]
        // An arch crossing the arc and the diagonal.
        primitives.append(try #require(SnapScene.cubic(
            id: 5, PDFPoint(x: 420, y: 440), PDFPoint(x: 460, y: 540),
            PDFPoint(x: 560, y: 540), PDFPoint(x: 600, y: 440)
        )))
        // A rotated parallelogram: its centre is a candidate, at the diagonals' midpoint.
        primitives.append(try #require(SnapScene.polyline(
            id: 6,
            [PDFPoint(x: 150, y: 450), PDFPoint(x: 250, y: 470),
             PDFPoint(x: 270, y: 570), PDFPoint(x: 170, y: 550)],
            isClosed: true
        )))
        let scene = try SnapScene.withVectorContent(page: page, primitives: primitives)
        try Self.assertAgreesWithBruteForce(
            name: "curved-scene", page: scene.page, index: scene.index, over: 130...620, and: 130...620
        )
    }

    // MARK: - Brute force agreement

    /// Sweeps a grid of cursor positions and requires the engine's `(kind, id, point)` to equal
    /// the brute-force scorer's at every one of them, at every zoom in the S7 list.
    static func assertAgreesWithBruteForce(
        _ kind: FixtureKind,
        over xs: ClosedRange<Double>,
        and ys: ClosedRange<Double>
    ) async throws {
        let built = try await SnapFixture.build(kind)
        try assertAgreesWithBruteForce(
            name: kind.rawValue, page: built.page, index: built.index, over: xs, and: ys
        )
    }

    static func assertAgreesWithBruteForce(
        name: String,
        page: PageDescriptor,
        index: SnapIndex,
        over xs: ClosedRange<Double>,
        and ys: ClosedRange<Double>
    ) throws {
        var reference = SnapBruteForceReference(settings: settings)

        // The truncation limits must not be reached, or the comparison would be testing the
        // truncation rule rather than the scorer.
        #expect(index.primitiveCount < SnapIndexLimits.standard.maximumIntersectionPrimitives)

        var compared = 0
        for zoom in [0.05, 0.25, 1.0, 4.0, 16.0, 64.0] {
            let layout = SnapReplay.layout(zoom: zoom)
            var engine = SnapEngine()
            for x in stride(from: xs.lowerBound, through: xs.upperBound, by: 17.0) {
                for y in stride(from: ys.lowerBound, through: ys.upperBound, by: 23.0) {
                    let cursor = PDFPoint(x: x, y: y)
                    // A fresh engine per position: hysteresis is a *history* term and the
                    // brute-force scorer has no history, so comparing them requires none here.
                    engine.reset()
                    let resolution = try engine.resolve(
                        SnapQuery(
                            event: SnapPointerEvent(
                                viewPoint: try SnapReplay.viewPoint(
                                    cursor, page: page, layout: layout
                                ),
                                layout: layout
                            ),
                            settings: settings
                        ),
                        in: index
                    )
                    let expected = reference.winner(
                        in: index, cursor: cursor, zoom: zoom
                    )
                    compared += 1

                    let where_: Comment = "\(name) zoom \(zoom) at \(cursor)"
                    // The pair budget must not have been reached either (CR-37): the
                    // reference solves every pair.
                    #expect(!resolution.isIntersectionSearchTruncated, where_)
                    guard let expected else {
                        #expect(resolution.winner == nil, where_)
                        continue
                    }
                    let winner = try #require(resolution.winner, where_)
                    #expect(winner.kind == expected.kind, where_)
                    #expect((winner.primitiveID ?? 0) == expected.primitiveID, where_)
                    #expect(winner.position.distance(to: expected.position) <= 1e-9, where_)
                }
            }
        }
        #expect(compared > 1000)
    }
}
