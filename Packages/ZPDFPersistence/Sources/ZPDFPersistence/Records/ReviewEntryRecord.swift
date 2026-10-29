import Foundation
import GRDB

// MARK: - review_entry (schema v12, ADR-0021 (collaboration))

/// One entry in a markup's review thread (NL-COLLAB-01): a reply with its own author and
/// time. See ``ProjectSchema/reviewEntryTableStatement`` for why `markup_id` has no foreign key.
public struct ReviewEntryRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "review_entry"

    /// The entry kinds this build writes. Stored as text so a newer kind survives a round trip
    /// through an older reader untouched.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case reply
        case assignment
    }

    public var id: String
    public var projectId: String
    public var markupId: String
    public var parentEntryId: String?
    public var kind: String
    public var authorId: String?
    public var authorName: String
    public var body: String
    public var statusFrom: String?
    public var statusTo: String?
    public var createdAt: String
    public var editedAt: String?
    public var retracted: Bool
    public var origin: String?
    public var lamport: Int?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case projectId = "project_id"
        case markupId = "markup_id"
        case parentEntryId = "parent_entry_id"
        case kind
        case authorId = "author_id"
        case authorName = "author_name"
        case body
        case statusFrom = "status_from"
        case statusTo = "status_to"
        case createdAt = "created_at"
        case editedAt = "edited_at"
        case retracted
        case origin
        case lamport
    }

    public init(
        id: String,
        projectId: String,
        markupId: String,
        parentEntryId: String? = nil,
        kind: String = Kind.reply.rawValue,
        authorId: String? = nil,
        authorName: String,
        body: String,
        statusFrom: String? = nil,
        statusTo: String? = nil,
        createdAt: String,
        editedAt: String? = nil,
        retracted: Bool = false,
        origin: String? = nil,
        lamport: Int? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.markupId = markupId
        self.parentEntryId = parentEntryId
        self.kind = kind
        self.authorId = authorId
        self.authorName = authorName
        self.body = body
        self.statusFrom = statusFrom
        self.statusTo = statusTo
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.retracted = retracted
        self.origin = origin
        self.lamport = lamport
    }
}

// MARK: - Store

/// Reads and writes `review_entry` rows, inside the caller's `read`/`write` block.
public enum ReviewEntryStore {

    /// The longest body a reply may carry. A reply is prose; this bounds a hostile import.
    public static let maximumBodyBytes = 64 * 1024

    /// Inserts an entry, or replaces the row with the same id — how a redo puts back the
    /// reply its undo removed, byte for byte.
    public static func upsert(_ record: ReviewEntryRecord, in db: Database) throws {
        guard record.body.utf8.count <= maximumBodyBytes else {
            throw ZPDFPersistenceError.packageMalformed(reason: "review entry body over \(maximumBodyBytes) bytes")
        }
        try record.upsert(db)
    }

    /// Removes an entry outright: only for the undo of the reply that created it, which is a
    /// reply that, as far as the document is concerned, was never written.
    public static func remove(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM review_entry WHERE id = ?", arguments: [id])
    }

    /// Sets or clears an entry's tombstone.
    public static func setRetracted(id: String, retracted: Bool, editedAt: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE review_entry SET retracted = ?, edited_at = ? WHERE id = ?",
            arguments: [retracted, editedAt, id]
        )
    }

    /// Every entry in a project, oldest first; ties break on id so the order is stable.
    public static func entries(project projectId: String, in db: Database) throws -> [ReviewEntryRecord] {
        try ReviewEntryRecord.fetchAll(
            db,
            sql: "SELECT * FROM review_entry WHERE project_id = ? ORDER BY created_at, id",
            arguments: [projectId]
        )
    }

    /// One markup's entries, oldest first.
    public static func entries(
        project projectId: String,
        markup markupId: String,
        in db: Database
    ) throws -> [ReviewEntryRecord] {
        try ReviewEntryRecord.fetchAll(
            db,
            sql: "SELECT * FROM review_entry WHERE project_id = ? AND markup_id = ? ORDER BY created_at, id",
            arguments: [projectId, markupId]
        )
    }

    /// Re-homes every entry of one project into another — Create Project carrying a Quick PDF
    /// takeoff's threads into the package, verbatim apart from the project.
    public static func carryOver(
        _ records: [ReviewEntryRecord],
        into projectId: String,
        in db: Database
    ) throws {
        for var record in records {
            record.projectId = projectId
            try record.upsert(db)
        }
    }
}
