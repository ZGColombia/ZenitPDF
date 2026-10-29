import Foundation
import GRDB
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

@Suite("Text indexing")
struct TextIndexerTests {

    /// The title-block fixture, with its nine strings at exactly known baseline origins.
    private static func titleBlockURL() throws -> URL {
        try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
    }

    @Test("Every title-block string is indexed and found")
    func titleBlockStringsAreFound() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.titleBlockURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)

            let report = try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            #expect(!report.wasSkippedAsUnchanged)
            #expect(report.pagesIndexed == 1)
            #expect(report.pagesWithoutTextLayer.isEmpty)
            #expect(report.charactersIndexed > 0)

            let service = SearchService(database: bed.database)
            let manifest = try ZPDFFixtures.manifest(for: .titleBlockSheet)
            #expect(manifest.texts.count == 9)

            for text in manifest.texts {
                let results = try await service.search(
                    SearchRequest(
                        text: text.string,
                        scope: .document(projectId: bed.projectId, documentId: documentId),
                        sources: .pdfTextOnly,
                        resolvesBounds: false
                    )
                )
                #expect(
                    results.hits.count == 1,
                    "\(text.string.debugDescription) produced \(results.hits.count) hits"
                )
                let hit = try #require(results.hits.first)
                #expect(hit.sourceType == .pdfText)
                #expect(hit.pageIndex == 0)
                #expect(hit.pageLabel == "1")
                #expect(hit.ocrConfidence == nil)
                #expect(!hit.isLowConfidenceOCR)
            }
        }
    }

    @Test("A title-block hit carries the page-space rectangle the fixture declares")
    func titleBlockHitCarriesBounds() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.titleBlockURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexDocumentText(documentId: documentId, handle: handle)

            let resolver = PDFKitTextBoundsResolver(
                provider: bed.provider,
                handles: [documentId: handle]
            )
            let service = SearchService(database: bed.database, textBounds: resolver)

            // `DRAWING NO ZP-0001` is drawn with its baseline origin at (1152, 204) in the
            // fixture manifest, inside the title block [1128 36 1692 288].
            let expected = try #require(
                try ZPDFFixtures.manifest(for: .titleBlockSheet).texts
                    .first { $0.id == "drawing-number" }
            )
            #expect(expected.origin.y == 204)

            let results = try await service.search(
                SearchRequest(
                    text: "\"DRAWING NO\"",
                    scope: .page(
                        projectId: bed.projectId,
                        pageId: bed.pageId(documentId: documentId, pageIndex: 0)
                    ),
                    sources: .pdfTextOnly
                )
            )
            let hit = try #require(results.hits.first)
            #expect(hit.boundsSource == .pageText)
            #expect(!hit.bounds.isEmpty)

            let union = hit.bounds.dropFirst().reduce(hit.bounds[0]) { $0.union($1) }
            // The glyph box sits on the baseline the manifest records, within the ascent
            // and descent of 12-point Helvetica.
            #expect(union.minY >= expected.origin.y - 4)
            #expect(union.minY <= expected.origin.y + 4)
            #expect(union.minX >= expected.origin.x - 2)
            #expect(union.minX <= expected.origin.x + 4)
            // And inside the title block the fixture declares.
            #expect(union.minX >= 1128)
            #expect(union.maxX <= 1692)
        }
    }

    @Test("Matching ignores case and diacritics in both directions")
    func caseAndDiacriticInsensitivity() async throws {
        try await withSearchTestBed { bed in
            let markupId = try await bed.addMarkupOnSyntheticPage(
                subject: "KÖK OCH FÖRRÅD",
                label: "Överbyggnad",
                comment: "Städskåp vid entrén"
            )
            #expect(!markupId.isEmpty)

            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            let report = try await indexer.indexProjectAnnotations(projectId: bed.projectId)
            #expect(report.markupRowsInserted == 3)

            let service = SearchService(database: bed.database)
            // Folded query against accented content, and the reverse.
            for (query, expectedType) in [
                ("kok", SearchSourceType.markupSubject),
                ("KÖK", SearchSourceType.markupSubject),
                ("kök", SearchSourceType.markupSubject),
                ("FORRAD", SearchSourceType.markupSubject),
                ("overbyggnad", SearchSourceType.markupLabel),
                ("ÖVERBYGGNAD", SearchSourceType.markupLabel),
                ("stadskap", SearchSourceType.markupComment),
                ("ENTREN", SearchSourceType.markupComment)
            ] {
                let results = try await service.search(
                    SearchRequest(
                        text: query,
                        scope: .project(projectId: bed.projectId),
                        resolvesBounds: false
                    )
                )
                #expect(results.hits.count == 1, "\(query) produced \(results.hits.count) hits")
                #expect(results.hits.first?.sourceType == expectedType)
            }
        }
    }

    @Test("A second index run over an unchanged document does nothing")
    func incrementalSkipsUnchangedDocuments() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.titleBlockURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)

            let first = try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            #expect(!first.wasSkippedAsUnchanged)
            #expect(first.rowsInserted == 1)
            let afterFirst = try await bed.indexRowCount(documentId: documentId)

            let second = try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            #expect(second.wasSkippedAsUnchanged)
            #expect(second.rowsInserted == 0)
            #expect(second.rowsDeleted == 0)
            #expect(try await bed.indexRowCount(documentId: documentId) == afterFirst)

            // The stamp is the document's own SHA, not a fabricated token.
            let recorded = try await indexer.indexedSHA(documentId: documentId)
            let sha = try await bed.database.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT sha256 FROM document WHERE id = ?",
                    arguments: [documentId]
                )
            }
            #expect(recorded == sha)
        }
    }

    @Test("Reindexing does not duplicate rows, forced or SHA-driven")
    func reindexNeverDuplicates() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.titleBlockURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)

            try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            let baselineTextRows = try await bed.indexRowCount(
                sourceType: .pdfText,
                documentId: documentId
            )
            let baselineStamps = try await bed.indexRowCount(
                sourceType: .indexStamp,
                documentId: documentId
            )
            #expect(baselineTextRows == 1)
            #expect(baselineStamps == 1)

            // Forced.
            for _ in 0..<3 {
                let report = try await indexer.indexDocumentText(
                    documentId: documentId,
                    handle: handle,
                    force: true
                )
                #expect(!report.wasSkippedAsUnchanged)
                #expect(report.rowsDeleted == baselineTextRows + baselineStamps)
            }
            #expect(
                try await bed.indexRowCount(sourceType: .pdfText, documentId: documentId)
                    == baselineTextRows
            )
            #expect(
                try await bed.indexRowCount(sourceType: .indexStamp, documentId: documentId)
                    == baselineStamps
            )

            // SHA-driven: the file "changed", so the next run reindexes rather than skips.
            try await bed.setDocumentSHA(String(repeating: "a", count: 64), documentId: documentId)
            let afterChange = try await indexer.indexDocumentText(
                documentId: documentId,
                handle: handle
            )
            #expect(!afterChange.wasSkippedAsUnchanged)
            #expect(
                try await bed.indexRowCount(sourceType: .pdfText, documentId: documentId)
                    == baselineTextRows
            )
            #expect(try await indexer.indexedSHA(documentId: documentId) == String(repeating: "a", count: 64))

            // And a search still returns exactly one hit, not four.
            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: .project(projectId: bed.projectId),
                    resolvesBounds: false
                )
            )
            #expect(results.hits.count == 1)
        }
    }

    @Test("Annotation reindexing is idempotent too")
    func annotationReindexNeverDuplicates() async throws {
        try await withSearchTestBed { bed in
            let markupId = try await bed.addMarkupOnSyntheticPage(
                subject: "DOOR SCHEDULE",
                label: "D-01",
                comment: "Fire rated"
            )
            try await bed.addCustomValue(markupId: markupId, columnName: "Trade", value: "CARPENTRY")

            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            let first = try await indexer.indexProjectAnnotations(projectId: bed.projectId)
            #expect(first.markupRowsInserted == 3)
            #expect(first.customValueRowsInserted == 1)
            #expect(first.rowsDeleted == 0)
            let total = try await bed.indexRowCount()

            for _ in 0..<3 {
                let again = try await indexer.indexProjectAnnotations(projectId: bed.projectId)
                #expect(again.rowsDeleted == 4)
                #expect(again.rowsInserted == 4)
            }
            #expect(try await bed.indexRowCount() == total)
        }
    }

    @Test("A scanned page contributes nothing to the text index and is reported as such")
    func scannedPageHasNoTextLayer() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(
                .scannedLookPage,
                in: SearchTestBed.fixtureDirectory
            ).url
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)

            let report = try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            #expect(report.pagesIndexed == 0)
            #expect(report.pagesWithoutTextLayer == [0])
            #expect(report.rowsInserted == 0)
            #expect(
                try await bed.indexRowCount(sourceType: .pdfText, documentId: documentId) == 0
            )
        }
    }

    @Test("Removing the index leaves nothing behind and can be rebuilt")
    func indexCanBeDeletedAndRebuilt() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.titleBlockURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            #expect(try await bed.indexRowCount() == 2)

            let deleted = try await indexer.removeProjectIndexReportingTokens(projectId: bed.projectId).rows
            #expect(deleted == 2)
            #expect(try await bed.indexRowCount() == 0)

            // With the stamp gone, the next run is a full index again.
            let rebuilt = try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            #expect(!rebuilt.wasSkippedAsUnchanged)
            #expect(try await bed.indexRowCount() == 2)
        }
    }

    @Test("Indexing an unknown document is a typed error, not a crash")
    func unknownDocument() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.titleBlockURL()
            let (_, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            await #expect(throws: ZPDFSearchError.unknownDocument(documentId: "nope")) {
                try await indexer.indexDocumentText(documentId: "nope", handle: handle)
            }
        }
    }
}
