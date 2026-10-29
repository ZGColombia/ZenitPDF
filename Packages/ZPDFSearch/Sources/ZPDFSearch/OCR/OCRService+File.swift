import CoreGraphics
import Foundation
import ZPDFPDFKitBridge

/// What recognising a whole file without an index found (NL-PDF-19).
///
/// Each page's words, and — separately — the pages that could not be read at all (V-078).
/// Since R-150 a page that fails to render or to be recognised no longer aborts the run; it
/// comes back with no words, which is exactly what a blank page returns. Without this list a
/// caller could not tell the two apart, and the batch processor reported a file "done" while
/// some of its sheets had no text layer and nothing said so.
public struct OCRFileRecognition: Sendable, Hashable {
    /// Each page's recognised words in page space, by zero-based page index. A page that
    /// already carried a text layer, that had nothing above the confidence floor, or that could
    /// not be read maps to no words.
    public let tokens: [Int: [OCRRecognisedToken]]
    /// Zero-based indices of the pages that could not be rendered or recognised, ascending.
    /// Their empty word lists are failures, not blank sheets.
    public let unreadablePages: [Int]

    public init(tokens: [Int: [OCRRecognisedToken]], unreadablePages: [Int] = []) {
        self.tokens = tokens
        self.unreadablePages = unreadablePages.sorted()
    }
}

extension OCRService {

    /// Recognises the text of every page of an open document **without an index** — for the
    /// batch processor (NL-PDF-19), which makes a file searchable and keeps nothing.
    ///
    /// The same page recogniser as ``recognize(documentId:handle:pageRange:progress:)`` —
    /// tiling, rotation handling, confidence floor, the sliding window of
    /// ``OCRSettings/maximumConcurrentPages`` — returning each page's words in page space
    /// instead of committing them. Pages that already carry a text layer are skipped as the
    /// settings say. A page that could not be read is listed in
    /// ``OCRFileRecognition/unreadablePages`` (V-078). On device only, like every OCR run.
    public static func recogniseFile(
        handle: DocumentHandle,
        provider: any PDFDocumentProviding,
        settings: OCRSettings = .standard,
        limits: SearchLimits = .standard,
        normalization: TextNormalizationOptions = .standard
    ) async throws -> OCRFileRecognition {
        try checkSearchCancellation()
        let descriptors: [PDFPageDescriptor]
        do {
            descriptors = try await provider.pageDescriptors(of: handle, range: nil)
        } catch {
            throw ZPDFSearchError.adaptEngine(error)
        }
        guard descriptors.count <= limits.maximumOCRPages else {
            throw ZPDFSearchError.tooManyPagesRequested(count: descriptors.count, limit: limits.maximumOCRPages)
        }
        let jobs = descriptors.enumerated().map { index, descriptor in
            PageJob(pageIndex: index, pageId: String(index), box: descriptor.boxes.crop, rotation: descriptor.rotation)
        }
        let maximumTokens = limits.maximumOCRTokensPerPage
        var tokens: [Int: [OCRRecognisedToken]] = [:]
        var unreadable: [Int] = []
        try await recognisePages(
            jobs, handle: handle, provider: provider, settings: settings,
            normalization: normalization, maximumTokens: maximumTokens
        ) { recognition in
            tokens[recognition.job.pageIndex] = recognition.tokens.map {
                OCRRecognisedToken(text: $0.text, confidence: $0.confidence, bounds: $0.bounds)
            }
            if recognition.skipReason == .notRenderable { unreadable.append(recognition.job.pageIndex) }
        }
        return OCRFileRecognition(tokens: tokens, unreadablePages: unreadable)
    }
}
