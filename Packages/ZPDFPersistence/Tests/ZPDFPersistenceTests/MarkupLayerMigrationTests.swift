import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v18 (ADR-0032): markup layers, the markup's layer column and project
/// settings. An old project opens, migrates, keeps every markup where it was — on the default
/// layer, which the migration creates — and the new tables round-trip.
@Suite("Markup layers v18")
struct MarkupLayerMigrationTests {

    /// A project database exactly as a v17 build left it: one project, one page, one markup.
    private func makeV17Database(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("project.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v17-automation-proposal-and-capture")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO project (id, name, created_at, modified_at, schema_version)
                VALUES ('p', 'P', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 17)
                """)
            try db.execute(sql: """
                INSERT INTO document (id, project_id, display_name, relative_path, sha256, page_count,
                    created_at, modified_at)
                VALUES ('d', 'p', 'Plan', 'documents/original.pdf', 'abc', 1,
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """)
            try db.execute(sql: """
                INSERT INTO page (id, document_id, page_index, media_x, media_y, media_width, media_height,
                    crop_x, crop_y, crop_width, crop_height, rotation)
                VALUES ('pg', 'd', 0, 0, 0, 612, 792, 0, 0, 612, 792, 0)
                """)
            try db.execute(sql: """
                INSERT INTO markup (id, document_id, page_id, type, subject, geometry_blob, style_blob,
                    created_at, modified_at, revision)
                VALUES ('m1', 'd', 'pg', 'polyline', 'Wall', x'00', x'7B7D',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 1)
                """)
            try db.execute(sql: """
                INSERT INTO markup_extra (markup_id, kind, sort_order, printable)
                VALUES ('m1', 'measurement', 0, 1)
                """)
            #expect(try !db.tableExists("markup_layer"), "precondition: a genuine v17 database")
            #expect(try !db.tableExists("project_setting"))
        }
        try queue.close()
        return url
    }

    @Test("A v17 project migrates with its markup on the default layer and no schema deviation")
    func oldProjectMigrates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkupLayerMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV17Database(in: directory)

        // The guard runs before the migrator: the v17 spelling of markup_extra is still ours.
        let readOnly = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        #expect(readOnly.schemaDeviations.isEmpty)
        try await readOnly.close()

        let migrated = try await ProjectDatabaseActor.open(at: url)
        #expect(migrated.schemaDeviations.isEmpty)
        let (version, layers, extras, units) = try await migrated.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try MarkupLayerStore.layers(project: "p", in: db),
             try MarkupExtraRecord.fetchAll(db),
             try MarkupLayerStore.setting("display_units", project: "p", in: db))
        }
        #expect(version == ProjectSchema.currentVersion)  // 18 when written
        // Exactly one layer, the default one, under the contract's fixed identity.
        #expect(layers.count == 1)
        #expect(layers.first?.id == "5A1E0000-0000-4000-8000-00000000DEF0")
        #expect(layers.first?.id == ProjectSchema.defaultMarkupLayerID)
        #expect(layers.first?.name == "Default")
        #expect(layers.first?.sortOrder == 0)
        #expect(layers.first.map { $0.visible && !$0.locked && $0.printable } == true)
        // The markup was not rewritten: its layer is NULL, which is the default layer.
        #expect(extras.map(\.markupId) == ["m1"])
        #expect(extras.first?.layerId == nil)
        #expect(units == nil, "nothing is backfilled into the settings")
        let columns = try await migrated.read { db in try db.columns(in: "markup_extra").map(\.name) }
        #expect(columns.last == "layer_id")
        try await migrated.close()

        // Reopening the migrated file is clean too: the v18 spelling of markup_extra is ours.
        let reopened = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        #expect(reopened.schemaDeviations.isEmpty)
        try await reopened.close()
    }

    @Test("Layers, a markup's layer and settings round-trip; a removed layer's row goes")
    func storesRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkupLayerStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV17Database(in: directory)
        let database = try await ProjectDatabaseActor.open(at: url)

        try await database.write { db in
            try MarkupLayerStore.replace([
                MarkupLayerRecord(projectId: "p", id: ProjectSchema.defaultMarkupLayerID, name: "Base", sortOrder: 0),
                MarkupLayerRecord(projectId: "p", id: "walls", name: "Walls", sortOrder: 1, visible: false),
                MarkupLayerRecord(projectId: "p", id: "doors", name: "Doors", sortOrder: 2, locked: true, printable: false)
            ], project: "p", in: db)
            try db.execute(sql: "UPDATE markup_extra SET layer_id = 'walls' WHERE markup_id = 'm1'")
            try MarkupLayerStore.setSetting("display_units", json: #"{"length":"foot"}"#, project: "p", in: db)
        }
        var layers = try await database.read { db in try MarkupLayerStore.layers(project: "p", in: db) }
        #expect(layers.map(\.name) == ["Base", "Walls", "Doors"])
        #expect(layers.map(\.visible) == [true, false, true])
        #expect(layers.map(\.locked) == [false, false, true])
        #expect(layers.map(\.printable) == [true, true, false])

        try await database.write { db in
            try MarkupLayerStore.replace([
                MarkupLayerRecord(projectId: "p", id: ProjectSchema.defaultMarkupLayerID, name: "Base", sortOrder: 0),
                MarkupLayerRecord(projectId: "p", id: "doors", name: "Doors", sortOrder: 1)
            ], project: "p", in: db)
            try MarkupLayerStore.setSetting("display_units", json: #"{"length":"metre"}"#, project: "p", in: db)
        }
        let (after, extra, units) = try await database.read { db in
            (try MarkupLayerStore.layers(project: "p", in: db),
             try MarkupExtraRecord.fetchOne(db, key: "m1"),
             try MarkupLayerStore.setting("display_units", project: "p", in: db))
        }
        layers = after
        #expect(layers.map(\.id) == [ProjectSchema.defaultMarkupLayerID, "doors"])
        #expect(extra?.layerId == "walls", "the column is data; resolving a gone layer is the reader's repair")
        #expect(units == #"{"length":"metre"}"#)

        // A name no person types is refused before anything is written.
        await #expect(throws: ZPDFPersistenceError.self) {
            try await database.write { db in
                try MarkupLayerStore.replace([
                    MarkupLayerRecord(projectId: "p", id: "x", name: String(repeating: "a", count: 2000), sortOrder: 0)
                ], project: "p", in: db)
            }
        }
        try await database.close()
    }
}
