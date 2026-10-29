import Foundation
import Observation

/// Presents search across PDF text, OCR text, markups and custom fields.
@MainActor
public protocol SearchPresenting: ZenitPresenting {

    /// The query string. Settable so a text field can bind straight to it.
    var query: String { get set }
    /// The active scope.
    var scope: SearchScope { get set }
    /// Results in document then page order.
    var hits: [SearchHit] { get }
    /// The hit that is currently revealed on the canvas, or `nil`.
    var activeHitID: SearchHit.ID? { get }
    /// Whether a search is running, so the field can show a quiet progress state.
    var isSearching: Bool { get }
    /// A localized result count such as `"12 results"`, also used as the field's
    /// accessibility value.
    var resultSummary: String { get }
    /// Set when any result came from OCR, so the view can show the accuracy note.
    var showsOCRDisclaimer: Bool { get }

    /// Whether the search also queries the other drawings that are open.
    ///
    /// Off by default. A search that silently reached into thirty drawings would answer a
    /// question the estimator did not ask, and every extra hit would be one more row to rule
    /// out. Turning it on is a deliberate act with a visible control behind it.
    ///
    /// A presenter that cannot search anything but its own drawing inherits the default below
    /// and stays honestly stuck at `false`, so the control it drives reads the truth rather
    /// than a preference nothing acts on.
    var searchesAllDrawings: Bool { get set }

    /// Whether the index this presenter searches can be deleted from here, with the text
    /// recognised into it (the index can always be deleted and rebuilt). A presenter
    /// with no index of its own inherits `false`, and the Search options offer no control
    /// that would do nothing.
    var canDeleteIndex: Bool { get }

    /// Asks to delete the searched index and its recognised text. The owner of the index
    /// confirms with the person before anything is deleted (V-079).
    func requestIndexDeletion()

    /// Runs the search for the current ``query`` and ``scope``.
    func runSearch()
    /// Reveals one hit on the canvas.
    func selectHit(id: SearchHit.ID)
    /// Moves the active hit by `delta` positions, wrapping at the ends.
    func advance(by delta: Int)
    /// Clears the query and the results.
    func clear()
}

extension SearchPresenting {

    /// A presenter with nothing but its own drawing to search. Additive: every conformer
    /// written before project-wide search existed keeps compiling and keeps meaning what it
    /// meant. Setting it is a no-op rather than a trap — the control reads back `false` and
    /// says so.
    public var searchesAllDrawings: Bool {
        get { false }
        set { _ = newValue }
    }

    /// A presenter with no index of its own to delete. Additive, like ``searchesAllDrawings``.
    public var canDeleteIndex: Bool { false }

    /// Nothing to delete.
    public func requestIndexDeletion() {}

    /// One-based position of the active hit, or `nil` when nothing is revealed.
    public var activeHitPosition: Int? {
        guard let activeHitID, let index = hits.firstIndex(where: { $0.id == activeHitID }) else {
            return nil
        }
        return index + 1
    }
}
