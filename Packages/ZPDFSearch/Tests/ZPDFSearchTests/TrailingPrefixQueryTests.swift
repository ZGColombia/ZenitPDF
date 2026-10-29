import Foundation
import GRDB
import Testing
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

/// Live-test finding LT-10: searching `Storkök` returned nothing while the sheet said
/// `Storkökskonsult`, because every compiled term matched whole tokens only. An estimator
/// types prefixes all day — a littera, the first half of a compound — so
/// ``SearchQueryOptions/findAsYouType`` compiles the trailing bare word as a prefix.
///
/// These tests pin the convention (last token only, earlier terms exact), the explicit-
/// syntax escape hatches, the whole-word off-switch, and the fact that the emitted
/// expression still runs against a real FTS5 table. `.standard` stays byte-for-byte what
/// it was; the rest of the suite proves that by passing unchanged.
@Suite("Implied trailing prefix (LT-10)")
struct TrailingPrefixQueryTests {

    // MARK: - Expression bytes

    @Test("The trailing bare word compiles as a prefix; earlier words stay exact")
    func trailingWordBecomesPrefix() {
        #expect(
            FTS5QueryCompiler.compile("Storkök", options: .findAsYouType).matchExpression
                == "\"Storkök\"*"
        )
        let two = FTS5QueryCompiler.compile("Utrustning Stork", options: .findAsYouType)
        #expect(two.matchExpression == "\"Utrustning\" AND \"Stork\"*")
        #expect(two.highlightTerms.count == 2)
        #expect(!two.highlightTerms[0].isPrefix)
        #expect(two.highlightTerms[1].isPrefix)
        // `.standard` is untouched: exact matching stays byte-for-byte what it was.
        #expect(FTS5QueryCompiler.compile("Storkök").matchExpression == "\"Storkök\"")
        #expect(
            FTS5QueryCompiler.compile("Utrustning Stork").matchExpression
                == "\"Utrustning\" AND \"Stork\""
        )
    }

    @Test("Explicit syntax wins: quotes stay phrases, an explicit star stays itself")
    func explicitSyntaxUntouched() {
        // Idempotent over an explicit `*`: same bytes as if the user had typed nothing extra.
        #expect(
            FTS5QueryCompiler.compile("Storkök*", options: .findAsYouType).matchExpression
                == "\"Storkök\"*"
        )
        // A trailing quoted phrase is the user saying "exactly this" and is never starred.
        #expect(
            FTS5QueryCompiler.compile("utrustning \"stork kök\"", options: .findAsYouType)
                .matchExpression == "\"utrustning\" AND \"stork kök\""
        )
        // A trailing operator word or trailing whitespace means the last word was finished.
        #expect(
            FTS5QueryCompiler.compile("Storkök AND", options: .findAsYouType).matchExpression
                == "\"Storkök\""
        )
        #expect(
            FTS5QueryCompiler.compile("Storkök ", options: .findAsYouType).matchExpression
                == "\"Storkök\""
        )
    }

    @Test("Whole-word mode disables the implied prefix")
    func wholeWordDisablesImpliedPrefix() {
        var wholeWord = SearchQueryOptions.findAsYouType
        wholeWord.allowsPrefixMatching = false
        #expect(
            FTS5QueryCompiler.compile("Storkök", options: wholeWord).matchExpression
                == "\"Storkök\""
        )
        var literal = SearchQueryOptions.literalOnly
        literal.impliesTrailingPrefix = true
        #expect(
            FTS5QueryCompiler.compile("Storkök", options: literal).matchExpression
                == "\"Storkök\""
        )
    }

    @Test("The trailing word prefixes even behind NOT, and is still never highlighted")
    func negatedTrailingWord() {
        let query = FTS5QueryCompiler.compile("utrustning NOT stork", options: .findAsYouType)
        #expect(query.matchExpression == "\"utrustning\" NOT \"stork\"*")
        #expect(query.highlightTerms.count == 1)
        #expect(query.highlightTerms[0].tokens == ["utrustning"])
    }

    @Test("An implied prefix cannot smuggle syntax: output stays compiler-written characters")
    func onlySafeCharactersWithImpliedPrefix() {
        for input in [
            "st1\"x", "kök NEAR( a", "a) OR b*", "\"unterminated Stork",
            "; DROP TABLE search_fts; --", "Storkök\u{0000}", "A-10"
        ] {
            let expression = FTS5QueryCompiler.compile(input, options: .findAsYouType)
                .matchExpression
            for scalar in expression.unicodeScalars {
                let allowed = ZPDFTextNormalizer.isTokenScalar(scalar)
                    || scalar == "\"" || scalar == " " || scalar == "*"
                #expect(allowed, "unexpected scalar \(scalar.debugDescription) in \(expression)")
            }
        }
        // The finding's metacharacter example, byte for byte: the quote is a separator,
        // never syntax — and the phrase it opens is explicit syntax, so no star.
        #expect(
            FTS5QueryCompiler.compile("st1\"x", options: .findAsYouType).matchExpression
                == "\"st1\" AND \"x\""
        )
    }

    // MARK: - Against a real FTS5 table

    /// Zone rows are the cheapest way to put exact strings into the real index: pure SQL,
    /// no PDF, no recogniser, and the real `unicode61 remove_diacritics 2` tokeniser on
    /// the other side of the match.
    private func seedZones(_ bed: SearchTestBed, _ contents: [String]) async throws {
        let projectId = bed.projectId
        try await bed.database.write { db in
            for (index, content) in contents.enumerated() {
                try SearchIndexStore.insert(
                    db,
                    SearchIndexRecord(
                        projectId: projectId,
                        documentId: nil,
                        pageId: nil,
                        sourceType: SearchSourceType.zoneName.rawValue,
                        sourceId: "zone-\(index)",
                        content: content
                    )
                )
            }
        }
    }

    private func hits(
        _ bed: SearchTestBed,
        _ text: String,
        options: SearchQueryOptions = .findAsYouType
    ) async throws -> SearchResults {
        let service = SearchService(database: bed.database)
        return try await service.search(
            SearchRequest(
                text: text,
                scope: .project(projectId: bed.projectId),
                queryOptions: options,
                resolvesBounds: false
            )
        )
    }

    @Test("LT-10: typing the start of a word finds the word on the sheet")
    func prefixFindsTheIndexedWord() async throws {
        try await withSearchTestBed { bed in
            try await seedZones(
                bed,
                ["Storkökskonsult", "Utrustning enl. Storkökskonsult", "A-102 DETALJ"]
            )

            // The finding itself, as the inverted line: with exact-only `.standard`
            // options the engine's answer to `Storkök` over a sheet saying
            // `Storkökskonsult` is zero hits — by design, that behaviour is unchanged.
            let exact = try await hits(bed, "Storkök", options: .standard)
            #expect(exact.hits.isEmpty)

            // Same index, same text, find-as-you-type options: both rows are found.
            let prefixed = try await hits(bed, "Storkök")
            #expect(prefixed.query.matchExpression == "\"Storkök\"*")
            #expect(prefixed.hits.count == 2)

            // Two tokens: the finished word stays exact, the trailing one prefixes.
            let two = try await hits(bed, "Utrustning Stork")
            #expect(two.hits.count == 1)
            #expect(two.hits.first?.sourceId == "zone-1")
            let twoExact = try await hits(bed, "Utrustning Stork", options: .standard)
            #expect(twoExact.hits.isEmpty)

            // A littera fragment: `A-10` tokenises into two tokens, so the implied
            // prefix emits a phrase-with-star, and real FTS5 accepts and matches it.
            let littera = try await hits(bed, "A-10")
            #expect(littera.query.matchExpression == "\"A 10\"*")
            #expect(littera.hits.count == 1)
            #expect(littera.hits.first?.sourceId == "zone-2")

            // A quoted word is explicit syntax: exact even in find-as-you-type.
            let quoted = try await hits(bed, "\"Storkök\"")
            #expect(quoted.hits.isEmpty)

            // Whole-word mode: same index, same query, and the hit disappears again.
            var wholeWord = SearchQueryOptions.findAsYouType
            wholeWord.allowsPrefixMatching = false
            let whole = try await hits(bed, "Storkök", options: wholeWord)
            #expect(whole.hits.isEmpty)
        }
    }

    @Test("Hostile input with the implied prefix still runs on a real FTS5 table")
    func hostileInputStillRuns() async throws {
        try await withSearchTestBed { bed in
            try await seedZones(bed, ["Storkökskonsult"])
            let before = try await bed.indexRowCount()
            #expect(before == 1)

            for text in [
                "st1\"x", "Storkök*", "*", "**", "kök NEAR( a", "a) OR b*",
                "\"unterminated Stork", "NOT", "AND Stork", "Stork AND",
                "; DROP TABLE search_fts; --", "zon\"); DROP TABLE ocr_token; --",
                String(repeating: "ö", count: 3000)
            ] {
                // Whatever each compiles to, executing it must neither throw nor write.
                _ = try await hits(bed, text)
            }

            #expect(try await bed.indexRowCount() == before)
        }
    }
}
