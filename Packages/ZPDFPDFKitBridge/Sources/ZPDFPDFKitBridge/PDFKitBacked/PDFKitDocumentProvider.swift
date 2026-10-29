import CoreGraphics
import Foundation
import PDFKit

/// The PDFKit implementation of ``PDFDocumentProviding``.
///
/// An actor, because `PDFDocument`, `PDFPage` and `PDFAnnotation` are reference types
/// that PDFKit does not promise are safe to touch from two threads. Every one of them
/// lives inside this actor's isolation and never escapes: the API hands out `Sendable`
/// value types and `CGImage`, which is `Sendable`.
///
/// Nothing here constructs a `PDFView`. That matters: `PDFView` is the PDFKit object that
/// *performs* actions — following links, running `/OpenAction`, opening attachments — and
/// its absence is why spec 7.4's "PDF JavaScript is never run, launch actions are ignored,
/// embedded files are not opened automatically" holds structurally rather than by
/// discipline. See ``PDFBridgeSecurityPolicy``.
public actor PDFKitDocumentProvider: PDFDocumentProviding {

    /// One open document and everything derived from it at open time.
    struct OpenDocument {
        let handle: DocumentHandle
        let document: PDFDocument
        let origin: DocumentOrigin
        let digest: FileDigest
        let limits: DocumentLimits
        /// Kept for in-memory sources so a write can reopen a pristine copy rather than
        /// mutating the document the caller is reading from.
        let sourceData: Data?
        /// Non-`nil` when the URL was reached through a security-scoped bookmark and the
        /// scope must be released on close.
        let securityScopedURL: URL?
        var descriptor: DocumentDescriptor
        var labels: PageLabelTable
        var namedDestinations: [NamedDestination]
        var password: String?
        /// The file probe taken at open, kept so `unlock` can recompute the integrity verdict.
        let probe: PDFFileProbe
        /// Fingerprint of the annotations layer visibility has hidden on this handle's
        /// document; empty while the display state is the file's own. Part of every thumbnail
        /// cache key, because `PDFPage.draw` honours `shouldDisplay`.
        var annotationDisplayState: String = ""
    }

    private var documents: [DocumentHandle: OpenDocument] = [:]
    private var thumbnails: ThumbnailCache
    private let identifiers: any HandleIDGenerating
    private let bookmarkResolver: (any SecurityScopedBookmarkResolving)?
    /// The optional on-disk thumbnail tier (IM-073). `nil` keeps thumbnails in memory only.
    let thumbnailDiskCache: ThumbnailDiskCache?
    /// Disk writes still in flight, by ticket, so a caller (and a test) can wait for them. Each
    /// write removes its own ticket when it finishes (R-117).
    var pendingThumbnailDiskWrites: [UInt64: Task<Void, Never>] = [:]
    var nextThumbnailDiskWriteTicket: UInt64 = 0
    /// Test seam: awaited by every disk write before it stores. `nil` in the product.
    var thumbnailDiskWriteGate: (@Sendable () async -> Void)?
    /// Writes since the disk tier was last trimmed; starts full so the first write trims.
    var thumbnailDiskWritesSinceTrim = Int.max
    /// Thumbnails rasterised through PDFKit, and thumbnails answered from the disk tier.
    private(set) var thumbnailRenderCount = 0
    private(set) var thumbnailDiskHitCount = 0

    /// - Parameters:
    ///   - thumbnailCacheCapacity: number of thumbnails retained. Zero disables caching.
    ///   - identifiers: injected so handles are `#1, #2, #3` in a test instead of UUIDs.
    ///   - bookmarkResolver: the platform tier's implementation of
    ///     ``SecurityScopedBookmarkResolving``. `nil` — the default — means this provider
    ///     rejects ``DocumentSource/securityScopedBookmark(_:)`` outright; see ADR-0005 §2.
    ///   - thumbnailDiskCache: an on-disk tier under the memory cache, so a drawing opened
    ///     again shows its thumbnails without rasterising every page (IM-073). `nil` — the
    ///     default — keeps thumbnails in memory only.
    public init(
        thumbnailCacheCapacity: Int = 512,
        thumbnailCacheByteCapacity: Int = ThumbnailCache.defaultByteCapacity,
        identifiers: any HandleIDGenerating = MonotonicHandleIDGenerator(),
        bookmarkResolver: (any SecurityScopedBookmarkResolving)? = nil,
        thumbnailDiskCache: ThumbnailDiskCache? = nil
    ) {
        self.thumbnails = ThumbnailCache(
            capacity: thumbnailCacheCapacity,
            byteCapacity: thumbnailCacheByteCapacity
        )
        self.identifiers = identifiers
        self.bookmarkResolver = bookmarkResolver
        self.thumbnailDiskCache = thumbnailDiskCache
    }

    // MARK: - Opening

    public func open(
        _ source: DocumentSource,
        password: String?,
        limits: DocumentLimits = .standard
    ) async throws -> OpenedDocument {
        try await open(source, password: password, limits: limits, knownDigest: nil)
    }

    /// Opens a document whose SHA-256 the caller has **already verified in this process**.
    ///
    /// A project open hashed `working.pdf` up to four times: once for the package's integrity
    /// verdict, once per provider that opened it, and once more for an encrypted drawing's
    /// password retry (IM-005). Passing the verified digest skips this open's own pass over
    /// the file. It is used only for a file source, and only when it is plausible — 64
    /// lower-case hexadecimal characters and the byte count the probe just measured; anything
    /// else is ignored and the file is hashed as usual. Pass a digest only for the same file,
    /// verified in this process: the descriptor's identity, the thumbnail cache and the write
    /// path's source check all key on it.
    public func open(
        _ source: DocumentSource,
        password: String?,
        limits: DocumentLimits = .standard,
        knownDigest: FileDigest?
    ) async throws -> OpenedDocument {
        try checkCancellation()

        var securityScopedURL: URL?
        let resolved: DocumentSource
        switch source {
        case .securityScopedBookmark(let bookmark):
            let url = try resolveSecurityScopedBookmark(bookmark)
            securityScopedURL = url
            resolved = .url(url)
        default:
            resolved = source
        }
        // If anything below throws, the scope must not leak.
        var succeeded = false
        defer {
            if !succeeded, let securityScopedURL {
                securityScopedURL.stopAccessingSecurityScopedResource()
            }
        }

        let origin: DocumentOrigin
        let digest: FileDigest
        let probe: PDFFileProbe
        let data: Data?
        let fileURL: URL?

        switch resolved {
        case .url(let url):
            fileURL = url
            data = nil
            origin = .file(url)
            probe = try PDFFileProbe.probe(fileAt: url, limits: limits)
            guard probe.byteCount > 0 else { throw PDFBridgeError.damaged(.empty) }
            guard probe.headerVersion != nil else { throw PDFBridgeError.damaged(.missingHeader) }
            if let knownDigest, FileDigestReader.isPlausible(knownDigest, byteCount: probe.byteCount) {
                // The size limit the skipped hash would have enforced still holds.
                guard probe.byteCount <= limits.maximumFileByteCount else {
                    throw PDFBridgeError.fileTooLarge(byteCount: probe.byteCount, limit: limits.maximumFileByteCount)
                }
                digest = knownDigest
            } else {
                digest = try FileDigestReader.digest(ofFileAt: url, maximumByteCount: limits.maximumFileByteCount)
            }
        case .data(let bytes):
            fileURL = nil
            data = bytes
            guard bytes.count <= limits.maximumFileByteCount else {
                throw PDFBridgeError.dataTooLarge(byteCount: bytes.count, limit: limits.maximumFileByteCount)
            }
            origin = .memory(byteCount: bytes.count)
            probe = PDFFileProbe.probe(data: bytes, limits: limits)
            guard probe.byteCount > 0 else { throw PDFBridgeError.damaged(.empty) }
            guard probe.headerVersion != nil else { throw PDFBridgeError.damaged(.missingHeader) }
            digest = FileDigestReader.digest(of: bytes)
        case .securityScopedBookmark:
            // Rewritten to `.url` above.
            throw PDFBridgeError.unsupported("unresolved bookmark")
        }

        try checkCancellation()

        guard let document = try EngineBarrier.guarded(
            "makePDFDocument", { Self.makePDFDocument(url: fileURL, data: data) }
        ) else {
            throw PDFBridgeError.damaged(.unparsable)
        }

        let pageCount = try EngineBarrier.guarded("pageCount") { document.pageCount }
        guard pageCount > 0 else { throw PDFBridgeError.damaged(.noPages) }
        guard pageCount <= limits.maximumPageCount else {
            throw PDFBridgeError.pageCountExceedsLimit(pageCount: pageCount, limit: limits.maximumPageCount)
        }

        var effectivePassword: String?
        if try EngineBarrier.guarded("isLocked", { document.isLocked }) {
            if let password {
                guard try EngineBarrier.guarded(
                    "unlock", { document.unlock(withPassword: password) }
                ) else {
                    throw PDFBridgeError.incorrectPassword
                }
                effectivePassword = password
            }
        }

        try checkCancellation()

        let coreGraphics = Self.makeCGPDFDocument(url: fileURL, data: data, password: effectivePassword)
        let report = CatalogInspector.inspect(document: coreGraphics, limits: limits)

        let encryption: EncryptionState = try EngineBarrier.guarded("encryptionState") {
            guard document.isEncrypted else { return .none }
            return document.isLocked ? .locked : .unlocked
        }

        let labels = PageLabelTable(
            pageCount: pageCount,
            ranges: report.pageLabelRanges ?? [PageLabelRange(startPageIndex: 0, style: .decimal)],
            isExplicit: report.pageLabelRanges != nil
        )

        let descriptor = DocumentDescriptor(
            handle: DocumentHandle(rawValue: identifiers.next()),
            origin: origin,
            digest: digest,
            pageCount: pageCount,
            version: probe.headerVersion ?? PDFVersion(major: document.majorVersion, minor: document.minorVersion),
            encryption: encryption,
            permissions: try EngineBarrier.guarded("permissions") { Self.permissions(of: document) },
            integrity: try EngineBarrier.guarded("integrity") {
                Self.integrity(
                    pdfKitPageCount: pageCount,
                    report: report,
                    probe: probe,
                    document: document,
                    limits: limits
                )
            },
            isLinearized: probe.isLinearized,
            hazards: report.hazards,
            embeddedFiles: report.embeddedFiles,
            attributes: Self.attributes(of: coreGraphics)
        )

        let named = Self.resolvedDestinations(report.namedDestinations, pageCount: pageCount, labels: labels)

        documents[descriptor.handle] = OpenDocument(
            handle: descriptor.handle,
            document: document,
            origin: origin,
            digest: digest,
            limits: limits,
            sourceData: data,
            securityScopedURL: securityScopedURL,
            descriptor: descriptor,
            labels: labels,
            namedDestinations: named,
            password: effectivePassword,
            probe: probe
        )
        succeeded = true
        return OpenedDocument(descriptor: descriptor)
    }

    public func unlock(_ handle: DocumentHandle, password: String) async throws -> DocumentDescriptor {
        var open = try entry(handle)
        let state = try EngineBarrier.guarded("unlock.state") {
            (encrypted: open.document.isEncrypted, locked: open.document.isLocked)
        }
        guard state.encrypted, state.locked else { return open.descriptor }
        guard try EngineBarrier.guarded(
            "unlock", { open.document.unlock(withPassword: password) }
        ) else {
            throw PDFBridgeError.incorrectPassword
        }
        open.password = password

        // Permissions and the catalog only become readable once the file is unlocked.
        let coreGraphics = Self.makeCGPDFDocument(
            url: open.origin.fileURL,
            data: open.sourceData,
            password: password
        )
        let report = CatalogInspector.inspect(document: coreGraphics, limits: open.limits)
        let pageCount = try EngineBarrier.guarded("unlock.pageCount") { open.document.pageCount }
        let labels = PageLabelTable(
            pageCount: pageCount,
            ranges: report.pageLabelRanges ?? [PageLabelRange(startPageIndex: 0, style: .decimal)],
            isExplicit: report.pageLabelRanges != nil
        )
        let descriptor = DocumentDescriptor(
            handle: handle,
            origin: open.descriptor.origin,
            digest: open.descriptor.digest,
            pageCount: pageCount,
            version: open.descriptor.version,
            encryption: .unlocked,
            permissions: try EngineBarrier.guarded("unlock.permissions") {
                Self.permissions(of: open.document)
            },
            // Recomputed, not copied: the page-box sampling is skipped while the document is
            // locked, so the verdict taken at a locked open could not see an unusable page box
            // and said `.intact` (BH-576).
            integrity: try EngineBarrier.guarded("unlock.integrity") {
                Self.integrity(
                    pdfKitPageCount: pageCount,
                    report: report,
                    probe: open.probe,
                    document: open.document,
                    limits: open.limits
                )
            },
            isLinearized: open.descriptor.isLinearized,
            hazards: open.descriptor.hazards.union(report.hazards),
            embeddedFiles: report.embeddedFiles.isEmpty ? open.descriptor.embeddedFiles : report.embeddedFiles,
            attributes: Self.attributes(of: coreGraphics)
        )
        open.descriptor = descriptor
        open.labels = labels
        // The same remap `open` applies: labels, and out-of-range pages unresolved (BH-577).
        open.namedDestinations = Self.resolvedDestinations(
            report.namedDestinations, pageCount: pageCount, labels: labels
        )
        documents[handle] = open
        return descriptor
    }

    public func close(_ handle: DocumentHandle) async {
        guard let open = documents.removeValue(forKey: handle) else { return }
        thumbnails.removeAll(forDocumentSHA256: open.digest.sha256)
        open.securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    public func closeAll() async {
        for handle in documents.keys { await close(handle) }
    }

    public func descriptor(of handle: DocumentHandle) async throws -> DocumentDescriptor {
        try entry(handle).descriptor
    }

    public func pageDescriptors(
        of handle: DocumentHandle,
        range: Range<Int>?
    ) async throws -> [PDFPageDescriptor] {
        let open = try entry(handle)
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        let pageCount = open.descriptor.pageCount
        let bounded = try Self.clampedRange(range, pageCount: pageCount)
        var out: [PDFPageDescriptor] = []
        out.reserveCapacity(bounded.count)
        for index in bounded {
            try checkCancellation()
            out.append(Self.pageDescriptor(index: index, page: open.document.page(at: index), labels: open.labels))
        }
        return out
    }

    /// One page's descriptor. **Always** one per index, so position `i` of the result is page
    /// `i`: a page PDFKit cannot materialise is described with empty boxes and rotation 0
    /// instead of being skipped. Skipping it shortened the array, and callers that index it
    /// positionally — OCR, search, the raster source's page count — paired every later page
    /// with the wrong descriptor and never reached the last one (BH-175). Rendering such a page
    /// still fails on its own, with a typed error, which is where the failure belongs.
    static func pageDescriptor(index: Int, page: PDFPage?, labels: PageLabelTable) -> PDFPageDescriptor {
        PDFPageDescriptor(
            index: index,
            label: labels.label(forPageIndex: index) ?? String(index + 1),
            labelIsExplicit: labels.isExplicit,
            boxes: page.map(Self.boxes(of:))
                ?? PageBoxes(media: .zero, crop: .zero, bleed: .zero, trim: .zero, art: .zero),
            rotation: page.map { PageRotationMath.normalised($0.rotation) } ?? 0
        )
    }

    public func pageLabels(of handle: DocumentHandle) async throws -> PageLabelTable {
        try entry(handle).labels
    }

    public func namedDestinations(of handle: DocumentHandle) async throws -> [NamedDestination] {
        try entry(handle).namedDestinations
    }

    // MARK: - Internal helpers

    func entry(_ handle: DocumentHandle) throws -> OpenDocument {
        guard let open = documents[handle] else { throw PDFBridgeError.unknownHandle(handle) }
        return open
    }

    /// Throws unless the document is readable: open, and past its encryption.
    func unlockedEntry(_ handle: DocumentHandle) throws -> OpenDocument {
        let open = try entry(handle)
        if open.descriptor.encryption == .locked { throw PDFBridgeError.documentLocked }
        return open
    }

    func page(_ open: OpenDocument, at index: Int) throws -> PDFPage {
        guard index >= 0, index < open.descriptor.pageCount else {
            throw PDFBridgeError.pageIndexOutOfRange(index: index, pageCount: open.descriptor.pageCount)
        }
        guard let page = open.document.page(at: index) else {
            throw PDFBridgeError.pageIndexOutOfRange(index: index, pageCount: open.descriptor.pageCount)
        }
        return page
    }

    /// Writes back a modified copy of an open document's entry, if it is still open.
    func storeEntry(_ open: OpenDocument) {
        guard documents[open.handle] != nil else { return }
        documents[open.handle] = open
    }

    func noteThumbnailRendered() { thumbnailRenderCount += 1 }
    func noteThumbnailDiskHit() { thumbnailDiskHitCount += 1 }

    func withThumbnailCache<T>(_ body: (inout ThumbnailCache) -> T) -> T {
        body(&thumbnails)
    }

    func openDocument(_ handle: DocumentHandle) -> OpenDocument? { documents[handle] }

    func pageCounts() -> [DocumentHandle: Int] {
        documents.mapValues(\.descriptor.pageCount)
    }

    /// The current `/Rotate` of every page of every open document, so a page pulled into a plan
    /// by `.insert` or `.merge` keeps its own rotation instead of being flattened to 0 (CR-75).
    func pageRotations() -> [DocumentHandle: [Int]] {
        var rotations: [DocumentHandle: [Int]] = [:]
        rotations.reserveCapacity(documents.count)
        for (handle, open) in documents {
            var perPage: [Int] = []
            perPage.reserveCapacity(open.descriptor.pageCount)
            for index in 0..<open.descriptor.pageCount {
                perPage.append(PageRotationMath.normalised(open.document.page(at: index)?.rotation ?? 0))
            }
            rotations[handle] = perPage
        }
        return rotations
    }

    /// Every file this provider currently has open, used to refuse a write that would
    /// land on someone's original.
    func openFileURLs() -> [URL] {
        documents.values.compactMap { $0.origin.fileURL }
    }

    func checkCancellation() throws {
        if Task.isCancelled { throw PDFBridgeError.cancelled }
    }

    // MARK: - Construction

    private static func makePDFDocument(url: URL?, data: Data?) -> PDFDocument? {
        if let url { return PDFDocument(url: url) }
        if let data { return PDFDocument(data: data) }
        return nil
    }

    static func makeCGPDFDocument(url: URL?, data: Data?, password: String?) -> CGPDFDocument? {
        let document: CGPDFDocument?
        if let url {
            document = CGPDFDocument(url as CFURL)
        } else if let data, let provider = CGDataProvider(data: data as CFData) {
            document = CGPDFDocument(provider)
        } else {
            document = nil
        }
        if let document, document.isEncrypted, !document.isUnlocked, let password {
            _ = document.unlockWithPassword(password)
        }
        return document
    }

    /// Named destinations as the provider reports them: each resolved page carries its label,
    /// and a page index the document does not have is reported as **unresolved** (`nil`), which
    /// is what ``DestinationTarget`` documents and what the outline reader already does.
    ///
    /// Passing an out-of-range index through made a navigation on it throw
    /// `pageIndexOutOfRange` and made ``DestinationTarget/isResolved`` true for a page that does
    /// not exist — whether the index came from a page tree the two engines repaired
    /// differently (BH-575) or from an integer page number in a local destination (BH-585).
    /// `open` and `unlock` both go through here, so the password's timing cannot change the
    /// answer (BH-577, BH-578).
    static func resolvedDestinations(
        _ destinations: [NamedDestination],
        pageCount: Int,
        labels: PageLabelTable
    ) -> [NamedDestination] {
        destinations.map { destination in
            let target = destination.target
            let index = target.pageIndex.flatMap { $0 >= 0 && $0 < pageCount ? $0 : nil }
            return NamedDestination(
                name: destination.name,
                target: DestinationTarget(
                    pageIndex: index,
                    pageLabel: index.flatMap { labels.label(forPageIndex: $0) },
                    left: target.left,
                    top: target.top,
                    zoom: target.zoom
                )
            )
        }
    }

    static func clampedRange(_ range: Range<Int>?, pageCount: Int) throws -> Range<Int> {
        guard let range else { return 0..<pageCount }
        guard range.lowerBound >= 0, range.upperBound <= pageCount, range.lowerBound <= range.upperBound
        else {
            throw PDFBridgeError.pageIndexOutOfRange(index: range.lowerBound, pageCount: pageCount)
        }
        return range
    }

    static func boxes(of page: PDFPage) -> PageBoxes {
        PageBoxes(
            media: page.bounds(for: .mediaBox),
            crop: page.bounds(for: .cropBox),
            bleed: page.bounds(for: .bleedBox),
            trim: page.bounds(for: .trimBox),
            art: page.bounds(for: .artBox)
        )
    }

    static func displayBox(for box: PDFPageBox) -> PDFDisplayBox {
        switch box {
        case .media: return .mediaBox
        case .crop: return .cropBox
        case .bleed: return .bleedBox
        case .trim: return .trimBox
        case .art: return .artBox
        }
    }

    static func permissions(of document: PDFDocument) -> DocumentPermissions {
        guard document.isEncrypted, !document.isLocked || document.allowsPrinting else {
            // Unencrypted files allow everything; a still-locked file reports what PDFKit
            // says, which is "nothing", and that is the honest answer.
            if !document.isEncrypted { return .all }
            return []
        }
        var permissions: DocumentPermissions = []
        if document.allowsPrinting { permissions.insert(.printing) }
        if document.allowsCopying { permissions.insert(.copying) }
        if document.allowsContentAccessibility { permissions.insert(.contentAccessibility) }
        if document.allowsDocumentChanges { permissions.insert(.documentChanges) }
        if document.allowsDocumentAssembly { permissions.insert(.documentAssembly) }
        if document.allowsCommenting { permissions.insert(.commenting) }
        if document.allowsFormFieldEntry { permissions.insert(.formFieldEntry) }
        return permissions
    }

    /// Document metadata, read through CoreGraphics rather than through
    /// `PDFDocument.documentAttributes`. See ``CatalogInspector/documentInfo(document:)``
    /// for why: the PDFKit getter raises an uncatchable Objective-C exception on some
    /// malformed `/Info` dictionaries.
    static func attributes(of document: CGPDFDocument?) -> DocumentAttributes {
        CatalogInspector.documentInfo(document: document)
    }

    /// Cross-checks PDFKit against CoreGraphics and against the file's own tail.
    ///
    /// Both engines repair a broken page tree, and they do not repair it the same way.
    /// A disagreement means at least one of them invented structure, which is precisely
    /// the situation where an estimator must be warned rather than reassured.
    static func integrity(
        pdfKitPageCount: Int,
        report: CatalogReport,
        probe: PDFFileProbe,
        document: PDFDocument,
        limits: DocumentLimits
    ) -> DocumentIntegrity {
        var findings: [IntegrityFinding] = []
        if !probe.hasEndOfFileMarker { findings.append(.missingEndOfFileMarker) }
        if report.coreGraphicsPageCount == 0 && !report.catalogReadable {
            findings.append(.coreGraphicsRefusedFile)
        } else if report.coreGraphicsPageCount != pdfKitPageCount {
            findings.append(
                .pageCountDisagreement(pdfKit: pdfKitPageCount, coreGraphics: report.coreGraphicsPageCount)
            )
        }
        if report.coreGraphicsPageCount > 0 && !report.catalogReadable {
            findings.append(.catalogUnreadable)
        }
        // Sampling the boxes: the first, the last and up to 30 evenly spaced pages, so a
        // 1 000-sheet set is checked in constant time.
        if !document.isLocked {
            for index in sampleIndices(pageCount: pdfKitPageCount, sampleCount: 32) {
                guard let page = document.page(at: index) else {
                    findings.append(.unusablePageBox(pageIndex: index))
                    continue
                }
                let bounds = page.bounds(for: .mediaBox)
                if !bounds.width.isFinite || !bounds.height.isFinite
                    || bounds.width <= 0 || bounds.height <= 0 {
                    findings.append(.unusablePageBox(pageIndex: index))
                }
            }
        }
        return findings.isEmpty ? .intact : .suspect(findings)
    }

    static func sampleIndices(pageCount: Int, sampleCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        guard pageCount > sampleCount else { return Array(0..<pageCount) }
        let step = max(1, pageCount / sampleCount)
        var indices: [Int] = []
        var index = 0
        while index < pageCount, indices.count < sampleCount {
            indices.append(index)
            index += step
        }
        if indices.last != pageCount - 1 { indices.append(pageCount - 1) }
        return indices
    }

    /// Resolves a bookmark through the injected platform service and starts its scope.
    ///
    /// The resolution itself is not written here: `URL.BookmarkResolutionOptions`
    /// `.withSecurityScope` is macOS-only, and an engine package may not carry a UIKit twin
    /// of it (ADR-0005 §2). Starting and stopping the scope *is* written here, because
    /// `startAccessingSecurityScopedResource()` is spelled identically on both platforms and
    /// because the start must be balanced by the close path in this same actor.
    private func resolveSecurityScopedBookmark(_ bookmark: Data) throws -> URL {
        guard let bookmarkResolver else {
            throw PDFBridgeError.bookmarkUnresolvable(
                reason: "no SecurityScopedBookmarkResolving service is installed on this provider"
            )
        }
        let url: URL
        do {
            url = try bookmarkResolver.resolve(bookmark)
        } catch let error as PDFBridgeError {
            throw error
        } catch {
            throw PDFBridgeError.bookmarkUnresolvable(reason: error.localizedDescription)
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw PDFBridgeError.securityScopeDenied(path: url.path)
        }
        return url
    }
}
