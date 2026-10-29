import Foundation
import ZPDFContracts
import ZPDFSearch
import ZPDFUIPresentation

/// Turns a batch sheet's search term into the set of pages that contain it.
///
/// ## Why this is a separate object
///
/// ``BatchApplyRequest/searchMatchedPageIDs`` is supplied by the caller rather than looked
/// up inside the planner, and that is the right shape: the planner runs on every keystroke
/// in the scope picker and must not be able to fail, hang or start an OCR run. But for as
/// long as nothing anywhere filled that field in, the scope was reachable and inert — the
/// sheet offered "Pages containing text", took a term, and placed nothing. This is the
/// thing that fills it in.
///
/// It is a value over the index's `SearchService`, so the whole resolution is testable
/// against a real FTS5 database without a window, a document or an `NSDocumentController`.
///
/// ## What "contains the term" means here
///
/// The drawing's own text layer and anything a recognition run added, and nothing else.
/// Markup subjects, labels and comments are deliberately excluded: "pages containing FIRE"
/// asked of a drawing set is a question about what the *sheets* say, and a scope that also
/// matched the estimator's own annotations would stamp the pages they had already worked
/// on. Recognised matches are included but flagged, because leaving them out would silently
/// miss every scanned sheet and folding them in silently would let a recogniser's guess
/// decide where a stamp goes.
///
/// ## Which drawings
///
/// Every drawing of the project's set (V-040): the primary drawing's index, and each added
/// drawing with a sheet in the set that ``init(service:projectID:documentID:identity:maximumHits:addedDrawings:)``
/// is given, each hit mapped through its own drawing's identity map. The other scopes — all
/// pages, a range, the Navigator selection — already cover the whole set, and a search scope
/// that asked the primary drawing alone left every added drawing's sheets out of the count
/// checked before placing hundreds of stamps, with nothing in the preview saying so.
///
/// An added drawing that cannot be asked is never dropped from the list: it comes as
/// ``Drawing/withoutIndex(title:)`` — its index failed to open — and the answer is unavailable,
/// naming it. So is a drawing whose text could not be read: a locked drawing reads as "not
/// permitted" on every page and indexes nothing, which would otherwise count as "no match".
public struct BatchSearchScopeResolver: Sendable {

    /// One drawing's index, as the resolver asks it — or a drawing of the set with no index to ask.
    public struct Drawing: Sendable {
        /// What the resolver asks.
        enum Source: Sendable {
            /// An open index.
            case index(Index)
            /// A drawing of the set whose index is not open.
            case notOpen
        }

        /// One open index's parts.
        struct Index: Sendable {
            /// The index to ask.
            let service: SearchService
            /// The project key the index was opened under.
            let projectID: String
            /// The document key, so the search stays inside this drawing.
            let documentID: String
            /// The map from the index's string keys back to the UI's page identities.
            let identity: SearchIdentityMap
            /// Waits until the drawing's own text layer is in the index, when that is still
            /// being read, and throws when it could not be read; `nil` for an index already filled.
            let settle: (@Sendable () async throws -> Void)?
        }

        let source: Source
        /// What the drawing is called, for the sentence that names it; `nil` for the primary.
        let title: String?

        /// A drawing over its index's parts.
        public init(
            service: SearchService,
            projectID: String,
            documentID: String,
            identity: SearchIdentityMap,
            title: String? = nil,
            settle: (@Sendable () async throws -> Void)? = nil
        ) {
            self.source = .index(Index(
                service: service, projectID: projectID, documentID: documentID, identity: identity, settle: settle
            ))
            self.title = title
        }

        /// An added drawing of the set: its index, its pages mapped under the project
        /// document's identity (as the Search panel maps them), and a settle that reads its text
        /// layer first — incremental, so an index already filled costs one hash comparison — and
        /// throws when a page could not be read, which is what a drawing opened without its
        /// password reports for every page.
        public init(
            index: DocumentSearchIndex,
            documentUUID: UUID,
            title: String,
            pages: [ZPDFContracts.PageDescriptor]
        ) {
            self.init(
                service: index.service,
                projectID: index.projectKey,
                documentID: index.documentKey,
                identity: index.identityMap(documentUUID: documentUUID, documentTitle: title, pages: pages, currentPageIndex: 0),
                title: title,
                settle: {
                    let report = try await index.indexDrawingText()
                    guard report.pagesNotPermitted.isEmpty else { throw UnreadableText() }
                }
            )
        }

        private init(withoutIndexTitled title: String) {
            self.source = .notOpen
            self.title = title
        }

        /// A drawing of the set with sheets in it whose text index is not open — its open
        /// failed. Never searched: it makes the answer unavailable, naming it, rather than
        /// leaving its sheets out of the count.
        public static func withoutIndex(title: String) -> Drawing {
            Drawing(withoutIndexTitled: title)
        }
    }

    /// A drawing whose text could not be read into its index.
    struct UnreadableText: Error {}

    /// The primary drawing.
    private let primary: Drawing
    /// The set's added drawings, asked at each resolution, since drawings join the set and
    /// their indexes open while the project is open.
    private let addedDrawings: @Sendable () async -> [Drawing]
    /// How many hits one resolution reads per drawing before it reports itself capped.
    ///
    /// One page can hold hundreds of matches, so a per-page question needs a much higher
    /// ceiling than a result list does; 2 000 is the package's own maximum. Reaching it is
    /// reported rather than hidden — see ``BatchSearchScopeResolution/wasTruncated``.
    private let maximumHits: Int

    /// Creates a resolver over the primary drawing's index and the set's added drawings.
    public init(
        service: SearchService,
        projectID: String,
        documentID: String,
        identity: SearchIdentityMap,
        maximumHits: Int = 2000,
        addedDrawings: @escaping @Sendable () async -> [Drawing] = { [] }
    ) {
        self.primary = Drawing(service: service, projectID: projectID, documentID: documentID, identity: identity)
        self.addedDrawings = addedDrawings
        self.maximumHits = max(1, maximumHits)
    }

    /// The pages whose text contains `term`, across every drawing of the set.
    ///
    /// Never throws: a preview that could fail is a preview the sheet has to render as
    /// something, and "the index could not answer" is a state this returns rather than an
    /// error the caller has to invent a sentence for. One drawing whose index cannot answer
    /// makes the whole answer unavailable: a count that silently left a drawing out is the
    /// wrong number this scope exists not to give.
    ///
    /// - Parameter term: exactly what the person typed. Trimmed here, and the trimmed form
    ///   is what the resolution reports, so a caller comparing terms compares like with
    ///   like.
    public func resolve(term: String) async -> BatchSearchScopeResolution {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return BatchSearchScopeResolution(term: trimmed) }

        let drawings = [primary] + (await addedDrawings())
        // A drawing with sheets in the set and no index to ask: no count at all, rather than a
        // count without its sheets (V-040).
        let unsearched = drawings.compactMap { drawing -> String? in
            if case .notOpen = drawing.source { return drawing.title ?? "" }
            return nil
        }
        if !unsearched.isEmpty {
            return .unavailable(term: trimmed, reason: Self.notSearchedReason(unsearched))
        }

        var pageIDs: Set<UUID> = []
        var truncated = false
        var recognised = false
        var dropped: [String] = []
        for drawing in drawings {
            guard case .index(let index) = drawing.source else { continue }
            do {
                try await index.settle?()
            } catch {
                return .unavailable(term: trimmed, reason: Self.unreadableReason(drawing.title))
            }
            let results: SearchResults
            do {
                results = try await index.service.search(request(trimmed, in: index))
            } catch {
                return .unavailable(
                    term: trimmed,
                    reason: NSLocalizedString(
                        "The text index could not be searched, so this scope cannot be previewed.",
                        comment: "Batch apply search scope, when the index query failed"
                    )
                )
            }
            for hit in results.hits {
                // A hit whose page is not in the identity map is dropped rather than pointed
                // at a page it is not on. The map is the app's own registration of this
                // drawing's pages, so this only happens for a stale index row.
                guard let mapped = index.identity.hit(hit) else { continue }
                pageIDs.insert(mapped.pageID)
                if hit.sourceType == .ocr { recognised = true }
            }
            truncated = truncated || results.wasTruncated
            // A `NOT` the index cannot run is left out of the query, not searched for
            // (U-081): `PLAN OR NOT DEMOLITION` counts the PLAN pages. The sheet says so
            // beside the count, the same way the Search panel does, or the count reads as if
            // DEMOLITION had been excluded from the pages about to be stamped. The query is
            // the same in every drawing, so the first answer's words stand for all.
            if dropped.isEmpty { dropped = results.query.droppedExclusions.map(\.sourceText) }
        }

        return BatchSearchScopeResolution(
            term: trimmed,
            pageIDs: pageIDs,
            wasTruncated: truncated,
            includesRecognisedText: recognised,
            droppedExclusions: dropped
        )
    }

    /// Why the scope cannot be previewed when drawings of the set have no index: each named.
    static func notSearchedReason(_ titles: [String]) -> String {
        // Joined plainly rather than through `ListFormatter`, which follows the system locale
        // and would put a Swedish "och" inside an English sentence.
        let named = titles.map { "“\($0)”" }
            .joined(separator: NSLocalizedString(", ", comment: "Batch apply search scope: between drawing names"))
        return String(
            format: titles.count == 1
                ? NSLocalizedString(
                    "The text of %@ could not be searched: its text index is not open. This scope cannot be previewed.",
                    comment: "Batch apply search scope, when an added drawing of the set has no text index; the drawing's name"
                )
                : NSLocalizedString(
                    "The text of %@ could not be searched: their text indexes are not open. This scope cannot be previewed.",
                    comment: "Batch apply search scope, when several added drawings have no text index; their names"
                ),
            named
        )
    }

    /// Why the scope cannot be previewed when a drawing's text could not be read into its index.
    static func unreadableReason(_ title: String?) -> String {
        guard let title else {
            return NSLocalizedString(
                "The drawing's text could not be read, so this scope cannot be previewed.",
                comment: "Batch apply search scope, when the drawing's text could not be indexed"
            )
        }
        return String(
            format: NSLocalizedString(
                "The text of “%@” could not be read, so this scope cannot be previewed.",
                comment: "Batch apply search scope, when an added drawing's text could not be indexed; the drawing's name"
            ),
            title
        )
    }

    /// The question asked of one drawing: its own text layer and recognised text, whole pages.
    private func request(_ text: String, in drawing: Drawing.Index) -> SearchRequest {
        SearchRequest(
            text: text,
            scope: .document(projectId: drawing.projectID, documentId: drawing.documentID),
            sources: [.pdfText, .ocr],
            // The sheet re-previews on every keystroke (`BatchApplySheet`'s
            // `onChange(of: searchTerm)`), so this is a find-as-you-type field and gets the
            // same preset the Search panel gets. It is also what keeps the promise made on
            // ``ZenitPDFProjectDocument/batchSearchScopeResolver`` — that the pages this
            // scope counts are the pages the panel would list. A preview that matched whole
            // tokens while the panel matched prefixes would disagree with the panel about
            // the same term, and the number the person checks before placing 312 stamps is
            // the last number that may disagree with anything.
            queryOptions: .findAsYouType,
            confidence: .standard,
            maximumHits: maximumHits,
            // The question is *which pages*, not *where on them*. Resolving highlight
            // rectangles would open the drawing once per hit to answer something the batch
            // sheet never shows.
            resolvesBounds: false
        )
    }
}
