import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v16 (NL-COLLAB-05, the author directory) and v17 (NL-AUTO-16, the Takeoff Assistant's
/// inbox). Both are new tables: an old project opens, migrates, keeps every row and
/// gains two empty tables that round-trip.
@Suite("Author directory v16 and proposal inbox v17")
struct PlatformR2MigrationTests {

    /// A project database exactly as a v15 build left it: one project, one review reply.
    private func makeV15Database(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("project.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v15-page-view-crop")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO project (id, name, created_at, modified_at, schema_version)
                VALUES ('p', 'P', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 15)
                """)
            try ReviewEntryStore.upsert(ReviewEntryRecord(
                id: "r1", projectId: "p", markupId: "m1", authorName: "Ada", body: "Check the door width",
                createdAt: "2026-01-02T00:00:00.000Z"), in: db)
            #expect(try !db.tableExists("author"), "precondition: a genuine v15 database")
            #expect(try !db.tableExists("automation_proposal"))
        }
        try queue.close()
        return url
    }

    @Test("A v15 project migrates to v17 with its reply intact and opens with no schema deviation")
    func oldProjectMigrates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("R2PlatformMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV15Database(in: directory)

        let readOnly = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        #expect(readOnly.schemaDeviations.isEmpty)
        try await readOnly.close()

        let migrated = try await ProjectDatabaseActor.open(at: url)
        #expect(migrated.schemaDeviations.isEmpty)
        let (version, replies, authors, proposals) = try await migrated.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try ReviewEntryStore.entries(project: "p", in: db),
             try AuthorDirectoryStore.authors(project: "p", in: db),
             try AutomationProposalStore.proposals(project: "p", in: db))
        }
        #expect(version == ProjectSchema.currentVersion)  // 17 when written; v18 (layers) follows
        let extraColumns = try await migrated.read { db in try db.columns(in: "markup_extra").map(\.name) }
        #expect(extraColumns.contains("capture_json"), "v17 adds the capture column (ADR-0031)")
        #expect(replies.map(\.body) == ["Check the door width"])
        #expect(authors.isEmpty && proposals.isEmpty, "nothing is backfilled")

        // The directory keeps first_seen and refreshes the rest.
        try await migrated.write { db in
            try AuthorDirectoryStore.upsert(AuthorRecord(id: "a1", projectId: "p", displayName: "Ada", initials: "A",
                                                         company: "North Build", firstSeen: "2026-02-01T00:00:00.000Z",
                                                         lastSeen: "2026-02-01T00:00:00.000Z"), in: db)
            try AuthorDirectoryStore.upsert(AuthorRecord(id: "a1", projectId: "p", displayName: "Ada L.", initials: "AL",
                                                         company: "North Build AB", firstSeen: "2026-03-01T00:00:00.000Z",
                                                         lastSeen: "2026-03-01T00:00:00.000Z"), in: db)
            try AutomationProposalStore.insert([
                AutomationProposalRecord(id: "x1", projectId: "p", pageId: "page-1", kind: "sheetName",
                                         payloadJson: #"{"number":"A-101"}"#, createdAt: "2026-03-01T00:00:00.000Z"),
                AutomationProposalRecord(id: "x2", projectId: "p", pageId: "page-1", kind: "scale",
                                         payloadJson: #"{"ratio":50}"#, createdAt: "2026-03-01T00:00:01.000Z"),
            ], in: db)
            try AutomationProposalStore.setState(id: "x1", state: .rejected, decidedAt: "2026-03-02T00:00:00.000Z", in: db)
            try AutomationProposalStore.removeOpen(project: "p", page: "page-1", in: db)
        }
        let (after, inbox) = try await migrated.read { db in
            (try AuthorDirectoryStore.authors(project: "p", in: db), try AutomationProposalStore.proposals(project: "p", in: db))
        }
        #expect(after.count == 1)
        #expect(after.first?.displayName == "Ada L.")
        #expect(after.first?.company == "North Build AB")
        #expect(after.first?.firstSeen == "2026-02-01T00:00:00.000Z", "first_seen never moves")
        #expect(inbox.map(\.id) == ["x1"], "a rerun clears open proposals and keeps the rejected one")
        #expect(inbox.first?.state == "rejected")
        try await migrated.close()
    }
}
