import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// ADR-0011's storage half: artwork lives once per project, addressed by content; a markup and
/// a preset each hold a **reference** to it; and `tool_preset.symbol_data` is finally written
/// and read after being in the schema, unused, since v1.
struct ArtworkPersistenceTests {

    private func openMigrated(_ label: String) async throws -> (ProjectDatabaseActor, URL) {
        let directory = try TestSupport.makeTemporaryDirectory(label)
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite")
        )
        return (database, directory)
    }

    private func seedMarkup(_ database: ProjectDatabaseActor, id: String = "m1") async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO project (id, name, created_at, modified_at, schema_version)
                VALUES ('p1', 'Artwork', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 8)
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO document (id, project_id, display_name, relative_path, sha256,
                                      page_count, created_at, modified_at)
                VALUES ('d1', 'p1', 'Plan.pdf', 'documents/original.pdf',
                        '0000000000000000000000000000000000000000000000000000000000000000',
                        1, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO page (id, document_id, page_index, page_label,
                                  media_x, media_y, media_width, media_height,
                                  crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
                VALUES ('pg1', 'd1', 0, 'A-101', 0, 0, 612, 792, 0, 0, 612, 792, 0, 'hash')
                """)
            try db.execute(sql: """
                INSERT INTO markup (id, document_id, page_id, type, subject, label, comment,
                                    geometry_blob, style_blob, status, author, locked, hidden,
                                    created_at, modified_at, revision)
                VALUES (?, 'd1', 'pg1', 'count', 'Sockets', '', '',
                        X'00', X'00', 'none', 'Estimator', 0, 0,
                        '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 1)
                """, arguments: [id])
        }
    }

    // MARK: - Artwork is stored once, compiled, and addressed by content

    @Test("Artwork stores its bytes, its compiled geometry and the compiler that made it")
    func artworkStoresBytesAndGeometry() async throws {
        let (database, directory) = try await openMigrated("Artwork")
        defer { try? FileManager.default.removeItem(at: directory) }

        let geometry = #"{"kind":"vector","strokes":[],"regions":[],"compilerVersion":1}"#
        let record = StampArtworkRecord(
            digest: String(repeating: "a", count: 64),
            kind: "vector",
            data: Data("%PDF-1.4 seal".utf8),
            sourceName: "seal.pdf",
            sourcePageIndex: 0,
            geometryJson: geometry,
            compilerVersion: 1
        )
        try await database.write { db in try record.insert(db) }

        let read = try await database.read { db in
            try StampArtworkRecord.fetchOne(db, key: record.digest)
        }
        let stored = try #require(read)
        #expect(stored.geometryJson == geometry)
        #expect(stored.compilerVersion == 1)
        #expect(stored.byteCount == record.data.count)
        #expect(stored.geometryFitsSchemaLimit)
        try await database.close()
    }

    @Test("Three hundred and twelve stamps of one seal are one artwork row")
    func artworkIsStoredOncePerDigest() async throws {
        let (database, directory) = try await openMigrated("ArtworkShared")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seedMarkup(database)

        let digest = String(repeating: "b", count: 64)
        try await database.write { db in
            try StampArtworkRecord(
                digest: digest, kind: "vector", data: Data(repeating: 7, count: 4096),
                geometryJson: "{}", compilerVersion: 1
            ).insert(db)
            // A second import of the same file is the same row, not a second copy. This is the
            // property that keeps a 4 MB seal from becoming a 1.2 GB project.
            try StampArtworkRecord(
                digest: digest, kind: "vector", data: Data(repeating: 7, count: 4096),
                geometryJson: "{}", compilerVersion: 1
            ).upsert(db)
        }
        let count = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stamp_artwork") ?? -1
        }
        #expect(count == 1)
        try await database.close()
    }

    @Test("Deleting the last markup that referenced artwork does not delete the artwork")
    func artworkOutlivesItsMarks() async throws {
        let (database, directory) = try await openMigrated("ArtworkOutlives")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seedMarkup(database)

        let digest = String(repeating: "c", count: 64)
        try await database.write { db in
            try StampArtworkRecord(digest: digest, kind: "raster", data: Data([1, 2, 3])).insert(db)
            try MarkupSymbolRecord(
                markupId: "m1", artworkDigest: digest, artworkKind: "raster", sizePoints: 14
            ).insert(db)
            // Undoing the mark must not take the picture with it: the preset still points at
            // it, and a redo has to find it there.
            try db.execute(sql: "DELETE FROM markup WHERE id = 'm1'")
        }
        let symbols = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup_symbol") ?? -1
        }
        let artwork = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stamp_artwork") ?? -1
        }
        #expect(symbols == 0, "the symbol row should cascade with its markup")
        #expect(artwork == 1, "the artwork should not")
        try await database.close()
    }

    @Test("A compiled-geometry document larger than the schema's own bound is refused")
    func oversizedGeometryIsRefused() {
        let huge = String(repeating: "x", count: ProjectSchema.maximumArtworkGeometryBytes + 1)
        let record = StampArtworkRecord(
            digest: String(repeating: "d", count: 64), kind: "vector",
            data: Data([0]), geometryJson: huge
        )
        #expect(record.geometryFitsSchemaLimit == false)
        var small = record
        small.geometryJson = "{}"
        #expect(small.geometryFitsSchemaLimit)
    }

    // MARK: - A markup's symbol

    @Test("A count mark's symbol round-trips, digest and glyph alike")
    func symbolRoundTrips() async throws {
        let (database, directory) = try await openMigrated("Symbol")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seedMarkup(database)
        try await seedMarkup(database, id: "m2")

        let imported = MarkupSymbolRecord(
            markupId: "m1",
            artworkDigest: String(repeating: "e", count: 64),
            artworkKind: "vector",
            sizePoints: 18,
            rotationDegrees: 45,
            sourceName: "socket.pdf"
        )
        let builtIn = MarkupSymbolRecord(
            markupId: "m2", artworkKind: "none", builtInGlyph: "cross", sizePoints: 12
        )
        try await database.write { db in
            try imported.insert(db)
            try builtIn.insert(db)
        }
        let rows = try await database.read { db in
            try MarkupSymbolRecord.order(Column("markup_id")).fetchAll(db)
        }
        #expect(rows == [imported, builtIn])
        // A glyph is stored by name. The renderer's raw values are a wire format for a GPU
        // buffer and a persisted mark must not be pinned to a byte in a shader.
        #expect(rows[1].builtInGlyph == "cross")
        #expect(rows[1].artworkDigest == nil)
        try await database.close()
    }
}

/// The v8 schema's own spelling, checked against a real migrated file.
struct ArtworkSchemaSpellingTests {

    @Test("stamp_artwork's stored SQL after v8 is exactly what the guard expects")
    func artworkColumnsMatchTheDeclaredV8Spelling() async throws {
        // `ALTER TABLE ADD COLUMN` edits a table's stored definition text rather than
        // re-emitting it, and `ProjectSchemaInventory` refuses to open a project whose stored
        // definition it does not recognise. So the declared v8 spelling has to be the one
        // SQLite actually produces — and if a toolchain ever changes that, this test is what
        // says so, rather than every project on the machine suddenly reading as hostile.
        let directory = try TestSupport.makeTemporaryDirectory("ArtworkSpelling")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite")
        )
        let stored = try await database.read { db in
            try String.fetchOne(
                db, sql: "SELECT sql FROM sqlite_master WHERE name = 'stamp_artwork'"
            ) ?? ""
        }
        #expect(
            ProjectSchemaInventory.normalized(stored)
                == ProjectSchemaInventory.normalized(ProjectSchema.stampArtworkTableStatementAfterV8)
        )
        let deviations = try await database.read { db in
            try ProjectSchemaInventory.deviations(in: db)
        }
        #expect(deviations.isEmpty, "a freshly migrated project must look like itself: \(deviations)")
        try await database.close()
    }
}
