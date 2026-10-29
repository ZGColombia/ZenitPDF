import CoreGraphics
import Foundation
import GRDB
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

@Suite("Unified search")
struct SearchServiceTests {

    /// Writes an `ocr` index row and its tokens directly, at a chosen confidence.
    ///
    /// The recogniser's own confidence is whatever it is; the confidence *policy* has to
    /// be testable at both sides of the threshold, and that means writing the rows rather
    /// than hoping a fixture comes back at 0.42.
    private func seedRecognisedPage(
        _ bed: SearchTestBed,
        documentId: String,
        pageId: String,
        words: [String],
        confidence: Double
    ) async throws {
        let projectId = bed.projectId
        try await bed.database.write { db in
            for (index, word) in words.enumerated() {
                let rect = CGRect(x: 100 + Double(index) * 60, y: 500, width: 50, height: 12)
                let blob = try GeometryBlob(
                    kind: .rectangle,
                    points: RecognitionGeometry.corners(of: rect).map {
                        GeometryPoint(x: $0.x, y: $0.y)
                    }
                ).encode()
                try SearchIndexStore.insertOCRToken(
                    db,
                    OCRTokenRecord(
                        pageId: pageId,
                        token: word,
                        normalizedToken: ZPDFTextNormalizer.folded(word),
                        confidence: confidence,
                        boundsBlob: blob,
                        lineIndex: 0,
                        tokenIndex: index
                    )
                )
            }
            try SearchIndexStore.insert(
                db,
                SearchIndexRecord(
                    projectId: projectId,
                    documentId: documentId,
                    pageId: pageId,
                    sourceType: SearchSourceType.ocr.rawValue,
                    sourceId: pageId,
                    content: words.joined(separator: " ")
                )
            )
        }
    }

    @Test("Scopes narrow the search from project to document to page")
    func scopes() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.mixedPageSizes, in: SearchTestBed.fixtureDirectory).url
            let (documentId, _) = try await bed.addDocument(at: url)
            let otherURL = try ZPDFFixtures.make(
                .titleBlockSheet,
                in: SearchTestBed.fixtureDirectory
            ).url
            let (otherId, otherHandle) = try await bed.addDocument(at: otherURL)

            // Two recognised pages in the first document, and the real text layer of the
            // second — three places the same word can be found.
            try await seedRecognisedPage(
                bed,
                documentId: documentId,
                pageId: bed.pageId(documentId: documentId, pageIndex: 0),
                words: ["CORRIDOR", "NORTH"],
                confidence: 0.9
            )
            try await seedRecognisedPage(
                bed,
                documentId: documentId,
                pageId: bed.pageId(documentId: documentId, pageIndex: 1),
                words: ["CORRIDOR", "SOUTH"],
                confidence: 0.9
            )
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexDocumentText(documentId: otherId, handle: otherHandle)

            let service = SearchService(database: bed.database)

            let project = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: .project(projectId: bed.projectId),
                    confidence: .permissive,
                    resolvesBounds: false
                )
            )
            #expect(project.hits.count == 3)
            #expect(project.hitCountsBySource[.ocr] == 2)
            #expect(project.hitCountsBySource[.pdfText] == 1)

            let document = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: .document(projectId: bed.projectId, documentId: documentId),
                    confidence: .permissive,
                    resolvesBounds: false
                )
            )
            #expect(document.hits.count == 2)

            let page = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: .page(
                        projectId: bed.projectId,
                        pageId: bed.pageId(documentId: documentId, pageIndex: 1)
                    ),
                    confidence: .permissive,
                    resolvesBounds: false
                )
            )
            #expect(page.hits.count == 1)
            #expect(page.hits.first?.pageIndex == 1)
        }
    }

    @Test("The source filter selects exactly the sources it names")
    func sourceFilters() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(
                .titleBlockSheet,
                in: SearchTestBed.fixtureDirectory
            ).url
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexDocumentText(documentId: documentId, handle: handle)

            let markupId = try await bed.addMarkup(
                documentId: documentId,
                pageIndex: 0,
                subject: "CORRIDOR floor",
                label: "CORRIDOR label",
                comment: "CORRIDOR comment"
            )
            try await bed.addCustomValue(
                markupId: markupId,
                columnName: "Trade",
                value: "CORRIDOR trade"
            )
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)

            try await seedRecognisedPage(
                bed,
                documentId: documentId,
                pageId: bed.pageId(documentId: documentId, pageIndex: 0),
                words: ["CORRIDOR"],
                confidence: 0.95
            )

            let service = SearchService(database: bed.database)
            func count(_ filter: SearchSourceFilter) async throws -> Int {
                try await service.search(
                    SearchRequest(
                        text: "CORRIDOR",
                        scope: .project(projectId: bed.projectId),
                        sources: filter,
                        resolvesBounds: false
                    )
                ).hits.count
            }

            #expect(try await count(.all) == 6)
            #expect(try await count(.pdfTextOnly) == 1)
            #expect(try await count(.ocrOnly) == 1)
            #expect(try await count(.markups) == 3)
            #expect(try await count([.customValue]) == 1)
            #expect(try await count([.zoneName]) == 0)
        }
    }

    @Test("Recognised hits are marked, never silently mixed with real text hits")
    func confidencePolicy() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(
                .titleBlockSheet,
                in: SearchTestBed.fixtureDirectory
            ).url
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexDocumentText(documentId: documentId, handle: handle)

            // One confident recognised page and one doubtful one, on a second document so
            // the real text layer stays untouched.
            let scannedURL = try ZPDFFixtures.make(
                .scannedLookPage,
                in: SearchTestBed.fixtureDirectory
            ).url
            let (scannedId, _) = try await bed.addDocument(at: scannedURL)
            try await seedRecognisedPage(
                bed,
                documentId: scannedId,
                pageId: bed.pageId(documentId: scannedId, pageIndex: 0),
                words: ["CORRIDOR"],
                confidence: 0.31
            )

            let service = SearchService(database: bed.database)
            let scope = SearchScope.project(projectId: bed.projectId)

            // Marked, and still returned.
            let marked = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: scope,
                    confidence: OCRConfidencePolicy(threshold: 0.5, handling: .mark)
                )
            )
            #expect(marked.hits.count == 2)
            #expect(marked.lowConfidenceOCRHitCount == 1)
            #expect(marked.excludedLowConfidenceOCRHitCount == 0)

            let recognised = try #require(marked.hits.first { $0.sourceType == .ocr })
            #expect(recognised.isLowConfidenceOCR)
            #expect(recognised.ocrConfidence == 0.31)
            #expect(recognised.sourceType == .ocr)

            let verbatim = try #require(marked.hits.first { $0.sourceType == .pdfText })
            #expect(!verbatim.isLowConfidenceOCR)
            #expect(verbatim.ocrConfidence == nil, "a real text layer has no confidence")
            #expect(verbatim.sourceType != .ocr)

            // Excluded.
            let strict = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: scope,
                    confidence: OCRConfidencePolicy(threshold: 0.5, handling: .exclude)
                )
            )
            #expect(strict.hits.count == 1)
            #expect(strict.hits.allSatisfy { $0.sourceType != .ocr })
            #expect(strict.excludedLowConfidenceOCRHitCount == 1)
            #expect(strict.lowConfidenceOCRHitCount == 0)

            // Below the bar only relative to the bar: lower it and the same hit is fine.
            let permissive = try await service.search(
                SearchRequest(text: "CORRIDOR", scope: scope, confidence: .permissive)
            )
            #expect(permissive.hits.count == 2)
            #expect(permissive.lowConfidenceOCRHitCount == 0)
        }
    }

    @Test("Phrase, prefix and boolean queries behave as the syntax promises")
    func querySyntaxEndToEnd() async throws {
        try await withSearchTestBed { bed in
            let markupA = try await bed.addMarkupOnSyntheticPage(
                subject: "ROOM 101 FINISH SCHEDULE",
                label: "north wing"
            )
            let markupB = try await bed.addMarkupOnSyntheticPage(
                subject: "101 ROOM inverted order",
                label: "south wing"
            )
            #expect(markupA != markupB)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)

            let service = SearchService(database: bed.database)
            let scope = SearchScope.project(projectId: bed.projectId)
            func hits(_ text: String) async throws -> [SearchHit] {
                try await service.search(
                    SearchRequest(text: text, scope: scope, resolvesBounds: false)
                ).hits
            }

            // Implied AND finds both, in either word order.
            #expect(try await hits("ROOM 101").count == 2)
            // The phrase only matches the one where the words are adjacent and in order.
            #expect(try await hits("\"ROOM 101\"").count == 1)
            #expect(try await hits("\"101 ROOM\"").count == 1)
            // Prefix.
            #expect(try await hits("SCHED*").count == 1)
            #expect(try await hits("wing").count == 2)
            #expect(try await hits("win*").count == 2)
            // Boolean.
            #expect(try await hits("north OR south").count == 2)
            #expect(try await hits("ROOM NOT inverted").count == 1)
            #expect(try await hits("FINISH AND SCHEDULE").count == 1)
        }
    }

    @Test("Results are ranked, and a markup hit carries its geometry as bounds")
    func rankingAndMarkupBounds() async throws {
        try await withSearchTestBed { bed in
            // A short, dense label and a long, diluted comment. bm25 prefers the short one.
            let dense = try await bed.addMarkupOnSyntheticPage(
                subject: "SLAB",
                rect: CGRect(x: 12, y: 34, width: 56, height: 78)
            )
            _ = try await bed.addMarkupOnSyntheticPage(
                subject: String(repeating: "general note ", count: 60) + "SLAB"
            )
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)

            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(text: "SLAB", scope: .project(projectId: bed.projectId))
            )
            #expect(results.hits.count == 2)
            // Sorted ascending: the better match comes first.
            #expect(results.hits[0].rank <= results.hits[1].rank)
            #expect(results.hits[0].sourceId == dense)

            let best = results.hits[0]
            #expect(best.boundsSource == .markupGeometry)
            #expect(best.bounds == [CGRect(x: 12, y: 34, width: 56, height: 78)])
            #expect(best.pageLabel == "A-101")
            #expect(best.snippet.contains("SLAB"))
        }
    }

    @Test("An empty or unmatchable query returns no hits and no error")
    func emptyQueries() async throws {
        try await withSearchTestBed { bed in
            try await bed.addMarkupOnSyntheticPage(subject: "ANYTHING")
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)

            let service = SearchService(database: bed.database)
            for text in ["", "   ", "((("] {
                let results = try await service.search(
                    SearchRequest(text: text, scope: .project(projectId: bed.projectId))
                )
                #expect(results.isEmpty)
                #expect(results.query.isEmpty)
            }
            // An empty source filter is also an answer, not an error.
            let none = try await service.search(
                SearchRequest(
                    text: "ANYTHING",
                    scope: .project(projectId: bed.projectId),
                    sources: []
                )
            )
            #expect(none.isEmpty)
        }
    }

    @Test("The hit limit truncates and says so")
    func truncation() async throws {
        try await withSearchTestBed { bed in
            for index in 0..<25 {
                try await bed.addMarkupOnSyntheticPage(subject: "BEAM \(index)")
            }
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)

            let service = SearchService(database: bed.database)
            let limited = try await service.search(
                SearchRequest(
                    text: "BEAM",
                    scope: .project(projectId: bed.projectId),
                    maximumHits: 10,
                    resolvesBounds: false
                )
            )
            #expect(limited.hits.count == 10)
            #expect(limited.wasTruncated)

            let full = try await service.search(
                SearchRequest(
                    text: "BEAM",
                    scope: .project(projectId: bed.projectId),
                    maximumHits: 100,
                    resolvesBounds: false
                )
            )
            #expect(full.hits.count == 25)
            #expect(!full.wasTruncated)
        }
    }

    @Test("The index-stamp row is never a search result")
    func stampsAreInvisible() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(
                .titleBlockSheet,
                in: SearchTestBed.fixtureDirectory
            ).url
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexDocumentText(documentId: documentId, handle: handle)

            let sha = try #require(try await indexer.indexedSHA(documentId: documentId))
            #expect(sha.count == 64)

            // Searching for the stamp's own content finds nothing, even with every source
            // selected: `index-stamp` is not a member of `SearchSourceFilter`.
            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(
                    text: sha,
                    scope: .project(projectId: bed.projectId),
                    sources: .all,
                    resolvesBounds: false
                )
            )
            #expect(results.isEmpty)

            // But the statistics do count it, because that is bookkeeping and not a hit.
            let statistics = try await service.statistics(projectId: bed.projectId)
            #expect(statistics.indexedDocumentCount == 1)
            #expect(statistics.rowCountsBySource[.pdfText] == 1)
        }
    }

    @Test("Project-wide search over a populated index, timed")
    func projectSearchTiming() async throws {
        try await withSearchTestBed { bed in
            // A populated index: 2 000 markup rows and 400 recognised pages, which is the
            // shape of a mid-sized takeoff rather than a toy.
            let markupCount = 2_000
            let recognisedPageCount = 400
            let projectId = bed.projectId

            let documentId = "document-bulk"
            let now = "2026-08-23T00:00:00Z"
            try await bed.database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO document
                        (id, project_id, display_name, relative_path, sha256, page_count,
                         active_revision_id, created_at, modified_at)
                    VALUES (?, ?, 'bulk', 'bulk.pdf', ?, ?, NULL, ?, ?)
                    """,
                    arguments: [
                        documentId, projectId, String(repeating: "b", count: 64),
                        recognisedPageCount, now, now
                    ]
                )
                for index in 0..<recognisedPageCount {
                    try db.execute(
                        sql: """
                        INSERT INTO page
                            (id, document_id, page_index, page_label,
                             media_x, media_y, media_width, media_height,
                             crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
                        VALUES (?, ?, ?, ?, 0, 0, 612, 792, 0, 0, 612, 792, 0, NULL)
                        """,
                        arguments: ["page-\(index)", documentId, index, "A-\(100 + index)"]
                    )
                    try SearchIndexStore.insert(
                        db,
                        SearchIndexRecord(
                            projectId: projectId,
                            documentId: documentId,
                            pageId: "page-\(index)",
                            sourceType: SearchSourceType.ocr.rawValue,
                            sourceId: "page-\(index)",
                            content: "SHEET A-\(100 + index) GENERAL NOTES CORRIDOR "
                                + "ROOM \(index) FINISH SCHEDULE CONCRETE SLAB"
                        )
                    )
                }
                for index in 0..<markupCount {
                    try SearchIndexStore.insert(
                        db,
                        SearchIndexRecord(
                            projectId: projectId,
                            documentId: documentId,
                            pageId: "page-\(index % recognisedPageCount)",
                            sourceType: SearchSourceType.markupSubject.rawValue,
                            sourceId: "bulk-markup-\(index)",
                            content: "TAKEOFF ITEM \(index) WALL TYPE W\(index % 12) GYPSUM BOARD"
                        )
                    )
                }
            }

            let rows = try await bed.indexRowCount()
            #expect(rows == markupCount + recognisedPageCount)

            let service = SearchService(database: bed.database)
            // Warm the page cache so the number below measures the query, not the first
            // read of a file that was just written.
            _ = try await service.search(
                SearchRequest(
                    text: "GYPSUM",
                    scope: .project(projectId: projectId),
                    resolvesBounds: false
                )
            )

            var timings: [(String, Double, Int)] = []
            for text in ["CORRIDOR", "\"CONCRETE SLAB\"", "GYPS*", "WALL AND GYPSUM", "W7"] {
                let results = try await service.search(
                    SearchRequest(
                        text: text,
                        scope: .project(projectId: projectId),
                        maximumHits: 200,
                        resolvesBounds: false
                    )
                )
                timings.append((text, results.elapsedSeconds, results.hits.count))
                #expect(!results.hits.isEmpty, "\(text) found nothing")
            }

            print(
                "[ZPDFSearch timing] project search over \(rows) indexed rows "
                    + "(\(recognisedPageCount) recognised pages, \(markupCount) markups):"
            )
            for (text, seconds, count) in timings {
                print(
                    "    \(text.padding(toLength: 20, withPad: " ", startingAt: 0)) "
                        + "\(String(format: "%7.2f", seconds * 1000)) ms  \(count) hits"
                )
            }
            #expect(timings.allSatisfy { $0.1 < 2.0 })
        }
    }
}
