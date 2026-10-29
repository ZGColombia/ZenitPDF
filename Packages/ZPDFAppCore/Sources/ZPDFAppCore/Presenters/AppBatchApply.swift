import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// What a scoped batch apply places on each page it touches.
///
/// This must be the general mechanism with stamps as its first client, not a stamp special
/// case, because the same machinery is what batch headers, footers, page numbers and revision
/// clouds will need. So the engine below knows
/// nothing about stamps: it resolves a scope, anchors a point per page, asks a producer for
/// a record, and commits the lot as one step. Everything stamp-shaped is in
/// ``StampBatchProducer``.
public protocol BatchPageItemProducing: Sendable {

    /// What the Edit menu says after "Undo", for example "Batch Stamp".
    var actionName: String { get }

    /// What one placement is, as a count phrase ("1 stamp", "3 stamps") for the preview and
    /// the progress line (V-075: it was a bare "stamp(s)").
    var itemNoun: BatchItemNoun { get }

    /// The name of the specific thing being placed, for example the preset's name.
    var itemName: String { get }

    /// The extent of one placement in PDF points, which the anchor uses to keep the whole
    /// of it inside the page inset rather than half of it hanging off the sheet.
    var placementSize: PDFSizeValue { get }

    /// Whether an existing markup counts as "this page already carries the same thing".
    ///
    /// The skip rule's only question, asked of the *summary* because that is what a
    /// snapshot carries and a preview must be answerable without touching the session.
    /// Identity is the producer's business rather than the engine's: two stamps are the
    /// same when they came from the same template, two page numbers when they sit in the
    /// same corner.
    func matchesExisting(_ markup: ZPDFUIPresentation.MarkupSummary) -> Bool

    /// The record to place on one page, or `nil` when this page cannot take one.
    ///
    /// - Parameters:
    ///   - page: the page, so a producer can resolve per-page content — a stamp's page
    ///     label is resolved here and frozen, which is the stamp rule the batch has to honour
    ///     312 times rather than once.
    ///   - position: the page's zero-based place in the set order, what a sheet number counts.
    ///     Not `page.index`, which is the page's index in its own PDF (ADR-0022): a combined
    ///     two-drawing set restarts it for the second drawing, and a reordered set keeps it.
    ///   - point: the anchored page-space point, already resolved against this page's box.
    ///   - documentID: the owning document.
    ///   - identifier: the identity to mint the record with, supplied so a test can make
    ///     a batch reproducible.
    ///
    /// `@MainActor` because record construction reaches the same geometry and style
    /// helpers the Draw path uses, and those are main-actor state. The batch loop yields
    /// between pages so a thousand of these do not hold the main thread in one stretch.
    @MainActor
    func record(
        forPage page: ZPDFUIPresentation.PageDescriptor,
        position: Int,
        at point: PDFPointValue,
        documentID: DocumentID,
        identifier: UUID
    ) -> MarkupRecord?
}

/// What the person chose in the batch sheet.
public struct BatchApplyRequest: Sendable {

    /// Which pages.
    public var scope: BatchPageScope
    /// Where on each of them.
    public var anchor: BatchAnchor
    /// Whether to skip a page that already carries the same thing.
    public var skipPagesAlreadyCarrying: Bool
    /// Page identifiers a text search matched, for ``BatchPageScope/matchingSearchTerm(_:)``.
    ///
    /// Supplied by the caller rather than looked up here: the search index is an actor with
    /// its own lifecycle and its own consent rules, and a planner that reached into it would
    /// make previewing a scope an operation that can fail, hang, or trigger OCR. `nil` means
    /// the search has not run, and a search scope then matches nothing and says so.
    public var searchMatchedPageIDs: Set<UUID>?

    /// Creates a request.
    public init(
        scope: BatchPageScope,
        anchor: BatchAnchor,
        skipPagesAlreadyCarrying: Bool = true,
        searchMatchedPageIDs: Set<UUID>? = nil
    ) {
        self.scope = scope
        self.anchor = anchor
        self.skipPagesAlreadyCarrying = skipPagesAlreadyCarrying
        self.searchMatchedPageIDs = searchMatchedPageIDs
    }
}

/// The scoped batch apply.
///
/// # The five promises, and where each one is kept
///
/// | Promise | Kept by |
/// |---|---|
/// | The scope is previewed before anything happens | ``planBatchApply(_:request:)`` returns a `BatchApplyPlan` and mutates nothing; the run takes that same plan as input, so the sentence and the outcome cannot disagree |
/// | Position is anchored per page, not absolute | `BatchPlacementGeometry.anchorPoint(in:rotation:anchor:size:)`, called once per page with **that page's** box |
/// | One undo removes all of them | one ``DocumentCommandBus/performBatch(_:actionName:)``, one merged inverse, one `UndoManager` registration |
/// | One audit group, expandable to the rows | ``AppHistoryPresenter/recordAppliedBatch(_:actionName:snapshot:)`` — one `undo_group`, one entry per markup |
/// | Bounded, cancellable, all-or-none | every record is built **before** the commit, with a `Task.isCancelled` check per page; cancelling returns before the single atomic `performBatch`, so nothing was written |
extension AppCoreEnvironment {

    /// Works out what a batch *would* do, without doing any of it.
    ///
    /// Pure with respect to the document: it reads the snapshot and returns a plan. Nothing
    /// in this method can change a markup, which is the property that makes it safe to call
    /// on every keystroke in the scope picker.
    public func planBatchApply(
        _ producer: some BatchPageItemProducing,
        request: BatchApplyRequest
    ) -> BatchApplyPlan {
        let inScope = Self.pageIDsInScope(request: request, pages: snapshot.pages)
        // One pass over the markups rather than one filter per page: a 1 000-page set with
        // 50 000 markups would otherwise be 50 million comparisons to preview a scope.
        var pagesAlreadyCarrying: Set<UUID> = []
        if request.skipPagesAlreadyCarrying {
            for markup in snapshot.markups where producer.matchesExisting(markup) {
                pagesAlreadyCarrying.insert(markup.pageID)
            }
        }

        let decisions = snapshot.pages.map { page -> BatchPageDecision in
            guard inScope.contains(page.id) else {
                return BatchPageDecision(
                    id: page.id, index: page.index, label: page.label, verdict: .outOfScope
                )
            }
            if pagesAlreadyCarrying.contains(page.id) {
                return BatchPageDecision(
                    id: page.id,
                    index: page.index,
                    label: page.label,
                    verdict: .skippedAlreadyPresent
                )
            }
            return BatchPageDecision(
                id: page.id,
                index: page.index,
                label: page.label,
                verdict: .included,
                anchorPoint: BatchPlacementGeometry.anchorPoint(
                    in: page.visibleBox,
                    rotation: page.rotation,
                    anchor: request.anchor,
                    size: producer.placementSize
                )
            )
        }

        return BatchApplyPlan(
            scope: request.scope,
            anchor: request.anchor,
            skipsPagesAlreadyCarrying: request.skipPagesAlreadyCarrying,
            decisions: decisions,
            itemNoun: producer.itemNoun,
            itemName: producer.itemName
        )
    }

    /// Runs a batch that was already planned.
    ///
    /// - Parameters:
    ///   - producer: what to place.
    ///   - plan: the plan the person was shown. Passing the plan rather than re-deriving it
    ///     is the point: a run that recomputed its own scope could place a different number
    ///     of items than the preview promised.
    ///   - progress: reports one unit per page while records are built, then one final
    ///     report. The commit itself is atomic and reports no intermediate fraction, because
    ///     there is no intermediate state to report — see below.
    /// - Returns: a receipt naming every markup created and every page skipped.
    ///
    /// # Why cancellation is all-or-none for free
    ///
    /// The expensive part of a 1 000-page batch is building 1 000 records: resolving a page
    /// label, resolving a stamp's fields, anchoring a point. That loop checks
    /// `Task.isCancelled` on every page and returns ``BatchApplyReceipt/cancelled`` without
    /// having touched the document. The commit that follows is a single
    /// ``TakeoffSession/applyBatch(_:)``, which is already atomic — a command that throws
    /// rolls the whole batch back. So there is no window in which half a batch exists, and
    /// the guarantee is a consequence of the shape rather than a promise the code has to
    /// keep by hand.
    @discardableResult
    public func runBatchApply(
        _ producer: some BatchPageItemProducing,
        plan: BatchApplyPlan,
        progress: ProgressSink = ProgressSink()
    ) async -> BatchApplyReceipt {
        let pages = plan.includedPages
        let skipped = plan.skippedPages.map(\.id)
        guard !pages.isEmpty else {
            progress(.completed)
            return BatchApplyReceipt(skippedPageIDs: skipped)
        }

        let descriptors = Dictionary(
            snapshot.pages.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Each sheet's place in the set: `snapshot.pages` is in set order (ADR-0022), so this
        // is what `{n}` counts — not the PDF page index, which restarts per drawing (W-026).
        let positions = Dictionary(
            snapshot.pages.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let documentID = DocumentID(snapshot.documentID)

        var commands: [DocumentCommand] = []
        var createdIDs: [UUID] = []
        commands.reserveCapacity(pages.count)
        createdIDs.reserveCapacity(pages.count)

        for (offset, decision) in pages.enumerated() {
            if Task.isCancelled {
                progress(.cancelled)
                return .cancelled
            }
            guard let page = descriptors[decision.id], let position = positions[decision.id],
                  let point = decision.anchorPoint else {
                continue
            }
            let identifier = UUID()
            guard let record = producer.record(
                forPage: page,
                position: position,
                at: point,
                documentID: documentID,
                identifier: identifier
            ) else { continue }
            commands.append(.addMarkup(record))
            createdIDs.append(record.id.rawValue)

            // A report per page would be a main-actor hop per page. Twenty reports is
            // enough for a progress bar to look alive and cheap enough not to be the
            // reason a 1 000-page batch is slow.
            let stride = max(1, pages.count / 20)
            if offset % stride == 0 {
                progress(.counting(
                    offset,
                    of: pages.count,
                    stage: .working,
                    detail: plan.itemNoun.progressDetail(offset, of: pages.count)
                ))
                // Records are built on the main actor because the geometry and style
                // helpers live there. Yielding at every progress step hands the run loop
                // back, so a 1 000-page batch draws its progress bar and answers Cancel
                // instead of presenting a beach ball: a long batch must never freeze the
                // application.
                await Task.yield()
            }
        }

        if Task.isCancelled {
            progress(.cancelled)
            return .cancelled
        }
        guard !commands.isEmpty else {
            progress(.completed)
            return BatchApplyReceipt(skippedPageIDs: skipped)
        }

        progress(OperationProgress(
            stage: .finishing,
            fraction: 1,
            completedUnits: commands.count,
            totalUnits: commands.count,
            detail: plan.itemNoun.progressDetail(commands.count, of: commands.count)
        ))

        do {
            _ = try await commands_performBatch(commands, actionName: producer.actionName)
        } catch {
            progress(OperationProgress(stage: .failed, detail: String(describing: error)))
            return BatchApplyReceipt(
                skippedPageIDs: skipped,
                failureMessage: String(
                    format: NSLocalizedString(
                        "The batch was refused and nothing was placed: %@",
                        comment: "Batch apply failure. %@ is the reason"
                    ),
                    String(describing: error)
                )
            )
        }

        progress(.completed)
        await refresh()
        return BatchApplyReceipt(
            createdMarkupIDs: createdIDs,
            skippedPageIDs: skipped,
            auditGroup: history.lastBatchAuditGroup
        )
    }

    /// The bus call, named apart so the long method above reads as one story.
    private func commands_performBatch(
        _ list: [DocumentCommand],
        actionName: String
    ) async throws -> DocumentBatchOutcome? {
        try await commands.performBatch(list, actionName: actionName)
    }

    /// The page identifiers a scope selects, resolved against the snapshot's own pages.
    ///
    /// `static` and taking its pages as a parameter, so every scope rule is testable without
    /// a session — including the two that are easy to get wrong: a range is one-based and
    /// clamped, and a size match ignores orientation. `pages` are in set order, as the snapshot
    /// holds them; a range counts positions in it.
    public static func pageIDsInScope(
        request: BatchApplyRequest,
        pages: [ZPDFUIPresentation.PageDescriptor]
    ) -> Set<UUID> {
        switch request.scope {
        case .allPages:
            return Set(pages.map(\.id))

        case .pageRange(let from, let through):
            // One-based, inclusive, and clamped rather than refused: "1 to 9999" on a
            // 312-page set means the whole set, and the preview says 312.
            //
            // Positions in the set, as the sheet seeds the range (`through` = the set's sheet
            // count), not the page's index in its own PDF (U-035, ADR-0022). The index restarts
            // for each drawing and survives a reorder: "Pages 11 to 15" of a 10 + 5 two-drawing
            // set selected nothing, "Pages 1 to 5" selected ten sheets, and after a reorder the
            // range stamped PDF pages rather than the sheets standing there.
            let lower = max(1, min(from, through))
            let upper = max(from, through)
            return Set(pages.enumerated().filter { $0.offset + 1 >= lower && $0.offset + 1 <= upper }.map(\.element.id))

        case .matchingSize(let width, let height, let tolerance):
            let target = (min(width, height), max(width, height))
            return Set(pages.filter { page in
                // Orientation-insensitive: a landscape A1 and a portrait A1 are the same
                // paper, and an estimator who picks "A1" means both of them.
                let size = page.rotatedVisibleSize
                let candidate = (min(size.width, size.height), max(size.width, size.height))
                return abs(candidate.0 - target.0) <= tolerance
                    && abs(candidate.1 - target.1) <= tolerance
            }.map(\.id))

        case .matchingSearchTerm:
            // `nil` means the search has not run. Matching nothing, loudly, is better than
            // matching everything: the preview then says "no page matches this scope", and
            // an empty batch is the safe reading of an unanswered question.
            guard let matched = request.searchMatchedPageIDs else { return [] }
            return Set(pages.map(\.id)).intersection(matched)

        case .navigatorSelection(let ids):
            return Set(pages.map(\.id)).intersection(ids)
        }
    }
}
