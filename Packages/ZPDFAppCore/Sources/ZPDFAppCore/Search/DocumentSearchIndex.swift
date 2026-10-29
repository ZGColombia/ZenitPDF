import CoreGraphics
import Foundation
import GRDB
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFSearch
import ZPDFUIPresentation

/// The seam between one open drawing and `ZPDFSearch`.
///
/// `AppSearchPresenter` needs three things it cannot make for itself: a `SearchService` over a
/// real database, a ``SearchIdentityMap`` that turns the index's string keys back into the UI's
/// `UUID`s, and something that actually *fills* the index. This type is all three, plus the
/// recognition run behind the OCR sheet.
///
/// ### Where the index lives, and why it is not the project package
///
/// The index is a **derived** artefact and it lives beside the document's other derived state in
/// the application container — never inside the user's `.zpdfproj`. Two reasons, both measured
/// against the schema rather than guessed:
///
/// 1. `ocr_token.page_id` is declared `REFERENCES page(id) ON DELETE CASCADE`, and
///    ``TakeoffArchive/write(_:into:)`` deletes and reinserts every `page` row of the document on
///    every save. Recognising a 400-page scan and then pressing `⌘S` would silently throw the
///    whole run away.
/// 2. A package's bytes are the user's file. A search index is a cache; rebuilding it must never
///    be able to dirty, grow or corrupt a takeoff.
///
/// The container copy is keyed by the document's own identity, so it survives quitting and
/// reopening, and `TextIndexer`'s SHA-256 stamp means reopening an unchanged drawing re-indexes
/// nothing.
///
/// ### What is honest about it
///
/// Nothing here invents a hit. Page text comes from PDFKit's text layer; recognised text comes
/// from Vision, on this Mac, and is labelled `ocr` all the way to the result row so the panel can
/// say so; markup text comes from the markups the session actually holds. A hit whose page is not
/// registered in the identity map is dropped rather than pointed at a plausible page.
public actor DocumentSearchIndex {

    // MARK: - Identity

    /// The index's key for the project. One open document is one "project" as far as the index is
    /// concerned; scoping to a page or a document inside it still works.
    public nonisolated let projectKey: String

    /// The index's key for the drawing: the SHA-256 of the bytes that were opened.
    ///
    /// Not the session's `DocumentID`, which is a fresh `UUID` on every open. An index keyed by a
    /// per-open identity would be rebuilt from scratch every launch, and every recognised page
    /// would be recognised again — twenty minutes of Vision, thrown away by closing a window.
    public nonisolated let documentKey: String

    /// The query surface. An `actor`, so the presenter may hold it directly.
    public nonisolated let service: SearchService

    /// Where the index file lives, for diagnostics and for teardown.
    public nonisolated let databaseURL: URL

    /// Internal, not private, so a test can watch its commits (the R-152 cancellation test).
    let database: ProjectDatabaseActor
    private let provider: PDFKitDocumentProvider
    private let handle: DocumentHandle
    private let indexer: TextIndexer
    private let ocr: OCRService
    private let indexedPageCount: Int
    /// The markup rows the index holds **and has finished full-text indexing**, so a re-index
    /// writes only the rows that changed and skips the full-text rebuild when none did (IM-057).
    ///
    /// `nil` means "unknown", and the next call does a full rebuild: before the first write,
    /// while a write is in flight, and after a write that failed part-way. A write that commits
    /// the markup table and is then cancelled before its full-text rebuild would otherwise leave
    /// this claiming rows whose search rows were never written, and no later incremental call
    /// would ever revisit them (R-152 re-fix).
    private var indexedMarkupRows: [String: IndexedMarkup]?
    /// The zone rows the index holds, by zone id — `nil` meaning unknown, exactly as for
    /// ``indexedMarkupRows``. Zones change rarely; a change rebuilds the project's full-text rows.
    private var indexedZoneRows: [String: IndexedZone]?

    /// One markup as the index holds it: its row and its searchable custom values, by column id.
    struct IndexedMarkup: Equatable, Sendable {
        var row: ZPDFPersistence.MarkupRecord
        var values: [String: String]
    }

    /// One Project Zone as the index holds it: its name, on one indexed page.
    struct IndexedZone: Equatable, Sendable {
        var name: String
        var pageKey: String
        var sortOrder: Int
    }

    /// Bumped by every ``indexMarkups(_:pages:columns:zones:)`` call that writes. A call only records its rows
    /// in ``indexedMarkupRows`` if no later call started writing meanwhile: this actor is
    /// re-entrant across its awaits, and an older call finishing last must not overwrite what a
    /// newer one wrote.
    private var markupIndexGeneration: UInt64 = 0
    /// The style blob every index row carries; the index never reads it.
    private static let neutralStyleBlob: Data = (try? TakeoffStyleCodec.encode(MarkupStyle.default)) ?? Data()

    private init(
        projectKey: String,
        documentKey: String,
        databaseURL: URL,
        database: ProjectDatabaseActor,
        provider: PDFKitDocumentProvider,
        handle: DocumentHandle,
        indexedPageCount: Int
    ) {
        self.projectKey = projectKey
        self.documentKey = documentKey
        self.databaseURL = databaseURL
        self.database = database
        self.provider = provider
        self.handle = handle
        self.indexedPageCount = indexedPageCount
        self.indexer = TextIndexer(database: database, provider: provider)
        self.ocr = OCRService(database: database, provider: provider)
        self.service = SearchService(
            database: database,
            textBounds: PDFKitTextBoundsResolver(
                provider: provider,
                handles: [documentKey: handle]
            )
        )
    }

    // MARK: - Opening

    /// The index's stable key for one page of the drawing.
    ///
    /// Derived from the document key and the page's position, never from the session's page
    /// `UUID`, for the same reason ``documentKey`` is the file hash: page identities are minted
    /// fresh on every open of a Quick PDF, and a key that changes on every open cannot address
    /// rows written last week.
    public nonisolated static func pageKey(documentKey: String, pageIndex: Int) -> String {
        "\(documentKey)#p\(pageIndex)"
    }

    /// Opens — creating on first use — the index for one drawing.
    ///
    /// The `project`, `document` and `page` rows the indexer needs are seeded with
    /// `INSERT OR IGNORE`: a second open of the same drawing must not replace a `page` row,
    /// because replacing one deletes it first and that cascade would take its recognised tokens
    /// with it.
    ///
    /// - Parameters:
    ///   - databaseURL: the container-side index file.
    ///   - pdfURL: the drawing itself. Opened read-only through PDFKit.
    ///   - displayName: what the drawing is called, for the hit rows.
    ///   - pages: the session's pages, for labels and boxes. Their `UUID`s are *not* used as
    ///     index keys — see ``pageKey(documentKey:pageIndex:)``.
    ///   - password: the password that unlocked the drawing, memory only (BH-069). Without it a
    ///     password-protected drawing opens locked, every page reads as not permitted and the
    ///     index holds none of its text — a search of it finds nothing and says nothing (V-040).
    public static func open(
        databaseAt databaseURL: URL,
        drawingAt pdfURL: URL,
        displayName: String,
        pages: [ZPDFContracts.PageDescriptor],
        knownDigest: FileDigest? = nil,
        password: String? = nil
    ) async throws -> DocumentSearchIndex {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try await ProjectDatabaseActor.open(at: databaseURL)
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened: OpenedDocument
        do {
            // A digest the caller already verified — the package's integrity check — is not
            // recomputed: a second full hash of a 200 MB drawing on every open is pure cost
            // (IM-005). The provider still checks it is plausible for the file.
            opened = try await provider.open(.url(pdfURL), password: password, limits: .standard, knownDigest: knownDigest)
        } catch {
            // A drawing PDFKit refuses — password-protected, damaged — used to leave the index
            // database and its WAL open until the actor happened to deallocate (BH-457).
            try? await database.close()
            throw error
        }

        let sha = opened.descriptor.digest.sha256
        let documentKey = sha
        let projectKey = "zenit.search." + sha
        let name = displayName
        let relativePath = pdfURL.lastPathComponent
        let pageCount = max(pages.count, opened.descriptor.pageCount)
        let stamp = PersistenceTimestamp.string(from: Date())

        let pageRows: [PageRecord] = pages.map { page in
            PageRecord(
                id: pageKey(documentKey: documentKey, pageIndex: page.index),
                documentId: documentKey,
                pageIndex: page.index,
                pageLabel: page.label.isEmpty ? nil : page.label,
                mediaX: page.boxes.media.origin.x,
                mediaY: page.boxes.media.origin.y,
                mediaWidth: page.boxes.media.size.width,
                mediaHeight: page.boxes.media.size.height,
                cropX: page.boxes.crop.origin.x,
                cropY: page.boxes.crop.origin.y,
                cropWidth: page.boxes.crop.size.width,
                cropHeight: page.boxes.crop.size.height,
                rotation: page.rotation.rawValue
            )
        }

        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO project (id, name, created_at, modified_at, schema_version)
                    VALUES (?, ?, ?, ?, 1)
                    """,
                    arguments: [projectKey, name, stamp, stamp]
                )
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO document
                        (id, project_id, display_name, relative_path, sha256, page_count,
                         active_revision_id, created_at, modified_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)
                    """,
                    arguments: [documentKey, projectKey, name, relativePath, sha, pageCount, stamp, stamp]
                )
                // A drawing that was replaced on disk keeps its identity and gets the new hash;
                // `TextIndexer`'s stamp comparison is what then decides to re-read it.
                try db.execute(
                    sql: "UPDATE document SET sha256 = ?, page_count = ?, modified_at = ? WHERE id = ?",
                    arguments: [sha, pageCount, stamp, documentKey]
                )
                for row in pageRows {
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO page
                            (id, document_id, page_index, page_label,
                             media_x, media_y, media_width, media_height,
                             crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                        """,
                        arguments: [
                            row.id, row.documentId, row.pageIndex, row.pageLabel,
                            row.mediaX, row.mediaY, row.mediaWidth, row.mediaHeight,
                            row.cropX, row.cropY, row.cropWidth, row.cropHeight, row.rotation
                        ]
                    )
                }
            }
        } catch {
            await provider.closeAll()
            try? await database.close()
            throw error
        }

        return DocumentSearchIndex(
            projectKey: projectKey,
            documentKey: documentKey,
            databaseURL: databaseURL,
            database: database,
            provider: provider,
            handle: opened.handle,
            indexedPageCount: pageCount
        )
    }

    /// Closes the PDF handle and the index database. Called when the document closes.
    /// One recognised word and its page-space box.
    public struct RecognisedWord: Sendable, Hashable {
        public let text: String
        public let bounds: CGRect
        /// The recogniser's confidence for the word, `0…1` (NL-AUTO-03), so a reader
        /// such as the dimension check can stay silent on a weak read instead of treating it as
        /// the drawing's own text.
        public let confidence: Double

        public init(text: String, bounds: CGRect, confidence: Double = 1) {
            self.text = text
            self.bounds = bounds
            self.confidence = confidence
        }
    }

    /// Every recognised word of the drawing, by page index, in reading order (NL-PDF-13's
    /// searchable copy).
    public func recognisedWords() async throws -> [Int: [RecognisedWord]] {
        try await ocr.recognisedTokens(documentId: documentKey).mapValues { tokens in
            tokens.map { RecognisedWord(text: $0.text, bounds: $0.bounds, confidence: $0.confidence) }
        }
    }

    /// The recognised words of one page, in reading order — that page's rows only, for a reader
    /// of one sheet (U-015).
    public func recognisedWords(onPage pageIndex: Int) async throws -> [RecognisedWord] {
        try await ocr.recognisedTokens(documentId: documentKey, pageIndex: pageIndex).map {
            RecognisedWord(text: $0.text, bounds: $0.bounds, confidence: $0.confidence)
        }
    }

    public func shutDown() async {
        await provider.closeAll()
        try? await database.close()
    }

    // MARK: - Deleting the index (spec 17.4, V-079)

    /// Deletes everything this drawing's index holds — the drawing's text, the markup and zone
    /// rows, and every word text recognition read off its sheets — and purges it from the file.
    ///
    /// Spec 17.4: the index can be deleted and rebuilt. The drawing's own text and the
    /// markups are the caller's to index again (``indexDrawingText(force:)``,
    /// ``indexMarkups(_:pages:columns:zones:)``); recognised text is gone until recognition is
    /// run again. The markup cache is forgotten and the generation moves on, so a markup
    /// re-index already in flight records nothing and the next one rebuilds every row.
    ///
    /// - Returns: the full-text rows and the recognised words removed.
    @discardableResult
    public func deleteIndexAndRecognisedText() async throws -> (rows: Int, recognisedWords: Int) {
        markupIndexGeneration &+= 1
        indexedMarkupRows = nil
        indexedZoneRows = nil
        let removed = try await indexer.removeProjectIndexReportingTokens(projectId: projectKey)
        return (removed.rows, removed.recognisedTokens)
    }

    // MARK: - The identity map

    /// The map ``AppSearchPresenter`` resolves hits through.
    ///
    /// `currentPageKey` is what the "This page" scope means; the caller updates it as the canvas
    /// changes page.
    public nonisolated func identityMap(
        documentUUID: UUID,
        documentTitle: String,
        pages: [ZPDFContracts.PageDescriptor],
        currentPageIndex: Int
    ) -> SearchIdentityMap {
        var map = SearchIdentityMap()
        map.register(documentKey: documentKey, id: documentUUID, title: documentTitle)
        for page in pages {
            map.register(
                pageKey: Self.pageKey(documentKey: documentKey, pageIndex: page.index),
                id: page.id.rawValue,
                index: page.index,
                label: page.label
            )
        }
        map.currentDocumentKey = documentKey
        map.currentPageKey = Self.pageKey(documentKey: documentKey, pageIndex: currentPageIndex)
        return map
    }

    // MARK: - Filling the index

    /// Reads the drawing's own text layer into the index.
    ///
    /// Incremental: a drawing whose SHA-256 already matches the stored stamp is skipped, so
    /// reopening a 400-page set costs one hash comparison.
    @discardableResult
    public func indexDrawingText(force: Bool = false) async throws -> TextIndexReport {
        try await indexer.indexDocumentText(documentId: documentKey, handle: handle, force: force)
    }

    /// Rebuilds the markup half of the index from the session's own markups.
    ///
    /// The rows written here are a **projection for searching**, not a takeoff: subject, label,
    /// comment and the geometry a hit is highlighted with. Scale, zone and Scale Region
    /// references are deliberately dropped — the index database holds no scales to point at, and
    /// a dangling reference is a foreign-key failure, not a search result.
    ///
    /// The Search panel's **Custom Fields** source reads two more things, written here since
    /// S-035: each markup's text and choice ledger values (`columns` names a Choice column's
    /// options, so a choice is found by the words the ledger shows), and the names of the Project
    /// Zones drawn on an indexed page. Before, nothing wrote either table into this database, and
    /// ticking only Custom Fields always found nothing.
    @discardableResult
    public func indexMarkups(
        _ markups: [ZPDFContracts.MarkupRecord],
        pages: [ZPDFContracts.PageDescriptor],
        columns: [LedgerColumnDefinition] = [],
        zones: [ProjectZoneDefinition] = []
    ) async throws -> AnnotationIndexReport {
        let documentKey = self.documentKey
        var pageIndexByID: [UUID: Int] = [:]
        for page in pages { pageIndexByID[page.id.rawValue] = page.index }
        let columnsByID = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var columnNames: [String: String] = [:]

        var rows: [ZPDFPersistence.MarkupRecord] = []
        var valuesByMarkup: [String: [String: String]] = [:]
        rows.reserveCapacity(markups.count)
        for record in markups {
            guard let pageIndex = pageIndexByID[record.pageID.rawValue],
                  pageIndex < indexedPageCount else { continue }
            let pageKey = Self.pageKey(documentKey: documentKey, pageIndex: pageIndex)
            var values: [String: String] = [:]
            for (columnID, value) in record.customValues {
                guard let text = Self.searchableText(value, column: columnsByID[columnID]) else { continue }
                let key = columnID.rawValue.uuidString
                values[key] = text
                columnNames[key] = columnsByID[columnID].map(LedgerBridge.title(of:)) ?? key
            }
            let hasText = !record.subject.isEmpty || !record.label.isEmpty || !record.comment.isEmpty || !values.isEmpty
            guard hasText else { continue }
            if !values.isEmpty { valuesByMarkup[record.id.rawValue.uuidString] = values }
            // Search reads the geometry for one thing only — the hit's bounding rectangle — so
            // the index stores that rectangle, not every vertex of every markup (IM-057). A
            // vertex drag that leaves the box where it was no longer changes the row.
            let geometry = try TakeoffGeometryCodec.encode(record.geometry?.bounds.map { box in
                MeasurementGeometry(
                    pageID: record.pageID,
                    points: [PDFPoint(x: box.minX, y: box.minY), PDFPoint(x: box.maxX, y: box.maxY)]
                )
            })
            rows.append(
                ZPDFPersistence.MarkupRecord(
                    id: record.id.rawValue.uuidString,
                    documentId: documentKey,
                    pageId: pageKey,
                    type: record.tool?.rawValue ?? record.kind.rawValue,
                    subject: record.subject,
                    label: record.label.isEmpty ? nil : record.label,
                    comment: record.comment.isEmpty ? nil : record.comment,
                    geometryBlob: geometry.blob,
                    // Search reads the id, the page, the three text fields and the bounding box
                    // and nothing else. The columns it never reads hold constants, so a style,
                    // status or lock change — which bumps nothing a search can find — leaves the
                    // row identical and the re-index skips it (IM-057).
                    styleBlob: Self.neutralStyleBlob,
                    scaleId: nil,
                    scaleVersion: nil,
                    scaleRegionId: nil,
                    zoneId: nil,
                    layerName: nil,
                    status: nil,
                    author: nil,
                    locked: false,
                    hidden: false,
                    createdAt: PersistenceTimestamp.string(from: record.createdAt),
                    modifiedAt: PersistenceTimestamp.string(from: record.createdAt),
                    revision: 1
                )
            )
        }

        var byID: [String: IndexedMarkup] = [:]
        for row in rows { byID[row.id] = IndexedMarkup(row: row, values: valuesByMarkup[row.id] ?? [:]) }

        var zoneRows: [String: IndexedZone] = [:]
        for zone in zones {
            guard let pageID = zone.pageID, let pageIndex = pageIndexByID[pageID.rawValue], pageIndex < indexedPageCount,
                  !zone.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            zoneRows[zone.id.rawValue.uuidString] = IndexedZone(
                name: zone.name, pageKey: Self.pageKey(documentKey: documentKey, pageIndex: pageIndex), sortOrder: zone.sortOrder
            )
        }

        let previous = indexedMarkupRows
        let previousZones = indexedZoneRows
        let zonesChanged = previousZones != zoneRows
        var removed: [String] = []
        var changed: [IndexedMarkup] = []
        if let previous, previousZones != nil {
            // Incremental: only the rows that differ are rewritten, and a re-index that changed
            // no searchable row — a style edit, a vertex nudge inside the same box, a status
            // change — writes nothing and rebuilds no full-text rows (IM-057).
            removed = previous.keys.filter { byID[$0] == nil }
            changed = byID.values.filter { previous[$0.row.id] != $0 }
            guard !removed.isEmpty || !changed.isEmpty || zonesChanged else {
                return AnnotationIndexReport(
                    projectId: projectKey, rowsDeleted: 0, markupRowsInserted: 0,
                    customValueRowsInserted: 0, zoneRowsInserted: 0
                )
            }
        }

        // From the first write until the full-text rows match it, nothing is known: any throw
        // below — above all a cancellation between the markup commit and the rebuild, which a
        // new edit causes routinely — leaves `nil`, and the next call rebuilds everything
        // instead of trusting rows whose search entries were never written (R-152 re-fix).
        markupIndexGeneration &+= 1
        let generation = markupIndexGeneration
        indexedMarkupRows = nil
        indexedZoneRows = nil

        let projectKey = self.projectKey
        let names = columnNames
        let report: AnnotationIndexReport
        if previous != nil, previousZones != nil {
            let deletions = removed
            let upserts = changed
            let zoneWrite = zonesChanged ? zoneRows : nil
            try await database.write { db in
                for id in deletions {
                    try db.execute(sql: "DELETE FROM custom_value WHERE markup_id = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM markup WHERE id = ?", arguments: [id])
                }
                for entry in upserts {
                    try entry.row.save(db)
                    try db.execute(sql: "DELETE FROM custom_value WHERE markup_id = ?", arguments: [entry.row.id])
                    try Self.insertValues(entry, names: names, projectKey: projectKey, db: db)
                }
                if let zoneWrite { try Self.replaceZones(zoneWrite, documentKey: documentKey, db: db) }
            }
            // Only the markups that changed get their full-text rows rebuilt (R-152), custom
            // values with them; a zone change rebuilds the project's rows, zones included.
            if zonesChanged {
                report = try await indexer.indexProjectAnnotations(projectId: projectKey)
            } else {
                report = try await indexer.indexAnnotations(projectId: projectKey, markupIds: removed + changed.map(\.row.id))
            }
        } else {
            let insert = byID.values.sorted { $0.row.id < $1.row.id }
            let zonesToWrite = zoneRows
            try await database.write { db in
                // Markups, their values and the zones. The `page` rows are left alone on purpose:
                // deleting one cascades into `ocr_token`, and a re-index of a subject line must
                // not cost a recognition run.
                try db.execute(
                    sql: "DELETE FROM custom_value WHERE markup_id IN (SELECT id FROM markup WHERE document_id = ?)",
                    arguments: [documentKey]
                )
                try db.execute(sql: "DELETE FROM markup WHERE document_id = ?", arguments: [documentKey])
                for entry in insert {
                    try entry.row.insert(db)
                    try Self.insertValues(entry, names: names, projectKey: projectKey, db: db)
                }
                try Self.replaceZones(zonesToWrite, documentKey: documentKey, db: db)
            }
            // The first build of this session, or the first after a failed one: every
            // annotation row, from scratch.
            report = try await indexer.indexProjectAnnotations(projectId: projectKey)
        }
        // Recorded only now that the tables and their full-text rows agree, and only if no
        // newer call has started writing since this one did.
        if generation == markupIndexGeneration {
            indexedMarkupRows = byID
            indexedZoneRows = zoneRows
        }
        return report
    }

    /// The words a ledger value is found by in Search: a text cell's text, a choice cell's option
    /// as the ledger shows it. Numbers, money, dates and ticks are not words a person searches for.
    static func searchableText(_ value: ZPDFContracts.LedgerCellValue, column: LedgerColumnDefinition?) -> String? {
        let text: String?
        switch value {
        case .text(let words):
            text = words
        case .choice(let id):
            text = column.flatMap { definition in
                definition.choices.first { $0.id == id }.map { LedgerBridge.choiceTitle($0.value, in: definition) }
            }
        default:
            text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// One markup's custom values, each under the `custom_column` row its foreign key needs. The
    /// index never reads that row beyond its identity; its name is kept for diagnostics.
    private static func insertValues(_ entry: IndexedMarkup, names: [String: String], projectKey: String, db: Database) throws {
        for (columnKey, text) in entry.values.sorted(by: { $0.key < $1.key }) {
            try db.execute(
                sql: "INSERT OR IGNORE INTO custom_column (id, project_id, name, type, sort_order) VALUES (?, ?, ?, 'text', 0)",
                arguments: [columnKey, projectKey, names[columnKey] ?? columnKey]
            )
            try db.execute(
                sql: "INSERT OR REPLACE INTO custom_value (markup_id, column_id, value_text) VALUES (?, ?, ?)",
                arguments: [entry.row.id, columnKey, text]
            )
        }
    }

    /// This drawing's zone rows, replaced by `zones`. Search reads only the name and the page.
    private static func replaceZones(_ zones: [String: IndexedZone], documentKey: String, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM project_zone WHERE page_id IN (SELECT id FROM page WHERE document_id = ?)",
            arguments: [documentKey]
        )
        for (id, zone) in zones.sorted(by: { $0.key < $1.key }) {
            try db.execute(
                sql: "INSERT OR REPLACE INTO project_zone (id, page_id, name, polygon_blob, sort_order, color_rgba) VALUES (?, ?, ?, ?, ?, 0)",
                arguments: [id, zone.pageKey, zone.name, Data(), zone.sortOrder]
            )
        }
    }

    // MARK: - Recognition

    /// The languages this Mac can recognise, most useful first.
    public nonisolated static func supportedRecognitionLanguages() -> [String] {
        OCRService.supportedRecognitionLanguages(accurate: true)
    }

    /// What one recognised page came back with, in vocabulary the app tier can use without
    /// importing `ZPDFSearch`.
    public struct RecognizedPage: Sendable, Hashable {
        /// Zero-based page position. The caller maps it back to its own page identity; the index's
        /// page key is deliberately not a session `UUID` (see ``pageKey(documentKey:pageIndex:)``).
        public let pageIndex: Int
        /// Words written into the index for this page.
        public let tokenCount: Int
        /// Mean recognition confidence, `0...1`, or `nil` when nothing was read.
        public let averageConfidence: Double?
        /// Set when the page was deliberately not read — it already carried real text, or it was
        /// blank. A skipped page is reported, never silently counted as done.
        public let skipReason: String?

        public init(
            pageIndex: Int,
            tokenCount: Int,
            averageConfidence: Double?,
            skipReason: String?
        ) {
            self.pageIndex = pageIndex
            self.tokenCount = tokenCount
            self.averageConfidence = averageConfidence
            self.skipReason = skipReason
        }
    }

    /// Runs recognition over a set of pages, reporting each page as it is committed.
    ///
    /// Pages are grouped into contiguous runs so a selection like `1-4, 9` is two engine calls
    /// rather than five. Each page is committed in its own transaction inside the engine, so
    /// cancelling leaves every reported page fully searchable and no page half-written.
    ///
    /// - Returns: the pages that were read, in document order.
    @discardableResult
    public func recognize(
        pageIndices: [Int],
        languageIDs: [String],
        skipsPagesWithText: Bool,
        progress: @escaping @Sendable (RecognizedPage) -> Void
    ) async throws -> [RecognizedPage] {
        let sorted = Array(Set(pageIndices)).sorted()
        guard !sorted.isEmpty else { return [] }

        var settings = OCRSettings.standard
        if !languageIDs.isEmpty { settings.recognitionLanguages = languageIDs }
        settings.skipsPagesWithTextLayer = skipsPagesWithText
        await ocr.update(settings: settings)

        let documentKey = self.documentKey
        let handle = self.handle
        var produced: [RecognizedPage] = []

        for range in Self.contiguousRanges(of: sorted) {
            let report = try await ocr.recognize(
                documentId: documentKey,
                handle: handle,
                pageRange: range,
                progress: { engineProgress in
                    progress(Self.recognized(engineProgress.lastPage))
                }
            )
            produced.append(contentsOf: report.pages.map(Self.recognized))
        }
        return produced.sorted { $0.pageIndex < $1.pageIndex }
    }

    private static func recognized(_ page: OCRPageResult) -> RecognizedPage {
        RecognizedPage(
            pageIndex: page.pageIndex,
            tokenCount: page.tokenCount,
            averageConfidence: page.averageConfidence,
            skipReason: page.skipReason?.rawValue
        )
    }

    /// Groups sorted, de-duplicated indices into contiguous half-open ranges.
    static func contiguousRanges(of sorted: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        var previous: Int?
        for value in sorted {
            if let last = previous, value == last + 1 {
                previous = value
                continue
            }
            if let begin = start, let last = previous {
                ranges.append(begin..<(last + 1))
            }
            start = value
            previous = value
        }
        if let begin = start, let last = previous {
            ranges.append(begin..<(last + 1))
        }
        return ranges
    }
}
