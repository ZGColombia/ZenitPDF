import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// The presenter half: the measurement
/// presenter asks the engine whether the cutout being drawn overlaps its parent, with nothing of
/// its own (`CutoutOverlapJudge`). A partial overlap informs (`cutoutOutsideParent`, "Only the
/// part inside is subtracted."); no overlap at all blocks Finish with "A cutout must overlap the
/// area it is subtracted from." — exactly the cutouts the engine refuses on commit.
@MainActor
@Suite("X-cutout-ui: the cutout overlap verdict is the engine's")
struct C2XCutoutOverlapPresenterTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)
    static let documentID = DocumentID(UUID(uuidString: "C2C20000-0000-4000-8000-000000000001")!)
    static let page = ZPDFContracts.PageDescriptor(
        id: PageID(UUID(uuidString: "C2C20000-0000-4000-8000-000000000002")!), documentID: documentID, index: 0, label: "A-1",
        boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
    )
    static let parentID = MarkupID(UUID(uuidString: "C2C20000-0000-4000-8000-0000000000a1")!)

    static func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    /// The 400 × 300 pt area (100, 100)–(500, 400), on a page calibrated 100 pt = 10 m.
    static func sessionWithParent() async throws -> TakeoffSession {
        let session = try TakeoffSession(documentID: documentID, pages: [page], units: .metric)
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let parent = ZPDFContracts.MarkupRecord(
            id: parentID, documentID: documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Slab", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)
            ]))]),
            createdAt: stamp, modifiedAt: stamp
        )
        _ = try await session.apply(.addMarkup(parent))
        return session
    }

    /// A presenter drawing `kind` against the parent, with `points` placed, every fetch and
    /// preview settled.
    static func drawing(
        _ kind: MeasurementKind,
        _ points: [PDFPointValue],
        on session: TakeoffSession,
        parentFirst: Bool = true
    ) async throws -> AppMeasurementToolPresenter {
        let presenter = AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: page.id)
        presenter.adopt(try await session.snapshot())
        presenter.activate(kind: kind)
        if parentFirst {
            presenter.cutoutParentID = parentID
            await presenter.settleCutoutParentForTesting()
            presenter.appendRawPoints(points)
        } else {
            presenter.appendRawPoints(points)
            presenter.cutoutParentID = parentID
            await presenter.settleCutoutParentForTesting()
        }
        await presenter.settlePreviewsForTesting()
        return presenter
    }

    /// The cutout (50, 200)–(150, 300), half past the parent's left edge. The engine accepts it
    /// and subtracts the half inside (the same cutout as X-044 c2's session test).
    ///
    /// Old output: the input flow refused the corner at (50, 200) before the presenter saw it;
    /// a presenter given the shape said nothing about the overlap at all.
    @Test("A polygon cutout partly over its area informs and can be finished")
    func partialPolygonInforms() async throws {
        let session = try await Self.sessionWithParent()
        let presenter = try await Self.drawing(
            .polygonCutout, [Self.p(50, 200), Self.p(150, 200), Self.p(150, 300), Self.p(50, 300)], on: session
        )
        #expect(presenter.liveWarnings.contains(.cutoutOutsideParent), "\(presenter.liveWarnings)")
        #expect(!presenter.hasBlockingWarning, "\(presenter.liveWarnings)")
        #expect(presenter.canCommit)
        #expect(presenter.commitRefusalReason == nil)

        var committed: [MarkupID] = []
        presenter.onCommitCutout = { parent, _ in committed.append(parent) }
        presenter.commitActiveMeasurement()
        #expect(committed == [Self.parentID])
    }

    /// An Ellipse Cutout boxed (50, 200)–(150, 300): the ring its parent loses hangs over the left
    /// edge, so the engine subtracts the part inside.
    @Test("An elliptical cutout partly over its area informs and can be finished")
    func partialEllipseInforms() async throws {
        let session = try await Self.sessionWithParent()
        let presenter = try await Self.drawing(.ellipseCutout, [Self.p(50, 200), Self.p(150, 300)], on: session)
        #expect(presenter.liveWarnings.contains(.cutoutOutsideParent), "\(presenter.liveWarnings)")
        #expect(presenter.canCommit)
        #expect(presenter.commitRefusalReason == nil)
    }

    /// The cutout (500, 200)–(600, 300) touches the parent's right edge and shares no area with
    /// it. Its first corner lies on the edge, so the input flow resolves the parent (edges are
    /// inclusive), and the engine refuses the cutout on commit.
    ///
    /// Old output: no warning, `canCommit` true — Finish sent the cutout, the engine refused it,
    /// and the tray said only "The measurement was not recorded." with the engine's raw error.
    @Test("A cutout that overlaps its area nowhere blocks Finish with the refusal's words")
    func disjointBlocks() async throws {
        let session = try await Self.sessionWithParent()
        let points = [Self.p(500, 200), Self.p(600, 200), Self.p(600, 300), Self.p(500, 300)]
        for parentFirst in [true, false] {
            let presenter = try await Self.drawing(.polygonCutout, points, on: session, parentFirst: parentFirst)
            #expect(presenter.liveWarnings.contains(.cutoutDoesNotOverlapParent), "\(presenter.liveWarnings)")
            #expect(presenter.hasBlockingWarning)
            #expect(!presenter.canCommit)
            #expect(presenter.commitRefusalReason == "A cutout must overlap the area it is subtracted from.")

            var committed = 0
            presenter.onCommitCutout = { _, _ in committed += 1 }
            presenter.commitActiveMeasurement()
            #expect(committed == 0, "nothing is sent for the engine to refuse")
            #expect(presenter.placedPoints == points, "the shape stays, so it can be corrected")
        }

        // The same cutout, sent anyway, is refused by the engine: the verdict is its rule.
        let cutout = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID(uuidString: "C2C20000-0000-4000-8000-0000000000b1")!), documentID: Self.documentID,
            pageID: Self.page.id, kind: .polygon, tool: .polygonCutout, subject: "Opening", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: Self.page.id, points: points.map(PDFPoint.init(shown:))),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        await #expect(throws: (any Error).self) {
            try await session.apply(.addCutout(parent: Self.parentID, cutout: cutout))
        }
    }

    /// Wholly inside: no overlap warning at all.
    @Test("A cutout wholly inside its area raises no overlap warning")
    func containedIsSilent() async throws {
        let session = try await Self.sessionWithParent()
        let presenter = try await Self.drawing(
            .polygonCutout, [Self.p(200, 200), Self.p(300, 200), Self.p(300, 300), Self.p(200, 300)], on: session
        )
        #expect(!presenter.liveWarnings.contains(.cutoutOutsideParent))
        #expect(!presenter.liveWarnings.contains(.cutoutDoesNotOverlapParent))
        #expect(presenter.canCommit)
    }

    /// The judge reads the engine's answer and nothing else: refusal, warning, silence.
    @Test("The judge's three answers are the engine's refusal, warning and silence")
    func judgeMatchesTheEngine() {
        let parent = PolygonRing(points: [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)
        ])
        func cutout(_ points: [PDFPointValue]) -> MeasurementGeometry {
            MeasurementGeometry(pageID: Self.page.id, points: points.map(PDFPoint.init(shown:)))
        }
        #expect(CutoutOverlapJudge.overlap(
            cutout: cutout([Self.p(500, 200), Self.p(600, 200), Self.p(600, 300), Self.p(500, 300)]),
            tool: .polygonCutout, parentOuter: parent) == .disjoint)
        #expect(CutoutOverlapJudge.overlap(
            cutout: cutout([Self.p(50, 200), Self.p(150, 200), Self.p(150, 300), Self.p(50, 300)]),
            tool: .polygonCutout, parentOuter: parent) == .partial)
        #expect(CutoutOverlapJudge.overlap(
            cutout: cutout([Self.p(200, 200), Self.p(300, 200), Self.p(300, 300), Self.p(200, 300)]),
            tool: .polygonCutout, parentOuter: parent) == .contained)
        // An ellipse flush with the parent's edge lies inside (X-044's ring), and one past it
        // overlaps partly.
        #expect(CutoutOverlapJudge.overlap(
            cutout: cutout([Self.p(100, 200), Self.p(200, 300)]), tool: .ellipseCutout, parentOuter: parent) == .contained)
        #expect(CutoutOverlapJudge.overlap(
            cutout: cutout([Self.p(50, 200), Self.p(150, 300)]), tool: .ellipseCutout, parentOuter: parent) == .partial)
        // Too few points to be a hole: no verdict, the commit decides.
        #expect(CutoutOverlapJudge.overlap(
            cutout: cutout([Self.p(200, 200), Self.p(300, 200)]), tool: .polygonCutout, parentOuter: parent) == nil)
    }
}
