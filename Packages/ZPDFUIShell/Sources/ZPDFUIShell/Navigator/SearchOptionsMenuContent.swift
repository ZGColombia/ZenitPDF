import SwiftUI
import ZPDFUIPresentation

/// Editing a search scope: the one rule both search surfaces follow (R-085).
enum SearchScopeEditing {

    /// The scope with one source ticked or unticked — never down to no source at all: a scope
    /// with no source searches nothing.
    static func scope(_ scope: SearchScope, togglingSource source: SearchSource) -> SearchScope {
        var next = scope
        if next.sources.contains(source) {
            guard next.sources.count > 1 else { return scope }
            next.sources.remove(source)
        } else {
            next.sources.insert(source)
        }
        return next
    }
}

/// The items of a Search Options menu — Look In, Match Case, Whole Words and, where the surface
/// offers it, Search All Open Drawings — over the presenter's own scope.
///
/// Every item changes the query that runs (W-081). Match Case reaches the engine as a
/// case-sensitive query. The menu used to offer a Regular Expression toggle as well, and
/// nothing read it — the index has no regular-expression search, so a pattern was split into
/// plain words — so it was removed rather than left looking like a filter.
///
/// R-085: the Navigator's Search page and the canvas bar each built this menu, and each kept its
/// own copy of the scope toggle, so the two could drift. Both draw this now; each keeps its own
/// button face.
struct SearchOptionsMenuContent: View {

    let search: any SearchPresenting
    /// Whether the menu carries the reach toggle. The canvas bar offers it once a second drawing
    /// is open; the Navigator has its own This Drawing | All Drawings control instead.
    var offersAllDrawings = false

    var body: some View {
        Section(NSLocalizedString("Look In", comment: "Search options: section of text sources")) {
            ForEach(SearchSource.allCases) { source in
                Toggle(source.displayName, isOn: Binding(
                    get: { search.scope.sources.contains(source) },
                    set: { _ in search.scope = SearchScopeEditing.scope(search.scope, togglingSource: source) }
                ))
                // A scope with no source searches nothing; the last one cannot be unticked.
                .disabled(search.scope.sources == [source])
            }
        }
        Divider()
        Toggle(
            NSLocalizedString("Match Case", comment: "Search option"),
            isOn: Binding(get: { search.scope.isCaseSensitive }, set: { search.scope.isCaseSensitive = $0 })
        )
        Toggle(
            NSLocalizedString("Whole Words", comment: "Search option"),
            isOn: Binding(get: { search.scope.isWholeWord }, set: { search.scope.isWholeWord = $0 })
        )
        if offersAllDrawings {
            Divider()
            Toggle(
                NSLocalizedString("Search All Open Drawings", comment: "Search option: reach every open drawing"),
                isOn: Binding(get: { search.searchesAllDrawings }, set: { search.searchesAllDrawings = $0 })
            )
        }
        // The index can always be deleted and rebuilt (V-079). Offered only where
        // there is an index to delete; the document confirms before anything goes.
        if search.canDeleteIndex {
            Divider()
            Button(Self.deleteIndexTitle) { search.requestIndexDeletion() }
                .help(Self.deleteIndexHelp)
        }
    }

    static let deleteIndexTitle = NSLocalizedString(
        "Delete Search Index and Recognised Text…",
        comment: "Search options: delete this drawing's search index and the text recognised on its scanned sheets"
    )
    static let deleteIndexHelp = NSLocalizedString(
        "Removes the words read from this project's drawings and scanned sheets from this Mac. The drawings' own text and the markups are indexed again.",
        comment: "Search options: tool tip of Delete Search Index and Recognised Text"
    )
}
