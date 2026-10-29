import CoreGraphics
import Foundation
import GRDB
import Testing
import ZPDFPersistence

@testable import ZPDFSearch

/// R-155: every word a query highlights reads its own candidate budget, and a phrase whose
/// common word filled its budget is completed from the rarest word's lines.
@Suite("OCR highlight budget per term (R-155)", .serialized)
struct OCRHighlightBudgetTests {

    /// A small budget, so the crowding is a dozen rows rather than hundreds.
    private static let limits = SearchLimits(maximumBoundsTokensPerHit: 8)

    /// A page row with the given recognised tokens `(text, line, index, confidence)` and one
    /// `ocr` index row whose content is those tokens in reading order.
    private static func page(
        _ bed: SearchTestBed,
        tokens: [(String, Int, Int, Double)]
    ) async throws -> String {
        let markupId = try await bed.addMarkupOnSyntheticPage(subject: "anchor")
        let projectId = bed.projectId
        return try await bed.database.write { db -> String in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT document_id, page_id FROM markup WHERE id = ?", arguments: [markupId]
            ))
            let documentId: String = row["document_id"]
            let pageId: String = row["page_id"]
            for (text, line, index, confidence) in tokens {
                let x = Double(index) * 20, y = 700 - Double(line) * 20
                let blob = try GeometryBlob(kind: .rectangle, points: [
                    GeometryPoint(x: x, y: y), GeometryPoint(x: x + 15, y: y),
                    GeometryPoint(x: x + 15, y: y + 10), GeometryPoint(x: x, y: y + 10)
                ]).encode()
                try SearchIndexStore.insertOCRToken(db, OCRTokenRecord(
                    pageId: pageId, token: text, normalizedToken: text.lowercased(), confidence: confidence,
                    boundsBlob: blob, lineIndex: line, tokenIndex: index
                ))
            }
            let content = tokens.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0).joined(separator: " ")
            try SearchIndexStore.insert(db, SearchIndexRecord(
                projectId: projectId, documentId: documentId, pageId: pageId,
                sourceType: SearchSourceType.ocr.rawValue, sourceId: pageId,
                content: ZPDFTextNormalizer.indexable(content, options: .standard)
            ))
            return pageId
        }
    }

    /// Old output: the twelve `1` tokens on line 0 took all eight candidate rows, so ROOM had
    /// no rectangle and the hit's confidence was 0.95 — the `1` tokens' — instead of 0.3.
    @Test("R-155: a common prefix no longer crowds out another term's only token")
    func separateTermsKeepTheirOwnBudget() async throws {
        try await withSearchTestBed { bed in
            var tokens: [(String, Int, Int, Double)] = (0..<12).map { ("1", 0, $0, 0.95) }
            tokens.append(("ROOM", 1, 0, 0.3))
            _ = try await Self.page(bed, tokens: tokens)
            let service = SearchService(database: bed.database, limits: Self.limits)
            let results = try await service.search(SearchRequest(
                text: "ROOM 1", scope: .project(projectId: bed.projectId), sources: .ocrOnly,
                queryOptions: .findAsYouType, confidence: .permissive
            ))
            let hit = try #require(results.hits.first)
            // By hand: ROOM (0.3) plus seven of the `1` tokens (0.95), capped at eight boxes.
            #expect(hit.ocrConfidence == 0.3)
            #expect(hit.bounds.count == 8)
            #expect(hit.bounds.contains { abs($0.minY - 680) < 1e-9 && abs($0.minX) < 1e-9 }, "ROOM's box, on line 1")
        }
    }

    /// Old output: no rectangle and no confidence — the thirteen `a` tokens filled the budget
    /// and `102` was never read, so the phrase `a 102` could not be matched.
    @Test("R-155: a split word is highlighted even behind a page full of its common half")
    func phraseIsCompletedFromItsRarestWord() async throws {
        try await withSearchTestBed { bed in
            var tokens: [(String, Int, Int, Double)] = (0..<12).map { ("A", 0, $0, 0.95) }
            tokens.append(("A", 1, 0, 0.9))
            tokens.append(("102", 1, 1, 0.7))
            _ = try await Self.page(bed, tokens: tokens)
            let service = SearchService(database: bed.database, limits: Self.limits)
            let results = try await service.search(SearchRequest(
                text: "A-102", scope: .project(projectId: bed.projectId), sources: .ocrOnly,
                confidence: .permissive
            ))
            let hit = try #require(results.hits.first)
            // By hand: the phrase is `a` at (1, 0) and `102` at (1, 1); the weaker is 0.7.
            #expect(hit.bounds.count == 2)
            #expect(hit.ocrConfidence == 0.7)
            #expect(hit.bounds.allSatisfy { abs($0.minY - 680) < 1e-9 })
        }
    }
}
