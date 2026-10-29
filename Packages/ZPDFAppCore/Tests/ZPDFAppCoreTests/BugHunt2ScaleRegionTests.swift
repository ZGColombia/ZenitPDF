import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIPresentation

/// Bug hunt 2, Scale Region commitment (BH-004, BH-006, BH-088, BH-096, BH-427).
@MainActor
@Suite("Bug hunt 2: Scale Region commitment")
struct BugHunt2ScaleRegionTests {

    private struct Fixture {
        let environment: AppCoreEnvironment
        let session: TakeoffSession
        let documentID: DocumentID
        let page: ZPDFContracts.PageDescriptor
        /// 100 pt = 10 m: 0.1 m per point.
        let pageScaleID: ScaleID
        /// 100 pt = 1 m: 0.01 m per point.
        let detailScaleID: ScaleID
    }

    private func makeFixture() async throws -> Fixture {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let pageScaleID = try #require(await session.firstPageScale?.id)
        let detailScaleID = ScaleID(UUID())
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre, scaleID: detailScaleID
        )
        return Fixture(
            environment: environment, session: session, documentID: documentID, page: page,
            pageScaleID: pageScaleID, detailScaleID: detailScaleID
        )
    }

    private func region(
        name: String,
        boundary: [PDFPoint],
        scaleID: ScaleID,
        pageID: PageID,
        priority: Int = 1
    ) -> ScaleRegionDefinition {
        ScaleRegionDefinition(
            id: ScaleRegionID(UUID()),
            pageID: pageID,
            name: name,
            boundary: boundary,
            scaleID: scaleID,
            priority: priority,
            colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
        )
    }

    private func square(_ x: Double, _ y: Double, _ side: Double) -> [PDFPoint] {
        [PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y), PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)]
    }

    private func record(
        tool: MeasurementTool,
        points: [PDFPoint],
        fixture: Fixture,
        parameters: MeasurementParameters? = nil
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: fixture.page.id,
            kind: .measurement,
            tool: tool,
            subject: "S",
            label: "S A",
            author: "test",
            geometry: MeasurementGeometry(pageID: fixture.page.id, points: points),
            parameters: parameters,
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// Left region at the page scale, right region at the detail scale, a gap between them.
    private func twoRegions(_ fixture: Fixture) async throws -> (ScaleRegionDefinition, ScaleRegionDefinition) {
        let left = region(name: "Left", boundary: square(0, 0, 200), scaleID: fixture.pageScaleID, pageID: fixture.page.id, priority: 2)
        let right = region(name: "Right", boundary: square(300, 0, 200), scaleID: fixture.detailScaleID, pageID: fixture.page.id)
        try await fixture.environment.commands.perform(.setScaleRegions([left, right]))
        return (left, right)
    }

    // MARK: BH-004, BH-006

    @Test("Only chain tools are offered the split; a radius or a slope is not cut")
    func nonChainToolsAreNotSplit() async throws {
        let fixture = try await makeFixture()
        _ = try await twoRegions(fixture)
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }
        let span = [PDFPoint(x: 100, y: 100), PDFPoint(x: 400, y: 100)]

        for tool: MeasurementTool in [.radius, .diameter, .slope, .angle, .arcLength] {
            await fixture.environment.commit(record(tool: tool, points: span, fixture: fixture), family: .measurement)
        }
        await fixture.environment.commit(record(tool: .length, points: span, fixture: fixture), family: .measurement)

        // Old output: `canSplitAtBoundary == true` for every one of them, so a Radius became two
        // radii with fabricated areas and a Slope applied its whole rise to each piece.
        #expect(asked.count == 6)
        #expect(asked.prefix(5).allSatisfy { !$0.canSplitAtBoundary })
        #expect(asked.last?.canSplitAtBoundary == true, "a length is a chain and is still cut")

        // A split answer for a tool that cannot be cut is refused out loud, never delivered.
        let radius = try #require(asked.first)
        await fixture.environment.resolveScaleRegionCrossing(id: radius.id, outcome: .splitAtBoundary)
        #expect(await fixture.session.orderedMarkups.isEmpty)
        #expect(fixture.environment.document.warnings.contains { $0.id == AppCoreEnvironment.commitFailureWarningID })
    }

    @Test("A split piece of a length keeps the tool and is measured at its own scale")
    func cuttableToolClassification() {
        let fixtureless = { (tool: MeasurementTool, slope: SlopeSpecification?) -> Bool in
            let page = PageID(UUID())
            return ScaleRegionSplitter.isCuttable(ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page,
                kind: .measurement, tool: tool, subject: "", author: "",
                geometry: MeasurementGeometry(pageID: page, points: []),
                parameters: slope.map { var p = MeasurementParameters.default; p.slope = $0; return p },
                createdAt: Date(), modifiedAt: Date()
            ))
        }
        #expect(fixtureless(.length, nil))
        #expect(fixtureless(.polylength, nil))
        #expect(fixtureless(.dimension, nil))
        #expect(fixtureless(.trueSlopedLength, .uniformPlane(.percent(50))))
        #expect(!fixtureless(.trueSlopedLength, .total(1)))
        #expect(!fixtureless(.riseDrop, .total(1)))
        #expect(!fixtureless(.threePointCircle, nil))
        #expect(!fixtureless(.ellipseArea, nil))
    }

    // MARK: BH-088

    @Test("Answering with a region that has since gone creates nothing and says so")
    func vanishedRegionIsRefused() async throws {
        let fixture = try await makeFixture()
        let (left, right) = try await twoRegions(fixture)
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }
        await fixture.environment.commit(
            record(tool: .length, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 400, y: 100)], fixture: fixture),
            family: .measurement
        )
        let crossing = try #require(asked.first)
        // The region is deleted while the question is open.
        try await fixture.environment.commands.perform(.setScaleRegions([left]))

        await fixture.environment.resolveScaleRegionCrossing(id: crossing.id, outcome: .useScale(regionID: right.id))
        // Old output: one markup at the page default (scaleID nil) — a scale nobody chose.
        #expect(await fixture.session.orderedMarkups.isEmpty)
        #expect(fixture.environment.document.warnings.contains { $0.id == AppCoreEnvironment.commitFailureWarningID })
    }

    // MARK: BH-096

    @Test("One region with an unreadable boundary does not disable the others on its page")
    func brokenRegionDoesNotDisableThePage() async throws {
        let fixture = try await makeFixture()
        let detail = region(name: "Detail", boundary: square(0, 0, 200), scaleID: fixture.detailScaleID, pageID: fixture.page.id)
        let broken = region(name: "Broken", boundary: [], scaleID: fixture.pageScaleID, pageID: fixture.page.id)
        try await fixture.environment.commands.perform(.setScaleRegions([detail, broken]))

        await fixture.environment.commit(
            record(tool: .length, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 10)], fixture: fixture),
            family: .measurement
        )
        let stored = try #require(await fixture.session.orderedMarkups.first)
        // Old output: scaleRegionID nil and 10 m — the whole page fell back to the page scale.
        // Hand-derived: 100 pt at 0.01 m/pt is 1 m.
        #expect(stored.scaleRegionID == detail.id)
        #expect(stored.measurement?.values[.planLength]?.value == 1)
    }

    // MARK: BH-427

    @Test("A vertex in two overlapping regions is not on the bare sheet")
    func overlapVertexDoesNotOfferThePageDefault() async throws {
        let fixture = try await makeFixture()
        let a = region(name: "A", boundary: square(0, 0, 200), scaleID: fixture.pageScaleID, pageID: fixture.page.id)
        let b = region(name: "B", boundary: square(100, 0, 200), scaleID: fixture.detailScaleID, pageID: fixture.page.id)
        try await fixture.environment.commands.perform(.setScaleRegions([a, b]))
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }
        // (150, 50) is inside both; (250, 50) is inside B only. Nothing lies outside every region.
        await fixture.environment.commit(
            record(tool: .length, points: [PDFPoint(x: 150, y: 50), PDFPoint(x: 250, y: 50)], fixture: fixture),
            family: .measurement
        )
        let crossing = try #require(asked.first)
        // Old output: true — `.ambiguous` read as "no region".
        #expect(crossing.touchesPageDefault == false)
    }
}
