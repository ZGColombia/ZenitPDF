import Foundation

/// Why a page operation could not be planned.
///
/// Faults are produced by ``PageOperationPlanner`` before any file is touched, so a
/// caller can show the user what is wrong without the bridge having opened a writer.
public enum PageOperationFault: Error, Sendable, Hashable, CustomStringConvertible {
    /// A page index outside `0 ..< count`.
    case pageIndexOutOfRange(index: Int, count: Int)
    /// The same page index appears twice in one operation.
    case duplicatePageIndex(Int)
    /// A reorder whose index list is not a permutation of `0 ..< count`.
    case notAPermutation(expectedCount: Int, receivedCount: Int)
    /// A rotation that is not a whole multiple of 90 degrees.
    case rotationNotMultipleOfNinety(degrees: Int)
    /// An insertion index outside `0 ... count`.
    case insertIndexOutOfRange(index: Int, count: Int)
    /// An operation naming a document the provider does not have open.
    case unknownDocument(DocumentHandle)
    /// The operation list would leave a document with no pages, which is not a legal PDF.
    case resultWouldBeEmpty
    /// The result would exceed ``DocumentLimits/maximumPageCount``.
    case resultExceedsPageLimit(count: Int, limit: Int)
    /// More operations than ``DocumentLimits/maximumPageOperations``.
    case tooManyOperations(count: Int, limit: Int)

    public var description: String {
        switch self {
        case let .pageIndexOutOfRange(index, count):
            return "page index \(index) is outside 0..<\(count)"
        case let .duplicatePageIndex(index):
            return "page index \(index) appears more than once"
        case let .notAPermutation(expected, received):
            return "reorder needs a permutation of \(expected) indices, received \(received)"
        case let .rotationNotMultipleOfNinety(degrees):
            return "rotation \(degrees) is not a multiple of 90"
        case let .insertIndexOutOfRange(index, count):
            return "insert index \(index) is outside 0...\(count)"
        case let .unknownDocument(handle):
            return "document \(handle.rawValue) is not open"
        case .resultWouldBeEmpty:
            return "the result would have no pages"
        case let .resultExceedsPageLimit(count, limit):
            return "the result would have \(count) pages, limit is \(limit)"
        case let .tooManyOperations(count, limit):
            return "\(count) operations requested, limit is \(limit)"
        }
    }
}

/// Why a document could not be trusted to be intact.
public enum DamageReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The bytes do not start with a `%PDF-` header.
    case missingHeader
    /// No `%%EOF` marker in the trailing window.
    case missingEndOfFileMarker
    /// Neither PDFKit nor CoreGraphics could build a document object.
    case unparsable
    /// A document object exists but reports zero pages.
    case noPages
    /// The file is empty.
    case empty
}

/// Every failure this package can produce.
///
/// The set is closed and `Equatable`, so tests assert on the exact case rather than on a
/// message, and call sites can switch exhaustively. Nothing in this package throws an
/// `NSError` across its own API boundary.
public enum PDFBridgeError: Error, Sendable, Hashable, CustomStringConvertible {
    // MARK: Opening
    case fileNotFound(path: String)
    case fileUnreadable(path: String, reason: String)
    case fileTooLarge(byteCount: Int, limit: Int)
    case dataTooLarge(byteCount: Int, limit: Int)
    case damaged(DamageReason)
    case pageCountExceedsLimit(pageCount: Int, limit: Int)
    case passwordRequired
    case incorrectPassword
    /// The document is encrypted and still locked, so this operation cannot run.
    case documentLocked
    case bookmarkUnresolvable(reason: String)
    case securityScopeDenied(path: String)

    // MARK: Handles and indices
    case unknownHandle(DocumentHandle)
    case pageIndexOutOfRange(index: Int, pageCount: Int)
    case characterRangeOutOfRange(location: Int, length: Int, characterCount: Int)

    // MARK: Rendering
    case pixelBudgetExceeded(requestedPixels: Int, limit: Int)
    case invalidScale(Double)
    case emptyRenderRegion
    case renderFailed(reason: String)

    // MARK: Text
    case emptySearchQuery
    case searchQueryTooLong(length: Int, limit: Int)

    // MARK: Writing — the original file is never touched
    case destinationIsSource(path: String)
    case destinationExists(path: String)
    case destinationDirectoryMissing(path: String)
    case writeFailed(path: String, reason: String)
    /// The source file's SHA-256 changed across a write, or no longer matches the bytes that
    /// were opened. The write is reported as failed even if the destination was produced,
    /// because the immutability guarantee broke; when the source changed after the open,
    /// nothing is written at all.
    case sourceMutatedDuringWrite(path: String)

    // MARK: Page operations
    case pageOperation(PageOperationFault)

    // MARK: Layers
    /// `/OCProperties` exists but cannot be read as a layer catalogue — `/OCGs` is
    /// missing, is not an array, or contains a reference that does not resolve to a
    /// dictionary. A missing `/OCProperties` is *not* this error; that is the normal
    /// no-layers document and reads as `nil`.
    case layerCatalogUnreadable(reason: String)

    // MARK: Lifecycle
    case cancelled
    case unsupported(String)

    // MARK: - Engine

    /// The underlying PDF engine raised an Objective-C exception, which
    /// ``EngineBarrier`` caught and converted rather than letting it kill the process.
    /// The document is not trustworthy for this operation.
    case engineRaised(operation: String, name: String, reason: String)

    public var description: String {
        switch self {
        case let .fileNotFound(path): return "no file at \(path)"
        case let .fileUnreadable(path, reason): return "cannot read \(path): \(reason)"
        case let .fileTooLarge(bytes, limit): return "file is \(bytes) bytes, limit is \(limit)"
        case let .dataTooLarge(bytes, limit): return "data is \(bytes) bytes, limit is \(limit)"
        case let .damaged(reason): return "damaged PDF: \(reason.rawValue)"
        case let .pageCountExceedsLimit(count, limit): return "\(count) pages, limit is \(limit)"
        case .passwordRequired: return "the document is encrypted and needs a password"
        case .incorrectPassword: return "the password did not unlock the document"
        case .documentLocked: return "the document is locked"
        case let .bookmarkUnresolvable(reason): return "bookmark unusable: \(reason)"
        case let .securityScopeDenied(path): return "security scope denied for \(path)"
        case let .unknownHandle(handle): return "document \(handle.rawValue) is not open"
        case let .pageIndexOutOfRange(index, count): return "page \(index) of \(count)"
        case let .characterRangeOutOfRange(location, length, count):
            return "character range \(location)..<\(location + length) of \(count)"
        case let .pixelBudgetExceeded(pixels, limit): return "\(pixels) pixels requested, budget is \(limit)"
        case let .invalidScale(scale): return "scale \(scale) is not usable"
        case .emptyRenderRegion: return "the render region is empty"
        case let .renderFailed(reason): return "render failed: \(reason)"
        case .emptySearchQuery: return "the search query is empty"
        case let .searchQueryTooLong(length, limit): return "query is \(length) characters, limit is \(limit)"
        case let .destinationIsSource(path): return "refusing to write over the source file \(path)"
        case let .destinationExists(path): return "\(path) already exists"
        case let .destinationDirectoryMissing(path): return "no directory at \(path)"
        case let .writeFailed(path, reason): return "cannot write \(path): \(reason)"
        case let .sourceMutatedDuringWrite(path): return "the source file \(path) changed during a write"
        case let .pageOperation(fault): return "invalid page operation: \(fault)"
        case let .layerCatalogUnreadable(reason): return "unreadable layer catalogue: \(reason)"
        case let .engineRaised(operation, name, reason):
            return "the PDF engine raised \(name) during \(operation): \(reason)"
        case .cancelled: return "cancelled"
        case let .unsupported(what): return "unsupported: \(what)"
        }
    }
}

/// What `NSError` bridging shows a person (IM-007).
///
/// Without this an engine error that reaches `NSDocument.presentError` reads "The
/// operation couldn't be completed. (ZPDFPDFKitBridge.PDFBridgeError error 5.)" and the
/// sentence above never appears. The description becomes the title, as a sentence; the
/// suggestion, where one exists, says what to do about it.
extension PDFBridgeError: LocalizedError {
    public var errorDescription: String? {
        let text = description
        guard let first = text.first else { return nil }
        let sentence = first.uppercased() + text.dropFirst()
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    public var recoverySuggestion: String? {
        switch self {
        case .passwordRequired, .incorrectPassword, .documentLocked:
            return "Enter the document's password to open it."
        case .fileTooLarge, .dataTooLarge, .pageCountExceedsLimit, .pixelBudgetExceeded:
            return "Split the drawing set into smaller files and open those instead."
        case .damaged, .engineRaised:
            return "Re-export the PDF from the program that produced it, then open it again."
        case .sourceMutatedDuringWrite:
            return "Another program changed the file while it was being written. Reopen it and try again."
        case .securityScopeDenied:
            return "Choose the file again so Zenit PDF is allowed to read it."
        default:
            return nil
        }
    }
}
