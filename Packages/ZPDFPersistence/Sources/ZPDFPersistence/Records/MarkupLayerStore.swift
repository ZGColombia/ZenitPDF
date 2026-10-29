import Foundation
import GRDB

extension ProjectSchema {

    /// v18 (ADR-0032): a project's markup layers.
    ///
    /// One row per layer of a project: its name, its place in the list and the three flags a
    /// person sets on it. The default layer — the one every markup without a layer belongs to —
    /// is a row like any other, under a fixed identity the application knows; the migration
    /// inserts it for every project, so a v17 project opens with its markups on "Default".
    ///
    /// Primary key `(project_id, id)`: the default layer's identity is the same constant in every
    /// project, and a database holds one project, but the key does not rely on that.
    public static let markupLayerTableStatement = """
        CREATE TABLE markup_layer (
            project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            id TEXT NOT NULL,
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            visible INTEGER NOT NULL DEFAULT 1,
            locked INTEGER NOT NULL DEFAULT 0,
            printable INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (project_id, id)
        )
        """

    /// v18: project-level settings the application stores as JSON under a key — today the
    /// takeoff's display units and the active markup layer. Persistence stores the values and does
    /// not interpret them, so a later setting needs no migration of its own.
    public static let projectSettingTableStatement = """
        CREATE TABLE project_setting (
            project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            key TEXT NOT NULL,
            value_json TEXT NOT NULL,
            PRIMARY KEY (project_id, key)
        )
        """

    /// v18: the markup's layer on the v5 companion row. NULL is the default layer, which is what
    /// every markup written before v18 reads as — so nothing is backfilled.
    ///
    /// A plain column with no `REFERENCES` clause, on purpose: the layer list is written once per
    /// project while a multi-drawing project writes each drawing's markups in its own step, so a
    /// foreign key would fail a save that deletes a layer between the two. A layer id the list
    /// does not hold is read as the default layer — a repair, never a refusal.
    public static let markupLayerColumnStatement = "ALTER TABLE markup_extra ADD COLUMN layer_id TEXT"

    /// `markup_extra` as SQLite stores it after v18's `layer_id` column.
    public static let markupExtraTableStatementAfterV18 = """
        CREATE TABLE markup_extra (
            markup_id TEXT PRIMARY KEY NOT NULL REFERENCES markup(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            parent_markup_id TEXT REFERENCES markup(id) ON DELETE CASCADE,
            count_group_id TEXT,
            caption TEXT,
            printable INTEGER NOT NULL DEFAULT 1,
            parameters_json TEXT,
            geometry_json TEXT,
            custom_values_json TEXT
        , provenance TEXT, derivation_json TEXT, capture_json TEXT, layer_id TEXT)
        """

    /// The default layer's identity, as the application's contract fixes it
    /// (`MarkupLayer.defaultID`). Repeated here because persistence does not import the contracts;
    /// `MarkupLayerMigrationTests` asserts the two agree.
    public static let defaultMarkupLayerID = "5A1E0000-0000-4000-8000-00000000DEF0"

    /// The default layer's name as the migration creates it.
    public static let defaultMarkupLayerName = "Default"

    static func createMarkupLayerTables(_ db: Database) throws {
        try db.execute(sql: markupLayerTableStatement)
        try db.execute(sql: projectSettingTableStatement)
        try db.execute(sql: markupLayerColumnStatement)
        // Every project gets its default layer, so an older project's markups — all of them
        // `layer_id` NULL — belong to a layer that exists the moment the file is opened.
        try db.execute(
            sql: """
                INSERT INTO markup_layer (project_id, id, name, sort_order, visible, locked, printable)
                SELECT id, ?, ?, 0, 1, 0, 1 FROM project
                """,
            arguments: [defaultMarkupLayerID, defaultMarkupLayerName]
        )
    }
}

/// One markup layer of a project (schema v18, ADR-0032).
public struct MarkupLayerRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "markup_layer"

    public var projectId: String
    public var id: String
    public var name: String
    public var sortOrder: Int
    public var visible: Bool
    public var locked: Bool
    public var printable: Bool

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case projectId = "project_id"
        case id
        case name
        case sortOrder = "sort_order"
        case visible
        case locked
        case printable
    }

    public init(
        projectId: String, id: String, name: String, sortOrder: Int,
        visible: Bool = true, locked: Bool = false, printable: Bool = true
    ) {
        self.projectId = projectId
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.visible = visible
        self.locked = locked
        self.printable = printable
    }
}

/// Reads and writes a project's markup layers and settings (schema v18). Pure database
/// functions, run inside the caller's transaction.
public enum MarkupLayerStore {

    /// The longest layer name kept, in UTF-8 bytes. A name is a word or two; a longer one in a
    /// file is somebody else's data and is refused rather than stored.
    public static let maximumNameByteCount = 1024

    /// The most layers a project may hold. Far above any real takeoff; a file claiming more is
    /// refused rather than drawn as ten thousand Navigator rows.
    public static let maximumLayerCount = 1000

    /// The project's layers, in list order. Empty for a database without the v18 table.
    public static func layers(project projectId: String, in db: Database) throws -> [MarkupLayerRecord] {
        guard try db.tableExists(MarkupLayerRecord.databaseTableName) else { return [] }
        return try MarkupLayerRecord
            .filter(MarkupLayerRecord.CodingKeys.projectId == projectId)
            .order(MarkupLayerRecord.CodingKeys.sortOrder, MarkupLayerRecord.CodingKeys.id)
            .limit(maximumLayerCount)
            .fetchAll(db)
    }

    /// Replaces the project's layer list with `records`, which must all name `projectId`.
    public static func replace(_ records: [MarkupLayerRecord], project projectId: String, in db: Database) throws {
        guard records.count <= maximumLayerCount else {
            throw ZPDFPersistenceError.packageMalformed(reason: "a project holds at most \(maximumLayerCount) markup layers")
        }
        for record in records {
            guard record.projectId == projectId else {
                throw ZPDFPersistenceError.packageMalformed(reason: "markup layer \(record.id) names another project")
            }
            guard record.name.utf8.count <= maximumNameByteCount else {
                throw ZPDFPersistenceError.packageMalformed(reason: "markup layer name is longer than \(maximumNameByteCount) bytes")
            }
        }
        let live = Set(records.map(\.id))
        let stored = try String.fetchAll(
            db, sql: "SELECT id FROM markup_layer WHERE project_id = ?", arguments: [projectId]
        )
        for id in stored where !live.contains(id) {
            try db.execute(sql: "DELETE FROM markup_layer WHERE project_id = ? AND id = ?", arguments: [projectId, id])
        }
        for record in records { try record.upsert(db) }
    }

    /// The largest setting value kept, in UTF-8 bytes.
    public static let maximumSettingByteCount = 64 * 1024

    /// One setting's stored JSON, or `nil` when the project has none (or predates v18).
    public static func setting(_ key: String, project projectId: String, in db: Database) throws -> String? {
        guard try db.tableExists("project_setting") else { return nil }
        return try String.fetchOne(
            db,
            sql: "SELECT value_json FROM project_setting WHERE project_id = ? AND key = ?",
            arguments: [projectId, key]
        )
    }

    /// Stores one setting's JSON, or removes it with `nil`.
    public static func setSetting(_ key: String, json: String?, project projectId: String, in db: Database) throws {
        guard let json else {
            try db.execute(sql: "DELETE FROM project_setting WHERE project_id = ? AND key = ?", arguments: [projectId, key])
            return
        }
        guard json.utf8.count <= maximumSettingByteCount else {
            throw ZPDFPersistenceError.packageMalformed(reason: "project setting \(key) is larger than \(maximumSettingByteCount) bytes")
        }
        try db.execute(
            sql: """
                INSERT INTO project_setting (project_id, key, value_json) VALUES (?, ?, ?)
                ON CONFLICT(project_id, key) DO UPDATE SET value_json = excluded.value_json
                """,
            arguments: [projectId, key, json]
        )
    }
}
