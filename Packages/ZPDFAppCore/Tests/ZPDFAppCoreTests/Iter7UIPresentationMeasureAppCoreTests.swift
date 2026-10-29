import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Through the app core: an area's
/// headline is the ledger's Plan Area — the net area — wherever it is printed (X-037), and an
/// Angle row shows its angle in the ledger's Value and Unit cells (X-038).
@MainActor
@Suite("Iteration 7 — measurement presentation, area headline, angle Value")
struct Iter7UIPresentationMeasureAppCoreTests {

    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// One A-101 page at 0.1 m per point: 100 pt = 10 m.
    private static func session() async throws -> (TakeoffSession, DocumentID, PageID) {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: pageID, documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        return (session, documentID, pageID)
    }

    private static func square(_ x: Double, _ y: Double, _ side: Double) -> [PDFPoint] {
        [PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y), PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)]
    }

    private static func record(
        _ id: MarkupID, _ documentID: DocumentID, _ pageID: PageID,
        tool: ZPDFContracts.MeasurementTool, ring: [PDFPoint], label: String = ""
    ) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: id, documentID: documentID, pageID: pageID,
            kind: tool == .area ? .measurement : .polygon, tool: tool,
            subject: tool == .area ? "Slab" : "Opening", label: label, author: "A. Berg",
            geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    // MARK: - X-037

    /// A 10 × 10 m slab (100 × 100 pt) with a 4 × 4 m opening (40 × 40 pt).
    /// Hand-derived: gross 10 × 10 = 100 m², opening 4 × 4 = 16 m², net 100 − 16 = 84 m².
    @Test("X-037: a slab with an opening reads 84.00 m² — the ledger's Plan Area — not the 100.00 m² outline")
    func areaHeadlineIsTheNetArea() async throws {
        let (session, documentID, pageID) = try await Self.session()
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(
            Self.record(parentID, documentID, pageID, tool: .area, ring: Self.square(100, 100, 100), label: "Slab A")
        ))
        let before = try #require(await session.markup(parentID))
        try await environment.commands.perform(.addCutout(
            parent: parentID,
            cutout: Self.record(cutoutID, documentID, pageID, tool: .polygonCutout, ring: Self.square(130, 130, 40))
        ))
        await environment.commands.settle()
        await environment.refresh()
        let after = try #require(await session.markup(parentID))
        #expect(after.measurement?[.planArea]?.value == 100)
        #expect(after.measurement?[.netArea]?.value == 84)

        let summary = try #require(environment.snapshot.markups.first { $0.id == parentID.rawValue })
        // Old output: "100.00 m²", the gross field, on every surface that prints the headline.
        #expect(summary.primaryField?.field == .netArea)
        #expect(summary.primaryField?.displayTextWithUnit == "84.00 m²", "old output: 100.00 m²")
        #expect(summary.field(.planArea)?.displayTextWithUnit == "100.00 m²", "the outline is still there, as Gross Area")
        #expect(summary.field(.planArea)?.isDerived == true)
        #expect(summary.accessibilityLabel.contains("84.00 m²"), "\(summary.accessibilityLabel)")
        #expect(!summary.accessibilityLabel.contains("100.00 m²"), "old output: VoiceOver read the outline")
        // The ledger's row reads the same number, so the drawing and the takeoff agree.
        let projection = try await session.ledgerProjection(.flat)
        let row = try #require((0..<projection.rowCount).compactMap { projection.row(at: $0) }.first { $0.markupID == parentID.rawValue })
        #expect(row.quantity(.planArea)?.value == 84)
        #expect(LedgerDefaultColumns.valueText(for: row) == "84.00")
        // The cutout's own headline stays its own area (its result has no net field).
        let cutout = try #require(environment.snapshot.markups.first { $0.id == cutoutID.rawValue })
        #expect(cutout.primaryField?.field == .planArea)
        #expect(cutout.primaryField?.displayTextWithUnit == "16.00 m²")

        // Carry Forward compares the headline: an opening cut in the new sheet is a change.
        // Old output: field planArea, 100 → 100, delta 0.
        let target = PageID(UUID())
        let plan = CarryForwardPlan(
            items: [CarryForwardItem(sourceID: parentID, carriedID: parentID, target: target, classification: .needsReview)],
            commands: [], skipped: []
        )
        let report = CarryForwardReport.make(plan: plan, source: [parentID: before], carried: [parentID: after])
        #expect(report.rows.first?.field == .netArea)
        #expect(report.rows.first?.delta == -16, "hand-derived: 84 − 100")
        #expect(report.totalDelta[.netArea] == -16)
    }

    @Test("X-037: a value kept under an older scale is flagged on the area's headline, the net area")
    func staleFlagRidesOnTheHeadline() throws {
        let result = MeasurementResult(values: [
            .planArea: .area(100), .netArea: .area(84), .perimeter: .length(40)
        ])
        let scale = try ScaleTransform.uniform(
            id: ScaleID(UUID()), pageID: PageID(UUID()), version: 2, metresPerPoint: Decimal(string: "0.1")!,
            units: ScaleUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre), source: .preset
        )
        let flagged = try #require(TakeoffSession.flaggingStale(result, current: scale, tool: .area))
        let warning = try #require(flagged.warnings.first { $0.code == .staleScaleVersion })
        // Old output: .planArea — the warning sat on a field the headline no longer shows.
        #expect(warning.field == .netArea)
    }

    // MARK: - X-038

    /// Two angles at the vertex (100, 100): a right angle (rays along +x and +y) and 45°
    /// (rays along +x and the diagonal). Hand-derived: atan2(1, 0) = 90°, atan2(1, 1) = 45°.
    @Test("X-038: an Angle row shows its angle in Value and ° in Unit, and no Value total")
    func angleRowShowsItsAngle() async throws {
        let (session, documentID, pageID) = try await Self.session()
        let angles: [(String, [PDFPoint])] = [
            ("Right", [PDFPoint(x: 200, y: 100), PDFPoint(x: 100, y: 100), PDFPoint(x: 100, y: 200)]),
            ("Half", [PDFPoint(x: 200, y: 100), PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 200)])
        ]
        for (label, points) in angles {
            _ = try await session.apply(.addMarkup(ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
                kind: .measurement, tool: .angle, subject: "Corner", label: label, author: "A. Berg",
                geometry: MeasurementGeometry(pageID: pageID, points: points),
                createdAt: Self.stamp, modifiedAt: Self.stamp
            )))
        }
        let set = await session.ledgerColumns
        let icon = LedgerColumnID(try #require(set.column(standard: .icon)).key)
        let presenter = AppLedgerPresenter(session: session, projection: try await session.ledgerProjection(.flat))
        presenter.setGrouping([icon])
        await presenter.refresh()
        let value = LedgerDefaultColumns.valueColumnID
        let unit = LedgerDefaultColumns.unitColumnID

        var shown: [String: String] = [:]
        for position in 0..<presenter.rowCount {
            let row = try #require(presenter.row(at: position))
            // Old output: "" and "" — no ledger column reads `angle`, and the candidate list
            // pointed at Slope Angle, which the Angle tool never writes.
            shown[row.displayValue(.label)] = LedgerDefaultColumns.valueText(for: row) + " " + LedgerDefaultColumns.unitText(for: row)
            #expect(row.displayValues[unit] == "°")
            let quantity = try #require(LedgerDefaultColumns.primaryQuantity(for: row))
            #expect(quantity.dimension == .angle)
            #expect(row.values[value] == .quantity(quantity))
        }
        #expect(shown == ["Right": "90.00 °", "Half": "45.00 °"])

        // An angle is a fact about one corner: the Angle heading and the grand total add none.
        let group = try #require(presenter.rootGroups.first)
        #expect(presenter.rootGroups.count == 1)
        #expect(group.totals.rowCount == 2)
        #expect(group.totals.total(value) == nil)
        #expect(presenter.grandTotals.total(value) == nil)
    }
}
