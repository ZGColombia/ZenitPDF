import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence

@testable import ZPDFSearch

/// S-103: text Vision returns without word boxes is
/// searchable. `assemble` kept a box-less line's text in the page content on purpose; `commit`
/// then required boxed tokens as well and wrote no index row, and the page was reported as
/// "nothing recognised".
@Suite("Iter2 OCR text without word boxes (S-103)", .serialized)
struct Iter2OCRBoxlessTextTests {

    private static let settings = OCRSettings(
        recognitionLanguages: ["en-US"],
        usesLanguageCorrection: false,
        usesAccurateRecognition: true,
        renderDPI: 200,
        maximumConcurrentPages: 1
    )

    @Test("S-103: a page whose only line has no word boxes is recognised, not 'nothing recognised'")
    func boxlessPageIsNotNothing() {
        let assembled = OCRService.assemble(
            [OCRService.PositionedLine(text: "PLANT ROOM", confidence: 0.9, spans: [])],
            box: CGRect(x: 0, y: 0, width: 1000, height: 500), rotation: 0, minimumConfidence: 0,
            normalization: .standard, maximumTokens: 1_000
        )
        #expect(assembled.tokens.isEmpty)
        #expect(assembled.lineCount == 1)
        #expect(assembled.content == ZPDFTextNormalizer.indexable("PLANT ROOM", options: .standard))
        // Old output: .nothingRecognised — the reason was derived from the empty token list.
        #expect(OCRService.skipReason(forRecognisedContent: assembled.content) == nil)
        #expect(OCRService.skipReason(forRecognisedContent: "") == .nothingRecognised)
    }

    @Test("S-103: committing box-less text writes the page's index row, and a search finds it")
    func boxlessTextIsSearchable() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(
                into: SearchTestBed.fixtureDirectory, name: "boxless-\(UUID().uuidString).pdf", pages: 1
            )
            let (documentId, _) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            let ocr = OCRService(database: bed.database, provider: bed.provider, settings: Self.settings)
            let content = ZPDFTextNormalizer.indexable("PLANT ROOM", options: .standard)

            let result = try await ocr.commit(
                OCRService.PageRecognition(
                    job: OCRService.PageJob(pageIndex: 0, pageId: pageId, box: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0),
                    tokens: [],
                    lineCount: 1,
                    content: content,
                    skipReason: OCRService.skipReason(forRecognisedContent: content),
                    elapsedSeconds: 0,
                    effectiveDPI: 200
                ),
                projectId: bed.projectId,
                documentId: documentId
            )
            #expect(result.skipReason == nil && !result.wasSkipped)
            #expect(result.tokenCount == 0)

            // Old output: [] — commit returned before writing the row because tokens was empty.
            #expect(try await bed.pagesWithOCRIndexRows() == [pageId])
            let hits = try await SearchService(database: bed.database).search(SearchRequest(
                text: "plant",
                scope: .document(projectId: bed.projectId, documentId: documentId),
                confidence: .permissive,
                resolvesBounds: false
            ))
            #expect(hits.hits.count == 1)
            let hit = try #require(hits.hits.first)
            #expect(hit.sourceType == .ocr && hit.pageId == pageId)
            // No token matched, so the confidence is unknown — not zero, not low (CR-125).
            #expect(hit.hasUnknownOCRConfidence && hit.ocrConfidence == nil && !hit.isLowConfidenceOCR)
        }
    }
}
