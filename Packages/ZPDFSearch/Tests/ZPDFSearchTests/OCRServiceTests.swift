import CoreGraphics
import Foundation
import os
import GRDB
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport

@testable import ZPDFSearch

@Suite("On-device recognition", .serialized)
struct OCRServiceTests {

    /// Recognition settings for a synthetic sheet: English and Swedish, no language
    /// correction, because `A-102` must come back as `A-102` and not as a word.
    private static let settings = OCRSettings(
        recognitionLanguages: ["en-US", "sv-SE"],
        usesLanguageCorrection: false,
        usesAccurateRecognition: true,
        renderDPI: 200,
        maximumConcurrentPages: 4
    )

    private static func scannedURL() throws -> URL {
        try ScannedSheetFixture.write(into: SearchTestBed.fixtureDirectory)
    }

    @Test("This machine has an accurate recogniser and the languages the suite asks for")
    func recogniserIsAvailable() {
        let languages = OCRService.supportedRecognitionLanguages()
        #expect(!languages.isEmpty)
        #expect(languages.contains("en-US"))
        #expect(languages.contains("sv-SE"))
    }

    @Test("A scanned page finds nothing before recognition and the expected words after")
    func nothingBeforeOCRAndWordsAfter() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.scannedURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)

            // The fixture really has no text layer. Everything below rests on this.
            let pageText = try await bed.provider.pageText(of: handle, pageIndex: 0)
            #expect(pageText.availability == .noTextLayer)

            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            let textReport = try await indexer.indexDocumentText(
                documentId: documentId,
                handle: handle
            )
            #expect(textReport.pagesWithoutTextLayer == [0])

            let service = SearchService(database: bed.database)
            let scope = SearchScope.document(projectId: bed.projectId, documentId: documentId)

            // Before.
            for word in ["ROOM", "CORRIDOR", "KÖK"] {
                let before = try await service.search(
                    SearchRequest(text: word, scope: scope, resolvesBounds: false)
                )
                #expect(before.isEmpty, "\(word) was found before recognition")
            }

            // Recognise.
            let ocr = OCRService(
                database: bed.database,
                provider: bed.provider,
                settings: Self.settings
            )
            let report = try await ocr.recognize(documentId: documentId, handle: handle)
            #expect(report.pagesRequested == 1)
            #expect(report.pagesRecognised == 1)
            #expect(report.tokensWritten >= 8)
            #expect(try await bed.ocrTokenCount(pageId: pageId) == report.tokensWritten)

            // After. Every word the fixture declares is findable, including the accented
            // one and the sheet number, and searching for the folded form finds it too.
            for word in ["ROOM", "101", "CORRIDOR", "DRAWING", "KÖK", "kok", "FÖRRÅD", "forrad"] {
                let after = try await service.search(
                    SearchRequest(
                        text: word,
                        scope: scope,
                        confidence: .permissive,
                        resolvesBounds: false
                    )
                )
                #expect(!after.isEmpty, "\(word) was not found after recognition")
                #expect(after.hits.allSatisfy { $0.sourceType == .ocr })
            }
        }
    }

    @Test("A recognised hit carries page-space bounds inside the page")
    func recognisedHitsCarryBounds() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.scannedURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let ocr = OCRService(
                database: bed.database,
                provider: bed.provider,
                settings: Self.settings
            )
            try await ocr.recognize(documentId: documentId, handle: handle)

            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: .document(projectId: bed.projectId, documentId: documentId),
                    confidence: .permissive
                )
            )
            let hit = try #require(results.hits.first)
            #expect(hit.boundsSource == .recognisedTokens)
            #expect(hit.bounds.count == 1)

            let rect = try #require(hit.bounds.first)
            let page = CGRect(origin: .zero, size: ScannedSheetFixture.pageSize)
            #expect(page.contains(rect), "\(rect) is outside \(page)")
            #expect(rect.width > 0)
            #expect(rect.height > 0)
            // "CORRIDOR" is the second of four lines, drawn 120 pt below the top of the
            // sheet and then 96 pt lower again, at 48-point type.
            #expect(rect.minY > 792 - 240)
            #expect(rect.maxY < 792 - 100)
            #expect(rect.minX > 60)
        }
    }

    @Test("A page that already has enough text is skipped")
    func pagesWithTextAreSkipped() async throws {
        try await withSearchTestBed { bed in
            let url = try ZPDFFixtures.make(
                .titleBlockSheet,
                in: SearchTestBed.fixtureDirectory
            ).url
            let (documentId, handle) = try await bed.addDocument(at: url)
            let ocr = OCRService(
                database: bed.database,
                provider: bed.provider,
                settings: Self.settings
            )
            let report = try await ocr.recognize(documentId: documentId, handle: handle)
            #expect(report.pagesSkipped == 1)
            #expect(report.tokensWritten == 0)
            #expect(report.pages.first?.skipReason == .hasTextLayer)
            #expect(try await bed.ocrTokenCount() == 0)

            // Turning the skip off recognises it after all.
            var eager = Self.settings
            eager.skipsPagesWithTextLayer = false
            await ocr.update(settings: eager)
            let forced = try await ocr.recognize(documentId: documentId, handle: handle)
            #expect(forced.pagesSkipped == 0)
            #expect(forced.tokensWritten > 0)
        }
    }

    @Test("Recognising twice replaces the tokens rather than duplicating them")
    func recognitionIsIdempotent() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.scannedURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            let ocr = OCRService(
                database: bed.database,
                provider: bed.provider,
                settings: Self.settings
            )

            let first = try await ocr.recognize(documentId: documentId, handle: handle)
            let tokensAfterFirst = try await bed.ocrTokenCount(pageId: pageId)
            #expect(tokensAfterFirst == first.tokensWritten)

            let second = try await ocr.recognize(documentId: documentId, handle: handle)
            #expect(second.tokensWritten == first.tokensWritten)
            #expect(try await bed.ocrTokenCount(pageId: pageId) == tokensAfterFirst)
            #expect(try await bed.indexRowCount(sourceType: .ocr, documentId: documentId) == 1)
        }
    }

    @Test("Cancelling mid-run leaves the index consistent, page by page")
    func cancellationLeavesAConsistentIndex() async throws {
        try await withSearchTestBed { bed in
            // Eight copies of the scanned sheet in one document, so there is a middle to
            // cancel in. Recognition of one page takes long enough that the cancellation
            // lands between pages rather than before the first.
            let pageCount = 12
            let url = try Self.multiPageScannedURL(pageCount: pageCount)
            let (documentId, handle) = try await bed.addDocument(at: url)
            let descriptors = try await bed.provider.pageDescriptors(of: handle)
            #expect(descriptors.count == pageCount)

            let reported = ReportedPages()
            let ocr = OCRService(
                database: bed.database,
                provider: bed.provider,
                settings: OCRSettings(
                    recognitionLanguages: ["en-US", "sv-SE"],
                    usesLanguageCorrection: false,
                    renderDPI: 200,
                    // One at a time, so "cancel after the third page" means exactly that.
                    maximumConcurrentPages: 1
                )
            )

            let task = Task { [reported] in
                try await ocr.recognize(documentId: documentId, handle: handle) { progress in
                    reported.append(progress.lastPage.pageId)
                }
            }
            // Let a couple of pages land, then stop. The poll is bounded so a machine on
            // which recognition somehow never completes fails the test rather than hanging.
            var polls = 0
            while reported.count < 2, polls < 500 {
                try await Task.sleep(for: .milliseconds(10))
                polls += 1
            }
            task.cancel()

            var cancelled = false
            do {
                _ = try await task.value
            } catch let error as ZPDFSearchError {
                cancelled = error == .cancelled
            }
            #expect(cancelled, "the run should have reported cancellation")

            let committed = reported.snapshot()
            #expect(committed.count >= 2)
            #expect(committed.count < pageCount, "the run finished instead of being cancelled")

            // The invariant: every page is either fully in the index or entirely absent.
            let pagesWithTokens = try await bed.pagesWithTokens()
            let pagesWithRows = try await bed.pagesWithOCRIndexRows()
            #expect(pagesWithTokens == pagesWithRows)

            // And every page that has anything is one the run reported as committed.
            #expect(pagesWithTokens.isSubset(of: Set(committed)))

            // No page has a partial token run: token indices are contiguous from 0 per line.
            let gaps = try await bed.database.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM (
                        SELECT page_id, line_index,
                               COUNT(*) AS n,
                               MIN(token_index) AS lo,
                               MAX(token_index) AS hi
                        FROM ocr_token GROUP BY page_id, line_index
                    ) WHERE lo != 0 OR hi != n - 1
                    """
                ) ?? -1
            }
            #expect(gaps == 0)

            // The index is usable: a search over what survived returns only committed pages.
            let service = SearchService(database: bed.database)
            let results = try await service.search(
                SearchRequest(
                    text: "CORRIDOR",
                    scope: .document(projectId: bed.projectId, documentId: documentId),
                    confidence: .permissive,
                    resolvesBounds: false
                )
            )
            #expect(results.hits.count == pagesWithRows.count)
            let hitPageIds = Set(results.hits.compactMap(\.pageId))
            #expect(hitPageIds == pagesWithRows)
        }
    }

    @Test("A page range outside the document is a typed error")
    func pageRangeIsChecked() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.scannedURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let ocr = OCRService(
                database: bed.database,
                provider: bed.provider,
                settings: Self.settings
            )
            await #expect(
                throws: ZPDFSearchError.pageRangeOutOfBounds(lowerBound: 0, upperBound: 5, pageCount: 1)
            ) {
                try await ocr.recognize(documentId: documentId, handle: handle, pageRange: 0..<5)
            }
            #expect(try await bed.ocrTokenCount() == 0)
        }
    }

    @Test("Recognition of one page, timed")
    func onePageTiming() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.scannedURL()
            let (documentId, handle) = try await bed.addDocument(at: url)
            let ocr = OCRService(
                database: bed.database,
                provider: bed.provider,
                settings: Self.settings
            )
            let report = try await ocr.recognize(
                documentId: documentId,
                handle: handle,
                pageRange: 0..<1
            )
            let page = try #require(report.pages.first)
            print(
                """
                [ZPDFSearch timing] OCR, one US Letter page at \
                \(String(format: "%.0f", page.effectiveDPI)) dpi: \
                \(String(format: "%.1f", page.elapsedSeconds * 1000)) ms render+recognise, \
                \(String(format: "%.1f", report.elapsedSeconds * 1000)) ms including the commit, \
                \(page.tokenCount) tokens, mean confidence \
                \(String(format: "%.3f", page.averageConfidence ?? 0))
                """
            )
            #expect(page.tokenCount > 0)
            #expect(report.elapsedSeconds > 0)
        }
    }

    // MARK: - Helpers

    /// A collector the progress callback can write to from any executor.
    ///
    /// `OSAllocatedUnfairLock` rather than a hand-rolled `@unchecked Sendable` box: the
    /// house rules forbid the latter without an ADR, and this is the standard-library
    /// answer to exactly this problem.
    private struct ReportedPages: Sendable {
        private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])

        func append(_ pageId: String) {
            storage.withLock { $0.append(pageId) }
        }

        var count: Int { storage.withLock { $0.count } }

        func snapshot() -> [String] { storage.withLock { $0 } }
    }

    /// `pageCount` copies of the scanned sheet in one document.
    private static func multiPageScannedURL(pageCount: Int) throws -> URL {
        let url = SearchTestBed.fixtureDirectory
            .appendingPathComponent("scanned-words-\(pageCount).pdf", isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let single = try scannedURL()
        guard let source = CGPDFDocument(single as CFURL) else {
            throw ScannedSheetFixture.FixtureFailure.noPDFContext
        }
        var mediaBox = CGRect(origin: .zero, size: ScannedSheetFixture.pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil),
              let page = source.page(at: 1)
        else {
            throw ScannedSheetFixture.FixtureFailure.noPDFContext
        }
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
