import CoreGraphics
import Foundation
import GRDB
import Testing
import ZPDFPersistence

@testable import ZPDFSearch

/// W-081: spec 17.5's "Case sensitive" search scope.
///
/// The Search options menu offered Match Case and nothing read it: the index folds case on
/// both sides of every match, so `ROOM` with Match Case on still returned every `room`. The
/// engine now runs the case-folded match for candidates and keeps the rows whose own text
/// holds the query in the typed case — whole words, phrases, prefixes, `OR` branches and
/// exclusions — and boxes only the typed case on the page.
@Suite("Case-sensitive search (W-081)", .serialized)
struct Iter6CaseSensitiveSearchTests {

    // MARK: - Fixtures

    /// One synthetic page carrying one index row of `sourceType` with `content`.
    @discardableResult
    private static func row(
        _ bed: SearchTestBed,
        _ content: String,
        sourceType: SearchSourceType = .pdfText
    ) async throws -> String {
        let markupId = try await bed.addMarkupOnSyntheticPage(subject: "anchor")
        let projectId = bed.projectId
        return try await bed.database.write { db -> String in
            let page = try #require(try Row.fetchOne(
                db, sql: "SELECT document_id, page_id FROM markup WHERE id = ?", arguments: [markupId]
            ))
            let pageId: String = page["page_id"]
            try SearchIndexStore.insert(db, SearchIndexRecord(
                projectId: projectId, documentId: page["document_id"], pageId: pageId,
                sourceType: sourceType.rawValue, sourceId: pageId,
                content: ZPDFTextNormalizer.indexable(content, options: .standard)
            ))
            return pageId
        }
    }

    private static func search(
        _ bed: SearchTestBed,
        _ text: String,
        caseSensitive: Bool,
        options: SearchQueryOptions = .standard,
        maximumHits: Int = 200
    ) async throws -> SearchResults {
        var options = options
        options.isCaseSensitive = caseSensitive
        return try await SearchService(database: bed.database).search(SearchRequest(
            text: text, scope: .project(projectId: bed.projectId), sources: .pdfTextOnly,
            queryOptions: options, maximumHits: maximumHits, resolvesBounds: false
        ))
    }

    private static func contents(_ results: SearchResults) -> [String] {
        results.hits.map { $0.snippet.replacingOccurrences(of: "\u{2068}", with: "")
            .replacingOccurrences(of: "\u{2069}", with: "") }.sorted()
    }

    // MARK: - The rule, on text

    @Test("W-081: a term holds in the typed case, as a whole word, with diacritics folded as the index folds them")
    func termRule() {
        func holds(_ query: String, _ text: String, options: SearchQueryOptions = SearchQueryOptions(isCaseSensitive: true)) -> Bool {
            FTS5QueryCompiler.compile(query, options: options).holdsWithCase(in: text)
        }
        #expect(holds("ROOM", "ROOM 101"))
        #expect(!holds("ROOM", "room 101"))
        #expect(!holds("ROOM", "Room 101"))
        // Whole words only, as the index matches tokens.
        #expect(!holds("ROOM", "BATHROOM 3"))
        #expect(!holds("ROOM", "ROOMS"))
        #expect(holds("ROOM", "BATHROOM, ROOM"))
        // A prefix term matches on a word's beginning, in case.
        #expect(holds("ROO*", "ROOMS"))
        #expect(!holds("ROO*", "rooms"))
        #expect(!holds("ROO*", "BATHROOM"))
        // A phrase is consecutive words with anything but letters and digits between them.
        #expect(holds("\"ROOM 101\"", "see ROOM-101 here"))
        #expect(holds("A-102", "SHEET A 102"))
        #expect(!holds("\"ROOM 101\"", "ROOM 1010"))
        #expect(!holds("\"ROOM 101\"", "Room 101"))
        #expect(!holds("\"ROOM 101\"", "ROOM X 101"))
        // Diacritics are folded on both sides, as `remove_diacritics 2` folds them; case is not.
        #expect(holds("KOK", "KÖK"))
        #expect(holds("KÖK", "KOK"))
        #expect(!holds("kök", "KÖK"))
        // `AND` needs every word in case; `OR` one branch.
        #expect(holds("ROOM Hall", "Hall by ROOM"))
        #expect(!holds("ROOM Hall", "hall by ROOM"))
        #expect(holds("ROOM OR Hall", "the Hall"))
        #expect(!holds("ROOM OR Hall", "the hall, the room"))
        // An exclusion excludes only the typed case.
        #expect(holds("ROOM NOT Hall", "ROOM hall"))
        #expect(!holds("ROOM NOT Hall", "ROOM Hall"))
    }

    @Test("W-081: a case-sensitive query asks the index without its exclusions; a case-folded one is unchanged")
    func candidateExpression() {
        let folded = FTS5QueryCompiler.compile("ROOM NOT Hall OR Corridor")
        #expect(folded.matchExpression == "\"ROOM\" NOT \"Hall\" OR \"Corridor\"")
        #expect(folded.candidateExpression == folded.matchExpression)
        #expect(!folded.isCaseSensitive)

        let cased = FTS5QueryCompiler.compile("ROOM NOT Hall OR Corridor", options: SearchQueryOptions(isCaseSensitive: true))
        #expect(cased.matchExpression == folded.matchExpression)
        #expect(cased.candidateExpression == "\"ROOM\" OR \"Corridor\"")
        #expect(cased.isCaseSensitive)
        #expect(cased.branches.map { $0.map(\.sourceText) } == [["ROOM", "Hall"], ["Corridor"]])
    }

    // MARK: - The rule, in the index

    /// Old output: the toggle reached no request, so every one of the three rows was
    /// returned for `ROOM` whatever Match Case said.
    @Test("W-081: Match Case returns only the rows that say ROOM in capitals")
    func matchCaseNarrowsTheHits() async throws {
        try await withSearchTestBed { bed in
            try await Self.row(bed, "ROOM 101 PLAN")
            try await Self.row(bed, "room 202 plan")
            try await Self.row(bed, "Room schedule")
            try await Self.row(bed, "BATHROOM 3")

            let folded = try await Self.search(bed, "ROOM", caseSensitive: false)
            #expect(Self.contents(folded) == ["ROOM 101 PLAN", "Room schedule", "room 202 plan"])

            let cased = try await Self.search(bed, "ROOM", caseSensitive: true)
            #expect(Self.contents(cased) == ["ROOM 101 PLAN"])
            #expect(cased.hitCountsBySource == [.pdfText: 1])
            #expect(!cased.wasTruncated)

            // The word still being typed matches as a prefix, in case.
            let typing = try await Self.search(bed, "Ro", caseSensitive: true, options: .findAsYouType)
            #expect(Self.contents(typing) == ["Room schedule"])
        }
    }

    /// Asking the index the full expression would lose the second row: the index folds
    /// case, so its `NOT Hall` excludes both.
    @Test("W-081: an exclusion is applied in the typed case — ROOM NOT Hall keeps a row that only says hall")
    func exclusionKeepsTheOtherCase() async throws {
        try await withSearchTestBed { bed in
            try await Self.row(bed, "ROOM Hall")
            try await Self.row(bed, "ROOM hall")

            #expect(try await Self.search(bed, "ROOM NOT Hall", caseSensitive: false).hits.isEmpty)
            let cased = try await Self.search(bed, "ROOM NOT Hall", caseSensitive: true)
            #expect(Self.contents(cased) == ["ROOM hall"])
        }
    }

    @Test("W-081: each OR branch holds in its own case")
    func orBranches() async throws {
        try await withSearchTestBed { bed in
            for text in ["ROOM", "room", "Hall", "hall"] { try await Self.row(bed, text) }
            #expect(try await Self.search(bed, "ROOM OR Hall", caseSensitive: false).hits.count == 4)
            let cased = try await Self.search(bed, "ROOM OR Hall", caseSensitive: true)
            #expect(Self.contents(cased) == ["Hall", "ROOM"])
        }
    }

    /// A limit of 1 reads batches of 2 rows. Stopping after the first batch, as a search
    /// that drops nothing does, would return no hit here and call itself truncated.
    @Test("W-081: rows dropped for case do not end the scan — the limit is filled from further batches")
    func droppedRowsDoNotTruncate() async throws {
        try await withSearchTestBed { bed in
            try await Self.row(bed, "room a")
            try await Self.row(bed, "room b")
            try await Self.row(bed, "room c")
            try await Self.row(bed, "ROOM d")
            let one = try await Self.search(bed, "ROOM", caseSensitive: true, maximumHits: 1)
            #expect(Self.contents(one) == ["ROOM d"])
            #expect(!one.wasTruncated)
        }
    }

    @Test("W-081: a kept row past the limit still proves the list is truncated")
    func keptRowPastTheLimitTruncates() async throws {
        try await withSearchTestBed { bed in
            try await Self.row(bed, "ROOM a")
            try await Self.row(bed, "room b")
            try await Self.row(bed, "ROOM c")
            let one = try await Self.search(bed, "ROOM", caseSensitive: true, maximumHits: 1)
            #expect(one.hits.count == 1)
            #expect(one.wasTruncated)
        }
    }

    // MARK: - Highlights

    @Test("W-081: a case-sensitive recognised hit boxes only the token in the typed case, and its confidence is that token's")
    func recognisedHighlightKeepsCase() async throws {
        try await withSearchTestBed { bed in
            let markupId = try await bed.addMarkupOnSyntheticPage(subject: "anchor")
            let projectId = bed.projectId
            try await bed.database.write { db in
                let page = try #require(try Row.fetchOne(
                    db, sql: "SELECT document_id, page_id FROM markup WHERE id = ?", arguments: [markupId]
                ))
                let pageId: String = page["page_id"]
                for (line, (text, confidence)) in [("ROOM", 0.9), ("room", 0.4)].enumerated() {
                    let y = 700 - Double(line) * 20
                    let blob = try GeometryBlob(kind: .rectangle, points: [
                        GeometryPoint(x: 0, y: y), GeometryPoint(x: 15, y: y),
                        GeometryPoint(x: 15, y: y + 10), GeometryPoint(x: 0, y: y + 10)
                    ]).encode()
                    try SearchIndexStore.insertOCRToken(db, OCRTokenRecord(
                        pageId: pageId, token: text, normalizedToken: ZPDFTextNormalizer.folded(text),
                        confidence: confidence, boundsBlob: blob, lineIndex: line, tokenIndex: 0
                    ))
                }
                try SearchIndexStore.insert(db, SearchIndexRecord(
                    projectId: projectId, documentId: page["document_id"], pageId: pageId,
                    sourceType: SearchSourceType.ocr.rawValue, sourceId: pageId, content: "ROOM room"
                ))
            }
            let service = SearchService(database: bed.database)
            func hit(caseSensitive: Bool) async throws -> SearchHit {
                let results = try await service.search(SearchRequest(
                    text: "ROOM", scope: .project(projectId: bed.projectId), sources: .ocrOnly,
                    queryOptions: SearchQueryOptions(isCaseSensitive: caseSensitive), confidence: .permissive
                ))
                return try #require(results.hits.first)
            }
            // By hand: case-folded, both tokens match, weakest 0.4; in case, only line 0 at 0.9.
            let folded = try await hit(caseSensitive: false)
            #expect(folded.bounds.count == 2)
            #expect(folded.ocrConfidence == 0.4)
            let cased = try await hit(caseSensitive: true)
            #expect(cased.bounds.count == 1)
            #expect(cased.bounds.first.map { abs($0.minY - 700) < 1e-9 } == true)
            #expect(cased.ocrConfidence == 0.9)
        }
    }

    /// Old output: the resolver always searched the page case-insensitively, so `ROOM` was
    /// boxed on `ROOM 101`, `room 202` and `Room 303` alike.
    @Test("W-081: a case-sensitive text hit is boxed only where the page has the typed case")
    func pageTextHighlightKeepsCase() async throws {
        try await withSearchTestBed { bed in
            let url = try TextSheetFixture.write(
                pages: [["ROOM 101", "room 202", "Room 303"], ["room only"]], into: bed.directory, name: "w081"
            )
            let (documentId, handle) = try await bed.addDocument(at: url)
            _ = try await TextIndexer(database: bed.database, provider: bed.provider)
                .indexDocumentText(documentId: documentId, handle: handle)
            let service = SearchService(
                database: bed.database,
                textBounds: PDFKitTextBoundsResolver(provider: bed.provider, handles: [documentId: handle])
            )
            func results(_ text: String, caseSensitive: Bool, options: SearchQueryOptions = .standard) async throws -> SearchResults {
                var options = options
                options.isCaseSensitive = caseSensitive
                return try await service.search(SearchRequest(
                    text: text, scope: .project(projectId: bed.projectId), sources: .pdfTextOnly, queryOptions: options
                ))
            }

            let folded = try await results("ROOM", caseSensitive: false)
            #expect(folded.hits.count == 2)
            #expect(folded.hits.first { $0.pageIndex == 0 }?.bounds.count == 3)

            let cased = try await results("ROOM", caseSensitive: true)
            #expect(cased.hits.map(\.pageIndex) == [0])
            #expect(cased.hits.first?.bounds.count == 1)

            let prefix = try await results("Ro", caseSensitive: true, options: .findAsYouType)
            #expect(prefix.hits.map(\.pageIndex) == [0])
            #expect(prefix.hits.first?.bounds.count == 1)

            #expect(try await results("rOOM", caseSensitive: true).hits.isEmpty)
        }
    }

    @Test("W-081: with case folded the prefix expansion still finds every case; with case kept only the typed one")
    func prefixExpansionKeepsCase() {
        let page = "Room 101\nROOM SCHEDULE\nroom 3"
        #expect(PDFKitTextBoundsResolver.wholeWords(startingWith: "RO", in: page, foldsCase: true) == ["Room"])
        #expect(PDFKitTextBoundsResolver.wholeWords(startingWith: "RO", in: page, foldsCase: false) == ["ROOM"])
        #expect(PDFKitTextBoundsResolver.wholeWords(startingWith: "ro", in: page, foldsCase: false) == ["room"])
    }
}
