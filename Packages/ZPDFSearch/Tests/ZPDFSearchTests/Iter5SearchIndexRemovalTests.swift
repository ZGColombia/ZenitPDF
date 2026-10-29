import CoreGraphics
import Foundation
import GRDB
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

/// V-079: deleting a project's index removes the
/// recognised words from the database *file*, not only from its rows.
@Suite("Search index removal leaves no recognised word in the file (V-079)", .serialized)
struct Iter5SearchIndexRemovalTests {

    /// A word no fixture, schema or index structure contains, in the two spellings the file can
    /// hold it in: as recognised (`ocr_token.token`, FTS content) and folded (FTS terms).
    private static let word = "QUIXOTEWARDROBE"

    private static func fileBytes(_ bed: SearchTestBed) throws -> Data {
        var bytes = Data()
        for suffix in ["", "-wal"] {
            let url = bed.directory.appendingPathComponent("project.sqlite" + suffix)
            if let data = try? Data(contentsOf: url) { bytes.append(data) }
        }
        return bytes
    }

    private static func contains(_ bytes: Data, _ text: String) -> Bool {
        bytes.range(of: Data(text.utf8)) != nil
    }

    /// Old output: after `removeProjectIndexReportingTokens` the rows were gone and the file
    /// still held both spellings — the deleted rows' bytes in free pages and the log, and the
    /// folded term in FTS5's index segments, which a delete only marks.
    @Test("V-079: after removal neither the recognised word nor its indexed term is in the file")
    func removalPurgesTheFile() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(.titleBlockSheet, in: SearchTestBed.fixtureDirectory).url
            let (documentId, _) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            let projectId = bed.projectId
            let words = (0..<200).map { "\(Self.word) SHEET \($0)" }
            try await bed.database.write { db in
                for (index, text) in words.enumerated() {
                    let rect = CGRect(x: 100, y: 500 - Double(index), width: 50, height: 12)
                    let blob = try GeometryBlob(
                        kind: .rectangle,
                        points: RecognitionGeometry.corners(of: rect).map { GeometryPoint(x: $0.x, y: $0.y) }
                    ).encode()
                    try SearchIndexStore.insertOCRToken(db, OCRTokenRecord(
                        pageId: pageId, token: Self.word, normalizedToken: ZPDFTextNormalizer.folded(Self.word),
                        confidence: 0.95, boundsBlob: blob, lineIndex: index, tokenIndex: 0
                    ))
                    try SearchIndexStore.insert(db, SearchIndexRecord(
                        projectId: projectId, documentId: documentId, pageId: pageId,
                        sourceType: SearchSourceType.ocr.rawValue, sourceId: "\(pageId)#\(index)", content: text
                    ))
                }
            }
            _ = try await bed.database.checkpoint(.truncate)
            let before = try Self.fileBytes(bed)
            #expect(Self.contains(before, Self.word), "the probe can see the word while it is indexed")
            #expect(Self.contains(before, Self.word.lowercased()), "and its folded term")

            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            let removal = try await indexer.removeProjectIndexReportingTokens(projectId: projectId)
            #expect(removal.recognisedTokens == 200)
            #expect(removal.rows == 200)

            let after = try Self.fileBytes(bed)
            #expect(!Self.contains(after, Self.word), "a recognised word survived in the file")
            #expect(!Self.contains(after, Self.word.lowercased()), "an indexed term survived in the file")
            // The index still answers after the rewrite, and finds nothing.
            let empty = try await SearchService(database: bed.database).search(SearchRequest(
                text: Self.word,
                scope: .document(projectId: projectId, documentId: documentId),
                confidence: .permissive,
                resolvesBounds: false
            ))
            #expect(empty.hits.isEmpty)
        }
    }
}
