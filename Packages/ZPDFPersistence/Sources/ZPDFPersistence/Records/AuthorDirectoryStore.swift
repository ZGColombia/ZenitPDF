import Foundation
import GRDB

extension ProjectSchema {

    /// v16 (NL-COLLAB-05): the people who have signed anything in this project —
    /// a stable id per installation, the name they last signed with, their initials, an optional
    /// avatar colour and an optional company. `markup.author` and `review_entry.author_name` keep
    /// the name each row was signed with (history is append-only); this table is what lets the
    /// Review List and the report say which company a name belongs to.
    public static let authorTableStatement = """
        CREATE TABLE author (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            initials TEXT NOT NULL,
            color_rgba TEXT,
            company TEXT,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL
        )
        """

    public static let authorIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_author_project_name",
            sql: "CREATE INDEX idx_author_project_name ON author(project_id, display_name)",
            rationale: "The review report and list look a signed name up in its project."
        )
    ]

    static func createAuthorTable(_ db: Database) throws {
        try db.execute(sql: authorTableStatement)
        for definition in authorIndexDefinitions { try db.execute(sql: definition.sql) }
    }
}

/// One person in a project's author directory (schema v16).
public struct AuthorRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "author"

    public var id: String
    public var projectId: String
    public var displayName: String
    public var initials: String
    /// `#RRGGBBAA`, or `nil` for the palette colour the name hashes to.
    public var colorRGBA: String?
    public var company: String?
    public var firstSeen: String
    public var lastSeen: String

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case projectId = "project_id"
        case displayName = "display_name"
        case initials
        case colorRGBA = "color_rgba"
        case company
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
    }

    public init(id: String, projectId: String, displayName: String, initials: String, colorRGBA: String? = nil,
                company: String? = nil, firstSeen: String, lastSeen: String) {
        self.id = id
        self.projectId = projectId
        self.displayName = displayName
        self.initials = initials
        self.colorRGBA = colorRGBA
        self.company = company
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Read and write API for the author directory (schema v16).
public enum AuthorDirectoryStore {

    /// The longest name or company kept; the directory is display text, and bounded.
    public static let maximumTextLength = 200

    /// Inserts the person, or refreshes their name, initials, colour, company and last-seen time.
    /// `first_seen` is never moved.
    public static func upsert(_ record: AuthorRecord, in db: Database) throws {
        var bounded = record
        bounded.displayName = String(record.displayName.prefix(maximumTextLength))
        bounded.company = record.company.map { String($0.prefix(maximumTextLength)) }
        bounded.initials = String(record.initials.prefix(4))
        if let existing = try AuthorRecord.filter(AuthorRecord.CodingKeys.id == record.id).fetchOne(db) {
            bounded.firstSeen = existing.firstSeen
            try bounded.update(db)
        } else {
            try bounded.insert(db)
        }
    }

    /// Everyone in a project, by name.
    public static func authors(project projectId: String, in db: Database) throws -> [AuthorRecord] {
        try AuthorRecord
            .filter(AuthorRecord.CodingKeys.projectId == projectId)
            .order(AuthorRecord.CodingKeys.displayName, AuthorRecord.CodingKeys.id)
            .fetchAll(db)
    }
}
