import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence

@testable import ZPDFSearch

/// R-150 (one failing page no longer aborts an OCR run)
/// and R-159 (a line crossing a tile seam is one line again).
@Suite("OCR: page failures and tile seams (R-150, R-159)", .serialized)
struct OCRPageFailureAndSeamTests {

    private static let settings = OCRSettings(
        recognitionLanguages: ["en-US", "sv-SE"],
        usesLanguageCorrection: false,
        usesAccurateRecognition: true,
        renderDPI: 200,
        // One page at a time, so pages 3 and 4 are still queued when page 2 fails.
        maximumConcurrentPages: 1
    )

    // MARK: - R-150

    /// Old output: `recognize` threw `ZPDFSearchError.pageRenderFailed(pageIndex: 1, …)` out
    /// of the task group; page 1 was committed, pages 3 and 4 were never recognised, and the
    /// caller got no report at all.
    @Test("R-150: a page that fails to render is reported not renderable; the rest of the run is committed")
    func failingPageDoesNotAbortTheRun() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(
                into: SearchTestBed.fixtureDirectory, name: "scanned-words-4.pdf", pages: 4
            )
            let (documentId, handle) = try await bed.addDocument(at: url)
            let provider = InstrumentedProvider(base: bed.provider)
            provider.failRenders(ofPages: [1])
            let ocr = OCRService(database: bed.database, provider: provider, settings: Self.settings)

            let report = try await ocr.recognize(documentId: documentId, handle: handle)

            #expect(report.pagesRequested == 4)
            #expect(report.pages.map(\.pageIndex) == [0, 1, 2, 3])
            #expect(report.pages[1].skipReason == .notRenderable)
            #expect(report.pages[1].tokenCount == 0)
            for index in [0, 2, 3] {
                #expect(report.pages[index].skipReason == nil, "page \(index)")
                #expect(report.pages[index].tokenCount > 0, "page \(index)")
            }
            #expect(report.pagesRecognised == 3)
            #expect(report.pagesSkipped == 1)
            let withTokens = try await bed.pagesWithTokens()
            #expect(withTokens == Set([0, 2, 3].map { bed.pageId(documentId: documentId, pageIndex: $0) }))
        }
    }

    /// Old output: the batch recogniser (NL-PDF-19) threw the same error and returned nothing.
    /// V-078: after R-150 it returned page 1 as `[]` — what a blank page returns — and dropped
    /// the skip reason, so its caller reported the file done; the page is now listed as unreadable.
    @Test("R-150, V-078: the index-free batch recogniser skips the failing page, returns the others and names it")
    func batchRecogniserSkipsTheFailingPage() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(
                into: SearchTestBed.fixtureDirectory, name: "scanned-words-4.pdf", pages: 4
            )
            let (_, handle) = try await bed.addDocument(at: url)
            let provider = InstrumentedProvider(base: bed.provider)
            provider.failRenders(ofPages: [1])

            let recognition = try await OCRService.recogniseFile(
                handle: handle, provider: provider, settings: Self.settings
            )
            let tokens = recognition.tokens

            #expect(Set(tokens.keys) == [0, 1, 2, 3])
            #expect(tokens[1]?.isEmpty == true)
            for index in [0, 2, 3] {
                #expect((tokens[index]?.count ?? 0) > 0, "page \(index)")
            }
            #expect(recognition.unreadablePages == [1], "the failed page is a failure, not a blank sheet")
        }
    }

    /// V-078: a page skipped because it already carries a text layer is not a failure.
    @Test("V-078: a page skipped for its own text layer is not listed as unreadable")
    func textLayerSkipIsNotUnreadable() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(
                into: SearchTestBed.fixtureDirectory, name: "scanned-words-2.pdf", pages: 2
            )
            let (_, handle) = try await bed.addDocument(at: url)
            let provider = InstrumentedProvider(base: bed.provider)
            // Page 0 reads as if it carried a full text layer.
            provider.rewritePageText { text in
                text.pageIndex == 0
                    ? PageText(pageIndex: 0, availability: .available, string: String(repeating: "PLAN ", count: 200),
                               characterCount: 1_000, wasTruncated: false)
                    : text
            }

            let recognition = try await OCRService.recogniseFile(
                handle: handle, provider: provider, settings: Self.settings
            )

            #expect(recognition.tokens[0]?.isEmpty == true, "skipped for its text layer")
            #expect((recognition.tokens[1]?.count ?? 0) > 0)
            #expect(recognition.unreadablePages.isEmpty)
        }
    }

    // MARK: - R-159

    private static let box = CGRect(x: 0, y: 0, width: 1000, height: 500)

    private static func line(
        _ words: [(String, CGRect)],
        tile: Int,
        region: CGRect,
        confidence: Float = 0.9
    ) -> OCRService.PositionedLine {
        OCRService.PositionedLine(
            text: words.map(\.0).joined(separator: " "),
            confidence: confidence,
            spans: words.map {
                OCRService.PositionedSpan(
                    text: $0.0,
                    pageRect: $0.1,
                    edgeDistance: OCRService.seamDistance($0.1, region: region, box: box)
                )
            },
            tile: tile
        )
    }

    private static func assemble(_ lines: [OCRService.PositionedLine]) -> (
        tokens: [OCRService.RecognisedToken], lineCount: Int, content: String
    ) {
        OCRService.assemble(
            lines, box: box, rotation: 0, minimumConfidence: 0,
            normalization: .standard, maximumTokens: 1_000
        )
    }

    private static func placement(_ tokens: [OCRService.RecognisedToken]) -> [String] {
        tokens.map { "\($0.text)@\($0.lineIndex).\($0.tokenIndex)" }
    }

    /// Old output: `ROOM@0.0, 101@0.1, NORTH@1.0` and content `"room 101\n101 north"` — the
    /// seam word kept the first tile's line, the second tile's line restarted at token 0, and
    /// `101` was indexed twice.
    @Test("R-159: a line split by a seam through a shared word is one line, each word once")
    func seamThroughASharedWord() {
        let left = CGRect(x: 0, y: 0, width: 600, height: 500)
        let right = CGRect(x: 400, y: 0, width: 600, height: 500)
        let room = CGRect(x: 380, y: 200, width: 60, height: 20)
        let first101 = CGRect(x: 450, y: 200, width: 50, height: 20)   // 100 pt from tile 0's seam
        let second101 = CGRect(x: 451, y: 200, width: 50, height: 20)  // 51 pt from tile 1's seam
        let north = CGRect(x: 610, y: 200, width: 90, height: 20)
        let result = Self.assemble([
            Self.line([("ROOM", room), ("101", first101)], tile: 0, region: left),
            Self.line([("101", second101), ("NORTH", north)], tile: 1, region: right)
        ])
        #expect(Self.placement(result.tokens) == ["ROOM@0.0", "101@0.1", "NORTH@0.2"])
        #expect(result.lineCount == 1)
        #expect(result.content == ZPDFTextNormalizer.indexable("ROOM 101 NORTH", options: .standard))
        // The reading farther from a seam is the one kept.
        #expect(result.tokens[1].bounds == first101)
    }

    @Test("R-159: the reading of a seam word farther from its tile's edge wins, even when less confident")
    func fartherFromTheEdgeWins() {
        let left = CGRect(x: 0, y: 0, width: 600, height: 500)
        let right = CGRect(x: 400, y: 0, width: 600, height: 500)
        let nearLeftEdge = CGRect(x: 540, y: 300, width: 50, height: 20)   // 10 pt from tile 0's seam
        let insideRight = CGRect(x: 541, y: 300, width: 50, height: 20)    // 141 pt from tile 1's seam
        let result = Self.assemble([
            Self.line([("A-102", nearLeftEdge)], tile: 0, region: left, confidence: 0.95),
            Self.line([("A-102", insideRight)], tile: 1, region: right, confidence: 0.6)
        ])
        #expect(result.tokens.count == 1)
        #expect(result.tokens.first?.bounds == insideRight)
        #expect(result.lineCount == 1)
    }

    /// Old output: `ROOM@0.0, 101@1.0` — two lines, so the phrase `"ROOM 101"` never matched.
    @Test("R-159: seam lines with no shared word merge on a common baseline")
    func seamWithoutASharedWord() {
        let left = CGRect(x: 0, y: 0, width: 600, height: 500)
        let right = CGRect(x: 580, y: 0, width: 420, height: 500)
        let result = Self.assemble([
            Self.line([("ROOM", CGRect(x: 520, y: 100, width: 58, height: 20))], tile: 0, region: left),
            Self.line([("101", CGRect(x: 590, y: 101, width: 40, height: 20))], tile: 1, region: right)
        ])
        #expect(Self.placement(result.tokens) == ["ROOM@0.0", "101@0.1"])
        #expect(result.content == ZPDFTextNormalizer.indexable("ROOM 101", options: .standard))
    }

    @Test("R-159: columns and other rows stay separate lines")
    func unrelatedLinesStaySeparate() {
        let left = CGRect(x: 0, y: 0, width: 600, height: 500)
        let right = CGRect(x: 400, y: 0, width: 600, height: 500)
        let result = Self.assemble([
            // Same baseline, 300 pt apart: two columns.
            Self.line([("KITCHEN", CGRect(x: 100, y: 400, width: 90, height: 20))], tile: 0, region: left),
            Self.line([("STORE", CGRect(x: 800, y: 400, width: 70, height: 20))], tile: 1, region: right),
            // Another row entirely.
            Self.line([("CORRIDOR", CGRect(x: 700, y: 100, width: 110, height: 20))], tile: 1, region: right)
        ])
        #expect(Self.placement(result.tokens) == ["KITCHEN@0.0", "STORE@1.0", "CORRIDOR@2.0"])
        #expect(result.lineCount == 3)
    }

    @Test("R-159: a whole-page read keeps the recogniser's lines, order and text exactly")
    func wholePageReadIsUnchanged() {
        let whole = Self.box
        let result = Self.assemble([
            Self.line([("DRAWING", CGRect(x: 72, y: 400, width: 200, height: 40)),
                       ("A", CGRect(x: 290, y: 400, width: 30, height: 40)),
                       ("102", CGRect(x: 330, y: 400, width: 90, height: 40))], tile: 0, region: whole),
            OCRService.PositionedLine(text: "no boxes here", confidence: 0.9, spans: []),
            Self.line([("CORRIDOR", CGRect(x: 72, y: 300, width: 200, height: 40))], tile: 0, region: whole)
        ])
        #expect(Self.placement(result.tokens) == ["DRAWING@0.0", "A@0.1", "102@0.2", "CORRIDOR@2.0"])
        #expect(result.lineCount == 3)
        #expect(result.content == ZPDFTextNormalizer.indexable(
            "DRAWING A 102\nno boxes here\nCORRIDOR", options: .standard
        ))
    }
}
