import Foundation
import GRDB
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

/// A real project database, a real PDF engine and a real file on disk.
///
/// Nothing here is a mock. The whole value of these tests is that FTS5's tokeniser,
/// SQLite's `bm25`, PDFKit's text extraction and Vision's recogniser are the actual
/// implementations — a fake index would agree with a fake query compiler about
/// everything and prove nothing.
struct SearchTestBed {

    let directory: URL
    let database: ProjectDatabaseActor
    let provider: PDFKitDocumentProvider
    let projectId: String

    /// The one directory the fixture corpus is generated into, shared across the suite so
    /// a 1 000-page fixture is written once per test run rather than once per test.
    static let fixtureDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-search-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func make(projectName: String = "Search test project") async throws -> SearchTestBed {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite", isDirectory: false)
        )
        let projectId = "project-\(UUID().uuidString)"
        let now = "2026-08-23T00:00:00Z"
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO project (id, name, created_at, modified_at, schema_version)
                VALUES (?, ?, ?, ?, 1)
                """,
                arguments: [projectId, projectName, now, now]
            )
        }

        return SearchTestBed(
            directory: directory,
            database: database,
            provider: PDFKitDocumentProvider(),
            projectId: projectId
        )
    }

    /// Opens a PDF, writes its `document` and `page` rows, and returns both identities.
    @discardableResult
    func addDocument(
        at url: URL,
        displayName: String? = nil
    ) async throws -> (documentId: String, handle: DocumentHandle) {
        let opened = try await provider.open(fileAt: url)
        let descriptor = opened.descriptor
        let pages = try await provider.pageDescriptors(of: opened.handle)

        let documentId = "document-\(UUID().uuidString)"
        let projectId = self.projectId
        let name = displayName ?? url.deletingPathExtension().lastPathComponent
        let path = url.lastPathComponent
        let sha = descriptor.digest.sha256
        let now = "2026-08-23T00:00:00Z"

        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO document
                    (id, project_id, display_name, relative_path, sha256, page_count,
                     active_revision_id, created_at, modified_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)
                """,
                arguments: [documentId, projectId, name, path, sha, pages.count, now, now]
            )
            for page in pages {
                try db.execute(
                    sql: """
                    INSERT INTO page
                        (id, document_id, page_index, page_label,
                         media_x, media_y, media_width, media_height,
                         crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    arguments: [
                        "\(documentId)-page-\(page.index)", documentId, page.index, page.label,
                        page.boxes.media.minX, page.boxes.media.minY,
                        page.boxes.media.width, page.boxes.media.height,
                        page.boxes.crop.minX, page.boxes.crop.minY,
                        page.boxes.crop.width, page.boxes.crop.height,
                        page.rotation
                    ]
                )
            }
        }
        return (documentId, opened.handle)
    }

    /// The `page.id` of one page of a document added by ``addDocument(at:displayName:)``.
    func pageId(documentId: String, pageIndex: Int) -> String {
        "\(documentId)-page-\(pageIndex)"
    }

    /// Rewrites a document's recorded SHA, which is how a test says "the file changed"
    /// without having to produce a different PDF.
    func setDocumentSHA(_ sha: String, documentId: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE document SET sha256 = ? WHERE id = ?",
                arguments: [sha, documentId]
            )
        }
    }

    /// Inserts a markup with a rectangular geometry, for the markup half of the index.
    @discardableResult
    func addMarkup(
        documentId: String,
        pageIndex: Int,
        subject: String,
        label: String? = nil,
        comment: String? = nil,
        rect: CGRect = CGRect(x: 10, y: 20, width: 30, height: 40)
    ) async throws -> String {
        let markupId = "markup-\(UUID().uuidString)"
        let pageId = pageId(documentId: documentId, pageIndex: pageIndex)
        let geometry = try GeometryBlob(
            kind: .rectangle,
            points: [
                GeometryPoint(x: rect.minX, y: rect.minY),
                GeometryPoint(x: rect.maxX, y: rect.minY),
                GeometryPoint(x: rect.maxX, y: rect.maxY),
                GeometryPoint(x: rect.minX, y: rect.maxY)
            ]
        ).encode()
        let now = "2026-08-23T00:00:00Z"
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO markup
                    (id, document_id, page_id, type, subject, label, comment,
                     geometry_blob, style_blob, scale_id, scale_version, scale_region_id,
                     zone_id, layer_name, status, author, locked, hidden,
                     created_at, modified_at, revision)
                VALUES (?, ?, ?, 'rectangle', ?, ?, ?, ?, ?, NULL, NULL, NULL,
                        NULL, NULL, NULL, NULL, 0, 0, ?, ?, 1)
                """,
                arguments: [
                    markupId, documentId, pageId, subject, label, comment,
                    geometry, Data(), now, now
                ]
            )
        }
        return markupId
    }

    /// A document and page row with no PDF behind them, plus one markup on that page.
    ///
    /// The markup half of the index is pure SQL — it never touches a PDF — so the tests
    /// that exercise it should not have to generate one. What they do need is a valid
    /// `document` and `page` row, because `markup` has foreign keys to both.
    @discardableResult
    func addMarkupOnSyntheticPage(
        subject: String,
        label: String? = nil,
        comment: String? = nil,
        rect: CGRect = CGRect(x: 100, y: 200, width: 300, height: 400)
    ) async throws -> String {
        let documentId = "document-\(UUID().uuidString)"
        let projectId = self.projectId
        let now = "2026-08-23T00:00:00Z"
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO document
                    (id, project_id, display_name, relative_path, sha256, page_count,
                     active_revision_id, created_at, modified_at)
                VALUES (?, ?, 'synthetic', 'synthetic.pdf', ?, 1, NULL, ?, ?)
                """,
                arguments: [documentId, projectId, String(repeating: "0", count: 64), now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO page
                    (id, document_id, page_index, page_label,
                     media_x, media_y, media_width, media_height,
                     crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
                VALUES (?, ?, 0, 'A-101', 0, 0, 612, 792, 0, 0, 612, 792, 0, NULL)
                """,
                arguments: ["\(documentId)-page-0", documentId]
            )
        }
        return try await addMarkup(
            documentId: documentId,
            pageIndex: 0,
            subject: subject,
            label: label,
            comment: comment,
            rect: rect
        )
    }

    /// A custom column and one text value on a markup.
    func addCustomValue(
        markupId: String,
        columnName: String,
        value: String
    ) async throws {
        let columnId = "column-\(UUID().uuidString)"
        let projectId = self.projectId
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO custom_column
                    (id, project_id, name, type, dimension_json, currency_code, formula,
                     choice_values_json, default_value, sort_order, visible)
                VALUES (?, ?, ?, 'text', NULL, NULL, NULL, NULL, NULL, 0, 1)
                """,
                arguments: [columnId, projectId, columnName]
            )
            try db.execute(
                sql: "INSERT INTO custom_value (markup_id, column_id, value_text) VALUES (?, ?, ?)",
                arguments: [markupId, columnId, value]
            )
        }
    }

    // MARK: - Counting, for the tests that assert on the index itself

    func indexRowCount(sourceType: SearchSourceType? = nil, documentId: String? = nil) async throws -> Int {
        try await database.read { db in
            var conditions: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if let sourceType {
                conditions.append("source_type = ?")
                arguments.append(sourceType.rawValue)
            }
            if let documentId {
                conditions.append("document_id = ?")
                arguments.append(documentId)
            }
            let clause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM search_fts" + clause,
                arguments: StatementArguments(arguments.map(\.databaseValue))
            ) ?? 0
        }
    }

    func ocrTokenCount(pageId: String? = nil) async throws -> Int {
        try await database.read { db in
            if let pageId {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM ocr_token WHERE page_id = ?",
                    arguments: [pageId]
                ) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_token") ?? 0
        }
    }

    /// Every page id that has at least one recognised token.
    func pagesWithTokens() async throws -> Set<String> {
        try await database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT page_id FROM ocr_token"))
        }
    }

    /// Every page id that has an `ocr` index row.
    func pagesWithOCRIndexRows() async throws -> Set<String> {
        try await database.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT page_id FROM search_fts WHERE source_type = ? AND page_id IS NOT NULL",
                arguments: [SearchSourceType.ocr.rawValue]
            ))
        }
    }

    func tearDown() async {
        await provider.closeAll()
        try? await database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Runs `body` against a fresh test bed and tears it down afterwards, on success and on
/// failure alike.
///
/// `defer` cannot `await`, so this is the only way to guarantee the database handle is
/// closed and the temporary directory removed when a test throws.
func withSearchTestBed<T>(
    _ body: (SearchTestBed) async throws -> T
) async throws -> T {
    let bed = try await SearchTestBed.make()
    do {
        let value = try await body(bed)
        await bed.tearDown()
        return value
    } catch {
        await bed.tearDown()
        throw error
    }
}
