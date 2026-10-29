import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFMeasurementEngine
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFUIPresentation

/// Snap and quantities:
/// U-086 (zone and region outlines and calibration points are snap targets), U-085 (an Ellipse
/// Cutout's derived hole ring is not indexed on its parent), U-093 (one ellipse box) and U-090
/// (a commit resolves an ellipse on its ellipse), through the shipping session and environment.
@Suite("Iteration 4 — snap boundaries, cutout holes, ellipse boxes")
struct Iter4QuantitiesCoreSnapTests {

    static let layout = PageViewLayout(zoom: 1, backingScale: 2)
    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    /// One 1 000 × 1 000 pt page, grid snap off so no lattice point sits beside a target.
    static func session() throws -> (TakeoffSession, ZPDFContracts.PageDescriptor) {
        let documentID = DocumentID(UUID(uuidString: "0A086000-0000-4000-8000-000000000001")!)
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID(uuidString: "0A086000-0000-4000-8000-000000000002")!), documentID: documentID, index: 0, label: "A-1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        var settings = SnapSettings.default
        settings.enabledKinds.remove(.grid)
        return (try TakeoffSession(documentID: documentID, pages: [page], snapSettings: settings), page)
    }

    static func candidates(_ session: TakeoffSession, _ page: PageID, at point: PDFPoint) async throws -> [SnapCandidate] {
        await session.resetSnapState()
        let resolution = try await session.resolveSnap(pageID: page, pagePoint: point, layout: layout)
        return [resolution.winner].compactMap { $0 } + resolution.alternatives
    }

    static func winner(_ session: TakeoffSession, _ page: PageID, at point: PDFPoint) async throws -> SnapCandidate? {
        try await candidates(session, page, at: point).first
    }

    static func square(_ x: Double, _ y: Double, _ side: Double) -> [PDFPoint] {
        [PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y), PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)]
    }

    // MARK: - U-086

    /// With the index installed: a calibration (10, 10) → (110, 10) makes both picked points
    /// calibrationPoint targets (priority 1); a Scale Region (200, 200)–(400, 400) makes its outline
    /// a zoneBoundary target — the pointer 1 pt above the bottom edge lands on (300, 200); a
    /// Project Zone (600, 600)–(800, 800) likewise at (700, 600). Undoing the region takes it out
    /// again, hiding the zone takes it out, and a fresh index build holds what is live.
    /// Old output: no candidate at all at any of these points — the boundary layer was never fed
    /// (`buildSnapIndex` passed no boundaries, nothing upserted one).
    @Test("U-086: zone and region outlines and calibration points are snap targets, and follow undo")
    func boundariesAreTargets() async throws {
        let (session, page) = try Self.session()
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 11, y: 11)) == nil)

        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 10, y: 10), second: PDFPoint(x: 110, y: 10),
                                        knownLength: 10, knownLengthUnit: .metre)
        let picked = try #require(try await Self.winner(session, page.id, at: PDFPoint(x: 11, y: 11)))
        #expect(picked.kind == .calibrationPoint && picked.position == PDFPoint(x: 10, y: 10), "\(picked.kind) \(picked.position)")
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 109, y: 11))?.position == PDFPoint(x: 110, y: 10))

        let scaleID = try #require(await session.scale(onPage: page.id)?.id)
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID(uuidString: "0A086000-0000-4000-8000-000000000003")!), pageID: page.id, name: "Detail",
            boundary: Self.square(200, 200, 200), scaleID: scaleID, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1)
        )
        let added = try await session.apply(.setScaleRegions([region]))
        let edge = try #require(try await Self.winner(session, page.id, at: PDFPoint(x: 300, y: 201)))
        #expect(edge.kind == .zoneBoundary && edge.position.distance(to: PDFPoint(x: 300, y: 200)) <= 1e-9, "\(edge.kind) \(edge.position)")

        let zone = ProjectZoneDefinition(
            id: ZoneID(UUID(uuidString: "0A086000-0000-4000-8000-000000000004")!), name: "Level 1", kind: .room,
            pageID: page.id, boundary: Self.square(600, 600, 200), sortOrder: 0, colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0)
        )
        _ = try await session.apply(.setProjectZones([zone]))
        let zoneEdge = try #require(try await Self.winner(session, page.id, at: PDFPoint(x: 700, y: 601)))
        #expect(zoneEdge.kind == .zoneBoundary && zoneEdge.position.distance(to: PDFPoint(x: 700, y: 600)) <= 1e-9)

        _ = try await session.revert(added.inverse)
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 300, y: 201)) == nil, "the undone region is gone")

        var hidden = zone
        hidden.isVisible = false
        _ = try await session.apply(.setProjectZones([hidden]))
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 700, y: 601)) == nil, "a hidden outline is no target")

        _ = try await session.apply(.setScaleRegions([region]))
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 300, y: 201))?.kind == .zoneBoundary)
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 11, y: 11))?.kind == .calibrationPoint)
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 700, y: 601)) == nil)
    }

    // MARK: - U-086 re-fix (it4r): every boundary target is a drawn mark

    /// Asserts that the snap boundary layer is exactly the snapshot's drawn marks for the page,
    /// and that each drawn mark is a live target in the installed index: the pointer 1 pt inside
    /// the first edge's midpoint of an outline wins as zoneBoundary on the edge, the pointer 1 pt
    /// off each calibration pick wins as calibrationPoint on the pick.
    static func expectDrawnEqualsTargets(_ session: TakeoffSession, _ page: PageID, _ comment: String) async throws {
        let drawn = try await session.snapshot().boundaryMarks(onPage: page.rawValue)
        let targets = await session.snapBoundaries(onPage: page)
        #expect(targets == drawn.map(\.snapBoundary), "\(comment): targets \(targets.map(\.id)) drawn \(drawn.map(\.id))")
        #expect(await session.boundaryMarks(onPage: page) == drawn, "\(comment)")
        for mark in drawn {
            switch mark.kind {
            case .projectZone, .scaleRegion:
                let a = mark.points[0], b = mark.points[1]
                let mid = PDFPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let hit = try #require(try await Self.winner(session, page, at: PDFPoint(x: mid.x, y: mid.y + 1)), "\(comment): \(mark.id)")
                #expect(hit.kind == .zoneBoundary && hit.position.distance(to: mid) <= 1e-9, "\(comment): \(mark.id) \(hit.kind) \(hit.position)")
            case .calibration:
                for pick in mark.points {
                    let hit = try #require(try await Self.winner(session, page, at: PDFPoint(x: pick.x + 1, y: pick.y + 1)), "\(comment): \(mark.id)")
                    #expect(hit.kind == .calibrationPoint && hit.position == pick, "\(comment): \(mark.id) \(hit.kind) \(hit.position)")
                }
            }
        }
    }

    /// The page is calibrated (10, 10) → (110, 10); a detail scale is calibrated (800, 100) →
    /// (900, 100) and assigned to a visible Scale Region (200, 200)–(400, 400); a Project Zone
    /// (600, 600)–(800, 800) is visible. The drawn marks are, in order, the zone, the region, the
    /// page's calibration and the detail calibration, and the snap boundary layer is exactly those.
    /// A calibration no visible region uses draws nothing and is no target (the detail picks before
    /// the region exists and after it is hidden); hiding the region takes its outline and its
    /// scale's picks out of both; a recalibration moves the page's picks in both.
    /// Old output (U-086's first fix): the detail scale's picks were calibrationPoint targets with
    /// no region using them, every scale's picks were targets whatever superseded them, and none of
    /// the targets was drawn — the snapshot carried no marks and the canvas stroked no outline.
    @Test("U-086 (it4r): the snap boundary layer is exactly the boundary marks the canvas draws")
    func boundaryTargetsAreTheDrawnMarks() async throws {
        let (session, page) = try Self.session()
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        try await Self.expectDrawnEqualsTargets(session, page.id, "empty page")
        #expect(try await session.snapshot().boundaryMarks.isEmpty)

        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 10, y: 10), second: PDFPoint(x: 110, y: 10),
                                        knownLength: 10, knownLengthUnit: .metre)
        let pageScale = try #require(await session.scale(onPage: page.id)?.id)
        let detail = ScaleID(UUID(uuidString: "0A086000-0000-4000-8000-0000000000D1")!)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 800, y: 100), second: PDFPoint(x: 900, y: 100),
                                        knownLength: 1, knownLengthUnit: .metre, scaleID: detail)
        try await Self.expectDrawnEqualsTargets(session, page.id, "calibrated")
        #expect(try await session.snapshot().boundaryMarks.map(\.id) == ["calibration:" + pageScale.rawValue.uuidString])
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 801, y: 101)) == nil, "a scale no region uses draws no pick")

        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID(uuidString: "0A086000-0000-4000-8000-0000000000D2")!), pageID: page.id, name: "Detail",
            boundary: Self.square(200, 200, 200), scaleID: detail, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1)
        )
        _ = try await session.apply(.setScaleRegions([region]))
        let zone = ProjectZoneDefinition(
            id: ZoneID(UUID(uuidString: "0A086000-0000-4000-8000-0000000000D3")!), name: "Level 1", kind: .room,
            pageID: page.id, boundary: Self.square(600, 600, 200), sortOrder: 0, colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0)
        )
        _ = try await session.apply(.setProjectZones([zone]))
        try await Self.expectDrawnEqualsTargets(session, page.id, "zone + region")
        let calibrations = [pageScale, detail].sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            .map { "calibration:" + $0.rawValue.uuidString }
        #expect(try await session.snapshot().boundaryMarks.map(\.id)
                == ["zone:" + zone.id.rawValue.uuidString, "scaleRegion:" + region.id.rawValue.uuidString] + calibrations)
        let marks = try await session.snapshot().boundaryMarks
        #expect(marks.first?.name == "Level 1" && marks.first?.colorRGBA == zone.colorRGBA && marks.first?.points == zone.boundary)

        var hiddenRegion = region
        hiddenRegion.isVisible = false
        _ = try await session.apply(.setScaleRegions([hiddenRegion]))
        try await Self.expectDrawnEqualsTargets(session, page.id, "region hidden")
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 300, y: 201)) == nil, "a hidden outline is no target")
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 801, y: 101)) == nil, "a hidden region hides its scale's picks")

        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 10, y: 500), second: PDFPoint(x: 110, y: 500),
                                        knownLength: 10, knownLengthUnit: .metre)
        try await Self.expectDrawnEqualsTargets(session, page.id, "recalibrated")
        #expect(try await Self.winner(session, page.id, at: PDFPoint(x: 11, y: 11)) == nil, "a superseded pick is no target")

        // A fresh index build is fed the same marks.
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        try await Self.expectDrawnEqualsTargets(session, page.id, "rebuilt")
    }

    // MARK: - U-085

    /// A 400 × 300 area (100, 100)–(500, 400) with an Ellipse Cutout dragged over (200, 200)–
    /// (400, 300): centre (300, 250), semi-axes 100 and 50. The parent stores the derived hole as
    /// the 360-facet ring, whose vertices sit about 2.5e-5·r outside the ellipse. The pointer 1 pt
    /// off the quadrant (400, 250) is offered the quadrant as markupCenter and wins on the ellipse
    /// (markupEdge or markupCenter); the pointer 2 pt outside
    /// the curve at t = π/3 — curve point (350, 250 + 25√3) — lands on the curve as markupEdge
    /// (within the 1e-9 pt of QUALITY_BAR S2, U-089); no candidate anywhere near is a markupVertex.
    /// Old output: a facet corner of the parent's hole ring about 1.7 pt away won as a priority-0
    /// markupVertex at both pointers.
    @Test("U-085: an Ellipse Cutout snaps at its curve and quadrants, not at its parent's hole facets")
    func ellipseCutoutHoleIsNotIndexed() async throws {
        let (session, page) = try Self.session()
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 10, y: 10), second: PDFPoint(x: 110, y: 10),
                                        knownLength: 10, knownLengthUnit: .metre)
        let parent = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Slab", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)
            ]))]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        _ = try await session.apply(.addMarkup(parent))
        let cutout = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .ellipseCutout,
            subject: "Opening", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 400, y: 300)]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        _ = try await session.apply(.addCutout(parent: parent.id, cutout: cutout))
        let holes = try #require(await session.markup(parent.id)?.geometry?.polygons.first?.holes)
        #expect(holes.first?.points.count == EllipseCutoutRing.facets, "the parent carries the facet ring")
        _ = try await session.buildSnapIndex(page: page, extraction: nil)

        let nearQuadrant = try await Self.candidates(session, page.id, at: PDFPoint(x: 401, y: 251))
        let quadrantWinner = try #require(nearQuadrant.first)
        #expect(quadrantWinner.kind == .markupEdge || quadrantWinner.kind == .markupCenter, "\(quadrantWinner.kind) \(quadrantWinner.position)")
        #expect(nearQuadrant.contains { $0.kind == .markupCenter && $0.position == PDFPoint(x: 400, y: 250) })
        #expect(!nearQuadrant.contains { $0.kind == .markupVertex }, "\(nearQuadrant.map { ($0.kind, $0.position) })")

        let t = Double.pi / 3
        let onCurve = PDFPoint(x: 300 + 100 * cos(t), y: 250 + 50 * sin(t))
        let nx = cos(t) / 100, ny = sin(t) / 50, norm = (nx * nx + ny * ny).squareRoot()
        let nearCurve = try await Self.candidates(session, page.id, at: PDFPoint(x: onCurve.x + 2 * nx / norm, y: onCurve.y + 2 * ny / norm))
        let curve = try #require(nearCurve.first)
        #expect(curve.kind == .markupEdge, "\(curve.kind) \(curve.position)")
        #expect(curve.position.distance(to: onCurve) <= 1e-9, "\(curve.position.distance(to: onCurve)) pt off the ellipse")
        #expect(!nearCurve.contains { $0.kind == .markupVertex })
    }

    // MARK: - U-093

    /// An Ellipse Cutout stored as two corners (100, 100), (300, 200) plus a stray segment
    /// (900, 900)–(950, 950): the hole is the ellipse of the corners' box — centre (200, 150),
    /// semi-axes 100 and 50 (times the facet ring's area factor k) — which is what the engine
    /// measures the child as.
    /// Old output: the ring of the union box (100, 100)–(950, 950), centre (525, 525).
    @Test("U-093: the hole a parent loses is the ellipse its Ellipse Cutout measures")
    func cutoutRingReadsTheEllipseBox() throws {
        var geometry = MeasurementGeometry(pageID: PageID(UUID()), points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 200)])
        geometry.segments = [SegmentGeometry(start: PDFPoint(x: 900, y: 900), end: PDFPoint(x: 950, y: 950))]
        let ring = try #require(TakeoffSession.cutoutRings(of: geometry, tool: .ellipseCutout).first)
        let box = try #require(ring.bounds)
        #expect(Swift.abs(box.center.x - 200) <= 1e-9 && Swift.abs(box.center.y - 150) <= 1e-9, "\(box)")
        #expect(Swift.abs(box.width / box.height - 2) <= 1e-9)
        #expect(Swift.abs(box.width - 200) <= 200 * 1e-4, "\(box.width)")
    }
}

/// U-086 (it4r) through the environment: the canvas presenter publishes the page's boundary
/// marks — what the canvas draws — and they are the snap boundary layer.
@MainActor
@Suite("Iteration 4 — canvas presenter boundary marks (U-086)")
struct Iter4QuantitiesCoreBoundaryMarkPresenterTests {

    /// A zone and a region on the page on screen, and a zone on the second page: the presenter
    /// publishes the first page's two outlines and its calibration, equal to the page's snap
    /// boundaries; hiding the zone through the command bus takes it out of both; turning to the
    /// second page publishes that page's zone.
    /// Old output: the presenter had no marks and the snapshot none to give it.
    @Test("U-086 (it4r): the canvas presenter's marks are the page's snap boundaries")
    func presenterPublishesTheTargets() async throws {
        let documentID = DocumentID(UUID())
        let first = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let second = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 1, label: "A-2",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [first, second])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(page: first.id, first: PDFPoint(x: 10, y: 10), second: PDFPoint(x: 110, y: 10),
                                                 knownLength: 10, knownLengthUnit: .metre)
        let scaleID = try #require(await session.scale(onPage: first.id)?.id)
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: first.id, name: "Detail", boundary: Iter4QuantitiesCoreSnapTests.square(200, 200, 200),
            scaleID: scaleID, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1)
        )
        let zone = ProjectZoneDefinition(
            id: ZoneID(UUID()), name: "Level 1", kind: .room, pageID: first.id,
            boundary: Iter4QuantitiesCoreSnapTests.square(600, 600, 200), sortOrder: 0, colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0)
        )
        let other = ProjectZoneDefinition(
            id: ZoneID(UUID()), name: "Level 2", kind: .floor, pageID: second.id,
            boundary: Iter4QuantitiesCoreSnapTests.square(100, 100, 100), sortOrder: 1, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 0)
        )
        try await environment.commands.perform(.setScaleRegions([region]))
        try await environment.commands.perform(.setProjectZones([zone, other]))
        await environment.refresh()
        #expect(environment.canvas.viewport.pageID == first.id.rawValue)
        #expect(environment.canvas.boundaryMarks.map(\.kind) == [.projectZone, .scaleRegion, .calibration])
        #expect(environment.canvas.boundaryMarks.map(\.snapBoundary) == (await session.snapBoundaries(onPage: first.id)))

        var hidden = zone
        hidden.isVisible = false
        try await environment.commands.perform(.setProjectZones([hidden, other]))
        await environment.refresh()
        #expect(environment.canvas.boundaryMarks.map(\.kind) == [.scaleRegion, .calibration])
        #expect(environment.canvas.boundaryMarks.map(\.snapBoundary) == (await session.snapBoundaries(onPage: first.id)))

        environment.canvas.showPage(try #require(environment.snapshot.pages.first { $0.id == second.id.rawValue }))
        #expect(environment.canvas.boundaryMarks.map(\.id) == ["zone:" + other.id.rawValue.uuidString])
        #expect(environment.canvas.boundaryMarks.map(\.snapBoundary) == (await session.snapBoundaries(onPage: second.id)))
    }
}

/// U-090 through the commit funnel: `AppCoreEnvironment.scaleRegionDecision(for:)` samples an
/// Ellipse Area on its ellipse.
@MainActor
@Suite("Iteration 4 — Scale Region decision for ellipses (U-090)")
struct Iter4QuantitiesCoreEllipseRegionTests {

    /// The diamond region (500, 300), (700, 500), (500, 700), (300, 500) holds the circle of radius
    /// 120 about (500, 500) wholly — each edge is 200/√2 = 141.4 from the centre — while both
    /// stored box corners (380, 380) and (620, 620) lie outside it (x + y = 760 < 800 and
    /// 1 240 > 1 200).
    /// Old output: `.pageDefault` — the commit sampled the two corners, both outside, and the
    /// ellipse measured at the sheet's scale instead of the region's.
    @Test("U-090: an Ellipse Area wholly inside a region is committed at the region's scale")
    func ellipseCommitsAtItsRegion() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                 knownLength: 10, knownLengthUnit: .metre)
        let detail = ScaleID(UUID())
        try await environment.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                 knownLength: 1, knownLengthUnit: .metre, scaleID: detail)
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page.id, name: "Diamond",
            boundary: [PDFPoint(x: 500, y: 300), PDFPoint(x: 700, y: 500), PDFPoint(x: 500, y: 700), PDFPoint(x: 300, y: 500)],
            scaleID: detail, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1)
        )
        try await environment.commands.perform(.setScaleRegions([region]))
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let ellipse = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .measurement, tool: .ellipseArea,
            subject: "Column", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 380, y: 380), PDFPoint(x: 620, y: 620)]),
            createdAt: stamp, modifiedAt: stamp
        )
        guard case .region(let id, let scaleID) = await environment.scaleRegionDecision(for: ellipse) else {
            Issue.record("an ellipse wholly inside the region must take the region's scale")
            return
        }
        #expect(id == region.id && scaleID == detail)
    }
}
