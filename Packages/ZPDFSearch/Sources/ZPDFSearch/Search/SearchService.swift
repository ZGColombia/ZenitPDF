import CoreGraphics
import Foundation
import GRDB
import ZPDFPersistence

/// One ranked query across PDF text, recognised text, markups, custom values and zones.
///
/// ### The query is never SQL
///
/// `request.text` reaches SQLite twice: once as a **bound argument** to `MATCH`, and never
/// as a fragment of a statement. What is bound is not even the user's string — it is the
/// expression ``FTS5QueryCompiler`` rebuilt out of the alphanumeric runs it found. A user
/// who types `"` or `NEAR(` or `a) OR b` gets a search for the words in what they typed,
/// with no syntax error and nothing executed.
///
/// ### Ranking
///
/// `bm25()`, SQLite's own. It weighs a term by how rare it is in the index and how short
/// the row is, which is the behaviour an estimator expects: `ROOM 101` matching a
/// four-word markup label ranks above the same words buried in a page of general notes.
/// Lower is better; `hits` is returned already sorted.
///
/// ### Recognised text is never silently mixed in
///
/// See ``OCRConfidencePolicy``. Every hit says which source it came from, and an `ocr` hit
/// additionally carries the confidence of the weakest token that matched.
public actor SearchService {

    private let database: ProjectDatabaseActor
    private let limits: SearchLimits
    private let textBounds: (any SearchTextBoundsResolving)?

    public init(
        database: ProjectDatabaseActor,
        limits: SearchLimits = .standard,
        textBounds: (any SearchTextBoundsResolving)? = nil
    ) {
        self.database = database
        self.limits = limits
        self.textBounds = textBounds
    }

    // MARK: - Searching

    public func search(_ request: SearchRequest) async throws -> SearchResults {
        try checkSearchCancellation()
        let startedAt = DispatchTime.now()

        let query = FTS5QueryCompiler.compile(
            request.text,
            options: request.queryOptions,
            limits: limits
        )

        func empty() -> SearchResults {
            SearchResults(
                query: query,
                hits: [],
                wasTruncated: false,
                hitCountsBySource: [:],
                lowConfidenceOCRHitCount: 0,
                excludedLowConfidenceOCRHitCount: 0,
                elapsedSeconds: elapsed(since: startedAt)
            )
        }

        guard !query.isEmpty else { return empty() }
        let sourceTypes = request.sources.sourceTypes
        guard !sourceTypes.isEmpty else { return empty() }

        // BH-648: both limits accept `Int.max` as "no limit", and `limit + 1` below is the
        // one-row look-ahead that decides truncation. Clamped so the addition cannot trap.
        let limit = Swift.min(request.maximumHits, limits.maximumHits, Int.max - 1)
        let batchSize = limit + 1

        // BH-210: `.exclude` drops recognised hits *after* the ranked fetch, so a first
        // batch whose best-ranked rows were all low-confidence used to come back empty and
        // truncated ("First 0 results") while confident hits ranked further down were
        // never read. When the policy can exclude, further batches are read until the
        // limit is filled or the rows run out, within a bounded scan.
        let mayExclude = request.confidence.handling == .exclude && sourceTypes.contains(.ocr)
        // W-081: a case-sensitive query keeps only the candidates that hold in the typed case,
        // so it can drop rows after the ranked fetch exactly as `.exclude` can, and reads
        // further batches the same way.
        let scanBudget: Int
        if mayExclude || query.isCaseSensitive {
            let extended = limit.addingReportingOverflow(Swift.max(limits.maximumHits, batchSize))
            scanBudget = extended.overflow ? Int.max : extended.partialValue
        } else {
            scanBudget = batchSize
        }

        var countsBySource: [SearchSourceType: Int] = [:]
        var pages: [String: SearchIndexStore.PageRow] = [:]
        var hits: [SearchHit] = []
        hits.reserveCapacity(Swift.min(limit, 256))
        var lowConfidence = 0
        var excluded = 0
        var unknownConfidence = 0
        var wasTruncated = false
        var offset = 0

        scan: while true {
            let fetched = try await fetchRows(
                query: query,
                scope: request.scope,
                sourceTypes: sourceTypes,
                limit: batchSize,
                offset: offset,
                snippetTokens: limits.snippetTokenCount
            )
            try checkSearchCancellation()
            // The index folds case; a case-sensitive query keeps the rows whose own text
            // holds the query in the typed case (W-081). A dropped row is not a hit: it is
            // not counted by source and does not prove the list is truncated.
            let rows = query.isCaseSensitive
                ? fetched.filter { query.holdsWithCase(in: $0.content ?? "") }
                : fetched

            // Everything the batch needs from storage, in as few reads as possible: page
            // identity, recognised-token matches (BH-649 — no geometry decoded unless it is
            // asked for) and markup geometry (IM-085 — one `IN (…)` instead of N reads).
            let missingPages = Array(Set(rows.compactMap(\.pageId)).subtracting(pages.keys))
            if !missingPages.isEmpty {
                let fetched = try await read { db in
                    try SearchIndexStore.pageLabels(db, pageIds: missingPages)
                }
                pages.merge(fetched) { current, _ in current }
            }
            let ocrPageIds = rows.filter { $0.sourceType == .ocr }.compactMap(\.pageId)
            let recognised = try await recognisedMatches(
                pageIds: ocrPageIds,
                query: query,
                includeBounds: request.resolvesBounds
            )
            let markupRects: [String: CGRect] = request.resolvesBounds
                ? try await markupBounds(markupIds: rows.compactMap(Self.markupId(of:)))
                : [:]

            for row in rows {
                try checkSearchCancellation()
                let page = row.pageId.flatMap { pages[$0] }

                var confidence: Double?
                var match: RecognisedMatch?
                if row.sourceType == .ocr, let pageId = row.pageId {
                    match = recognised[pageId]
                    confidence = match?.minimumConfidence
                }

                // CR-125. `(confidence ?? 0) < threshold` treated "no recognised token on
                // this page matched" as the *worst possible* confidence, so a disagreement
                // between the FTS tokeniser and the token table — a folding difference, or
                // an `ocr_token` table cleared while the FTS rows survived — deleted a good
                // hit outright under `.exclude`. Unknown is its own answer: the hit is kept,
                // it is not called low confidence, and the count says how often it happened.
                let isUnknown = row.sourceType == .ocr && confidence == nil
                let isLow = row.sourceType == .ocr
                    && (confidence.map { $0 < request.confidence.threshold } ?? false)
                let isExcluded = isLow && request.confidence.handling == .exclude

                if hits.count == limit {
                    // The look-ahead row. A row the policy keeps proves there is more than
                    // the list shows; a row it drops proves nothing, so keep looking.
                    if isExcluded {
                        countsBySource[row.sourceType, default: 0] += 1
                        excluded += 1
                        continue
                    }
                    wasTruncated = true
                    break scan
                }

                countsBySource[row.sourceType, default: 0] += 1
                if isExcluded {
                    excluded += 1
                    continue
                }
                if isLow { lowConfidence += 1 }
                if isUnknown { unknownConfidence += 1 }

                var bounds: [CGRect] = []
                var boundsSource = SearchBoundsSource.none
                if request.resolvesBounds {
                    switch row.sourceType {
                    case .ocr:
                        if let rects = match?.bounds, !rects.isEmpty {
                            bounds = rects
                            boundsSource = .recognisedTokens
                        }
                    case .pdfText:
                        let resolved = await pageTextBounds(
                            documentId: row.documentId,
                            pageIndex: page?.index,
                            query: query
                        )
                        if !resolved.isEmpty {
                            bounds = resolved
                            boundsSource = .pageText
                        }
                    case .markupSubject, .markupLabel, .markupComment, .customValue:
                        if let markupId = Self.markupId(of: row), let rect = markupRects[markupId] {
                            bounds = [rect]
                            boundsSource = .markupGeometry
                        }
                    case .zoneName, .indexStamp:
                        break
                    }
                }

                hits.append(
                    SearchHit(
                        sourceType: row.sourceType,
                        projectId: row.projectId,
                        documentId: row.documentId,
                        pageId: row.pageId,
                        sourceId: row.sourceId,
                        pageIndex: page?.index,
                        pageLabel: page.map { $0.label ?? String($0.index + 1) },
                        snippet: row.snippet,
                        rank: row.rank,
                        bounds: bounds,
                        boundsSource: boundsSource,
                        ocrConfidence: confidence,
                        isLowConfidenceOCR: isLow,
                        hasUnknownOCRConfidence: isUnknown
                    )
                )
            }

            offset += fetched.count
            // Fewer rows than asked for: the index has nothing further.
            if fetched.count < batchSize { break }
            if offset >= scanBudget {
                // Rows remain that the bounded scan did not examine.
                wasTruncated = true
                break
            }
        }

        return SearchResults(
            query: query,
            hits: hits,
            wasTruncated: wasTruncated,
            hitCountsBySource: countsBySource,
            lowConfidenceOCRHitCount: lowConfidence,
            excludedLowConfidenceOCRHitCount: excluded,
            unknownConfidenceOCRHitCount: unknownConfidence,
            elapsedSeconds: elapsed(since: startedAt)
        )
    }

    // MARK: - Bounds on demand (IM-085)

    /// Highlight rectangles for hits that were returned without them.
    ///
    /// A result list does not need geometry to be shown: search with
    /// ``SearchRequest/resolvesBounds`` `false`, publish the list, then resolve the
    /// rectangles only for the hits the user reveals or can see. A `pdf-text` hit costs
    /// one engine page search here instead of one per hit before the list could appear;
    /// markup hits are read in one statement, recognised hits in one statement per 200
    /// pages.
    ///
    /// - Parameters:
    ///   - hits: hits from ``search(_:)``, typically with ``SearchHit/boundsSource``
    ///     `.none`. Hits of any project scope may be mixed.
    ///   - query: ``SearchResults/query`` of the search that produced them.
    /// - Returns: one entry per hit, in order. A hit with no geometry gets empty
    ///   rectangles and source `.none`.
    public func bounds(for hits: [SearchHit], query: SearchQuery) async throws -> [SearchHitBounds] {
        try checkSearchCancellation()
        guard !hits.isEmpty, !query.isEmpty else {
            return hits.map { _ in SearchHitBounds(rects: [], source: .none) }
        }
        let ocrPageIds = hits.filter { $0.sourceType == .ocr }.compactMap(\.pageId)
        let recognised = try await recognisedMatches(pageIds: ocrPageIds, query: query, includeBounds: true)
        let markupIds = hits.compactMap { hit -> String? in
            Self.markupId(sourceType: hit.sourceType, sourceId: hit.sourceId)
        }
        let markupRects = try await markupBounds(markupIds: markupIds)

        var output: [SearchHitBounds] = []
        output.reserveCapacity(hits.count)
        for hit in hits {
            try checkSearchCancellation()
            switch hit.sourceType {
            case .ocr:
                if let pageId = hit.pageId, let rects = recognised[pageId]?.bounds, !rects.isEmpty {
                    output.append(SearchHitBounds(rects: rects, source: .recognisedTokens))
                    continue
                }
            case .pdfText:
                let rects = await pageTextBounds(
                    documentId: hit.documentId,
                    pageIndex: hit.pageIndex,
                    query: query
                )
                if !rects.isEmpty {
                    output.append(SearchHitBounds(rects: rects, source: .pageText))
                    continue
                }
            case .markupSubject, .markupLabel, .markupComment, .customValue:
                if let markupId = Self.markupId(sourceType: hit.sourceType, sourceId: hit.sourceId),
                   let rect = markupRects[markupId] {
                    output.append(SearchHitBounds(rects: [rect], source: .markupGeometry))
                    continue
                }
            case .zoneName, .indexStamp:
                break
            }
            output.append(SearchHitBounds(rects: [], source: .none))
        }
        return output
    }

    /// Highlight rectangles for one hit. See ``bounds(for:query:)-(SearchHit[],_)``.
    public func bounds(for hit: SearchHit, query: SearchQuery) async throws -> SearchHitBounds {
        try await bounds(for: [hit], query: query).first ?? SearchHitBounds(rects: [], source: .none)
    }

    /// The engine's rectangles for the query's positive terms on one page.
    private func pageTextBounds(
        documentId: String?,
        pageIndex: Int?,
        query: SearchQuery
    ) async -> [CGRect] {
        guard let resolver = textBounds, let documentId, let pageIndex else { return [] }
        // CR-123: the literal the user typed, not the tokens the index split it into.
        // `A-102` joined back from its tokens is `A 102`, which is on no drawing anywhere.
        let terms = query.highlightTerms.map {
            SearchBoundsTerm(text: $0.sourceText, isPrefix: $0.isPrefix, isCaseSensitive: query.isCaseSensitive)
        }
        return await resolver.textBounds(documentId: documentId, pageIndex: pageIndex, terms: terms)
    }

    /// The markup whose geometry a markup or custom-value row belongs to.
    private static func markupId(of row: HitRow) -> String? {
        markupId(sourceType: row.sourceType, sourceId: row.sourceId)
    }

    private static func markupId(sourceType: SearchSourceType, sourceId: String) -> String? {
        switch sourceType {
        case .markupSubject, .markupLabel, .markupComment:
            return sourceId
        case .customValue:
            // `source_id` is `markupId/columnId`; the geometry belongs to the markup.
            return String(sourceId.prefix(while: { $0 != "/" }))
        case .ocr, .pdfText, .zoneName, .indexStamp:
            return nil
        }
    }

    /// What the index holds for one project. Internal (V-082): no product surface reads it;
    /// the tests that check what a removal left behind do.
    func statistics(projectId: String) async throws -> SearchIndexStatistics {
        try await read { db in
            var counts: [SearchSourceType: Int] = [:]
            for type in SearchSourceType.allCases {
                let count = try SearchIndexStore.rowCount(db, projectId: projectId, type: type)
                if count > 0 { counts[type] = count }
            }
            let tokens = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM ocr_token t
                JOIN page p ON p.id = t.page_id
                JOIN document d ON d.id = p.document_id
                WHERE d.project_id = ?
                """,
                arguments: [projectId]
            ) ?? 0
            return SearchIndexStatistics(
                projectId: projectId,
                rowCountsBySource: counts,
                recognisedTokenCount: tokens,
                indexedDocumentCount: counts[.indexStamp] ?? 0
            )
        }
    }

    // MARK: - The one statement

    private struct HitRow: Sendable {
        let projectId: String
        let documentId: String?
        let pageId: String?
        let sourceType: SearchSourceType
        let sourceId: String
        let snippet: String
        let rank: Double
        /// The row's indexed text, read only for a case-sensitive query (W-081).
        let content: String?
    }

    /// Runs the ranked `MATCH` of ``SearchQuery/candidateExpression``.
    ///
    /// Every value is bound. The only text built into the statement is the run of `?`
    /// placeholders for the source-type list, whose length is an integer this package
    /// computed from its own enum, and whether the `content` column is selected — it is,
    /// only for a case-sensitive query, which needs each candidate's own text (W-081).
    private func fetchRows(
        query: SearchQuery,
        scope: SearchScope,
        sourceTypes: [SearchSourceType],
        limit: Int,
        offset: Int = 0,
        snippetTokens: Int
    ) async throws -> [HitRow] {
        let expression = query.candidateExpression
        let placeholders = SearchIndexStore.databaseQuestionMarks(count: sourceTypes.count)

        // Argument order is statement order, not logical order. `snippet(...)` is in the
        // SELECT clause, so its four placeholders are bound *before* the ones in WHERE;
        // building the array in the order the conditions were thought of silently binds
        // the match expression into the snippet's open-bracket parameter and the search
        // returns nothing. Column 5 is `content`, the only indexed column of the frozen
        // schema. The brackets are the Unicode isolates, so a snippet cannot be confused
        // with text that happens to contain the marker.
        var arguments: [any DatabaseValueConvertible] = [
            "\u{2068}", "\u{2069}", "…", snippetTokens
        ]

        var conditions = ["search_fts MATCH ?", "project_id = ?"]
        arguments.append(expression)
        arguments.append(scope.projectId)

        switch scope {
        case .page(_, let pageId):
            conditions.append("page_id = ?")
            arguments.append(pageId)
        case .document(_, let documentId):
            conditions.append("document_id = ?")
            arguments.append(documentId)
        case .project:
            break
        }

        conditions.append("source_type IN (\(placeholders))")
        arguments.append(contentsOf: sourceTypes.map(\.rawValue))
        arguments.append(limit)
        arguments.append(Swift.max(0, offset))

        let contentColumn = query.isCaseSensitive ? "content" : "NULL AS content"
        let sql = """
        SELECT project_id, document_id, page_id, source_type, source_id,
               bm25(search_fts) AS rank,
               snippet(search_fts, 5, ?, ?, ?, ?) AS snip,
               \(contentColumn)
        FROM search_fts
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY rank
        LIMIT ? OFFSET ?
        """

        let bound = StatementArguments(arguments.map(\.databaseValue))
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: bound)
            return rows.compactMap { row in
                let raw: String = row["source_type"]
                guard let type = SearchSourceType(rawValue: raw), type != .indexStamp else { return nil }
                return HitRow(
                    projectId: row["project_id"],
                    documentId: row["document_id"],
                    pageId: row["page_id"],
                    sourceType: type,
                    sourceId: row["source_id"],
                    snippet: row["snip"] ?? "",
                    rank: row["rank"] ?? 0,
                    content: row["content"]
                )
            }
        }
    }

    // MARK: - Bounds and confidence

    private struct RecognisedMatch: Sendable {
        let bounds: [CGRect]
        let minimumConfidence: Double?
    }

    /// The recognised tokens on one page that a query term matches, with their rectangles.
    ///
    /// Matching happens on `normalized_token`, which this package wrote with the same
    /// folding it applies to the query term here, so the comparison is between two values
    /// produced by one function. A prefix term uses `GLOB` rather than `LIKE`: `GLOB` is
    /// case-sensitive and both sides are already folded, whereas `LIKE`'s ASCII-only case
    /// folding would quietly disagree with the folding used to write the column.
    ///
    /// ### Phrases are adjacency, not an OR (CR-124)
    ///
    /// A phrase term used to be flattened into "any of these tokens", so `"ROOM 101"`
    /// highlighted every `ROOM` and every `101` on the sheet — on a floor plan, most of
    /// the page. FTS5 matched the phrase properly and only the highlight lied, which is
    /// the worst version of the bug: the hit is right and the drawing is covered in boxes
    /// that are not it.
    ///
    /// The token table carries `line_index` and `token_index`, so adjacency is decidable
    /// here: the candidate rows are read once, grouped by line, and a phrase contributes
    /// rectangles only where its tokens appear consecutively, in order, on one line.
    ///
    /// ### One statement per 200 pages, geometry only when asked (BH-649, IM-085)
    ///
    /// Every recognised hit used to cost its own serialized read, and every candidate row's
    /// `bounds_blob` was copied and decoded even for a `resolvesBounds: false` preview that
    /// only needed the weakest confidence. The candidates for a batch of pages are now read
    /// together, capped with a window function at ``SearchLimits/maximumBoundsTokensPerHit``
    /// per page **and per matched token** (R-155; see `readCandidates` and
    /// `completePhrases`), and the blob column is not selected at all unless rectangles are
    /// wanted.
    private func recognisedMatches(
        pageIds: [String],
        query: SearchQuery,
        includeBounds: Bool
    ) async throws -> [String: RecognisedMatch] {
        let uniquePages = Array(Set(pageIds)).sorted()
        guard !uniquePages.isEmpty else { return [:] }

        // The union of every token any term could match, so one statement reads all the
        // candidates; which of them actually count is decided below, per term.
        var exact: Set<String> = []
        var prefixes: Set<String> = []
        var terms: [RecognisedTerm] = []
        for term in query.highlightTerms {
            let pairs = zip(term.tokens, term.foldedTokens).filter { !$0.1.isEmpty }
            let tokens = pairs.map(\.1)
            guard !tokens.isEmpty else { continue }
            terms.append(RecognisedTerm(
                folded: tokens,
                cased: query.isCaseSensitive ? pairs.map { ZPDFTextNormalizer.caseKept($0.0) } : nil,
                isPrefix: term.isPrefix
            ))
            for token in tokens.dropLast() { exact.insert(token) }
            if let last = tokens.last {
                if term.isPrefix { prefixes.insert(last) } else { exact.insert(last) }
            }
        }
        guard !exact.isEmpty || !prefixes.isEmpty else { return [:] }

        // One matcher per distinct token a term can match — an exact token, or a prefix —
        // and each gets its own candidate budget (R-155). The budget used to be one window
        // over the union of every term's tokens, so more than `maximumBoundsTokensPerHit`
        // occurrences of one common word earlier on the page cut every other term's tokens:
        // `ROOM 1` lost its only ROOM behind 512 `1…` tokens, and its confidence came from
        // the `1…` tokens alone.
        var matchers: [CandidateMatcher] = exact.sorted().map { CandidateMatcher(token: $0, isPrefix: false) }
        matchers += prefixes.sorted().map { CandidateMatcher(token: $0, isPrefix: true) }
        let maximum = limits.maximumBoundsTokensPerHit
        let chunks = stride(from: 0, to: uniquePages.count, by: 200).map {
            Array(uniquePages[$0..<Swift.min($0 + 200, uniquePages.count)])
        }
        let phraseTerms = terms.filter { $0.folded.count > 1 }
        let candidateMatchers = matchers

        let candidatesByPage: [String: [CandidateToken]] = try await read { db in
            var byPage: [String: [CandidateToken]] = [:]
            for chunk in chunks {
                let found = try Self.readCandidates(
                    db, pages: chunk, matchers: candidateMatchers, maximum: maximum,
                    includeBounds: includeBounds
                )
                let completed = try Self.completePhrases(
                    db, found: found, phraseTerms: phraseTerms, matchers: candidateMatchers,
                    maximum: maximum, includeBounds: includeBounds
                )
                for (pageId, tokens) in completed { byPage[pageId] = tokens }
            }
            return byPage
        }

        var result: [String: RecognisedMatch] = [:]
        for pageId in uniquePages {
            result[pageId] = Self.resolve(
                terms: terms, against: candidatesByPage[pageId] ?? [], maximumRects: limits.maximumBoundsTokensPerHit
            )
        }
        return result
    }

    /// One query term as the token table is searched for it.
    private struct RecognisedTerm: Sendable {
        /// The term's tokens folded, as `normalized_token` holds them.
        let folded: [String]
        /// The same tokens with case kept, for a case-sensitive query; `nil` otherwise. A
        /// recognised token whose own text differs in case is then not this term (W-081).
        let cased: [String]?
        let isPrefix: Bool
    }

    /// One `ocr_token` row, reduced to what adjacency and highlighting need.
    private struct CandidateToken: Sendable {
        let token: String
        /// `ocr_token.token`, the token as it was recognised, case and all.
        let recognised: String
        let lineIndex: Int
        let tokenIndex: Int
        let confidence: Double
        let rect: CGRect?
    }

    /// One distinct token a term can match: exactly, or — the last word of a prefix term —
    /// on its beginning.
    private struct CandidateMatcher: Sendable {
        let token: String
        let isPrefix: Bool

        func matches(_ candidate: String) -> Bool {
            isPrefix ? candidate.hasPrefix(token) : candidate == token
        }
    }

    /// The candidate tokens of one page, keyed by position so a row read twice (by two
    /// matchers, or again by phrase completion) is kept once, plus how many rows each
    /// matcher returned — a matcher that returned the whole budget may have been cut.
    private struct PageCandidates: Sendable {
        var tokens: [Int: CandidateToken] = [:]   // line * 1_000_000 + tokenIndex
        var matcherCounts: [Int: Int] = [:]

        mutating func add(_ token: CandidateToken) {
            tokens[token.lineIndex &* 1_000_000 &+ token.tokenIndex] = token
        }
    }

    private static func candidate(from row: Row) -> CandidateToken {
        var rect: CGRect?
        if let data: Data = row["bounds_blob"],
           let blob = try? GeometryBlob.decode(data),
           let ring = blob.rings.first, ring.count >= 2 {
            rect = boundingRect(of: ring)
        }
        return CandidateToken(
            token: row["normalized_token"],
            recognised: row["token"] ?? "",
            lineIndex: row["line_index"] ?? 0,
            tokenIndex: row["token_index"] ?? 0,
            confidence: row["confidence"],
            rect: rect
        )
    }

    /// The first `maximum` rows in reading order of every matcher on every page of `pages`,
    /// in one statement: one windowed branch per matcher, joined by `UNION ALL`. The branch
    /// index is a literal this function computed; every token and page id is bound.
    private static func readCandidates(
        _ db: Database,
        pages: [String],
        matchers: [CandidateMatcher],
        maximum: Int,
        includeBounds: Bool
    ) throws -> [String: PageCandidates] {
        guard !pages.isEmpty, !matchers.isEmpty else { return [:] }
        let blobColumn = includeBounds ? "bounds_blob" : "NULL AS bounds_blob"
        let pageValues = Array(repeating: "(?)", count: pages.count).joined(separator: ", ")
        var arguments: [any DatabaseValueConvertible] = pages
        var branches: [String] = []
        for (index, matcher) in matchers.enumerated() {
            let condition = matcher.isPrefix ? "normalized_token GLOB ?" : "normalized_token = ?"
            // `GLOB`'s metacharacters are `*`, `?`, `[` and `]`. A folded token can still
            // contain none of them — it is alphanumeric — but escaping is free and a future
            // caller may not be so careful.
            arguments.append(matcher.isPrefix ? globEscape(matcher.token) + "*" : matcher.token)
            arguments.append(maximum)
            branches.append("""
                SELECT \(index) AS matcher, page_id, token, normalized_token, line_index, token_index,
                       confidence, bounds_blob
                FROM (
                    SELECT page_id, token, normalized_token, line_index, token_index, confidence,
                           \(blobColumn),
                           ROW_NUMBER() OVER (
                               PARTITION BY page_id ORDER BY line_index, token_index
                           ) AS candidate_rank
                    FROM ocr_token
                    WHERE page_id IN (SELECT id FROM pages) AND \(condition)
                )
                WHERE candidate_rank <= ?
                """)
        }
        let sql = "WITH pages(id) AS (VALUES \(pageValues))\n" + branches.joined(separator: "\nUNION ALL\n")
        var byPage: [String: PageCandidates] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments.map(\.databaseValue))) {
            let pageId: String = row["page_id"]
            let matcher: Int = row["matcher"]
            byPage[pageId, default: PageCandidates()].add(candidate(from: row))
            byPage[pageId, default: PageCandidates()].matcherCounts[matcher, default: 0] += 1
        }
        return byPage
    }

    /// Makes sure a phrase whose rarest word survived the budget can still be matched.
    ///
    /// Per-matcher budgets keep a rare word from being crowded out, but a phrase needs its
    /// common words too, at the right positions: `A-102` is the phrase `a 102`, and the one
    /// `a` beside `102` can sit behind hundreds of other `a`s. So when a phrase word's matcher
    /// filled its budget, the phrase's least frequent word whose matcher did not is taken as
    /// the anchor, and every phrase word on the anchor's lines is read — one statement per
    /// page that needs it, bounded by the anchor's own budget of lines.
    private static func completePhrases(
        _ db: Database,
        found: [String: PageCandidates],
        phraseTerms: [RecognisedTerm],
        matchers: [CandidateMatcher],
        maximum: Int,
        includeBounds: Bool
    ) throws -> [String: [CandidateToken]] {
        func matcherIndex(_ token: String, prefix: Bool) -> Int? {
            matchers.firstIndex { $0.token == token && $0.isPrefix == prefix }
        }
        var result: [String: [CandidateToken]] = [:]
        let blobColumn = includeBounds ? "bounds_blob" : "NULL AS bounds_blob"
        for (pageId, page) in found {
            var candidates = page
            var lines: Set<Int> = []
            var needed: Set<Int> = []
            for term in phraseTerms {
                let positions = term.folded.indices.compactMap { position -> Int? in
                    matcherIndex(term.folded[position], prefix: term.isPrefix && position == term.folded.count - 1)
                }
                guard positions.count == term.folded.count else { continue }
                let counts = positions.map { page.matcherCounts[$0] ?? 0 }
                guard counts.contains(where: { $0 >= maximum }) else { continue }
                // The least frequent word that was read in full anchors the phrase.
                guard let anchor = positions.indices
                    .filter({ counts[$0] < maximum && counts[$0] > 0 })
                    .min(by: { counts[$0] < counts[$1] })
                else { continue }
                let anchorMatcher = matchers[positions[anchor]]
                for token in page.tokens.values where anchorMatcher.matches(token.token) {
                    lines.insert(token.lineIndex)
                }
                needed.formUnion(positions)
            }
            if !lines.isEmpty, !needed.isEmpty {
                let wanted = needed.sorted().map { matchers[$0] }
                let lineList = lines.sorted()
                var arguments: [any DatabaseValueConvertible] = [pageId]
                arguments.append(contentsOf: lineList)
                var conditions: [String] = []
                for matcher in wanted {
                    conditions.append(matcher.isPrefix ? "normalized_token GLOB ?" : "normalized_token = ?")
                    arguments.append(matcher.isPrefix ? globEscape(matcher.token) + "*" : matcher.token)
                }
                let sql = """
                    SELECT token, normalized_token, line_index, token_index, confidence, \(blobColumn)
                    FROM ocr_token
                    WHERE page_id = ?
                      AND line_index IN (\(SearchIndexStore.databaseQuestionMarks(count: lineList.count)))
                      AND (\(conditions.joined(separator: " OR ")))
                    """
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments.map(\.databaseValue))) {
                    candidates.add(candidate(from: row))
                }
            }
            result[pageId] = candidates.tokens.values.sorted {
                ($0.lineIndex, $0.tokenIndex) < ($1.lineIndex, $1.tokenIndex)
            }
        }
        return result
    }

    /// Keeps the candidate tokens that actually satisfy a term, phrases included.
    ///
    /// Single-token terms match wherever they appear. A multi-token phrase matches only
    /// where its tokens sit at consecutive `token_index` on one `line_index`, in order —
    /// and only the last token of a prefix term is allowed to match on its beginning.
    /// The confidence reported is the weakest token that took part in a match, so a
    /// phrase is no more trusted than its worst word.
    private static func resolve(
        terms: [RecognisedTerm],
        against candidates: [CandidateToken],
        maximumRects: Int
    ) -> RecognisedMatch {
        var byLine: [Int: [CandidateToken]] = [:]
        for candidate in candidates { byLine[candidate.lineIndex, default: []].append(candidate) }
        for key in byLine.keys { byLine[key]?.sort { $0.tokenIndex < $1.tokenIndex } }

        var rects: [CGRect] = []
        var minimum: Double?
        var used: Set<Int> = []          // line * 1_000_000 + tokenIndex, so a token is
                                         // never highlighted twice by two terms.

        func accept(_ run: [CandidateToken]) {
            for token in run {
                minimum = minimum.map { Swift.min($0, token.confidence) } ?? token.confidence
                let key = token.lineIndex &* 1_000_000 &+ token.tokenIndex
                guard used.insert(key).inserted, let rect = token.rect else { continue }
                // Each matcher now reads its own budget, so the accepted rectangles are what
                // is capped (R-155); the confidence above still counts every accepted token.
                guard rects.count < maximumRects else { continue }
                rects.append(rect)
            }
        }

        for term in terms {
            let width = term.folded.count
            for line in byLine.keys.sorted() {
                guard let row = byLine[line] else { continue }
                for start in row.indices where start + width <= row.count {
                    let run = Array(row[start..<(start + width)])
                    // Consecutive positions on the line, with no gap where a token the
                    // query did not ask for was skipped by the WHERE clause.
                    var adjacent = true
                    for offset in 1..<max(width, 1) where
                        run[offset].tokenIndex != run[offset - 1].tokenIndex + 1 {
                        adjacent = false
                    }
                    guard adjacent else { continue }
                    var matches = true
                    for (offset, expected) in term.folded.enumerated() {
                        let isLast = offset == width - 1
                        // Folded, as the index matched it; with case kept too when the
                        // query is case-sensitive (W-081).
                        var comparisons = [(run[offset].token, expected)]
                        if let cased = term.cased {
                            comparisons.append((ZPDFTextNormalizer.caseKept(run[offset].recognised), cased[offset]))
                        }
                        for (actual, wanted) in comparisons {
                            if term.isPrefix && isLast {
                                if !actual.hasPrefix(wanted) { matches = false }
                            } else if actual != wanted {
                                matches = false
                            }
                        }
                        if !matches { break }
                    }
                    guard matches else { continue }
                    accept(run)
                }
            }
        }
        return RecognisedMatch(bounds: rects, minimumConfidence: minimum)
    }

    /// One bounding rectangle per markup, read in one statement per 400 ids (IM-085).
    ///
    /// Each markup and custom-value hit used to cost its own read (an N+1 pattern); a
    /// result list of 200 markup hits is now one `WHERE id IN (…)`.
    private func markupBounds(markupIds: [String]) async throws -> [String: CGRect] {
        let unique = Array(Set(markupIds.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return [:] }
        return try await read { db in
            var result: [String: CGRect] = [:]
            for start in stride(from: 0, to: unique.count, by: 400) {
                let chunk = Array(unique[start..<Swift.min(start + 400, unique.count)])
                let placeholders = SearchIndexStore.databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, geometry_blob FROM markup WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    guard let data: Data = row["geometry_blob"],
                          let blob = try? GeometryBlob.decode(data)
                    else { continue }
                    let points = blob.rings.flatMap { $0 }
                    guard !points.isEmpty else { continue }
                    let id: String = row["id"]
                    result[id] = Self.boundingRect(of: points)
                }
            }
            return result
        }
    }

    private static func boundingRect(of points: [GeometryPoint]) -> CGRect {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for point in points {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        guard minX <= maxX, minY <= maxY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Escapes `GLOB`'s four metacharacters by bracketing each one.
    private static func globEscape(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "*", "?", "[", "]":
                output.append("[")
                output.append(character)
                output.append("]")
            default:
                output.append(character)
            }
        }
        return output
    }

    // MARK: - Internals

    /// Storage reads this service has issued. Test instrumentation for the batching
    /// guarantees (BH-649, IM-085): the number is observable, so "one read per batch, not
    /// one per hit" is asserted rather than described.
    private(set) var storageReadCount = 0

    private func read<T: Sendable>(
        _ body: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        storageReadCount += 1
        do { return try await database.read(body) } catch { throw ZPDFSearchError.adaptStorage(error) }
    }

    private func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1e9
    }
}
