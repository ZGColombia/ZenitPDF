import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// A shipped schema version, frozen as the SQL that build actually wrote.
///
/// There is one entry today. The point of writing the harness now is that adding the
/// second one is a paste of the v1 statements plus whatever v2 changed, and the forward
/// migration test then runs over both without a line of new test code.
struct HistoricalSchema {
    /// The migration identifiers that had been applied at this version.
    let appliedMigrations: [String]
    /// The `CREATE` statements that build emitted, verbatim.
    let statements: [String]
    /// Rows to insert, so the migration is tested against a database with content in it
    /// rather than an empty one.
    let seed: [String]

    static let all: [HistoricalSchema] = [
        version1, version2, version3, version4, version5, version6, version7
    ]

    /// Zenit PDF 1.0.0, `v1-core-schema`.
    static let version1 = HistoricalSchema(
        appliedMigrations: ["v1-core-schema"],
        statements: ProjectSchema.coreTableStatements
            + ProjectSchema.indexDefinitions.map(\.sql)
            + ["PRAGMA user_version = 1"],
        seed: [
            """
            INSERT INTO project (id, name, created_at, modified_at, schema_version)
            VALUES ('p1', 'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 1)
            """,
            """
            INSERT INTO document (id, project_id, display_name, relative_path, sha256,
                                  page_count, created_at, modified_at)
            VALUES ('d1', 'p1', 'Plan.pdf', 'documents/original.pdf',
                    '0000000000000000000000000000000000000000000000000000000000000000',
                    1, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        ]
    )

    /// ADR-0007, `v2-measurement-audit`: v1 plus the append-only audit trail.
    static let version2 = HistoricalSchema(
        appliedMigrations: ["v1-core-schema", "v2-measurement-audit"],
        statements: ProjectSchema.coreTableStatements
            + ProjectSchema.indexDefinitions.map(\.sql)
            + [ProjectSchema.auditTableStatement]
            + ProjectSchema.auditTriggerStatements
            + ProjectSchema.auditIndexDefinitions.map(\.sql)
            + ["PRAGMA user_version = 2"],
        seed: version1.seed.map {
            $0.replacingOccurrences(of: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 1",
                                    with: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 2")
        }
    )

    /// `v3-layer-overrides`: v2 plus the per-project layer override table.
    static let version3 = HistoricalSchema(
        appliedMigrations: ["v1-core-schema", "v2-measurement-audit", "v3-layer-overrides"],
        statements: version2.statements.filter { $0 != "PRAGMA user_version = 2" }
            + [ProjectSchema.layerOverrideTableStatement]
            + ProjectSchema.layerOverrideIndexDefinitions.map(\.sql)
            + ["PRAGMA user_version = 3"],
        seed: version1.seed.map {
            $0.replacingOccurrences(of: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 1",
                                    with: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 3")
        } + [
            """
            INSERT INTO layer_override (project_id, document_id, layer_id, visible, locked)
            VALUES ('p1', 'd1', 'ocg:2', 1, NULL)
            """
        ]
    )
    /// ADR-0007 §4 hardening, `v4-audit-unique-markup-sequence`: v3 with the plain
    /// `(markup_id, sequence)` index replaced by a UNIQUE one.
    static let version4 = HistoricalSchema(
        appliedMigrations: [
            "v1-core-schema", "v2-measurement-audit", "v3-layer-overrides",
            "v4-audit-unique-markup-sequence"
        ],
        statements: version3.statements
            .filter {
                $0 != "PRAGMA user_version = 3"
                    && !$0.contains("idx_measurement_audit_markup_sequence")
            }
            + [ProjectSchema.auditUniqueMarkupSequenceIndex.sql]
            + ["PRAGMA user_version = 4"],
        seed: version3.seed.map {
            $0.replacingOccurrences(of: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 3",
                                    with: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 4")
        }
    )
    /// ADR-0009, `v5-takeoff-hydration`: v4 plus the takeoff companion tables.
    static let version5 = HistoricalSchema(
        appliedMigrations: [
            "v1-core-schema", "v2-measurement-audit", "v3-layer-overrides",
            "v4-audit-unique-markup-sequence", "v5-takeoff-hydration"
        ],
        statements: version4.statements.filter { $0 != "PRAGMA user_version = 4" }
            + ProjectSchema.takeoffHydrationTableStatements
            + ProjectSchema.takeoffHydrationIndexDefinitions.map(\.sql)
            + ["PRAGMA user_version = 5"],
        seed: version4.seed.map {
            $0.replacingOccurrences(of: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 4",
                                    with: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 5")
        } + [
            """
            INSERT INTO takeoff_state (document_id, default_scale_id, saved_at)
            VALUES ('d1', NULL, '2026-01-01T00:00:00.000Z')
            """
        ]
    )

    /// `v6-project-structure`: v5 plus the Scale Region and Project Zone companions.
    ///
    /// Written with v8, not with the change that shipped v6. Until now `all` stopped at
    /// version 5, so "every historical version migrates forward" was a claim about the first
    /// five of seven. It is now a claim about all of them.
    static let version6 = HistoricalSchema(
        appliedMigrations: version5.appliedMigrations + ["v6-project-structure"],
        statements: version5.statements.filter { $0 != "PRAGMA user_version = 5" }
            + ProjectSchema.projectStructureTableStatements
            + ProjectSchema.projectStructureIndexDefinitions.map(\.sql)
            + ["PRAGMA user_version = 6"],
        seed: version5.seed.map {
            $0.replacingOccurrences(of: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 5",
                                    with: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 6")
        }
    )

    /// ADR-0010, `v7-stamps`: v6 plus the placed-stamp and artwork tables — the schema this
    /// build's v8 migration has to carry forward, with a stamp and an artwork row already in it.
    static let version7 = HistoricalSchema(
        appliedMigrations: version6.appliedMigrations + ["v7-stamps"],
        statements: version6.statements.filter { $0 != "PRAGMA user_version = 6" }
            + ProjectSchema.stampTableStatements
            + ProjectSchema.stampIndexDefinitions.map(\.sql)
            + ["PRAGMA user_version = 7"],
        seed: version6.seed.map {
            $0.replacingOccurrences(of: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 6",
                                    with: "'Historic', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 7")
        } + [
            """
            INSERT INTO page (id, document_id, page_index, page_label,
                              media_x, media_y, media_width, media_height,
                              crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
            VALUES ('pg1', 'd1', 0, 'A-101', 0, 0, 612, 792, 0, 0, 612, 792, 0, 'hash')
            """,
            """
            INSERT INTO markup (id, document_id, page_id, type, subject, label, comment,
                                geometry_blob, style_blob, status, author, locked, hidden,
                                created_at, modified_at, revision)
            VALUES ('m1', 'd1', 'pg1', 'stamp', 'Approved', '', '',
                    X'00', X'00', 'none', 'Estimator', 0, 0,
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 1)
            """,
            """
            INSERT INTO markup_stamp (markup_id, template_id, template_name, template_revision,
                                      artwork_digest, artwork_kind, width_points, height_points,
                                      rotation_degrees, fields_json, resolved_at)
            VALUES ('m1', 't1', 'Approved', 1, 'abc123', 'vector', 160, 80, 0, '[]',
                    '2026-01-01T00:00:00.000Z')
            """,
            """
            INSERT INTO stamp_artwork (digest, kind, data, byte_count, source_name,
                                       source_page_index, pixel_width, pixel_height)
            VALUES ('abc123', 'vector', X'255044462D', 5, 'seal.pdf', 0, NULL, NULL)
            """
        ]
    )
}

struct MigrationHarnessTests {

    /// Builds a database exactly as the given historical build would have left it,
    /// including the `grdb_migrations` bookkeeping.
    private func buildHistorical(_ schema: HistoricalSchema, at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            for statement in schema.statements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in schema.appliedMigrations {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            for statement in schema.seed {
                try db.execute(sql: statement)
            }
        }
        try queue.close()
    }

    private func schemaFingerprint(_ database: ProjectDatabaseActor) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT type || ' ' || name || ' :: ' || COALESCE(sql, '')
                FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'
                ORDER BY type, name
                """)
        }
    }

    @Test("Every historical version migrates forward to the current schema")
    func forwardMigrationFromEveryShippedVersion() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("Migrate")
        defer { try? FileManager.default.removeItem(at: directory) }

        // The reference: a database this build created from nothing.
        let referenceURL = directory.appendingPathComponent("reference.sqlite")
        let reference = try await ProjectDatabaseActor.open(at: referenceURL)
        let referenceFingerprint = try await schemaFingerprint(reference)
        try await reference.close()
        #expect(!referenceFingerprint.isEmpty)

        for (index, historical) in HistoricalSchema.all.enumerated() {
            let url = directory.appendingPathComponent("historical-\(index).sqlite")
            try buildHistorical(historical, at: url)

            let migrated = try await ProjectDatabaseActor.open(at: url)
            #expect(try await schemaFingerprint(migrated) == referenceFingerprint,
                    "version \(index + 1) did not migrate to the current schema")
            #expect(try await migrated.appliedMigrationCount() == ProjectSchema.identifiers.count)
            // The rows that were there before the migration are still there after it.
            let projectName = try await migrated.read { db in
                try String.fetchOne(db, sql: "SELECT name FROM project WHERE id = 'p1'")
            }
            #expect(projectName == "Historic")
            try await migrated.integrityCheck()
            try await migrated.close()
        }
    }

    @Test("A database migrated by a newer build is refused, and left untouched")
    func futureDatabaseIsRefused() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("MigrateFuture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("project.sqlite")

        let database = try await ProjectDatabaseActor.open(at: url)
        try await database.close()

        // A build from the future added a migration we have never heard of.
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v3-cost-codes')")
        }
        try queue.close()
        let bytesBefore = try Data(contentsOf: url)

        await #expect(throws: ZPDFPersistenceError.databaseSchemaTooNew(
            found: "v3-cost-codes", supported: ProjectSchema.currentVersion
        )) {
            _ = try await ProjectDatabaseActor.open(at: url)
        }
        #expect(try Data(contentsOf: url) == bytesBefore, "the refused file was modified")
    }

    @Test("A package whose manifest declares a newer schema is refused")
    func futurePackageIsRefused() async throws {
        let workspace = try TestSupport.makeWorkspace("MigratePackage")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        try await package.save()
        try await package.close()

        let manifestURL = workspace.packageURL.member(ProjectPackageLayout.manifest)
        var manifest = try ProjectManifest.read(from: manifestURL)
        manifest.schemaVersion = 99
        try Data(manifest.encoded()).write(to: manifestURL)
        let databaseBefore = try Data(
            contentsOf: workspace.packageURL.member(ProjectPackageLayout.database)
        )

        await #expect(throws: ZPDFPersistenceError.packageSchemaTooNew(found: 99, supported: 1)) {
            _ = try await ProjectPackage.open(at: workspace.packageURL, resolving: .discard)
        }
        #expect(try Data(contentsOf: workspace.packageURL.member(ProjectPackageLayout.database))
            == databaseBefore, "the refused package's database was modified")
    }

    @Test("The manifest records the schema version this build wrote")
    func manifestRecordsSchemaVersion() async throws {
        let workspace = try TestSupport.makeWorkspace("MigrateManifest")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let manifest = await package.manifest
        #expect(manifest.schemaVersion == ProjectManifest.currentSchemaVersion)
        #expect(manifest.databaseSchema == ProjectSchema.currentVersion)
        #expect(manifest.coordinateSystem == "PDF_POINTS_BOTTOM_LEFT")
        try await package.close()
    }
}
