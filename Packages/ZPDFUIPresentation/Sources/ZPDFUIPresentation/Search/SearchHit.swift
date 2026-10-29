import Foundation

/// How far a search reaches.
public enum SearchLocation: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Only the page currently shown.
    case currentPage
    /// Every page of the active document.
    case currentDocument
    /// Every document in the project.
    case entireProject

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the scope picker.
    public var displayName: String {
        switch self {
        case .currentPage: return NSLocalizedString("Current Page", comment: "Search location scope")
        case .currentDocument: return NSLocalizedString("Current Document", comment: "Search location scope")
        case .entireProject: return NSLocalizedString("Entire Project", comment: "Search location scope")
        }
    }
}

/// Which body of text a search examines.
public enum SearchSource: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Text embedded in the PDF.
    case pdfText
    /// Text recognised by OCR on a scanned page.
    case ocrText
    /// Markup subjects and captions.
    case markups
    /// Markup comments.
    case comments
    /// Markup labels.
    case labels
    /// Values in custom ledger columns.
    case customFields

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the scope picker and the result grouping header.
    public var displayName: String {
        switch self {
        case .pdfText: return NSLocalizedString("PDF Text", comment: "Search source")
        case .ocrText: return NSLocalizedString("OCR Text", comment: "Search source")
        case .markups: return NSLocalizedString("Markups", comment: "Search source")
        case .comments: return NSLocalizedString("Comments", comment: "Search source")
        case .labels: return NSLocalizedString("Labels", comment: "Search source")
        case .customFields: return NSLocalizedString("Custom Fields", comment: "Search source")
        }
    }

    /// SF Symbol name so the source is legible without colour.
    public var symbolName: String {
        switch self {
        case .pdfText: return "doc.text"
        case .ocrText: return "text.viewfinder"
        case .markups: return "pencil.tip"
        case .comments: return "text.bubble"
        case .labels: return "tag"
        case .customFields: return "tablecells"
        }
    }
}

/// The full configuration of a search.
public struct SearchScope: Codable, Hashable, Sendable {

    /// How far the search reaches.
    public var location: SearchLocation
    /// Which bodies of text it examines. Never empty in a valid scope.
    public var sources: Set<SearchSource>
    /// Whether case must match.
    public var isCaseSensitive: Bool
    /// Whether only whole words match.
    public var isWholeWord: Bool

    /// Creates a search scope.
    ///
    /// There is no regular-expression option (W-081): the search index has no
    /// regular-expression path, and a toggle that changed nothing was worse than none.
    ///
    /// The default sources include ``SearchSource/ocrText`` (L-20). Words read by Tools ▸ Read
    /// Text from Scanned Pages are searched without a trip to Search Options: the default used
    /// to leave them out and nothing added them, so a recognised scan answered "No results" for
    /// words that were plainly on it. A recognised hit stays labelled as one — it carries
    /// `.ocrText`, and the panel shows the search-aid disclaimer beside it.
    public init(
        location: SearchLocation = .currentDocument,
        sources: Set<SearchSource> = [.pdfText, .ocrText, .markups, .comments, .labels],
        isCaseSensitive: Bool = false,
        isWholeWord: Bool = false
    ) {
        self.location = location
        self.sources = sources
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
    }

    /// The default scope: the whole document — its text, recognised text and markups —
    /// case-insensitive.
    public static let `default` = SearchScope()

    /// A localized one-line summary such as `"Current Document · PDF Text, Markups"`.
    public var summary: String {
        let sourceNames = SearchSource.allCases
            .filter { sources.contains($0) }
            .map(\.displayName)
            .joined(separator: ", ")
        let format = NSLocalizedString(
            "%1$@ · %2$@",
            comment: "Search scope summary: location, comma-separated source list"
        )
        return String(format: format, location.displayName, sourceNames)
    }
}

/// One search result.
public struct SearchHit: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the hit for the duration of the result set.
    public let id: UUID
    /// Document the hit belongs to.
    public var documentID: UUID
    /// Document title, denormalised for project-wide result lists.
    public var documentTitle: String
    /// Page the hit is on.
    public var pageID: PageDescriptor.ID
    /// Zero-based page index, for ordering.
    public var pageIndex: Int
    /// Page label shown in the result row.
    public var pageLabel: String
    /// Where the text came from.
    public var source: SearchSource
    /// A short excerpt with surrounding context.
    public var snippet: String
    /// Range of the match inside ``snippet``, as UTF-16 offsets, for highlighting.
    public var highlightRange: Range<Int>?
    /// Bounds of the match on the page, used to scroll and flash the hit.
    public var boundsInPageSpace: PDFRectValue?
    /// The markup that produced the hit, for markup, comment, label and custom sources.
    public var markupID: UUID?

    /// The *other* open drawing this hit came from, or `nil` when it came from the drawing
    /// the user is looking at.
    ///
    /// Optional rather than always-set so that every existing construction of a hit is
    /// unchanged and means what it always meant: a hit with no source document is a hit on the
    /// active document. A hit with one was found by a project-wide search in a drawing that is
    /// open but not in front, and the results list must say so — see
    /// ``sourceDocumentTitle``.
    public var sourceDocumentID: UUID?

    /// The title of that other drawing, denormalised so a result row can name it without a
    /// lookup — and can still name it after the drawing has been closed.
    public var sourceDocumentTitle: String?

    /// Creates a search hit.
    public init(
        id: UUID,
        documentID: UUID,
        documentTitle: String,
        pageID: PageDescriptor.ID,
        pageIndex: Int,
        pageLabel: String,
        source: SearchSource,
        snippet: String,
        highlightRange: Range<Int>? = nil,
        boundsInPageSpace: PDFRectValue? = nil,
        markupID: UUID? = nil,
        sourceDocumentID: UUID? = nil,
        sourceDocumentTitle: String? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.pageID = pageID
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.source = source
        self.snippet = snippet
        self.highlightRange = highlightRange
        self.boundsInPageSpace = boundsInPageSpace
        self.markupID = markupID
        self.sourceDocumentID = sourceDocumentID
        self.sourceDocumentTitle = sourceDocumentTitle
    }

    /// A localized VoiceOver label: source, page and excerpt — and, for a hit found in another
    /// open drawing, which drawing that was.
    ///
    /// The drawing is named first. A screen-reader user stepping through a project-wide result
    /// list has no column to glance at, so "which drawing" has to arrive before the excerpt or
    /// it arrives too late to be the thing that disambiguates two identical snippets.
    public var accessibilityLabel: String {
        let format = NSLocalizedString(
            "%1$@ on page %2$@: %3$@",
            comment: "VoiceOver label for a search hit: source name, page label, excerpt"
        )
        let base = String(format: format, source.displayName, pageLabel, snippet)
        guard let sourceDocumentTitle else { return base }
        let scoped = NSLocalizedString(
            "In %1$@: %2$@",
            comment: "VoiceOver label for a search hit found in another open drawing: drawing title, hit description"
        )
        return String(format: scoped, sourceDocumentTitle, base)
    }
}
