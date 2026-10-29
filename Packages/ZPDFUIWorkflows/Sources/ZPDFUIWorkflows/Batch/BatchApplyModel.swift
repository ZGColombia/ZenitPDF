import Foundation
import Observation
import ZPDFUIPresentation

/// The state behind the scoped batch apply sheet.
///
/// A model with no view in it, so the whole of the batch's safety story is testable without a
/// window: the scope choices, the preview sentence, the anchor, the skip rule, the progress
/// and — the one that matters — the fact that **nothing runs until the person has seen the
/// count**. ``run()`` refuses when no plan has been previewed, which is not a defensive
/// nicety: an apply that could fire before a preview existed is exactly the expensive
/// mistake people make with batch features.
@MainActor
@Observable
public final class BatchApplyModel {

    /// The scope kinds the picker offers, as a stable list.
    public enum ScopeChoice: String, Hashable, Sendable, CaseIterable, Identifiable {
        case allPages
        case pageRange
        case matchingSize
        case matchingSearchTerm
        case navigatorSelection

        public var id: String { rawValue }

        /// A localized name for the picker row.
        public var displayName: String {
            switch self {
            case .allPages:
                return NSLocalizedString("All pages", comment: "Batch apply scope choice")
            case .pageRange:
                return NSLocalizedString("Page range", comment: "Batch apply scope choice")
            case .matchingSize:
                return NSLocalizedString("Pages of one size", comment: "Batch apply scope choice")
            case .matchingSearchTerm:
                return NSLocalizedString("Pages containing text", comment: "Batch apply scope choice")
            case .navigatorSelection:
                return NSLocalizedString("Navigator selection", comment: "Batch apply scope choice")
            }
        }
    }

    // MARK: Choices

    /// Which scope kind is selected.
    public var scopeChoice: ScopeChoice = .allPages { didSet { invalidatePlan() } }
    /// First page of a range, one-based.
    public var rangeFrom: Int = 1 { didSet { invalidatePlan() } }
    /// Last page of a range, one-based and inclusive.
    public var rangeThrough: Int = 1 { didSet { invalidatePlan() } }
    /// Width in PDF points for a size scope.
    public var sizeWidthPoints: Double = 2384 { didSet { invalidatePlan() } }
    /// Height in PDF points for a size scope.
    public var sizeHeightPoints: Double = 1684 { didSet { invalidatePlan() } }
    /// Tolerance in PDF points for a size scope, so a sheet trimmed by a point still matches.
    public var sizeTolerancePoints: Double = 2 { didSet { invalidatePlan() } }
    /// The term a search scope matches.
    public var searchTerm: String = "" { didSet { invalidatePlan() } }
    /// The pages the navigator has selected.
    public var navigatorSelection: [UUID] = [] { didSet { invalidatePlan() } }

    /// Which corner the placement anchors at, or `nil` for centred.
    public var anchorCorner: BatchAnchorCorner? = .bottomRight { didSet { invalidatePlan() } }
    /// Horizontal inset from that corner, in PDF points.
    public var insetX: Double = 36 { didSet { invalidatePlan() } }
    /// Vertical inset from that corner, in PDF points.
    public var insetY: Double = 36 { didSet { invalidatePlan() } }

    /// Whether pages that already carry the same thing are skipped.
    public var skipPagesAlreadyCarrying: Bool = true { didSet { invalidatePlan() } }

    /// Text for a stamp's prompted free-text field, when the template asks for one.
    public var promptedText: String = "" { didSet { invalidatePlan() } }
    /// The question to ask for that text, or `nil` when the template asks nothing.
    public var placementPrompt: String?
    /// Whether nothing can be placed until that text is typed — a header or footer is its text,
    /// where a stamp's free-text field is optional. The preview then asks for the text rather
    /// than for a scope that is already chosen (L-60).
    public var requiresPromptedText = false

    // MARK: State

    /// The previewed plan, or `nil` before anything has been previewed.
    public private(set) var plan: BatchApplyPlan?
    /// What the search term resolved to, when a search scope has been resolved.
    public private(set) var searchResolution: BatchSearchScopeResolution?
    /// Whether the search term is being resolved into pages right now.
    ///
    /// A separate state from "no plan yet" because the sentence has to be different. A
    /// preview that says "no page matches this scope" while the index is still being asked
    /// is a preview that lies for a quarter of a second, and a person who reads it in that
    /// quarter-second changes a term that was correct.
    public private(set) var isResolvingScope: Bool = false
    /// Fraction complete while a batch runs, `0...1`, or `nil` when nothing is running.
    public private(set) var progressFraction: Double?
    /// A one-line description of what the batch is doing, for the progress row.
    public private(set) var progressDetail: String = ""
    /// Whether a batch is running right now.
    public private(set) var isRunning: Bool = false
    /// The receipt of the last completed batch.
    public private(set) var receipt: BatchApplyReceipt?
    /// How the last run ended, for the sheet to show once it has stopped: a run that placed
    /// fewer than it previewed (BH-829) or a cancelled one. `nil` before any run, while one
    /// runs, after a run that failed (``resultFailure`` carries that) and once any choice
    /// changes. The sheet used to show the after-run sentence only inside its `isRunning`
    /// block, which `run()` had already left, so neither sentence was ever seen and a short run
    /// fell back to "Choose a scope…" (W-072).
    public private(set) var resultSentence: String?
    /// Whether ``resultSentence`` reports a short run, which the sheet shows as a warning.
    public private(set) var resultIsShortfall: Bool = false
    /// The failed last run's own message, for the sheet to show once it has stopped. Set when a
    /// run fails; gone at the start of every ``preview()`` (Preview Again included), when any
    /// choice changes and when the next run starts. Unlike the short-run sentence, it does not
    /// survive Preview Again: a fresh count with Apply live, over an error in warning colour,
    /// reads as a forecast that the next Apply will fail too. ``receipt`` keeps the message as
    /// the record of what happened.
    ///
    /// X-035: the sheet used to read ``receipt``'s failure message, which nothing ever clears,
    /// so after Preview Again or a scope change the fresh preview sat over the old run's error
    /// in warning colour, with Apply live.
    public private(set) var resultFailure: String?
    /// Whether the last run dropped its plan because it changed the document (a short or a
    /// failed run). The sheet then offers Preview Again, which calls ``preview()``, instead of
    /// asking for a scope that is already chosen.
    public private(set) var needsFreshPreview: Bool = false

    // MARK: Host hooks

    /// Computes a plan for the current choices. The host wires this to the environment's
    /// planner; unset, the model previews nothing and ``run()`` stays refused.
    public var onPlan: (@MainActor (BatchApplyRequestValues) -> BatchApplyPlan?)?
    /// Runs a previewed plan. The host wires this to the environment's batch apply.
    public var onRun: (@MainActor (BatchApplyPlan, String) async -> BatchApplyReceipt)?
    /// Cancels the running batch.
    public var onCancel: (@MainActor () -> Void)?
    /// Resolves a search term into the pages whose text contains it.
    ///
    /// Async and host-supplied, for the same reason ``BatchApplyRequest`` takes the matched
    /// pages as an input rather than looking them up: the text index is an actor with its
    /// own lifecycle, and a planner that could hang or throw is not a planner you can call
    /// on every keystroke. Left unset, the search scope resolves to nothing and the sheet
    /// says the search is unavailable — never that no page matched, which is a different
    /// fact.
    public var onResolveSearchScope: (@MainActor (String) async -> BatchSearchScopeResolution)?
    /// Called when the sheet should close.
    public var onClose: (@MainActor () -> Void)?

    /// How long the term sits still before the index is asked.
    ///
    /// A resolution is a database query over a whole drawing; one per keystroke would be
    /// one per keystroke. Matches the search panel's own debounce closely enough that the
    /// two feel like the same feature.
    public var searchResolveDebounce: Duration = .milliseconds(250)

    /// The running resolution, so a newer term cancels an older one.
    private var resolveTask: Task<Void, Never>?

    /// How many pages the drawing set has, so a range defaults to all of them and its fields
    /// accept nothing past the last page (IM-143). `nil` when the host did not say, and the
    /// range fields then accept any page number.
    public let pageCount: Int?
    /// The size of the page the person was looking at when the sheet opened, in PDF points,
    /// or `nil` when the host did not say. It seeds the size scope and bounds the insets.
    public let currentPageSize: PDFSizeValue?

    /// How long choices sit still before the preview is recomputed (IM-144). Every choice
    /// invalidates the plan and schedules one coalesced preview, so a new choice cannot be
    /// added without re-previewing and the synchronous planner is not run on every keystroke.
    public var previewCoalescing: Duration = .milliseconds(150)
    /// The scheduled coalesced preview.
    private var previewTask: Task<Void, Never>?

    /// Creates a model.
    ///
    /// - Parameters:
    ///   - currentPageSize: the page the person is looking at. "Pages of one size" then means
    ///     "like this page" rather than a hard-coded A1 (IM-143).
    ///   - pageCount: the drawing set's page count; the range defaults to 1…pageCount.
    ///   - anchorCorner: the corner last used for this item, which the host remembers per
    ///     stamp template; `.bottomRight` when it has none.
    ///   - insetX: the horizontal inset last used, in points.
    ///   - insetY: the vertical inset last used, in points.
    public init(
        currentPageSize: PDFSizeValue? = nil,
        pageCount: Int? = nil,
        anchorCorner: BatchAnchorCorner? = .bottomRight,
        insetX: Double = 36,
        insetY: Double = 36
    ) {
        self.pageCount = pageCount.map { max(1, $0) }
        self.currentPageSize = currentPageSize
        if let currentPageSize, currentPageSize.width > 0, currentPageSize.height > 0 {
            self.sizeWidthPoints = currentPageSize.width
            self.sizeHeightPoints = currentPageSize.height
        }
        self.rangeThrough = max(1, pageCount ?? 1)
        self.anchorCorner = anchorCorner
        self.insetX = insetX
        self.insetY = insetY
    }

    // MARK: Derived

    /// The scope the current choices describe.
    public var scope: BatchPageScope {
        switch scopeChoice {
        case .allPages: return .allPages
        case .pageRange: return .pageRange(from: rangeFrom, through: rangeThrough)
        case .matchingSize:
            return .matchingSize(
                widthPoints: sizeWidthPoints,
                heightPoints: sizeHeightPoints,
                tolerancePoints: sizeTolerancePoints
            )
        case .matchingSearchTerm: return .matchingSearchTerm(searchTerm)
        case .navigatorSelection: return .navigatorSelection(navigatorSelection)
        }
    }

    /// The position the current choices describe.
    public var anchor: BatchAnchor {
        guard let anchorCorner else { return .centered }
        return .corner(anchorCorner, insetX: insetX, insetY: insetY)
    }

    /// The choices as one value for the host's planner.
    public var requestValues: BatchApplyRequestValues {
        BatchApplyRequestValues(
            scope: scope,
            anchor: anchor,
            skipPagesAlreadyCarrying: skipPagesAlreadyCarrying,
            promptedText: promptedText,
            searchMatchedPageIDs: searchMatchedPageIDs
        )
    }

    /// The pages a search scope resolved to, or `nil` when this is not a search scope or
    /// the resolution on hand answers a different term.
    ///
    /// The term check is the whole safety of this: a resolution for `FIRE` shown against a
    /// field that now reads `FIRE E` would preview a count belonging to a question nobody
    /// asked. `nil` reaches the planner as "the search has not run", which selects nothing.
    public var searchMatchedPageIDs: Set<UUID>? {
        guard scopeChoice == .matchingSearchTerm else { return nil }
        guard let searchResolution, searchResolution.term == trimmedSearchTerm else { return nil }
        guard searchResolution.isAvailable else { return nil }
        return searchResolution.pageIDs
    }

    /// The term as it is searched: trimmed, so trailing whitespace is not a new question.
    private var trimmedSearchTerm: String {
        searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sentence shown above the Apply button.
    ///
    /// Before a preview exists it says so rather than saying nothing: a blank where a count
    /// belongs reads as "zero", and the person is about to press Apply.
    public var previewSentence: String {
        if let insetIssue { return insetIssue }
        if isResolvingScope {
            let format = NSLocalizedString(
                "Finding the pages that contain \u{201C}%@\u{201D}\u{2026}",
                comment: "Batch apply preview while the search scope is being resolved. %@ is the term"
            )
            return String(format: format, trimmedSearchTerm)
        }
        if scopeChoice == .matchingSearchTerm, trimmedSearchTerm.isEmpty {
            return NSLocalizedString(
                "Type the text a page must contain.",
                comment: "Batch apply preview when the search scope has no term yet"
            )
        }
        if searchIsUnavailable {
            // An unanswered question is not a question answered "none". The planner selects
            // zero pages when the index could not answer, and its sentence for zero pages is
            // "No page matches this scope" — the one thing the model's contract says must never
            // be shown for an unavailable search. Finding BH-305.
            return NSLocalizedString(
                "Nothing can be counted until search can read this drawing, so nothing will be placed.",
                comment: "Batch apply preview when the search index could not answer"
            )
        }
        guard let plan else {
            if needsFreshPreview {
                return NSLocalizedString(
                    "Not counted since the last run.",
                    comment: "Batch apply sheet, after a short or failed run dropped the previewed count"
                )
            }
            // L-60: the scope already read "All pages"; what was missing was the text.
            if requiresPromptedText, promptedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return NSLocalizedString(
                    "Type the text for each sheet to see how many will be placed.",
                    comment: "Batch apply sheet, before the text a header or footer needs has been typed"
                )
            }
            return NSLocalizedString(
                "Choose a scope to see how many will be placed.",
                comment: "Batch apply sheet, before a scope has been previewed"
            )
        }
        return plan.previewSentence
    }

    /// Whether the search scope's answer on hand is "the index could not answer".
    private var searchIsUnavailable: Bool {
        guard scopeChoice == .matchingSearchTerm, !isResolvingScope,
              let searchResolution, searchResolution.term == trimmedSearchTerm
        else { return false }
        return !searchResolution.isAvailable
    }

    /// The largest inset the sheet accepts, in points: the shorter side of the current page
    /// when the host said what it is, otherwise the largest page PDF allows.
    public var maximumInsetPoints: Double {
        guard let currentPageSize, currentPageSize.width > 0, currentPageSize.height > 0 else {
            return 14_400
        }
        return min(currentPageSize.width, currentPageSize.height)
    }

    /// Why the insets cannot be used, or `nil` when they can.
    ///
    /// A negative inset or one the size of the page used to preview as "This will place 312
    /// stamps" and write 312 markups whose centre is off every sheet — invisible on the canvas,
    /// present in the ledger. Finding BH-831. Refused here, before the count, with the limit.
    public var insetIssue: String? {
        guard anchorCorner != nil else { return nil }
        let limit = maximumInsetPoints
        guard insetX.isFinite, insetY.isFinite,
              (0..<limit).contains(insetX), (0..<limit).contains(insetY)
        else {
            return String(
                format: NSLocalizedString(
                    "Insets must be at least 0 and less than %@ pt, or the placement would land off the page.",
                    comment: "Batch apply: the insets are negative or as large as the page. %@ is the limit in points"
                ),
                limit.formatted(.number.precision(.fractionLength(0...1)))
            )
        }
        return nil
    }

    /// The scope restated in words, or `nil` before a plan exists.
    ///
    /// Shown above the count, because the count is only checkable against a statement of
    /// what was counted.
    public var scopeSentence: String? {
        // "Scope: Pages containing “FIRE” — 0 of 312 pages" over an index that never answered
        // is the same lie as the count below it. BH-305.
        guard !isResolvingScope, !searchIsUnavailable else { return nil }
        return plan?.scopeSentence
    }

    /// What qualifies the scope, when something does: a capped search, matches that came
    /// from recognised text, or an index that could not answer at all.
    public var scopeCautionSentence: String? {
        guard scopeChoice == .matchingSearchTerm, !isResolvingScope else { return nil }
        guard let searchResolution, searchResolution.term == trimmedSearchTerm else { return nil }
        return searchResolution.cautionSentence
    }

    /// The skip sentence, or `nil` when nothing will be skipped.
    public var skipSentence: String? { searchIsUnavailable ? nil : plan?.skipSentence }

    /// Whether Apply can be pressed.
    ///
    /// A previewed, non-empty plan and no batch already running. The person cannot apply a
    /// count they have not been shown.
    public var canApply: Bool {
        guard let plan, !isRunning, !isResolvingScope, insetIssue == nil else { return false }
        return !plan.isEmpty
    }

    // MARK: Actions

    /// Recomputes the preview from the current choices.
    ///
    /// Synchronous for four of the five scopes, because four of them are answerable from
    /// the snapshot alone. The search scope is the exception: it needs the text index, so
    /// this starts a debounced resolution and re-plans when the answer lands. Everything
    /// the sheet renders in between says which of the two it is looking at — resolving, or
    /// resolved — and ``canApply`` is false throughout.
    public func preview() {
        previewTask?.cancel()
        previewTask = nil
        needsFreshPreview = false
        // A fresh count describes the batch about to run, not the one that failed (X-035).
        resultFailure = nil
        guard scopeChoice == .matchingSearchTerm else {
            cancelResolution()
            searchResolution = nil
            replan()
            return
        }

        let term = trimmedSearchTerm
        guard !term.isEmpty else {
            cancelResolution()
            searchResolution = nil
            plan = nil
            return
        }

        // An answer already on hand for exactly this term is reused: retyping a character
        // and deleting it again must not re-query a 1 000-sheet index.
        if let searchResolution, searchResolution.term == term {
            cancelResolution()
            replan()
            return
        }

        guard let onResolveSearchScope else {
            // No host resolver. The scope resolves to nothing, and the sheet says the
            // search is unavailable rather than reporting an empty drawing.
            cancelResolution()
            searchResolution = .unavailable(
                term: term,
                reason: NSLocalizedString(
                    "Search is unavailable for this drawing, so this scope cannot be previewed.",
                    comment: "Batch apply search scope, with no index behind the sheet"
                )
            )
            replan()
            return
        }

        resolveTask?.cancel()
        isResolvingScope = true
        plan = nil
        let debounce = searchResolveDebounce
        resolveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let resolution = await onResolveSearchScope(term)
            guard !Task.isCancelled, let self else { return }
            // The field may have moved on while the index was being read. A resolution for
            // a term nobody is looking at is dropped, never rendered.
            guard self.scopeChoice == .matchingSearchTerm, self.trimmedSearchTerm == term else { return }
            self.searchResolution = resolution
            self.isResolvingScope = false
            self.resolveTask = nil
            self.replan()
        }
    }

    /// Recomputes the plan from the choices as they stand, with no resolution step.
    private func replan() {
        guard let onPlan else {
            plan = nil
            return
        }
        plan = onPlan(requestValues)
    }

    /// Stops any resolution in flight and leaves the sheet out of the resolving state.
    private func cancelResolution() {
        resolveTask?.cancel()
        resolveTask = nil
        isResolvingScope = false
    }

    /// Runs the previewed plan.
    ///
    /// Refuses whenever ``canApply`` is false, which is the preview-first rule made structural rather
    /// than remembered — and structural in one place, so the button's enabled state and the
    /// method's guard cannot drift apart. That drift was real: `run()` used to check only
    /// that *a* plan existed, so a plan for a scope that resolved to zero pages ran, placed
    /// nothing, and reported "Placed 0. One Undo removes all of them" over an undo step that
    /// did not exist.
    public func run() async {
        guard canApply, let plan, let onRun else { return }
        resultSentence = nil
        resultIsShortfall = false
        resultFailure = nil
        isRunning = true
        progressFraction = 0
        progressDetail = plan.previewSentence
        let outcome = await onRun(plan, promptedText)
        receipt = outcome
        isRunning = false
        progressFraction = outcome.wasCancelled ? nil : 1
        progressDetail = outcome.completionSentence
        if let shortfall = Self.shortfallSentence(plan: plan, outcome: outcome) {
            // Fewer placed than previewed, with no failure and no cancel: the runner skipped
            // pages it could not place on, or the core went away and handed back an empty
            // receipt. The sheet used to call that a success — "Placed 0. One Undo removes all
            // of them." over an undo step that did not exist — and close before anybody could
            // read it. Finding BH-829. It stays open, says what happened, and asks for a fresh
            // preview, because the document is no longer the one the plan described.
            progressDetail = shortfall
            resultSentence = shortfall
            resultIsShortfall = true
            needsFreshPreview = true
            self.plan = nil
            return
        }
        if let failure = outcome.failureMessage {
            resultFailure = failure
            // A failed run is not a run that did not happen. It stopped part way through, so
            // the document underneath is no longer the one the plan was previewed against —
            // and the plan survived, with Apply live again the instant `isRunning` went false,
            // over pages the failed run had already written to. Dropping it forces the same
            // Preview-then-Apply the first attempt went through. Finding CR-182.
            needsFreshPreview = true
            self.plan = nil
            return
        }
        if outcome.wasCancelled {
            resultSentence = outcome.completionSentence
        } else {
            onClose?()
        }
    }

    /// Cancels the running batch.
    public func cancel() {
        guard isRunning else {
            onClose?()
            return
        }
        onCancel?()
    }

    /// The sentence for a run that placed fewer than its plan previewed, or `nil` when it did
    /// not. Pages the run skipped because they already carried the item count as accounted for.
    static func shortfallSentence(plan: BatchApplyPlan, outcome: BatchApplyReceipt) -> String? {
        guard !outcome.wasCancelled, outcome.failureMessage == nil else { return nil }
        let included = Set(plan.includedPages.map(\.id))
        let skippedIncluded = outcome.skippedPageIDs.filter(included.contains).count
        let accounted = outcome.placementCount + skippedIncluded
        guard accounted < plan.placementCount else { return nil }
        let missing = plan.placementCount - accounted
        if outcome.placementCount == 0 {
            return String(
                format: NSLocalizedString(
                    "Nothing was placed. The preview counted %d, but none could be placed. Preview again to see what the pages hold now.",
                    comment: "Batch apply: a run placed nothing although the plan counted some. %d is the previewed count"
                ),
                plan.placementCount
            )
        }
        return String(
            format: NSLocalizedString(
                "Placed %1$d of the %2$d previewed; %3$d could not be placed. One Undo removes the ones that were. Preview again to see what the pages hold now.",
                comment: "Batch apply: a run placed fewer than previewed. 1: placed, 2: previewed, 3: missing"
            ),
            outcome.placementCount,
            plan.placementCount,
            missing
        )
    }

    /// Records a progress report from the running batch.
    ///
    /// A late report from a batch that has already finished is dropped, so a cancelled run
    /// cannot be resurrected to 60 % by a report that was in flight when Cancel was pressed.
    public func report(fraction: Double?, detail: String) {
        guard isRunning else { return }
        progressFraction = fraction.map { min(1, max(0, $0)) }
        progressDetail = detail
    }

    /// Drops the plan whenever a choice changes.
    ///
    /// The preview and the run must describe the same batch. Keeping a stale plan after the
    /// scope changed is precisely how a person previews 12 and applies 312.
    private func invalidatePlan() {
        guard !isRunning else { return }
        plan = nil
        // What the last run did is about the choices as they were, and the preview scheduled
        // below is the fresh count a short or failed run asked for.
        resultSentence = nil
        resultIsShortfall = false
        resultFailure = nil
        needsFreshPreview = false
        // A resolution in flight answers the choices as they were, so it is abandoned with
        // them. The coalesced `preview()` scheduled below starts a fresh one.
        cancelResolution()
        schedulePreview()
    }

    /// Schedules one preview for when the choices have sat still for ``previewCoalescing``.
    ///
    /// The sheet used to re-preview through one `onChange` per field, and three fields had
    /// none — so a navigator selection that changed while the sheet was open dropped the plan
    /// to "Choose a scope…" with Apply dead until an unrelated control was touched. Findings
    /// BH-830, IM-144. The model now re-previews itself for every choice, host-driven or typed.
    private func schedulePreview() {
        previewTask?.cancel()
        let delay = previewCoalescing
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isRunning else { return }
            self.previewTask = nil
            self.preview()
        }
    }
}

/// The batch choices as a plain value, so the host can build its own request without the
/// model having to know the engine's vocabulary.
public struct BatchApplyRequestValues: Hashable, Sendable {

    /// Which pages.
    public var scope: BatchPageScope
    /// Where on each of them.
    public var anchor: BatchAnchor
    /// Whether to skip pages that already carry the same thing.
    public var skipPagesAlreadyCarrying: Bool
    /// The text a prompted stamp field takes.
    public var promptedText: String
    /// The pages a search scope resolved to, or `nil` when the scope is not a search or the
    /// search has not answered. The host passes this straight through to the planner.
    public var searchMatchedPageIDs: Set<UUID>?

    /// Creates request values.
    public init(
        scope: BatchPageScope,
        anchor: BatchAnchor,
        skipPagesAlreadyCarrying: Bool,
        promptedText: String,
        searchMatchedPageIDs: Set<UUID>? = nil
    ) {
        self.scope = scope
        self.anchor = anchor
        self.skipPagesAlreadyCarrying = skipPagesAlreadyCarrying
        self.promptedText = promptedText
        self.searchMatchedPageIDs = searchMatchedPageIDs
    }
}
