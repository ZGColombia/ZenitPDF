import Foundation

/// One *other* open drawing, offered to a search presenter as something it may also query.
///
/// Every open drawing carries its own text index, keyed by that drawing's own bytes. There is
/// no single index spanning the open set, and building one would mean re-indexing thirty
/// drawings into a shared database every time the open set changed. So a project-wide search
/// is a **fan-out**: the active document searches its own index, and asks each of these for the
/// same query — the same text *and* the same matching rules (``ProjectSearchOptions``). A source
/// that heard only the text answered Match Case and Whole Word questions case-folded and by
/// prefix, so the other drawings listed every `room` under a Match Case `ROOM` (W-081).
///
/// The source is a closure rather than a protocol on purpose. What sits behind it — another
/// document's presenter, a cached result set, a stub in a test — is nobody's business here, and
/// the seam has to be fillable by the app tier without the presentation tier learning what a
/// `DocumentSearchIndex` is.
///
/// The closure is `@MainActor`, which makes the function type implicitly `Sendable`, so the
/// value crosses no isolation boundary it should not.
public struct ProjectSearchSource: Identifiable, Sendable {

    /// The document this source searches. Also the source's identity, because one document
    /// contributing twice would double every hit it produced.
    public let documentID: UUID

    /// What the drawing is called, shown on every hit it produces.
    ///
    /// Denormalised here rather than looked up later: a result row that outlives the drawing
    /// being closed must still be able to say where it came from.
    public let title: String

    /// Runs the query against that drawing, under the asking panel's matching rules, and
    /// returns whatever it found.
    ///
    /// The options are a parameter, not something the answering drawing looks up: they are the
    /// *asker's* toggles. The answering drawing's own Search panel may say anything at all, and
    /// reading it would let one drawing's checkboxes silently change another drawing's search.
    ///
    /// The implementation is free to be slow — a drawing whose index is still filling, or one
    /// that has to wait on a database — and callers are required not to let it hold up the
    /// hits the active document already produced.
    public let search: @MainActor (String, ProjectSearchOptions) async -> [SearchHit]

    /// Creates a source.
    public init(
        documentID: UUID,
        title: String,
        search: @escaping @MainActor (String, ProjectSearchOptions) async -> [SearchHit]
    ) {
        self.documentID = documentID
        self.title = title
        self.search = search
    }

    /// Stable identity for a list.
    public var id: UUID { documentID }

    /// Runs the query and stamps every hit with the drawing it came from.
    ///
    /// The stamping happens here, once, rather than at each call site: a hit from another
    /// drawing that reached the results list unlabelled would read as a hit on the drawing the
    /// user is looking at, and clicking it would appear to point at a page that does not
    /// contain the word. Labelling is the whole safety property of this seam.
    @MainActor
    public func labelledHits(for text: String, options: ProjectSearchOptions) async -> [SearchHit] {
        await search(text, options).map { hit in
            var labelled = hit
            labelled.sourceDocumentID = documentID
            labelled.sourceDocumentTitle = title
            return labelled
        }
    }
}

/// The matching rules a project-wide fan-out carries from the asking panel to every other drawing.
///
/// Only the rules that decide *whether a word matches*. Where the asker searches (location) and
/// which bodies of text (sources) stay with the asker: every other drawing answers project-wide,
/// and the asker filters what comes back. Match Case and Whole Word cannot be filtered afterwards
/// — a case-folded answer has already lost the case — so they travel with the query.
public struct ProjectSearchOptions: Hashable, Sendable {

    /// Whether case must match.
    public var isCaseSensitive: Bool
    /// Whether only whole words match — no find-as-you-type prefix on the last word.
    public var isWholeWord: Bool

    /// Creates options. The defaults are the panel's: case-folded, find-as-you-type.
    public init(isCaseSensitive: Bool = false, isWholeWord: Bool = false) {
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
    }

    /// The matching rules of a panel's scope.
    public init(scope: SearchScope) {
        self.init(isCaseSensitive: scope.isCaseSensitive, isWholeWord: scope.isWholeWord)
    }
}
