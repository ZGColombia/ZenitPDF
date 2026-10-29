import Foundation
import GRDB

// MARK: - page_set_entry (schema v13, ADR-0022 (documents))

/// A page's place in the set and its sheet identity. See
/// ``ProjectSchema/documentSetTableStatements``.
public struct PageSetEntryRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "page_set_entry"

    public var pageId: String
    /// Zero-based position in the set.
    public var position: Int
    public var sheetNumber: String?
    public var sheetTitle: String?
    public var discipline: String?
    /// Where the sheet's number and title came from, as text so a newer source survives a
    /// round trip through an older reader. The vocabulary is ZPDFAppCore's `SheetNameSource`
    /// (V-097: the copy of it this package kept was read by nothing).
    public var nameSource: String?
    /// 0, 90, 180 or 270, added to the page's own `/Rotate` for display only.
    public var viewRotation: Int
    /// Removed from the set (reversible); the page and its markups are kept.
    public var excluded: Bool
    /// The view crop (schema v15, NL-DOCS-16): `{"x":…,"y":…,"width":…,"height":…}` in page
    /// space, display only; `nil` shows the page's crop box.
    public var cropJSON: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case pageId = "page_id"
        case position
        case sheetNumber = "sheet_number"
        case sheetTitle = "sheet_title"
        case discipline
        case nameSource = "name_source"
        case viewRotation = "view_rotation"
        case excluded
        case cropJSON = "crop_json"
    }

    public init(
        pageId: String,
        position: Int,
        sheetNumber: String? = nil,
        sheetTitle: String? = nil,
        discipline: String? = nil,
        nameSource: String? = nil,
        viewRotation: Int = 0,
        excluded: Bool = false,
        cropJSON: String? = nil
    ) {
        self.pageId = pageId
        self.position = position
        self.sheetNumber = sheetNumber
        self.sheetTitle = sheetTitle
        self.discipline = discipline
        self.nameSource = nameSource
        self.viewRotation = viewRotation
        self.excluded = excluded
        self.cropJSON = cropJSON
    }
}

// MARK: - revision_entry / revision_sheet

/// A revision of a document: its file, copied read-only into the package and hashed.
public struct RevisionEntryRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "revision_entry"

    public var id: String
    public var documentId: String
    public var label: String
    /// Relative to the package root: `documents/revisions/<id>.pdf`.
    public var relativePath: String
    public var sha256: String
    public var pageCount: Int
    public var sortOrder: Int
    public var addedAt: String

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case documentId = "document_id"
        case label
        case relativePath = "relative_path"
        case sha256
        case pageCount = "page_count"
        case sortOrder = "sort_order"
        case addedAt = "added_at"
    }

    public init(
        id: String, documentId: String, label: String, relativePath: String, sha256: String,
        pageCount: Int, sortOrder: Int, addedAt: String
    ) {
        self.id = id
        self.documentId = documentId
        self.label = label
        self.relativePath = relativePath
        self.sha256 = sha256
        self.pageCount = pageCount
        self.sortOrder = sortOrder
        self.addedAt = addedAt
    }
}

/// Which set page one revision page is paired with, and on what evidence.
public struct RevisionSheetRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "revision_sheet"

    /// How a pairing was decided.
    public enum Evidence: String, Codable, Sendable, CaseIterable {
        /// The sheet numbers (labels) are the same.
        case label
        /// Same position, same paper, no label to compare: a fallback the review shows.
        case position
        /// A person paired them.
        case manual
        /// No partner in the set: a sheet the revision adds.
        case added
    }

    public var revisionId: String
    public var revisionPageIndex: Int
    /// The set page it pairs with; `nil` for an added sheet.
    public var pageId: String?
    public var evidence: String

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case revisionId = "revision_id"
        case revisionPageIndex = "revision_page_index"
        case pageId = "page_id"
        case evidence
    }

    public init(revisionId: String, revisionPageIndex: Int, pageId: String?, evidence: String) {
        self.revisionId = revisionId
        self.revisionPageIndex = revisionPageIndex
        self.pageId = pageId
        self.evidence = evidence
    }
}

// MARK: - Store

/// Reads and writes the v13 document-set rows, inside the caller's `read`/`write` block.
public enum DocumentSetStore {

    /// The set entries of one document's pages, keyed by page id.
    public static func pageEntries(document documentId: String, in db: Database) throws -> [String: PageSetEntryRecord] {
        let rows = try PageSetEntryRecord.fetchAll(
            db,
            sql: """
                SELECT page_set_entry.* FROM page_set_entry
                JOIN page ON page.id = page_set_entry.page_id
                WHERE page.document_id = ?
                """,
            arguments: [documentId]
        )
        return Dictionary(rows.map { ($0.pageId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// One document's revisions, oldest first.
    public static func revisions(document documentId: String, in db: Database) throws -> [RevisionEntryRecord] {
        try RevisionEntryRecord.fetchAll(
            db,
            sql: "SELECT * FROM revision_entry WHERE document_id = ? ORDER BY sort_order, added_at, id",
            arguments: [documentId]
        )
    }

    /// The pairings of one revision, in revision page order.
    public static func sheets(revision revisionId: String, in db: Database) throws -> [RevisionSheetRecord] {
        try RevisionSheetRecord.fetchAll(
            db,
            sql: "SELECT * FROM revision_sheet WHERE revision_id = ? ORDER BY revision_page_index",
            arguments: [revisionId]
        )
    }

    /// Adds a revision with its pairings. Upsert, so recording a revision again replaces
    /// its pairings rather than failing on the existing row.
    public static func upsertRevision(
        _ revision: RevisionEntryRecord,
        sheets: [RevisionSheetRecord],
        in db: Database
    ) throws {
        try revision.save(db)
        try db.execute(sql: "DELETE FROM revision_sheet WHERE revision_id = ?", arguments: [revision.id])
        for sheet in sheets { try sheet.insert(db) }
    }
}
