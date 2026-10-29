import Foundation

/// What produced a row of `search_fts`.
///
/// The raw values are written into the frozen `search_fts.source_type` column, so they are
/// a file format: renaming one silently orphans every index built by an earlier build.
public enum SearchSourceType: String, Sendable, Hashable, Codable, CaseIterable {

    /// A page's PDF text layer. `source_id` is the `page.id`.
    case pdfText = "pdf-text"
    /// A page's recognised text. `source_id` is the `page.id`.
    case ocr = "ocr"
    /// `markup.subject`. `source_id` is the `markup.id`.
    case markupSubject = "markup-subject"
    /// `markup.label`. `source_id` is the `markup.id`.
    case markupLabel = "markup-label"
    /// `markup.comment`. `source_id` is the `markup.id`.
    case markupComment = "markup-comment"
    /// A `custom_value.value_text`. `source_id` is `markupId + "/" + columnId`.
    case customValue = "custom-value"
    /// `project_zone.name`. `source_id` is the `project_zone.id`.
    case zoneName = "zone-name"

    /// Bookkeeping, never a search result.
    ///
    /// ### Why the stamp lives in the FTS table
    ///
    /// Incremental reindexing needs one fact per document: "the text index in this file
    /// was built from SHA-256 *x*". The v1 schema is frozen and has nowhere to put it —
    /// there is no key/value table, and `document.sha256` records the file's hash, not the
    /// index's. Adding a table would mean a migration, and a migration to hold one string
    /// is a bad trade against a file format that users' projects are stored in.
    ///
    /// So the stamp is a row of `search_fts` whose `source_type` is this case, whose
    /// `source_id` is the document id and whose `content` is the SHA-256 hex. It cannot
    /// pollute results because every query this package issues constrains `source_type` to
    /// an explicit list, and ``SearchSourceFilter`` has no member that maps to it.
    case indexStamp = "index-stamp"
}

/// Which sources a search looks at. Spec 17.5's scope list, as a set rather than a mode,
/// because "PDF text and markups but not OCR" is a real thing an estimator asks for.
public struct SearchSourceFilter: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let pdfText = SearchSourceFilter(rawValue: 1 << 0)
    public static let ocr = SearchSourceFilter(rawValue: 1 << 1)
    public static let markupSubject = SearchSourceFilter(rawValue: 1 << 2)
    public static let markupLabel = SearchSourceFilter(rawValue: 1 << 3)
    public static let markupComment = SearchSourceFilter(rawValue: 1 << 4)
    public static let customValue = SearchSourceFilter(rawValue: 1 << 5)
    public static let zoneName = SearchSourceFilter(rawValue: 1 << 6)

    /// Subject, label and comment together — "Markups" in the scope list.
    public static let markups: SearchSourceFilter = [.markupSubject, .markupLabel, .markupComment]
    /// Everything a user can be shown.
    public static let all: SearchSourceFilter = [
        .pdfText, .ocr, .markupSubject, .markupLabel, .markupComment, .customValue, .zoneName
    ]
    /// Recognised text only, for "show me what OCR found and nothing else".
    public static let ocrOnly: SearchSourceFilter = [.ocr]
    /// Real text layers only, with nothing recognised mixed in.
    public static let pdfTextOnly: SearchSourceFilter = [.pdfText]

    /// The `source_type` values this filter selects, in a stable order so the generated
    /// SQL is identical for identical filters.
    public var sourceTypes: [SearchSourceType] {
        var types: [SearchSourceType] = []
        if contains(.pdfText) { types.append(.pdfText) }
        if contains(.ocr) { types.append(.ocr) }
        if contains(.markupSubject) { types.append(.markupSubject) }
        if contains(.markupLabel) { types.append(.markupLabel) }
        if contains(.markupComment) { types.append(.markupComment) }
        if contains(.customValue) { types.append(.customValue) }
        if contains(.zoneName) { types.append(.zoneName) }
        return types
    }
}
