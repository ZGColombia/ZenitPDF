import Foundation
import Observation
import ZPDFUIPresentation

/// How many canvases are on screen and how they are arranged.
public enum SplitCanvasLayout: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// One canvas.
    case single
    /// Two canvases side by side: one row, two columns.
    case twoColumns
    /// Two canvases stacked: two rows, one column.
    case twoRows
    /// Four canvases in a two-by-two grid.
    case grid

    /// Stable identity.
    public var id: String { rawValue }

    /// How many panes the layout shows.
    public var paneCount: Int {
        switch self {
        case .single: return 1
        case .twoColumns, .twoRows: return 2
        case .grid: return 4
        }
    }

    /// How many columns the panes are laid out in.
    public var columnCount: Int {
        switch self {
        case .single, .twoRows: return 1
        case .twoColumns, .grid: return 2
        }
    }

    /// A localized name for the layout switch.
    public var displayName: String {
        switch self {
        case .single: return NSLocalizedString("One Canvas", comment: "Split Canvas layout")
        case .twoColumns: return NSLocalizedString("Two Across", comment: "Split Canvas layout")
        case .twoRows: return NSLocalizedString("Two Down", comment: "Split Canvas layout")
        case .grid: return NSLocalizedString("Four Panes", comment: "Split Canvas layout")
        }
    }

    /// A localized shape description, so the layout is nameable without seeing the icon.
    public var shapeDescription: String {
        switch self {
        case .single: return NSLocalizedString("1 by 1", comment: "Split Canvas layout shape")
        case .twoColumns: return NSLocalizedString("1 by 2", comment: "Split Canvas layout shape")
        case .twoRows: return NSLocalizedString("2 by 1", comment: "Split Canvas layout shape")
        case .grid: return NSLocalizedString("2 by 2", comment: "Split Canvas layout shape")
        }
    }
}

/// Which pane, by position.
public enum SplitCanvasPaneID: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    case first
    case second
    case third
    case fourth

    /// Stable identity.
    public var id: String { rawValue }

    /// Zero-based position in the layout.
    public var index: Int {
        switch self {
        case .first: return 0
        case .second: return 1
        case .third: return 2
        case .fourth: return 3
        }
    }

    /// A localized name, used in the focus announcement and in the Window menu.
    public var displayName: String {
        switch self {
        case .first: return NSLocalizedString("Pane 1", comment: "Split Canvas pane name")
        case .second: return NSLocalizedString("Pane 2", comment: "Split Canvas pane name")
        case .third: return NSLocalizedString("Pane 3", comment: "Split Canvas pane name")
        case .fourth: return NSLocalizedString("Pane 4", comment: "Split Canvas pane name")
        }
    }
}

/// What one pane is showing.
public struct SplitCanvasPaneState: Hashable, Sendable, Identifiable {

    /// Which pane this is.
    public let id: SplitCanvasPaneID
    /// The document in the pane, or `nil` when it is empty.
    public var documentID: UUID?
    /// The document's title, shown in the pane header.
    public var documentTitle: String
    /// The page in the pane, or `nil` when it is empty.
    public var pageID: PageDescriptor.ID?
    /// The page label. Always what the person reads; never the index.
    public var pageLabel: String
    /// Zero-based page position, used by page synchronisation.
    public var pageIndex: Int
    /// Zoom factor, where `1.0` is 100 %.
    public var zoom: Double
    /// Scroll offset in page space, used by scroll synchronisation.
    public var scrollOffset: PDFPointValue

    /// Creates a pane state.
    public init(
        id: SplitCanvasPaneID,
        documentID: UUID? = nil,
        documentTitle: String = "",
        pageID: PageDescriptor.ID? = nil,
        pageLabel: String = "",
        pageIndex: Int = 0,
        zoom: Double = 1,
        scrollOffset: PDFPointValue = .zero
    ) {
        self.id = id
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.pageID = pageID
        self.pageLabel = pageLabel
        self.pageIndex = pageIndex
        self.zoom = zoom
        self.scrollOffset = scrollOffset
    }

    /// Whether the pane has anything in it.
    public var isEmpty: Bool { documentID == nil || pageID == nil }

    /// A localized VoiceOver label: pane, document, page, zoom.
    public var accessibilityLabel: String {
        guard !isEmpty else {
            let format = NSLocalizedString(
                "%@, empty",
                comment: "VoiceOver label for an empty Split Canvas pane"
            )
            return String(format: format, id.displayName)
        }
        let format = NSLocalizedString(
            "%1$@, %2$@, page %3$@, %4$d percent",
            comment: "VoiceOver label for a Split Canvas pane: pane name, document, page label, zoom percentage"
        )
        return String(format: format, id.displayName, documentTitle, pageLabel, Int((zoom * 100).rounded()))
    }
}

/// Which movements are mirrored between panes.
public struct SplitCanvasSyncOptions: Hashable, Sendable {

    /// Whether scrolling one pane scrolls the others.
    public var syncsScroll: Bool
    /// Whether zooming one pane zooms the others.
    public var syncsZoom: Bool
    /// Whether turning the page in one pane turns it in the others.
    public var syncsPage: Bool

    /// Creates sync options.
    public init(syncsScroll: Bool = true, syncsZoom: Bool = true, syncsPage: Bool = false) {
        self.syncsScroll = syncsScroll
        self.syncsZoom = syncsZoom
        self.syncsPage = syncsPage
    }

    /// Nothing is mirrored; every pane moves on its own.
    public static let independent = SplitCanvasSyncOptions(
        syncsScroll: false,
        syncsZoom: false,
        syncsPage: false
    )

    /// Everything is mirrored, which is what side-by-side revision review wants.
    public static let locked = SplitCanvasSyncOptions(
        syncsScroll: true,
        syncsZoom: true,
        syncsPage: true
    )
}

/// Owns the Split Canvas layout, what each pane shows, and which movements are mirrored.
///
/// Synchronisation is deliberately one-directional per gesture: the pane the person is actually
/// touching is the source, and the others follow. There is no feedback loop, because a follower
/// never re-broadcasts what it was told.
@MainActor
@Observable
public final class SplitCanvasController {

    /// How the canvases are arranged.
    public private(set) var layout: SplitCanvasLayout
    /// State for every pane the layout could show, always four entries.
    public private(set) var panes: [SplitCanvasPaneState]
    /// Which pane the keyboard and the tool palette act on.
    public private(set) var focusedPaneID: SplitCanvasPaneID
    /// Which movements are mirrored.
    public var syncOptions: SplitCanvasSyncOptions

    /// Runs when the focused pane changes, so the host can retarget the tool palette.
    public var onFocusChange: (@MainActor (SplitCanvasPaneID) -> Void)?
    /// Runs whenever a pane's state changes, so the host can drive the real canvas view.
    public var onPaneChange: (@MainActor (SplitCanvasPaneState) -> Void)?
    /// Moves a pane to a window of its own (NL-DOCS-14, a second display). Set by the host;
    /// until it is, the pane header offers no Move to Window.
    public var onDetachPane: (@MainActor (SplitCanvasPaneID) -> Void)?
    /// Panes shown in their own window; the split shows a note in their place.
    public private(set) var detachedPaneIDs: Set<SplitCanvasPaneID> = []

    /// Records that a pane moved to its own window, or came back.
    public func setDetached(_ detached: Bool, pane: SplitCanvasPaneID) {
        if detached { detachedPaneIDs.insert(pane) } else { detachedPaneIDs.remove(pane) }
    }

    /// Creates a controller.
    public init(
        layout: SplitCanvasLayout = .single,
        panes: [SplitCanvasPaneState]? = nil,
        focusedPaneID: SplitCanvasPaneID = .first,
        syncOptions: SplitCanvasSyncOptions = SplitCanvasSyncOptions()
    ) {
        self.layout = layout
        self.panes = SplitCanvasController.normalize(panes)
        self.focusedPaneID = focusedPaneID
        self.syncOptions = syncOptions
    }

    // MARK: - Reading

    /// The panes the current layout actually shows, in reading order.
    public var visiblePanes: [SplitCanvasPaneState] {
        Array(panes.prefix(layout.paneCount))
    }

    /// One pane's state.
    public func pane(_ id: SplitCanvasPaneID) -> SplitCanvasPaneState {
        panes.first { $0.id == id } ?? SplitCanvasPaneState(id: id)
    }

    /// Whether a pane is on screen under the current layout.
    public func isVisible(_ id: SplitCanvasPaneID) -> Bool {
        id.index < layout.paneCount
    }

    // MARK: - Layout and focus

    /// Changes the layout. Focus follows into a visible pane rather than disappearing.
    public func setLayout(_ layout: SplitCanvasLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        if !isVisible(focusedPaneID) {
            focusPane(.first)
        }
    }

    /// Moves focus to a pane, if the layout shows it.
    public func focusPane(_ id: SplitCanvasPaneID) {
        guard isVisible(id), id != focusedPaneID else { return }
        focusedPaneID = id
        onFocusChange?(id)
    }

    /// Moves focus to the next visible pane, wrapping at the end.
    public func focusNextPane() {
        advanceFocus(by: 1)
    }

    /// Moves focus to the previous visible pane, wrapping at the start.
    public func focusPreviousPane() {
        advanceFocus(by: -1)
    }

    private func advanceFocus(by delta: Int) {
        let count = layout.paneCount
        guard count > 1 else { return }
        let current = focusedPaneID.index
        let next = ((current + delta) % count + count) % count
        guard let id = SplitCanvasPaneID.allCases.first(where: { $0.index == next }) else { return }
        focusPane(id)
    }

    // MARK: - Pane content

    /// Puts a document and page into a pane.
    public func setContent(
        documentID: UUID?,
        documentTitle: String,
        page: PageDescriptor?,
        in paneID: SplitCanvasPaneID
    ) {
        update(paneID) { pane in
            pane.documentID = documentID
            pane.documentTitle = documentTitle
            pane.pageID = page?.id
            pane.pageLabel = page?.label ?? ""
            pane.pageIndex = page?.index ?? 0
        }
    }

    /// Whether the scroll, zoom and page sync toggles can be used: only with a second pane.
    /// The layout switch is always usable, including in the single layout (BH-312).
    public var syncControlsAreEnabled: Bool { layout != .single }

    /// Finds the page at a zero-based position in a document, so page sync can move a follower
    /// showing a different document to *its own* page at that position. Installed by the host.
    public var pageAtIndex: (@MainActor (_ documentID: UUID, _ index: Int) -> PageDescriptor?)?

    /// Turns the page in one pane, mirroring into the others when page sync is on.
    ///
    /// A follower showing the same document takes the page itself. A follower showing another
    /// document moves to *that* document's page at the same position, through
    /// ``pageAtIndex`` — or, when there is no such page or no lookup, stays where it is. It
    /// used to take the other document's page *label* while keeping its own page identity,
    /// so its header read "A-104" over a pane still drawing B-101, and an empty pane was given
    /// a label too. Finding BH-311.
    public func setPage(_ page: PageDescriptor, in paneID: SplitCanvasPaneID) {
        update(paneID) { pane in
            pane.pageID = page.id
            pane.pageLabel = page.label
            pane.pageIndex = page.index
        }
        guard syncOptions.syncsPage else { return }
        let sourceDocument = self.pane(paneID).documentID
        for follower in followers(of: paneID) {
            let followerDocument = self.pane(follower).documentID
            let target: PageDescriptor?
            if let followerDocument, followerDocument == sourceDocument {
                target = page
            } else if let followerDocument {
                target = pageAtIndex?(followerDocument, page.index)
            } else {
                target = nil
            }
            guard let target else { continue }
            update(follower) { pane in
                pane.pageID = target.id
                pane.pageLabel = target.label
                pane.pageIndex = target.index
            }
        }
    }

    /// Sets the zoom in one pane, mirroring into the others when zoom sync is on.
    public func setZoom(_ zoom: Double, in paneID: SplitCanvasPaneID) {
        let clamped = min(ViewportSnapshot.maximumZoom, max(ViewportSnapshot.minimumZoom, zoom))
        update(paneID) { $0.zoom = clamped }
        guard syncOptions.syncsZoom else { return }
        for follower in followers(of: paneID) {
            update(follower) { $0.zoom = clamped }
        }
    }

    /// Sets the scroll offset in one pane, mirroring into the others when scroll sync is on.
    public func setScrollOffset(_ offset: PDFPointValue, in paneID: SplitCanvasPaneID) {
        update(paneID) { $0.scrollOffset = offset }
        guard syncOptions.syncsScroll else { return }
        for follower in followers(of: paneID) {
            update(follower) { $0.scrollOffset = offset }
        }
    }

    /// Empties a pane without changing the layout.
    public func clearPane(_ paneID: SplitCanvasPaneID) {
        update(paneID) { pane in
            pane.documentID = nil
            pane.documentTitle = ""
            pane.pageID = nil
            pane.pageLabel = ""
            pane.pageIndex = 0
        }
    }

    // MARK: - Private

    private func followers(of source: SplitCanvasPaneID) -> [SplitCanvasPaneID] {
        visiblePanes.map(\.id).filter { $0 != source }
    }

    private func update(_ id: SplitCanvasPaneID, _ mutate: (inout SplitCanvasPaneState) -> Void) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        var pane = panes[index]
        mutate(&pane)
        guard pane != panes[index] else { return }
        panes[index] = pane
        onPaneChange?(pane)
    }

    private static func normalize(_ panes: [SplitCanvasPaneState]?) -> [SplitCanvasPaneState] {
        SplitCanvasPaneID.allCases.map { id in
            panes?.first { $0.id == id } ?? SplitCanvasPaneState(id: id)
        }
    }
}
