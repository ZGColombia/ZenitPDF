import Foundation
import Observation
import ZPDFUIPresentation

/// One tab in the document tab bar.
///
/// `ZPDFUIPresentation.DocumentTabSummary` carries the document itself; the revision label is
/// resolved here from the revision list, because a tab shows *which drawing revision is open*
/// and the summary type does not carry that.
public struct DocumentTabItem: Identifiable, Hashable, Sendable {

    /// The document's identity, matching ``DocumentTabSummary/id``.
    public let id: UUID
    /// The project title shown first.
    public let title: String
    /// The file name, shown as the tooltip and spoken after the title.
    public let fileName: String
    /// The revision badge, for example `"Rev C"`, or `nil` when the document has no revisions.
    public let revisionLabel: String?
    /// Whether the unsaved dot is drawn.
    public let hasUnsavedChanges: Bool
    /// Whether this is the front tab.
    public let isActive: Bool
    /// Page count, spoken by VoiceOver.
    public let pageCount: Int
    /// How the document was opened.
    public let mode: DocumentOpenMode
    /// Where the document lives on disk, when it has been saved. Drives the tab's
    /// Reveal in Finder and Copy Path.
    public let fileURL: URL?

    /// Creates a tab item.
    public init(
        id: UUID,
        title: String,
        fileName: String,
        revisionLabel: String?,
        hasUnsavedChanges: Bool,
        isActive: Bool,
        pageCount: Int,
        mode: DocumentOpenMode,
        fileURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.revisionLabel = revisionLabel
        self.hasUnsavedChanges = hasUnsavedChanges
        self.isActive = isActive
        self.pageCount = pageCount
        self.mode = mode
        self.fileURL = fileURL
    }

    /// Builds a tab item from a presentation summary plus the document's revisions.
    ///
    /// `revisions` may hold every open document's revisions; only this document's are read.
    public init(summary: DocumentTabSummary, revisions: [RevisionSummary]) {
        let matching = revisions.filter { $0.documentID == summary.id }
        self.init(
            id: summary.id,
            title: summary.title,
            fileName: summary.fileName,
            revisionLabel: Self.badgeRevision(among: matching)?.revisionLabel,
            hasUnsavedChanges: summary.hasUnsavedChanges,
            isActive: summary.isActive,
            pageCount: summary.pageCount,
            mode: summary.mode,
            fileURL: summary.fileURL
        )
    }

    /// The revision the badge names: the newest issued one.
    ///
    /// Dated revisions order by date. Undated ones fall back to the baseline being the oldest
    /// and then to the labels read **as numbers** (BH-820, IM-223): the old fallback compared
    /// labels as plain strings, so "Rev 9" beat "Rev 10" and the tab named the older revision —
    /// and the baseline its comment promised to fall back on was never consulted.
    /// `localizedStandardCompare` is numeric-aware ("Rev 9" < "Rev 10", "B" < "C").
    static func badgeRevision(among revisions: [RevisionSummary]) -> RevisionSummary? {
        revisions.max { lhs, rhs in isOlder(lhs, than: rhs) }
    }

    /// Whether `lhs` is older than `rhs` for the badge's purposes.
    static func isOlder(_ lhs: RevisionSummary, than rhs: RevisionSummary) -> Bool {
        switch (lhs.issuedDate, rhs.issuedDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        default:
            if lhs.isBaseline != rhs.isBaseline { return lhs.isBaseline }
            return lhs.revisionLabel.localizedStandardCompare(rhs.revisionLabel) == .orderedAscending
        }
    }

    /// The document's full name: the file name with its extension, or the document title when
    /// there is no file name yet. The tooltip, the spoken label and the › menu use it.
    public var displayTitle: String {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? title : name
    }

    /// What the tab itself shows: the full name without its file extension (L-24).
    ///
    /// Live test 5 (2026-10-03): three tabs in a 1 728 pt window read "Pl...df", "• ..." and
    /// "S...df" — the extension took half of what little room each tab had, and it is the one
    /// part of the name that tells documents apart least. The full name, extension included,
    /// stays in the tooltip and the accessibility label (``displayTitle``).
    public var tabTitle: String {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        // A document title is not a file name: "Block v1.2" keeps its ".2".
        guard !name.isEmpty else { return title }
        let stem = (name as NSString).deletingPathExtension
        return stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : stem
    }

    /// The tab's hover help: everything the tab may have had to leave out at its width — the
    /// document title, the revision and the unsaved state — one per line.
    public var tooltip: String {
        var lines: [String] = [displayTitle]
        if title != displayTitle, !title.isEmpty { lines.append(title) }
        if let revisionLabel { lines.append(revisionLabel) }
        if let unsavedStateText { lines.append(unsavedStateText) }
        return lines.joined(separator: "\n")
    }

    /// The spoken state after the label: "edited" while there is unsaved work, else none.
    public var accessibilityValue: String? {
        hasUnsavedChanges
            ? NSLocalizedString("edited", comment: "Accessibility value of a document tab with unsaved changes")
            : nil
    }

    /// The full spoken description: title, revision, unsaved state, page count.
    ///
    /// The unsaved dot is a dot; it has to be said out loud as well, or the state is
    /// visual-only.
    public var accessibilityLabel: String {
        // The visible file name first, then the document title when it differs, so the spoken
        // label names both what is on screen and what the document is called.
        var parts: [String] = [displayTitle]
        if title != displayTitle, !title.isEmpty { parts.append(title) }
        if let revisionLabel {
            let format = NSLocalizedString(
                "revision %@",
                comment: "Accessibility: the drawing revision shown on a document tab"
            )
            parts.append(String(format: format, revisionLabel))
        }
        parts.append(
            hasUnsavedChanges
                ? NSLocalizedString("unsaved changes", comment: "Accessibility: document tab state")
                : NSLocalizedString("saved", comment: "Accessibility: document tab state")
        )
        // Plural-aware (BH-821): a single-sheet drawing used to be announced as "1 pages".
        parts.append(LocalizedPlural.string(
            "%lld pages",
            count: pageCount,
            one: NSLocalizedString("%lld page", comment: "Accessibility: page count spoken on a document tab, singular"),
            other: NSLocalizedString("%lld pages", comment: "Accessibility: page count spoken on a document tab, plural")
        ))
        return parts.joined(separator: ", ")
    }

    /// The visible state word next to the unsaved dot, so the dot is never the only signal.
    public var unsavedStateText: String? {
        hasUnsavedChanges
            ? NSLocalizedString("Edited", comment: "Document tab: there are unsaved changes")
            : nil
    }
}

/// The document state one render of the tab bar is built from.
public struct DocumentTabBarInput: Sendable {

    /// Open documents in presenter order.
    public var tabs: [DocumentTabSummary]
    /// The front document.
    public var activeTabID: UUID?
    /// Revisions across all open documents, used to resolve each tab's badge.
    public var revisions: [RevisionSummary]

    /// Creates an input snapshot.
    public init(tabs: [DocumentTabSummary], activeTabID: UUID?, revisions: [RevisionSummary]) {
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.revisions = revisions
    }

    /// Nothing open.
    public static let empty = DocumentTabBarInput(tabs: [], activeTabID: nil, revisions: [])
}

/// Drives the document tab bar.
///
/// The model owns no documents. ``items`` is derived on every read from ``source``, which reads
/// the document presenter — so the bar follows the presenter through Observation instead of
/// needing someone to remember to refresh it after every open, close and save.
@MainActor
@Observable
public final class DocumentTabBarModel {

    /// Where the tab bar reads its state. Set by ``ProjectShellEnvironment``.
    @ObservationIgnored
    public var source: (@MainActor () -> DocumentTabBarInput)?

    /// Called when a tab is clicked.
    @ObservationIgnored
    public var onSelect: (@MainActor (UUID) -> Void)?
    /// Called when a tab's close control is used.
    @ObservationIgnored
    public var onClose: (@MainActor (UUID) -> Void)?
    /// Called when the `+` new-tab button is used.
    @ObservationIgnored
    public var onNewTab: (@MainActor () -> Void)?
    /// Moves a tab so it lands at a position in the strip (NL-DOCS-14, drag to reorder).
    /// Unset, tabs are not draggable.
    @ObservationIgnored
    public var onMoveTab: (@MainActor (_ id: UUID, _ toIndex: Int) -> Void)?
    /// Reveals a saved document in Finder. Wired by the environment; unset hides the item.
    @ObservationIgnored
    public var onRevealInFinder: (@MainActor (URL) -> Void)?
    /// Puts a saved document's path on the pasteboard. Wired by the environment; unset hides
    /// the item.
    @ObservationIgnored
    public var onCopyPath: (@MainActor (URL) -> Void)?

    /// Creates a model with no source, which renders an empty bar.
    public init() {}

    /// Creates a model over a fixed set of documents, for previews and tests.
    public init(input: DocumentTabBarInput) {
        self.source = { input }
    }

    /// The tabs to draw, in presenter order.
    ///
    /// Revisions are grouped by document once per read (IM-224). Every tab used to scan the
    /// whole revision list — O(tabs × revisions) per render of the strip, and the view read
    /// `items` twice per render on top of that.
    public var items: [DocumentTabItem] {
        Self.items(from: source?() ?? .empty)
    }

    /// The tab items for one input snapshot.
    static func items(from input: DocumentTabBarInput) -> [DocumentTabItem] {
        let revisionsByDocument = Dictionary(grouping: input.revisions, by: \.documentID)
        return input.tabs.map { summary in
            var summary = summary
            summary.isActive = summary.id == input.activeTabID
            return DocumentTabItem(summary: summary, revisions: revisionsByDocument[summary.id] ?? [])
        }
    }

    /// Whether the bar has anything to draw. An empty bar says so rather than sitting blank.
    public var isEmpty: Bool { items.isEmpty }

    /// Selects a tab.
    public func select(_ id: UUID) { onSelect?(id) }

    /// Closes a tab.
    public func close(_ id: UUID) { onClose?(id) }

    /// Opens a new document tab.
    public func newTab() { onNewTab?() }

    /// Moves a tab dropped on the tab at `targetID`: it takes that tab's place.
    public func moveTab(_ id: UUID, onto targetID: UUID) {
        let ids = items.map(\.id)
        guard id != targetID, ids.contains(id), let target = ids.firstIndex(of: targetID) else { return }
        onMoveTab?(id, target)
    }

    /// A tab's drag payload: private, so only a tab lands on a tab.
    static let dragPrefix = "zenit-tab:"
    static func dragPayload(for id: UUID) -> String { dragPrefix + id.uuidString }
    static func draggedTab(in payload: String) -> UUID? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(dragPrefix.count)))
    }

    /// Closes every tab except one, through the same close hook each tab's ✕ uses — so a
    /// drawing with unsaved work still asks before it goes.
    public func closeOthers(keeping id: UUID) {
        for other in items.map(\.id) where other != id {
            onClose?(other)
        }
    }
}
