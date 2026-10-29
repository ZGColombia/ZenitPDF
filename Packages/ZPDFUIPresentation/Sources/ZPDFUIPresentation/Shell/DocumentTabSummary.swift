import Foundation

/// The editing mode a document is open in.
public enum DocumentOpenMode: String, Codable, Hashable, Sendable, CaseIterable {

    /// A Zenit project with its own markup database.
    case project
    /// A PDF opened directly, with markups kept in a side-car project.
    case standalonePDF
    /// Opened read-only, for example from a locked or unsupported source.
    case readOnly

    /// A localized name for the window subtitle.
    public var displayName: String {
        switch self {
        case .project: return NSLocalizedString("Project", comment: "Document open mode")
        case .standalonePDF: return NSLocalizedString("PDF", comment: "Document open mode")
        case .readOnly: return NSLocalizedString("Read Only", comment: "Document open mode")
        }
    }
}

/// One open document in the window's tab bar.
public struct DocumentTabSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the open document.
    public let id: UUID
    /// Display title, normally the file name without extension.
    public var title: String
    /// File name including extension, used as the tab tooltip.
    public var fileName: String
    /// Location on disk, or `nil` for a document that has never been saved.
    public var fileURL: URL?
    /// Number of pages.
    public var pageCount: Int
    /// Whether there are unsaved changes.
    public var hasUnsavedChanges: Bool
    /// Whether the tab is the active one.
    public var isActive: Bool
    /// How the document is open.
    public var mode: DocumentOpenMode
    /// SF Symbol name for the tab's leading glyph.
    public var symbolName: String

    /// Creates a document tab summary.
    public init(
        id: UUID,
        title: String,
        fileName: String,
        fileURL: URL? = nil,
        pageCount: Int,
        hasUnsavedChanges: Bool = false,
        isActive: Bool = false,
        mode: DocumentOpenMode = .project,
        symbolName: String = "doc.richtext"
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.fileURL = fileURL
        self.pageCount = pageCount
        self.hasUnsavedChanges = hasUnsavedChanges
        self.isActive = isActive
        self.mode = mode
        self.symbolName = symbolName
    }

    /// A localized VoiceOver label: title, page count and edited state.
    public var accessibilityLabel: String {
        // BH-790: a single sheet read "A-101, 1 pages".
        let pages = LocalizedPlural.string(
            "%lld pages",
            count: pageCount,
            one: NSLocalizedString("%lld page", comment: "Page count, singular"),
            other: NSLocalizedString("%lld pages", comment: "Page count, plural")
        )
        let base = String(
            format: NSLocalizedString(
                "%1$@, %2$@",
                comment: "VoiceOver label for a document tab: title, page count phrase"
            ),
            title,
            pages
        )
        guard hasUnsavedChanges else { return base }
        return base + ", " + NSLocalizedString("edited", comment: "VoiceOver suffix for a document with unsaved changes")
    }
}
