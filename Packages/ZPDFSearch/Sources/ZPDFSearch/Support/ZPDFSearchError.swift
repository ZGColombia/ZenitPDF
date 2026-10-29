import Foundation

/// Every failure this package can produce.
///
/// The set is closed and `Equatable`, so a test asserts on the exact case rather than on
/// a message. Nothing here carries document *text*: spec 17.4 forbids document text in
/// diagnostics, and an error string is a diagnostic. Identifiers, page indices and counts
/// are safe; the words on the sheet are not.
public enum ZPDFSearchError: Error, Sendable, Hashable, CustomStringConvertible {

    // MARK: Lifecycle
    /// The task was cancelled. Whatever had been committed stays committed; nothing
    /// half-written is left behind.
    case cancelled

    // MARK: Identity
    case unknownDocument(documentId: String)
    case unknownProject(projectId: String)
    /// The document row exists but has no `page` rows for the indices being indexed, so
    /// there is no `page_id` to key FTS and OCR rows by.
    case documentHasNoPageRows(documentId: String)
    /// A page index present in the PDF has no matching `page` row.
    case missingPageRow(documentId: String, pageIndex: Int)

    // MARK: Ranges and budgets
    case pageRangeOutOfBounds(lowerBound: Int, upperBound: Int, pageCount: Int)
    case tooManyPagesRequested(count: Int, limit: Int)

    // MARK: OCR
    /// Vision accepted the request and then failed on this page.
    case recognitionFailed(pageIndex: Int, reason: String)
    /// The page could not be rasterised for recognition.
    case pageRenderFailed(pageIndex: Int, reason: String)

    // MARK: Storage
    /// A `ZPDFPersistence` failure, reduced to its description so this enum stays
    /// `Hashable` without depending on the shape of the persistence error.
    case storage(String)
    /// A `ZPDFPDFKitBridge` failure, likewise.
    case engine(String)

    public var description: String {
        switch self {
        case .cancelled:
            return "cancelled"
        case let .unknownDocument(id):
            return "no document row with id \(id)"
        case let .unknownProject(id):
            return "no project row with id \(id)"
        case let .documentHasNoPageRows(id):
            return "document \(id) has no page rows"
        case let .missingPageRow(id, index):
            return "document \(id) has no page row for index \(index)"
        case let .pageRangeOutOfBounds(lower, upper, count):
            return "page range \(lower)..<\(upper) is outside 0..<\(count)"
        case let .tooManyPagesRequested(count, limit):
            return "\(count) pages requested, limit is \(limit)"
        case let .recognitionFailed(index, reason):
            return "recognition failed on page \(index): \(reason)"
        case let .pageRenderFailed(index, reason):
            return "page \(index) could not be rendered: \(reason)"
        case let .storage(reason):
            return "storage: \(reason)"
        case let .engine(reason):
            return "pdf engine: \(reason)"
        }
    }
}

// MARK: - Adapting foreign errors

extension ZPDFSearchError {
    /// Wraps whatever a dependency threw, preserving cancellation as cancellation.
    ///
    /// Cancellation arrives in three shapes here — Swift's `CancellationError`, the
    /// bridge's `.cancelled`, and the persistence layer's `.cancelled` — and all three
    /// must land on ``ZPDFSearchError/cancelled`` or a caller cannot tell "the user
    /// pressed stop" from "the database is broken".
    static func adaptStorage(_ error: any Error) -> ZPDFSearchError {
        if let already = error as? ZPDFSearchError { return already }
        if error is CancellationError { return .cancelled }
        let text = String(describing: error)
        if text.contains("cancelled") { return .cancelled }
        return .storage(text)
    }

    static func adaptEngine(_ error: any Error) -> ZPDFSearchError {
        if let already = error as? ZPDFSearchError { return already }
        if error is CancellationError { return .cancelled }
        let text = String(describing: error)
        if text == "cancelled" { return .cancelled }
        return .engine(text)
    }
}

/// Throws ``ZPDFSearchError/cancelled`` when the current task has been cancelled.
@inlinable
func checkSearchCancellation() throws(ZPDFSearchError) {
    if Task.isCancelled { throw ZPDFSearchError.cancelled }
}

// MARK: - What NSError bridging shows a person (IM-007)

/// Without this conformance a search error reaching `NSDocument.presentError` or an alert
/// read "The operation couldn't be completed. (ZPDFSearch.ZPDFSearchError error 7.)".
/// The description is a sentence a person can read; the suggestion says what to do.
/// Localization-ready: every string goes through `NSLocalizedString`.
extension ZPDFSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return NSLocalizedString("search.error.cancelled", value: "Search was stopped.",
                                     comment: "Search or indexing was cancelled")
        case .unknownDocument, .unknownProject, .documentHasNoPageRows, .missingPageRow:
            return NSLocalizedString("search.error.index-mismatch",
                                     value: "The search index does not match this project’s drawings.",
                                     comment: "Search index refers to rows that do not exist")
        case .pageRangeOutOfBounds, .tooManyPagesRequested:
            return NSLocalizedString("search.error.page-range",
                                     value: "Those pages are not in this drawing.",
                                     comment: "Requested page range is invalid")
        case let .recognitionFailed(pageIndex, _), let .pageRenderFailed(pageIndex, _):
            let format = NSLocalizedString("search.error.ocr-page",
                                           value: "Text on page %d could not be recognised.",
                                           comment: "OCR failed on one page; %d is the 1-based page number")
            return String(format: format, pageIndex + 1)
        case .storage:
            return NSLocalizedString("search.error.storage",
                                     value: "The search index could not be read or saved.",
                                     comment: "Database failure in search")
        case .engine:
            return NSLocalizedString("search.error.engine",
                                     value: "The drawing could not be read for search.",
                                     comment: "PDF engine failure in search")
        }
    }

    /// The developer-facing detail, for logs and diagnostics.
    public var failureReason: String? { description }

    public var recoverySuggestion: String? {
        switch self {
        case .unknownDocument, .unknownProject, .documentHasNoPageRows, .missingPageRow, .storage:
            return NSLocalizedString("search.suggestion.reindex",
                                     value: "Rebuild the search index, then search again.",
                                     comment: "Suggestion for an index/storage failure")
        case .recognitionFailed, .pageRenderFailed:
            return NSLocalizedString("search.suggestion.ocr",
                                     value: "Searching the drawing’s own text still works; recognised text on this page is missing.",
                                     comment: "Suggestion for an OCR failure")
        case .engine:
            return NSLocalizedString("search.suggestion.engine",
                                     value: "Check that the drawing opens, then search again.",
                                     comment: "Suggestion for a PDF engine failure")
        case .cancelled, .pageRangeOutOfBounds, .tooManyPagesRequested:
            return nil
        }
    }
}
