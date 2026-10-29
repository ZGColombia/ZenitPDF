import Foundation
import GRDB
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFSearch
import ZPDFUIPresentation

/// IM-054 (incremental archive write) and IM-057 (incremental markup search index).
@Suite("Bug hunt 2: incremental writes")
struct BugHunt2IncrementalWriteTests {

    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(1, bound)))
        }
    }

    private func workspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-bh2-inc-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func area(_ generator: inout Generator, documentID: DocumentID, page: PageID) -> ZPDFContracts.MarkupRecord {
        let x = Double(generator.next(400)), y = Double(generator.next(400))
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .area,
            subject: ["Slab", "Wall", "Door"][generator.next(3)], author: "t",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: y), PDFPoint(x: x + 20, y: y), PDFPoint(x: x + 20, y: y + 10), PDFPoint(x: x, y: y + 10)
            ], isClosed: true))]),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Every markup-owned row, with the package-specific document id taken out.
    private static func dump(_ package: ProjectPackage) async throws -> [String] {
        try await package.read { db in
            var lines: [String] = []
            for (table, order) in [
                ("markup", "id"), ("measurement_value", "markup_id"), ("markup_extra", "markup_id"),
                ("markup_stamp", "markup_id"), ("markup_symbol", "markup_id")
            ] {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(order)") {
                    let cells = row.columnNames.sorted().filter { $0 != "document_id" }.map { "\($0)=\(row[$0] as DatabaseValue)" }
                    lines.append("\(table): " + cells.joined(separator: ","))
                }
            }
            return lines
        }
    }

    @Test("Incremental saves produce the database a full save produces")
    func incrementalSaveEqualsFullSave() async throws {
        let directory = try workspace("equal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let page = fixture.firstPage.id
        _ = try await session.calibrate(
            page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        let saved = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Incremental.zpdfproj", isDirectory: true),
            displayName: "Incremental", originalPDF: fixture.url
        )
        defer { Task { try? await saved.close() } }

        var generator = Generator(state: 7)
        for _ in 0..<20 { _ = try await session.apply(.addMarkup(Self.area(&generator, documentID: fixture.documentID, page: page))) }
        try await TakeoffArchive.write(await session.takeoffState(), into: saved)

        for step in 0..<40 {
            let ids = await session.orderedMarkups.map(\.id)
            let target = ids[generator.next(ids.count)]
            switch generator.next(5) {
            case 0: _ = try await session.apply(.addMarkup(Self.area(&generator, documentID: fixture.documentID, page: page)))
            case 1: _ = try? await session.apply(.removeMarkup(target))
            case 2: _ = try await session.apply(.editSubject(id: target, subject: "S\(step)"))
            case 3: _ = try await session.apply(.moveMarkup(id: target, dx: 3, dy: 1))
            default:
                _ = try await session.calibrate(
                    page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                    knownLength: Decimal(1 + generator.next(5)), knownLengthUnit: .metre
                )
            }
            try await TakeoffArchive.write(await session.takeoffState(), into: saved)
            let read = try #require(try await TakeoffArchive.read(from: saved))
            #expect(read.markups.map(\.id) == (await session.orderedMarkups.map(\.id)), "step \(step)")
        }

        // The same final state written in one full save into a fresh package.
        let full = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Full.zpdfproj", isDirectory: true),
            displayName: "Full", originalPDF: fixture.url
        )
        defer { Task { try? await full.close() } }
        try await TakeoffArchive.write(await session.takeoffState(), into: full)
        #expect(try await Self.dump(saved) == (try await Self.dump(full)))
    }

    @Test("A one-markup edit on 5 000 markups writes one markup's rows")
    func oneEditWritesOneMarkup() async throws {
        let directory = try workspace("measure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let page = fixture.firstPage.id
        _ = try await session.calibrate(
            page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        var generator = Generator(state: 11)
        var records: [ZPDFContracts.MarkupRecord] = []
        for _ in 0..<5_000 { records.append(Self.area(&generator, documentID: fixture.documentID, page: page)) }
        _ = try await session.applyBatch(records.map { .addMarkup($0) })
        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Big.zpdfproj", isDirectory: true),
            displayName: "Big", originalPDF: fixture.url
        )
        defer { Task { try? await package.close() } }
        try await TakeoffArchive.write(await session.takeoffState(), into: package)

        _ = try await session.apply(.editSubject(id: records[2_500].id, subject: "Renamed"))
        let before = try await package.write { db in db.totalChangesCount }
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await TakeoffArchive.write(await session.takeoffState(), into: package)
        }
        let after = try await package.write { db in db.totalChangesCount }
        let rowsWritten = after - before
        print("IM-054 one-markup edit on 5 000 markups: \(rowsWritten) row changes, \(elapsed)")
        // A full rewrite changes at least 3 rows per markup (markup, value, extra): 15 000+.
        // The incremental save changes the one markup (row + children) plus the structure rows.
        #expect(rowsWritten < 100, "rows changed: \(rowsWritten)")
        let stored = try #require(try await TakeoffArchive.read(from: package))
        #expect(stored.markups.first { $0.id == records[2_500].id }?.subject == "Renamed")
        #expect(stored.markups.count == 5_000)
    }

    // MARK: IM-057

    @Test("A re-index that changed no searchable row writes nothing")
    func searchReindexIsIncremental() async throws {
        let index = try await DocumentSearchIndexTests.makeIndex()
        defer { Task { await index.shutDown() } }
        let documentID = DocumentID(UUID())
        let pages = DocumentSearchIndexTests.pages(count: 1, documentID: documentID)
        var generator = Generator(state: 3)
        var markups = (0..<30).map { _ in Self.area(&generator, documentID: documentID, page: pages[0].id) }

        let first = try await index.indexMarkups(markups, pages: pages)
        #expect(first.markupRowsInserted == 30)

        // A style change: nothing search reads has moved. Old output: 30 rows rebuilt.
        markups[4].style.color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let unchanged = try await index.indexMarkups(markups, pages: pages)
        #expect(unchanged.rowsInserted == 0)
        #expect(unchanged.rowsDeleted == 0)

        // A subject edit is written, and only that markup's full-text rows are rebuilt (R-152).
        // Old output: 30 rows deleted and 30 inserted, the whole project's annotation rows.
        markups[4].subject = "Screed bay"
        let edited = try await index.indexMarkups(markups, pages: pages)
        #expect(edited.markupRowsInserted == 1)
        #expect(edited.rowsDeleted == 1)
        let found = try await index.service.search(SearchRequest(
            text: "screed", scope: .project(projectId: index.projectKey), resolvesBounds: false
        ))
        #expect(found.hits.count == 1)
    }
}
