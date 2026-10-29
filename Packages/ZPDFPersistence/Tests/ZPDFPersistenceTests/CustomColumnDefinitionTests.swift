import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v11 (BH-075): `custom_column.definition_json` and ``CustomColumnStore``.
@Suite("Custom column definitions, v11")
struct CustomColumnDefinitionTests {

    /// Stands in for the application's column definition: the persistence layer only sees Codable.
    struct Definition: Codable, Sendable, Hashable {
        var key: String
        var precision: Int
        var displayUnit: String
        var editable: Bool
    }

    private let seedSQL = [
        """
        INSERT INTO project (id, name, created_at, modified_at, schema_version)
        VALUES ('p', 'P', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 10)
        """,
        """
        INSERT INTO custom_column (id, project_id, name, type, sort_order, visible)
        VALUES ('c-old', 'p', 'Cost code', 'text', 0, 1)
        """
    ]

    /// A project database exactly as a v10 build left it: migrated to v10, one column row.
    private func makeV10Database(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("project.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v10-quantity-provenance")
        try queue.write { db in
            for statement in seedSQL { try db.execute(sql: statement) }
            let columns = try db.columns(in: "custom_column").map(\.name)
            #expect(!columns.contains("definition_json"), "precondition: a genuine v10 table")
        }
        try queue.close()
        return url
    }

    @Test("An old-schema database opens read-only unmigrated, and migrates with its rows intact")
    func oldDatabaseKeepsWorking() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("V11OldSchema")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV10Database(in: directory)

        // Read-only, no migration: the schema guard accepts the v10 spelling, and the record
        // reads without the column it does not have.
        let readOnly = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        #expect(readOnly.schemaDeviations.isEmpty)
        let before = try await readOnly.read { db in try CustomColumnRecord.fetchAll(db) }
        #expect(before.map(\.id) == ["c-old"])
        #expect(before.first?.definitionJson == nil)
        try await readOnly.close()

        // Read-write: v11 applies, the row is unchanged, the new column is there and empty.
        let migrated = try await ProjectDatabaseActor.open(at: url)
        let (rows, userVersion, columns) = try await migrated.read { db in
            (
                try CustomColumnStore.columns(project: "p", as: Definition.self, in: db),
                try Int.fetchOne(db, sql: "PRAGMA user_version"),
                try db.columns(in: "custom_column").map(\.name)
            )
        }
        #expect(userVersion == ProjectSchema.currentVersion)
        #expect(columns.contains("definition_json"))
        #expect(rows.count == 1)
        #expect(rows.first?.name == "Cost code")
        #expect(rows.first?.definition == nil, "nothing is backfilled")
        #expect(migrated.schemaDeviations.isEmpty)
        try await migrated.close()
    }

    @Test("A definition round-trips; an upsert keeps the column's values; remove cascades")
    func definitionRoundTrips() async throws {
        let workspace = try TestSupport.makeWorkspace("V11RoundTrip")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let projectId = try await TestSupport.projectIdentifier(of: package)
        let area = Definition(key: "imported.netArea", precision: 3, displayUnit: "m²", editable: false)

        try await package.write { db in
            try CustomColumnStore.upsert(
                [CustomColumnStore.Column(id: "c1", name: "Net area", type: "number", sortOrder: 1, definition: area),
                 CustomColumnStore.Column<Definition>(id: "c0", name: "Code", type: "text", sortOrder: 0, definition: nil)],
                project: projectId, in: db
            )
        }
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let geometry = try TestSupport.sampleGeometry()
        try await package.write { db in
            try MarkupRecord(
                id: "m1", documentId: documentId, pageId: pageId, type: "area", subject: "Slab",
                geometryBlob: geometry, styleBlob: Data([1]),
                createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
            ).insert(db)
            try db.execute(sql: """
                INSERT INTO custom_value (markup_id, column_id, value_text) VALUES ('m1', 'c1', '12.5')
                """)
        }

        // Change the precision: the row is updated in place, its value survives.
        let sharper = Definition(key: area.key, precision: 4, displayUnit: area.displayUnit, editable: false)
        try await package.write { db in
            try CustomColumnStore.upsert(
                [CustomColumnStore.Column(id: "c1", name: "Net area", type: "number", sortOrder: 1, definition: sharper)],
                project: projectId, in: db
            )
        }
        let (columns, values) = try await package.read { db in
            (
                try CustomColumnStore.columns(project: projectId, as: Definition.self, in: db),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM custom_value WHERE column_id = 'c1'") ?? -1
            )
        }
        #expect(columns.map(\.id) == ["c0", "c1"])
        #expect(columns[1].definition == sharper)
        #expect(columns[0].definition == nil)
        #expect(values == 1)

        // It survives a save and a reopen.
        try await package.save()
        try await package.close()
        let reopened = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .discard
        )
        let afterReopen = try await reopened.read { db in
            try CustomColumnStore.columns(project: projectId, as: Definition.self, in: db)
        }
        #expect(afterReopen.first { $0.id == "c1" }?.definition == sharper)

        let removed = try await reopened.write { db in
            try CustomColumnStore.remove(ids: ["c1"], project: projectId, in: db)
        }
        #expect(removed == 1)
        let orphanValues = try await reopened.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM custom_value WHERE column_id = 'c1'") ?? -1
        }
        #expect(orphanValues == 0)
        try await reopened.close()
    }

    @Test("A definition that is not JSON is refused by save validation")
    func malformedDefinitionFailsValidation() async throws {
        let workspace = try TestSupport.makeWorkspace("V11Malformed")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let projectId = try await TestSupport.projectIdentifier(of: package)
        let issues = try await package.write { db in
            try CustomColumnRecord(
                id: "bad", projectId: projectId, name: "X", type: "text", sortOrder: 0,
                definitionJson: "not json"
            ).insert(db)
            return try DomainValidation.validate(db)
        }
        #expect(issues.contains { $0.code == "malformed-column-definition" })
        try await package.close()
    }
}
