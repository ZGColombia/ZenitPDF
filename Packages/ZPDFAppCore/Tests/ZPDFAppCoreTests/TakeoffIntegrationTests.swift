import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFUIPresentation

/// The product in miniature.
///
/// Open a real PDF, calibrate a scale on it, snap a vertex to geometry the file actually
/// contains, draw an area with a cutout, watch the row appear in the ledger with the right
/// number and the right unit, undo it, watch it go.
///
/// Nothing here is mocked. The measurement engine computes the area, the snap engine finds
/// the corner, the aggregation core builds the row, `UndoManager` drives the undo, and the
/// presenters are the same ones the UI binds to.
@Suite("Takeoff integration")
struct TakeoffIntegrationTests {

    // The `geo-rectangle` fixture is a 288 × 180 stroked rectangle whose lower-left corner
    // is at (72, 72), with closed-form area 51 840 pt² recorded in its manifest.
    static let corner = PDFPointValue(x: 72, y: 72)
    static let rightBottom = PDFPointValue(x: 360, y: 72)
    static let rightTop = PDFPointValue(x: 360, y: 252)
    static let leftTop = PDFPointValue(x: 72, y: 252)

    /// 288 pt is declared to be 28.8 m, so one PDF point is exactly 0.1 m and one square
    /// PDF point is exactly 0.01 m². Chosen so the expected area is exact in `Decimal` and
    /// the assertion is an equality rather than a tolerance.
    static let knownLength: Decimal = 28.8

    @Test("Open, calibrate, draw an area with a cutout, snap a vertex, read the row, undo it")
    @MainActor
    func theWholeProduct() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        // 1 ─ Open a real fixture through PDFKit and the vector scanner.
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        #expect(fixture.pages.count == 1)
        let page = fixture.firstPage

        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )
        let environment = try await AppCoreEnvironment.make(
            session: session,
            documentID: fixture.documentID
        )

        // The ledger starts empty, and says so through its count rather than through an
        // array anyone could accidentally materialise.
        #expect(environment.ledger.rowCount == 0)
        #expect(environment.ledger.isEmpty)

        // 2 ─ Calibrate. 288 pt of the rectangle's base is declared to be 28.8 m.
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(shown: Self.corner),
            second: PDFPoint(shown: Self.rightBottom),
            knownLength: Self.knownLength,
            knownLengthUnit: .metre,
            label: "Base of the test rectangle"
        )
        let scale = try #require(await session.firstPageScale)
        #expect(abs(scale.matrix.metresPerPointX - 0.1) < 1e-12, "one PDF point is 0.1 m")
        #expect(scale.matrix.isUniform)

        // 3 ─ Snap a vertex. The pointer is 3 pt inside the rectangle's top-right corner;
        //     the snap engine must put the point exactly on the corner the file draws.
        let availability = try await session.buildSnapIndex(page: page, extraction: fixture.extraction)
        #expect(availability.allowsVectorCandidates, "the rectangle fixture has vector content")

        let resolution = try await session.resolveSnap(
            pageID: page.id,
            pagePoint: PDFPoint(x: 357, y: 249),
            layout: PageViewLayout(zoom: 1, backingScale: 2)
        )
        let winner = try #require(resolution.winner, "a corner 3 pt away is inside the 10 px radius")
        #expect(winner.kind == .endpoint)
        #expect(abs(resolution.resolvedPagePoint.x - Self.rightTop.x) < 1e-9)
        #expect(abs(resolution.resolvedPagePoint.y - Self.rightTop.y) < 1e-9)

        // 4 ─ Draw the area on the snapped vertices, then cut a hole in it.
        let areaID = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(
            Self.areaMarkup(
                id: areaID,
                documentID: fixture.documentID,
                pageID: page.id,
                ring: [Self.corner, Self.rightBottom, Self.rightTop, Self.leftTop]
            )
        ))

        // 40 × 50 pt hole = 2 000 pt² = 20 m².
        let cutoutID = MarkupID(UUID())
        try await environment.commands.perform(.addCutout(
            parent: areaID,
            cutout: Self.areaMarkup(
                id: cutoutID,
                documentID: fixture.documentID,
                pageID: page.id,
                tool: .polygonCutout,
                subject: "Opening",
                ring: [
                    PDFPointValue(x: 120, y: 120),
                    PDFPointValue(x: 160, y: 120),
                    PDFPointValue(x: 160, y: 170),
                    PDFPointValue(x: 120, y: 170)
                ]
            )
        ))

        // 5 ─ The row is in the ledger, addressed by index, with the right value and unit.
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 2, "the area and its cutout are both rows")

        let position = try #require(environment.ledger.index(of: areaID.rawValue))
        let row = try #require(environment.ledger.row(at: position))
        #expect(row.markupID == areaID.rawValue)

        // 288 × 180 = 51 840 pt²; at 0.01 m² per pt² that is exactly 518.40 m² gross. Since
        // ADR-0016 (BH-017) the Plan Area column reads the **net** field, so the row shows
        // 518.40 − 20.00 (the 40 × 50 pt hole) = 498.40 m². The scale was chosen to make this
        // exact, so the assertion is an equality on `Decimal`, not a tolerance on a `Double`.
        let planArea = try #require(row.quantity("planArea"))
        #expect(planArea.value == Decimal(string: "498.4"), "net plan area in square metres")
        #expect(planArea.dimension == QuantityDimension.area)
        #expect(row.displayValue("planArea") == "498.40")
        #expect(row.displayValue("perimeter") == "93.60", "2 × (28.8 + 18.0) m")

        // The unit reaches the UI on the column, which is what the header and the
        // accessibility label read.
        let column = try #require(environment.ledger.column("planArea"))
        #expect(column.displayUnitSymbol == "m²")
        #expect(column.dimension == QuantityDimension.area)

        // The cutout really was subtracted. `netArea` is a measurement field (spec 12.4)
        // but *not* a column in spec 15.2's frozen list, so it is asserted on the stored
        // result rather than on the row — see the package README, "Known contract gaps".
        let stored = try #require(await session.markup(areaID))
        let measured = try #require(stored.measurement)
        let netArea = try #require(measured[.netArea])
        #expect(netArea.value == Decimal(string: "498.4"), "518.40 m² less the 20 m² hole")
        #expect(measured[.cutoutArea]?.value == Decimal(string: "20"))

        // 6 ─ The totals come from the aggregation core, not from the rows on screen.
        // Both rows carry a plan area, so the grand total is the sum of the two.
        let total = try #require(environment.ledger.grandTotals.total("planArea"))
        // ADR-0016: the cutout row carries no net area, so only the slab's 498.40 m² sums.
        #expect(total.value == Decimal(string: "498.4"), "the slab's net 498.40 m²; the opening row adds none")

        // 7 ─ Undo. The row goes, and so does the markup the canvas draws.
        #expect(environment.commands.undoManager.canUndo)
        await environment.commands.undo()
        await environment.ledger.refresh()

        #expect(environment.ledger.index(of: cutoutID.rawValue) == nil, "the cutout is gone")
        #expect(environment.ledger.rowCount == 1, "the area survives; only the cutout was undone")

        // The parent's number is restored too: undoing a cutout and leaving the reduced net
        // area behind would be the worst possible outcome — a quantity nothing on screen
        // explains.
        let restoredPosition = try #require(environment.ledger.index(of: areaID.rawValue))
        let restored = try #require(environment.ledger.row(at: restoredPosition))
        #expect(try #require(restored.quantity("planArea")).value == Decimal(string: "518.4"))
        let restoredRecord = try #require(await session.markup(areaID))
        let restoredMeasurement = try #require(restoredRecord.measurement)
        #expect(restoredMeasurement[.netArea]?.value == Decimal(string: "518.4"), "the hole is gone")
        #expect(restoredRecord.cutoutMarkupIDs.isEmpty)

        // 8 ─ Undo again: the area itself goes, and the canvas empties with the ledger.
        await environment.commands.undo()
        await environment.refresh()
        #expect(environment.ledger.rowCount == 0)
        #expect(environment.ledger.index(of: areaID.rawValue) == nil)
        #expect(environment.canvas.visibleMarkups.isEmpty, "the canvas reflects the undo too")

        // 9 ─ Redo brings it back, through the same mechanism running the other way.
        await environment.commands.redo()
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 1)
        #expect(environment.ledger.index(of: areaID.rawValue) != nil)
    }

    @Test("Without a scale there is no number, and the row says so instead of guessing")
    @MainActor
    func noScaleNoNumber() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let page = fixture.firstPage
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let environment = try await AppCoreEnvironment.make(
            session: session,
            documentID: fixture.documentID
        )

        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(
            Self.areaMarkup(
                id: id,
                documentID: fixture.documentID,
                pageID: page.id,
                ring: [Self.corner, Self.rightBottom, Self.rightTop, Self.leftTop]
            )
        ))
        await environment.ledger.refresh()

        let position = try #require(environment.ledger.index(of: id.rawValue))
        let row = try #require(environment.ledger.row(at: position))
        // The geometry is stored; the quantity is absent. An unscaled drawing must never
        // produce a plausible-looking figure (spec 10.2).
        #expect(row.quantity("planArea") == nil)
        #expect(row.displayValue("planArea").isEmpty)
        #expect(environment.ledger.grandTotals.total("planArea") == nil)
    }

    @Test("Calibrating after the fact restamps the measurements that predate the scale")
    @MainActor
    func calibratingLaterRecomputes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let page = fixture.firstPage
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let environment = try await AppCoreEnvironment.make(
            session: session,
            documentID: fixture.documentID
        )

        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(
            Self.areaMarkup(
                id: id,
                documentID: fixture.documentID,
                pageID: page.id,
                ring: [Self.corner, Self.rightBottom, Self.rightTop, Self.leftTop]
            )
        ))

        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(shown: Self.corner),
            second: PDFPoint(shown: Self.rightBottom),
            knownLength: Self.knownLength,
            knownLengthUnit: .metre
        )
        await environment.ledger.refresh()

        let position = try #require(environment.ledger.index(of: id.rawValue))
        let row = try #require(environment.ledger.row(at: position))
        let area = try #require(row.quantity("planArea"))
        #expect(area.value == Decimal(string: "518.4"))

        // And the restamp is undoable with the calibration that caused it.
        await environment.commands.undo()
        await environment.ledger.refresh()
        let after = try #require(environment.ledger.row(at: 0))
        #expect(after.quantity("planArea") == nil, "undoing the calibration takes the number with it")
    }

    // MARK: Helpers

    /// A polygon area markup over a page-space ring.
    static func areaMarkup(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        tool: MeasurementTool = .area,
        subject: String = "Floor slab",
        ring: [PDFPointValue]
    ) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: tool,
            subject: subject,
            label: "",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [
                    PolygonGeometry(
                        outer: PolygonRing(points: ring.map { PDFPoint(shown: $0) }, isClosed: true)
                    )
                ]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }
}
