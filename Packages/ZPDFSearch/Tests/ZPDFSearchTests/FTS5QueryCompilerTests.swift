import Foundation
import GRDB
import Testing
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

@Suite("FTS5 query compilation")
struct FTS5QueryCompilerTests {

    @Test("A plain word becomes one quoted term")
    func plainWord() {
        let query = FTS5QueryCompiler.compile("ROOM")
        #expect(query.matchExpression == "\"ROOM\"")
        #expect(query.highlightTerms.count == 1)
        #expect(query.highlightTerms[0].foldedTokens == ["room"])
        #expect(!query.isEmpty)
    }

    @Test("Two words are joined by the implied operator")
    func impliedAnd() {
        #expect(FTS5QueryCompiler.compile("ROOM 101").matchExpression == "\"ROOM\" AND \"101\"")
        var options = SearchQueryOptions.standard
        options.impliedOperator = .or
        #expect(
            FTS5QueryCompiler.compile("ROOM 101", options: options).matchExpression
                == "\"ROOM\" OR \"101\""
        )
    }

    @Test("A quoted phrase becomes one quoted string with its words in order")
    func phrase() {
        let query = FTS5QueryCompiler.compile("\"ROOM 101\"")
        #expect(query.matchExpression == "\"ROOM 101\"")
        #expect(query.highlightTerms.count == 1)
        #expect(query.highlightTerms[0].isPhrase)
        #expect(query.highlightTerms[0].tokens == ["ROOM", "101"])
    }

    @Test("A trailing star is a prefix match")
    func prefix() {
        let query = FTS5QueryCompiler.compile("CORR*")
        #expect(query.matchExpression == "\"CORR\"*")
        #expect(query.highlightTerms[0].isPrefix)
        // Turning prefix matching off makes the star a separator, not a term.
        #expect(
            FTS5QueryCompiler.compile("CORR*", options: .literalOnly).matchExpression == "\"CORR\""
        )
    }

    @Test("Uppercase AND, OR and NOT are operators; anything else is a word")
    func booleans() {
        #expect(FTS5QueryCompiler.compile("a OR b").matchExpression == "\"a\" OR \"b\"")
        #expect(FTS5QueryCompiler.compile("a NOT b").matchExpression == "\"a\" NOT \"b\"")
        #expect(FTS5QueryCompiler.compile("a and b").matchExpression == "\"a\" AND \"and\" AND \"b\"")
        #expect(
            FTS5QueryCompiler.compile("a OR b", options: .literalOnly).matchExpression
                == "\"a\" AND \"OR\" AND \"b\""
        )
    }

    @Test("A NOT term is in the expression but is never a highlight term")
    func negatedTermsAreNotHighlighted() {
        let query = FTS5QueryCompiler.compile("room NOT corridor")
        #expect(query.allTerms.count == 2)
        #expect(query.highlightTerms.count == 1)
        #expect(query.highlightTerms[0].tokens == ["room"])
    }

    @Test("A leading, trailing or repeated operator produces no dangling syntax")
    func danglingOperators() {
        #expect(FTS5QueryCompiler.compile("AND OR NOT").matchExpression.isEmpty)
        #expect(FTS5QueryCompiler.compile("AND room").matchExpression == "\"room\"")
        #expect(FTS5QueryCompiler.compile("room AND").matchExpression == "\"room\"")
        #expect(FTS5QueryCompiler.compile("a AND OR b").matchExpression == "\"a\" AND \"b\"")
    }

    @Test("Nothing tokenisable compiles to an empty expression, not to a broken one")
    func nothingToSearch() {
        for input in ["", "   ", "(((", "\"\"", "***", "!@#$%^&*()", "\"\"\"\"", "- -"] {
            let query = FTS5QueryCompiler.compile(input)
            #expect(query.isEmpty, "\(input.debugDescription) should compile to nothing")
        }
    }

    @Test("An over-long query is truncated rather than refused")
    func lengthIsTruncatedNotRefused() {
        let long = String(repeating: "room ", count: 2000)
        let query = FTS5QueryCompiler.compile(long)
        #expect(query.wasTruncated)
        #expect(!query.isEmpty)
        #expect(query.allTerms.count <= SearchLimits.standard.maximumQueryTerms)
    }

    @Test("The emitted expression contains only characters this compiler wrote")
    func onlySafeCharactersEscape() {
        let hostile = "\" NEAR( a , b ) ^col: -x * ((( ))) \\ ; DROP TABLE search_fts; --"
        let expression = FTS5QueryCompiler.compile(hostile).matchExpression
        for scalar in expression.unicodeScalars {
            let allowed = ZPDFTextNormalizer.isTokenScalar(scalar)
                || scalar == "\"" || scalar == " " || scalar == "*"
            #expect(allowed, "unexpected scalar \(scalar.debugDescription) in \(expression)")
        }
        #expect(!expression.contains("("))
        #expect(!expression.contains(";"))
        #expect(!expression.contains(":"))
    }

    // MARK: - Fuzz

    /// Hostile strings a real search box receives, plus the FTS5 metacharacters that
    /// would be a syntax error if any of them reached SQLite unquoted.
    static let hostileSeeds: [String] = [
        "\"", "\"\"", "\"unterminated", "a\"b", "''", "'", "`",
        "(", ")", "(((", ")))", "((a)", "a)", "()",
        "*", "**", "*a", "a*", "a**b", "^", "^a", "a^",
        ":", "col:", "content:", "rowid:", "-", "--", "- -",
        "NEAR", "NEAR(", "NEAR(a b, 3)", "NEAR(\"a\" \"b\", 10)",
        "AND", "OR", "NOT", "AND AND", "OR OR OR", "NOT NOT",
        "a AND", "AND a", "a OR OR b", "a NOT NOT b",
        "{", "}", "{a}", "[", "]", "[a]", "\\", "\\\"", "\\\\",
        "%", "_", "%a%", "a%b", "a_b",
        "; DROP TABLE search_fts;", "1); DELETE FROM ocr_token; --",
        "' OR '1'='1", "\" OR \"\"=\"", "\u{0000}", "\u{FFFF}",
        "😀", "😀 room", "ROOM\u{00AD}101", "\u{202E}room",
        "ROOM 101", "\"ROOM 101\"", "kök", "KÖK*", "för-råd",
        String(repeating: "a", count: 5000),
        String(repeating: "\"", count: 200),
        String(repeating: "*", count: 200),
        String(repeating: "(", count: 200),
        String(repeating: "NEAR(", count: 100)
    ]

    @Test("Every hostile query runs against a real FTS5 table without an error")
    func hostileQueriesNeverProduceASyntaxError() async throws {
        try await withSearchTestBed { bed in
            // A row to match against, so the statement is genuinely executed rather than
            // short-circuited by an empty table.
            let projectId = bed.projectId
            try await bed.database.write { db in
                try SearchIndexStore.insert(
                    db,
                    SearchIndexRecord(
                        projectId: projectId,
                        documentId: nil,
                        pageId: nil,
                        sourceType: SearchSourceType.zoneName.rawValue,
                        sourceId: "zone-1",
                        content: "ROOM 101 CORRIDOR KOK NEAR AND OR NOT"
                    )
                )
            }

            let service = SearchService(database: bed.database)
            var generator = SplitMix64(seed: 0x5A45_4E49_5420_5044)

            // The declared seeds, then deterministic mutations of them: a prefix of one
            // seed concatenated with another. A failure therefore reproduces exactly.
            var corpus = Self.hostileSeeds
            for _ in 0..<400 {
                let a = Self.hostileSeeds[Int(generator.next() % UInt64(Self.hostileSeeds.count))]
                let b = Self.hostileSeeds[Int(generator.next() % UInt64(Self.hostileSeeds.count))]
                let cut = Int(generator.next() % UInt64(max(1, a.count)))
                corpus.append(String(a.prefix(cut)) + b)
            }

            var executed = 0
            for text in corpus {
                let compiled = FTS5QueryCompiler.compile(text)
                // Whatever it compiled to, running it must not throw.
                let results = try await service.search(
                    SearchRequest(text: text, scope: .project(projectId: projectId))
                )
                #expect(results.query.matchExpression == compiled.matchExpression)
                executed += 1
            }

            #expect(executed == corpus.count)
            #expect(executed >= 440)
        }
    }

    @Test("A hostile query cannot delete or alter a row")
    func hostileQueriesCannotWrite() async throws {
        try await withSearchTestBed { bed in
            let projectId = bed.projectId
            try await bed.database.write { db in
                for index in 0..<5 {
                    try SearchIndexStore.insert(
                        db,
                        SearchIndexRecord(
                            projectId: projectId,
                            documentId: nil,
                            pageId: nil,
                            sourceType: SearchSourceType.zoneName.rawValue,
                            sourceId: "zone-\(index)",
                            content: "ZONE \(index) ROOM"
                        )
                    )
                }
            }
            let before = try await bed.indexRowCount()
            #expect(before == 5)

            let service = SearchService(database: bed.database)
            for text in [
                "'; DELETE FROM search_fts; --",
                "\"); DELETE FROM search_fts; --",
                "room\"); DROP TABLE ocr_token; SELECT (\"",
                "1' UNION SELECT * FROM sqlite_master --"
            ] {
                _ = try await service.search(
                    SearchRequest(text: text, scope: .project(projectId: projectId))
                )
            }
            let after = try await bed.indexRowCount()
            #expect(after == before)
        }
    }
}
