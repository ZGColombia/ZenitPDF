import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v13 (ADR-0022 (documents)): page set entries, document entries, persisted revisions.
@Suite("Document set, v13")
struct DocumentSetMigrationTests {

    /// A project database exactly as a v12 build left it.
    private func makeV12Database(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("project.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v12-review-entries")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO project (id, name, created_at, modified_at, schema_version)
                VALUES ('p', 'P', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 12)
                """)
            #expect(try !db.tableExists("page_set_entry"), "precondition: a genuine v12 database")
        }
        try queue.close()
        return url
    }

    @Test("A v12 project migrates to v13 with empty document-set tables and opens clean")
    func oldProjectMigrates() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("V13OldSchema")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV12Database(in: directory)

        let readOnly = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        #expect(readOnly.schemaDeviations.isEmpty)
        try await readOnly.close()

        let migrated = try await ProjectDatabaseActor.open(at: url)
        let (version, tables) = try await migrated.read { db in
            (
                try Int.fetchOne(db, sql: "PRAGMA user_version"),
                try ["page_set_entry", "document_set_entry", "revision_entry", "revision_sheet"].map { try db.tableExists($0) }
            )
        }
        #expect(version == ProjectSchema.currentVersion) // 13 when written; v14 (quantities snapshots) follows
        #expect(tables == [true, true, true, true])
        #expect(migrated.schemaDeviations.isEmpty)
        try await migrated.close()
    }

    @Test("Page entries round-trip and go with their page")
    func pageEntriesRoundTrip() async throws {
        let workspace = try TestSupport.makeWorkspace("V13Pages")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let a = try await TestSupport.insertPage(into: package, pageIndex: 0)
        let b = try await TestSupport.insertPage(into: package, pageIndex: 1)
        try await package.write { db in
            try PageSetEntryRecord(pageId: a, position: 1, sheetNumber: "A-102", sheetTitle: "ROOF", nameSource: "manual").insert(db)
            try PageSetEntryRecord(pageId: b, position: 0, viewRotation: 90, excluded: true).insert(db)
        }
        var entries = try await package.read { db in try DocumentSetStore.pageEntries(document: documentId, in: db) }
        #expect(entries[a]?.position == 1 && entries[a]?.sheetNumber == "A-102")
        #expect(entries[b]?.viewRotation == 90 && entries[b]?.excluded == true)

        try await package.write { db in try db.execute(sql: "DELETE FROM page WHERE id = ?", arguments: [b]) }
        entries = try await package.read { db in try DocumentSetStore.pageEntries(document: documentId, in: db) }
        #expect(entries.keys.sorted() == [a], "the entry cascades with its page")
        try await package.close()
    }

    /// Before v13 a dropped revision was not stored at all.
    @Test("A revision is copied read-only and hashed, keeps its pairings, and survives close and reopen")
    func revisionSurvivesReopen() async throws {
        let workspace = try TestSupport.makeWorkspace("V13Revision")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let page = try await TestSupport.insertPage(into: package, pageIndex: 0)
        let revisionPDF = try TestSupport.makeSourcePDF(in: workspace.root.appendingPathComponent("rev", isDirectory: true))
        let stored = try await package.addRevision(
            pdf: revisionPDF, documentId: documentId, label: "Rev B", pageCount: 1,
            sheets: [RevisionSheetRecord(revisionId: "", revisionPageIndex: 0, pageId: page, evidence: RevisionSheetRecord.Evidence.label.rawValue)]
        )
        let file = package.revisionFileURL(stored)
        #expect(file.path.contains("documents/revisions/"))
        #expect(!FileManager.default.isWritableFile(atPath: file.path), "read-only, like every drawing in the package")
        #expect(stored.sha256.count == 64)
        try await package.save()
        try await package.close()

        guard case let .opened(reopened) = try await ProjectPackage.open(at: workspace.packageURL) else {
            Issue.record("a cleanly closed package must open without a decision")
            return
        }
        let (revisions, sheets) = try await reopened.read { db in
            let revisions = try DocumentSetStore.revisions(document: documentId, in: db)
            return (revisions, try DocumentSetStore.sheets(revision: stored.id, in: db))
        }
        #expect(revisions.map(\.label) == ["Rev B"])
        #expect(sheets.map(\.pageId) == [page])
        #expect(sheets.first?.evidence == "label")
        #expect(FileManager.default.fileExists(atPath: reopened.revisionFileURL(revisions[0]).path), "the save carried the file forward")
        try await reopened.close()
    }
}
