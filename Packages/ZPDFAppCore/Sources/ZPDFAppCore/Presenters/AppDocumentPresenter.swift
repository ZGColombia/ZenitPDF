import Foundation
import Observation
import ZPDFContracts
import ZPDFUIPresentation

/// `DocumentPresenting` over a ``TakeoffSession``.
///
/// Deliberately independent of `NSDocument`: the presenter holds tab, page and zone state
/// as values and exposes closures for the two things only a document controller can decide
/// — whether closing a tab may discard unsaved work, and which document is frontmost. That
/// keeps every screen in this package testable without an `NSDocumentController`, and lets
/// the same presenter serve a document window, a detached ledger window and a preview.
@MainActor
@Observable
public final class AppDocumentPresenter: DocumentPresenting {

    public private(set) var tabs: [DocumentTabSummary] = []
    public private(set) var activeTabID: DocumentTabSummary.ID?
    public private(set) var pages: [ZPDFUIPresentation.PageDescriptor] = []

    /// The drawing's outline titles, by page identity, as the app read them from the PDF.
    ///
    /// The frozen page contract carries no outline, so the titles travel beside it and are laid
    /// onto every adopted snapshot's pages here: the page's own label when it is a name, then the outline entry
    /// (``PageDescriptor/resolvedSheetTitle(outlineTitle:label:)``). Setting it retitles the
    /// pages already adopted, so it may arrive after the first snapshot.
    public var sheetOutlineTitles: [UUID: String] = [:] {
        didSet { pages = Self.titled(pages, outline: sheetOutlineTitles) }
    }

    /// `pages` with each sheet title resolved against `outline`.
    static func titled(
        _ pages: [ZPDFUIPresentation.PageDescriptor],
        outline: [UUID: String]
    ) -> [ZPDFUIPresentation.PageDescriptor] {
        pages.map { page in
            page.withSheetTitle(ZPDFUIPresentation.PageDescriptor.resolvedSheetTitle(
                outlineTitle: outline[page.id],
                label: page.label
            ))
        }
    }
    public private(set) var currentPageID: ZPDFUIPresentation.PageDescriptor.ID?

    /// The Navigator's page selection, in document order.
    ///
    /// A real multi-selection, not a synonym for ``currentPageID``. The scoped batch
    /// apply's "Navigator selection" scope reads this, and while it read the current page
    /// instead the scope was a lie: it offered a choice, accepted it, and then stamped one
    /// sheet whatever the person had selected. Document order rather than click order,
    /// because every consumer presents it as pages of a drawing and "3, 1, 2" is not a
    /// thing a drawing set contains.
    public private(set) var selectedPageIDs: [ZPDFUIPresentation.PageDescriptor.ID] = []

    /// Where a Shift-click measures its range from.
    ///
    /// Held apart from the selection because Shift-click after Shift-click must extend
    /// from the *original* anchor rather than from the last page reached; without it,
    /// shift-clicking 5 then 9 then 7 leaves 7...9 selected instead of 5...7.
    private var selectionAnchorID: ZPDFUIPresentation.PageDescriptor.ID?
    public private(set) var zones: [ProjectZoneSummary] = []
    public private(set) var scaleRegions: [ScaleRegionSummary] = []
    /// The scale of the page that is current, or `nil` when that page has none.
    ///
    /// This was `defaultScale`, a document-wide field. On a set whose sheets differ it named
    /// the scale of exactly one of them and was wrong about the rest.
    public private(set) var currentPageScale: ScaleSummary?
    /// Every calibrated page's scale, keyed by page identity.
    public private(set) var pageScales: [UUID: ScaleSummary] = [:]

    /// `DocumentPresenting`'s spelling of ``currentPageScale``.
    ///
    /// The protocol lives in `ZPDFUIPresentation` and still calls this the *default* scale,
    /// which is the vocabulary of a document-wide scale that no longer exists. The value it
    /// serves is the current page's, which is what every view that reads it wanted all along —
    /// a status bar or an inspector is always looking at one sheet. The name is owed a rename in
    /// the presentation package; the behaviour is not owed anything.
    public var defaultScale: ScaleSummary? { currentPageScale }
    public private(set) var warnings: [AppWarning] = []

    /// Asked before a tab closes. Returning `false` leaves the tab open, which is how
    /// "do not discard unsaved work without asking" is enforced at this layer rather than
    /// being remembered at every call site.
    public var shouldCloseTab: (@MainActor (DocumentTabSummary) -> Bool)?

    /// Called after the current page changed, so the canvas can follow.
    public var onPageChange: (@MainActor (ZPDFUIPresentation.PageDescriptor) -> Void)?

    /// Called whenever the warning list changes, so the status bar's tray mirrors it.
    ///
    /// The tray reads `StatusPresenting.warnings`; warnings are *posted* here. Without
    /// this callback the two lists were never connected and a posted warning was raised
    /// into a list nothing rendered — which is why the swallowed measurement error had
    /// nowhere to appear even once it stopped being swallowed.
    public var onWarningsChange: (@MainActor ([AppWarning]) -> Void)?

    /// NL-UX-20: the presenter that owns the warning tray when this one is a second window's view
    /// of the same document. Posts and dismissals go there, and its list comes back through
    /// ``mirrorWarnings(_:)``, so both windows show one tray. `nil` for the document's own.
    @ObservationIgnored public weak var warningAuthority: AppDocumentPresenter?

    private let session: TakeoffSession

    /// Creates a presenter over a session.
    public init(session: TakeoffSession) {
        self.session = session
    }

    // MARK: Snapshot intake

    /// Adopts a document snapshot. The current page survives if it still exists, so a
    /// page reorder does not throw the user back to page one.
    public func adopt(_ snapshot: DocumentSnapshot) {
        // Whether this is the drawing arriving, or a refresh of one already open. It decides
        // whether an empty selection is a fresh start or a deliberate one — see below.
        let isFirstAdoption = pages.isEmpty
        let previousPageID = currentPageID
        pages = Self.titled(snapshot.pages, outline: sheetOutlineTitles)
        pageScales = snapshot.pageScales
        // Regions and zones arrive on the same snapshot as the markups they classify, so a
        // panel can never show a region the ledger row beside it has not heard of.
        scaleRegions = snapshot.scaleRegions
        zones = snapshot.zones
        if let currentPageID, pages.contains(where: { $0.id == currentPageID }) {
            // Keep it.
        } else {
            currentPageID = pages.first?.id
        }
        // After the current page is settled, never before: the scale shown is the scale of the
        // page that ended up current.
        currentPageScale = snapshot.scale(onPage: currentPageID)
        // A page that was deleted cannot stay selected: a batch scope holding the id of a
        // page that no longer exists would resolve to fewer pages than the count it was
        // previewed with. Pruning here keeps the selection a subset of the document at all
        // times, and re-sorting keeps it in document order across a reorder.
        pruneSelection()
        // An opened drawing starts with its first page selected, so the page the Navigator
        // highlights and the page a batch scope reads are the same page. Only on the first
        // adoption: every edit refreshes the snapshot, and re-seeding here would undo a
        // deselection the person made on purpose the moment they drew anything.
        if isFirstAdoption, selectedPageIDs.isEmpty, let currentPageID {
            selectedPageIDs = [currentPageID]
            selectionAnchorID = currentPageID
        }
        // The sheet on screen left the set (removed, or an insert undone): the fallback is a page
        // change like any other. Without it the markup tools stayed pinned to the removed sheet,
        // so the next cloud or text landed on a page outside the set, and the palette kept that
        // sheet's scale (R-049).
        if let previousPageID, previousPageID != currentPageID,
           let page = pages.first(where: { $0.id == currentPageID }) {
            onPageChange?(page)
        }
    }

    /// Drops selected pages the snapshot no longer has, and restores document order.
    private func pruneSelection() {
        let live = Set(pages.map(\.id))
        let selected = Set(selectedPageIDs).intersection(live)
        selectedPageIDs = pages.map(\.id).filter { selected.contains($0) }
        if let selectionAnchorID, !live.contains(selectionAnchorID) {
            self.selectionAnchorID = selectedPageIDs.last
        }
    }

    /// Installs the open documents and which one is frontmost.
    public func setTabs(_ tabs: [DocumentTabSummary], active: DocumentTabSummary.ID?) {
        self.tabs = tabs
        activeTabID = active ?? tabs.first?.id
    }

    /// Adds a warning to the tray, replacing any warning with the same identity.
    public func post(_ warning: AppWarning) {
        if let warningAuthority {
            warningAuthority.post(warning)
            return
        }
        warnings.removeAll { $0.id == warning.id }
        warnings.append(warning)
        warnings.sort { $0.severity > $1.severity }
        onWarningsChange?(warnings)
    }

    // MARK: DocumentPresenting

    public func selectTab(_ id: DocumentTabSummary.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        for index in tabs.indices { tabs[index].isActive = tabs[index].id == id }
    }

    public func closeTab(_ id: DocumentTabSummary.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.hasUnsavedChanges, shouldCloseTab?(tab) == false { return }
        tabs.remove(at: index)
        if activeTabID == id { activeTabID = tabs.first?.id }
    }

    /// Navigates to a page, which is also a plain selection of it.
    ///
    /// Everything that moves the canvas by page identity — the page field, a search hit, a
    /// menu command — arrives here, and after any of them the Navigator shows one page
    /// selected. That is the behaviour a person expects and, more to the point, it means a
    /// "Navigator selection" batch scope can never be stale relative to what the sidebar
    /// is highlighting.
    public func goToPage(id: ZPDFUIPresentation.PageDescriptor.ID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        currentPageID = id
        currentPageScale = pageScales[id]
        selectedPageIDs = [id]
        selectionAnchorID = id
        onPageChange?(page)
    }

    /// Changes the Navigator's page selection (``PageSelectionMode``), and shows the page
    /// that was clicked.
    ///
    /// The three modes are the platform's, and each one has a failure this implementation
    /// avoids:
    ///
    /// * `.replace` — a plain click. Selection becomes this page, anchor becomes this page.
    /// * `.toggle` — Command-click. Removing the last selected page leaves an *empty*
    ///   selection rather than silently keeping one, because "I deselected everything" and
    ///   "one page is selected" are different states and the batch scope treats them
    ///   differently.
    /// * `.extend` — Shift-click. The range runs from the anchor, so repeated Shift-clicks
    ///   grow and shrink one range instead of walking away from where the person started.
    ///
    /// The canvas follows the clicked page in every mode: Command-clicking a thumbnail to
    /// add it to a batch and not being shown it would be a click with no visible result.
    public func selectPage(id: ZPDFUIPresentation.PageDescriptor.ID, mode: PageSelectionMode) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        switch mode {
        case .replace:
            selectedPageIDs = [id]
            selectionAnchorID = id
        case .toggle:
            if selectedPageIDs.contains(id) {
                selectedPageIDs.removeAll { $0 == id }
                // The anchor cannot point at a page that is no longer in the selection, or
                // the next Shift-click would extend from somewhere the person cannot see.
                selectionAnchorID = selectedPageIDs.last
            } else {
                selectedPageIDs.append(id)
                selectionAnchorID = id
            }
            pruneSelection()
        case .extend:
            let anchor = selectionAnchorID ?? currentPageID
            guard let anchor,
                  let start = pages.firstIndex(where: { $0.id == anchor }),
                  let end = pages.firstIndex(where: { $0.id == id })
            else {
                selectedPageIDs = [id]
                selectionAnchorID = id
                break
            }
            selectedPageIDs = pages[min(start, end)...max(start, end)].map(\.id)
            // The anchor deliberately survives an extend.
        }
        currentPageID = id
        currentPageScale = pageScales[id]
        onPageChange?(page)
    }

    public func goToPage(index: Int) {
        guard pages.indices.contains(index) else { return }
        goToPage(id: pages[index].id)
    }

    public func dismissWarning(id: AppWarning.ID) {
        if let warningAuthority {
            warningAuthority.dismissWarning(id: id)
            return
        }
        let before = warnings.count
        warnings.removeAll { $0.id == id && $0.isDismissible }
        // Only a real removal is news. Every successful refresh dismisses the refresh-failure
        // warning, and announcing an unchanged list on each one re-pushed the whole tray (S-029).
        guard warnings.count != before else { return }
        onWarningsChange?(warnings)
    }

    /// Removes every dismissible warning: the tray's "Dismiss All", routed here so it lasts (S-029).
    public func dismissAllWarnings() {
        if let warningAuthority {
            warningAuthority.dismissAllWarnings()
            return
        }
        let before = warnings.count
        warnings.removeAll(where: \.isDismissible)
        guard warnings.count != before else { return }
        onWarningsChange?(warnings)
    }

    /// NL-UX-20: takes the ``warningAuthority``'s list as this presenter's own, without posting
    /// anything back to it.
    public func mirrorWarnings(_ warnings: [AppWarning]) {
        self.warnings = warnings
        onWarningsChange?(warnings)
    }
}
