import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Iteration 2, appcore: summaries and reports that must agree with the ledger (S-026, S-031, S-037).
@Suite("Iter2 appcore: summaries agree with the ledger")
struct Iter2AppCoreSummaryTests {

    struct Fixture {
        let session: TakeoffSession
        let documentID: DocumentID
        let page: PageID
    }

    /// A Letter sheet at 100 pt = 10 m, so 1 pt is 0.1 m and 1 pt² is 0.01 m².
    static func fixture() async throws -> Fixture {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        return Fixture(session: session, documentID: documentID, page: page.id)
    }

    static func record(
        _ fixture: Fixture, tool: MeasurementTool, subject: String, geometry: MeasurementGeometry,
        parameters: MeasurementParameters? = nil
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: fixture.documentID, pageID: fixture.page, kind: .measurement,
            tool: tool, subject: subject, author: "test", geometry: geometry, parameters: parameters,
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func rectangle(_ fixture: Fixture, x: Double = 0, y: Double = 0, width: Double, height: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: fixture.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x, y: y), PDFPoint(x: x + width, y: y),
            PDFPoint(x: x + width, y: y + height), PDFPoint(x: x, y: y + height)
        ], isClosed: true))])
    }

    static func line(_ fixture: Fixture, y: Double = 300, length: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: fixture.page, points: [PDFPoint(x: 0, y: y), PDFPoint(x: length, y: y)])
    }

    @discardableResult
    static func add(_ fixture: Fixture, _ record: ZPDFContracts.MarkupRecord) async throws -> MarkupID {
        _ = try await fixture.session.apply(.addMarkup(record))
        return record.id
    }

    struct Line: Hashable {
        let subject: String
        let value: Decimal
        let lengthPower: Int
        let rows: Int
    }

    static func lines(_ totals: [LedgerSubjectTotal]) -> Set<Line> {
        Set(totals.map { Line(subject: $0.subject, value: $0.quantity.value, lengthPower: $0.quantity.dimension.lengthPower, rows: $0.rowCount) })
    }

    // MARK: S-026

    @Test("A subject with rows in two units, or with a Rise/Drop row, keeps its lines in the project summary")
    func mixedAndNonAdditiveSubjectsStay() async throws {
        let fixture = try await Self.fixture()
        // Wall: 40 pt = 4 m, and 50 × 20 pt = 5 m × 2 m = 10 m².
        try await Self.add(fixture, Self.record(fixture, tool: .length, subject: "Wall", geometry: Self.line(fixture, length: 40)))
        try await Self.add(fixture, Self.record(fixture, tool: .area, subject: "Wall", geometry: Self.rectangle(fixture, width: 50, height: 20)))
        // Roof: 100 × 20 pt = 10 m × 2 m = 20 m², plus a Rise/Drop row whose Value (its 1 m rise) never totals.
        try await Self.add(fixture, Self.record(fixture, tool: .area, subject: "Roof", geometry: Self.rectangle(fixture, y: 100, width: 100, height: 20)))
        var rise = MeasurementParameters.default
        rise.slope = .total(1)
        try await Self.add(fixture, Self.record(fixture, tool: .riseDrop, subject: "Roof", geometry: Self.line(fixture, y: 400, length: 30), parameters: rise))
        // Slab: 100 × 30 pt = 10 m × 3 m = 30 m², one unit only — the core's own heading.
        try await Self.add(fixture, Self.record(fixture, tool: .area, subject: "Slab", geometry: Self.rectangle(fixture, y: 200, width: 100, height: 30)))

        let totals = try await fixture.session.subjectTotals()
        // Old output: only Slab 30 m² — Wall ("Mixed units") and Roof (non-additive) vanished.
        #expect(Self.lines(totals) == [
            Line(subject: "Wall", value: 4, lengthPower: 1, rows: 1),
            Line(subject: "Wall", value: 10, lengthPower: 2, rows: 1),
            Line(subject: "Roof", value: 20, lengthPower: 2, rows: 1),
            Line(subject: "Slab", value: 30, lengthPower: 2, rows: 1)
        ])
        let wall = totals.filter { $0.subject == "Wall" }
        #expect(wall.map(\.quantity.dimension.lengthPower) == [1, 2], "length before area")
        #expect(wall.allSatisfy { !$0.text.isEmpty })

        // Another drawing's Wall 6 m combines with this one's 4 m; the 10 m² stays its own line.
        let other = try await Self.fixture()
        try await Self.add(other, Self.record(other, tool: .length, subject: "Wall", geometry: Self.line(other, length: 60)))
        let combined = ProjectLedgerCombiner.combine([
            .init(documentID: UUID(), title: "A", totals: totals),
            .init(documentID: UUID(), title: "B", totals: try await other.session.subjectTotals())
        ], formatter: QuantityFormatter())
        #expect(Self.lines(combined).contains(Line(subject: "Wall", value: 10, lengthPower: 1, rows: 2)))
        #expect(Self.lines(combined).contains(Line(subject: "Wall", value: 10, lengthPower: 2, rows: 1)))
        #expect(combined.count == 4)
    }

    // MARK: S-031

    @Test("The snapshot change report adds exactly what the ledger adds: a Rise/Drop row's rise stays out")
    func changeReportFollowsTheLedgersAdditivity() async throws {
        let fixture = try await Self.fixture()
        // Roof: a 40 pt = 4 m length, and a Rise/Drop row whose Value is its 1 m rise.
        let length = try await Self.add(fixture, Self.record(fixture, tool: .length, subject: "Roof", geometry: Self.line(fixture, length: 40)))
        var rise = MeasurementParameters.default
        rise.slope = .total(1)
        let riseID = try await Self.add(fixture, Self.record(fixture, tool: .riseDrop, subject: "Roof",
                                                             geometry: Self.line(fixture, y: 400, length: 30), parameters: rise))
        let before = try await fixture.session.ledgerSnapshotBody()
        let riseRow = try #require(before.rows.first { $0.markupID == riseID.rawValue })
        #expect(riseRow.primary?.value == 1 && riseRow.primary?.dimension.lengthPower == 1, "the rise is a length")
        // Old output: true — a dimension test cannot tell a rise from a length.
        #expect(riseRow.primaryAdds == false)
        #expect(before.rows.first { $0.markupID == length.rawValue }?.primaryAdds == true)

        // The length grows to 60 pt = 6 m.
        _ = try await fixture.session.apply(.editVertices(id: length, geometry: Self.line(fixture, length: 60)))
        let after = try await fixture.session.ledgerSnapshotBody()
        let report = LedgerChangeReportBuilder.report(name: "Issue A", date: Date(), before: before, after: after, formatter: QuantityFormatter())
        let roof = try #require(report.subjectTotals.first { $0.title == "Roof" && $0.before.dimension.lengthPower == 1 })
        // Old output: 5 m → 7 m (the 1 m rise added to both); the ledger says 4 m → 6 m.
        #expect(roof.before.value == 4)
        #expect(roof.after.value == 6)
        #expect(report.grandTotals.first?.after.value == 6)

        // A snapshot written by the old rule marked the rise as adding. The same markup's current
        // flag answers for it, so an unchanged takeoff reports no change in the totals.
        var legacy = before
        legacy.rows = legacy.rows.map { row in
            var row = row
            if row.markupID == riseID.rawValue { row.primaryAdds = true }
            return row
        }
        let unchanged = LedgerChangeReportBuilder.report(name: "Legacy", date: Date(), before: legacy, after: before, formatter: QuantityFormatter())
        // Without the carry-over: Roof 5 m → 4 m, "the rise left the totals".
        #expect(unchanged.subjectTotals.isEmpty)
        #expect(unchanged.grandTotals.isEmpty)
    }

    // MARK: S-037

    @Test("The recalibration prompt's totals are the ledger's: Repeat × applied, cutout perimeters left out")
    func scaleImpactTotalsAgreeWithTheLedger() async throws {
        let fixture = try await Self.fixture()
        // A 100 × 100 pt room at 0.1 m/pt: 10 m × 10 m = 100 m², perimeter 40 m, marked ×10.
        let room = try await Self.add(fixture, Self.record(fixture, tool: .area, subject: "Room", geometry: Self.rectangle(fixture, width: 100, height: 100)))
        _ = try await fixture.session.apply(RepetitionColumn.edit(markupID: room, count: 10))
        // A 20 × 20 pt hole in it: 2 m × 2 m = 4 m², perimeter 8 m. The room nets 96 m².
        var hole = Self.record(fixture, tool: .polygonCutout, subject: "Room", geometry: Self.rectangle(fixture, x: 20, y: 20, width: 20, height: 20))
        hole.parentMarkupID = nil
        _ = try await fixture.session.apply(.addCutout(parent: room, cutout: hole))

        // Doubling the scale to 0.2 m/pt: net 384 m² per room, perimeter 80 m.
        let current = try #require(await fixture.session.scale(onPage: fixture.page))
        let candidate = try ScaleTransform.uniform(
            id: current.id, pageID: fixture.page, version: current.version + 1,
            metresPerPoint: Decimal(string: "0.2")!, units: .metric, source: .calibrationTwoPoint
        )
        let impact = await fixture.session.scaleChangeImpact(page: fixture.page, candidate: candidate)
        let net = try #require(impact.totals.first { $0.field == .netArea })
        // Old output: 96 → 384 — the ×10 the ledger shows (960 m²) ignored.
        #expect(net.before == 960)
        #expect(net.after == 3_840)
        let perimeter = try #require(impact.totals.first { $0.field == .perimeter })
        // Old output: 48 → 96 — the hole's 8 m perimeter added beside the room's 40 m, and no ×10.
        #expect(perimeter.before == 400)
        #expect(perimeter.after == 800)
        #expect(net.relativeChange == 3)
        #expect(impact.changedCount == 2, "the room and its hole both get new values")

        // The ledger agrees: Plan Area (the net area, ADR-0016) totals 960 m², Perimeter 400 m.
        let ledger = try await fixture.session.ledgerProjection(.flat)
        let areaColumn = LedgerColumnID(try #require(await fixture.session.ledgerColumns.column(standard: .planArea)).key)
        let perimeterColumn = LedgerColumnID(try #require(await fixture.session.ledgerColumns.column(standard: .perimeter)).key)
        #expect(ledger.grandTotals.quantities[areaColumn]?.value == 960)
        #expect(ledger.grandTotals.quantities[perimeterColumn]?.value == 400)
    }
}
