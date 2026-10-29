import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// CR-12: a rescale is one `scale_changed` entry **and** one `markup_modified` entry per
/// markup it restamped, all under one `undo_group` (ADR-0007 §2).
///
/// The trail used to carry the scale entry alone, so forty rows whose numbers a recalibration
/// rewrote had a history that said nothing had happened to them.
@Suite("History fan-out for a rescale")
struct HistoryRescaleFanOutTests {

    @MainActor
    private func makeEnvironment() async throws -> (AppCoreEnvironment, ZPDFContracts.PageDescriptor, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, page, documentID)
    }

    private func makeDatabase() async throws -> (ProjectDatabaseActor, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-rescale-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("history.sqlite")
        )
        return (database, directory)
    }

    private static func markup(documentID: DocumentID, pageID: PageID, subject: String) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: subject,
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80),
                    PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    @Test("A recalibration fans out to every markup it restamped, under one undo group")
    @MainActor
    func rescaleFansOutPerMarkup() async throws {
        let (environment, page, documentID) = try await makeEnvironment()
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)

        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let slab = Self.markup(documentID: documentID, pageID: page.id, subject: "Slab")
        let deck = Self.markup(documentID: documentID, pageID: page.id, subject: "Deck")
        try await environment.commands.perform(.addMarkup(slab))
        try await environment.commands.perform(.addMarkup(deck))
        await environment.history.settle()
        let before = environment.history.events.count
        #expect(before == 3, "calibration, two creations: \(environment.history.events.map(\.action))")

        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 200, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        await environment.history.settle()
        let added = Array(environment.history.events.dropFirst(before))

        // Old output: one entry — `scale_changed` — and neither row's history mentioned it.
        #expect(added.map(\.action) == ["scale_changed", "markup_modified", "markup_modified"])
        #expect(Set(added.compactMap(\.undoGroup)).count == 1, "one step, one undo group")
        #expect(Set(added.compactMap(\.markupID)) == [slab.id.rawValue, deck.id.rawValue])
        #expect(added.first?.markupID == nil, "the scale entry names the scale, not a markup")
        for entry in added.dropFirst() {
            #expect(entry.changes.contains { $0.field == "planArea" && $0.before != $0.after },
                    "the fan-out carries the number that changed: \(entry.changes)")
        }

        // Undo compensates the whole group — an entry per entry, never an edit of the trail.
        await environment.commands.undo()
        await environment.history.settle()
        let compensations = Array(environment.history.events.dropFirst(before + 3))
        #expect(compensations.count == 3, "\(compensations.map(\.action))")
        #expect(environment.history.events.count == before + 6)
    }
}
