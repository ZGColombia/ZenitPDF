import Foundation
import Observation

/// How a click on a page in the Navigator changes the page selection.
///
/// A closed value rather than a pair of booleans, so the three cases are exhaustive at
/// every call site and the batch scope that reads the result cannot be handed a fourth
/// meaning nobody implemented. The mapping from modifier keys lives in
/// ``PageSelectionMode/forModifiers(command:shift:)`` so it is testable without AppKit.
public enum PageSelectionMode: String, Hashable, Sendable, CaseIterable {

    /// A plain click: this page and nothing else.
    case replace

    /// Command-click: add this page to the selection, or take it out of one.
    case toggle

    /// Shift-click: every page from the anchor to this one, inclusive.
    case extend

    /// The mode a click with these modifiers means.
    ///
    /// Command wins over Shift, which is the platform rule: Command-Shift-click on a list
    /// toggles, it does not extend.
    public static func forModifiers(command: Bool, shift: Bool) -> PageSelectionMode {
        if command { return .toggle }
        if shift { return .extend }
        return .replace
    }
}

/// Presents the open documents, their pages, zones and scale regions.
@MainActor
public protocol DocumentPresenting: ZenitPresenting {

    /// Open documents in tab-bar order.
    var tabs: [DocumentTabSummary] { get }
    /// The active document, or `nil` when no document is open.
    var activeTabID: DocumentTabSummary.ID? { get }
    /// Pages of the active document, in document order.
    var pages: [PageDescriptor] { get }
    /// The page the canvas is showing, or `nil` when no document is open.
    var currentPageID: PageDescriptor.ID? { get }
    /// The pages the Navigator has selected, in document order.
    ///
    /// Empty means *nothing is selected*, and never *all of them*. Every consumer of this
    /// — the scoped batch apply above all — has to be able to tell the difference, because
    /// the failure mode of confusing them is placing 312 stamps when the person selected
    /// none.
    var selectedPageIDs: [PageDescriptor.ID] { get }
    /// Project Zones of the active document.
    var zones: [ProjectZoneSummary] { get }
    /// Scale Regions of the active document.
    var scaleRegions: [ScaleRegionSummary] { get }
    /// The scale applied to pages that no Scale Region covers.
    var defaultScale: ScaleSummary? { get }
    /// Outstanding warnings for the active document.
    var warnings: [AppWarning] { get }

    /// Makes a document active.
    func selectTab(_ id: DocumentTabSummary.ID)
    /// Closes a document. Implementations must not discard unsaved work without asking.
    func closeTab(_ id: DocumentTabSummary.ID)
    /// Navigates to a page by identity.
    func goToPage(id: PageDescriptor.ID)
    /// Navigates to a page by zero-based index. Out-of-range indices are ignored.
    ///
    /// A typed sheet reference (number, label or position) is resolved by the shell's one
    /// rule, `StatusBarDisplay.pageDestination(forTyped:pages:)`, and arrives here as an index.
    func goToPage(index: Int)
    /// Changes the Navigator's page selection, and shows the page that was clicked.
    func selectPage(id: PageDescriptor.ID, mode: PageSelectionMode)
    /// Dismisses a warning from the tray.
    func dismissWarning(id: AppWarning.ID)
}

extension DocumentPresenting {

    /// A presenter with no selection of its own selects whatever the canvas is showing.
    ///
    /// The honest default for a presenter that does not model a multi-selection: one page,
    /// the one on screen. A presenter that *does* model one overrides this, and the batch
    /// scope then sees what the person actually picked.
    public var selectedPageIDs: [PageDescriptor.ID] { currentPageID.map { [$0] } ?? [] }

    /// Without a selection model, every click is a plain navigation.
    public func selectPage(id: PageDescriptor.ID, mode: PageSelectionMode) { goToPage(id: id) }

    // MARK: - Page-relative navigation

    /// The zero-based index of the page on screen, or `nil` when no page is current.
    public var currentPageIndex: Int? {
        guard let currentPageID else { return nil }
        return pages.firstIndex { $0.id == currentPageID }
    }

    /// Whether there is a page after the current one. Drives menu-item enablement.
    public var canGoToNextPage: Bool {
        guard let index = currentPageIndex else { return !pages.isEmpty }
        return index + 1 < pages.count
    }

    /// Whether there is a page before the current one.
    public var canGoToPreviousPage: Bool {
        guard let index = currentPageIndex else { return false }
        return index > 0
    }

    /// Shows the next page. Does nothing at the end of the document — it does **not** wrap.
    ///
    /// Wrapping would mean a person holding the shortcut at the last sheet of a 300-page set
    /// silently arrives back at sheet 1, which reads as the application losing their place.
    public func goToNextPage() {
        guard let index = currentPageIndex else {
            if !pages.isEmpty { goToPage(index: 0) }
            return
        }
        goToPage(index: index + 1)
    }

    /// Shows the previous page. Does nothing at the start; see ``goToNextPage()``.
    public func goToPreviousPage() {
        guard let index = currentPageIndex else { return }
        goToPage(index: index - 1)
    }

    /// Shows the first page.
    public func goToFirstPage() { goToPage(index: 0) }

    /// Shows the last page.
    public func goToLastPage() { goToPage(index: pages.count - 1) }

    /// The pages the Navigator has selected, resolved to descriptors in document order.
    public var selectedPages: [PageDescriptor] {
        let selected = Set(selectedPageIDs)
        return pages.filter { selected.contains($0.id) }
    }

    /// The active document, resolved from ``activeTabID``.
    public var activeTab: DocumentTabSummary? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    /// The page the canvas is showing, resolved from ``currentPageID``.
    public var currentPage: PageDescriptor? {
        guard let currentPageID else { return nil }
        return pages.first { $0.id == currentPageID }
    }

    /// The Scale Regions that live on one page, in resolution order (highest priority first,
    /// ties by name — ``ScaleRegionSummary/inResolutionOrder(_:)``). The tie used to be left to
    /// the sort, so two regions of equal priority could swap places in the Inspector's popup.
    public func scaleRegions(onPage pageID: PageDescriptor.ID) -> [ScaleRegionSummary] {
        ScaleRegionSummary.inResolutionOrder(scaleRegions.filter { $0.pageID == pageID })
    }
}
