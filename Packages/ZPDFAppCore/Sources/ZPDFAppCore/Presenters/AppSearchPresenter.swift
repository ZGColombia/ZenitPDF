import CoreGraphics
import Foundation
import Observation
import ZPDFSearch
import ZPDFUIPresentation

/// `SearchPresenting` over `ZPDFSearch`.
///
/// Two vocabularies meet here. `ZPDFSearch` speaks in string project, document and page
/// identifiers and returns `CGRect` bounds; the UI speaks in `UUID`s and page-space
/// rectangles. The mapping goes through ``SearchIdentityMap`` rather than through string
/// parsing, because a `UUID(uuidString:)` that fails silently turns a real hit into a hit
/// on nothing.
@MainActor
@Observable
public final class AppSearchPresenter: SearchPresenting {

    // MARK: Published state

    public var query: String = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    public var scope: ZPDFUIPresentation.SearchScope {
        didSet { if scope != oldValue { scheduleSearch() } }
    }

    public private(set) var hits: [ZPDFUIPresentation.SearchHit] = []
    public private(set) var activeHitID: ZPDFUIPresentation.SearchHit.ID?
    /// Whether ``activeHitID`` is a hit the person picked (a click or the stepper) rather than
    /// the default "first hit". Only a picked hit survives a republish; a default follows the
    /// ordering, so another drawing that answers before this one cannot keep the active hit once
    /// this drawing's own hits arrive and sort in front of it.
    private var activeHitIsPersonsChoice = false
    public private(set) var isSearching: Bool = false
    public private(set) var showsOCRDisclaimer: Bool = false

    /// Whether the search also queries ``externalSources``.
    ///
    /// Off by default, and re-runs the query when it changes: a person who ticks "All
    /// Drawings" while looking at a result set is asking for that result set to widen, not for
    /// the next query to be wider.
    public var searchesAllDrawings: Bool = false {
        didSet { if searchesAllDrawings != oldValue { scheduleSearch() } }
    }

    /// The other open drawings this presenter may also query.
    ///
    /// Filled by the app tier, which is the only layer that knows what else is open. Empty
    /// here, always: a presenter that invented its own sources would be searching drawings the
    /// window has no idea are being searched.
    ///
    /// Changing the set while ``searchesAllDrawings`` is on re-runs the query, so closing a
    /// drawing drops its hits rather than leaving them on screen pointing at nothing.
    public var externalSources: [ZPDFUIPresentation.ProjectSearchSource] = [] {
        didSet {
            guard searchesAllDrawings else { return }
            guard externalSources.map(\.id) != oldValue.map(\.id) else { return }
            scheduleSearch()
        }
    }

    /// `"12 results"`, or a truncation note when the engine capped the result set.
    ///
    /// Truncation is stated rather than hidden: a user who searches a 1 000-sheet set and
    /// gets exactly 500 hits must know the 501st exists (QUALITY_BAR A23).
    public private(set) var resultSummary: String = ""

    /// Called when a hit is revealed, so the canvas can scroll to it.
    public var onReveal: (@MainActor (ZPDFUIPresentation.SearchHit) -> Void)?

    /// Called when the person asks, from the Search options, to delete the index and its
    /// recognised text (V-079). The document that owns the index confirms, deletes and
    /// re-indexes; `nil` offers no such control.
    public var onRequestIndexDeletion: (@MainActor () -> Void)?

    public var canDeleteIndex: Bool { onRequestIndexDeletion != nil }

    public func requestIndexDeletion() { onRequestIndexDeletion?() }

    // MARK: Private state

    private let service: SearchService
    private let projectID: String
    private var identity: SearchIdentityMap
    private var searchTask: Task<Void, Never>?

    /// Hits from this drawing's own index, kept apart from the ones other drawings sent.
    ///
    /// Two stores rather than one because the two arrive independently and in either order. A
    /// single `hits` array assigned by whichever finished last would let a fast external source
    /// erase the active document's results, or a slow one erase them 200 ms after they landed
    /// — the failure this split exists to make unrepresentable. ``hits`` is always
    /// `own + external`, rebuilt whenever either half changes.
    private var ownHits: [ZPDFUIPresentation.SearchHit] = []
    /// The engine hit behind each of this drawing's UI hits, and the query they answered, so a
    /// hit's rectangles can be resolved when it is revealed rather than for every hit up front
    /// (IM-085).
    private var engineHits: [UUID: ZPDFSearch.SearchHit] = [:]
    private var engineQuery: SearchQuery?
    /// How many of the first results get their rectangles resolved as soon as the list lands.
    static let eagerBoundsCount = 30

    /// The engine hit and query behind each hit this drawing gave another drawing's fan-out,
    /// by UI hit id, so the one the person reveals is located then (R-153). The fan-out lists
    /// without rectangles: resolving them up front cost one PDFKit page search per text hit —
    /// up to sixteen for a find-as-you-type prefix — on every other open drawing, per keystroke.
    private var answeredEngineHits: [UUID: (hit: ZPDFSearch.SearchHit, query: SearchQuery)] = [:]
    /// Most answered hits remembered before the memory starts over. Two fan-outs' worth at
    /// the engine's default cap.
    static let answeredHitMemory = 1_000

    /// Hits other drawings returned, in completion order, already labelled with their drawing.
    private var externalHits: [ZPDFUIPresentation.SearchHit] = []

    /// Whether this drawing's own engine capped its result set, remembered so that appending a
    /// external hit does not quietly drop the truncation note.
    private var ownResultsWereTruncated: Bool = false

    /// One fan-out per source, so a slow drawing delays only its own results.
    private var externalTasks: [Task<Void, Never>] = []

    /// Which run of the query the results being applied belong to. A reply from a cancelled
    /// run carries a stale generation and is discarded rather than appended to the new one.
    private var generation: UInt64 = 0
    /// The query text ``ownHits`` answers, so a re-run for the same word keeps them standing.
    private var ownHitsText: String?

    /// Debounce before a keystroke becomes a query.
    public var debounce: Duration = .milliseconds(300)

    /// The running search, so the UI can show and cancel it.
    public private(set) var operation: OperationHandle?

    /// Creates a presenter over a search service.
    public init(
        service: SearchService,
        projectID: String,
        identity: SearchIdentityMap = SearchIdentityMap(),
        scope: ZPDFUIPresentation.SearchScope = SearchScope()
    ) {
        self.service = service
        self.projectID = projectID
        self.identity = identity
        self.scope = scope
    }

    /// The sheet on screen, by page identity, or `nil` before the first page change.
    public private(set) var currentPageID: UUID?

    /// The window whose sheet "Current Page" means, when several windows show one document and
    /// share this presenter (NL-UX-20). Set by ``AppCoreEnvironment/takeSearchFocus()``; `nil`
    /// means whichever window turns a page — the one-window case. Without it a page turned in
    /// window 2 re-pointed a Current Page search typed in window 1 (S-033).
    @ObservationIgnored weak var currentPageOwner: AnyObject?

    /// Follows the sheet on screen, so the "Current Page" scope means it (R-048). Before this the
    /// scope's page key was fixed at `currentPageIndex: 0` when the presenter was made, and
    /// nothing moved it, so "Current Page" always searched the first page of the PDF.
    ///
    /// A sheet of another drawing of the set has no key in this drawing's index: the own query
    /// then answers nothing, and only that drawing's results for that sheet are listed.
    public func setCurrentPage(_ pageID: UUID) {
        currentPageID = pageID
        identity.currentPageKey = identity.pageKey(forPageID: pageID)
    }

    // MARK: SearchPresenting

    public func runSearch() {
        searchTask?.cancel()
        performSearch()
    }

    public func selectHit(id: ZPDFUIPresentation.SearchHit.ID) {
        guard let hit = hits.first(where: { $0.id == id }) else { return }
        activeHitID = id
        activeHitIsPersonsChoice = true
        // A hit listed without rectangles gets them now, then reveals — one engine page
        // search for the hit the person asked for, instead of one per hit before the list
        // appeared (IM-085).
        guard hit.boundsInPageSpace == nil, let engineHit = engineHits[id], let query = engineQuery else {
            onReveal?(hit)
            return
        }
        let generation = self.generation
        let service = self.service
        Task { [weak self] in
            let bounds = try? await service.bounds(for: engineHit, query: query)
            await MainActor.run {
                guard let self, generation == self.generation else { return }
                let resolved = bounds.map { self.install(bounds: $0, forHit: id) } ?? hit
                guard self.activeHitID == id else { return }
                self.onReveal?(resolved ?? hit)
            }
        }
    }

    /// Writes resolved rectangles into one of this drawing's hits, keeping its identity.
    @discardableResult
    private func install(bounds: SearchHitBounds, forHit id: UUID) -> ZPDFUIPresentation.SearchHit? {
        guard let index = ownHits.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = ownHits[index]
        updated.boundsInPageSpace = bounds.rects.first.map {
            PDFRectValue(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height)
        }
        ownHits[index] = updated
        engineHits.removeValue(forKey: id)
        republish()
        return updated
    }

    /// Resolves the rectangles of the first results in one batched call, so the rows a person
    /// sees first carry their highlight without every hit paying for one.
    private func resolveLeadingBounds(generation: UInt64) {
        guard let query = engineQuery else { return }
        let leading = ownHits.prefix(Self.eagerBoundsCount).compactMap { hit in
            engineHits[hit.id].map { (hit.id, $0) }
        }
        guard !leading.isEmpty else { return }
        let service = self.service
        Task { [weak self] in
            guard let bounds = try? await service.bounds(for: leading.map(\.1), query: query) else { return }
            await MainActor.run {
                guard let self, generation == self.generation else { return }
                for (pair, resolved) in zip(leading, bounds) { self.install(bounds: resolved, forHit: pair.0) }
            }
        }
    }

    public func advance(by delta: Int) {
        guard !hits.isEmpty else { return }
        let current = activeHitID.flatMap { id in hits.firstIndex { $0.id == id } } ?? -1
        let count = hits.count
        // Wrapping arithmetic that stays correct for a negative delta larger than `count`.
        let next = ((current + delta) % count + count) % count
        selectHit(id: hits[next].id)
    }

    public func clear() {
        abandonRunningSearch()
        query = ""
        hits = []
        activeHitID = nil
        activeHitIsPersonsChoice = false
        showsOCRDisclaimer = false
        resultSummary = ""
        operation?.cancel()
        operation = nil
    }

    // MARK: Searching

    /// Answers another drawing's project-wide fan-out, without touching this panel's state.
    ///
    /// `ProjectSearchSource` closures call this on the presenter of every *other* open drawing.
    /// It runs the same engine query the panel runs — same service, same identity mapping — but
    /// writes nothing back: no `query`, no hits, no spinner. A fan-out that flickered every
    /// other drawing's own Search panel would be this feature leaking sideways.
    ///
    /// `options` are the *asking* panel's Match Case and Whole Word (W-081), compiled by the
    /// same rule as that panel's own query (``engineQueryOptions(_:)``). A fan-out that matched
    /// by other rules than the drawing in front answers one question two ways, and the person
    /// reads the difference as "the other drawings do not contain it" — or, before this, as
    /// Match Case not working: a Match Case `ROOM` listed every `room` of every other drawing.
    public func hitsForProjectSearch(
        _ text: String,
        options: ProjectSearchOptions
    ) async -> [ZPDFUIPresentation.SearchHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let request = SearchRequest(
            text: trimmed,
            scope: .project(projectId: projectID),
            sources: .all,
            // Nothing here reads this panel's own `scope`, exactly as `.project` and `.all`
            // above do not: this runs on the *answering* drawing's presenter, and its
            // checkboxes narrowing another drawing's search would be a silent cross-talk. The
            // matching rules come from the asker, through `options`.
            queryOptions: Self.engineQueryOptions(options),
            confidence: .standard,
            // Listed first, located when the drawing's own window reveals one (R-153).
            resolvesBounds: false
        )
        guard let results = try? await service.search(request) else { return [] }
        let identity = self.identity
        var answered: [(UUID, ZPDFSearch.SearchHit)] = []
        let mapped = results.hits.compactMap { engineHit -> ZPDFUIPresentation.SearchHit? in
            guard let hit = identity.hit(engineHit) else { return nil }
            answered.append((hit.id, engineHit))
            return hit
        }
        if answeredEngineHits.count + answered.count > Self.answeredHitMemory {
            answeredEngineHits.removeAll(keepingCapacity: true)
        }
        for (id, engineHit) in answered { answeredEngineHits[id] = (engineHit, results.query) }
        return mapped
    }

    /// Where a hit this drawing listed in another drawing's fan-out lies on its page, resolved
    /// now — the drawing that owns the hit calls this when the person reveals it (R-153).
    /// `nil` for a hit this presenter did not answer, or one with no geometry.
    public func projectSearchBounds(forHit id: ZPDFUIPresentation.SearchHit.ID) async -> PDFRectValue? {
        guard let entry = answeredEngineHits[id] else { return nil }
        guard let bounds = try? await service.bounds(for: entry.hit, query: entry.query),
              let rect = bounds.rects.first
        else { return nil }
        return PDFRectValue(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    /// Stops the running query and makes its replies unusable.
    ///
    /// Cancellation alone is not enough and never was. A task that has already passed its
    /// `Task.isCancelled` check still has a `MainActor.run` in flight, and that hop lands after
    /// `clear()` returns — repopulating a panel the person just emptied, with results for a
    /// word they are no longer looking for. Bumping the generation is what makes the late
    /// reply arrive to a question nobody is asking and be dropped.
    private func abandonRunningSearch() {
        searchTask?.cancel()
        searchTask = nil
        cancelExternalSearches()
        generation &+= 1
        activeHitIsPersonsChoice = false
        ownHits = []
        ownHitsText = nil
        externalHits = []
        ownResultsWereTruncated = false
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        cancelExternalSearches()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            abandonRunningSearch()
            hits = []
            activeHitID = nil
            showsOCRDisclaimer = false
            resultSummary = ""
            isSearching = false
            return
        }
        isSearching = true
        let debounce = self.debounce
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.performSearch()
        }
    }

    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        cancelExternalSearches()
        generation &+= 1
        let generation = self.generation
        // The own-document hits stand while the *text* is unchanged. A re-run that only
        // changed the sources — another drawing finished opening — used to clear them here and
        // then publish whichever half answered first; the in-process fan-out usually did, so
        // the list read "no own results, the other drawing's" until this drawing's index
        // answered again, and anyone who looked in that window saw the front drawing's own
        // results gone. Keeping the standing answer makes the merge independent of which reply
        // lands first: the new own result replaces it when it arrives, under the same
        // generation check as ever, and a new word still starts from nothing.
        if ownHitsText != trimmed {
            ownHits = []
            ownResultsWereTruncated = false
            // The previous word's query goes with its hits. Kept, it put that query's "NOT … was
            // not excluded" note beside the new word's first results from another drawing,
            // until this drawing's own answer replaced it (V-039).
            engineQuery = nil
        }
        externalHits = []

        // The fan-out starts *before* the own-document query is awaited, and lands in its own
        // store. Neither half waits on the other, and neither half can overwrite the other.
        if searchesAllDrawings { queryExternalSources(text: trimmed, generation: generation) }

        let handle = OperationHandle(
            title: NSLocalizedString("Searching", comment: "Progress title for a running search")
        )
        operation = handle
        isSearching = true

        let request = SearchRequest(
            text: trimmed,
            scope: engineScope,
            sources: sourceFilter,
            queryOptions: queryOptions,
            confidence: .standard,
            // Listed first, located on reveal (IM-085).
            resolvesBounds: false
        )
        let service = self.service
        let identity = self.identity
        let task = Task { [weak self] in
            let sink = ProgressSink(handle: handle)
            sink(OperationProgress(stage: .working, detail: trimmed))
            do {
                let results = try await service.search(request)
                guard !Task.isCancelled else {
                    sink(.cancelled)
                    return
                }
                var engine: [UUID: ZPDFSearch.SearchHit] = [:]
                let mapped = results.hits.compactMap { engineHit -> ZPDFUIPresentation.SearchHit? in
                    guard let hit = identity.hit(engineHit) else { return nil }
                    engine[hit.id] = engineHit
                    return hit
                }
                sink(.completed)
                let engineHits = engine
                await MainActor.run {
                    self?.apply(
                        hits: mapped, engineHits: engineHits, results: results,
                        text: trimmed, generation: generation
                    )
                }
            } catch {
                sink(OperationProgress(stage: .failed, detail: String(describing: error)))
                await MainActor.run { self?.applyFailure(generation: generation) }
            }
        }
        handle.attach(cancelling: task)
    }

    // MARK: The other open drawings

    /// Asks every external source the same question, each in its own task.
    ///
    /// One task per source rather than a sequence: a drawing whose index is still filling can
    /// take hundreds of milliseconds, and a sequential walk would make the slowest drawing the
    /// deadline for every drawing behind it. Results are appended as each drawing answers, so
    /// the list fills in rather than appearing all at once at the end.
    private func queryExternalSources(text: String, generation: UInt64) {
        // The matching rules travel with the text (W-081): Match Case and Whole Word cannot be
        // applied to the other drawings' answers afterwards, a case-folded answer has lost the
        // case. Location and sources stay here — every drawing answers project-wide and
        // ``appendExternal(_:generation:)`` keeps what this scope asked for.
        let options = ProjectSearchOptions(scope: scope)
        for source in externalSources {
            externalTasks.append(Task { [weak self] in
                let hits = await source.labelledHits(for: text, options: options)
                guard !Task.isCancelled else { return }
                self?.appendExternal(hits, generation: generation)
            })
        }
    }

    private func cancelExternalSearches() {
        for task in externalTasks { task.cancel() }
        externalTasks = []
    }

    /// Adds one other drawing's results to the list.
    ///
    /// The generation check is what makes a slow drawing safe: a reply that arrives after the
    /// query changed belongs to a question nobody is asking any more, and appending it would
    /// show hits for the previous word.
    private func appendExternal(_ hits: [ZPDFUIPresentation.SearchHit], generation: UInt64) {
        guard generation == self.generation else { return }
        // Another drawing answers project-wide and from every source; this scope keeps what it
        // asked for. "Current Page" keeps only the sheet on screen, and the Look In boxes keep
        // only their sources — before, only the location was applied here, so unticking OCR
        // Text still listed every other drawing's recognised words.
        let sources = scope.sources
        let hits = hits.filter { hit in
            sources.contains(hit.source) && (scope.location != .currentPage || hit.pageID == currentPageID)
        }
        guard !hits.isEmpty else { return }
        externalHits.append(contentsOf: hits)
        republish()
    }

    // MARK: Publishing

    private func apply(
        hits: [ZPDFUIPresentation.SearchHit],
        engineHits: [UUID: ZPDFSearch.SearchHit] = [:],
        results: SearchResults,
        text: String,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        ownHits = hits
        self.engineHits = engineHits
        engineQuery = results.query
        defer { resolveLeadingBounds(generation: generation) }
        ownHitsText = text
        ownResultsWereTruncated = results.wasTruncated
        isSearching = false
        republish()
    }

    /// Rebuilds the published result set from the two stores.
    ///
    /// The active document's hits stay first. That is the ordering the person asked for — they
    /// are looking at this drawing — and it also means the revealed hit does not jump to
    /// another drawing the moment a fan-out lands.
    private func republish() {
        hits = ownHits + externalHits
        // The search-aid disclaimer stands beside every listed recognised hit, this drawing's
        // or another's (L-20). It used to follow this drawing's own answer only, so a
        // recognised word from another open drawing was listed without it.
        showsOCRDisclaimer = Self.listsRecognisedText(hits)
        resultSummary = Self.summary(
            ownCount: ownHits.count,
            externalCount: externalHits.count,
            truncated: ownResultsWereTruncated
        )
        if ownHitsText != nil, let dropped = engineQuery?.droppedExclusions, !dropped.isEmpty {
            resultSummary += " — " + Self.droppedExclusionNote(dropped.map(\.sourceText))
        }
        if activeHitIsPersonsChoice, let activeHitID, hits.contains(where: { $0.id == activeHitID }) { return }
        activeHitIsPersonsChoice = false
        activeHitID = hits.first?.id
    }

    private func applyFailure(generation: UInt64) {
        guard generation == self.generation else { return }
        isSearching = false
        ownHits = []
        ownHitsText = nil
        ownResultsWereTruncated = false
        // A failure of *this* drawing's index is not a failure of the others. Whatever they
        // already returned stays, because it is true, and the summary says the query failed.
        hits = externalHits
        showsOCRDisclaimer = Self.listsRecognisedText(hits)
        activeHitID = hits.first?.id
        resultSummary = NSLocalizedString(
            "Search failed",
            comment: "Search field status when the query could not be run"
        )
    }

    /// The status for this drawing's hits plus other drawings'.
    ///
    /// The cap is this drawing's index's; the other drawings' hits are not under it. Folding
    /// them into one "First 523 results" named a cap the engine never applied to a mixed set
    /// (BH-451), so a capped own set says so on its own count and the rest are added after it.
    static func summary(ownCount: Int, externalCount: Int, truncated: Bool) -> String {
        guard truncated, externalCount > 0 else {
            return summary(count: ownCount + externalCount, truncated: truncated)
        }
        let format = NSLocalizedString(
            "First %1$d results in this drawing, %2$d in other drawings",
            comment: "Search result count when this drawing's results were capped and other drawings added more"
        )
        return String(format: format, ownCount, externalCount)
    }

    /// What the status adds when the query held an exclusion the index cannot run — a leading
    /// `NOT`, or `NOT` after `OR` — and the compiler left the excluded words out rather than
    /// searching for them (U-081). Without it the list would read as if they had been excluded.
    /// The wording is ``SearchExclusionNote``'s, shared with the batch sheet's search scope.
    static func droppedExclusionNote(_ terms: [String]) -> String {
        SearchExclusionNote.text(for: terms)
    }

    /// Whether a result list holds a recognised hit, so the search-aid disclaimer must show.
    static func listsRecognisedText(_ hits: [ZPDFUIPresentation.SearchHit]) -> Bool {
        hits.contains { $0.source == .ocrText }
    }

    static func summary(count: Int, truncated: Bool) -> String {
        if truncated {
            let format = NSLocalizedString(
                "First %d results",
                comment: "Search result count when the engine capped the result set"
            )
            return String(format: format, count)
        }
        let format = NSLocalizedString(
            "%d results",
            comment: "Search result count"
        )
        return String(format: format, count)
    }

    /// How much of the query string is syntax, and whether the word being typed is a prefix.
    ///
    /// The panel is a find-as-you-type field, so the **last bare word** compiles as a prefix:
    /// an estimator who has typed `Storkök` is in the middle of `Storkökskonsult`, and a
    /// whole-token match answers "no results" to a word that is on the sheet in front of them
    /// (LT-10). Only the last bare word — every term the person put a separator after is
    /// finished — and never over explicit syntax: a quoted phrase stays a phrase, a typed `*`
    /// is already a prefix, a trailing operator or trailing space means the word was finished.
    ///
    /// ``SearchScope/isWholeWord`` turns it off, and turns it off the honest way: by refusing
    /// prefix matching outright rather than by leaving the implied `*` on and hoping. Whole
    /// word is the person saying *exactly this token*, and a scope that quietly widened it
    /// would be the same class of lie as inventing a hit.
    ///
    /// ``SearchScope/isCaseSensitive`` reaches the engine as
    /// ``SearchQueryOptions/isCaseSensitive`` (W-081). Before, nothing read it: Match Case on
    /// `ROOM` still listed every `room`.
    private var queryOptions: SearchQueryOptions {
        Self.engineQueryOptions(ProjectSearchOptions(scope: scope))
    }

    /// The one rule from the panel's matching toggles to the engine's query options, shared by
    /// this panel's own query and the answers it gives another drawing's fan-out, so the two
    /// can never match by different rules.
    static func engineQueryOptions(_ options: ProjectSearchOptions) -> SearchQueryOptions {
        var engine = options.isWholeWord ? SearchQueryOptions(allowsPrefixMatching: false) : .findAsYouType
        engine.isCaseSensitive = options.isCaseSensitive
        return engine
    }

    /// A page key no index holds: the own query's scope when the sheet on screen is another
    /// drawing's.
    static let noPageKey = "#no-page-in-this-drawing"

    private var engineScope: ZPDFSearch.SearchScope {
        switch scope.location {
        case .entireProject:
            return .project(projectId: projectID)
        case .currentDocument:
            guard let documentID = identity.currentDocumentKey else { return .project(projectId: projectID) }
            return .document(projectId: projectID, documentId: documentID)
        case .currentPage:
            if let pageKey = identity.currentPageKey { return .page(projectId: projectID, pageId: pageKey) }
            // The sheet on screen is another drawing's: no page of this index is it, so the own
            // query answers nothing rather than the whole project.
            guard currentPageID != nil else { return .project(projectId: projectID) }
            return .page(projectId: projectID, pageId: Self.noPageKey)
        }
    }

    /// The engine's source filter for the UI's scope checkboxes.
    ///
    /// The UI offers "Markups", "Comments" and "Labels" as three boxes; the index stores
    /// subject, label and comment as three source types. The mapping is one-to-one except
    /// for "Markups", which means the subject line specifically — ticking all three gives
    /// the same set as the engine's `.markups`.
    private var sourceFilter: SearchSourceFilter {
        var filter: SearchSourceFilter = []
        for source in scope.sources {
            switch source {
            case .pdfText: filter.insert(.pdfText)
            case .ocrText: filter.insert(.ocr)
            case .markups: filter.insert(.markupSubject)
            case .labels: filter.insert(.markupLabel)
            case .comments: filter.insert(.markupComment)
            case .customFields: filter.formUnion([.customValue, .zoneName])
            }
        }
        return filter.isEmpty ? .all : filter
    }
}

/// Maps the search index's string identifiers back to the UI's `UUID`s.
///
/// The index stores whatever key the importer gave it, which is not required to be a
/// `UUID` string — a project imported from another tool can have any key at all. So the
/// mapping is a table the app fills in, and a hit whose key is not in it is dropped rather
/// than pointed at a random page.
public struct SearchIdentityMap: Sendable {

    private var documents: [String: (id: UUID, title: String)]
    private var pages: [String: (id: UUID, index: Int, label: String)]
    private var pageKeysByID: [UUID: String]

    /// The document the "current document" scope means.
    public var currentDocumentKey: String?
    /// The page the "current page" scope means.
    public var currentPageKey: String?

    /// Creates a map.
    public init() {
        documents = [:]
        pages = [:]
        pageKeysByID = [:]
    }

    /// Registers a document.
    public mutating func register(documentKey: String, id: UUID, title: String) {
        documents[documentKey] = (id, title)
    }

    /// Registers a page.
    public mutating func register(pageKey: String, id: UUID, index: Int, label: String) {
        pages[pageKey] = (id, index, label)
        pageKeysByID[id] = pageKey
    }

    /// The index key of the page with this identity, or `nil` when this map does not hold it.
    public func pageKey(forPageID id: UUID) -> String? { pageKeysByID[id] }

    /// Converts an engine hit, or `nil` when its document or page is not registered.
    public func hit(_ hit: ZPDFSearch.SearchHit) -> ZPDFUIPresentation.SearchHit? {
        guard let documentKey = hit.documentId, let document = documents[documentKey] else { return nil }
        guard let pageKey = hit.pageId, let page = pages[pageKey] else { return nil }
        return ZPDFUIPresentation.SearchHit(
            id: UUID(),
            documentID: document.id,
            documentTitle: document.title,
            pageID: page.id,
            pageIndex: hit.pageIndex ?? page.index,
            pageLabel: hit.pageLabel ?? page.label,
            source: Self.source(hit.sourceType),
            snippet: hit.snippet,
            highlightRange: nil,
            boundsInPageSpace: hit.bounds.first.map { rect in
                PDFRectValue(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.size.width,
                    height: rect.size.height
                )
            },
            markupID: Self.markupID(of: hit)
        )
    }

    /// The markup a hit came from, when it came from one.
    ///
    /// A custom-value hit's `source_id` is `markupId + "/" + columnId`, so the identifier
    /// is the part before the slash; a subject, label or comment hit's is the markup id
    /// itself. A key that is not a `UUID` yields `nil` rather than a wrong markup.
    static func markupID(of hit: ZPDFSearch.SearchHit) -> UUID? {
        switch hit.sourceType {
        case .markupSubject, .markupLabel, .markupComment:
            return UUID(uuidString: hit.sourceId)
        case .customValue:
            return hit.sourceId.split(separator: "/").first.flatMap { UUID(uuidString: String($0)) }
        case .pdfText, .ocr, .zoneName, .indexStamp:
            return nil
        }
    }

    /// The UI source family for an index source type.
    ///
    /// `indexStamp` never reaches here — every query constrains `source_type` to an
    /// explicit list that excludes it — but the switch stays total so that adding a source
    /// type to the index is a compile error here rather than a hit with the wrong icon.
    static func source(_ type: SearchSourceType) -> SearchSource {
        switch type {
        case .pdfText, .indexStamp: .pdfText
        case .ocr: .ocrText
        case .markupSubject: .markups
        case .markupLabel: .labels
        case .markupComment: .comments
        case .customValue, .zoneName: .customFields
        }
    }
}
