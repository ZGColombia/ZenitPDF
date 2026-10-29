import CoreGraphics
import Foundation
import os
import GRDB
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

/// Records the terms a search hands to the bounds resolver, and resolves nothing.
///
/// The point of the recorder is the *argument*: what the highlight is asked to look for
/// is the thing CR-123 and CR-140 are about, and it is not observable from the returned
/// rectangles.
private final class RecordingBoundsResolver: SearchTextBoundsResolving, Sendable {
    // `OSAllocatedUnfairLock` rather than `NSLock`: the recorder is touched from an async
    // context, and it makes the type honestly `Sendable` without an `@unchecked` claim.
    private let recorded = OSAllocatedUnfairLock(initialState: [SearchBoundsTerm]())

    var terms: [SearchBoundsTerm] { recorded.withLock { $0 } }

    func textBounds(
        documentId: String,
        pageIndex: Int,
        terms: [SearchBoundsTerm]
    ) async -> [CGRect] {
        recorded.withLock { $0.append(contentsOf: terms) }
        return []
    }
}

@Suite("Search findings CR-123 … CR-140")
struct SearchFindingsRegressionTests {

    /// Writes recognised tokens and the matching FTS row. `tokens` are laid out on one
    /// line, left to right, at consecutive `token_index`.
    private func seedRecognisedLine(
        _ bed: SearchTestBed,
        documentId: String,
        pageId: String,
        words: [String],
        confidence: Double = 0.95,
        writeTokens: Bool = true,
        content: String? = nil
    ) async throws {
        let projectId = bed.projectId
        try await bed.database.write { db in
            if writeTokens {
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
            }
            try SearchIndexStore.insert(
                db,
                SearchIndexRecord(
                    projectId: projectId,
                    documentId: documentId,
                    pageId: pageId,
                    sourceType: SearchSourceType.ocr.rawValue,
                    sourceId: pageId,
                    content: content ?? words.joined(separator: " ")
                )
            )
        }
    }

    private func recognisedTokenCount(_ bed: SearchTestBed) async throws -> Int {
        try await bed.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_token") ?? 0
        } ?? 0
    }

    // MARK: - CR-123 — the literal is what the user typed

    /// Old code: `query.highlightTerms.map { $0.tokens.joined(separator: " ") }`, so the
    /// engine was asked for `A 102` and a sheet stamped `A-102` was never highlighted.
    /// The punctuated string is the one a construction set is searched for most.
    @Test("A punctuated term keeps its source text for the highlight")
    func punctuatedTermIsSearchedLiterally() {
        let query = FTS5QueryCompiler.compile("A-102")
        let term = query.highlightTerms.first
        #expect(term?.tokens == ["A", "102"], "the index still sees two tokens")
        #expect(term?.sourceText == "A-102", "the highlight sees what was typed")
        #expect(term?.isPhrase == true)

        // A quoted phrase keeps its inside, and an ordinary word is unchanged.
        #expect(FTS5QueryCompiler.compile("\"ROOM 101\"").highlightTerms.first?.sourceText
                == "ROOM 101")
        #expect(FTS5QueryCompiler.compile("CORRIDOR").highlightTerms.first?.sourceText
                == "CORRIDOR")
    }

    /// Old code, measured at the resolver's door:
    /// `Expectation failed: (resolver.terms.map(\.text) → ["A 102"]) == (["A-102"] →
    /// ["A-102"])`.
    @Test("The bounds resolver is handed the punctuated literal, not the joined tokens")
    func resolverReceivesTheSourceText() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, handle) = try await bed.addDocument(at: url)
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexDocumentText(documentId: documentId, handle: handle)

            // A pdf-text row whose content contains both tokens, so the FTS phrase matches
            // and the pdf-text branch reaches the resolver.
            try await bed.database.write { db in
                try SearchIndexStore.insert(
                    db,
                    SearchIndexRecord(
                        projectId: bed.projectId,
                        documentId: documentId,
                        pageId: bed.pageId(documentId: documentId, pageIndex: 0),
                        sourceType: SearchSourceType.pdfText.rawValue,
                        sourceId: "\(documentId)-literal",
                        content: "SHEET A-102 GROUND FLOOR PLAN"
                    )
                )
            }

            let resolver = RecordingBoundsResolver()
            let service = SearchService(database: bed.database, textBounds: resolver)
            _ = try await service.search(
                SearchRequest(
                    text: "A-102",
                    scope: .project(projectId: bed.projectId),
                    sources: SearchSourceFilter.pdfTextOnly,
                    resolvesBounds: true
                )
            )
            #expect(resolver.terms.map(\.text) == ["A-102"])
            #expect(resolver.terms.allSatisfy { !$0.isPrefix })
        }
    }

    // MARK: - CR-140 — a prefix highlights the whole word

    /// The word-boundary expansion itself. Old code had no such step: the engine was
    /// asked for the three glyphs the user had typed and drew a box around `ROO` inside
    /// `ROOM`.
    @Test("A prefix expands to the whole words of the page that start with it")
    func prefixExpandsToWholeWords() {
        let page = "ROOM 101\nROOFING PLAN\nCORRIDOR\nroommate notes\nBROOM"
        let words = PDFKitTextBoundsResolver.wholeWords(startingWith: "ROO", in: page)
        #expect(words == ["ROOM", "ROOFING", "roommate"],
                "case-folded, in page order, no duplicates, and never mid-word: \(words)")

        // Punctuation ends a word, so a sheet number expands as one token run would.
        #expect(PDFKitTextBoundsResolver.wholeWords(startingWith: "A", in: "A-102 AREA")
                == ["A", "AREA"])
        #expect(PDFKitTextBoundsResolver.wholeWords(startingWith: "ZZZ", in: page).isEmpty)
    }

    /// And the prefix-ness reaches the resolver at all, which is what lets it expand.
    ///
    /// Old code: the protocol took `[String]`, so there was nothing to carry it —
    /// `Expectation failed: (resolver.terms.map(\.isPrefix) → [false]) == ([true] →
    /// [true])` once the field existed.
    @Test("A find-as-you-type prefix reaches the resolver marked as a prefix")
    func prefixReachesTheResolver() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, _) = try await bed.addDocument(at: url)
            try await bed.database.write { db in
                try SearchIndexStore.insert(
                    db,
                    SearchIndexRecord(
                        projectId: bed.projectId,
                        documentId: documentId,
                        pageId: bed.pageId(documentId: documentId, pageIndex: 0),
                        sourceType: SearchSourceType.pdfText.rawValue,
                        sourceId: "\(documentId)-prefix",
                        content: "ROOM 101 ROOFING PLAN"
                    )
                )
            }

            let resolver = RecordingBoundsResolver()
            let service = SearchService(database: bed.database, textBounds: resolver)
            _ = try await service.search(
                SearchRequest(
                    text: "ROO",
                    scope: .project(projectId: bed.projectId),
                    sources: SearchSourceFilter.pdfTextOnly,
                    queryOptions: .findAsYouType,
                    resolvesBounds: true
                )
            )
            #expect(resolver.terms.map(\.text) == ["ROO"])
            #expect(resolver.terms.map(\.isPrefix) == [true])
        }
    }

    // MARK: - CR-124 — a phrase is adjacency, not an OR

    /// Old code: every token of a phrase was OR-ed into one `IN (…)` and every match was
    /// highlighted, so `"ROOM 101"` boxed every ROOM and every 101 on the sheet. Measured
    /// on this page: `Expectation failed: (hit.bounds.count → 4) == 2` and
    /// `(hit.bounds.map { Int($0.minX) }.sorted() → [100, 160, 280, 460]) == [100, 160]`.
    @Test("A phrase highlights only the tokens that are adjacent and in order")
    func phraseHighlightsOnlyAdjacentTokens() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, _) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            // ROOM 101 appears once as a phrase; ROOM and 101 each appear again, apart.
            try await seedRecognisedLine(
                bed,
                documentId: documentId,
                pageId: pageId,
                words: ["ROOM", "101", "CORRIDOR", "ROOM", "205", "EXIT", "101"]
            )

            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(
                    text: "\"ROOM 101\"",
                    scope: .project(projectId: bed.projectId),
                    sources: SearchSourceFilter.ocrOnly,
                    confidence: .permissive,
                    resolvesBounds: true
                )
            )
            let hit = try #require(results.hits.first)
            #expect(hit.boundsSource == .recognisedTokens)
            #expect(hit.bounds.count == 2, "one ROOM and one 101, the adjacent pair")
            // The pair is the leftmost one: tokens 0 and 1, at x = 100 and x = 160.
            #expect(hit.bounds.map { Int($0.minX) }.sorted() == [100, 160])
        }
    }

    /// A single-token term is unaffected: it still matches everywhere it appears.
    @Test("A one-word term still highlights every occurrence")
    func singleTokenStillHighlightsEverywhere() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, _) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            try await seedRecognisedLine(
                bed,
                documentId: documentId,
                pageId: pageId,
                words: ["ROOM", "101", "CORRIDOR", "ROOM", "205"]
            )
            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(
                    text: "ROOM",
                    scope: .project(projectId: bed.projectId),
                    sources: SearchSourceFilter.ocrOnly,
                    confidence: .permissive,
                    resolvesBounds: true
                )
            )
            let hit = try #require(results.hits.first)
            #expect(hit.bounds.count == 2)
        }
    }

    // MARK: - CR-125 — an unknown confidence is not a zero confidence

    /// A recognised row whose tokens cannot be matched — a folding difference, or an
    /// `ocr_token` table cleared while the FTS rows survived, which is exactly what
    /// CR-121's `DELETE FROM page` produces.
    ///
    /// Old code: `(confidence ?? 0) < threshold` made that the worst possible confidence,
    /// so under `.strict` the hit was deleted from the result list without a word.
    /// Measured: `Expectation failed: (results.hits.count → 0) == 1`,
    /// `(results.excludedLowConfidenceOCRHitCount → 1) == 0` and
    /// `(results.unknownConfidenceOCRHitCount → 0) == 1`.
    @Test("A recognised hit with no token to measure is kept and marked unknown, not excluded")
    func unknownConfidenceIsNotZero() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, _) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            try await seedRecognisedLine(
                bed,
                documentId: documentId,
                pageId: pageId,
                words: ["CORRIDOR"],
                writeTokens: false          // the FTS row exists; the tokens do not
            )

            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: .project(projectId: bed.projectId),
                    sources: SearchSourceFilter.ocrOnly,
                    confidence: .strict,     // threshold 0.8, handling .exclude
                    resolvesBounds: true
                )
            )
            #expect(results.hits.count == 1, "an unmeasurable hit is still a hit")
            #expect(results.excludedLowConfidenceOCRHitCount == 0)
            #expect(results.lowConfidenceOCRHitCount == 0, "unknown is not low")
            #expect(results.unknownConfidenceOCRHitCount == 1)
            let hit = try #require(results.hits.first)
            #expect(hit.ocrConfidence == nil)
            #expect(hit.hasUnknownOCRConfidence)
            #expect(!hit.isLowConfidenceOCR)
        }
    }

    /// A genuinely low confidence is still low, and `.exclude` still excludes it.
    @Test("A measured low confidence is still excluded by the strict policy")
    func measuredLowConfidenceStillExcluded() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, _) = try await bed.addDocument(at: url)
            try await seedRecognisedLine(
                bed,
                documentId: documentId,
                pageId: bed.pageId(documentId: documentId, pageIndex: 0),
                words: ["CORRIDOR"],
                confidence: 0.2
            )
            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: .project(projectId: bed.projectId),
                    sources: SearchSourceFilter.ocrOnly,
                    confidence: .strict,
                    resolvesBounds: true
                )
            )
            #expect(results.hits.isEmpty)
            #expect(results.excludedLowConfidenceOCRHitCount == 1)
            #expect(results.unknownConfidenceOCRHitCount == 0)
        }
    }

    // MARK: - CR-126 — deleting the index deletes the recognised words

    /// Old code: `removeProjectIndex` deleted the FTS rows only, so every word Vision had
    /// read off every scanned sheet stayed in the file. Measured:
    /// `Expectation failed: (removal.recognisedTokens → 0) == 3` and
    /// `(statistics.recognisedTokenCount → 3) == 0`.
    @Test("Removing a project's index removes its recognised tokens as well")
    func removingTheIndexRemovesTheRecognisedText() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, _) = try await bed.addDocument(at: url)
            try await seedRecognisedLine(
                bed,
                documentId: documentId,
                pageId: bed.pageId(documentId: documentId, pageIndex: 0),
                words: ["CONFIDENTIAL", "SITE", "PLAN"]
            )
            #expect(try await recognisedTokenCount(bed) == 3)

            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            let removal = try await indexer.removeProjectIndexReportingTokens(
                projectId: bed.projectId
            )
            #expect(removal.rows > 0, "the FTS rows went, as they always did")
            #expect(removal.recognisedTokens == 3, "and so did the words themselves")
            #expect(try await recognisedTokenCount(bed) == 0)

            let statistics = try await SearchService(database: bed.database)
                .statistics(projectId: bed.projectId)
            #expect(statistics.recognisedTokenCount == 0)
            #expect(statistics.totalRowCount == 0)
        }
    }
}
