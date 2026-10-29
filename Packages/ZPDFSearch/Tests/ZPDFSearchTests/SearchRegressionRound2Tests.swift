import CoreGraphics
import Foundation
import GRDB
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

/// Regression tests for bug hunt 2 findings BH-204 … BH-210 and BH-644 … BH-649, and the
/// measurement behind improvement IM-085. Every test names the finding and, where the old
/// code produced an observable wrong answer, says what it was.
@Suite("Search fixes, round 2 (BH-204…210, BH-644…649, IM-085)", .serialized)
struct SearchRegressionRound2Tests {

    private static let ocrSettings = OCRSettings(
        recognitionLanguages: ["en-US", "sv-SE"],
        usesLanguageCorrection: false,
        usesAccurateRecognition: true,
        renderDPI: 200,
        maximumConcurrentPages: 4
    )


    /// Rectangles the real resolver draws for `terms` on page 0 of a one-page sheet.
    private func resolve(
        _ bed: SearchTestBed,
        lines: [String],
        terms: [SearchBoundsTerm],
        name: String
    ) async throws -> (rects: [CGRect], queries: [String]) {
        let url = try TextSheetFixture.write(pages: [lines], into: bed.directory, name: name)
        let (documentId, handle) = try await bed.addDocument(at: url)
        let provider = InstrumentedProvider(base: bed.provider)
        let resolver = PDFKitTextBoundsResolver(provider: provider, handles: [documentId: handle])
        let rects = await resolver.textBounds(documentId: documentId, pageIndex: 0, terms: terms)
        return (rects, provider.searchQueries)
    }

    private func terms(_ text: String, options: SearchQueryOptions = .standard) -> [SearchBoundsTerm] {
        FTS5QueryCompiler.compile(text, options: options).highlightTerms.map {
            SearchBoundsTerm(text: $0.sourceText, isPrefix: $0.isPrefix)
        }
    }

    // MARK: - BH-204

    /// Old output: `first.pagesNotPermitted == [0]` but `indexedSHA == <document sha>`, and
    /// the second, unforced run returned `wasSkippedAsUnchanged == true`, `rowsInserted ==
    /// 0` — the document stayed unsearchable after the provider could read it.
    @Test("BH-204: a run that could not read a page does not stamp the index as current")
    func notPermittedRunDoesNotStamp() async throws {
        try await withSearchTestBed { bed in
            let url = try TextSheetFixture.write(
                pages: [["LOCKED SHEET PAYLOAD"]], into: bed.directory, name: "bh204"
            )
            let (documentId, handle) = try await bed.addDocument(at: url)
            let provider = InstrumentedProvider(base: bed.provider)
            provider.rewritePageText { real in
                PageText(pageIndex: real.pageIndex, availability: .notPermitted,
                         string: "", characterCount: 0, wasTruncated: false)
            }
            let indexer = TextIndexer(database: bed.database, provider: provider)

            let first = try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            #expect(first.pagesNotPermitted == [0])
            #expect(first.rowsInserted == 0)
            #expect(try await indexer.indexedSHA(documentId: documentId) == nil)

            // The provider can read the page now; the bytes did not change.
            provider.rewritePageText(nil)
            let second = try await indexer.indexDocumentText(documentId: documentId, handle: handle)
            #expect(!second.wasSkippedAsUnchanged)
            #expect(second.rowsInserted == 1)
            #expect(try await indexer.indexedSHA(documentId: documentId) != nil)

            let found = try await SearchService(database: bed.database).search(
                SearchRequest(text: "PAYLOAD", scope: .project(projectId: bed.projectId),
                              sources: .pdfTextOnly, resolvesBounds: false)
            )
            #expect(found.hits.count == 1)
        }
    }

    // MARK: - BH-205

    /// Old output: after the second (skipping) run `ocrTokenCount() == 0` and the page's
    /// `ocr` index row was gone — the earlier recognition was silently erased.
    @Test("BH-205: a page skipped for its text layer keeps its earlier recognition")
    func skippedPageKeepsTokens() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, handle) = try await bed.addDocument(at: url)
            var eager = Self.ocrSettings
            eager.skipsPagesWithTextLayer = false
            let ocr = OCRService(database: bed.database, provider: bed.provider, settings: eager)

            let forced = try await ocr.recognize(documentId: documentId, handle: handle)
            #expect(forced.tokensWritten > 0)
            let tokensBefore = try await bed.ocrTokenCount()
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            #expect(try await bed.pagesWithOCRIndexRows() == [pageId])

            await ocr.update(settings: Self.ocrSettings)   // skip is on by default
            let skipped = try await ocr.recognize(documentId: documentId, handle: handle)
            #expect(skipped.pages.first?.skipReason == .hasTextLayer)
            #expect(try await bed.ocrTokenCount() == tokensBefore)
            #expect(try await bed.pagesWithOCRIndexRows() == [pageId])
        }
    }

    // MARK: - BH-206

    /// Old output: `sourceText == "A-102,"`, `"(ROOM)"`, `"101."`, `"*ROOM"`,
    /// `"ROOM  101"` — literals that are on no page.
    @Test("BH-206: the highlight literal drops edge punctuation and collapses spaces")
    func literalIsTrimmed() {
        let cases: [(String, String)] = [
            ("A-102,", "A-102"), ("(ROOM)", "ROOM"), ("101.", "101"), ("*ROOM", "ROOM"),
            ("\"ROOM  101\"", "ROOM 101"), ("A-102", "A-102"), ("3.5m", "3.5m")
        ]
        for (typed, expected) in cases {
            let term = FTS5QueryCompiler.compile(typed).highlightTerms.first
            #expect(term?.sourceText == expected, "\(typed) -> \(String(describing: term?.sourceText))")
        }
    }

    /// Old output: `rects.isEmpty` for `A-102,` and for `"ROOM  101"`.
    @Test("BH-206: a punctuated or double-spaced query still highlights on the page")
    func trimmedLiteralHighlights() async throws {
        try await withSearchTestBed { bed in
            let comma = try await resolve(
                bed, lines: ["SHEET A-102 GROUND FLOOR"], terms: terms("A-102,"), name: "bh206a"
            )
            #expect(comma.queries == ["A-102"])
            #expect(!comma.rects.isEmpty)

            let spaced = try await resolve(
                bed, lines: ["ROOM 101 CORRIDOR"], terms: terms("\"ROOM  101\""), name: "bh206b"
            )
            #expect(spaced.queries == ["ROOM 101"])
            #expect(!spaced.rects.isEmpty)
        }
    }

    // MARK: - BH-207

    /// Old output: `rects.count == 4` for `ROOM` (BATHROOM, ROOM, SHOWROOM, ROOMS) and
    /// `3` for `101` (101, 1010, A101).
    @Test("BH-207: an exact term boxes whole words only")
    func exactTermIsWholeWord() async throws {
        try await withSearchTestBed { bed in
            let room = try await resolve(
                bed, lines: ["BATHROOM ROOM SHOWROOM ROOMS"], terms: terms("ROOM"), name: "bh207a"
            )
            #expect(room.rects.count == 1, "\(room.rects)")

            let number = try await resolve(
                bed, lines: ["101 1010 A101"], terms: terms("101"), name: "bh207b"
            )
            #expect(number.rects.count == 1, "\(number.rects)")
        }
    }

    // MARK: - BH-208

    /// Old output: `wholeWords(startingWith: "A-10", …) == []`, and the engine was asked for
    /// the substring `A-10` — a box around the first four glyphs of `A-102`.
    @Test("BH-208: a punctuated prefix highlights the whole sheet number")
    func punctuatedPrefixExpands() async throws {
        #expect(PDFKitTextBoundsResolver.wholeWords(startingWith: "A-10", in: "A-102 A-105 A-2 B-101")
                == ["A-102", "A-105"])
        #expect(PDFKitTextBoundsResolver.wholeWords(startingWith: "3.5", in: "3.50 m and 3.5 m")
                == ["3.50", "3.5"])

        try await withSearchTestBed { bed in
            let result = try await resolve(
                bed,
                lines: ["SHEET A-102 GROUND FLOOR"],
                terms: terms("A-10", options: .findAsYouType),
                name: "bh208"
            )
            #expect(result.queries == ["A-102"])
            #expect(result.rects.count == 1)

            // Nothing on the page completes the prefix: no partial-glyph fallback search.
            let none = try await resolve(
                bed,
                lines: ["SHEET A-1 GROUND FLOOR"],
                terms: terms("A-1X", options: .findAsYouType),
                name: "bh208b"
            )
            #expect(none.queries.isEmpty)
            #expect(none.rects.isEmpty)
        }
    }

    // MARK: - BH-209

    /// Old output: `queries.count == 60` — one engine page search per distinct word that
    /// starts with `1`.
    @Test("BH-209: a one-character prefix is capped in engine searches")
    func prefixFanOutIsCapped() async throws {
        try await withSearchTestBed { bed in
            let words = (100..<160).map(String.init)
            let lines = stride(from: 0, to: words.count, by: 10).map {
                words[$0..<min($0 + 10, words.count)].joined(separator: " ")
            }
            let result = try await resolve(
                bed, lines: lines, terms: terms("1", options: .findAsYouType), name: "bh209"
            )
            #expect(result.queries.count == PDFKitTextBoundsResolver.defaultMaximumWordsPerPrefix)
            #expect(result.queries == Array(words.prefix(PDFKitTextBoundsResolver.defaultMaximumWordsPerPrefix)))
            #expect(result.rects.count == PDFKitTextBoundsResolver.defaultMaximumWordsPerPrefix)
        }
    }

    // MARK: - BH-210

    /// Old output: `hits.count == 0`, `wasTruncated == true` — the four best-ranked rows
    /// were all below 0.8 and the confident ones ranked after them were never read.
    @Test("BH-210: the strict policy backfills past excluded rows")
    func exclusionBackfills() async throws {
        try await withSearchTestBed { bed in
            let documentId = try await bed.addSyntheticDocument(pageCount: 7)
            // Short rows rank first under bm25, whatever their confidence.
            for index in 0..<4 {
                try await bed.seedRecognisedPage(documentId: documentId, pageIndex: index,
                                                 words: ["ROOM"], confidence: 0.3)
            }
            for index in 4..<7 {
                try await bed.seedRecognisedPage(
                    documentId: documentId, pageIndex: index,
                    words: ["ROOM", "CORRIDOR", "STAIR", "LOBBY", "OFFICE", "PLANT"],
                    confidence: 0.95
                )
            }
            let service = SearchService(database: bed.database)

            let two = try await service.search(
                SearchRequest(text: "ROOM", scope: .project(projectId: bed.projectId),
                              sources: .ocrOnly, confidence: .strict, maximumHits: 2)
            )
            #expect(two.hits.count == 2)
            #expect(two.hits.allSatisfy { ($0.ocrConfidence ?? 0) >= 0.8 })
            #expect(two.wasTruncated, "a third confident hit exists")
            #expect(two.excludedLowConfidenceOCRHitCount == 4)

            let three = try await service.search(
                SearchRequest(text: "ROOM", scope: .project(projectId: bed.projectId),
                              sources: .ocrOnly, confidence: .strict, maximumHits: 3)
            )
            #expect(three.hits.count == 3)
            #expect(!three.wasTruncated, "every confident hit is in the list")

            // The marking policy is unchanged: first rows, flagged, no backfill needed.
            let marked = try await service.search(
                SearchRequest(text: "ROOM", scope: .project(projectId: bed.projectId),
                              sources: .ocrOnly, maximumHits: 2)
            )
            #expect(marked.hits.count == 2)
            #expect(marked.wasTruncated)
        }
    }

    // MARK: - BH-644

    /// Old output: `pages.first?.skipReason == .hasTextLayer`, `tokensWritten == 0` — a
    /// layer of 40 whitespace characters counted as "enough text".
    @Test("BH-644: a whitespace-only text layer does not count as enough text")
    func whitespaceLayerIsRecognised() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(into: SearchTestBed.fixtureDirectory)
            let (documentId, handle) = try await bed.addDocument(at: url)
            let provider = InstrumentedProvider(base: bed.provider)
            let blank = String(repeating: " \n", count: 20)
            provider.rewritePageText { real in
                PageText(pageIndex: real.pageIndex, availability: .available,
                         string: blank, characterCount: blank.count, wasTruncated: false)
            }
            let ocr = OCRService(database: bed.database, provider: provider, settings: Self.ocrSettings)
            let report = try await ocr.recognize(documentId: documentId, handle: handle)
            #expect(report.pages.first?.skipReason == nil)
            #expect(report.tokensWritten > 0)
        }
    }

    // MARK: - BH-645

    /// Old output: the exact-area scale for an ARCH-D crop box at a 64 M budget renders
    /// `ceil(2592·s) x ceil(1728·s) = 9 798 x 6 532 = 64 000 536` pixels, over budget.
    @Test("BH-645: the fitted scale respects the renderer's rounding")
    func fittedScaleFitsAfterCeil() {
        let width = 2592.0, height = 1728.0, budget = 64_000_000
        let old = min(300.0 / 72.0, (Double(budget) / (width * height)).squareRoot())
        let oldPixels = (width * old).rounded(.up) * (height * old).rounded(.up)
        #expect(oldPixels > Double(budget), "the finding's arithmetic: \(oldPixels)")

        // T-069: the fit lives in the bridge, beside the render's rounding, for OCR and
        // Revision Compare alike.
        let fitted = RenderPixelSize.fittedScale(
            width: width, height: height, requested: 300.0 / 72.0, pixelBudget: budget
        )
        let pixels = (width * fitted).rounded(.up) * (height * fitted).rounded(.up)
        #expect(pixels <= Double(budget))
        #expect(fitted > old * 0.999, "not needlessly smaller: \(fitted) vs \(old)")

        // A scale under the budget is returned untouched.
        #expect(RenderPixelSize.fittedScale(width: 612, height: 792, requested: 2, pixelBudget: 64_000_000) == 2)
    }

    /// Old output: `ZPDFSearchError.pageRenderFailed(… pixelBudgetExceeded …)` thrown for
    /// the whole run — once from the rounding (settings budget == engine budget), and
    /// once because the engine's budget is below the settings'.
    @Test("BH-645: a page over the engine's own budget is scaled down, not failed")
    func engineBudgetIsHonoured() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(into: SearchTestBed.fixtureDirectory)
            for engineBudget in [1_000_000, 800_000] {
                let (documentId, handle) = try await bed.addDocument(
                    at: url, limits: DocumentLimits(maximumRenderPixels: engineBudget)
                )
                var settings = Self.ocrSettings
                settings.maximumRenderPixels = 1_000_000
                // The single-image path this finding was about. Since NL-PDF-13 a page over the
                // budget is read in tiles by default; that path is checked below.
                settings.tilesLargePages = false
                let ocr = OCRService(database: bed.database, provider: bed.provider, settings: settings)
                let report = try await ocr.recognize(documentId: documentId, handle: handle)
                let page = try #require(report.pages.first)
                #expect(page.skipReason != .notRenderable)
                let scale = page.effectiveDPI / 72
                #expect((612 * scale).rounded(.up) * (792 * scale).rounded(.up) <= Double(engineBudget))

                // Tiled (the default): every tile is refitted to the engine's budget the same
                // way, and the page is recognised, not failed.
                settings.tilesLargePages = true
                let tiled = OCRService(database: bed.database, provider: bed.provider, settings: settings)
                let tiledReport = try await tiled.recognize(documentId: documentId, handle: handle)
                #expect(tiledReport.pages.first?.skipReason != .notRenderable)
                #expect(tiledReport.tokensWritten > 0)
            }
        }
    }

    // MARK: - BH-646

    /// Old output: `matchExpression == "\"m²\""` and zero hits for `m²` / `PROﬁLE`.
    @Test("BH-646: the query is compatibility-mapped like the index")
    func queryIsCompatibilityMapped() async throws {
        #expect(FTS5QueryCompiler.compile("m²").matchExpression == "\"m2\"")
        #expect(FTS5QueryCompiler.compile("PRO\u{FB01}LE").matchExpression == "\"PROfiLE\"")

        try await withSearchTestBed { bed in
            let documentId = try await bed.addSyntheticDocument(pageCount: 1)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            let content = ZPDFTextNormalizer.indexable("AREA 12,5 m² STEEL PRO\u{FB01}LE")
            try await bed.database.write { db in
                try SearchIndexStore.insert(db, SearchIndexRecord(
                    projectId: bed.projectId, documentId: documentId, pageId: pageId,
                    sourceType: SearchSourceType.pdfText.rawValue, sourceId: pageId, content: content
                ))
            }
            let service = SearchService(database: bed.database)
            for typed in ["m²", "PRO\u{FB01}LE"] {
                let results = try await service.search(
                    SearchRequest(text: typed, scope: .project(projectId: bed.projectId), resolvesBounds: false)
                )
                #expect(results.hits.count == 1, "\(typed)")
            }
        }
    }

    // MARK: - BH-647

    /// Old output: `wholeWords == ["Room", "ROOM"]` and `rects.count == 4` — each case
    /// variant was searched case-insensitively and every box was drawn twice.
    @Test("BH-647: case variants of one word are searched and drawn once")
    func caseVariantsDeduplicated() async throws {
        #expect(PDFKitTextBoundsResolver.wholeWords(startingWith: "roo", in: "Room 101\nROOM SCHEDULE")
                == ["Room"])
        try await withSearchTestBed { bed in
            let result = try await resolve(
                bed, lines: ["Room 101", "ROOM SCHEDULE"],
                terms: terms("roo", options: .findAsYouType), name: "bh647"
            )
            #expect(result.queries.count == 1)
            #expect(result.rects.count == 2, "\(result.rects)")
            #expect(Set(result.rects.map { "\($0)" }).count == result.rects.count)
        }
    }

    // MARK: - BH-648

    /// Old output: a trap on `limit + 1` (arithmetic overflow) — the process died.
    @Test("BH-648: Int.max as 'no limit' on both sides does not trap")
    func unlimitedDoesNotTrap() async throws {
        try await withSearchTestBed { bed in
            try await bed.addMarkupOnSyntheticPage(subject: "UNLIMITED")
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)
            let service = SearchService(database: bed.database, limits: SearchLimits(maximumHits: .max))
            let results = try await service.search(
                SearchRequest(text: "UNLIMITED", scope: .project(projectId: bed.projectId), maximumHits: .max)
            )
            #expect(results.hits.count == 1)
            #expect(!results.wasTruncated)
        }
    }

    // MARK: - BH-649 and IM-085: storage reads

    /// Old: one read for the ranked rows, one for page labels, then **one serialized read
    /// per recognised hit**, each decoding every candidate's `bounds_blob` even for a
    /// `resolvesBounds: false` preview — 52 reads for 50 hits. Now: 3.
    @Test("BH-649: a bounds-free preview reads recognised confidence in one statement")
    func previewReadsAreBatched() async throws {
        try await withSearchTestBed { bed in
            let documentId = try await bed.addSyntheticDocument(pageCount: 50)
            for index in 0..<50 {
                try await bed.seedRecognisedPage(documentId: documentId, pageIndex: index,
                                                 words: ["DOOR", "D\(index)"], confidence: 0.6 + Double(index) / 200)
            }
            let service = SearchService(database: bed.database)
            let before = await service.storageReadCount
            let preview = try await service.search(
                SearchRequest(text: "DOOR", scope: .project(projectId: bed.projectId),
                              sources: .ocrOnly, maximumHits: 2000, resolvesBounds: false)
            )
            let reads = await service.storageReadCount - before
            print("[BH-649] 50 recognised hits, resolvesBounds:false -> \(reads) storage reads (old: 52)")
            #expect(preview.hits.count == 50)
            #expect(reads <= 3)
            #expect(preview.hits.allSatisfy { $0.boundsSource == .none && $0.bounds.isEmpty })
            #expect(preview.hits.allSatisfy { $0.ocrConfidence != nil && !$0.hasUnknownOCRConfidence })

            // The same confidences as the full search, which does decode the geometry.
            let full = try await service.search(
                SearchRequest(text: "DOOR", scope: .project(projectId: bed.projectId),
                              sources: .ocrOnly, maximumHits: 2000)
            )
            #expect(full.hits.map(\.ocrConfidence) == preview.hits.map(\.ocrConfidence))
            #expect(full.hits.allSatisfy { $0.boundsSource == .recognisedTokens && $0.bounds.count == 1 })
        }
    }

    /// Old: `markupBounds(markupId:)` per hit — 2 + 40 = 42 reads for 40 markup hits.
    @Test("IM-085: markup bounds are read in one statement")
    func markupBoundsAreBatched() async throws {
        try await withSearchTestBed { bed in
            var expected: [String: CGRect] = [:]
            for index in 0..<40 {
                let rect = CGRect(x: 10 + index, y: 20, width: 30, height: 40 + index)
                let id = try await bed.addMarkupOnSyntheticPage(subject: "FIRE DOOR \(index)", rect: rect)
                expected[id] = rect
            }
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)

            let service = SearchService(database: bed.database)
            let before = await service.storageReadCount
            let results = try await service.search(
                SearchRequest(text: "FIRE", scope: .project(projectId: bed.projectId),
                              sources: .markups)
            )
            let reads = await service.storageReadCount - before
            print("[IM-085] 40 markup hits with bounds -> \(reads) storage reads (old: 42)")
            #expect(results.hits.count == 40)
            #expect(reads <= 3)
            for hit in results.hits {
                #expect(hit.boundsSource == .markupGeometry)
                #expect(hit.bounds == [expected[hit.sourceId]!])
            }

            // Two-phase: list first, then bounds on demand — same rectangles, one read.
            let listed = try await service.search(
                SearchRequest(text: "FIRE", scope: .project(projectId: bed.projectId),
                              sources: .markups, resolvesBounds: false)
            )
            #expect(listed.hits.allSatisfy { $0.boundsSource == .none })
            let beforeLazy = await service.storageReadCount
            let lazy = try await service.bounds(for: listed.hits, query: listed.query)
            #expect(await service.storageReadCount - beforeLazy == 1)
            #expect(zip(listed.hits, lazy).map { $0.withBounds($1) } == results.hits.map {
                $0.withBounds(SearchHitBounds(rects: $0.bounds, source: $0.boundsSource))
            })
            #expect(lazy.map(\.rects) == results.hits.map(\.bounds))
        }
    }

    /// The headline measurement. A term present on every page of a 100-page set:
    /// `resolvesBounds: true` performs one engine page search per hit before the list can
    /// be shown; the two-phase path performs none, and one per revealed hit.
    @Test("IM-085: engine page searches before the list appears, eager vs two-phase")
    func twoPhaseSearchMeasured() async throws {
        try await withSearchTestBed { bed in
            let pageCount = 100
            let pages = (0..<pageCount).map { ["SHEET \($0 + 1) ROOM SCHEDULE", "GENERAL NOTES"] }
            let url = try TextSheetFixture.write(pages: pages, into: bed.directory, name: "im085")
            let (documentId, handle) = try await bed.addDocument(at: url)
            try await TextIndexer(database: bed.database, provider: bed.provider)
                .indexDocumentText(documentId: documentId, handle: handle)

            let provider = InstrumentedProvider(base: bed.provider)
            let service = SearchService(
                database: bed.database,
                textBounds: PDFKitTextBoundsResolver(provider: provider, handles: [documentId: handle])
            )
            let request = SearchRequest(text: "ROOM", scope: .project(projectId: bed.projectId),
                                        sources: .pdfTextOnly)

            let eagerStart = DispatchTime.now()
            let eager = try await service.search(request)
            let eagerSeconds = Double(DispatchTime.now().uptimeNanoseconds - eagerStart.uptimeNanoseconds) / 1e9
            let eagerSearches = provider.searchCount
            provider.resetSearchLog()

            var listRequest = request
            listRequest.resolvesBounds = false
            let listStart = DispatchTime.now()
            let listed = try await service.search(listRequest)
            let listSeconds = Double(DispatchTime.now().uptimeNanoseconds - listStart.uptimeNanoseconds) / 1e9
            let listSearches = provider.searchCount

            let revealed = try #require(listed.hits.first)
            let revealedBounds = try await service.bounds(for: revealed, query: listed.query)
            let revealSearches = provider.searchCount - listSearches

            print("""
            [IM-085] \(pageCount)-page set, term on every page: eager \(eagerSearches) engine searches \
            in \(String(format: "%.1f", eagerSeconds * 1000)) ms before the list; two-phase \
            \(listSearches) searches in \(String(format: "%.1f", listSeconds * 1000)) ms, then \
            \(revealSearches) for the revealed hit
            """)

            #expect(eager.hits.count == pageCount)
            #expect(eagerSearches == pageCount)
            #expect(listSearches == 0)
            #expect(revealSearches == 1)
            #expect(listed.hits.map(\.sourceId) == eager.hits.map(\.sourceId),
                    "the bounds-free list is the same list, in the same order")
            let eagerTwin = try #require(eager.hits.first { $0.sourceId == revealed.sourceId })
            #expect(revealedBounds.source == .pageText)
            #expect(revealedBounds.rects == eagerTwin.bounds)
            #expect(revealed.withBounds(revealedBounds) == eagerTwin)
        }
    }
}

extension SearchHit {
    /// The same hit carrying `bounds`, as ``SearchService/bounds(for:query:)-(SearchHit,_)``
    /// resolves them after the list was shown (IM-085). Test-only: the shipping code never
    /// rebuilt a hit this way, so the helper left the library (W-084).
    fileprivate func withBounds(_ bounds: SearchHitBounds) -> SearchHit {
        SearchHit(
            sourceType: sourceType,
            projectId: projectId,
            documentId: documentId,
            pageId: pageId,
            sourceId: sourceId,
            pageIndex: pageIndex,
            pageLabel: pageLabel,
            snippet: snippet,
            rank: rank,
            bounds: bounds.rects,
            boundsSource: bounds.source,
            ocrConfidence: ocrConfidence,
            isLowConfidenceOCR: isLowConfidenceOCR,
            hasUnknownOCRConfidence: hasUnknownOCRConfidence
        )
    }
}
