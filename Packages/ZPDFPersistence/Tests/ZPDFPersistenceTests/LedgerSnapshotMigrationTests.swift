import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v14 (NL-QTY-16): named takeoff snapshots.
@Suite("Ledger snapshots, v14")
struct LedgerSnapshotMigrationTests {

    /// A project database exactly as a v13 build left it, with a project row in it.
    private func makeV13Database(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("project.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v13-document-set")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO project (id, name, created_at, modified_at, schema_version)
                VALUES ('p', 'P', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 13)
                """)
            #expect(try !db.tableExists("ledger_snapshot"), "precondition: a genuine v13 database")
        }
        try queue.close()
        return url
    }

    @Test("A v13 project migrates to v14 with an empty snapshot table, keeps its data, and opens clean")
    func oldProjectMigrates() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("V14OldSchema")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV13Database(in: directory)

        let readOnly = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        #expect(readOnly.schemaDeviations.isEmpty)
        try await readOnly.close()

        let migrated = try await ProjectDatabaseActor.open(at: url)
        let (version, exists, projectName, snapshots) = try await migrated.read { db in
            (
                try Int.fetchOne(db, sql: "PRAGMA user_version"),
                try db.tableExists("ledger_snapshot"),
                try String.fetchOne(db, sql: "SELECT name FROM project WHERE id = 'p'"),
                try LedgerSnapshotStore.list(project: "p", in: db)
            )
        }
        #expect(version == ProjectSchema.currentVersion)
        #expect(exists)
        #expect(projectName == "P", "the old project's data survives the migration")
        #expect(snapshots.isEmpty)
        #expect(migrated.schemaDeviations.isEmpty)
        try await migrated.close()
    }

    @Test("Snapshots round-trip newest first and delete by id, per project")
    func snapshotsRoundTrip() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("V14Snapshots")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV13Database(in: directory)
        let database = try await ProjectDatabaseActor.open(at: url)
        try await database.write { db in
            try LedgerSnapshotStore.insert(LedgerSnapshotRecord(
                id: "a", projectId: "p", name: "Bid 1", createdAt: "2026-09-01T00:00:00.000Z",
                author: "E", rowCount: 3, bodyJson: "{\"rows\":[]}"
            ), in: db)
            try LedgerSnapshotStore.insert(LedgerSnapshotRecord(
                id: "b", projectId: "p", name: "Bid 2", createdAt: "2026-09-10T00:00:00.000Z",
                author: "E", rowCount: 4, bodyJson: "{}"
            ), in: db)
            try LedgerSnapshotStore.insert(LedgerSnapshotRecord(
                id: "c", projectId: "other", name: "Elsewhere", createdAt: "2026-09-11T00:00:00.000Z",
                author: "E", rowCount: 1, bodyJson: "{}"
            ), in: db)
        }
        var names = try await database.read { db in try LedgerSnapshotStore.list(project: "p", in: db).map(\.name) }
        #expect(names == ["Bid 2", "Bid 1"])
        let body = try await database.read { db in try LedgerSnapshotStore.snapshot(id: "a", project: "p", in: db)?.bodyJson }
        #expect(body == "{\"rows\":[]}")
        let deleted = try await database.write { db in try LedgerSnapshotStore.delete(id: "b", project: "p", in: db) }
        #expect(deleted)
        names = try await database.read { db in try LedgerSnapshotStore.list(project: "p", in: db).map(\.name) }
        #expect(names == ["Bid 1"])
        try await database.close()
    }
}
