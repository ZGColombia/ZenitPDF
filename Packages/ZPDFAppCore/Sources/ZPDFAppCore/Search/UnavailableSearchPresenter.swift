import Foundation
import Observation
import ZPDFUIPresentation

/// What the Search panel shows when this document has no index to search.
///
/// It exists so that the answer to "the index could not be opened" is a sentence saying so,
/// rather than either a fabricated result set or a bare "No results" — which would tell the
/// estimator that the word is not on the drawing when the truth is that nobody looked.
///
/// A drawing that is still being indexed is not this: that state is ``AppSearchPresenter``
/// reporting an empty index, which is honest because the index really is empty at that moment
/// and fills as pages are read.
@MainActor
@Observable
public final class UnavailableSearchPresenter: SearchPresenting {

    public var query: String = ""
    public var scope: SearchScope

    public private(set) var hits: [SearchHit] = []
    public private(set) var activeHitID: SearchHit.ID?
    public private(set) var isSearching: Bool = false
    public private(set) var showsOCRDisclaimer: Bool = false

    /// Why searching is not available, in one sentence the user can act on.
    public let reason: String

    /// - Parameter reason: the failure, already worded for a person. A default is supplied so a
    ///   caller with nothing better to say still says something true.
    public init(
        reason: String = NSLocalizedString(
            "Search is unavailable for this drawing: its text index could not be opened.",
            comment: "Search panel state when the index could not be opened"
        ),
        scope: SearchScope = SearchScope()
    ) {
        self.reason = reason
        self.scope = scope
    }

    public var resultSummary: String { reason }

    public func runSearch() {}
    public func selectHit(id: SearchHit.ID) {}
    public func advance(by delta: Int) {}
    public func clear() { query = "" }
}
