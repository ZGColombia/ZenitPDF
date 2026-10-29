import Foundation
import Testing
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
@testable import ZPDFAppCore

/// A project saved with a cutout that lies wholly outside its parent must still open.
///
/// ADR-0015 turned such a cutout from a warning into an engine refusal — right while it is
/// being drawn, and a shipping regression for a file written before the ADR, which
/// `hydrate` recomputes on open. The open repairs it: the cutout is detached from the parent,
/// both markups stay, the parent shows its hole-free value, and the tray says so.
@Suite("A saved cutout outside its parent is repaired on open")
struct HydrationRepairTests {

    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private static let parentRing = [
        PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)
    ]
    /// 20 × 20 pt, entirely off the parent.
    private static let outsideRing = [
        PDFPoint(x: 200, y: 200), PDFPoint(x: 220, y: 200), PDFPoint(x: 220, y: 220), PDFPoint(x: 200, y: 220)
    ]

    private static func polygon(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        tool: ZPDFContracts.MeasurementTool,
        ring: [PDFPoint],
        parentMarkupID: MarkupID? = nil
    ) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: tool == .area ? .measurement : .polygon,
            tool: tool,
            subject: tool == .area ? "Slab" : "Opening",
            label: tool == .area ? "Area A" : "",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]
            ),
            parentMarkupID: parentMarkupID,
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// Net area while a hole exists, gross area once none does.
    private static func net(_ record: ZPDFContracts.MarkupRecord?) -> Decimal? {
        record?.measurement?[.netArea]?.value ?? record?.measurement?[.planArea]?.value
    }

    @Test("An archive whose cutout lies wholly outside its parent opens: detached, kept, reported")
    @MainActor
    func outsideCutoutIsDetachedOnOpen() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let pageID = fixture.firstPage.id
        let documentID = fixture.documentID
        let session = try TakeoffSession(documentID: documentID, pages: fixture.pages, units: .metric)
        _ = try await session.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(
            Self.polygon(id: parentID, documentID: documentID, pageID: pageID, tool: .area, ring: Self.parentRing)
        ))

        // What a pre-ADR-0015 writer saved: the parent naming the cutout, the outside ring
        // merged into the parent's polygon, and the cutout as its child.
        let live = await session.takeoffState()
        let damaged = live.markups.map { record -> ZPDFContracts.MarkupRecord in
            guard record.id == parentID, var geometry = record.geometry else { return record }
            geometry.polygons[0].holes = [PolygonRing(points: Self.outsideRing, isClosed: true)]
            var parent = record
            parent.geometry = geometry
            parent.cutoutMarkupIDs = [cutoutID]
            return parent
        }
        let cutout = Self.polygon(
            id: cutoutID, documentID: documentID, pageID: pageID, tool: .polygonCutout,
            ring: Self.outsideRing, parentMarkupID: parentID
        )
        let state = TakeoffSession.TakeoffState(
            pages: live.pages,
            markups: damaged + [cutout],
            scales: live.scales,
            pageScaleIDs: live.pageScaleIDs,
            calibrationEvidence: live.calibrationEvidence
        )
        let packageURL = directory.url.appendingPathComponent("OutsideCutout.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "OutsideCutout", originalPDF: fixture.url
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
        #expect(stored.markups.first { $0.id == parentID }?.cutoutMarkupIDs == [cutoutID])

        // Old behaviour: `hydrate` threw `measurementFailed("… cutoutOutsideParent …")` and the
        // project did not open.
        let restored = try TakeoffSession(documentID: documentID, pages: fixture.pages, units: .metric)
        let repairs = try await restored.hydrate(
            markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs
        )
        #expect(repairs.map(\.cutoutID) == [cutoutID])
        #expect(repairs.first?.parentID == parentID)
        #expect(repairs.first?.parentSubject == "Slab")

        let parent = try #require(await restored.markup(parentID))
        #expect(Self.net(parent) == 80, "the hole-free area")
        #expect(parent.cutoutMarkupIDs.isEmpty)
        #expect(parent.geometry?.polygons.first?.holes.isEmpty == true)
        let kept = try #require(await restored.markup(cutoutID))
        #expect(kept.parentMarkupID == nil, "detached on both sides")
        #expect(Self.net(kept) == 4, "still a measured polygon of its own")
        #expect(await restored.orderedMarkups.count == 2)

        // The tray: one warning, naming the parent, through the same path as every refusal.
        let environment = try await AppCoreEnvironment.make(session: restored, documentID: documentID)
        let warning = try #require(
            environment.document.warnings.first { $0.id == AppCoreEnvironment.hydrationRepairWarningID }
        )
        #expect(warning.title.contains("touched nothing"))
        #expect(warning.title.contains("Slab — Area A"))
        #expect(environment.status.warnings.contains { $0.id == warning.id })
        // Said once: the repairs were drained.
        #expect(await restored.takeHydrationRepairs().isEmpty)
    }

    @Test("A live cutout drawn wholly outside its parent is still refused, and leaves nothing behind")
    func liveOutsideCutoutIsRefused() async throws {
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
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(
            Self.polygon(id: parentID, documentID: documentID, pageID: page.id, tool: .area, ring: Self.parentRing)
        ))

        await #expect(throws: DocumentCommandError.self) {
            _ = try await session.apply(.addCutout(
                parent: parentID,
                cutout: Self.polygon(id: cutoutID, documentID: documentID, pageID: page.id, tool: .polygonCutout, ring: Self.outsideRing)
            ))
        }
        #expect(await session.markup(cutoutID) == nil, "a refused cutout is not left behind")
        #expect(await session.markup(parentID)?.cutoutMarkupIDs.isEmpty == true)
        #expect(await Self.net(session.markup(parentID)) == 80)
        #expect(await session.orderedMarkups.count == 1)
    }
}
