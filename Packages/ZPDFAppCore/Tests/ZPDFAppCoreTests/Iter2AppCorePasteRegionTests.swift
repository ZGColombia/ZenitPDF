import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Iteration 2, appcore S-028: a pasted measurement is measured at the scale of where it lands.
///
/// Two 1000 pt sheets. Each has a page scale of 100 pt = 10 m (0.1 m/pt) and a "Detail" Scale
/// Region over x, y ∈ [500, 800] at 100 pt = 1 m (0.01 m/pt), ten times finer.
@Suite("Iter2 appcore: paste and Scale Regions")
@MainActor
struct Iter2AppCorePasteRegionTests {

    struct Fixture {
        let environment: AppCoreEnvironment
        let session: TakeoffSession
        let documentID: DocumentID
        let pages: [PageID]
    }

    static func fixture() async throws -> Fixture {
        let documentID = DocumentID(UUID())
        let pages = (0..<2).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()), documentID: documentID, index: index, label: "A-10\(index + 1)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        var regions: [ScaleRegionDefinition] = []
        for page in pages {
            try await environment.commands.calibrate(
                page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 10, knownLengthUnit: .metre
            )
            let detail = ScaleID(UUID())
            try await environment.commands.calibrate(
                page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 1, knownLengthUnit: .metre, scaleID: detail
            )
            regions.append(ScaleRegionDefinition(
                id: ScaleRegionID(UUID()), pageID: page.id, name: "Detail",
                boundary: [PDFPoint(x: 500, y: 500), PDFPoint(x: 800, y: 500), PDFPoint(x: 800, y: 800), PDFPoint(x: 500, y: 800)],
                scaleID: detail, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
            ))
        }
        try await environment.commands.perform(.setScaleRegions(regions))
        return Fixture(environment: environment, session: session, documentID: documentID, pages: pages.map(\.id))
    }

    static func length(_ fixture: Fixture, page: Int = 0, from: PDFPoint, to: PDFPoint) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: fixture.documentID, pageID: fixture.pages[page], kind: .measurement,
            tool: .length, subject: "Wall", author: "test",
            geometry: MeasurementGeometry(pageID: fixture.pages[page], points: [from, to]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func square(_ fixture: Fixture, tool: MeasurementTool, x: Double, y: Double, side: Double) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: fixture.documentID, pageID: fixture.pages[0], kind: .measurement,
            tool: tool, subject: "Slab", author: "test",
            geometry: MeasurementGeometry(pageID: fixture.pages[0], polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y), PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func planLength(_ fixture: Fixture, _ id: UUID) async -> Decimal? {
        await fixture.session.markup(MarkupID(id))?.measurement?.values[.planLength]?.value
    }

    @Test("A detail measurement pasted onto the plan area of the same sheet takes the page scale")
    func samePageOffsetPasteLeavesTheRegion() async throws {
        let fixture = try await Self.fixture()
        // 100 pt inside the detail region: 100 × 0.01 = 1 m.
        let detail = Self.length(fixture, from: PDFPoint(x: 550, y: 600), to: PDFPoint(x: 650, y: 600))
        await fixture.environment.commit(detail, family: .measurement)
        #expect(await fixture.session.markup(detail.id)?.measurement?.values[.planLength]?.value == 1)
        let payload = try #require(await fixture.environment.markupClipboardPayload(for: [detail.id.rawValue]))

        // 500 pt to the left: (50, 600)–(150, 600), on the bare plan: 100 × 0.1 = 10 m.
        let moved = await fixture.environment.pasteMarkups(payload, onto: [fixture.pages[0].rawValue], placement: .offset(dx: -500, dy: 0))
        let movedID = try #require(moved.pastedIDs.first)
        // Old output: 1 m (the detail region's scale carried onto the plan), recalculatedCount 0.
        #expect(await Self.planLength(fixture, movedID) == 10)
        #expect(await fixture.session.markup(MarkupID(movedID))?.scaleRegionID == nil)
        #expect(moved.recalculatedCount == 1)
        #expect(moved.heldForScaleDecisionCount == 0)

        // Paste in Place stays inside the region: still 1 m, nothing recalculated.
        let inPlace = await fixture.environment.pasteMarkups(payload, onto: [fixture.pages[0].rawValue], placement: .inPlace)
        let inPlaceID = try #require(inPlace.pastedIDs.first)
        #expect(await Self.planLength(fixture, inPlaceID) == 1)
        #expect(inPlace.recalculatedCount == 0)
    }

    @Test("A plan measurement pasted onto another sheet inside its Scale Region takes the region's scale")
    func otherPagePasteEntersTheRegion() async throws {
        let fixture = try await Self.fixture()
        let plan = Self.length(fixture, from: PDFPoint(x: 50, y: 600), to: PDFPoint(x: 150, y: 600))
        await fixture.environment.commit(plan, family: .measurement)
        #expect(await fixture.session.markup(plan.id)?.measurement?.values[.planLength]?.value == 10)
        let payload = try #require(await fixture.environment.markupClipboardPayload(for: [plan.id.rawValue]))
        // Onto sheet 2, 500 pt to the right: (550, 600)–(650, 600), inside sheet 2's region: 1 m.
        let receipt = await fixture.environment.pasteMarkups(payload, onto: [fixture.pages[1].rawValue], placement: .offset(dx: 500, dy: 0))
        // Old output: 10 m — sheet 2's page default, although the copy lies inside its region.
        let pastedID = try #require(receipt.pastedIDs.first)
        #expect(await Self.planLength(fixture, pastedID) == 1)
        #expect(receipt.recalculatedCount == 1)
    }

    @Test("A paste that would straddle a region boundary is held and said, never measured at a guessed scale")
    func straddlingPasteIsHeld() async throws {
        let fixture = try await Self.fixture()
        let detail = Self.length(fixture, from: PDFPoint(x: 550, y: 600), to: PDFPoint(x: 650, y: 600))
        let plan = Self.length(fixture, from: PDFPoint(x: 50, y: 100), to: PDFPoint(x: 150, y: 100))
        await fixture.environment.commit(detail, family: .measurement)
        await fixture.environment.commit(plan, family: .measurement)
        let payload = try #require(await fixture.environment.markupClipboardPayload(for: [detail.id.rawValue, plan.id.rawValue]))
        // 100 pt left: the detail copy spans x 450–550 across the boundary at x = 500; the plan
        // copy lands at x −50–50 on the plan.
        let receipt = await fixture.environment.pasteMarkups(payload, onto: [fixture.pages[0].rawValue], placement: .offset(dx: -100, dy: 0))
        #expect(receipt.heldForScaleDecisionCount == 1)
        #expect(receipt.pastedIDs.count == 1)
        #expect(await fixture.session.orderedMarkups.count == 3)
        #expect(fixture.environment.document.warnings.contains { $0.id == AppCoreEnvironment.pasteHeldForScaleDecisionWarningID })
    }

    @Test("A pasted area and its cutout both move to the scale of where they land")
    func cutoutFollowsItsParent() async throws {
        let fixture = try await Self.fixture()
        // 100 × 100 pt in the region: 1 m × 1 m = 1 m²; a 20 × 20 pt hole: 0.04 m².
        let parent = Self.square(fixture, tool: .area, x: 600, y: 600, side: 100)
        await fixture.environment.commit(parent, family: .measurement)
        await fixture.environment.commitCutout(parent: parent.id, record: Self.square(fixture, tool: .polygonCutout, x: 620, y: 620, side: 20))
        #expect(await fixture.session.markup(parent.id)?.measurement?.values[.netArea]?.value == Decimal(string: "0.96"))
        let payload = try #require(await fixture.environment.markupClipboardPayload(for: [parent.id.rawValue]))
        // 500 pt down-left onto the plan: 10 m × 10 m = 100 m² less a 2 m × 2 m hole = 96 m².
        let receipt = await fixture.environment.pasteMarkups(payload, onto: [fixture.pages[0].rawValue], placement: .offset(dx: -500, dy: -500))
        #expect(receipt.pastedIDs.count == 2)
        let pastedParent = try #require(await fixture.session.orderedMarkups.last { $0.parentMarkupID == nil && $0.id != parent.id })
        // Old output: 0.96 m² (both kept the detail region's scale).
        #expect(pastedParent.measurement?.values[.netArea]?.value == 96)
        let holeID = try #require(pastedParent.cutoutMarkupIDs.first)
        let pastedHole = try #require(await fixture.session.markup(holeID))
        #expect(pastedHole.scaleRegionID == nil)
        #expect(pastedHole.scaleID == pastedParent.scaleID)
    }
}
