import CoreGraphics
import CoreText
import Foundation
import os
import Testing
import Vision
import ZPDFPDFKitBridge

@testable import ZPDFSearch

/// 1.0.1: when Vision throws instead of reading, recognition is tried again at revision 2
/// `.accurate`, then at `.fast`. On macOS 27 the default `.accurate` request threw on every call
/// on a virtual Mac, and is reported to throw after the first call on hardware; the error was
/// swallowed and the page reported as having no text.
///
/// The chain's own tests drive its seam with stand-ins for Vision, so they mean the same on
/// every Mac. The page-run tests bind ``OCRService/pagePerform`` for their own task to drive
/// ``OCRService`` through the same stand-ins. Only `.fast` runs Vision for real, which read on
/// the virtual Mac where `.accurate` threw.
@Suite("Text recognition falls back when Vision throws (1.0.1)", .serialized)
struct TextRecognitionFallbackTests {

    private typealias Attempt = TextRecognitionFallback.Attempt

    private struct Thrown: Error, Equatable {
        let attempt: Attempt
    }

    /// Runs the whole chain, throwing for the attempts in `failing`; returns the attempts that
    /// ran and the one whose result came back.
    private static func run(failing: Set<Attempt>) throws -> (ran: [Attempt], answer: Attempt) {
        var ran: [Attempt] = []
        let answer = try TextRecognitionFallback.firstSuccess(of: Attempt.allCases, purpose: .page) { attempt in
            ran.append(attempt)
            if failing.contains(attempt) { throw Thrown(attempt: attempt) }
            return attempt
        }
        return (ran, answer)
    }

    // MARK: - The chain

    @Test("The configured request runs alone when it reads")
    func firstAttemptWorks() throws {
        let result = try Self.run(failing: [])
        #expect(result.ran == [.configured])
        #expect(result.answer == .configured)
    }

    @Test("A request that throws is read again at revision 2 .accurate")
    func secondAttemptWorks() throws {
        let result = try Self.run(failing: [.configured])
        #expect(result.ran == [.configured, .accurateRevision2])
        #expect(result.answer == .accurateRevision2)
    }

    @Test("When both .accurate attempts throw, .fast reads")
    func fastWorks() throws {
        let result = try Self.run(failing: [.configured, .accurateRevision2])
        #expect(result.ran == [.configured, .accurateRevision2, .fast])
        #expect(result.answer == .fast)
    }

    @Test("When every attempt throws, the configured request's error surfaces")
    func everyAttemptThrows() {
        var ran: [Attempt] = []
        #expect(throws: Thrown(attempt: .configured)) {
            try TextRecognitionFallback.firstSuccess(of: Attempt.allCases, purpose: .page) { attempt -> Int in
                ran.append(attempt)
                throw Thrown(attempt: attempt)
            }
        }
        #expect(ran == [.configured, .accurateRevision2, .fast])
    }

    @Test("A request that reads nothing has answered: it does not fall through")
    func emptyReadDoesNotFallThrough() throws {
        var ran: [Attempt] = []
        let observations = try TextRecognitionFallback.recognize(
            image: try Self.image(of: "SCALE 1:50"),
            accurate: true,
            languages: ["en-US"],
            purpose: .page,
            perform: { attempt, _, _ in ran.append(attempt) }
        )
        #expect(observations.isEmpty)
        #expect(ran == [.configured])
    }

    @Test("An .accurate request falls back to revision 2 when this OS has it, then to .fast; a .fast request runs once")
    func attemptOrder() {
        #expect(TextRecognitionFallback.attempts(accurate: true, supportedRevisions: IndexSet([1, 2, 3]))
            == [.configured, .accurateRevision2, .fast])
        #expect(TextRecognitionFallback.attempts(accurate: true, supportedRevisions: IndexSet([1, 3]))
            == [.configured, .fast])
        #expect(TextRecognitionFallback.attempts(accurate: false, supportedRevisions: IndexSet([1, 2, 3]))
            == [.configured])
    }

    @Test("Each attempt keeps the caller's options, sets its own level and revision, and asks only for languages it has")
    func attemptRequests() throws {
        var requests: [Attempt: VNRecognizeTextRequest] = [:]
        #expect(throws: Thrown(attempt: .configured)) {
            try TextRecognitionFallback.recognize(
                image: try Self.image(of: "SCALE 1:50"),
                accurate: true,
                languages: ["en-US", "sv-SE"],
                purpose: .page,
                configure: { $0.usesLanguageCorrection = false },
                perform: { attempt, request, _ in
                    requests[attempt] = request
                    throw Thrown(attempt: attempt)
                }
            )
        }

        let configured = try #require(requests[.configured])
        #expect(configured.revision == VNRecognizeTextRequest.defaultRevision)
        #expect(configured.recognitionLevel == .accurate)

        if VNRecognizeTextRequest.supportedRevisions.contains(2) {
            let revision2 = try #require(requests[.accurateRevision2])
            #expect(revision2.revision == 2)
            #expect(revision2.recognitionLevel == .accurate)
        }

        let fast = try #require(requests[.fast])
        #expect(fast.revision == VNRecognizeTextRequest.defaultRevision)
        #expect(fast.recognitionLevel == .fast)

        for (attempt, request) in requests {
            #expect(!request.usesLanguageCorrection, "\(attempt)")
            let supported = Set(try request.supportedRecognitionLanguages())
            #expect(request.recognitionLanguages.contains("en-US"), "\(attempt)")
            #expect(Set(request.recognitionLanguages).isSubset(of: supported), "\(attempt)")
            #expect(Set(request.recognitionLanguages).isSubset(of: ["en-US", "sv-SE"]), "\(attempt)")
        }
    }

    @Test("A sheet read again at .fast still gives its words")
    func fastReadsForReal() throws {
        let observations = try TextRecognitionFallback.recognize(
            image: try Self.image(of: "SCALE 1:50"),
            accurate: true,
            languages: ["en-US", "sv-SE"],
            purpose: .page,
            perform: { attempt, request, image in
                guard attempt == .fast else { throw Thrown(attempt: attempt) }
                try TextRecognitionFallback.performWithVision(attempt, request, image)
            }
        )
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        #expect(text.contains("SCALE"), "read: \(text)")
    }

    // MARK: - What a page that could not be read is called

    @Test("A page Vision could not read is a recognition failure, not an unrendered or empty page")
    func pageSkipReason() {
        #expect(OCRService.skipReason(forPageError: .recognitionFailed(pageIndex: 2, reason: "x")) == .recognitionFailed)
        #expect(OCRService.skipReason(forPageError: .pageRenderFailed(pageIndex: 2, reason: "x")) == .notRenderable)
        #expect(OCRService.skipReason(forPageError: .engine("x")) == .notRenderable)
        #expect(OCRService.skipReason(forPageError: .cancelled) == nil)
        #expect(OCRService.skipReason(forPageError: .storage("x")) == nil)

        #expect(OCRSkipReason.recognitionFailed.isFailure)
        #expect(OCRSkipReason.notRenderable.isFailure)
        #expect(!OCRSkipReason.nothingRecognised.isFailure)
        #expect(!OCRSkipReason.hasTextLayer.isFailure)

        // The app tier maps each skip reason by these words (`OCRPageStatus(recognitionSkipReason:)`
        // in ZPDFUIWorkflows). A reason added here fails the count until the app tier maps it.
        #expect(OCRSkipReason.recognitionFailed.rawValue == "recognitionFailed")
        #expect(OCRSkipReason.hasTextLayer.rawValue == "hasTextLayer")
        #expect(OCRSkipReason.notRenderable.rawValue == "notRenderable")
        #expect(OCRSkipReason.nothingRecognised.rawValue == "nothingRecognised")
        #expect(OCRSkipReason.allCases.count == 4)
    }

    @Test("A page macOS could not read keeps the words an earlier run recognised on it")
    func failedPageKeepsEarlierWords() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(
                into: SearchTestBed.fixtureDirectory, name: "fallback-\(UUID().uuidString).pdf", pages: 1
            )
            let (documentId, _) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            let ocr = OCRService(database: bed.database, provider: bed.provider)
            let job = OCRService.PageJob(
                pageIndex: 0, pageId: pageId, box: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0
            )
            let content = ZPDFTextNormalizer.indexable("PLANT ROOM", options: .standard)

            _ = try await ocr.commit(
                OCRService.PageRecognition(
                    job: job,
                    tokens: [OCRService.RecognisedToken(
                        text: "PLANT", normalized: ZPDFTextNormalizer.folded("PLANT"), confidence: 0.9,
                        bounds: CGRect(x: 100, y: 100, width: 80, height: 20), lineIndex: 0, tokenIndex: 0
                    )],
                    lineCount: 1, content: content, skipReason: nil, elapsedSeconds: 0, effectiveDPI: 200
                ),
                projectId: bed.projectId,
                documentId: documentId
            )
            #expect(try await bed.ocrTokenCount(pageId: pageId) == 1)

            let failed = try await ocr.commit(
                OCRService.PageRecognition(
                    job: job, tokens: [], lineCount: 0, content: "", skipReason: .recognitionFailed,
                    elapsedSeconds: 0, effectiveDPI: 0
                ),
                projectId: bed.projectId,
                documentId: documentId
            )
            #expect(failed.skipReason == .recognitionFailed && failed.wasSkipped)
            #expect(try await bed.ocrTokenCount(pageId: pageId) == 1)
            #expect(try await bed.pagesWithOCRIndexRows() == [pageId])
        }
    }

    // MARK: - Through OCRService

    private static let settings = OCRSettings(
        recognitionLanguages: ["en-US", "sv-SE"],
        usesLanguageCorrection: false,
        usesAccurateRecognition: true,
        renderDPI: 200,
        maximumConcurrentPages: 1
    )

    /// The attempts a bound ``OCRService/pagePerform`` was asked to run, from whichever queue.
    private final class AttemptLog: Sendable {
        private let attempts = OSAllocatedUnfairLock<[Attempt]>(initialState: [])
        func append(_ attempt: Attempt) { attempts.withLock { $0.append(attempt) } }
        var all: [Attempt] { attempts.withLock { $0 } }
    }

    /// A one-page scan with one word an earlier run recognised on it already committed.
    private static func scanWithEarlierWord(
        _ bed: SearchTestBed,
        ocr: OCRService
    ) async throws -> (documentId: String, handle: DocumentHandle, pageId: String) {
        let url = try ScannedSheetFixture.write(
            into: SearchTestBed.fixtureDirectory, name: "fallback-\(UUID().uuidString).pdf", pages: 1
        )
        let (documentId, handle) = try await bed.addDocument(at: url)
        let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
        _ = try await ocr.commit(
            OCRService.PageRecognition(
                job: OCRService.PageJob(
                    pageIndex: 0, pageId: pageId, box: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0
                ),
                tokens: [OCRService.RecognisedToken(
                    text: "PLANT", normalized: ZPDFTextNormalizer.folded("PLANT"), confidence: 0.9,
                    bounds: CGRect(x: 100, y: 100, width: 80, height: 20), lineIndex: 0, tokenIndex: 0
                )],
                lineCount: 1, content: ZPDFTextNormalizer.indexable("PLANT ROOM", options: .standard),
                skipReason: nil, elapsedSeconds: 0, effectiveDPI: 200
            ),
            projectId: bed.projectId,
            documentId: documentId
        )
        return (documentId, handle, pageId)
    }

    /// Old output: no test reached `recognisePage` with a failing recogniser. Live Vision reads
    /// on a Mac, and `.fast` reads on the virtual one, so reporting the page `.notRenderable`,
    /// or the host mapping it to "No text found", left every test green.
    @Test("A page every attempt throws on is a recognition failure that keeps its earlier words, and the file path lists it as unreadable")
    func everyAttemptThrowingFailsThePage() async throws {
        try await withSearchTestBed { bed in
            let ocr = OCRService(database: bed.database, provider: bed.provider, settings: Self.settings)
            let (documentId, handle, pageId) = try await Self.scanWithEarlierWord(bed, ocr: ocr)
            #expect(try await bed.ocrTokenCount(pageId: pageId) == 1)

            let log = AttemptLog()
            let report = try await OCRService.$pagePerform.withValue({ attempt, _, _ in
                log.append(attempt)
                throw Thrown(attempt: attempt)
            }) {
                try await ocr.recognize(documentId: documentId, handle: handle)
            }

            #expect(log.all == TextRecognitionFallback.attempts(accurate: true), "every attempt ran and threw")
            let page = try #require(report.pages.first)
            #expect(report.pages.count == 1)
            #expect(page.skipReason == .recognitionFailed, "not .notRenderable: the page rendered")
            #expect(page.wasSkipped && page.tokenCount == 0)
            #expect(report.pagesRecognised == 0 && report.pagesSkipped == 1)
            // BH-205: the earlier run's word and index row stay, so search still finds them.
            #expect(try await bed.ocrTokenCount(pageId: pageId) == 1)
            #expect(try await bed.pagesWithOCRIndexRows() == [pageId])

            // The index-free path the batch processor runs: the page is a failure, not a blank
            // sheet, so its file is not marked finished and the next run retries it (V-078).
            let file = try await OCRService.$pagePerform.withValue({ attempt, _, _ in
                throw Thrown(attempt: attempt)
            }) {
                try await OCRService.recogniseFile(handle: handle, provider: bed.provider, settings: Self.settings)
            }
            #expect(file.unreadablePages == [0])
            #expect(file.tokens[0]?.isEmpty == true)
        }
    }

    @Test("A page read by the .fast fallback after both .accurate attempts throw is indexed and searchable")
    func fallbackThatReadsIndexesTheWords() async throws {
        try await withSearchTestBed { bed in
            let url = try ScannedSheetFixture.write(
                into: SearchTestBed.fixtureDirectory, name: "fallback-\(UUID().uuidString).pdf", pages: 1
            )
            let (documentId, handle) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)
            let ocr = OCRService(database: bed.database, provider: bed.provider, settings: Self.settings)

            let log = AttemptLog()
            let report = try await OCRService.$pagePerform.withValue({ attempt, request, image in
                log.append(attempt)
                guard attempt == .fast else { throw Thrown(attempt: attempt) }
                try TextRecognitionFallback.performWithVision(attempt, request, image)
            }) {
                try await ocr.recognize(documentId: documentId, handle: handle)
            }

            #expect(log.all.last == .fast)
            #expect(log.all.dropLast().allSatisfy { $0 != .fast }, "\(log.all)")
            let page = try #require(report.pages.first)
            #expect(page.skipReason == nil)
            #expect(page.tokenCount > 0)
            #expect(try await bed.ocrTokenCount(pageId: pageId) == page.tokenCount)
            #expect(try await bed.pagesWithOCRIndexRows() == [pageId])

            let hits = try await SearchService(database: bed.database).search(SearchRequest(
                text: "CORRIDOR",
                scope: .document(projectId: bed.projectId, documentId: documentId),
                resolvesBounds: false
            ))
            #expect(!hits.isEmpty, "the word the fallback read is searchable")
        }
    }

    // MARK: - Fixture

    /// `text` in 96 pt Helvetica, black on white: legible to any recogniser.
    private static func image(of text: String) throws -> CGImage {
        let width = 1_200, height = 300
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 96, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]))
        context.textPosition = CGPoint(x: 40, y: 100)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }
}
