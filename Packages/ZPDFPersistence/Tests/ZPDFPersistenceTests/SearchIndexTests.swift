import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// `unicode61 remove_diacritics 2` is in the schema for a concrete reason: Swedish,
/// Norwegian, German and French drawing sets are full of characters a naive tokenizer
/// treats as unrelated to their unaccented forms. These tests are that promise, in the
/// languages it was made for.
struct SearchIndexTests {

    private func makeIndexedPackage(_ label: String, contents: [String])
    async throws -> (ProjectPackage, TestSupport.Workspace) {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let projectId = try await TestSupport.projectIdentifier(of: package)

        try await package.write { db in
            for (index, content) in contents.enumerated() {
                try SearchIndexRecord(
                    projectId: projectId, documentId: documentId, pageId: pageId,
                    sourceType: "markup", sourceId: "s\(index)", content: content
                ).insert(db)
            }
        }
        return (package, workspace)
    }

    static let corpus = [
        "Kök och badrum, plan 2",           // Swedish
        "KÖKSSKÅP typ B",                   // Swedish, upper case
        "Fönsterparti FP-14",
        "Beton armé, dalle épaisse",        // French
        "Türöffnung EG",                    // German
        "Straße 14, Außenwand",
        "Plain ASCII stair nosing"
    ]

    @Test("An unaccented query finds accented content")
    func diacriticsAreFolded() async throws {
        let (package, workspace) = try await makeIndexedPackage("FTSDiacritics", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let cases: [(query: String, expectedHits: Int, label: String)] = [
            ("kok", 1, "kok finds Kök: the diacritic is stripped at index time"),
            ("kök", 1, "the accented spelling of the same query finds the same row"),
            ("KOK", 1, "case is folded too"),
            ("koksskap", 1, "KÖKSSKÅP folds to koksskap"),
            ("kok*", 2, "a prefix query reaches both Kök and KÖKSSKÅP"),
            ("fonsterparti", 1, "fonsterparti finds Fönsterparti"),
            ("arme", 1, "arme finds armé"),
            ("epaisse", 1, "epaisse finds épaisse"),
            ("turoffnung", 1, "turoffnung finds Türöffnung"),
            ("aussenwand", 0, "ß is not folded to ss by unicode61, and we do not pretend it is")
        ]
        for testCase in cases {
            let hits = try await package.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH ?",
                    arguments: [testCase.query]
                ) ?? -1
            }
            #expect(hits == testCase.expectedHits, "\(testCase.label): got \(hits)")
        }
        try await package.close()
    }

    @Test("Prefix queries and multi-token queries behave")
    func prefixAndPhraseQueries() async throws {
        let (package, workspace) = try await makeIndexedPackage("FTSPrefix", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        func hits(_ query: String) async throws -> Int {
            try await package.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH ?",
                    arguments: [query]
                ) ?? -1
            }
        }
        #expect(try await hits("kok*") == 2)
        #expect(try await hits("\"plan 2\"") == 1)
        #expect(try await hits("badrum AND plan") == 1)
        #expect(try await hits("nothinglikethis") == 0)
        try await package.close()
    }

    @Test("The index survives a save and reopen")
    func indexSurvivesASave() async throws {
        let (package, workspace) = try await makeIndexedPackage("FTSPersist", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try await package.save()
        try await package.close()

        let reopened = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .discard
        )
        let hits = try await reopened.read { db in
            try String.fetchAll(
                db, sql: "SELECT content FROM search_fts WHERE search_fts MATCH 'kok*' ORDER BY source_id"
            )
        }
        #expect(hits.count == 2)
        #expect(hits.contains("Kök och badrum, plan 2"))
        #expect(hits.contains("KÖKSSKÅP typ B"))
        try await reopened.close()
    }
}
