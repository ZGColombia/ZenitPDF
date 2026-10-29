import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport

/// CR-1 and CR-19: a parent's holes are derived from the cutouts it names *now*.
///
/// `applyCutout` used to merge the cutout's ring into the parent's stored polygon for good.
/// Deleting the cutout edited `cutoutMarkupIDs` and left the ring in place; moving it moved
/// the child and not the hole; and the merged ring was saved, so a reopened project inherited
/// the wrong number. Every test states the number the old code produced.
///
/// 100 pt = 10 m, so 1 pt = 0.1 m and 1 pt² = 0.01 m². The parent is 100 × 80 pt = 80 m², the
/// cutout 20 × 20 pt = 4 m². Exact in `Decimal`, so every assertion is an equality.
@Suite("Cutout holes are derived")
struct CutoutHoleRebuildTests {

    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private static let parentRing = [
        PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)
    ]
    private static let cutoutRing = [
        PDFPoint(x: 10, y: 10), PDFPoint(x: 30, y: 10), PDFPoint(x: 30, y: 30), PDFPoint(x: 10, y: 30)
    ]

    private static func makeSession() async throws -> (TakeoffSession, PageID, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        return (session, page.id, documentID)
    }

    private static func polygon(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        tool: ZPDFContracts.MeasurementTool,
        ring: [PDFPoint],
        holes: [[PDFPoint]] = [],
        locked: Bool = false,
        parentMarkupID: MarkupID? = nil,
        cutoutMarkupIDs: [MarkupID] = []
    ) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: tool == .area ? .measurement : .polygon,
            tool: tool,
            subject: tool == .area ? "Slab" : "Opening",
            author: "test",
            locked: locked,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(
                    outer: PolygonRing(points: ring, isClosed: true),
                    holes: holes.map { PolygonRing(points: $0, isClosed: true) }
                )]
            ),
            parentMarkupID: parentMarkupID,
            cutoutMarkupIDs: cutoutMarkupIDs,
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// The parent's **net** area — `netArea` while it has a hole, the gross `planArea` once it
    /// has none (the engine emits the net fields only for a polygon with cutouts) — and a
    /// cutout's own area. `planArea` alone is the gross figure and never changes with a hole.
    private static func net(_ record: ZPDFContracts.MarkupRecord?) -> Decimal? {
        record?.measurement?[.netArea]?.value ?? record?.measurement?[.planArea]?.value
    }

    private static func holes(_ record: ZPDFContracts.MarkupRecord?) -> [ZPDFContracts.PolygonRing] {
        record?.geometry?.polygons.first?.holes ?? []
    }

    @Test("Deleting a cutout gives the parent its area back: 80 → 76 → 80")
    func deletingACutoutRestoresTheArea() async throws {
        let (session, pageID, documentID) = try await Self.makeSession()
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(
            Self.polygon(id: parentID, documentID: documentID, pageID: pageID, tool: .area, ring: Self.parentRing)
        ))
        #expect(await Self.net(session.markup(parentID)) == 80)

        _ = try await session.apply(.addCutout(
            parent: parentID,
            cutout: Self.polygon(id: cutoutID, documentID: documentID, pageID: pageID, tool: .polygonCutout, ring: Self.cutoutRing)
        ))
        #expect(await Self.net(session.markup(parentID)) == 76)
        #expect(await Self.net(session.markup(cutoutID)) == 4)
        #expect(await Self.holes(session.markup(parentID)).count == 1)

        let removal = try await session.apply(.removeMarkup(cutoutID))
        // Old output: 76 — the ring stayed in the parent's stored polygon.
        #expect(await Self.net(session.markup(parentID)) == 80)
        #expect(await session.markup(parentID)?.cutoutMarkupIDs.isEmpty == true)
        #expect(await Self.holes(session.markup(parentID)).isEmpty)

        // Undo brings the cutout and the hole back together.
        _ = try await session.revert(removal.inverse)
        #expect(await Self.net(session.markup(parentID)) == 76)
        #expect(await Self.holes(session.markup(parentID)).count == 1)
    }

    @Test("Moving a cutout moves the hole")
    func movingACutoutMovesTheHole() async throws {
        let (session, pageID, documentID) = try await Self.makeSession()
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(
            Self.polygon(id: parentID, documentID: documentID, pageID: pageID, tool: .area, ring: Self.parentRing)
        ))
        _ = try await session.apply(.addCutout(
            parent: parentID,
            cutout: Self.polygon(id: cutoutID, documentID: documentID, pageID: pageID, tool: .polygonCutout, ring: Self.cutoutRing)
        ))

        _ = try await session.apply(.moveMarkup(id: cutoutID, dx: 50, dy: 20))
        let parent = try #require(await session.markup(parentID))
        let expected = Self.cutoutRing.map { PDFPoint(x: $0.x + 50, y: $0.y + 20) }
        // Old output: one hole still at (10, 10)–(30, 30) while the child sat at (60, 30)–(80, 50).
        #expect(Self.holes(parent).map(\.points) == [expected])
        #expect(Self.net(parent) == 76)
    }

    @Test("Editing a cutout's vertices resizes the hole")
    func editingACutoutResizesTheHole() async throws {
        let (session, pageID, documentID) = try await Self.makeSession()
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(
            Self.polygon(id: parentID, documentID: documentID, pageID: pageID, tool: .area, ring: Self.parentRing)
        ))
        _ = try await session.apply(.addCutout(
            parent: parentID,
            cutout: Self.polygon(id: cutoutID, documentID: documentID, pageID: pageID, tool: .polygonCutout, ring: Self.cutoutRing)
        ))

        // 40 × 40 pt = 16 m².
        let bigger = [PDFPoint(x: 10, y: 10), PDFPoint(x: 50, y: 10), PDFPoint(x: 50, y: 50), PDFPoint(x: 10, y: 50)]
        _ = try await session.apply(.editVertices(
            id: cutoutID,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: bigger, isClosed: true))]
            )
        ))
        // Old output: 76 — the parent kept the 4 m² ring while the child reported 16 m².
        #expect(await Self.net(session.markup(parentID)) == 64)
        #expect(await Self.net(session.markup(cutoutID)) == 16)
    }

    @Test("An archive that carries merged holes reopens with the holes derived from its cutouts")
    func preFixArchiveIsNormalisedOnLoad() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let pageID = fixture.firstPage.id
        let documentID = fixture.documentID
        let session = try TakeoffSession(documentID: documentID, pages: fixture.pages, units: .metric)
        _ = try await session.calibrate(
            page: pageID,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(
            Self.polygon(id: parentID, documentID: documentID, pageID: pageID, tool: .area, ring: Self.parentRing)
        ))
        _ = try await session.apply(.addCutout(
            parent: parentID,
            cutout: Self.polygon(id: cutoutID, documentID: documentID, pageID: pageID, tool: .polygonCutout, ring: Self.cutoutRing)
        ))

        // What the old writer saved: the live cutout's ring merged into the parent — plus the
        // ring of a cutout that had since been deleted, which the old code never removed.
        let live = await session.takeoffState()
        let stale = [PDFPoint(x: 50, y: 50), PDFPoint(x: 70, y: 50), PDFPoint(x: 70, y: 70), PDFPoint(x: 50, y: 70)]
        let merged = live.markups.map { record -> ZPDFContracts.MarkupRecord in
            guard record.id == parentID, var geometry = record.geometry else { return record }
            geometry.polygons[0].holes.append(PolygonRing(points: stale, isClosed: true))
            var damaged = record
            damaged.geometry = geometry
            return damaged
        }
        let state = TakeoffSession.TakeoffState(
            pages: live.pages,
            markups: merged,
            scales: live.scales,
            pageScaleIDs: live.pageScaleIDs,
            calibrationEvidence: live.calibrationEvidence
        )

        let packageURL = directory.url.appendingPathComponent("MergedHoles.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "MergedHoles", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(state, into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        // The archive really does carry both rings — this is what the fix has to survive.
        #expect(stored.markups.first { $0.id == parentID }?.geometry?.polygons.first?.holes.count == 2)

        let restored = try TakeoffSession(documentID: documentID, pages: fixture.pages, units: .metric)
        try await restored.hydrate(
            markups: stored.markups,
            scales: stored.scales,
            pageScaleIDs: stored.pageScaleIDs
        )
        // Old output: two holes and 72 m² — the stale ring outlived its cutout.
        #expect(await Self.holes(restored.markup(parentID)).count == 1)
        #expect(await Self.holes(restored.markup(parentID)).first?.points == Self.cutoutRing)
        #expect(await Self.net(restored.markup(parentID)) == 76)

        _ = try await restored.apply(.removeMarkup(cutoutID))
        #expect(await Self.net(restored.markup(parentID)) == 80)
    }

    @Test("A locked parent refuses to be rewritten through its cutout")
    func lockedParentRefusesCutoutEdits() async throws {
        let (session, pageID, documentID) = try await Self.makeSession()
        let scale = try #require(await session.firstPageScale)
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        // Hydrated rather than applied: a locked parent cannot *take* a cutout, and no command
        // locks a record — the lock arrives with the file.
        try await session.hydrate(
            markups: [
                Self.polygon(
                    id: parentID, documentID: documentID, pageID: pageID, tool: .area,
                    ring: Self.parentRing, locked: true, cutoutMarkupIDs: [cutoutID]
                ),
                Self.polygon(
                    id: cutoutID, documentID: documentID, pageID: pageID, tool: .polygonCutout,
                    ring: Self.cutoutRing, parentMarkupID: parentID
                )
            ],
            scales: [scale],
            pageScaleIDs: [pageID: scale.id]
        )
        #expect(await Self.net(session.markup(parentID)) == 76)

        // Old behaviour: both succeeded, and the locked parent's number changed.
        await #expect(throws: DocumentCommandError.markupLocked(parentID)) {
            _ = try await session.apply(.removeMarkup(cutoutID))
        }
        await #expect(throws: DocumentCommandError.markupLocked(parentID)) {
            _ = try await session.apply(.moveMarkup(id: cutoutID, dx: 5, dy: 5))
        }
        #expect(await Self.net(session.markup(parentID)) == 76)
        #expect(await session.markup(cutoutID) != nil)
        // A style change touches no number, so it is still allowed.
        _ = try await session.apply(.changeStyle(id: cutoutID, style: .default))
    }
}
