import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFMeasurementEngine
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation

/// Fix round 3, contract additions (ADR-0018), end to end through the application core.
///
/// - IM-070: a skipped self-intersection check reaches the person as plain-English copy.
/// - Plan Area and cutouts: through the real session — measure, add cutouts, read the ledger the
///   pane and the exports read, save, reopen — the parent's Plan Area is outline minus the union
///   of its cutouts, and a cutout row adds nothing to any total, under every policy.
///
/// Geometry, hand-derived. Calibration 100 pt = 10 m, so 1 pt = 0.1 m and 1 pt² = 0.01 m²:
///
/// ```text
/// parent   (0,0)-(100,100) pt  = 10 x 10 m = 100 m²,   perimeter 40 m
/// cutout A (10,10)-(50,50) pt  =  4 x 4 m  =  16 m²
/// cutout B (30,30)-(70,70) pt  =  4 x 4 m  =  16 m²,   overlap (30..50)² pt = 2 x 2 m = 4 m²
/// union    16 + 16 - 4         =  28 m²
/// net      100 - 28            =  72 m²  (subtract / report separately);  100 m² under ignore
/// ```
@Suite("Fix 3 — contract additions through the application core (ADR-0018)")
struct Fix3ContractsAppCoreTests {

    // MARK: IM-070

    @Test("IM-070: selfIntersectionCheckSkipped maps to a non-blocking, plain-English warning")
    func skippedCheckIsToldToThePerson() throws {
        // Old output: the engine emitted `numericalPrecisionLoss`, which maps to `nil` here —
        // the person was told nothing.
        #expect(MeasurementWarningSummary(domain: .numericalPrecisionLoss) == nil)
        let summary = try #require(MeasurementWarningSummary(domain: .selfIntersectionCheckSkipped))
        #expect(summary == .selfIntersectionUnchecked)
        #expect(!summary.isBlocking, "the number stands; the person is told it was not checked")
        #expect(summary.message == "This outline has too many points to check whether it crosses itself. The area assumes it does not.")
        #expect(summary.symbolName == "exclamationmark.triangle")

        // Through the real engine and the real bridge: a 60 000-vertex outline, above the
        // shipping 50 000-vertex limit.
        let pageID = PageID(UUID())
        let ring = (0..<60_000).map { index -> PDFPoint in
            let angle = Double(index) / 60_000 * 2 * Double.pi
            return PDFPoint(x: 1_000 * cos(angle), y: 1_000 * sin(angle))
        }
        let scale = try ScaleTransform.uniform(
            id: ScaleID(UUID()), pageID: pageID, version: 1, metresPerPoint: Decimal(string: "0.01")!,
            units: ScaleUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre),
            source: .preset
        )
        let result = try MeasurementEngine().calculate(
            tool: .area,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]
            ),
            scale: scale
        )
        #expect(MarkupBridge.warnings(of: result).contains(.selfIntersectionUnchecked))
        let fields = MarkupBridge.fields(of: result, tool: .area, formatter: QuantityFormatter())
        let planArea = try #require(fields.first { $0.field == .planArea })
        #expect(planArea.warning == .selfIntersectionUnchecked, "the warning rides on the Plan Area readout")
    }

    // MARK: Plan Area and cutouts, end to end

    static let stamp = Date(timeIntervalSince1970: 1_787_000_000)

    static func polygon(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        tool: ZPDFContracts.MeasurementTool,
        ring: [PDFPoint],
        policy: CutoutPolicy? = nil
    ) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: tool == .area ? .measurement : .polygon,
            tool: tool,
            subject: "Slab",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]
            ),
            parameters: policy.map { MeasurementParameters(cutoutPolicy: $0) },
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    static func square(_ x: Double, _ y: Double, _ side: Double) -> [PDFPoint] {
        [PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y),
         PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)]
    }

    struct Built {
        let session: TakeoffSession
        let parent: MarkupID
        let cutouts: [MarkupID]
    }

    static func build(_ policy: CutoutPolicy, fixture: OpenedFixture) async throws -> Built {
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        let pageID = fixture.firstPage.id
        _ = try await session.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let parent = MarkupID(UUID())
        let cutoutA = MarkupID(UUID())
        let cutoutB = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(polygon(
            id: parent, documentID: fixture.documentID, pageID: pageID, tool: .area,
            ring: square(0, 0, 100), policy: policy
        )))
        for (id, ring) in [(cutoutA, square(10, 10, 40)), (cutoutB, square(30, 30, 40))] {
            _ = try await session.apply(.addCutout(
                parent: parent,
                cutout: polygon(id: id, documentID: fixture.documentID, pageID: pageID,
                                tool: .polygonCutout, ring: ring)
            ))
        }
        return Built(session: session, parent: parent, cutouts: [cutoutA, cutoutB])
    }

    /// Asserts the ledger the pane and every export read, for one policy.
    static func expectLedger(_ session: TakeoffSession, _ built: Built, _ policy: CutoutPolicy) async throws {
        let projection = try await session.ledgerProjection(.flat)
        let net: Decimal = policy == .ignore ? 100 : 72
        let parentPosition = try #require(projection.positionByMarkupID[built.parent.rawValue])
        let parentRow = try #require(projection.row(at: parentPosition))
        #expect(parentRow.quantity("planArea")?.value == net, "\(policy): Plan Area = outline - union(cutouts)")
        #expect(parentRow.quantity("grossArea")?.value == 100, "\(policy): Gross Area = the outline")
        #expect(parentRow.quantity("cutoutArea")?.value == (policy == .ignore ? nil : 28), "\(policy)")
        #expect(parentRow.quantity("perimeter")?.value == 40, "\(policy): perimeter is the drawn outline")
        for id in built.cutouts {
            let position = try #require(projection.positionByMarkupID[id.rawValue])
            let row = try #require(projection.row(at: position))
            for column in ["planArea", "grossArea", "perimeter", "trueArea", "radius", "diameter"] {
                #expect(row.quantity(LedgerColumnID(column)) == nil, "\(policy): cutout \(column)")
            }
            #expect(row.quantity("cutoutArea")?.value == (policy == .subtractAndReportSeparately ? 16 : nil), "\(policy)")
        }
        // Grand totals: the parent once; the cutout rows add nothing.
        // Old output (before this fix): Perimeter 40 + 16 + 16 = 72.
        #expect(projection.grandTotals.total("planArea")?.value == net, "\(policy)")
        #expect(projection.grandTotals.total("perimeter")?.value == 40, "\(policy)")
        #expect(projection.grandTotals.total("grossArea")?.value == 100, "\(policy)")
        #expect(projection.grandTotals.total("cutoutArea") == nil, "\(policy): Cutout Area is never totalled")
    }

    @Test("Plan Area is the net area and cutout rows add nothing, under every policy, before and after save")
    func planAreaAndCutoutsEndToEnd() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        for policy in CutoutPolicy.allCases {
            let built = try await Self.build(policy, fixture: fixture)
            // The stored parent result is the engine's own: net and gross side by side.
            let stored = try #require(await built.session.markup(built.parent)?.measurement)
            #expect(stored[.planArea]?.value == 100, "\(policy)")
            #expect(stored[.netArea]?.value == (policy == .ignore ? 100 : 72), "\(policy)")
            try await Self.expectLedger(built.session, built, policy)

            // Save through the real package pipeline, reopen, hydrate: the same ledger.
            let packageURL = directory.url.appendingPathComponent("Cutouts-\(policy.rawValue).zpdfproj", isDirectory: true)
            let package = try await ProjectPackage.create(at: packageURL, displayName: "Cutouts", originalPDF: fixture.url)
            try await TakeoffArchive.write(await built.session.takeoffState(), into: package)
            _ = try await package.save()
            try await package.close()
            guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
                Issue.record("reopen required recovery")
                return
            }
            let storedTakeoff = try #require(try await TakeoffArchive.read(from: reopened))
            let restored = try TakeoffSession(
                documentID: DocumentID(UUID()),
                pages: TakeoffArchive.adoptingStoredPageIDs(fixture.pages, stored: storedTakeoff),
                units: .metric
            )
            try await restored.hydrate(
                markups: storedTakeoff.markups,
                scales: storedTakeoff.scales,
                pageScaleIDs: storedTakeoff.pageScaleIDs
            )
            try await reopened.close()
            #expect(await restored.markup(built.parent)?.parameters?.cutoutPolicy ?? .subtractFromArea == policy,
                    "\(policy): the parent's policy survives the archive")
            try await Self.expectLedger(restored, built, policy)
        }
    }
}
