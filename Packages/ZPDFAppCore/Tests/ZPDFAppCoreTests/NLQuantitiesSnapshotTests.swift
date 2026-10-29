import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// NL-QTY-16: takeoff snapshots and the quantity-change report.
///
/// Hand-derived: four rectangles of 12, 12, 2 and 2 m² ("Slab 0" … "Slab 3") = 28 m². Then:
/// row 0 relabelled; row 1 re-drawn at 20 × 10 pt = 2 m²; row 2 moved to subject "Slab 0";
/// row 3 deleted; a 10 × 10 pt = 1 m² "Slab 4" added. After: 12 + 2 + 2 + 1 = 17 m², a delta of
/// −11 m². Per subject: Slab 0 12 → 14 (+2), Slab 1 12 → 2 (−10), Slab 2 2 → 0 (−2),
/// Slab 3 2 → 0 (−2), Slab 4 0 → 1 (+1); the deltas sum to −11.
@Suite("Quantities — snapshots and change report")
@MainActor
struct NLQuantitiesSnapshotTests {

    let bugs = NLQuantitiesBugTests()

    @Test("Snapshot 'Bid 1', edit three rows, add one, delete one: exactly those five, with exact deltas")
    func changeReportAcceptance() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30), (40, 30), (20, 10), (20, 10)])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("project.sqlite"))
        let documentID = await fixture.session.pageDescriptors[0].documentID
        fixture.environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)

        let snapshots = try #require(fixture.environment.ledger as? any LedgerSnapshotting)
        let taken = await snapshots.takeSnapshot(named: "Bid 1")
        #expect(!taken.didFail, "\(taken.failureDescription ?? "")")
        let list = await snapshots.snapshots()
        #expect(list.map(\.name) == ["Bid 1"])
        #expect(list.first?.rowCount == 4)
        let before = try #require(fixture.environment.ledger.grandTotals.quantities[LedgerDefaultColumns.valueColumnID])
        #expect(before.value == 28)

        let page = await fixture.session.pageDescriptors[0]
        try await fixture.environment.commands.perform(.editLabel(id: fixture.ids[0], label: "L-1"))
        try await fixture.environment.commands.perform(.editVertices(id: fixture.ids[1], geometry: MeasurementGeometry(
            pageID: page.id,
            polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 20, y: 0), PDFPoint(x: 20, y: 10), PDFPoint(x: 0, y: 10)
            ], isClosed: true))]
        )))
        try await fixture.environment.commands.perform(.editSubject(id: fixture.ids[2], subject: "Slab 0"))
        try await fixture.environment.commands.perform(.removeMarkup(fixture.ids[3]))
        let added = MarkupID(UUID())
        let stamp = Date(timeIntervalSince1970: 1_700_000_500)
        try await fixture.environment.commands.perform(.addMarkup(MarkupRecord(
            id: added, documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Slab 4", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 10)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )))
        await fixture.environment.ledger.refresh()
        let after = try #require(fixture.environment.ledger.grandTotals.quantities[LedgerDefaultColumns.valueColumnID])
        #expect(after.value == 17)

        let report = try await snapshots.changeReport(since: try #require(list.first?.id))
        #expect(report.snapshotName == "Bid 1")
        // Exactly the five rows, each with what happened to it.
        let kinds = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.markupID, $0.kind) })
        #expect(kinds.count == 5)
        #expect(kinds[fixture.ids[0].rawValue] == .changed)
        #expect(kinds[fixture.ids[1].rawValue] == .changed)
        #expect(kinds[fixture.ids[2].rawValue] == .changed)
        #expect(kinds[fixture.ids[3].rawValue] == .removed)
        #expect(kinds[added.rawValue] == .added)
        let relabelled = try #require(report.rows.first { $0.markupID == fixture.ids[0].rawValue })
        #expect(relabelled.fields.map(\.column) == ["Label"], "a label edit changes the label and nothing else")
        #expect(relabelled.fields.first?.after == "L-1")
        let moved = try #require(report.rows.first { $0.markupID == fixture.ids[2].rawValue })
        #expect(moved.fields.contains { $0.column == "Subject" && $0.before == "Slab 2" && $0.after == "Slab 0" })

        // The grand delta is exactly after − before of the two grand totals: 17 − 28 = −11.
        let grand = try #require(report.grandTotals.first)
        #expect(grand.before.value == before.value && grand.after.value == after.value)
        #expect(grand.delta == -11)
        let bySubject = Dictionary(uniqueKeysWithValues: report.subjectTotals.map { ($0.title, $0.delta) })
        #expect(bySubject == ["Slab 0": 2, "Slab 1": -10, "Slab 2": -2, "Slab 3": -2, "Slab 4": 1])
        #expect(bySubject.values.reduce(Decimal(0), +) == grand.delta)

        #expect(await snapshots.deleteSnapshot(try #require(list.first?.id)))
        #expect(await snapshots.snapshots().isEmpty)
        try await database.close()
    }
}
