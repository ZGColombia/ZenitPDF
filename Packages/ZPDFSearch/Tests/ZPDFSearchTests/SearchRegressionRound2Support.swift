import CoreGraphics
import CoreText
import Foundation
import os
import GRDB
import ZPDFPDFKitBridge
import ZPDFPersistence

@testable import ZPDFSearch

/// A real PDF engine with two test hooks: it records every page search it is asked for,
/// and it can rewrite what `pageText` reports.
///
/// Everything else is forwarded untouched to a real ``PDFKitDocumentProvider``, so a
/// handle opened on the wrapped provider (for example by ``SearchTestBed/addDocument``)
/// is valid here too. The recorder is what turns "one engine search per hit" and "one
/// engine search per distinct word" into numbers a test can assert.
final class InstrumentedProvider: PDFDocumentProviding, Sendable {

    typealias PageTextRewrite = @Sendable (PageText) -> PageText

    private struct State: Sendable {
        var searchQueries: [String] = []
        var pageTextRewrite: PageTextRewrite?
        var failingRenderPages: Set<Int> = []
    }

    let base: PDFKitDocumentProvider
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(base: PDFKitDocumentProvider) {
        self.base = base
    }

    /// Every `search(in:query:options:)` literal, in call order.
    var searchQueries: [String] { state.withLock { $0.searchQueries } }
    var searchCount: Int { state.withLock { $0.searchQueries.count } }

    func resetSearchLog() { state.withLock { $0.searchQueries.removeAll() } }

    func rewritePageText(_ rewrite: PageTextRewrite?) {
        state.withLock { $0.pageTextRewrite = rewrite }
    }

    /// Every render of these zero-based pages throws `PDFBridgeError.renderFailed`, as a
    /// damaged page does (R-150).
    func failRenders(ofPages pages: Set<Int>) {
        state.withLock { $0.failingRenderPages = pages }
    }

    // MARK: - Instrumented

    func pageText(of handle: DocumentHandle, pageIndex: Int) async throws -> PageText {
        let real = try await base.pageText(of: handle, pageIndex: pageIndex)
        let rewrite = state.withLock { $0.pageTextRewrite }
        return rewrite.map { $0(real) } ?? real
    }

    func search(
        in handle: DocumentHandle,
        query: String,
        options: TextSearchOptions
    ) async throws -> TextSearchResults {
        state.withLock { $0.searchQueries.append(query) }
        return try await base.search(in: handle, query: query, options: options)
    }

    // MARK: - Forwarded

    func open(_ source: DocumentSource, password: String?, limits: DocumentLimits) async throws -> OpenedDocument {
        try await base.open(source, password: password, limits: limits)
    }
    func unlock(_ handle: DocumentHandle, password: String) async throws -> DocumentDescriptor {
        try await base.unlock(handle, password: password)
    }
    func close(_ handle: DocumentHandle) async { await base.close(handle) }
    func closeAll() async { await base.closeAll() }
    func descriptor(of handle: DocumentHandle) async throws -> DocumentDescriptor {
        try await base.descriptor(of: handle)
    }
    func pageDescriptors(of handle: DocumentHandle, range: Range<Int>?) async throws -> [PDFPageDescriptor] {
        try await base.pageDescriptors(of: handle, range: range)
    }
    func renderPageRegion(_ request: PageRenderRequest) async throws -> RenderedPageImage {
        if state.withLock({ $0.failingRenderPages.contains(request.pageIndex) }) {
            throw PDFBridgeError.renderFailed(reason: "test: damaged page")
        }
        return try await base.renderPageRegion(request)
    }
    func thumbnail(_ request: ThumbnailRequest) async throws -> ThumbnailResult {
        try await base.thumbnail(request)
    }
    func thumbnailCacheStatistics() async -> ThumbnailCacheStatistics {
        await base.thumbnailCacheStatistics()
    }
    func clearThumbnailCache() async { await base.clearThumbnailCache() }
    func characterBoxes(of handle: DocumentHandle, pageIndex: Int, range: CharacterRange?) async throws -> [CharacterBox] {
        try await base.characterBoxes(of: handle, pageIndex: pageIndex, range: range)
    }
    func selection(of handle: DocumentHandle, pageIndex: Int, from: CGPoint, to: CGPoint) async throws -> TextSelection? {
        try await base.selection(of: handle, pageIndex: pageIndex, from: from, to: to)
    }
    func outline(of handle: DocumentHandle) async throws -> DocumentOutline {
        try await base.outline(of: handle)
    }
    func namedDestinations(of handle: DocumentHandle) async throws -> [NamedDestination] {
        try await base.namedDestinations(of: handle)
    }
    func pageLabels(of handle: DocumentHandle) async throws -> PageLabelTable {
        try await base.pageLabels(of: handle)
    }
    func layerTree(of handle: DocumentHandle) async throws -> PDFLayerTree? {
        try await base.layerTree(of: handle)
    }
    func annotations(of handle: DocumentHandle, pageIndex: Int) async throws -> [NeutralAnnotation] {
        try await base.annotations(of: handle, pageIndex: pageIndex)
    }
    func allAnnotations(of handle: DocumentHandle) async throws -> [NeutralAnnotation] {
        try await base.allAnnotations(of: handle)
    }
    func writeAnnotations(
        _ request: AnnotationWriteRequest,
        of handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        try await base.writeAnnotations(request, of: handle, to: destination)
    }
    func planPageOperations(_ operations: [PageOperation], on handle: DocumentHandle) async throws -> PageOperationPlan {
        try await base.planPageOperations(operations, on: handle)
    }
    func applyPageOperations(
        _ operations: [PageOperation],
        on handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        try await base.applyPageOperations(operations, on: handle, to: destination)
    }
    func extractPages(
        _ pageIndices: [Int],
        of handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        try await base.extractPages(pageIndices, of: handle, to: destination)
    }
    func mergeDocuments(_ handles: [DocumentHandle], to destination: DocumentDestination) async throws -> DocumentWriteReceipt {
        try await base.mergeDocuments(handles, to: destination)
    }
}

/// A vector PDF whose text layer is exactly the given lines, drawn with CoreText.
///
/// Generated per test into the test bed's own directory, so the words a test searches
/// for are declared next to the test and nothing binary is checked in.
enum TextSheetFixture {

    static func write(
        pages: [[String]],
        into directory: URL,
        name: String,
        pageSize: CGSize = CGSize(width: 612, height: 792)
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(name).pdf", isDirectory: false)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            for (index, line) in lines.enumerated() {
                let attributed = NSAttributedString(
                    string: line,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 40, y: pageSize.height - 60 - CGFloat(index) * 24)
                CTLineDraw(ctLine, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}

extension SearchTestBed {

    /// ``addDocument(at:displayName:)`` for a document opened with explicit engine limits.
    func addDocument(
        at url: URL,
        limits: DocumentLimits
    ) async throws -> (documentId: String, handle: DocumentHandle) {
        let opened = try await provider.open(.url(url), password: nil, limits: limits)
        let pages = try await provider.pageDescriptors(of: opened.handle)
        let documentId = "document-\(UUID().uuidString)"
        let projectId = self.projectId
        let sha = opened.descriptor.digest.sha256
        let now = "2026-08-23T00:00:00Z"
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO document
                    (id, project_id, display_name, relative_path, sha256, page_count,
                     active_revision_id, created_at, modified_at)
                VALUES (?, ?, 'limited', ?, ?, ?, NULL, ?, ?)
                """,
                arguments: [documentId, projectId, url.lastPathComponent, sha, pages.count, now, now]
            )
            for page in pages {
                try db.execute(
                    sql: """
                    INSERT INTO page
                        (id, document_id, page_index, page_label,
                         media_x, media_y, media_width, media_height,
                         crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    arguments: [
                        "\(documentId)-page-\(page.index)", documentId, page.index, page.label,
                        page.boxes.media.minX, page.boxes.media.minY,
                        page.boxes.media.width, page.boxes.media.height,
                        page.boxes.crop.minX, page.boxes.crop.minY,
                        page.boxes.crop.width, page.boxes.crop.height,
                        page.rotation
                    ]
                )
            }
        }
        return (documentId, opened.handle)
    }

    /// A document row with `pageCount` synthetic page rows and no PDF behind it.
    func addSyntheticDocument(pageCount: Int) async throws -> String {
        let documentId = "document-\(UUID().uuidString)"
        let projectId = self.projectId
        let now = "2026-08-23T00:00:00Z"
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO document
                    (id, project_id, display_name, relative_path, sha256, page_count,
                     active_revision_id, created_at, modified_at)
                VALUES (?, ?, 'synthetic', 'synthetic.pdf', ?, ?, NULL, ?, ?)
                """,
                arguments: [documentId, projectId, String(repeating: "1", count: 64), pageCount, now, now]
            )
            for index in 0..<pageCount {
                try db.execute(
                    sql: """
                    INSERT INTO page
                        (id, document_id, page_index, page_label,
                         media_x, media_y, media_width, media_height,
                         crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
                    VALUES (?, ?, ?, NULL, 0, 0, 612, 792, 0, 0, 612, 792, 0, NULL)
                    """,
                    arguments: ["\(documentId)-page-\(index)", documentId, index]
                )
            }
        }
        return documentId
    }

    /// Recognised tokens on one line of a page, plus the page's `ocr` index row.
    func seedRecognisedPage(
        documentId: String,
        pageIndex: Int,
        words: [String],
        confidence: Double,
        content: String? = nil
    ) async throws {
        let projectId = self.projectId
        let pageId = self.pageId(documentId: documentId, pageIndex: pageIndex)
        try await database.write { db in
            for (index, word) in words.enumerated() {
                let rect = CGRect(x: 100 + Double(index) * 60, y: 500, width: 50, height: 12)
                let blob = try GeometryBlob(
                    kind: .rectangle,
                    points: RecognitionGeometry.corners(of: rect).map {
                        GeometryPoint(x: $0.x, y: $0.y)
                    }
                ).encode()
                try SearchIndexStore.insertOCRToken(
                    db,
                    OCRTokenRecord(
                        pageId: pageId,
                        token: word,
                        normalizedToken: ZPDFTextNormalizer.folded(word),
                        confidence: confidence,
                        boundsBlob: blob,
                        lineIndex: 0,
                        tokenIndex: index
                    )
                )
            }
            try SearchIndexStore.insert(
                db,
                SearchIndexRecord(
                    projectId: projectId,
                    documentId: documentId,
                    pageId: pageId,
                    sourceType: SearchSourceType.ocr.rawValue,
                    sourceId: pageId,
                    content: content ?? words.joined(separator: " ")
                )
            )
        }
    }
}
