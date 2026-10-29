import Foundation

/// Which pages a scoped batch apply touches.
///
/// The five scopes, as a closed value. It is deliberately *not* a stamp concept: the same
/// scope drives batch headers, footers, page numbers and revision clouds, which is why this
/// is a scoped batch apply rather than a batch stamper.
public enum BatchPageScope: Hashable, Sendable, Codable {

    /// Every page of the document.
    case allPages

    /// A one-based inclusive range of page positions, as the person typed it.
    ///
    /// Positions, not indices, and not page labels: "5 to 12" means the fifth to the
    /// twelfth sheet. A range that runs off either end is clamped rather than refused,
    /// and the preview says how many pages actually matched.
    case pageRange(from: Int, through: Int)

    /// Pages whose visible box matches a size, within a tolerance in PDF points.
    ///
    /// The scope that exists because a drawing set is not one size. Orientation is
    /// ignored: an A1 landscape sheet and an A1 portrait sheet are the same size of paper
    /// and an estimator who picks "A1" means both.
    case matchingSize(widthPoints: Double, heightPoints: Double, tolerancePoints: Double)

    /// Pages whose text contains a search term.
    case matchingSearchTerm(String)

    /// The pages currently selected in the navigator.
    case navigatorSelection([UUID])

    /// A localized name for the scope row.
    public var displayName: String {
        switch self {
        case .allPages:
            return NSLocalizedString("All pages", comment: "Batch apply scope")
        case .pageRange(let from, let through):
            let format = NSLocalizedString(
                "Pages %1$d to %2$d", comment: "Batch apply scope: a page range"
            )
            return String(format: format, from, through)
        case .matchingSize(let width, let height, _):
            let format = NSLocalizedString(
                "Pages %1$d × %2$d pt", comment: "Batch apply scope: pages matching a size"
            )
            // BH-268: `Int(_:)` traps on a non-finite or out-of-range Double, and the
            // width/height come from a free text field.
            return String(format: format, BatchDisplayInteger.clamped(width), BatchDisplayInteger.clamped(height))
        case .matchingSearchTerm(let term):
            let format = NSLocalizedString(
                "Pages containing “%@”", comment: "Batch apply scope: pages matching a search term"
            )
            return String(format: format, term)
        case .navigatorSelection(let ids):
            let format = NSLocalizedString(
                "Navigator selection (%d)", comment: "Batch apply scope: the navigator selection"
            )
            return String(format: format, ids.count)
        }
    }
}

/// What a search-term scope actually resolved to.
///
/// ``BatchPageScope/matchingSearchTerm(_:)`` was reachable and inert for as long as nothing
/// filled it in: the sheet offered "Pages containing text", the person typed a term, and
/// the scope selected no pages while the preview said so in a way that read as *"there are
/// none"* rather than *"nobody looked"*. This value is the answer to the question, and it
/// carries the qualifications that make the answer checkable rather than merely numeric.
public struct BatchSearchScopeResolution: Hashable, Sendable {

    /// The term this resolution answers, trimmed exactly as it was searched.
    ///
    /// Carried so a stale answer cannot be shown against a newer term: a resolution whose
    /// term is not the term in the field is discarded rather than displayed.
    public var term: String

    /// The pages whose text contains the term.
    public var pageIDs: Set<UUID>

    /// `true` when the search stopped at its own result ceiling, so more pages may match.
    ///
    /// A count that might be short is still worth showing, but only alongside the fact that
    /// it might be short — an estimator who sees "18 pages" and applies is entitled to know
    /// the number was not capped.
    public var wasTruncated: Bool

    /// `true` when at least one page qualified only through recognised text.
    ///
    /// Recognition is a search aid, not a certified transcription, and a batch that stamps
    /// a sheet because a recogniser thought a smudge said `FIRE` is exactly the mistake
    /// this preview exists to prevent.
    public var includesRecognisedText: Bool

    /// Words the person put after a `NOT` the text index cannot run — a leading `NOT`, or
    /// `NOT` after `OR` — as they typed them, empty when every exclusion was run.
    ///
    /// The query compiler leaves such a word out rather than searching for it (U-081), so
    /// `PLAN OR NOT DEMOLITION` counts the PLAN pages and `NOT DEMOLITION` counts none. Both
    /// are honest counts of what was searched, and both read as a count with the exclusion
    /// applied unless the sheet says it was not.
    public var droppedExclusions: [String]

    /// Why no answer could be given, when none could — an index that is not open, for
    /// instance. `nil` when ``pageIDs`` is a real answer, including a real answer of none.
    public var unavailableReason: String?

    /// Creates a resolution.
    public init(
        term: String,
        pageIDs: Set<UUID> = [],
        wasTruncated: Bool = false,
        includesRecognisedText: Bool = false,
        droppedExclusions: [String] = [],
        unavailableReason: String? = nil
    ) {
        self.term = term
        self.pageIDs = pageIDs
        self.wasTruncated = wasTruncated
        self.includesRecognisedText = includesRecognisedText
        self.droppedExclusions = droppedExclusions
        self.unavailableReason = unavailableReason
    }

    /// A resolution that could not be computed, which is not the same fact as "no page
    /// matched" and must never be rendered as if it were.
    public static func unavailable(term: String, reason: String) -> BatchSearchScopeResolution {
        BatchSearchScopeResolution(term: term, unavailableReason: reason)
    }

    /// Whether an answer exists at all.
    public var isAvailable: Bool { unavailableReason == nil }

    /// What qualifies the count, or `nil` when nothing needs qualifying.
    ///
    /// A dropped exclusion comes first: it changes which question the count answers, where a
    /// capped search or a recognised match only qualifies how complete or how certain the
    /// answer is. It is followed by the cap, or failing that the recognised-text note, so a
    /// count that answers a different question and may also be short says both.
    public var cautionSentence: String? {
        if let unavailableReason { return unavailableReason }
        var sentences: [String] = []
        if !droppedExclusions.isEmpty {
            sentences.append(SearchExclusionNote.text(for: droppedExclusions) + ".")
        }
        if wasTruncated {
            let format = NSLocalizedString(
                "The search stopped at its result limit, so more pages may contain \u{201C}%@\u{201D}.",
                comment: "Batch apply search scope caution. %@ is the search term"
            )
            sentences.append(String(format: format, term))
        } else if includesRecognisedText {
            sentences.append(NSLocalizedString(
                "Some of these pages matched on recognised text, which is a search aid rather than a certified transcription.",
                comment: "Batch apply search scope caution when OCR contributed matches"
            ))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

/// Which corner of a page an anchored placement measures its inset from.
public enum BatchAnchorCorner: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {

    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var id: String { rawValue }

    /// A localized name for the position picker.
    public var displayName: String {
        switch self {
        case .topLeft: return NSLocalizedString("Top left", comment: "Batch apply anchor corner")
        case .topRight: return NSLocalizedString("Top right", comment: "Batch apply anchor corner")
        case .bottomLeft: return NSLocalizedString("Bottom left", comment: "Batch apply anchor corner")
        case .bottomRight: return NSLocalizedString("Bottom right", comment: "Batch apply anchor corner")
        }
    }
}

/// Where a batch places its markup on each page.
///
/// Anchoring is the part a naive implementation gets wrong. The naive implementation takes the point the person clicked on the sheet they were
/// looking at and writes it into every page. On a set that mixes A1 title sheets with A3
/// details — which is most sets — that point is in the bottom corner of one sheet and in
/// the middle of the drawing on the next. An anchor is resolved **per page, against that
/// page's own visible box**, which is the only formulation that survives a mixed set.
public enum BatchAnchor: Hashable, Sendable, Codable {

    /// A corner of the page's visible box, with an inset measured inwards from that corner
    /// in PDF points.
    case corner(BatchAnchorCorner, insetX: Double, insetY: Double)

    /// The centre of the page's visible box.
    case centered

    /// A localized name for the position row.
    public var displayName: String {
        switch self {
        case .corner(let corner, let insetX, let insetY):
            let format = NSLocalizedString(
                "%1$@, inset %2$d × %3$d pt",
                comment: "Batch apply position: a corner with an inset"
            )
            // BH-763: the insets come from free text fields; never trap on 1e22 or infinity.
            return String(
                format: format, corner.displayName,
                BatchDisplayInteger.clamped(insetX), BatchDisplayInteger.clamped(insetY)
            )
        case .centered:
            return NSLocalizedString("Centred", comment: "Batch apply position")
        }
    }
}

/// Resolving an anchor into a page-space point, per page.
///
/// Pure arithmetic over one page's box and one placement's size, kept out of every actor
/// so the rule that matters most can be tested on its own: "a bottom-right anchor
/// with a 36-point inset lands 36 points from the right edge of *this* page, whatever size
/// this page is."
public enum BatchPlacementGeometry {

    /// The page-space point a placement of the given size anchors at.
    ///
    /// - Parameters:
    ///   - box: the page's visible box, in page space.
    ///   - rotation: the page's explicit rotation. A corner is what the estimator *sees*,
    ///     so "top right" on a page rotated 90° clockwise is the page-space corner that
    ///     appears at the top right once the rotation is applied — not the page-space top
    ///     right, which is somewhere else on screen.
    ///   - anchor: the anchor to resolve.
    ///   - size: the placement's own extent, so the returned point is its **centre** and
    ///     the whole of it lands inside the inset rather than half of it hanging off.
    /// - Returns: the centre point of the placement, in page space.
    public static func anchorPoint(
        in box: PDFRectValue,
        rotation: PageRotation = .degrees0,
        anchor: BatchAnchor,
        size: PDFSizeValue
    ) -> PDFPointValue {
        switch anchor {
        case .centered:
            return box.center
        case .corner(let corner, let insetX, let insetY):
            let pageCorner = pageSpaceCorner(of: corner, rotation: rotation)
            // `size` is the placement's extent **in page space**. A batch-placed stamp is
            // written with the template's own rotation (0), not counter-rotated against the
            // page, so it turns with the page and its page-space box keeps width along x and
            // height along y whatever the page's /Rotate. Swapping the extent here (the old
            // code) put the centre 30 pt too far along x on a 90° page — a 100 × 40 stamp
            // anchored top-right with a 20 × 10 inset hung 20 pt off the sheet. BH-051.
            let halfWidth = size.width / 2
            let halfHeight = size.height / 2
            // The inset is measured in the direction the estimator means, so it swaps with
            // the axes for the same reason the extent does.
            let inX = rotation.swapsAxes ? insetY : insetX
            let inY = rotation.swapsAxes ? insetX : insetY

            let x: Double
            switch pageCorner.isRight {
            case true: x = box.maxX - inX - halfWidth
            case false: x = box.minX + inX + halfWidth
            }
            let y: Double
            switch pageCorner.isTop {
            case true: y = box.maxY - inY - halfHeight
            case false: y = box.minY + inY + halfHeight
            }
            return PDFPointValue(x: x, y: y)
        }
    }

    /// Which page-space corner the estimator's visual corner is, once rotation is applied.
    ///
    /// A page rotated 90° clockwise for display means the page-space content is turned
    /// clockwise on screen, so the corner the estimator calls "top right" is the page-space
    /// corner that rotation moves there — bottom right for 90°, bottom left for 180°, and
    /// so on around the cycle.
    static func pageSpaceCorner(
        of corner: BatchAnchorCorner,
        rotation: PageRotation
    ) -> (isTop: Bool, isRight: Bool) {
        let order: [BatchAnchorCorner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        guard let position = order.firstIndex(of: corner) else { return (true, false) }
        let quarterTurns = ((rotation.rawValue / 90) % 4 + 4) % 4
        // Turning the displayed page clockwise by n quarter turns means the visual corner
        // came from n quarter turns counter-clockwise around the page-space cycle.
        let source = order[(position - quarterTurns + 4 * 4) % 4]
        switch source {
        case .topLeft: return (true, false)
        case .topRight: return (true, true)
        case .bottomRight: return (false, true)
        case .bottomLeft: return (false, false)
        }
    }
}

/// One page's verdict in a batch plan.
public struct BatchPageDecision: Hashable, Sendable, Identifiable {

    /// Why a page is or is not in the batch.
    public enum Verdict: String, Hashable, Sendable, Codable {
        /// In scope, and nothing on the page blocks it.
        case included
        /// In scope, but the page already carries the same thing and the skip rule is on.
        case skippedAlreadyPresent
        /// Not in scope.
        case outOfScope
    }

    /// The page.
    public let id: UUID
    /// Its zero-based position.
    public var index: Int
    /// Its label, which is what the preview lists.
    public var label: String
    /// The verdict.
    public var verdict: Verdict
    /// Where the placement would land on this page, for an included page.
    public var anchorPoint: PDFPointValue?

    /// Creates a decision.
    public init(
        id: UUID,
        index: Int,
        label: String,
        verdict: Verdict,
        anchorPoint: PDFPointValue? = nil
    ) {
        self.id = id
        self.index = index
        self.label = label
        self.verdict = verdict
        self.anchorPoint = anchorPoint
    }
}

/// What a batch places, as a count phrase that reads right for every count: "1 stamp",
/// "312 stamps".
///
/// It replaces a bare noun such as "stamp(s)", which the preview printed after the count
/// whatever the count was (V-075). The rule is `Plurals.stringsdict`'s under ``pluralKey``,
/// with ``one`` and ``other`` as the English fallback ``LocalizedPlural`` uses when the bundle
/// has no rule.
public struct BatchItemNoun: Hashable, Sendable {

    /// The `Plurals.stringsdict` key: the English plural format, for example `"%lld stamps"`.
    public var pluralKey: String
    /// The localised singular format, with one `%lld`.
    public var one: String
    /// The localised plural format, with one `%lld`.
    public var other: String

    /// Creates a noun from its plural key and its two English formats.
    public init(pluralKey: String, one: String, other: String) {
        self.pluralKey = pluralKey
        self.one = one
        self.other = other
    }

    /// "1 stamp", "3 stamps".
    public func phrase(count: Int, bundle: Bundle = .main) -> String {
        LocalizedPlural.string(pluralKey, count: count, one: one, other: other, bundle: bundle)
    }

    /// The batch's progress line: "Preparing 3 of 10 stamps", "Preparing 1 of 1 stamp". It
    /// read "Preparing 1 of 1 stamp(s)" (V-075).
    public func progressDetail(_ done: Int, of total: Int) -> String {
        let format = NSLocalizedString(
            "Preparing %1$d of %2$@",
            comment: "Batch apply progress. 1: done, 2: the total, as \"10 stamps\""
        )
        return String(format: format, done, phrase(count: total))
    }

    /// Stamps, for the batch stamp.
    public static var stamp: BatchItemNoun {
        BatchItemNoun(
            pluralKey: "%lld stamps",
            one: NSLocalizedString("%lld stamp", comment: "Batch apply: a count of stamps, singular"),
            other: NSLocalizedString("%lld stamps", comment: "Batch apply: a count of stamps, plural")
        )
    }

    /// Lines of text, for the batch header and footer.
    public static var lineOfText: BatchItemNoun {
        BatchItemNoun(
            pluralKey: "%lld lines of text",
            one: NSLocalizedString("%lld line of text", comment: "Batch apply: a count of header or footer lines, singular"),
            other: NSLocalizedString("%lld lines of text", comment: "Batch apply: a count of header or footer lines, plural")
        )
    }

    /// "1 page", "5 pages": the page counts the preview sentences end on.
    static func pages(_ count: Int, bundle: Bundle = .main) -> String {
        LocalizedPlural.string(
            "%lld pages",
            count: count,
            one: NSLocalizedString("%lld page", comment: "A count of pages, singular"),
            other: NSLocalizedString("%lld pages", comment: "A count of pages, plural"),
            bundle: bundle
        )
    }
}

/// What a scoped batch apply *would* do, computed before anything happens.
///
/// The scope is previewed — *"this will place 312 stamps on 312 pages"* — before the batch
/// runs. The plan is that preview, and it is also the batch's
/// input: the run applies exactly the decisions the person was shown, so the sentence and
/// the outcome cannot disagree.
public struct BatchApplyPlan: Hashable, Sendable {

    /// The scope this plan was computed for.
    public var scope: BatchPageScope
    /// The position each placement anchors at.
    public var anchor: BatchAnchor
    /// Whether pages that already carry the same thing were skipped.
    public var skipsPagesAlreadyCarrying: Bool
    /// Every page of the document, with its verdict, in document order.
    public var decisions: [BatchPageDecision]
    /// What is being placed, as a count phrase: "1 stamp", "312 stamps".
    public var itemNoun: BatchItemNoun
    /// The name of the thing being placed, for example the preset's name.
    public var itemName: String

    /// Creates a plan.
    public init(
        scope: BatchPageScope,
        anchor: BatchAnchor,
        skipsPagesAlreadyCarrying: Bool,
        decisions: [BatchPageDecision],
        itemNoun: BatchItemNoun,
        itemName: String
    ) {
        self.scope = scope
        self.anchor = anchor
        self.skipsPagesAlreadyCarrying = skipsPagesAlreadyCarrying
        self.decisions = decisions
        self.itemNoun = itemNoun
        self.itemName = itemName
    }

    /// The pages that will be written to, in document order.
    public var includedPages: [BatchPageDecision] {
        decisions.filter { $0.verdict == .included }
    }

    /// The pages that are in scope but already carry the same thing.
    public var skippedPages: [BatchPageDecision] {
        decisions.filter { $0.verdict == .skippedAlreadyPresent }
    }

    /// How many placements the batch will make.
    public var placementCount: Int { includedPages.count }

    /// How many pages the batch will skip.
    public var skippedCount: Int { skippedPages.count }

    /// How many pages the document has.
    public var totalPageCount: Int { decisions.count }

    /// How many pages the scope selected, before the skip rule took any of them out.
    ///
    /// Distinct from ``placementCount`` on purpose. "The scope found 20 pages, 2 of which
    /// already carry it, so 18 will be stamped" is three numbers, and a preview that shows
    /// one of them cannot be checked against what the person believes they chose.
    public var inScopeCount: Int {
        decisions.reduce(into: 0) { total, decision in
            if decision.verdict != .outOfScope { total += 1 }
        }
    }

    /// Whether the batch would do nothing at all.
    public var isEmpty: Bool { placementCount == 0 }

    /// The scope, restated in words the person can check against what they chose.
    ///
    /// The preview *is* the safety mechanism for this feature, and a preview that only
    /// gives a number is one the person has to take on trust: "18" is as consistent with
    /// "18 pages contain FIRE" as it is with "the scope silently fell back to something
    /// else and 18 is a coincidence". So the sentence names the scope and the two counts
    /// that bound it — "Scope: Pages containing \u{201C}FIRE\u{201D} \u{2014} 18 of 312 pages." — and it says
    /// the same thing when the answer is none.
    public var scopeSentence: String {
        let format = NSLocalizedString(
            "Scope: %1$@ \u{2014} %2$d of %3$@.",
            comment: "Batch apply scope restatement. 1: the scope, 2: pages in scope, 3: pages in document, as \"6 pages\""
        )
        return String(format: format, scope.displayName, inScopeCount, BatchItemNoun.pages(totalPageCount))
    }

    /// The sentence shown before the batch runs.
    ///
    /// Deliberately counted twice — placements and pages — because they are the same
    /// number here and will not be for a batch that places more than one item per page,
    /// and a preview that quietly conflates the two is a preview nobody can check.
    public var previewSentence: String {
        guard placementCount > 0 else {
            // Two different noughts, and conflating them is how a person concludes their
            // search term was wrong when in fact every matching page already carried the
            // stamp — or the other way round.
            if inScopeCount > 0 {
                // "All 1 pages" was the singular of this sentence (V-075).
                return LocalizedPlural.string(
                    "All %lld pages in scope already carry “%@”, so nothing will be placed.",
                    count: inScopeCount,
                    one: NSLocalizedString(
                        "The %1$lld page in scope already carries “%2$@”, so nothing will be placed.",
                        comment: "Batch apply preview when the one page in scope is skipped. 1: 1, 2: the item's name"
                    ),
                    other: NSLocalizedString(
                        "All %1$lld pages in scope already carry “%2$@”, so nothing will be placed.",
                        comment: "Batch apply preview when every page in scope is skipped. 1: pages in scope, 2: the item's name"
                    ),
                    arguments: [itemName]
                )
            }
            return NSLocalizedString(
                "No page matches this scope, so nothing will be placed.",
                comment: "Batch apply preview when the scope selects nothing"
            )
        }
        let format = NSLocalizedString(
            "This will place %1$@ on %2$d of %3$@.",
            comment: "Batch apply preview. 1: placements, as \"3 stamps\", 2: pages written, 3: pages in document, as \"6 pages\""
        )
        return String(
            format: format,
            itemNoun.phrase(count: placementCount),
            includedPages.count,
            BatchItemNoun.pages(totalPageCount)
        )
    }

    /// The sentence that reports what will be skipped, or `nil` when nothing is.
    ///
    /// The skip is *reported* rather than silent, and reporting it before
    /// the run is worth more than reporting it after: a person who did not expect eight
    /// skips can change the rule instead of undoing the batch.
    public var skipSentence: String? {
        guard skippedCount > 0 else { return nil }
        return LocalizedPlural.string(
            "%lld pages already carry “%@” and will be skipped.",
            count: skippedCount,
            one: NSLocalizedString(
                "%1$lld page already carries “%2$@” and will be skipped.",
                comment: "Batch apply preview, one page skipped. 1: 1, 2: the item's name"
            ),
            other: NSLocalizedString(
                "%1$lld pages already carry “%2$@” and will be skipped.",
                comment: "Batch apply preview. 1: skipped page count, 2: the item's name"
            ),
            arguments: [itemName]
        )
    }
}

/// What a scoped batch apply actually did.
public struct BatchApplyReceipt: Hashable, Sendable {

    /// The markups the batch created, in the order it created them.
    public var createdMarkupIDs: [UUID]
    /// The pages it skipped because they already carried the same thing.
    public var skippedPageIDs: [UUID]
    /// The audit group every entry of this batch shares, or `nil` when no trail is kept.
    public var auditGroup: String?
    /// Whether the person cancelled before anything was written.
    public var wasCancelled: Bool
    /// Why nothing happened, when nothing did.
    public var failureMessage: String?

    /// Creates a receipt.
    public init(
        createdMarkupIDs: [UUID] = [],
        skippedPageIDs: [UUID] = [],
        auditGroup: String? = nil,
        wasCancelled: Bool = false,
        failureMessage: String? = nil
    ) {
        self.createdMarkupIDs = createdMarkupIDs
        self.skippedPageIDs = skippedPageIDs
        self.auditGroup = auditGroup
        self.wasCancelled = wasCancelled
        self.failureMessage = failureMessage
    }

    /// A cancelled run. Nothing was written: cancelling leaves either all or none, consistent
    /// with the save pipeline's rule.
    public static let cancelled = BatchApplyReceipt(wasCancelled: true)

    /// How many placements the batch made.
    public var placementCount: Int { createdMarkupIDs.count }

    /// A localized sentence for the status bar after the batch.
    public var completionSentence: String {
        if wasCancelled {
            return NSLocalizedString(
                "Batch cancelled. Nothing was placed.",
                comment: "Status after a cancelled batch apply"
            )
        }
        if let failureMessage { return failureMessage }
        if skippedPageIDs.isEmpty {
            let format = NSLocalizedString(
                "Placed %d. One Undo removes all of them.",
                comment: "Status after a batch apply. %d is the placement count"
            )
            return String(format: format, placementCount)
        }
        let format = NSLocalizedString(
            "Placed %1$d, skipped %2$d that already carried it. One Undo removes all of them.",
            comment: "Status after a batch apply with skips. 1: placed, 2: skipped"
        )
        return String(format: format, placementCount, skippedPageIDs.count)
    }
}

/// A Double rounded for a `%d` display, without ever trapping.
///
/// `Int(x.rounded())` is a fatal error for NaN, ±infinity and anything beyond `Int.max`; the
/// batch sheet's size and inset fields accept all of those from a paste (BH-268, BH-763).
enum BatchDisplayInteger {
    static func clamped(_ value: Double) -> Int {
        guard value.isFinite else { return value.isNaN ? 0 : (value > 0 ? Int(Int32.max) : Int(Int32.min)) }
        let limit = Double(Int32.max)
        return Int(min(max(value.rounded(), -limit), limit))
    }
}
