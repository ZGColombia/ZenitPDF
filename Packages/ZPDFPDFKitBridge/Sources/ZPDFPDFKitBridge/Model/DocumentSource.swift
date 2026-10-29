import Foundation

/// Where a document's bytes come from.
///
/// A security-scoped bookmark is a first-class case rather than something the caller
/// resolves itself, because in a sandboxed app the resolve/`startAccessingSecurityScopedResource`
/// /`stop` triple must bracket every read, and getting that wrong silently produces
/// "file not found" for a file the user can plainly see.
public enum DocumentSource: Sendable, Hashable {
    /// A file the process already has permission to read.
    case url(URL)
    /// Bytes already in memory. Nothing is written to disk.
    case data(Data)
    /// A security-scoped bookmark as produced by
    /// `URL.bookmarkData(options: .withSecurityScope, ...)`.
    case securityScopedBookmark(Data)

    /// The file this source refers to, when it refers to one at all.
    public var fileURL: URL? {
        if case let .url(url) = self { return url }
        return nil
    }
}

/// Where an opened document came from, recorded on its descriptor.
public enum DocumentOrigin: Sendable, Hashable {
    case file(URL)
    case memory(byteCount: Int)

    public var fileURL: URL? {
        if case let .file(url) = self { return url }
        return nil
    }
}

/// What to do when the destination of a write already exists.
public enum OverwritePolicy: Sendable, Hashable, Codable, CaseIterable {
    /// Throw ``PDFBridgeError/destinationExists(path:)``. The default everywhere.
    case fail
    /// Replace the existing file.
    case replace
}

/// The destination of any operation that produces a new document.
///
/// Every write in this package goes to a `DocumentDestination`. There is no API that
/// writes back into an open document, which is how "the original is never mutated" is
/// enforced in code rather than by convention: there is nothing to call.
public struct DocumentDestination: Sendable, Hashable {
    public var url: URL
    public var overwritePolicy: OverwritePolicy

    public init(url: URL, overwritePolicy: OverwritePolicy = .fail) {
        self.url = url
        self.overwritePolicy = overwritePolicy
    }
}

/// What a write produced, and proof that the source survived it.
///
/// `sourceDigestBefore` and `sourceDigestAfter` are the SHA-256 of the *source* file,
/// hashed immediately before and immediately after the write. They are part of the
/// return value rather than an internal assertion so a caller — or an audit log — can
/// see the guarantee rather than trust it.
public struct DocumentWriteReceipt: Sendable, Hashable {
    public let destination: URL
    public let digest: FileDigest
    public let pageCount: Int
    /// `nil` when the source was in-memory rather than a file.
    public let sourceDigestBefore: FileDigest?
    public let sourceDigestAfter: FileDigest?
    /// Document structure a page operation could not carry into the result — for a
    /// confirmation sheet to say. Empty for every other write.
    public let structureNotCarried: Set<DocumentStructureFeature>

    /// `true` when there was no source file, or the source file's bytes are unchanged.
    public var sourceIsUnchanged: Bool {
        guard let before = sourceDigestBefore, let after = sourceDigestAfter else { return true }
        return before == after
    }

    public init(
        destination: URL,
        digest: FileDigest,
        pageCount: Int,
        sourceDigestBefore: FileDigest?,
        sourceDigestAfter: FileDigest?,
        structureNotCarried: Set<DocumentStructureFeature> = []
    ) {
        self.destination = destination
        self.digest = digest
        self.pageCount = pageCount
        self.sourceDigestBefore = sourceDigestBefore
        self.sourceDigestAfter = sourceDigestAfter
        self.structureNotCarried = structureNotCarried
    }
}
