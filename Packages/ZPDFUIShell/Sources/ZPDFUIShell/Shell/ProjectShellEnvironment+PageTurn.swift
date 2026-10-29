import Foundation
import ZPDFUIPresentation

/// One way to turn the page from anywhere in the shell.
///
/// Before this existed only the four menu commands (`perform(.nextPage)` and its siblings)
/// called ``ProjectShellEnvironment/pageDidChange()`` after moving the document. Every other
/// control that turns a page — a Navigator thumbnail, a search hit, the status bar's page field —
/// called the document presenter directly, so the canvas moved and the page-scoped panels did
/// not: the Scale Regions panel kept listing the previous sheet's regions and kept a boundary
/// drawn on that sheet armed over the new one (BH-296, the CR-179 shape; the status bar's twin
/// is BH-299).
///
/// The application tier's `onPageChange` wiring reaches the canvas, the measurement presenter and
/// the status bar, never the shell's own page-scoped models, and nothing on a page turn raises
/// the core's `onDidRefresh`. So the shell has to say it itself, on every path — which is only
/// dependable if every path goes through here.
extension ProjectShellEnvironment {

    /// Selects a page the way a Navigator thumbnail click does, then refreshes page-scoped state.
    public func selectPage(id: PageDescriptor.ID, mode: PageSelectionMode) {
        turningPage { document.selectPage(id: id, mode: mode) }
    }

    /// Shows the page with this identity, then refreshes page-scoped state.
    public func goToPage(id: PageDescriptor.ID) {
        turningPage { document.goToPage(id: id) }
    }

    /// Shows the page at this zero-based index, then refreshes page-scoped state.
    public func goToPage(index: Int) {
        turningPage { document.goToPage(index: index) }
    }

    /// Runs anything that may move the document to another page — revealing a search hit,
    /// following a link — and then refreshes every page-scoped panel.
    ///
    /// ``pageDidChange()`` is idempotent (the Scale Regions panel discards nothing when the page
    /// has not moved), so it is always called: a caller that cannot know in advance whether its
    /// action turns the page does not have to guess.
    public func turningPage(_ turn: () -> Void) {
        turn()
        pageDidChange()
    }

    /// Pages the canvas to a markup and zooms to it — selecting it first unless the caller has
    /// already selected it — then refreshes page-scoped state (R-078).
    ///
    /// `zoomTo(markupID:)` turns to the markup's sheet when it lies on another one, and that turn
    /// raised no ``pageDidChange()``: Reveal from History, the Review List and the ledger's row
    /// menu left the Scale Regions panel on the previous sheet (the BH-296 / CR-179 shape).
    public func reveal(markupID: UUID, selecting: Bool = true) {
        turningPage {
            if selecting { canvas.select(markupIDs: [markupID], additive: false) }
            canvas.zoomTo(markupID: markupID)
        }
    }

    /// Fits the whole selection, on whichever sheet it lies, then refreshes page-scoped state
    /// (S-045). `perform(.zoomToSelection)` — the View menu's `⌘*`, the palette, the Inspector
    /// and the ledger's multi-row Zoom To — all come here.
    ///
    /// The application's fit covers the selected markups *of the sheet on screen* — the canvas
    /// holds only that sheet's markups — so rows chosen in the ledger, or an Inspector
    /// selection, that lay on another sheet did nothing at all. This turns first:
    /// - a selection on the sheet on screen (or none the shell can place) is fitted where it is;
    /// - a selection on one other sheet turns to that sheet, then fits;
    /// - a selection over several sheets fits its part on the sheet on screen when there is
    ///   one, otherwise turns to the first of its sheets in set order
    ///   (``selectionPlacement(of:)`` says which, so a control can say so).
    public func zoomToSelection() {
        switch selectionPlacement(of: canvas.resolvedSelectedMarkups) {
        case .none, .currentSheet:
            // Nothing to turn to: the canvas fits what it has selected (with nothing selected it
            // does nothing, and the menu item is disabled then).
            externalCommandHandler?(.zoomToSelection)
        case .otherSheet(let target), .severalSheets(_, let target):
            turningPage {
                if target != document.currentPageID { document.goToPage(id: target) }
                externalCommandHandler?(.zoomToSelection)
            }
        }
    }

    /// Where a set of markups lies, sheet by sheet, and which sheet a Zoom to Selection lands on.
    public func selectionPlacement(of markups: [MarkupSummary]) -> SelectionPlacement {
        let pages = Set(markups.map(\.pageID))
        guard !pages.isEmpty else { return .none }
        let current = document.currentPageID
        if pages.count == 1, let only = pages.first {
            return only == current ? .currentSheet : .otherSheet(only)
        }
        if let current, pages.contains(current) {
            return .severalSheets(count: pages.count, target: current)
        }
        let first = document.pages.first { pages.contains($0.id) }?.id
            ?? markups.first?.pageID
        return first.map { .severalSheets(count: pages.count, target: $0) } ?? .none
    }

    /// Reveals the next (`+1`) or previous (`-1`) search hit, wrapping at the ends, and
    /// refreshes page-scoped state — a hit is often on another page (IM-129).
    ///
    /// The one entry point for stepping through results: the Search page's Previous/Next
    /// buttons call it today, and a Find Next / Find Previous command should call it too.
    public func advanceSearch(by delta: Int) {
        turningPage { search.advance(by: delta) }
    }
}

/// Where a selection lies, sheet by sheet (S-045).
public enum SelectionPlacement: Equatable, Sendable {
    /// Nothing is selected.
    case none
    /// Every selected markup is on the sheet on screen.
    case currentSheet
    /// Every selected markup is on one other sheet.
    case otherSheet(PageDescriptor.ID)
    /// The selection spans several sheets; a Zoom to Selection fits its part on `target`.
    case severalSheets(count: Int, target: PageDescriptor.ID)
}
