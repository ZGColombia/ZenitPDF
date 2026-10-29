import CoreGraphics
import Foundation
import ZPDFPDFKitBridge

/// A ``PDFDocumentProviding`` with no PDF engine behind it at all.
///
/// Its existence is the point of the protocol: a call site that talks to
/// ``PDFDocumentProviding`` can be tested without PDFKit, without files, and without
/// PDFKit's rounding, and a future PDFium- or qpdf-backed implementation slots into the
/// same shape. If this type stops compiling, the protocol has grown a PDFKit-shaped
/// assumption and that is a design regression, not a test failure.
///
/// It is also a scripted double: every answer is data handed to the initialiser.
actor FakeDocumentProvider: PDFDocumentProviding {

    struct Script: Sendable {
        var pageCount: Int = 3
        var labels: PageLabelTable = PageLabelTable(pageCount: 3, ranges: [], isExplicit: false)
        var text: [Int: PageText] = [:]
        var annotations: [Int: [NeutralAnnotation]] = [:]
        var outline: DocumentOutline = .empty
        var destinations: [NamedDestination] = []
        var layerTree: PDFLayerTree?
        var boxes = PageBoxes(
            media: CGRect(x: 0, y: 0, width: 612, height: 792),
            crop: CGRect(x: 0, y: 0, width: 612, height: 792),
            bleed: CGRect(x: 0, y: 0, width: 612, height: 792),
            trim: CGRect(x: 0, y: 0, width: 612, height: 792),
            art: CGRect(x: 0, y: 0, width: 612, height: 792)
        )
        init() {}
    }

    private let script: Script
    private var open: [DocumentHandle: DocumentDescriptor] = [:]
    private let identifiers: any HandleIDGenerating
    private(set) var writeCount = 0

    init(script: Script = Script(), identifiers: any HandleIDGenerating = MonotonicHandleIDGenerator()) {
        self.script = script
        self.identifiers = identifiers
    }

    func open(
        _ source: DocumentSource,
        password: String?,
        limits: DocumentLimits
    ) async throws -> OpenedDocument {
        let handle = DocumentHandle(rawValue: identifiers.next())
        let descriptor = DocumentDescriptor(
            handle: handle,
            origin: source.fileURL.map(DocumentOrigin.file) ?? .memory(byteCount: 0),
            digest: FileDigest(sha256: String(repeating: "0", count: 64), byteCount: 0),
            pageCount: script.pageCount,
            version: PDFVersion(major: 1, minor: 7),
            encryption: .none,
            permissions: .all,
            integrity: .intact,
            isLinearized: false,
            hazards: [],
            embeddedFiles: [],
            attributes: .empty
        )
        open[handle] = descriptor
        return OpenedDocument(descriptor: descriptor)
    }

    func unlock(_ handle: DocumentHandle, password: String) async throws -> DocumentDescriptor {
        try descriptor(of: handle)
    }

    func close(_ handle: DocumentHandle) async { open[handle] = nil }
    func closeAll() async { open.removeAll() }

    func descriptor(of handle: DocumentHandle) throws -> DocumentDescriptor {
        guard let descriptor = open[handle] else { throw PDFBridgeError.unknownHandle(handle) }
        return descriptor
    }

    func pageDescriptors(of handle: DocumentHandle, range: Range<Int>?) async throws -> [PDFPageDescriptor] {
        let descriptor = try descriptor(of: handle)
        let indices = range ?? 0..<descriptor.pageCount
        return indices.map {
            PDFPageDescriptor(
                index: $0,
                label: script.labels.label(forPageIndex: $0) ?? String($0 + 1),
                labelIsExplicit: script.labels.isExplicit,
                boxes: script.boxes,
                rotation: 0
            )
        }
    }

    func renderPageRegion(_ request: PageRenderRequest) async throws -> RenderedPageImage {
        _ = try descriptor(of: request.document)
        let region = request.region ?? script.boxes[request.box]
        return RenderedPageImage(
            image: try Self.blankImage(width: 1, height: 1),
            pageIndex: request.pageIndex,
            renderedRegion: region,
            box: request.box,
            scale: request.scale,
            rotation: 0
        )
    }

    func thumbnail(_ request: ThumbnailRequest) async throws -> ThumbnailResult {
        _ = try descriptor(of: request.document)
        let key = ThumbnailCache.Key(
            documentSHA256: String(repeating: "0", count: 64),
            pageIndex: request.pageIndex,
            box: request.box,
            pixelWidth: 1,
            pixelHeight: 1
        )
        return ThumbnailResult(
            image: try Self.blankImage(width: 1, height: 1),
            pageIndex: request.pageIndex,
            wasCacheHit: false,
            key: key
        )
    }

    func thumbnailCacheStatistics() async -> ThumbnailCacheStatistics { ThumbnailCacheStatistics() }
    func clearThumbnailCache() async {}

    func pageText(of handle: DocumentHandle, pageIndex: Int) async throws -> PageText {
        _ = try descriptor(of: handle)
        return script.text[pageIndex]
            ?? PageText(pageIndex: pageIndex, availability: .noTextLayer, string: "", characterCount: 0, wasTruncated: false)
    }

    func characterBoxes(
        of handle: DocumentHandle,
        pageIndex: Int,
        range: CharacterRange?
    ) async throws -> [CharacterBox] {
        _ = try descriptor(of: handle)
        return []
    }

    func selection(
        of handle: DocumentHandle,
        pageIndex: Int,
        from: CGPoint,
        to: CGPoint
    ) async throws -> TextSelection? {
        _ = try descriptor(of: handle)
        return nil
    }

    func search(
        in handle: DocumentHandle,
        query: String,
        options: TextSearchOptions
    ) async throws -> TextSearchResults {
        let descriptor = try descriptor(of: handle)
        guard !query.isEmpty else { throw PDFBridgeError.emptySearchQuery }
        var hits: [TextSearchHit] = []
        for (pageIndex, text) in script.text.sorted(by: { $0.key < $1.key }) {
            let haystack = text.string as NSString
            let found = haystack.range(of: query, options: .caseInsensitive)
            guard found.location != NSNotFound else { continue }
            hits.append(
                TextSearchHit(
                    pageIndex: pageIndex,
                    pageLabel: script.labels.label(forPageIndex: pageIndex) ?? String(pageIndex + 1),
                    range: CharacterRange(found),
                    matchedText: haystack.substring(with: found),
                    bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                    lineRects: [],
                    excerpt: haystack.substring(with: found)
                )
            )
        }
        return TextSearchResults(
            query: query,
            hits: hits,
            wasTruncated: false,
            pagesWithoutTextLayer: (0..<descriptor.pageCount).filter { script.text[$0] == nil },
            pagesSearched: descriptor.pageCount
        )
    }

    func outline(of handle: DocumentHandle) async throws -> DocumentOutline {
        _ = try descriptor(of: handle)
        return script.outline
    }

    func namedDestinations(of handle: DocumentHandle) async throws -> [NamedDestination] {
        _ = try descriptor(of: handle)
        return script.destinations
    }

    func pageLabels(of handle: DocumentHandle) async throws -> PageLabelTable {
        _ = try descriptor(of: handle)
        return script.labels
    }

    func layerTree(of handle: DocumentHandle) async throws -> PDFLayerTree? {
        _ = try descriptor(of: handle)
        return script.layerTree
    }

    func annotations(of handle: DocumentHandle, pageIndex: Int) async throws -> [NeutralAnnotation] {
        _ = try descriptor(of: handle)
        return script.annotations[pageIndex] ?? []
    }

    func allAnnotations(of handle: DocumentHandle) async throws -> [NeutralAnnotation] {
        _ = try descriptor(of: handle)
        return script.annotations.sorted { $0.key < $1.key }.flatMap(\.value)
    }

    func writeAnnotations(
        _ request: AnnotationWriteRequest,
        of handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        let descriptor = try descriptor(of: handle)
        writeCount += 1
        return DocumentWriteReceipt(
            destination: destination.url,
            digest: FileDigest(sha256: String(repeating: "1", count: 64), byteCount: 1),
            pageCount: descriptor.pageCount,
            sourceDigestBefore: descriptor.digest,
            sourceDigestAfter: descriptor.digest
        )
    }

    func planPageOperations(
        _ operations: [PageOperation],
        on handle: DocumentHandle
    ) async throws -> PageOperationPlan {
        let descriptor = try descriptor(of: handle)
        do {
            return try PageOperationPlanner.plan(
                operations: operations,
                document: handle,
                initialRotations: Array(repeating: 0, count: descriptor.pageCount),
                pageCounts: open.mapValues(\.pageCount)
            )
        } catch let fault {
            throw PDFBridgeError.pageOperation(fault)
        }
    }

    func applyPageOperations(
        _ operations: [PageOperation],
        on handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        let plan = try await planPageOperations(operations, on: handle)
        let descriptor = try descriptor(of: handle)
        writeCount += 1
        return DocumentWriteReceipt(
            destination: destination.url,
            digest: FileDigest(sha256: String(repeating: "2", count: 64), byteCount: 1),
            pageCount: plan.resultingPages.count,
            sourceDigestBefore: descriptor.digest,
            sourceDigestAfter: descriptor.digest
        )
    }

    func extractPages(
        _ pageIndices: [Int],
        of handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        try await applyPageOperations([.extract(pageIndices: pageIndices)], on: handle, to: destination)
    }

    func mergeDocuments(
        _ handles: [DocumentHandle],
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        guard let first = handles.first else { throw PDFBridgeError.pageOperation(.resultWouldBeEmpty) }
        var operations: [PageOperation] = []
        for other in handles.dropFirst() {
            operations.append(.merge(document: other, pageCount: try descriptor(of: other).pageCount))
        }
        return try await applyPageOperations(operations, on: first, to: destination)
    }

    private static func blankImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ), let image = context.makeImage() else {
            throw PDFBridgeError.renderFailed(reason: "fake bitmap")
        }
        return image
    }
}
