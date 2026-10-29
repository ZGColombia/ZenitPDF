import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Scale Regions and Project Zones, driven through the shipping command bus and the shipping
/// commit funnel — the same door the canvas and the two panels use.
///
/// The claims under test are the ones spec §10.4 and `CORE_LOOP.md`'s silent-wrongness doctrine
/// turn on:
///
/// 1. A measurement inside a region is measured with **that region's** scale.
/// 2. A measurement across two regions is **not created at all** until a person chooses, and
///    each of the three legal outcomes does exactly what it says.
/// 3. A region or zone that goes away never leaves a markup pointing at it — which is both a
///    correctness rule and the reason a save does not fail on a foreign key.
/// 4. Every one of these edits is undoable and survives save → reopen.
@Suite("Scale Regions and Project Zones")
struct ProjectStructureTests {

    // MARK: - Fixture

    private struct Fixture {
        let environment: AppCoreEnvironment
        let session: TakeoffSession
        let documentID: DocumentID
        let page: ZPDFContracts.PageDescriptor
        /// The document default: 100 pt = 10 m, so 1 pt = 0.1 m.
        let pageScaleID: ScaleID
        /// A second scale, 100 pt = 1 m, so 1 pt = 0.01 m — ten times finer.
        let detailScaleID: ScaleID
    }

    /// One page, two scales, no regions. The two scales differ by exactly ten so a wrong one
    /// is visible by eye rather than by a rounding argument.
    @MainActor
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
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let pageScaleID = try #require(await session.firstPageScale?.id)
        let detailScaleID = ScaleID(UUID())
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre,
            scaleID: detailScaleID
        )
        #expect(await session.firstPageScale?.id == pageScaleID, "a region scale must not steal the page default")
        return Fixture(
            environment: environment,
            session: session,
            documentID: documentID,
            page: page,
            pageScaleID: pageScaleID,
            detailScaleID: detailScaleID
        )
    }

    /// A square region, given as its lower-left corner and its side.
    private func region(
        id: ScaleRegionID = ScaleRegionID(UUID()),
        name: String,
        origin: PDFPoint,
        side: Double,
        scaleID: ScaleID,
        pageID: PageID,
        priority: Int = 1
    ) -> ScaleRegionDefinition {
        ScaleRegionDefinition(
            id: id,
            pageID: pageID,
            name: name,
            boundary: [
                origin,
                PDFPoint(x: origin.x + side, y: origin.y),
                PDFPoint(x: origin.x + side, y: origin.y + side),
                PDFPoint(x: origin.x, y: origin.y + side)
            ],
            scaleID: scaleID,
            priority: priority,
            colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
        )
    }

    /// A two-point length measurement.
    private func length(
        _ from: PDFPoint,
        _ to: PDFPoint,
        documentID: DocumentID,
        pageID: PageID,
        subject: String = "Length"
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .length,
            subject: subject,
            label: "Length A",
            author: "test",
            geometry: MeasurementGeometry(pageID: pageID, points: [from, to]),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    private func planLength(of record: ZPDFContracts.MarkupRecord) -> Decimal? {
        record.measurement?.values[.planLength]?.value
    }

    // MARK: - 1. A region decides the scale

    @Test("A measurement inside a Scale Region is measured with that region's scale")
    @MainActor
    func measurementInsideRegionUsesItsScale() async throws {
        let fixture = try await makeFixture()
        let detail = region(
            name: "Stair Detail",
            origin: PDFPoint(x: 100, y: 100),
            side: 400,
            scaleID: fixture.detailScaleID,
            pageID: fixture.page.id
        )
        try await fixture.environment.commands.perform(.setScaleRegions([detail]))

        // 200 pt drawn wholly inside the region. At the page scale that is 20 m; at the
        // region's it is 2 m, and only one of the two is right.
        await fixture.environment.commit(
            length(
                PDFPoint(x: 150, y: 150),
                PDFPoint(x: 350, y: 150),
                documentID: fixture.documentID,
                pageID: fixture.page.id
            ),
            family: .measurement
        )

        let stored = try #require(await fixture.session.orderedMarkups.first)
        #expect(stored.scaleRegionID == detail.id)
        #expect(stored.scaleID == fixture.detailScaleID)
        #expect(planLength(of: stored) == Decimal(2), "expected 2 m at 1 pt = 0.01 m")
    }

    @Test("A measurement outside every region keeps the page default")
    @MainActor
    func measurementOutsideRegionsUsesThePageScale() async throws {
        let fixture = try await makeFixture()
        let detail = region(
            name: "Stair Detail",
            origin: PDFPoint(x: 100, y: 100),
            side: 200,
            scaleID: fixture.detailScaleID,
            pageID: fixture.page.id
        )
        try await fixture.environment.commands.perform(.setScaleRegions([detail]))

        await fixture.environment.commit(
            length(
                PDFPoint(x: 600, y: 600),
                PDFPoint(x: 800, y: 600),
                documentID: fixture.documentID,
                pageID: fixture.page.id
            ),
            family: .measurement
        )

        let stored = try #require(await fixture.session.orderedMarkups.first)
        #expect(stored.scaleRegionID == nil)
        #expect(planLength(of: stored) == Decimal(20), "expected 20 m at 1 pt = 0.1 m")
    }

    // MARK: - 2. A crossing is never resolved by the application

    /// Two abutting squares with different scales, and a length that runs through both.
    @MainActor
    private func makeCrossingFixture() async throws -> (Fixture, ScaleRegionDefinition, ScaleRegionDefinition) {
        let fixture = try await makeFixture()
        let left = region(
            name: "Left",
            origin: PDFPoint(x: 0, y: 0),
            side: 200,
            scaleID: fixture.pageScaleID,
            pageID: fixture.page.id,
            priority: 2
        )
        let right = region(
            name: "Right",
            origin: PDFPoint(x: 300, y: 0),
            side: 200,
            scaleID: fixture.detailScaleID,
            pageID: fixture.page.id,
            priority: 1
        )
        try await fixture.environment.commands.perform(.setScaleRegions([left, right]))
        return (fixture, left, right)
    }

    @Test("A measurement crossing two regions is not created; the question is raised instead")
    @MainActor
    func crossingRaisesTheQuestionAndCreatesNothing() async throws {
        let (fixture, left, right) = try await makeCrossingFixture()
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }

        await fixture.environment.commit(
            length(
                PDFPoint(x: 100, y: 100),
                PDFPoint(x: 400, y: 100),
                documentID: fixture.documentID,
                pageID: fixture.page.id
            ),
            family: .measurement
        )

        #expect(await fixture.session.orderedMarkups.isEmpty, "nothing may exist before the answer")
        #expect(asked.count == 1)
        let crossing = try #require(asked.first)
        #expect(Set(crossing.regionIDs) == Set([left.id, right.id]))
        #expect(crossing.touchesPageDefault, "the middle of the chain is outside both regions")
        #expect(crossing.canSplitAtBoundary, "a polyline can be cut exactly")
        #expect(fixture.environment.pendingScaleRegionCrossings.count == 1)
    }

    @Test("With nothing to ask the question, the measurement is refused and the tray says so")
    @MainActor
    func unaskableCrossingRefusesRatherThanGuessing() async throws {
        let (fixture, _, _) = try await makeCrossingFixture()
        // `onScaleRegionCrossing` deliberately left unset.
        await fixture.environment.commit(
            length(
                PDFPoint(x: 100, y: 100),
                PDFPoint(x: 400, y: 100),
                documentID: fixture.documentID,
                pageID: fixture.page.id
            ),
            family: .measurement
        )
        #expect(await fixture.session.orderedMarkups.isEmpty)
        #expect(fixture.environment.document.warnings.contains { $0.severity == .danger })
    }

    @Test("Block creates nothing at all")
    @MainActor
    func blockCreatesNothing() async throws {
        let (fixture, _, _) = try await makeCrossingFixture()
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }
        await fixture.environment.commit(
            length(
                PDFPoint(x: 100, y: 100),
                PDFPoint(x: 400, y: 100),
                documentID: fixture.documentID,
                pageID: fixture.page.id
            ),
            family: .measurement
        )
        let crossing = try #require(asked.first)

        #expect(await fixture.environment.resolveScaleRegionCrossing(id: crossing.id, outcome: .block))
        #expect(await fixture.session.orderedMarkups.isEmpty)
        #expect(fixture.environment.pendingScaleRegionCrossings.isEmpty)
        // A second answer to the same question must not create anything either.
        #expect(await fixture.environment.resolveScaleRegionCrossing(id: crossing.id, outcome: .block) == false)
    }

    @Test("Use one region's scale creates exactly one measurement, at that scale")
    @MainActor
    func useOneScaleCreatesOneMeasurement() async throws {
        let (fixture, _, right) = try await makeCrossingFixture()
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }
        await fixture.environment.commit(
            length(
                PDFPoint(x: 100, y: 100),
                PDFPoint(x: 400, y: 100),
                documentID: fixture.documentID,
                pageID: fixture.page.id
            ),
            family: .measurement
        )
        let crossing = try #require(asked.first)

        await fixture.environment.resolveScaleRegionCrossing(
            id: crossing.id,
            outcome: .useScale(regionID: right.id)
        )
        let stored = await fixture.session.orderedMarkups
        #expect(stored.count == 1)
        #expect(stored.first?.scaleRegionID == right.id)
        // The whole 300 pt chain at the detail scale: 3 m, not the 30 m the page would give.
        #expect(planLength(of: try #require(stored.first)) == Decimal(3))
    }

    @Test("Split at the boundary creates one measurement per region, in one undo step")
    @MainActor
    func splitCreatesOnePartPerRegion() async throws {
        let (fixture, left, right) = try await makeCrossingFixture()
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }
        await fixture.environment.commit(
            length(
                PDFPoint(x: 100, y: 100),
                PDFPoint(x: 400, y: 100),
                documentID: fixture.documentID,
                pageID: fixture.page.id
            ),
            family: .measurement
        )
        let crossing = try #require(asked.first)

        await fixture.environment.resolveScaleRegionCrossing(
            id: crossing.id,
            outcome: .splitAtBoundary
        )
        let stored = await fixture.session.orderedMarkups
        #expect(stored.count == 3, "left region, the gap between them, right region")
        #expect(stored.compactMap(\.scaleRegionID).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            == [left.id, right.id].sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
        // 100 pt inside the left region at the page scale is 10 m; 100 pt inside the right
        // one at the detail scale is 1 m; the 100 pt between them keeps the page scale.
        let byRegion = Dictionary(grouping: stored) { $0.scaleRegionID }
        #expect(planLength(of: try #require(byRegion[left.id]?.first)) == Decimal(10))
        #expect(planLength(of: try #require(byRegion[right.id]?.first)) == Decimal(1))
        let outside = try #require(byRegion[ScaleRegionID?.none]?.first)
        #expect(planLength(of: outside) == Decimal(10))

        // One user action, one ⌘Z.
        await fixture.environment.commands.undo()
        #expect(await fixture.session.orderedMarkups.isEmpty)
    }

    @Test("An area that crosses two regions is offered the exact split (ADR-0030 §5.6)")
    @MainActor
    func anAreaCrossingIsNotOfferedTheSplit() async throws {
        let (fixture, _, _) = try await makeCrossingFixture()
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        await fixture.environment.commit(
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()),
                documentID: fixture.documentID,
                pageID: fixture.page.id,
                kind: .measurement,
                tool: .area,
                subject: "Area",
                author: "test",
                geometry: MeasurementGeometry(
                    pageID: fixture.page.id,
                    polygons: [PolygonGeometry(outer: PolygonRing(points: [
                        PDFPoint(x: 100, y: 100),
                        PDFPoint(x: 400, y: 100),
                        PDFPoint(x: 400, y: 150),
                        PDFPoint(x: 100, y: 150)
                    ], isClosed: true))]
                ),
                createdAt: stamp,
                modifiedAt: stamp
            ),
            family: .measurement
        )
        let crossing = try #require(asked.first)
        // Old output (before ADR-0030 §5.6): `canSplitAtBoundary == false` — no exact polygon clip
        // existed. The exact ring booleans cut the 300 × 50 area into the Left piece
        // [100,200]×[100,150], the bare-sheet piece [200,300]×[100,150] and the Right piece
        // [300,400]×[100,150], 5 000 pt² each, which tile the 15 000 pt² whole.
        #expect(crossing.canSplitAtBoundary)
        let parts = try #require(crossing.splitParts)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Swift.abs(Swift.abs($0.polygon?.outer.exactSignedArea ?? 0) - 5_000) <= 1e-9 })
    }

    // MARK: - 3. Nothing is left pointing at something that is gone

    @Test("Deleting a region clears its markups and re-measures them at the page scale")
    @MainActor
    func deletingARegionRepairsItsMarkups() async throws {
        let fixture = try await makeFixture()
        let detail = region(
            name: "Stair Detail",
            origin: PDFPoint(x: 100, y: 100),
            side: 400,
            scaleID: fixture.detailScaleID,
            pageID: fixture.page.id
        )
        try await fixture.environment.commands.perform(.setScaleRegions([detail]))
        await fixture.environment.commit(
            length(
                PDFPoint(x: 150, y: 150),
                PDFPoint(x: 350, y: 150),
                documentID: fixture.documentID,
                pageID: fixture.page.id
            ),
            family: .measurement
        )
        #expect(planLength(of: try #require(await fixture.session.orderedMarkups.first)) == Decimal(2))

        try await fixture.environment.commands.perform(.setScaleRegions([]))
        let repaired = try #require(await fixture.session.orderedMarkups.first)
        #expect(repaired.scaleRegionID == nil, "a dangling region reference is a save that fails")
        #expect(planLength(of: repaired) == Decimal(20), "the page scale applies once the region is gone")

        // And undo puts both the region and its measurement back exactly.
        await fixture.environment.commands.undo()
        #expect(await fixture.session.scaleRegionDefinitions.map(\.id) == [detail.id])
        #expect(planLength(of: try #require(await fixture.session.orderedMarkups.first)) == Decimal(2))
    }

    @Test("Deleting a zone unfiles its markups")
    @MainActor
    func deletingAZoneUnfilesItsMarkups() async throws {
        let fixture = try await makeFixture()
        let zone = ProjectZoneDefinition(
            id: ZoneID(UUID()),
            name: "Ground Floor",
            kind: .floor,
            sortOrder: 0,
            colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1)
        )
        try await fixture.environment.commands.perform(.setProjectZones([zone]))
        let record = length(
            PDFPoint(x: 600, y: 600),
            PDFPoint(x: 700, y: 600),
            documentID: fixture.documentID,
            pageID: fixture.page.id
        )
        await fixture.environment.commit(record, family: .measurement)
        try await fixture.environment.commands.perform(
            .setMarkupZone(ids: [record.id], zoneID: zone.id)
        )
        #expect(await fixture.session.orderedMarkups.first?.zoneID == zone.id)

        try await fixture.environment.commands.perform(.setProjectZones([]))
        #expect(await fixture.session.orderedMarkups.first?.zoneID == nil)
    }

    // MARK: - 4. The zone is a grouping key the ledger can total by

    @Test("The Quantity Ledger groups by Project Zone under the zone's own name")
    @MainActor
    func theLedgerGroupsByZoneName() async throws {
        let fixture = try await makeFixture()
        let ground = ProjectZoneDefinition(
            id: ZoneID(UUID()),
            name: "Ground Floor",
            kind: .floor,
            sortOrder: 0,
            colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1)
        )
        try await fixture.environment.commands.perform(.setProjectZones([ground]))

        let first = length(
            PDFPoint(x: 600, y: 600),
            PDFPoint(x: 700, y: 600),
            documentID: fixture.documentID,
            pageID: fixture.page.id,
            subject: "Skirting"
        )
        let second = length(
            PDFPoint(x: 600, y: 650),
            PDFPoint(x: 800, y: 650),
            documentID: fixture.documentID,
            pageID: fixture.page.id,
            subject: "Skirting"
        )
        await fixture.environment.commit(first, family: .measurement)
        await fixture.environment.commit(second, family: .measurement)
        try await fixture.environment.commands.perform(
            .setMarkupZone(ids: [first.id, second.id], zoneID: ground.id)
        )

        let projection = try await fixture.session.ledgerProjection(
            LedgerRequest(grouping: [.projectZone])
        )
        let names = (0..<projection.rowCount).compactMap { index -> String? in
            projection.row(at: index)?.displayValue(.projectZone)
        }
        #expect(names.allSatisfy { $0 == "Ground Floor" }, "got \(names)")
        #expect(names.count == 2)

        // And the panel's view of the zone knows how many markups it holds.
        let summary = try #require(await fixture.session.projectZoneSummaries().first)
        #expect(summary.markupCount == 2)
        #expect(summary.name == "Ground Floor")
    }

    // MARK: - 5. Overlap is reported, never resolved

    @Test("Two regions that share area are reported as an overlapping pair")
    @MainActor
    func overlapIsReported() async throws {
        let fixture = try await makeFixture()
        let a = region(
            name: "A", origin: PDFPoint(x: 0, y: 0), side: 200,
            scaleID: fixture.pageScaleID, pageID: fixture.page.id
        )
        let b = region(
            name: "B", origin: PDFPoint(x: 100, y: 100), side: 200,
            scaleID: fixture.detailScaleID, pageID: fixture.page.id
        )
        try await fixture.environment.commands.perform(.setScaleRegions([a, b]))
        let pairs = await fixture.session.overlappingScaleRegions(page: fixture.page.id)
        #expect(pairs.count == 1)
        #expect(Set([pairs[0].0, pairs[0].1]) == Set([a.id, b.id]))
    }

    @Test("A region naming a scale the document does not hold is refused")
    @MainActor
    func aRegionCannotNameAnUnknownScale() async throws {
        let fixture = try await makeFixture()
        let orphan = region(
            name: "Nowhere", origin: .zero, side: 10,
            scaleID: ScaleID(UUID()), pageID: fixture.page.id
        )
        await #expect(throws: (any Error).self) {
            try await fixture.environment.commands.perform(.setScaleRegions([orphan]))
        }
        #expect(await fixture.session.scaleRegionDefinitions.isEmpty)
    }

    // MARK: - 6. Boundary capture is not a measurement

    @Test("A boundary polygon is handed to the panel and never becomes a markup")
    @MainActor
    func boundaryCaptureProducesNoMarkup() async throws {
        let fixture = try await makeFixture()
        var captured: [(AppMeasurementToolPresenter.BoundaryPurpose, [PDFPointValue])] = []
        fixture.environment.measurement.onCommitBoundary = { purpose, points, _ in
            captured.append((purpose, points))
        }
        fixture.environment.measurement.beginBoundaryCapture(.scaleRegion)
        #expect(fixture.environment.measurement.isCapturingBoundary)

        for point in [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0), PDFPointValue(x: 100, y: 100)] {
            fixture.environment.measurement.placePoint(point)
        }
        await fixture.environment.measurement.settlePlacements()
        fixture.environment.measurement.commitActiveMeasurement()

        #expect(captured.count == 1)
        #expect(captured.first?.0 == .scaleRegion)
        #expect(captured.first?.1.count == 3)
        #expect(!fixture.environment.measurement.isCapturingBoundary)
        #expect(await fixture.session.orderedMarkups.isEmpty, "a boundary is not a measurement")
    }

    @Test("A boundary closes on an uncalibrated sheet — a zone outline is not a quantity")
    @MainActor
    func boundaryCommitsWithoutAScale() async throws {
        // No calibrate call anywhere: the sheet drawn on in the manual test had "No scale",
        // `missingScale` is a blocking measurement warning, and judging the boundary by
        // measurement rules made Return silently refuse to close the polygon — neither
        // Project Zones nor Scale Regions could ever be created live (LT-35/LT-36,
        // 2026-08-29). Every other test in this suite calibrates first, which is exactly
        // why none of them caught it.
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

        var captured: [(AppMeasurementToolPresenter.BoundaryPurpose, [PDFPointValue])] = []
        environment.measurement.onCommitBoundary = { purpose, points, _ in
            captured.append((purpose, points))
        }
        environment.measurement.beginBoundaryCapture(.projectZone)
        for point in [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 400, y: 100),
            PDFPointValue(x: 400, y: 400),
            PDFPointValue(x: 100, y: 400)
        ] {
            environment.measurement.placePoint(point)
        }
        await environment.measurement.settlePlacements()

        #expect(environment.measurement.canCommit,
                "an unscaled page must not block a boundary polygon from closing")
        environment.measurement.commitActiveMeasurement()
        #expect(captured.count == 1, "the boundary never reached the panel — LT-35's silence")
        #expect(captured.first?.1.count == 4)
        #expect(await session.orderedMarkups.isEmpty)

        // The same four points as an ordinary AREA on the unscaled page must still refuse:
        // the boundary exemption is for boundaries alone.
        environment.measurement.activate(kind: .area)
        for point in [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 400, y: 100),
            PDFPointValue(x: 400, y: 400),
            PDFPointValue(x: 100, y: 400)
        ] {
            environment.measurement.placePoint(point)
        }
        await environment.measurement.settlePlacements()
        #expect(!environment.measurement.canCommit,
                "a real measurement without a scale must stay blocked")
    }

    @Test("Escaping a boundary capture tells the panel rather than leaving it waiting")
    @MainActor
    func cancellingBoundaryCaptureReportsIt() async throws {
        let fixture = try await makeFixture()
        var cancelled: [AppMeasurementToolPresenter.BoundaryPurpose] = []
        fixture.environment.measurement.onCancelBoundary = { cancelled.append($0) }
        fixture.environment.measurement.beginBoundaryCapture(.projectZone)
        fixture.environment.measurement.cancelActiveMeasurement()
        #expect(cancelled == [.projectZone])
        #expect(!fixture.environment.measurement.isCapturingBoundary)
    }

    // MARK: - 7. Save → reopen

    @Test("Regions, zones and the markups that name them survive save and reopen")
    func structureSurvivesTheRoundTrip() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-structure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: workspace)

        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        _ = try await session.calibrate(
            page: try #require(await session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let pageScaleID = try #require(await session.firstPageScale?.id)
        let detailScaleID = ScaleID(UUID())
        _ = try await session.calibrate(
            page: try #require(await session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre,
            scaleID: detailScaleID
        )
        let pageID = fixture.firstPage.id
        let detail = region(
            name: "Stair Detail",
            origin: PDFPoint(x: 20, y: 20),
            side: 200,
            scaleID: detailScaleID,
            pageID: pageID,
            priority: 7
        )
        let spanning = ProjectZoneDefinition(
            id: ZoneID(UUID()),
            name: "Phase 2",
            kind: .quantityGroup,
            sortOrder: 0,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        )
        let drawn = ProjectZoneDefinition(
            id: ZoneID(UUID()),
            name: "Room 101",
            kind: .room,
            parentID: spanning.id,
            pageID: pageID,
            boundary: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 50, y: 0), PDFPoint(x: 50, y: 50)
            ],
            sortOrder: 1,
            isVisible: false,
            colorRGBA: ColorRGBA(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        )
        _ = try await session.apply(.setScaleRegions([detail]))
        _ = try await session.apply(.setProjectZones([spanning, drawn]))

        var record = length(
            PDFPoint(x: 40, y: 40),
            PDFPoint(x: 140, y: 40),
            documentID: fixture.documentID,
            pageID: pageID
        )
        record.scaleRegionID = detail.id
        record.scaleID = detailScaleID
        _ = try await session.apply(.addMarkup(record))
        _ = try await session.apply(.setMarkupZone(ids: [record.id], zoneID: drawn.id))
        let before = try #require(await session.orderedMarkups.first)
        #expect(planLength(of: before) == Decimal(1))

        // ── Save through the real package pipeline ──────────────────────────────────
        let packageURL = workspace.appendingPathComponent("Structure.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Structure", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        #expect(stored.scaleRegions.count == 1)
        let storedRegion = try #require(stored.scaleRegions.first)
        #expect(storedRegion.id == detail.id)
        #expect(storedRegion.name == "Stair Detail")
        #expect(storedRegion.priority == 7)
        #expect(storedRegion.scaleID == detailScaleID)
        #expect(storedRegion.boundary.count == 4)

        #expect(stored.projectZones.count == 2)
        let storedSpanning = try #require(stored.projectZones.first { $0.id == spanning.id })
        #expect(storedSpanning.pageID == nil, "a zone with no boundary must not claim a page")
        #expect(storedSpanning.kind == .quantityGroup)
        let storedRoom = try #require(stored.projectZones.first { $0.id == drawn.id })
        #expect(storedRoom.kind == .room)
        #expect(storedRoom.parentID == spanning.id)
        #expect(storedRoom.isVisible == false)
        #expect(storedRoom.boundary.count == 3)

        // Rehydrate and prove the number is the same one, computed again from the region.
        let fresh = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        try await fresh.hydrate(
            markups: stored.markups,
            scales: stored.scales,
            pageScaleIDs: stored.pageScaleIDs,
            scaleRegions: stored.scaleRegions,
            projectZones: stored.projectZones
        )
        let after = try #require(await fresh.orderedMarkups.first)
        #expect(after.scaleRegionID == detail.id)
        #expect(after.zoneID == drawn.id)
        #expect(planLength(of: after) == planLength(of: before))
        #expect(await fresh.firstPageScale?.id == pageScaleID)

        // The zone name is back in the table the ledger groups by.
        let projection = try await fresh.ledgerProjection(LedgerRequest(grouping: [.projectZone]))
        #expect(projection.row(at: 0)?.displayValue(.projectZone) == "Room 101")
        try await reopened.close()
    }

    // MARK: - 8. The splitter's own arithmetic

    @Test("A chain that stays in one region is not split")
    func aChainInsideOneRegionIsNotSplit() throws {
        let pageID = PageID(UUID())
        let resolver = try ScaleRegionResolver(
            pageID: pageID,
            regions: [
                ZPDFGeometry.ScaleRegion(
                    id: ScaleRegionID(UUID()),
                    pageID: pageID,
                    scaleID: ScaleID(UUID()),
                    boundary: PolygonRing(points: [
                        PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0),
                        PDFPoint(x: 100, y: 100), PDFPoint(x: 0, y: 100)
                    ], isClosed: true)
                )
            ]
        )
        let parts = ScaleRegionSplitter.split(
            polyline: [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 10)],
            resolver: resolver
        )
        #expect(parts == nil)
    }

    @Test("A chain leaving a region is cut exactly at the boundary")
    func aChainLeavingARegionIsCutAtTheEdge() throws {
        let pageID = PageID(UUID())
        let regionID = ScaleRegionID(UUID())
        let resolver = try ScaleRegionResolver(
            pageID: pageID,
            regions: [
                ZPDFGeometry.ScaleRegion(
                    id: regionID,
                    pageID: pageID,
                    scaleID: ScaleID(UUID()),
                    boundary: PolygonRing(points: [
                        PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0),
                        PDFPoint(x: 100, y: 100), PDFPoint(x: 0, y: 100)
                    ], isClosed: true)
                )
            ]
        )
        let parts = try #require(
            ScaleRegionSplitter.split(
                polyline: [PDFPoint(x: 50, y: 50), PDFPoint(x: 150, y: 50)],
                resolver: resolver
            )
        )
        #expect(parts.count == 2)
        #expect(parts[0].regionID == regionID)
        #expect(parts[0].points.last?.x == 100)
        #expect(parts[1].regionID == nil)
        #expect(parts[1].points.first?.x == 100)
        #expect(parts[1].points.last?.x == 150)
    }
}
