import Foundation
import GRDB

extension ProjectSchema {

    /// v14 (NL-QTY-16): one named snapshot of the takeoff's quantities. The body is the
    /// application's own JSON — the persistence layer stores it and does not interpret it.
    public static let ledgerSnapshotTableStatement = """
        CREATE TABLE ledger_snapshot (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            author TEXT NOT NULL,
            row_count INTEGER NOT NULL,
            body_json TEXT NOT NULL
        )
        """

    public static let ledgerSnapshotIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_ledger_snapshot_project",
            sql: "CREATE INDEX idx_ledger_snapshot_project ON ledger_snapshot(project_id, created_at)",
            rationale: "The snapshot list reads a project's snapshots newest first."
        )
    ]

    static func createLedgerSnapshotTable(_ db: Database) throws {
        try db.execute(sql: ledgerSnapshotTableStatement)
        for definition in ledgerSnapshotIndexDefinitions { try db.execute(sql: definition.sql) }
    }
}

/// One stored snapshot row.
public struct LedgerSnapshotRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ledger_snapshot"

    public var id: String
    public var projectId: String
    public var name: String
    public var createdAt: String
    public var author: String
    public var rowCount: Int
    public var bodyJson: String

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case projectId = "project_id"
        case name
        case createdAt = "created_at"
        case author
        case rowCount = "row_count"
        case bodyJson = "body_json"
    }

    public init(id: String, projectId: String, name: String, createdAt: String, author: String, rowCount: Int, bodyJson: String) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.createdAt = createdAt
        self.author = author
        self.rowCount = rowCount
        self.bodyJson = bodyJson
    }
}

/// Read and write API for takeoff snapshots (schema v14, NL-QTY-16).
public enum LedgerSnapshotStore {

    /// The largest body stored: a 100 000-row takeoff's quantities in JSON fit well inside it.
    public static let maximumBodyByteCount = 64 * 1024 * 1024

    /// Stores a snapshot. A body past the bound is refused, not truncated.
    public static func insert(_ record: LedgerSnapshotRecord, in db: Database) throws {
        guard record.bodyJson.utf8.count <= maximumBodyByteCount else {
            throw ZPDFPersistenceError.packageMalformed(reason: "ledger snapshot body is larger than \(maximumBodyByteCount) bytes")
        }
        try record.insert(db)
    }

    /// A project's snapshots, newest first, without their bodies: every record's
    /// ``LedgerSnapshotRecord/bodyJson`` is empty. ``snapshot(id:project:in:)`` is the one
    /// reader of a body.
    ///
    /// The body column is never selected (R-191). The old query fetched every column, so
    /// listing names for a menu decoded every stored takeoff body — up to
    /// ``maximumBodyByteCount`` each — only to drop them.
    public static func list(project projectId: String, in db: Database) throws -> [LedgerSnapshotRecord] {
        try LedgerSnapshotRecord
            .select(sql: "id, project_id, name, created_at, author, row_count, '' AS body_json")
            .filter(LedgerSnapshotRecord.CodingKeys.projectId == projectId)
            .order(LedgerSnapshotRecord.CodingKeys.createdAt.desc, LedgerSnapshotRecord.CodingKeys.id)
            .fetchAll(db)
    }

    /// One snapshot with its body.
    public static func snapshot(id: String, project projectId: String, in db: Database) throws -> LedgerSnapshotRecord? {
        try LedgerSnapshotRecord
            .filter(LedgerSnapshotRecord.CodingKeys.projectId == projectId)
            .filter(LedgerSnapshotRecord.CodingKeys.id == id)
            .fetchOne(db)
    }

    /// Deletes a snapshot.
    @discardableResult
    public static func delete(id: String, project projectId: String, in db: Database) throws -> Bool {
        try LedgerSnapshotRecord
            .filter(LedgerSnapshotRecord.CodingKeys.projectId == projectId)
            .filter(LedgerSnapshotRecord.CodingKeys.id == id)
            .deleteAll(db) > 0
    }
}
