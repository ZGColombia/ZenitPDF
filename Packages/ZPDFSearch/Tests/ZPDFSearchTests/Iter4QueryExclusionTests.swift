import Foundation
import Testing

@testable import ZPDFSearch

/// U-081: an exclusion typed the usual way never
/// compiles into a search that requires the excluded word.
@Suite("Iter4 query exclusions")
struct Iter4QueryExclusionTests {

    @Test("U-081: 'NOT corridor' searches for nothing and reports the exclusion it could not run")
    func leadingNot() {
        let query = FTS5QueryCompiler.compile("NOT corridor")
        // Old output: matchExpression `"corridor"`, and corridor a positive highlight term.
        #expect(query.matchExpression.isEmpty)
        #expect(query.highlightTerms.isEmpty)
        #expect(query.allTerms.isEmpty)
        #expect(query.droppedExclusions.map(\.sourceText) == ["corridor"])
        #expect(query.droppedExclusions.allSatisfy { $0.isNegated })
    }

    @Test("U-081: 'room AND NOT corridor' is FTS5's room NOT corridor")
    func andNot() {
        let query = FTS5QueryCompiler.compile("room AND NOT corridor")
        // Old output: `"room" AND "corridor"`, corridor highlighted.
        #expect(query.matchExpression == "\"room\" NOT \"corridor\"")
        #expect(query.highlightTerms.map(\.sourceText) == ["room"])
        #expect(query.allTerms.map(\.isNegated) == [false, true])
        #expect(query.droppedExclusions.isEmpty)
    }

    @Test("U-081: 'room OR NOT corridor' searches for room alone and reports corridor as dropped")
    func orNot() {
        let query = FTS5QueryCompiler.compile("room OR NOT corridor")
        // Old output: `"room" OR "corridor"`, corridor highlighted.
        #expect(query.matchExpression == "\"room\"")
        #expect(query.highlightTerms.map(\.sourceText) == ["room"])
        #expect(query.droppedExclusions.map(\.sourceText) == ["corridor"])
        // The OR that preceded the dropped exclusion still joins what follows.
        #expect(FTS5QueryCompiler.compile("room OR NOT corridor kitchen").matchExpression == "\"room\" OR \"kitchen\"")
    }

    @Test("U-081: the find-as-you-type and whole-word options the app passes behave the same")
    func appOptions() {
        for options in [SearchQueryOptions.findAsYouType, SearchQueryOptions(allowsPrefixMatching: false)] {
            #expect(FTS5QueryCompiler.compile("NOT corridor", options: options).matchExpression.isEmpty)
            #expect(FTS5QueryCompiler.compile("room AND NOT corridor", options: options).matchExpression.hasPrefix("\"room\" NOT \"corridor\""))
            #expect(FTS5QueryCompiler.compile("room OR NOT corridor", options: options).matchExpression == "\"room\"")
        }
        // Unchanged: a plain NOT between two words, a doubled NOT, and a run that keeps its first.
        #expect(FTS5QueryCompiler.compile("room NOT corridor").matchExpression == "\"room\" NOT \"corridor\"")
        #expect(FTS5QueryCompiler.compile("a NOT NOT b").matchExpression == "\"a\" NOT \"b\"")
        #expect(FTS5QueryCompiler.compile("a OR AND b").matchExpression == "\"a\" OR \"b\"")
        #expect(FTS5QueryCompiler.compile("AND OR NOT").matchExpression.isEmpty)
    }

    @Test("U-081: against a real index the excluded word is never what the search finds")
    func endToEnd() async throws {
        try await withSearchTestBed { bed in
            try await bed.addMarkupOnSyntheticPage(subject: "ROOM 101", label: "office")
            try await bed.addMarkupOnSyntheticPage(subject: "ROOM 102 CORRIDOR", label: "hall")
            try await bed.addMarkupOnSyntheticPage(subject: "CORRIDOR 3", label: "stair")
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)
            let service = SearchService(database: bed.database)
            func search(_ text: String) async throws -> SearchResults {
                try await service.search(SearchRequest(
                    text: text, scope: .project(projectId: bed.projectId),
                    queryOptions: .findAsYouType, resolvesBounds: false
                ))
            }
            // Old output: 2 hits, the two markups that do say CORRIDOR.
            let notCorridor = try await search("NOT corridor")
            #expect(notCorridor.hits.isEmpty)
            #expect(notCorridor.query.droppedExclusions.count == 1)
            // Old output: 1 hit, ROOM 102 CORRIDOR.
            let roomNotCorridor = try await search("room AND NOT corridor")
            #expect(roomNotCorridor.hits.count == 1)
            #expect(roomNotCorridor.hits.allSatisfy { !$0.snippet.uppercased().contains("CORRIDOR") })
            // Old output: 3 hits (room OR corridor). Now room alone, with the exclusion reported.
            let roomOrNot = try await search("room OR NOT corridor")
            #expect(roomOrNot.hits.count == 2)
            #expect(roomOrNot.query.droppedExclusions.map(\.sourceText) == ["corridor"])
        }
    }
}
