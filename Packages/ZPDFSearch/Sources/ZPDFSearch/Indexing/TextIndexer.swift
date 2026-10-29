import Foundation
import GRDB
import ZPDFPDFKitBridge
import ZPDFPersistence

/// How far an index run got.
public struct IndexProgress: Sendable, Hashable {
    public let pagesCompleted: Int
    public let pagesTotal: Int
    /// The index of the page just finished.
    public let lastPageIndex: Int

    public init(pagesCompleted: Int, pagesTotal: Int, lastPageIndex: Int) {
        self.pagesCompleted = pagesCompleted
        self.pagesTotal = pagesTotal
        self.lastPageIndex = lastPageIndex
    }

    public var fraction: Double {
        pagesTotal > 0 ? Double(pagesCompleted) / Double(pagesTotal) : 1
    }
}

/// What one text-index run did.
public struct TextIndexReport: Sendable, Hashable {
    public let documentId: String
    /// The SHA-256 the index now reflects.
    public let sha256: String
    /// `true` when the stamp already matched and nothing was touched.
    public let wasSkippedAsUnchanged: Bool
    public let pagesIndexed: Int
    /// Pages with no text layer at all. These are the OCR candidates, and reporting them
    /// is the difference between "no hits" and "nothing to hit".
    public let pagesWithoutTextLayer: [Int]
    /// Pages that could not be read because the document is locked or forbids copying.
    public let pagesNotPermitted: [Int]
    public let rowsDeleted: Int
    public let rowsInserted: Int
    public let charactersIndexed: Int

    public init(
        documentId: String,
        sha256: String,
        wasSkippedAsUnchanged: Bool,
        pagesIndexed: Int,
        pagesWithoutTextLayer: [Int],
        pagesNotPermitted: [Int],
        rowsDeleted: Int,
        rowsInserted: Int,
        charactersIndexed: Int
    ) {
        self.documentId = documentId
        self.sha256 = sha256
        self.wasSkippedAsUnchanged = wasSkippedAsUnchanged
        self.pagesIndexed = pagesIndexed
        self.pagesWithoutTextLayer = pagesWithoutTextLayer
        self.pagesNotPermitted = pagesNotPermitted
        self.rowsDeleted = rowsDeleted
        self.rowsInserted = rowsInserted
        self.charactersIndexed = charactersIndexed
    }
}

/// What one project-annotation index run did.
public struct AnnotationIndexReport: Sendable, Hashable {
    public let projectId: String
    public let rowsDeleted: Int
    public let markupRowsInserted: Int
    public let customValueRowsInserted: Int
    public let zoneRowsInserted: Int

    public init(
        projectId: String,
        rowsDeleted: Int,
        markupRowsInserted: Int,
        customValueRowsInserted: Int,
        zoneRowsInserted: Int
    ) {
        self.projectId = projectId
        self.rowsDeleted = rowsDeleted
        self.markupRowsInserted = markupRowsInserted
        self.customValueRowsInserted = customValueRowsInserted
        self.zoneRowsInserted = zoneRowsInserted
    }

    public var rowsInserted: Int {
        markupRowsInserted + customValueRowsInserted + zoneRowsInserted
    }
}

/// Fills `search_fts` from a document's text layer and from the project's own annotations.
///
/// ### Incremental, keyed by document SHA
///
/// Reindexing a 1 000-sheet set costs seconds; reindexing it on every project open costs
/// the user seconds every time, forever. So the indexer records the document's SHA-256 in
/// an ``SearchSourceType/indexStamp`` row when it finishes, and a later run that finds the
/// same SHA does nothing at all and says so in ``TextIndexReport/wasSkippedAsUnchanged``.
/// The SHA is the document's, not the file's path or its modification date: a sheet
/// replaced by an identical revision is not reindexed, and a sheet whose bytes changed by
/// one is.
///
/// ### Why a reindex cannot duplicate
///
/// The write is delete-then-insert inside one transaction: every `pdf-text` row for the
/// document, plus its stamp, is deleted before the first new row is written. There is no
/// upsert and no "insert if missing" path, so there is no way for the second run over the
/// same document to leave two rows for one page — which is the failure this design exists
/// to make impossible, because FTS5 has no unique constraint to catch it.
public actor TextIndexer {

    private let database: ProjectDatabaseActor
    private let provider: any PDFDocumentProviding
    private let limits: SearchLimits
    private let normalization: TextNormalizationOptions

    public init(
        database: ProjectDatabaseActor,
        provider: any PDFDocumentProviding,
        limits: SearchLimits = .standard,
        normalization: TextNormalizationOptions = .standard
    ) {
        self.database = database
        self.provider = provider
        self.limits = limits
        self.normalization = normalization
    }

    // MARK: - PDF text

    /// Indexes the text layer of every page of one document.
    ///
    /// - Parameters:
    ///   - documentId: the `document.id` row this PDF is stored under. Its `sha256` column
    ///     is the incremental key.
    ///   - handle: the same document, open in the provider.
    ///   - force: reindex even when the stamp matches. Used after the normalisation rules
    ///     change, and by the tests that assert reindexing does not duplicate.
    ///   - progress: called on the indexer's executor after each page.
    @discardableResult
    public func indexDocumentText(
        documentId: String,
        handle: DocumentHandle,
        force: Bool = false,
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> TextIndexReport {
        try checkSearchCancellation()

        let identity = try await documentIdentity(documentId)
        let document = identity.document
        let pages = identity.pages

        if !force, let stamp = identity.stamp, stamp == document.sha256 {
            return TextIndexReport(
                documentId: documentId,
                sha256: document.sha256,
                wasSkippedAsUnchanged: true,
                pagesIndexed: 0,
                pagesWithoutTextLayer: [],
                pagesNotPermitted: [],
                rowsDeleted: 0,
                rowsInserted: 0,
                charactersIndexed: 0
            )
        }

        guard !pages.isEmpty else {
            throw ZPDFSearchError.documentHasNoPageRows(documentId: documentId)
        }

        // Read every page's text first, then write once. Two reasons: the provider is a
        // separate actor and interleaving its awaits with an open write transaction would
        // hold the writer for the whole extraction; and a document that throws halfway
        // must not leave a half-replaced index.
        var contents: [(pageId: String, text: String)] = []
        var withoutTextLayer: [Int] = []
        var notPermitted: [Int] = []
        var characters = 0

        let sortedIndices = pages.keys.sorted()
        for (position, pageIndex) in sortedIndices.enumerated() {
            try checkSearchCancellation()
            guard let page = pages[pageIndex] else {
                throw ZPDFSearchError.missingPageRow(documentId: documentId, pageIndex: pageIndex)
            }

            let pageText: PageText
            do {
                pageText = try await provider.pageText(of: handle, pageIndex: pageIndex)
            } catch {
                throw ZPDFSearchError.adaptEngine(error)
            }

            switch pageText.availability {
            case .noTextLayer:
                withoutTextLayer.append(pageIndex)
            case .notPermitted:
                notPermitted.append(pageIndex)
            case .available:
                var raw = pageText.string
                if raw.count > limits.maximumIndexedCharactersPerPage {
                    raw = String(raw.prefix(limits.maximumIndexedCharactersPerPage))
                }
                let normalised = ZPDFTextNormalizer.indexable(raw, options: normalization)
                if !normalised.isEmpty {
                    characters += normalised.count
                    contents.append((page.id, normalised))
                } else {
                    // A text layer of nothing but whitespace is, for search, no text layer.
                    withoutTextLayer.append(pageIndex)
                }
            }

            progress?(
                IndexProgress(
                    pagesCompleted: position + 1,
                    pagesTotal: sortedIndices.count,
                    lastPageIndex: pageIndex
                )
            )
        }

        try checkSearchCancellation()

        let projectId = document.projectId
        let sha = document.sha256
        let rows = contents
        // BH-204: the stamp is a claim that the index reflects these bytes. A page whose
        // text the provider refused to read (a locked document, a permission the file
        // withholds) was not read, so the index does not reflect it, and stamping would
        // freeze that gap: every later non-forced run would return `wasSkippedAsUnchanged`
        // even after the provider can read the page. The rows that could be read are still
        // written; only the stamp is withheld, so the next run tries again.
        let writesStamp = notPermitted.isEmpty
        let counts = try await write { db in
            let deleted = try SearchIndexStore.deleteRows(
                db,
                documentId: documentId,
                types: [.pdfText, .indexStamp]
            )
            for row in rows {
                try SearchIndexStore.insert(
                    db,
                    SearchIndexRecord(
                        projectId: projectId,
                        documentId: documentId,
                        pageId: row.pageId,
                        sourceType: SearchSourceType.pdfText.rawValue,
                        sourceId: row.pageId,
                        content: row.text
                    )
                )
            }
            if writesStamp {
                try SearchIndexStore.writeIndexStamp(
                    db,
                    projectId: projectId,
                    documentId: documentId,
                    sha256: sha
                )
            }
            return (deleted, rows.count)
        }

        return TextIndexReport(
            documentId: documentId,
            sha256: sha,
            wasSkippedAsUnchanged: false,
            pagesIndexed: rows.count,
            pagesWithoutTextLayer: withoutTextLayer,
            pagesNotPermitted: notPermitted,
            rowsDeleted: counts.0,
            rowsInserted: counts.1,
            charactersIndexed: characters
        )
    }

    /// The SHA-256 the text index for `documentId` currently reflects, or `nil` when the
    /// document has never been indexed. Internal (V-082): the stamp is the indexer's own
    /// business; only the tests read it.
    func indexedSHA(documentId: String) async throws -> String? {
        try await read { db in try SearchIndexStore.indexStamp(db, documentId: documentId) }
    }

    // MARK: - Markups, custom values and zones

    /// Rebuilds the annotation half of the index for one project.
    ///
    /// Markup subject, label and comment, every custom text value, and every zone name.
    /// This half is cheap — it is a few SQL reads — so it is a full rebuild rather than an
    /// incremental one: there is no hash of "the markups" that would be cheaper to compute
    /// than the rebuild itself.
    @discardableResult
    public func indexProjectAnnotations(projectId: String) async throws -> AnnotationIndexReport {
        try checkSearchCancellation()
        let normalization = self.normalization
        let limit = limits.maximumIndexedCharactersPerPage

        // Checked before the write opens, for the reason documented on `documentIdentity`.
        let projectExists = try await read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM project WHERE id = ?)",
                arguments: [projectId]
            ) ?? false
        }
        guard projectExists else { throw ZPDFSearchError.unknownProject(projectId: projectId) }

        return try await write { db in
            let deleted = try SearchIndexStore.deleteProjectRows(
                db,
                projectId: projectId,
                types: [.markupSubject, .markupLabel, .markupComment, .customValue, .zoneName]
            )

            let clean = { (text: String?) in Self.clean(text, limit: limit, normalization: normalization) }

            // Markups.
            let markups = try Row.fetchAll(
                db,
                sql: """
                SELECT m.id, m.document_id, m.page_id, m.subject, m.label, m.comment
                FROM markup m
                JOIN document d ON d.id = m.document_id
                WHERE d.project_id = ?
                ORDER BY m.id
                """,
                arguments: [projectId]
            )
            let markupRows = try Self.insertMarkupRows(db, markups, projectId: projectId, clean: clean)

            // Custom values.
            let values = try Row.fetchAll(
                db,
                sql: """
                SELECT cv.markup_id, cv.column_id, cv.value_text, m.document_id, m.page_id
                FROM custom_value cv
                JOIN markup m ON m.id = cv.markup_id
                JOIN document d ON d.id = m.document_id
                WHERE d.project_id = ?
                ORDER BY cv.markup_id, cv.column_id
                """,
                arguments: [projectId]
            )
            let customRows = try Self.insertCustomValueRows(db, values, projectId: projectId, clean: clean)

            // Zones.
            var zoneRows = 0
            let zones = try Row.fetchAll(
                db,
                sql: """
                SELECT z.id, z.name, z.page_id, p.document_id
                FROM project_zone z
                JOIN page p ON p.id = z.page_id
                JOIN document d ON d.id = p.document_id
                WHERE d.project_id = ?
                ORDER BY z.id
                """,
                arguments: [projectId]
            )
            for row in zones {
                guard let content = clean(row["name"]) else { continue }
                try SearchIndexStore.insert(
                    db,
                    SearchIndexRecord(
                        projectId: projectId,
                        documentId: row["document_id"],
                        pageId: row["page_id"],
                        sourceType: SearchSourceType.zoneName.rawValue,
                        sourceId: row["id"],
                        content: content
                    )
                )
                zoneRows += 1
            }

            return AnnotationIndexReport(
                projectId: projectId,
                rowsDeleted: deleted,
                markupRowsInserted: markupRows,
                customValueRowsInserted: customRows,
                zoneRowsInserted: zoneRows
            )
        }
    }

    /// Rebuilds the full-text rows of just the given markups: subject, label, comment and
    /// their custom text values (IM-057, for `DocumentSearchIndex.indexMarkups`).
    ///
    /// The markups' existing `search_fts` rows — keyed `source_id = markupId` and, for custom
    /// values, `markupId/columnId` — are deleted and re-inserted from the current tables in
    /// one transaction. An id that no longer exists (a deleted markup) just loses its rows.
    /// Zone names are untouched; ``indexProjectAnnotations(projectId:)`` stays the full
    /// rebuild. Ids are processed in chunks, so a long list never exceeds SQLite's bound
    /// variable limit.
    @discardableResult
    public func indexAnnotations(projectId: String, markupIds: [String]) async throws -> AnnotationIndexReport {
        try checkSearchCancellation()
        let ids = Array(Set(markupIds)).sorted()
        let normalization = self.normalization
        let limit = limits.maximumIndexedCharactersPerPage

        let projectExists = try await read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM project WHERE id = ?)",
                arguments: [projectId]
            ) ?? false
        }
        guard projectExists else { throw ZPDFSearchError.unknownProject(projectId: projectId) }
        guard !ids.isEmpty else {
            return AnnotationIndexReport(
                projectId: projectId, rowsDeleted: 0, markupRowsInserted: 0,
                customValueRowsInserted: 0, zoneRowsInserted: 0
            )
        }

        return try await write { db in
            let clean = { (text: String?) in Self.clean(text, limit: limit, normalization: normalization) }
            let markupTypes = [SearchSourceType.markupSubject, .markupLabel, .markupComment].map(\.rawValue)
            var deleted = 0
            var markupRows = 0
            var customRows = 0
            var start = 0
            while start < ids.count {
                let chunk = Array(ids[start..<Swift.min(start + 400, ids.count)])
                start += chunk.count
                let marks = databaseQuestionMarks(count: chunk.count)
                let typeMarks = databaseQuestionMarks(count: markupTypes.count)

                // Delete: the markup's own fields, then its custom values (`markupId/…`). One
                // statement each per chunk, counted by SQLite (R-152): the key columns are
                // UNINDEXED, so the per-id COUNT and DELETE this replaced were two full scans
                // of the FTS table for every id. A custom value's markup is the part of its
                // `source_id` before the first `/` — markup ids are UUID strings and carry
                // none — compared exactly, so no `%` or `_` in an id can widen the match.
                let markupArgs = StatementArguments([projectId] + markupTypes + chunk)
                let markupClause = "WHERE project_id = ? AND source_type IN (\(typeMarks)) AND source_id IN (\(marks))"
                try db.execute(sql: "DELETE FROM search_fts \(markupClause)", arguments: markupArgs)
                deleted += db.changesCount
                let customArgs = StatementArguments([projectId, SearchSourceType.customValue.rawValue] + chunk)
                let customClause = """
                    WHERE project_id = ? AND source_type = ? \
                    AND substr(source_id, 1, instr(source_id, '/') - 1) IN (\(marks))
                    """
                try db.execute(sql: "DELETE FROM search_fts \(customClause)", arguments: customArgs)
                deleted += db.changesCount

                // Re-insert from the current rows.
                let markups = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT m.id, m.document_id, m.page_id, m.subject, m.label, m.comment
                    FROM markup m
                    JOIN document d ON d.id = m.document_id
                    WHERE d.project_id = ? AND m.id IN (\(marks))
                    ORDER BY m.id
                    """,
                    arguments: StatementArguments([projectId] + chunk)
                )
                markupRows += try Self.insertMarkupRows(db, markups, projectId: projectId, clean: clean)
                let values = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT cv.markup_id, cv.column_id, cv.value_text, m.document_id, m.page_id
                    FROM custom_value cv
                    JOIN markup m ON m.id = cv.markup_id
                    JOIN document d ON d.id = m.document_id
                    WHERE d.project_id = ? AND cv.markup_id IN (\(marks))
                    ORDER BY cv.markup_id, cv.column_id
                    """,
                    arguments: StatementArguments([projectId] + chunk)
                )
                customRows += try Self.insertCustomValueRows(db, values, projectId: projectId, clean: clean)
            }
            return AnnotationIndexReport(
                projectId: projectId,
                rowsDeleted: deleted,
                markupRowsInserted: markupRows,
                customValueRowsInserted: customRows,
                zoneRowsInserted: 0
            )
        }
    }

    // MARK: Annotation rows, written the same way by the full and the incremental path (R-162)

    /// `text` cut to the per-page limit and normalised for the index, or `nil` when nothing
    /// indexable is left.
    private static func clean(
        _ text: String?,
        limit: Int,
        normalization: TextNormalizationOptions
    ) -> String? {
        guard let text else { return nil }
        let normalised = ZPDFTextNormalizer.indexable(String(text.prefix(limit)), options: normalization)
        return normalised.isEmpty ? nil : normalised
    }

    /// Inserts the subject, label and comment rows of `markups` (rows with `id`,
    /// `document_id`, `page_id`, `subject`, `label`, `comment`), keyed `source_id = id`.
    /// Returns how many rows were written.
    private static func insertMarkupRows(
        _ db: Database,
        _ markups: [Row],
        projectId: String,
        clean: (String?) -> String?
    ) throws -> Int {
        var inserted = 0
        for row in markups {
            let markupId: String = row["id"]
            let fields: [(SearchSourceType, String?)] = [
                (.markupSubject, row["subject"]),
                (.markupLabel, row["label"]),
                (.markupComment, row["comment"])
            ]
            for (type, value) in fields {
                guard let content = clean(value) else { continue }
                try SearchIndexStore.insert(
                    db,
                    SearchIndexRecord(
                        projectId: projectId,
                        documentId: row["document_id"],
                        pageId: row["page_id"],
                        sourceType: type.rawValue,
                        sourceId: markupId,
                        content: content
                    )
                )
                inserted += 1
            }
        }
        return inserted
    }

    /// Inserts one row per custom text value (rows with `markup_id`, `column_id`,
    /// `value_text`, `document_id`, `page_id`). `source_id` is `markupId/columnId`, because
    /// `custom_value` has a composite key and one column of `search_fts` has to carry both
    /// halves. Returns how many rows were written.
    private static func insertCustomValueRows(
        _ db: Database,
        _ values: [Row],
        projectId: String,
        clean: (String?) -> String?
    ) throws -> Int {
        var inserted = 0
        for row in values {
            guard let content = clean(row["value_text"]) else { continue }
            let markupId: String = row["markup_id"]
            let columnId: String = row["column_id"]
            try SearchIndexStore.insert(
                db,
                SearchIndexRecord(
                    projectId: projectId,
                    documentId: row["document_id"],
                    pageId: row["page_id"],
                    sourceType: SearchSourceType.customValue.rawValue,
                    sourceId: "\(markupId)/\(columnId)",
                    content: content
                )
            )
            inserted += 1
        }
        return inserted
    }

    /// Deletes the whole index for a project and reports both halves of what it removed:
    /// the FTS rows and the recognised tokens. Spec 17.4: the index can always be thrown away
    /// and rebuilt, so there is a supported way to throw it away — the Search panel's Delete
    /// Search Index and Recognised Text… (V-079).
    ///
    /// "The whole index" includes `ocr_token` (CR-126). Deleting only the FTS rows left
    /// every word the recogniser read off every scanned sheet in the file — the searchable
    /// rows were gone and the recognised text was not — which is not what a control that
    /// says it deletes the index means, least of all on drawings a user may consider
    /// confidential.
    ///
    /// And "deleted" means gone from the file, not only from the rows (V-079). SQLite keeps a
    /// deleted row's bytes in free pages and in the write-ahead log, and FTS5 keeps a deleted
    /// document's terms in its index segments until they are merged; a word read off a
    /// confidential sheet could still be read out of the file with a hex viewer. So the removal
    /// merges the full-text segments (`'optimize'`), rewrites the file without its free pages
    /// (`VACUUM`) and empties the log (a truncating checkpoint).
    @discardableResult
    public func removeProjectIndexReportingTokens(
        projectId: String
    ) async throws -> (rows: Int, recognisedTokens: Int) {
        let removed = try await write { db in
            let rows = try SearchIndexStore.deleteProjectRows(
                db,
                projectId: projectId,
                types: SearchSourceType.allCases
            )
            let tokens = try SearchIndexStore.deleteProjectOCRTokens(db, projectId: projectId)
            try db.execute(sql: "INSERT INTO search_fts(search_fts) VALUES('optimize')")
            return (rows, tokens)
        }
        do {
            _ = try await database.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
            try await database.checkpoint(.truncate)
        } catch {
            throw ZPDFSearchError.adaptStorage(error)
        }
        return removed
    }

    // MARK: - Internals

    private struct DocumentIdentity: Sendable {
        let document: SearchIndexStore.DocumentRow
        let pages: [Int: SearchIndexStore.PageRow]
        let stamp: String?
    }

    /// Reads the document row, its pages and its stamp.
    ///
    /// The "no such document" check happens *outside* the database closure on purpose.
    /// GRDB catches whatever a read block throws and re-presents it as a `DatabaseError`,
    /// which `ProjectDatabaseActor` then maps to `ZPDFPersistenceError.databaseFailure` —
    /// so a `ZPDFSearchError.unknownDocument` thrown inside the closure reaches the caller
    /// as `.storage("SQLite error 0: no document row with id …")`. A typed error that has
    /// to be pattern-matched out of a string is not a typed error.
    private func documentIdentity(_ documentId: String) async throws -> DocumentIdentity {
        let identity: DocumentIdentity? = try await read { db in
            guard let document = try SearchIndexStore.documentRow(db, documentId: documentId) else {
                return nil
            }
            return DocumentIdentity(
                document: document,
                pages: try SearchIndexStore.pageRows(db, documentId: documentId),
                stamp: try SearchIndexStore.indexStamp(db, documentId: documentId)
            )
        }
        guard let identity else {
            throw ZPDFSearchError.unknownDocument(documentId: documentId)
        }
        return identity
    }

    private func read<T: Sendable>(
        _ body: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do { return try await database.read(body) } catch { throw ZPDFSearchError.adaptStorage(error) }
    }

    private func write<T: Sendable>(
        _ body: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do { return try await database.write(body) } catch { throw ZPDFSearchError.adaptStorage(error) }
    }
}
