import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// Project Zones and the save (U-027, U-028, U-029).
///
/// `markup.zone_id` and `project_zone_extra.parent_zone_id` are foreign keys, checked when the
/// save's transaction commits (`defer_foreign_keys`). Each case below used to fail that commit —
/// so that save and every later save and autosave — or silently drop a zone's parent.
@Suite("Iteration 4 — zones and the save")
struct Iter4AppCoreZoneSaveTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    static func workspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it4-appcore-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func line(on page: ZPDFContracts.PageDescriptor, length: Double) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .length,
            subject: "Wall", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 10 + length, y: 10)]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func square(on page: ZPDFContracts.PageDescriptor, origin: Double, side: Double) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Slab", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: origin, y: origin), PDFPoint(x: origin + side, y: origin),
                PDFPoint(x: origin + side, y: origin + side), PDFPoint(x: origin, y: origin + side)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func zone(_ name: String, page: PageID?, parent: ZoneID? = nil, order: Int = 0) -> ProjectZoneDefinition {
        ProjectZoneDefinition(
            id: ZoneID(UUID()), name: name, kind: .room, parentID: parent, pageID: page,
            boundary: page == nil ? [] : [PDFPoint(x: 0, y: 0), PDFPoint(x: 50, y: 0), PDFPoint(x: 50, y: 50)],
            sortOrder: order, colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        )
    }

    /// Writes the session into a fresh single-drawing package and reads it back.
    static func saveAndRead(
        _ session: TakeoffSession, fixture: OpenedFixture, in directory: URL
    ) async throws -> TakeoffArchive.StoredTakeoff {
        let url = directory.appendingPathComponent("Zones-\(UUID().uuidString).zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Zones", originalPDF: fixture.url)
        do {
            try await TakeoffArchive.write(await session.takeoffState(), into: package)
            _ = try await package.save()
        } catch {
            try? await package.close()
            throw error
        }
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            throw ZPDFPersistenceError.packageMalformed(reason: "reopen required recovery")
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        return stored
    }

    // MARK: U-027

    /// Combine Open Drawings carries another project's markups whole, zone included. Old output:
    /// the save threw `FOREIGN KEY constraint failed` at COMMIT, and so did every later one.
    @Test("A markup carried in from another project, filed in that project's zone, arrives unfiled and saves")
    func carriedForeignZoneIsUnfiled() async throws {
        let directory = try Self.workspace("carry-zone")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.appendingPathComponent("a"))
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)

        // The other drawing's markup, filed in a zone only that drawing has.
        var foreign = Self.line(on: fixture.firstPage, length: 100)
        foreign.pageID = PageID(UUID())
        foreign.geometry?.pageID = foreign.pageID
        foreign.zoneID = ZoneID(UUID())
        let plan = CarryForwardPlanner.plan(
            markups: [foreign],
            pairs: [foreign.pageID: CarryPair(target: fixture.firstPage.id, alignment: .identity)],
            now: Self.stamp
        )
        for command in plan.commands { _ = try await session.apply(command) }
        let carried = try #require(await session.orderedMarkups.first)
        #expect(carried.zoneID == nil, "the other project's zone is not one this project holds")

        let stored = try await Self.saveAndRead(session, fixture: fixture, in: directory)
        #expect(stored.markups.map(\.id) == [carried.id], "the save committed")
        #expect(stored.markups.first?.zoneID == nil)
    }

    /// Cut a zoned markup, delete its zone, paste. Old output: the pasted record kept the deleted
    /// zone's id and the save failed at COMMIT.
    @Test("Pasting a markup whose zone was deleted after the copy files it nowhere and saves")
    func pasteAfterZoneDeletionIsUnfiled() async throws {
        let directory = try Self.workspace("paste-zone")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.appendingPathComponent("a"))
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        let room = Self.zone("Room 1", page: fixture.firstPage.id)
        let kept = Self.zone("Room 2", page: fixture.firstPage.id, order: 1)
        _ = try await session.apply(.setProjectZones([room, kept]))
        let original = Self.line(on: fixture.firstPage, length: 100)
        _ = try await session.apply(.addMarkup(original))
        _ = try await session.apply(.setMarkupZone(ids: [original.id], zoneID: room.id))
        let copied = try #require(await session.orderedMarkups.first)
        #expect(copied.zoneID == room.id)
        let payload = MarkupClipboardPayload(
            sourceDocumentID: fixture.documentID.rawValue, sourcePageID: fixture.firstPage.id.rawValue, records: [copied]
        )
        _ = try await session.apply(.removeMarkup(original.id))   // the cut
        _ = try await session.apply(.setProjectZones([kept]))     // Room 1 deleted

        let pasted = MarkupClipboard.prepared(
            payload, targetPageID: fixture.firstPage.id.rawValue, targetDocumentID: fixture.documentID.rawValue,
            dx: 0, dy: 0, now: Self.stamp, author: "A. Berg", newID: { UUID() }
        )
        #expect(pasted.first?.zoneID == room.id, "the pasteboard still names the deleted zone")
        for record in pasted { _ = try await session.apply(.addMarkup(record)) }
        #expect(await session.orderedMarkups.map(\.zoneID) == [nil])

        // A zone the project still holds is kept: the paste of a Room 2 markup stays filed there.
        var filed = Self.line(on: fixture.firstPage, length: 50)
        filed.zoneID = kept.id
        _ = try await session.apply(.addMarkup(filed))
        #expect(await session.orderedMarkups.last?.zoneID == kept.id)

        let stored = try await Self.saveAndRead(session, fixture: fixture, in: directory)
        #expect(stored.markups.count == 2, "the save committed")
        #expect(stored.markups.first { $0.id == filed.id }?.zoneID == kept.id)
        #expect(stored.markups.first { $0.id != filed.id }?.zoneID == nil)
    }

    /// A cutout enters through its own funnel. Old output: the cutout kept the unknown zone and
    /// the save failed at COMMIT.
    @Test("A cutout naming a zone the project does not hold arrives unfiled")
    func cutoutWithForeignZoneIsUnfiled() async throws {
        let directory = try Self.workspace("cutout-zone")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory.appendingPathComponent("a"))
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        let parent = Self.square(on: fixture.firstPage, origin: 0, side: 100)
        _ = try await session.apply(.addMarkup(parent))
        var hole = Self.square(on: fixture.firstPage, origin: 20, side: 10)
        hole.tool = .polygonCutout
        hole.zoneID = ZoneID(UUID())
        _ = try await session.apply(.addCutout(parent: parent.id, cutout: hole))
        #expect(await session.orderedMarkups.first { $0.id == hole.id }?.zoneID == nil)
        let stored = try await Self.saveAndRead(session, fixture: fixture, in: directory)
        #expect(stored.markups.count == 2, "the save committed")
    }

    // MARK: U-028

    /// File a markup, remove its sheet from the set, delete the zone, save. Old output: the
    /// set-aside markup still named the deleted zone and the save failed at COMMIT.
    @Test("Deleting a zone while its markup's sheet is out of the set leaves the project saveable; undo refiles it")
    func setAsideMarkupUnfiledFromDeletedZone() async throws {
        let directory = try Self.workspace("set-aside-zone")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory.appendingPathComponent("a"))
        let pages = Array(fixture.pages.prefix(2))
        let session = try TakeoffSession(documentID: fixture.documentID, pages: pages, units: .metric)
        let room = Self.zone("Room 1", page: nil)
        _ = try await session.apply(.setProjectZones([room]))
        let markup = Self.line(on: pages[1], length: 100)
        _ = try await session.apply(.addMarkup(markup))
        _ = try await session.apply(.setMarkupZone(ids: [markup.id], zoneID: room.id))
        _ = try await session.apply(.setPagesExcluded([pages[1].id], excluded: true))
        let deletion = try await session.apply(.setProjectZones([]))

        #expect(await session.takeoffState().setAsideMarkups.map(\.zoneID) == [nil], "saved unfiled")
        let stored = try await Self.saveAndRead(session, fixture: fixture, in: directory)
        #expect(stored.markups.map(\.id) == [markup.id], "the save committed")
        #expect(stored.markups.first?.zoneID == nil)
        #expect(stored.excludedPageIDs == [pages[1].id])

        // The stored set-aside record is untouched: undoing the deletion refiles it.
        let redo = try await session.revert(deletion.inverse)
        #expect(await session.takeoffState().setAsideMarkups.map(\.zoneID) == [room.id])

        // Deleted again, then the sheet restored: the markup returns filed nowhere, and saves.
        _ = try await session.revert(redo)
        _ = try await session.apply(.setPagesExcluded([pages[1].id], excluded: false))
        #expect(await session.orderedMarkups.first { $0.id == markup.id }?.zoneID == nil)
        let again = try await Self.saveAndRead(session, fixture: fixture, in: directory)
        #expect(again.markups.map(\.id) == [markup.id])
        #expect(again.excludedPageIDs.isEmpty)
    }

    // MARK: U-029

    /// Writes the set, closes, reopens and reads every drawing back as one stored takeoff.
    static func writeSetAndRead(
        _ session: TakeoffSession, at url: URL, rows: [DocumentID: String], package: ProjectPackage
    ) async throws -> TakeoffArchive.StoredTakeoff {
        try await TakeoffArchive.writeSet(await session.takeoffState(), into: package, documentRows: rows)
        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            throw ZPDFPersistenceError.packageMalformed(reason: "reopen required recovery")
        }
        let stored = try await TakeoffArchive.readSet(from: reopened)
        try await reopened.close()
        var merged: TakeoffArchive.StoredTakeoff?
        for entry in stored { if let takeoff = entry.takeoff { merged = merged.map { $0.merging(takeoff) } ?? takeoff } }
        return try #require(merged)
    }

    /// A markup on drawing 1 filed in a new zone on drawing 2. Old output: drawing 1's own
    /// transaction committed before drawing 2 wrote the zone, and failed on the foreign key.
    @Test("A two-drawing set saves a drawing-1 markup filed in a new zone on drawing 2, and reopens filed")
    func crossDrawingZoneFilingSaves() async throws {
        let directory = try Self.workspace("set-zone")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await OpenedFixture.open(.titleBlockSheet, in: directory.appendingPathComponent("a"))
        let b = try await OpenedFixture.open(.mixedPageSizes, in: directory.appendingPathComponent("b"))
        let url = directory.appendingPathComponent("Set.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Set", originalPDF: a.url)
        let rowA = try await TakeoffArchive.documentRows(of: package)[0]
        let rowB = try await package.addDocument(originalPDF: b.url, displayName: "B", pageCount: b.pages.count)
        let rows = [a.documentID: rowA, b.documentID: rowB]
        let session = try TakeoffSession(documentID: a.documentID, pages: a.pages + b.pages, units: .metric)
        let onB = Self.zone("Level 2", page: b.pages[0].id)
        _ = try await session.apply(.setProjectZones([onB]))
        let markup = Self.line(on: a.pages[0], length: 100)
        _ = try await session.apply(.addMarkup(markup))
        _ = try await session.apply(.setMarkupZone(ids: [markup.id], zoneID: onB.id))

        let takeoff = try await Self.writeSetAndRead(session, at: url, rows: rows, package: package)
        #expect(takeoff.markups.first { $0.id == markup.id }?.zoneID == onB.id, "filed across drawings")
        #expect(takeoff.projectZones.map(\.id) == [onB.id])
        #expect(takeoff.projectZones.first?.pageID == b.pages[0].id, "the zone stays on drawing 2's sheet")
    }

    /// A child zone on drawing 1 under a parent on drawing 2, saved twice. Old output: after the
    /// second save the child's parent was nil — drawing 2's `DELETE FROM project_zone` fired
    /// `ON DELETE SET NULL` on drawing 1's already-written child row. On the first save of a new
    /// parent the save failed outright.
    @Test("A child zone on drawing 1 keeps its parent on drawing 2 through two saves")
    func crossDrawingZoneNestingSurvives() async throws {
        let directory = try Self.workspace("set-nesting")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await OpenedFixture.open(.titleBlockSheet, in: directory.appendingPathComponent("a"))
        let b = try await OpenedFixture.open(.mixedPageSizes, in: directory.appendingPathComponent("b"))
        let url = directory.appendingPathComponent("Nest.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Nest", originalPDF: a.url)
        let rowA = try await TakeoffArchive.documentRows(of: package)[0]
        let rowB = try await package.addDocument(originalPDF: b.url, displayName: "B", pageCount: b.pages.count)
        let rows = [a.documentID: rowA, b.documentID: rowB]
        let session = try TakeoffSession(documentID: a.documentID, pages: a.pages + b.pages, units: .metric)
        let parent = Self.zone("Building", page: b.pages[0].id)
        let child = Self.zone("Room 101", page: a.pages[0].id, parent: parent.id, order: 1)
        let unpaged = Self.zone("Phase 2", page: nil, parent: parent.id, order: 2)
        _ = try await session.apply(.setProjectZones([parent, child, unpaged]))

        let first = try await Self.writeSetAndRead(session, at: url, rows: rows, package: package)
        #expect(first.projectZones.first { $0.id == child.id }?.parentID == parent.id, "first save")
        #expect(first.projectZones.first { $0.id == unpaged.id }?.parentID == parent.id)
        #expect(first.projectZones.first { $0.id == unpaged.id }?.pageID == nil, "a zone with no sheet claims none")

        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            Issue.record("reopen required recovery"); return
        }
        let second = try await Self.writeSetAndRead(session, at: url, rows: rows, package: reopened)
        #expect(Set(second.projectZones.map(\.id)) == [parent.id, child.id, unpaged.id])
        #expect(second.projectZones.first { $0.id == child.id }?.parentID == parent.id, "second save keeps the parent")
        #expect(second.projectZones.first { $0.id == unpaged.id }?.parentID == parent.id)
    }
}
