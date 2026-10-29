import Foundation
import GRDB
import ZPDFPersistence

/// The only place this package writes SQL against `search_fts` and `ocr_token`.
///
/// It exists so that "which columns are written, in what order, with what `source_id`
/// convention" is one file rather than a habit spread across the indexer, the recogniser
/// and the query surface. Everything here is a plain function over a GRDB `Database`, run
/// inside whatever transaction the caller opened on ``ZPDFPersistence/ProjectDatabaseActor``.
///
/// No method here interpolates a value into SQL. Identifiers and query text are always
/// bound as statement arguments; the only strings ever built into a statement are the
/// `?` placeholder runs, whose count comes from an array this package owns.
enum SearchIndexStore {

    // MARK: - Rows in, rows out

    /// A page's row identity, read once and reused for every write about that page.
    struct PageRow: Sendable, Hashable {
        let id: String
        let index: Int
        let label: String?
    }

    /// The document facts the indexer needs before it touches a page.
    struct DocumentRow: Sendable, Hashable {
        let id: String
        let projectId: String
        let sha256: String
        let pageCount: Int
    }

    // MARK: - Reading identity

    static func documentRow(_ db: Database, documentId: String) throws -> DocumentRow? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT id, project_id, sha256, page_count FROM document WHERE id = ?",
            arguments: [documentId]
        )
        guard let row else { return nil }
        return DocumentRow(
            id: row["id"],
            projectId: row["project_id"],
            sha256: row["sha256"],
            pageCount: row["page_count"]
        )
    }

    static func pageRows(_ db: Database, documentId: String) throws -> [Int: PageRow] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, page_index, page_label FROM page WHERE document_id = ? ORDER BY page_index",
            arguments: [documentId]
        )
        var byIndex: [Int: PageRow] = [:]
        byIndex.reserveCapacity(rows.count)
        for row in rows {
            let index: Int = row["page_index"]
            byIndex[index] = PageRow(id: row["id"], index: index, label: row["page_label"])
        }
        return byIndex
    }

    /// Page index and label for a set of page ids, for decorating hits.
    static func pageLabels(_ db: Database, pageIds: [String]) throws -> [String: PageRow] {
        guard !pageIds.isEmpty else { return [:] }
        var result: [String: PageRow] = [:]
        // Chunked so a 5 000-hit result cannot build a statement with 5 000 placeholders,
        // which SQLite refuses past SQLITE_MAX_VARIABLE_NUMBER.
        for chunk in stride(from: 0, to: pageIds.count, by: 400).map({
            Array(pageIds[$0..<min($0 + 400, pageIds.count)])
        }) {
            let placeholders = databaseQuestionMarks(count: chunk.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, page_index, page_label FROM page WHERE id IN (\(placeholders))",
                arguments: StatementArguments(chunk)
            )
            for row in rows {
                let id: String = row["id"]
                result[id] = PageRow(id: id, index: row["page_index"], label: row["page_label"])
            }
        }
        return result
    }

    // MARK: - The index stamp

    /// The SHA-256 the text index for `documentId` was built from, if there is one.
    static func indexStamp(_ db: Database, documentId: String) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT content FROM search_fts WHERE source_type = ? AND source_id = ?",
            arguments: [SearchSourceType.indexStamp.rawValue, documentId]
        )
    }

    static func writeIndexStamp(
        _ db: Database,
        projectId: String,
        documentId: String,
        sha256: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM search_fts WHERE source_type = ? AND source_id = ?",
            arguments: [SearchSourceType.indexStamp.rawValue, documentId]
        )
        try insert(
            db,
            SearchIndexRecord(
                projectId: projectId,
                documentId: documentId,
                pageId: nil,
                sourceType: SearchSourceType.indexStamp.rawValue,
                sourceId: documentId,
                content: sha256
            )
        )
    }

    // MARK: - Writing

    static func insert(_ db: Database, _ record: SearchIndexRecord) throws {
        try db.execute(
            sql: """
            INSERT INTO search_fts (project_id, document_id, page_id, source_type, source_id, content)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                record.projectId, record.documentId, record.pageId,
                record.sourceType, record.sourceId, record.content
            ]
        )
    }

    /// Replaces every row of `types` for one document, so a reindex cannot duplicate.
    ///
    /// Returns the number of **index rows** removed — logical FTS5 rows, which is what a
    /// caller comparing "rows deleted" against "rows inserted" needs. SQLite's change counter
    /// for the DELETE statement reports exactly that: the shadow-table writes FTS5 makes
    /// underneath run as nested statements and are not counted against the outer one.
    /// `SearchIndexMaintenanceTests` pins it (R-163).
    @discardableResult
    static func deleteRows(
        _ db: Database,
        documentId: String,
        types: [SearchSourceType]
    ) throws -> Int {
        try deleteRows(db, column: .document, value: documentId, types: types)
    }

    @discardableResult
    static func deleteRows(
        _ db: Database,
        pageId: String,
        types: [SearchSourceType]
    ) throws -> Int {
        try deleteRows(db, column: .page, value: pageId, types: types)
    }

    @discardableResult
    static func deleteProjectRows(
        _ db: Database,
        projectId: String,
        types: [SearchSourceType]
    ) throws -> Int {
        try deleteRows(db, column: .project, value: projectId, types: types)
    }

    /// The three key columns a delete may be scoped by.
    ///
    /// An enum rather than a `String`, so the column name in the statement is chosen from a
    /// closed set at compile time. There is then no code path — not even a mistaken future
    /// one — by which a caller's string reaches the SQL, and no runtime assertion is needed
    /// to say so.
    enum ScopeColumn: String {
        case document = "document_id"
        case page = "page_id"
        case project = "project_id"
    }

    /// `column` names the statement's key column; `value` and the types are bound.
    private static func deleteRows(
        _ db: Database,
        column: ScopeColumn,
        value: String,
        types: [SearchSourceType]
    ) throws -> Int {
        guard !types.isEmpty else { return 0 }
        let placeholders = databaseQuestionMarks(count: types.count)
        var arguments: [any DatabaseValueConvertible] = [value]
        arguments.append(contentsOf: types.map(\.rawValue))
        let bound = StatementArguments(arguments.map(\.databaseValue))
        let clause = "WHERE \(column.rawValue) = ? AND source_type IN (\(placeholders))"
        // One statement, and SQLite's own count of what it removed (R-163). The key columns
        // are UNINDEXED, so the COUNT that used to run first was a second full scan of the
        // FTS table for a number the DELETE already knows.
        try db.execute(sql: "DELETE FROM search_fts \(clause)", arguments: bound)
        return db.changesCount
    }

    /// Deletes every recognised token belonging to a project (CR-126).
    ///
    /// `ocr_token` has no `project_id`; it is reached through its page and that page's
    /// document. Deleting only the FTS rows left the recognised **text** — every word
    /// Vision read off every scanned sheet — sitting in the file after the user asked
    /// for the index to be thrown away. Spec 17.4's "throw it away and rebuild" is a
    /// privacy control as much as a maintenance one, and it has to remove the words.
    @discardableResult
    static func deleteProjectOCRTokens(_ db: Database, projectId: String) throws -> Int {
        let scope = """
        page_id IN (
            SELECT p.id FROM page p
            JOIN document d ON d.id = p.document_id
            WHERE d.project_id = ?
        )
        """
        try db.execute(sql: "DELETE FROM ocr_token WHERE \(scope)", arguments: [projectId])
        return db.changesCount
    }

    @discardableResult
    static func deleteOCRTokens(_ db: Database, pageId: String) throws -> Int {
        try db.execute(sql: "DELETE FROM ocr_token WHERE page_id = ?", arguments: [pageId])
        return db.changesCount
    }

    static func insertOCRToken(_ db: Database, _ token: OCRTokenRecord) throws {
        try db.execute(
            sql: """
            INSERT INTO ocr_token
                (page_id, token, normalized_token, confidence, bounds_blob, line_index, token_index)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                token.pageId, token.token, token.normalizedToken, token.confidence,
                token.boundsBlob, token.lineIndex, token.tokenIndex
            ]
        )
    }

    // MARK: - Counting

    static func rowCount(_ db: Database, projectId: String, type: SearchSourceType) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_fts WHERE project_id = ? AND source_type = ?",
            arguments: [projectId, type.rawValue]
        ) ?? 0
    }

    // MARK: - Placeholders

    /// `?, ?, ?` for `count` bound values. The only string this file ever builds into SQL,
    /// and its content is fixed by an integer this package computed.
    static func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
    }
}
