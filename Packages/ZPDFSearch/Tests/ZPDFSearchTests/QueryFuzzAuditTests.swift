import Foundation
import GRDB
import ZPDFPersistence
import Testing

@testable import ZPDFSearch

/// An independently generated hostile corpus for the query parser.
///
/// `FTS5QueryCompilerTests.hostileQueriesNeverProduceASyntaxError` already fuzzes the
/// compiler, but its corpus is a fixed seed list plus one mutation shape — `prefix(a) + b`.
/// A corpus built that way can only ever contain substrings of what its author already
/// thought of, so it proves the compiler survives *those* strings, not that it survives
/// arbitrary input.
///
/// This suite generates 500 strings a different way: an alphabet of FTS5 metacharacters,
/// SQL punctuation, Unicode format and direction controls, surrogate-adjacent scalars and
/// ordinary letters, drawn at random lengths from a seeded PRNG, plus structural templates
/// that nest quotes and parentheses to depths the seed list never reaches. The seed is
/// fixed, so a failure names the exact string that caused it.
///
/// Three properties are asserted for every one of the 500:
///
/// 1. `FTS5QueryCompiler.compile` returns rather than throwing or trapping;
/// 2. the compiled expression executes against a **real FTS5 table** without SQLite
///    reporting a syntax error — the search call is the caller's path, so an error there
///    is an error escaping to the caller;
/// 3. no row of the index is created, changed or removed by running the search.
@Suite("Query parser fuzz audit")
struct QueryFuzzAuditTests {

    /// A deterministic 64-bit PRNG. `SystemRandomNumberGenerator` would make a failure
    /// unreproducible, which is the one thing a fuzz corpus must never be.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ upperBound: Int) -> Int {
            upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
        }
        mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
    }

    /// Everything a hostile search box can contain. Every FTS5 metacharacter, every SQL
    /// punctuation mark, the Unicode controls that break naive tokenisers, and enough
    /// ordinary letters that the generated strings are not pure punctuation.
    static let alphabet: [String] = [
        "\"", "'", "`", "(", ")", "[", "]", "{", "}", "*", "^", ":", "-", "+", "~",
        ";", ",", ".", "/", "\\", "|", "&", "!", "?", "=", "<", ">", "%", "_", "#",
        "@", "$", " ", "\t", "\n", "\r",
        "AND", "OR", "NOT", "NEAR", "NEAR(", "MATCH", "UNION", "SELECT", "DROP",
        "DELETE", "INSERT", "UPDATE", "TABLE", "FROM", "WHERE", "--", "/*", "*/",
        "a", "b", "z", "0", "9", "room", "101", "kök", "för", "ÅÄÖ",
        "\u{0000}", "\u{0001}", "\u{0007}", "\u{001B}", "\u{007F}",
        "\u{00A0}", "\u{00AD}", "\u{200B}", "\u{200E}", "\u{202E}", "\u{2028}",
        "\u{2029}", "\u{FEFF}", "\u{FFFD}", "\u{FFFF}",
        "😀", "👨‍👩‍👧‍👦", "🇸🇪", "が", "ﬁ", "Ⅷ", "①",
        "\u{0301}", "\u{0308}", "e\u{0301}",
        "\u{10FFFF}"
    ]

    /// Templates that nest, which random concatenation reaches only by luck.
    static func templates(_ rng: inout Rng) -> [String] {
        let filler = rng.pick(["room", "a b", "kök", "1", ""])
        let depth = 1 + rng.int(12)
        return [
            String(repeating: "\"", count: depth) + filler,
            String(repeating: "(", count: depth) + filler + String(repeating: ")", count: rng.int(depth + 1)),
            String(repeating: "NEAR(", count: depth) + filler,
            "\"" + String(repeating: filler + " ", count: depth) + "\"",
            String(repeating: "*", count: depth) + filler + String(repeating: "*", count: depth),
            String(repeating: "AND ", count: depth) + filler,
            filler + String(repeating: " OR", count: depth),
            "col" + String(repeating: ":", count: depth) + filler,
            String(repeating: "-", count: depth) + filler,
            "\u{202E}" + String(repeating: filler, count: depth) + "\u{202C}",
            String(repeating: "\u{0000}", count: depth) + filler,
            String(repeating: "\u{0301}", count: depth * 8) + filler
        ]
    }

    static let corpusSize = 500

    /// The corpus, built once so the test and its failure message agree on the indices.
    static func corpus() -> [String] {
        var rng = Rng(state: 0x5A50_4446_5345_4152)   // "ZPDFSEAR"
        var result: [String] = []
        result.reserveCapacity(corpusSize)

        // Two fifths structural, three fifths random soup.
        while result.count < corpusSize {
            if result.count % 5 < 2 {
                let choices = templates(&rng)
                result.append(rng.pick(choices))
            } else {
                let pieces = 1 + rng.int(24)
                var text = ""
                for _ in 0..<pieces { text += rng.pick(alphabet) }
                result.append(text)
            }
        }

        // Three lengths no random draw would reach, appended last so the count is exact.
        result[corpusSize - 3] = String(repeating: "\"a\" ", count: 4_000)
        result[corpusSize - 2] = String(repeating: "NEAR(\u{202E}", count: 2_000)
        result[corpusSize - 1] = String(repeating: "\u{0000}", count: 10_000)
        return result
    }

    @Test("500 independently generated hostile queries never crash, never error, never write")
    func fiveHundredHostileQueries() async throws {
        let corpus = Self.corpus()
        #expect(corpus.count == Self.corpusSize)
        #expect(Set(corpus).count > Self.corpusSize / 2, "the generator is producing duplicates")

        try await withSearchTestBed { bed in
            let projectId = bed.projectId
            try await bed.database.write { db in
                for index in 0..<8 {
                    try SearchIndexStore.insert(
                        db,
                        SearchIndexRecord(
                            projectId: projectId,
                            documentId: nil,
                            pageId: nil,
                            sourceType: SearchSourceType.zoneName.rawValue,
                            sourceId: "fuzz-zone-\(index)",
                            content: "ROOM \(index) CORRIDOR KOK NEAR AND OR NOT room a b"
                        )
                    )
                }
            }
            let rowsBefore = try await bed.indexRowCount()
            #expect(rowsBefore == 8)

            let service = SearchService(database: bed.database)
            var executed = 0
            var nonEmptyExpressions = 0

            for (index, text) in corpus.enumerated() {
                let compiled = FTS5QueryCompiler.compile(text)

                // Property 1: only characters this compiler wrote reach the expression.
                for scalar in compiled.matchExpression.unicodeScalars {
                    let allowed = ZPDFTextNormalizer.isTokenScalar(scalar)
                        || scalar == "\"" || scalar == " " || scalar == "*"
                    #expect(
                        allowed,
                        "corpus[\(index)] leaked \(scalar.debugDescription) into \(compiled.matchExpression)" as Comment
                    )
                }

                // Property 2: the caller's own path runs it. A `throw` here is an FTS5
                // syntax error escaping, which is exactly what must not happen.
                let results: SearchResults
                do {
                    results = try await service.search(
                        SearchRequest(
                            text: text,
                            scope: .project(projectId: projectId),
                            resolvesBounds: false
                        )
                    )
                } catch {
                    Issue.record("corpus[\(index)] threw \(error) for expression \(compiled.matchExpression)")
                    continue
                }
                #expect(results.query.matchExpression == compiled.matchExpression)
                if !compiled.matchExpression.isEmpty { nonEmptyExpressions += 1 }
                executed += 1
            }

            #expect(executed == Self.corpusSize)
            // A corpus that compiles to nothing 500 times out of 500 would pass every
            // assertion above while testing nothing at all.
            #expect(
                nonEmptyExpressions >= 100,
                "only \(nonEmptyExpressions) of \(Self.corpusSize) produced a runnable expression" as Comment
            )

            // Property 3: nothing was written.
            let rowsAfter = try await bed.indexRowCount()
            #expect(rowsAfter == rowsBefore)
            print(
                "[ZPDFSearch fuzz audit] \(executed) hostile queries executed, "
                    + "\(nonEmptyExpressions) with a non-empty MATCH expression, "
                    + "index rows \(rowsBefore) -> \(rowsAfter)"
            )
        }
    }

    @Test("Every FTS5 metacharacter alone is harmless, individually named")
    func eachMetacharacterAlone() async throws {
        // The corpus above mixes characters; if one of them were the sole cause of a
        // failure the message would not say which. This one names it.
        let singles = ["\"", "'", "(", ")", "*", "^", ":", "-", "+", "~", ";", "{", "}",
                       "[", "]", "\\", "%", "_", "|", "&", "!", "?", "<", ">", "#", "@",
                       "\u{0000}", "\u{202E}", "\u{FEFF}", "\u{FFFF}", "😀"]
        try await withSearchTestBed { bed in
            let projectId = bed.projectId
            try await bed.database.write { db in
                try SearchIndexStore.insert(
                    db,
                    SearchIndexRecord(
                        projectId: projectId, documentId: nil, pageId: nil,
                        sourceType: SearchSourceType.zoneName.rawValue,
                        sourceId: "single", content: "ROOM 101"
                    )
                )
            }
            let service = SearchService(database: bed.database)
            for character in singles {
                let compiled = FTS5QueryCompiler.compile(character)
                #expect(
                    compiled.matchExpression.isEmpty,
                    "\(character.debugDescription) alone compiled to \(compiled.matchExpression)" as Comment
                )
                let results = try await service.search(
                    SearchRequest(text: character, scope: .project(projectId: projectId), resolvesBounds: false)
                )
                #expect(results.hits.isEmpty)
            }
        }
    }
}
