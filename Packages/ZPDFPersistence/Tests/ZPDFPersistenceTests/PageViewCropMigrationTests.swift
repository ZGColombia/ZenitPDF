import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v15 (NL-DOCS-16): a per-page view crop in `page_set_entry`.
@Suite("Page view crop, v15")
struct PageViewCropMigrationTests {

    /// A project database exactly as a v14 build left it: one document, one page, and the
    /// page's set entry rotated 90° and excluded.
    private func makeV14Database(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("project.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v14-ledger-snapshots")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO project (id, name, created_at, modified_at, schema_version)
                VALUES ('p', 'P', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 14)
                """)
            try DocumentRecord(
                id: "d", projectId: "p", displayName: "A", relativePath: "documents/working.pdf",
                sha256: "00", pageCount: 1, createdAt: "2026-01-01T00:00:00.000Z",
                modifiedAt: "2026-01-01T00:00:00.000Z"
            ).insert(db)
            try PageRecord(
                id: "page-1", documentId: "d", pageIndex: 0, pageLabel: nil,
                mediaX: 0, mediaY: 0, mediaWidth: 612, mediaHeight: 792,
                cropX: 0, cropY: 0, cropWidth: 612, cropHeight: 792, rotation: 0
            ).insert(db)
            try db.execute(sql: """
                INSERT INTO page_set_entry (page_id, position, view_rotation, excluded)
                VALUES ('page-1', 0, 90, 1)
                """)
            let columns = try db.columns(in: "page_set_entry").map(\.name)
            #expect(!columns.contains("crop_json"), "precondition: a genuine v14 database")
        }
        try queue.close()
        return url
    }

    @Test("A v14 project migrates to v15, keeps rotation and exclusion, has no crop, and opens clean")
    func oldProjectMigrates() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("V15OldSchema")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV14Database(in: directory)

        let readOnly = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        #expect(readOnly.schemaDeviations.isEmpty)
        try await readOnly.close()

        let migrated = try await ProjectDatabaseActor.open(at: url)
        let (version, entries) = try await migrated.read { db in
            (
                try Int.fetchOne(db, sql: "PRAGMA user_version"),
                try DocumentSetStore.pageEntries(document: "d", in: db)
            )
        }
        #expect(version == ProjectSchema.currentVersion) // 15 when written; v16/v17 follow
        let entry = try #require(entries["page-1"])
        #expect(entry.viewRotation == 90)
        #expect(entry.excluded)
        #expect(entry.cropJSON == nil, "nothing is backfilled")
        #expect(migrated.schemaDeviations.isEmpty)

        // The new column round-trips.
        try await migrated.write { db in
            var updated = entry
            updated.cropJSON = #"{"x":10,"y":20,"width":300,"height":400}"#
            try updated.update(db)
        }
        let reread = try await migrated.read { db in
            try DocumentSetStore.pageEntries(document: "d", in: db)["page-1"]?.cropJSON
        }
        #expect(reread == #"{"x":10,"y":20,"width":300,"height":400}"#)
        try await migrated.close()
    }
}
