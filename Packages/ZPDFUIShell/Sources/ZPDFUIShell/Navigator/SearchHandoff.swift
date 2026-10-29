import Foundation
import ZPDFUIPresentation

/// Carries a search from one drawing into another when a hit opens the other drawing (L-91).
///
/// Every drawing has its own search presenter, and the Navigator's Search page reads the one of
/// the drawing in front. Live test 8: a hit in another drawing, from an All Drawings search,
/// switched to that drawing and highlighted the word — and the Search page there was empty and
/// back on This Drawing, so the next hit could not be reached without typing the search again.
/// The search now goes with the person: the drawing they land in takes the query, the scope and
/// the reach, runs it, and makes the hit they opened its active one, so ▲ ▼ go on from there.
@MainActor
public enum ZPDFSearchHandoff {

    /// How long the destination may take to answer before the hand-off stops waiting for the
    /// opened hit to appear in its list. The query, scope and reach are handed over at once
    /// either way.
    public static let resultWait: Duration = .seconds(10)

    /// Hands `source`'s search to `destination`, which has just opened `hit`.
    ///
    /// - Returns: the task that waits for the destination's results and selects the opened hit
    ///   in them, so a caller — or a test — can await it. `nil` when there is nothing to hand
    ///   over (the same presenter, or an empty query).
    @discardableResult
    public static func continueSearch(
        from source: any SearchPresenting,
        into destination: any SearchPresenting,
        at hit: SearchHit,
        wait: Duration = resultWait
    ) -> Task<Bool, Never>? {
        guard source !== destination else { return nil }
        let query = source.query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Reach before query: a presenter re-runs on each change, and the run that counts is the
        // one with everything set.
        destination.searchesAllDrawings = source.searchesAllDrawings
        destination.scope = source.scope
        if destination.query == query {
            destination.runSearch()
        } else {
            destination.query = query
        }
        return Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now + wait
            while clock.now < deadline {
                if !destination.isSearching, let match = destination.hits.first(where: { isSameFind($0, as: hit) }) {
                    if destination.activeHitID != match.id { destination.selectHit(id: match.id) }
                    return true
                }
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return false }
            }
            return false
        }
    }

    /// Whether `candidate`, in the destination's own list, is the find `hit` named from the
    /// other drawing's list: the same page, the same words in the same place, the same markup.
    /// The identifiers differ — each presenter numbers its own results — and a hit listed from
    /// another drawing carries no rectangle (R-153), so neither can be compared.
    static func isSameFind(_ candidate: SearchHit, as hit: SearchHit) -> Bool {
        candidate.pageID == hit.pageID
            && candidate.snippet == hit.snippet
            && candidate.highlightRange == hit.highlightRange
            && candidate.markupID == hit.markupID
            && candidate.source == hit.source
    }
}
