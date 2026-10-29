import CoreGraphics
import CryptoKit
import Foundation

/// Extracts vector geometry from a PDF page with CoreGraphics only.
///
/// An actor because it owns file IO and because `CGPDFDocument` is not thread-safe: one
/// extractor serialises every page it reads. Callers that want parallelism across
/// documents create one extractor per document.
///
/// ```swift
/// let extractor = VectorExtractor()
/// let page = try await extractor.extract(documentAt: url, pageIndex: 0)
/// switch page.availability {
/// case .available:            // normal Vector Snap
/// case .partial(let reason):  // works, but say it is incomplete
/// case .unavailable:          // "Vector Snap unavailable"; grid and markup snap still work
/// }
/// ```
public actor VectorExtractor {

    /// Bumped whenever a change can move a coordinate or change which primitives are
    /// emitted. Part of every ``VectorCacheKey``.
    public static var extractorVersion: Int { VectorPageScanner.extractorVersion }

    private let options: VectorExtractionOptions
    private let cache: VectorExtractionCache?
    /// Digests are expensive on large files and constant per file, so they are memoised
    /// for the lifetime of the extractor, keyed by path plus size plus modification date.
    private var digestCache: [String: String] = [:]
    private static let maximumDigestCacheEntries = 256
    /// The most recently opened document, under the same key as the digest memo. Every
    /// open re-reads the trailer and the cross-reference table — and rebuilds it by
    /// scanning the whole file when the table is damaged — so a 200-sheet set used to be
    /// parsed again for each call to ``extract(documentAt:pageIndex:password:)`` on every
    /// page turn (IM-159). The actor serialises access, which is what makes holding a
    /// `CGPDFDocument` here safe; it is dropped as soon as the file changes underneath.
    private var openDocument: (memoKey: String, document: CGPDFDocument)?
    /// How many times a document was opened, for the reuse test.
    private(set) var documentOpenCount = 0

    public init(
        options: VectorExtractionOptions = .standard,
        cache: VectorExtractionCache? = nil
    ) {
        self.options = options
        self.cache = cache
    }

    // MARK: - Extraction

    /// Extracts one page.
    ///
    /// - Parameter password: the user password of a password-protected drawing, when the
    ///   person has unlocked it in the viewer (BH-069). Tried with
    ///   `CGPDFDocument.unlockWithPassword` only when the document is locked; ignored for an
    ///   unencrypted file or one that opens with an empty user password. A locked document
    ///   is unlocked on a private handle that is never memoised, and its extraction is never
    ///   stored in (or served from) the cache — otherwise a later call *without* the password
    ///   would receive the geometry of a drawing it cannot open.
    /// - Throws: ``VectorExtractionError`` and nothing else. A page with no vector
    ///   content is **not** an error: it returns `.unavailable(.noVectorContent)`. A locked
    ///   document with no password, or a wrong one, throws `.documentEncrypted`.
    public func extract(
        documentAt url: URL,
        pageIndex: Int,
        password: String? = nil
    ) async throws -> VectorPageExtraction {
        let options = try self.options.validated()
        try Task.checkCancellation(mapping: VectorExtractionError.cancelled)

        let fileName = url.lastPathComponent
        let digest = try documentDigest(for: url)

        if let cache {
            let key = VectorCacheKey(
                documentDigest: digest,
                pageIndex: pageIndex,
                extractorVersion: Self.extractorVersion,
                configurationFingerprint: options.fingerprint
            )
            if let hit = await cache.value(for: key) { return hit }
        }

        var document = try self.document(at: url)
        var unlockedWithPassword = false
        if document.isEncrypted && !document.isUnlocked {
            document = try Self.unlockedDocument(at: url, password: password)
            unlockedWithPassword = true
        }
        let pageCount = document.numberOfPages
        guard pageCount > 0 else {
            throw VectorExtractionError.documentHasNoPages(fileName: fileName)
        }
        guard pageIndex >= 0, pageIndex < pageCount else {
            throw VectorExtractionError.pageIndexOutOfRange(index: pageIndex, pageCount: pageCount)
        }
        guard let page = document.page(at: pageIndex + 1) else {
            throw VectorExtractionError.contentStreamUnavailable(pageIndex: pageIndex)
        }

        let extraction = try VectorPageScanner.scan(
            page: page,
            pageIndex: pageIndex,
            documentDigest: digest,
            options: options
        )
        if let cache, !unlockedWithPassword, Self.isCacheable(extraction) { await cache.store(extraction) }
        return extraction
    }

    /// A fresh handle on a locked document, unlocked with `password`.
    ///
    /// Fresh and private on purpose: the memoised handle is never unlocked, so the memo can
    /// never hand an unlocked drawing to a caller that did not supply the password.
    private static func unlockedDocument(at url: URL, password: String?) throws -> CGPDFDocument {
        let fileName = url.lastPathComponent
        guard let password, !password.isEmpty,
              let document = CGPDFDocument(url as CFURL),
              document.unlockWithPassword(password),
              document.isUnlocked
        else {
            throw VectorExtractionError.documentEncrypted(fileName: fileName)
        }
        return document
    }

    /// Whether a result is a property of the page rather than of the run that produced it.
    ///
    /// The cache key deliberately excludes the clock, so a result must not depend on it
    /// either. A page cut short by the **wall-clock** budget on a busy machine would
    /// otherwise be served as that page's permanent extraction — truncated, with missing
    /// snap targets, for the life of the cache — although a retry would extract it in
    /// full (BH-324). The other budgets (operator count, primitive count, the memory
    /// *estimate*) are deterministic functions of the content and the options, so their
    /// partial results are reproducible and stay cacheable.
    static func isCacheable(_ extraction: VectorPageExtraction) -> Bool {
        !extraction.partialReasons.contains { reason in
            if case .budgetExceeded(.wallClock, _) = reason { return true }
            return false
        }
    }

    /// The number of pages, without extracting anything.
    public func pageCount(documentAt url: URL) throws -> Int {
        try document(at: url).numberOfPages
    }

    // MARK: - Document handle

    /// The open document for `url`, reused while the file on disk is unchanged.
    private func document(at url: URL) throws -> CGPDFDocument {
        let memoKey = Self.fileMemoKey(for: url)
        if let open = openDocument, open.memoKey == memoKey { return open.document }
        openDocument = nil
        guard let document = CGPDFDocument(url as CFURL) else {
            throw VectorExtractionError.documentUnreadable(fileName: url.lastPathComponent)
        }
        documentOpenCount += 1
        openDocument = (memoKey, document)
        return document
    }

    /// Path plus size plus modification date: what both the digest memo and the open
    /// document are keyed by, so either is dropped the moment the file changes.
    private static func fileMemoKey(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
        return "\(url.path)|\(size)|\(modified)"
    }

    // MARK: - Digest

    /// Lowercase hex SHA-256 of the file, streamed in 1 MiB chunks.
    ///
    /// Streamed rather than `Data(contentsOf:)` on purpose: the digest of a 400 MB
    /// drawing set must not cost 400 MB of resident memory, and a hostile file is
    /// exactly the case where it would.
    public func documentDigest(for url: URL) throws -> String {
        let fileName = url.lastPathComponent
        let memoKey = Self.fileMemoKey(for: url)
        if let cached = digestCache[memoKey] { return cached }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw VectorExtractionError.fileUnreadable(fileName: fileName, reason: "\(error)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw VectorExtractionError.fileUnreadable(fileName: fileName, reason: "\(error)")
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        if digestCache.count >= Self.maximumDigestCacheEntries { digestCache.removeAll() }
        digestCache[memoKey] = digest
        return digest
    }
}

extension Task where Success == Never, Failure == Never {
    /// `Task.checkCancellation()` throws `CancellationError`; this package promises that
    /// everything it throws is a ``VectorExtractionError``.
    static func checkCancellation(mapping error: VectorExtractionError) throws {
        if Task.isCancelled { throw error }
    }
}
