import Foundation
import GRDB
import Testing
import ZPDFPersistence

@testable import ZPDFSearch

/// R-163 (one DELETE, SQLite's own count) and R-152 /
/// R-162 (the per-markup reindex deletes a chunk's custom values in one statement and writes
/// its rows through the same helpers as the full rebuild).
@Suite("Search index maintenance (R-152, R-162, R-163)", .serialized)
struct SearchIndexMaintenanceTests {

    private func hits(_ text: String, _ bed: SearchTestBed) async throws -> Int {
        try await SearchService(database: bed.database).search(
            SearchRequest(text: text, scope: .project(projectId: bed.projectId), resolvesBounds: false)
        ).hits.count
    }

    /// The deletes used to run `SELECT COUNT(*)` and then the same `DELETE`, two full scans of
    /// an FTS table whose key columns are UNINDEXED. They now run the DELETE alone and return
    /// `changesCount`; this pins that SQLite counts **logical** FTS5 rows there, not the
    /// shadow-table writes behind them, so every caller still gets the number it got before.
    @Test("R-163: every delete returns the logical rows it removed, from one statement")
    func deleteCountsAreLogicalRows() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(
                into: SearchTestBed.fixtureDirectory, name: "scanned-words-4.pdf", pages: 4
            )
            let (documentId, _) = try await bed.addDocument(at: url)
            let page0 = bed.pageId(documentId: documentId, pageIndex: 0)
            let page1 = bed.pageId(documentId: documentId, pageIndex: 1)
            let projectId = bed.projectId

            let counts = try await bed.database.write { db -> [Int] in
                func row(_ page: String, _ type: SearchSourceType, _ n: Int) throws {
                    try SearchIndexStore.insert(db, SearchIndexRecord(
                        projectId: projectId, documentId: documentId, pageId: page,
                        sourceType: type.rawValue, sourceId: "\(page)-\(type.rawValue)-\(n)",
                        content: "room \(n) corridor drawing"
                    ))
                }
                func token(_ page: String, _ n: Int) throws {
                    try SearchIndexStore.insertOCRToken(db, OCRTokenRecord(
                        pageId: page, token: "ROOM", normalizedToken: "room", confidence: 0.9,
                        boundsBlob: Data([0]), lineIndex: 0, tokenIndex: n
                    ))
                }
                for n in 0..<5 { try row(page0, .ocr, n) }
                for n in 0..<3 { try row(page1, .ocr, n) }
                for n in 0..<2 { try row(page0, .pdfText, n) }
                for n in 0..<4 { try token(page0, n) }
                for n in 0..<2 { try token(page1, n) }

                return [
                    try SearchIndexStore.deleteRows(db, pageId: page0, types: [.ocr]),
                    try SearchIndexStore.deleteRows(db, pageId: page0, types: [.ocr]),
                    try SearchIndexStore.deleteRows(db, documentId: documentId, types: [.ocr, .pdfText]),
                    try SearchIndexStore.deleteRows(db, documentId: documentId, types: []),
                    try SearchIndexStore.deleteOCRTokens(db, pageId: page0),
                    try SearchIndexStore.deleteOCRTokens(db, pageId: page0),
                    try SearchIndexStore.deleteProjectOCRTokens(db, projectId: projectId)
                ]
            }
            // By hand: 5 ocr rows on page 0; then none; then page 1's 3 ocr rows plus page 0's
            // 2 pdf-text rows; no types, no statement; 4 tokens on page 0; none; page 1's 2.
            #expect(counts == [5, 0, 5, 0, 4, 0, 2])
            #expect(try await bed.indexRowCount() == 0)
            #expect(try await bed.ocrTokenCount() == 0)
        }
    }

    /// Old code: one COUNT and one DELETE per markup id for its custom values. The rebuilt
    /// delete is one statement per chunk, keyed on the part of `source_id` before the `/`.
    @Test("R-152: a per-markup reindex deletes exactly the named markups' custom values")
    func perMarkupReindexDeletesOnlyNamedCustomValues() async throws {
        try await withSearchTestBed { bed in
            var markups: [String] = []
            for index in 0..<4 {
                let id = try await bed.addMarkupOnSyntheticPage(subject: "Wall \(index)")
                try await bed.addCustomValue(markupId: id, columnName: "Finish \(index)", value: "gloss\(index)")
                try await bed.addCustomValue(markupId: id, columnName: "Grade \(index)", value: "grade\(index)")
                markups.append(id)
            }
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            let full = try await indexer.indexProjectAnnotations(projectId: bed.projectId)
            #expect(full.markupRowsInserted == 4 && full.customValueRowsInserted == 8)

            let named = markups
            try await bed.database.write { db in
                for id in named {
                    try db.execute(sql: "UPDATE custom_value SET value_text = 'matte' || value_text WHERE markup_id = ?", arguments: [id])
                }
            }
            let report = try await indexer.indexAnnotations(projectId: bed.projectId, markupIds: [markups[1], markups[3]])
            // By hand: markups 1 and 3 each lose a subject row and two custom-value rows (6),
            // and get the same back.
            #expect(report.rowsDeleted == 6)
            #expect(report.markupRowsInserted == 2)
            #expect(report.customValueRowsInserted == 4)
            #expect(try await bed.indexRowCount(sourceType: .customValue) == 8)
            #expect(try await hits("mattegloss1", bed) == 1)
            #expect(try await hits("mattegloss3", bed) == 1)
            // Not named, not touched.
            #expect(try await hits("gloss0", bed) == 1)
            #expect(try await hits("mattegloss0", bed) == 0)
            #expect(try await hits("gloss2", bed) == 1)
        }
    }

    /// The two paths share their row writers, so a markup reindexed one way or the other ends
    /// with byte-identical rows.
    @Test("R-162: the full rebuild and the per-markup reindex write identical rows")
    func fullAndIncrementalWriteTheSameRows() async throws {
        try await withSearchTestBed { bed in
            let id = try await bed.addMarkupOnSyntheticPage(subject: "Kitchen  WALL", label: "Tiles", comment: "Gloss finish")
            try await bed.addCustomValue(markupId: id, columnName: "Finish", value: "Épée")
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            func rows() async throws -> [String] {
                try await bed.database.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT source_type, source_id, document_id, page_id, content FROM search_fts
                        ORDER BY source_type, source_id
                        """).map { "\($0)" }
                }
            }
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)
            let fromFull = try await rows()
            try await indexer.indexAnnotations(projectId: bed.projectId, markupIds: [id])
            let fromIncremental = try await rows()
            #expect(fromFull.count == 4)
            #expect(fromFull == fromIncremental)
        }
    }
}
