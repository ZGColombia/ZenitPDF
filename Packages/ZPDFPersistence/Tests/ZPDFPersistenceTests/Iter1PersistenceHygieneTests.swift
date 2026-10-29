import CryptoKit
import Foundation
import GRDB
import Testing
import ZPDFSpreadsheet
import ZPDFPersistence

/// The snapshot list reads no bodies (R-191), Send
/// Project writes the one shared stored-zip format (R-212), and an unsaved page's identity is
/// derived, not minted (K-03), and a read-only open of an older project reads a migrated
/// private copy (R-197).
@Suite("Iteration 1 — persistence hygiene")
struct Iter1PersistenceHygieneTests {

    @Test("R-191: listing snapshots returns every summary field and no body")
    func snapshotListCarriesNoBodies() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("Iter1SnapshotList")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("project.sqlite"))
        // A 2 MB body: what the old query decoded for every snapshot, only to list names.
        let body = "{\"rows\":[" + String(repeating: "1,", count: 1_048_576) + "1]}"
        try await database.write { db in
            try LedgerSnapshotStore.insert(LedgerSnapshotRecord(
                id: "a", projectId: "p", name: "Bid 1", createdAt: "2026-09-01T00:00:00.000Z",
                author: "E", rowCount: 3, bodyJson: body
            ), in: db)
            try LedgerSnapshotStore.insert(LedgerSnapshotRecord(
                id: "b", projectId: "p", name: "Bid 2", createdAt: "2026-09-10T00:00:00.000Z",
                author: "F", rowCount: 4, bodyJson: body
            ), in: db)
        }
        let listed = try await database.read { db in try LedgerSnapshotStore.list(project: "p", in: db) }
        #expect(listed.map(\.id) == ["b", "a"])
        #expect(listed.map(\.name) == ["Bid 2", "Bid 1"])
        #expect(listed.map(\.author) == ["F", "E"])
        #expect(listed.map(\.rowCount) == [4, 3])
        #expect(listed.map(\.projectId) == ["p", "p"])
        // Old output: two 2 097 163-character bodies.
        #expect(listed.allSatisfy { $0.bodyJson.isEmpty })
        let one = try await database.read { db in try LedgerSnapshotStore.snapshot(id: "a", project: "p", in: db) }
        #expect(one?.bodyJson == body, "the single-snapshot read still carries its body")
        try await database.close()
    }

    @Test("R-212: the Send Project zip reads back through the shared reader, CRC-checked, member for member")
    func sendArchiveReadsBackThroughTheSharedReader() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1SendZip")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        _ = try await package.save()
        let archive = workspace.root.appendingPathComponent("Project.zip")
        let written = try await package.writeSendArchive(to: archive, packageName: "Project.zpdfproj")
        try await package.close()

        let reader = try ZipArchiveReader(data: try Data(contentsOf: archive))
        let latest = workspace.packageURL.member(ProjectPackageLayout.versions)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
        for relative in written {
            let expected = try Data(contentsOf: latest.appendingPathComponent(relative))
            #expect(try reader.contents(of: "Project.zpdfproj/\(relative)") == expected, "\(relative)")
        }
        // The package's standard directories travel as empty directory entries.
        #expect(reader.entry(named: "Project.zpdfproj/\(ProjectPackageLayout.recovery)/") != nil)
        #expect(!reader.entries.contains { $0.name.hasPrefix("Project.zpdfproj/versions/") && !$0.name.hasSuffix("/") })
    }

    @Test("K-03: a stable page id depends only on the document row and the index, and is a v8 UUID")
    func stablePageIdentity() {
        let a0 = StablePageIdentity.pageID(documentId: "doc-A", pageIndex: 0)
        #expect(a0 == StablePageIdentity.pageID(documentId: "doc-A", pageIndex: 0), "same inputs, same id, every call")
        #expect(a0 != StablePageIdentity.pageID(documentId: "doc-A", pageIndex: 1))
        #expect(a0 != StablePageIdentity.pageID(documentId: "doc-B", pageIndex: 0))
        // "doc-A1" + index 0 must not collide with "doc-A" + index 10: the fields are separated.
        #expect(StablePageIdentity.pageID(documentId: "doc-A1", pageIndex: 0)
                != StablePageIdentity.pageID(documentId: "doc-A", pageIndex: 10))
        let bytes = a0.uuid
        #expect(bytes.6 >> 4 == 0x8, "RFC 9562 version 8")
        #expect(bytes.8 >> 6 == 0b10, "RFC 9562 variant")
        let many = Set((0..<2_000).map { StablePageIdentity.pageID(documentId: "doc-A", pageIndex: $0) })
        #expect(many.count == 2_000)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("R-197: a read-only open of a project last written before v9 reads a migrated copy; the package is untouched")
    func readOnlyOpenMigratesAPrivateCopy() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1ReadOnlyOld")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let created = try await TestSupport.createPackage(workspace)
        try await created.close()

        // The package's database, as a build before per-page scale (v9) wrote it: one page,
        // one scale parked on it, and the takeoff state naming it the document default.
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        try FileManager.default.removeItem(at: databaseURL)
        let queue = try DatabaseQueue(path: databaseURL.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v8-artwork-geometry")
        let stamp = "2026-08-01T00:00:00.000Z"
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO project (id, name, created_at, modified_at, schema_version) VALUES ('p', 'Old', ?, ?, 8)",
                           arguments: [stamp, stamp])
            try db.execute(sql: """
                INSERT INTO document (id, project_id, display_name, relative_path, sha256, page_count, created_at, modified_at)
                VALUES ('d', 'p', 'Set', 'documents/original.pdf', 'sha', 1, ?, ?)
                """, arguments: [stamp, stamp])
            try db.execute(sql: """
                INSERT INTO page (id, document_id, page_index, page_label, media_x, media_y, media_width, media_height,
                                  crop_x, crop_y, crop_width, crop_height, rotation)
                VALUES ('pg', 'd', 0, 'A-101', 0, 0, 612, 792, 0, 0, 612, 792, 0)
                """)
            try db.execute(sql: """
                INSERT INTO scale_definition (id, page_id, name, matrix_a, matrix_b, matrix_c, matrix_d, translation_x,
                    translation_y, base_length_unit, source_type, precision_mode, version, created_at, modified_at)
                VALUES ('s', 'pg', '1:50', '0.01', '0', '0', '0.01', '0', '0', 'metre', 'calibrationTwoPoint',
                        'decimalPlaces:3', 1, ?, ?)
                """, arguments: [stamp, stamp])
            try db.execute(sql: "INSERT INTO takeoff_state (document_id, default_scale_id, saved_at) VALUES ('d', 's', ?)",
                           arguments: [stamp])
        }
        try queue.close()
        let before = try sha256(databaseURL)
        let membersBefore = try FileManager.default.contentsOfDirectory(atPath: workspace.packageURL.path).sorted()

        let readOnly = try await ProjectPackage.open(at: workspace.packageURL, resolving: .openReadOnly)
        let seen = try await readOnly.read { db in
            (
                pageScale: try db.tableExists("page_scale"),
                stamp: try db.tableExists("markup_stamp"),
                snapshots: try db.tableExists("ledger_snapshot"),
                backfilled: try String.fetchOne(db, sql: "SELECT scale_id FROM page_scale WHERE page_id = 'pg'"),
                version: try Int.fetchOne(db, sql: "PRAGMA user_version")
            )
        }
        try await readOnly.close()

        // Old output: false, false, false and user_version 8 — the read-only handle read the
        // unmigrated file, and the takeoff reader failed on "no such table: page_scale".
        #expect(seen.pageScale && seen.stamp && seen.snapshots)
        #expect(seen.backfilled == "s", "the v9 reading: the document default belongs to page one")
        #expect(seen.version == ProjectSchema.currentVersion)
        #expect(try sha256(databaseURL) == before, "the package's own database is not touched by a byte")
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.packageURL.path).sorted() == membersBefore,
                "no sidecar or scratch copy is left in the package")
    }
}
