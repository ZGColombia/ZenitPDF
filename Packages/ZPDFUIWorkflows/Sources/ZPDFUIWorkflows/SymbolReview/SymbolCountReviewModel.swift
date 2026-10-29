import CoreGraphics
import Foundation
import Observation
import ZPDFUIPresentation

/// One place a symbol search found, as the review lists it (NL-AUTO-02).
public struct SymbolCountReviewRow: Identifiable, Hashable, Sendable {

    public enum Status: Hashable, Sendable {
        /// The matcher confirmed it. Ticked.
        case confirmed
        /// It almost matched. Unticked, highlighted on the canvas; the person decides.
        case nearMiss
        /// A count point already sits here, under `subject`. Unticked: accepting it again
        /// would count it twice.
        case alreadyCounted(subject: String)
    }

    public let id: Int
    public let pageIndex: Int
    /// The page's name as the Navigator shows it.
    public let pageLabel: String
    public let position: PDFPointValue
    /// The candidate's extent, for its thumbnail and highlight.
    public let bounds: PDFRectValue
    public let status: Status
    /// How close the match was, in words the app tier wrote: "residual 0.31 of the bar ·
    /// mirrored · 1.00×".
    public let detail: String
    public let isExemplar: Bool
    /// The designation this row lands under when a review holds several (a library search,
    /// NL-AUTO-17); `nil` lands under the review's own ``SymbolCountReviewModel/designation``.
    public let designation: String?
    /// Rows sharing a group are one place claimed by several types (NL-AUTO-06): at most one of
    /// them can be ticked, so a contested place is never counted twice.
    public let exclusiveGroup: Int?
    /// The other designations that claim this place, for the status line.
    public let alsoClaimedBy: [String]

    public init(
        id: Int,
        pageIndex: Int,
        pageLabel: String,
        position: PDFPointValue,
        bounds: PDFRectValue,
        status: Status,
        detail: String,
        isExemplar: Bool,
        designation: String? = nil,
        exclusiveGroup: Int? = nil,
        alsoClaimedBy: [String] = []
    ) {
        self.designation = designation
        self.exclusiveGroup = exclusiveGroup
        self.alsoClaimedBy = alsoClaimedBy
        self.id = id
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.position = position
        self.bounds = bounds
        self.status = status
        self.detail = detail
        self.isExemplar = isExemplar
    }

    /// Ticked before the person touches anything: confirmed places only, and never a place
    /// another type also claims — the person picks which type it is.
    public var isSelectedByDefault: Bool { status == .confirmed && exclusiveGroup == nil }

    /// The status in words, so the list never relies on colour.
    public var statusText: String {
        if !alsoClaimedBy.isEmpty {
            return String(
                format: NSLocalizedString(
                    "Also matches %@ — tick the one it is",
                    comment: "Symbol review row status: a place two types both matched; the other designations"
                ),
                alsoClaimedBy.joined(separator: ", ")
            )
        }
        switch status {
        case .confirmed:
            return NSLocalizedString("Match", comment: "Symbol review row status: confirmed match")
        case .nearMiss:
            return NSLocalizedString("Near miss", comment: "Symbol review row status: almost matched")
        case .alreadyCounted(let subject):
            return String(
                format: NSLocalizedString(
                    "Already counted as %@", comment: "Symbol review row status: a count point already sits here; the subject"
                ),
                subject
            )
        }
    }
}

/// One searched page's totals, for the summary.
public struct SymbolCountReviewPage: Hashable, Sendable {
    public let pageIndex: Int
    public let pageLabel: String
    /// Shapes the search looked at that did not resemble the symbol.
    public let otherShapeCount: Int
    /// A cap stopped the search on this page, so it may hold more.
    public let isTruncated: Bool
    /// The page could not be searched at all; the reason, in words.
    public let failure: String?

    public init(pageIndex: Int, pageLabel: String, otherShapeCount: Int, isTruncated: Bool, failure: String? = nil) {
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.otherShapeCount = otherShapeCount
        self.isTruncated = isTruncated
        self.failure = failure
    }
}

/// The person's decision.
public struct SymbolCountReviewOutcome: Hashable, Sendable {
    /// The rows to land, by id.
    public let selectedRowIDs: Set<Int>
    /// The designation, as finally typed.
    public let designation: String
    /// Keep the boxed symbol in the local symbol library (NL-AUTO-17).
    public let saveToLibrary: Bool
}

/// Drives the symbol count review (NL-AUTO-02, NL-AUTO-05): confirm per instance, see the near
/// misses, read one honest summary, and land the ticked places as one undoable step.
///
/// Like the table-import review, it never touches a session: ``accept()`` hands the outcome to
/// the app tier and ``cancel()`` says no. A search across pages fills it progressively
/// (``append(page:rows:)``) while ``progress`` counts pages, and ``cancelSearch()`` stops the
/// search with nothing committed.
@MainActor @Observable
public final class SymbolCountReviewModel {

    public enum Phase: Equatable {
        /// Pages still being searched.
        case searching(done: Int, total: Int)
        /// Every page answered.
        case ready
        /// The person stopped the search; what was found so far stays reviewable.
        case stopped(done: Int, total: Int)
    }

    /// The designation the counts land under. Editable until acceptance.
    public var designation: String
    /// Keep the boxed symbol in the local symbol library, to find it on later sheets and in other
    /// projects (NL-AUTO-17). Off unless the person ticks it.
    public var saveToLibrary = false
    /// Whether rows carry their own designations (a library search); the designation field and
    /// the library toggle then do not apply.
    public var isMultiDesignation: Bool { rows.contains { $0.designation != nil } }
    public private(set) var rows: [SymbolCountReviewRow] = []
    public private(set) var pages: [SymbolCountReviewPage] = []
    public var selectedRowIDs: Set<Int> = []
    public private(set) var phase: Phase
    /// The row the person last asked to see on the canvas.
    public private(set) var revealedRowID: Int?
    /// Symbols against printed tags, per page (NL-AUTO-23): two counts that must agree.
    public private(set) var tagCounts: [Int: (symbols: Int, tags: Int, orphanTags: Int)] = [:]

    /// A picture of one row's place on the sheet, rendered by the app tier. Optional: the list
    /// works without it.
    @ObservationIgnored public var thumbnailProvider: (@MainActor (SymbolCountReviewRow) async -> CGImage?)?

    @ObservationIgnored private let onAccept: (SymbolCountReviewOutcome) -> Void
    @ObservationIgnored private let onCancel: () -> Void
    @ObservationIgnored private let onStopSearch: () -> Void
    @ObservationIgnored private let onReveal: (SymbolCountReviewRow) -> Void

    public init(
        designation: String,
        pageTotal: Int,
        onAccept: @escaping (SymbolCountReviewOutcome) -> Void,
        onCancel: @escaping () -> Void,
        onStopSearch: @escaping () -> Void = {},
        onReveal: @escaping (SymbolCountReviewRow) -> Void = { _ in }
    ) {
        self.designation = designation
        self.phase = pageTotal > 0 ? .searching(done: 0, total: pageTotal) : .ready
        self.onAccept = onAccept
        self.onCancel = onCancel
        self.onStopSearch = onStopSearch
        self.onReveal = onReveal
    }

    // MARK: - Filling

    /// One page's answer. Confirmed rows arrive ticked.
    public func append(page: SymbolCountReviewPage, rows newRows: [SymbolCountReviewRow]) {
        pages.append(page)
        pages.sort { $0.pageIndex < $1.pageIndex }
        rows.append(contentsOf: newRows)
        rows.sort { $0.pageIndex != $1.pageIndex ? $0.pageIndex < $1.pageIndex : $0.id < $1.id }
        selectedRowIDs.formUnion(newRows.filter(\.isSelectedByDefault).map(\.id))
        if case .searching(let done, let total) = phase {
            phase = done + 1 >= total ? .ready : .searching(done: done + 1, total: total)
        }
    }

    /// Records one page's tag cross-count. Pages with no tags printed are not recorded:
    /// there is nothing to reconcile.
    public func setTagCount(pageIndex: Int, symbols: Int, tags: Int, orphanTags: Int) {
        guard tags > 0 else { return }
        tagCounts[pageIndex] = (symbols, tags, orphanTags)
    }

    /// The search finished early — every page answered, or the app tier gave up on the rest.
    public func finishSearch() {
        if case .searching = phase { phase = .ready }
    }

    /// Stops a search in progress. Found rows stay; nothing is committed.
    public func cancelSearch() {
        guard case .searching(let done, let total) = phase else { return }
        phase = .stopped(done: done, total: total)
        onStopSearch()
    }

    public var isSearching: Bool {
        if case .searching = phase { return true }
        return false
    }

    // MARK: - Choosing

    public func isSelected(_ row: SymbolCountReviewRow) -> Bool { selectedRowIDs.contains(row.id) }

    public func toggle(_ row: SymbolCountReviewRow) {
        setSelected(!selectedRowIDs.contains(row.id), for: row)
    }

    /// Ticks or unticks a row. Ticking one claim of a contested place unticks the others.
    public func setSelected(_ selected: Bool, for row: SymbolCountReviewRow) {
        guard selected else {
            selectedRowIDs.remove(row.id)
            return
        }
        if let group = row.exclusiveGroup {
            for other in rows where other.exclusiveGroup == group && other.id != row.id {
                selectedRowIDs.remove(other.id)
            }
        }
        selectedRowIDs.insert(row.id)
    }

    /// Contested places still waiting for the person's pick.
    public var unresolvedContestedCount: Int {
        let groups = Set(rows.compactMap(\.exclusiveGroup))
        return groups.filter { group in !rows.contains { $0.exclusiveGroup == group && selectedRowIDs.contains($0.id) } }.count
    }

    /// Shows the row's place on the canvas.
    public func reveal(_ row: SymbolCountReviewRow) {
        revealedRowID = row.id
        onReveal(row)
    }

    // MARK: - Counting

    /// Confirmed **places**, not claims (W-065). A place two types both matched arrives as one
    /// confirmed row per claiming type, sharing an ``SymbolCountReviewRow/exclusiveGroup``, and at
    /// most one of them can be ticked; it counts once. Ten places, two of them claimed twice,
    /// used to read "12 confirmed" while the selection could land at most ten.
    public var confirmedCount: Int {
        let confirmed = rows.filter { $0.status == .confirmed }
        let uncontested = confirmed.filter { $0.exclusiveGroup == nil }.count
        return uncontested + Set(confirmed.compactMap(\.exclusiveGroup)).count
    }
    public var nearMissCount: Int { rows.filter { $0.status == .nearMiss }.count }
    public var alreadyCountedCount: Int {
        rows.filter { if case .alreadyCounted = $0.status { return true } else { return false } }.count
    }
    public var otherShapeCount: Int { pages.reduce(0) { $0 + $1.otherShapeCount } }
    public var truncatedPages: [SymbolCountReviewPage] { pages.filter(\.isTruncated) }
    public var failedPages: [SymbolCountReviewPage] { pages.filter { $0.failure != nil } }

    /// The one summary: "6 confirmed, 1 near miss shown; 212 other shapes did not resemble the
    /// symbol." — plus what was already counted and where the search stopped early.
    public var summaryText: String {
        var parts: [String] = [String(
            format: NSLocalizedString(
                "%1$lld confirmed, %2$@; %3$@",
                comment: "Symbol review summary: the confirmed count, the near misses as '2 near misses shown', the other shapes as '212 other shapes did not resemble the symbol.'"
            ),
            confirmedCount, WorkflowPlurals.nearMissesShown(nearMissCount), WorkflowPlurals.otherShapes(otherShapeCount)
        )]
        if alreadyCountedCount > 0 {
            parts.append(String(
                format: NSLocalizedString(
                    "Already counted: %d — left unticked so nothing is counted twice.",
                    comment: "Symbol review summary: places already carrying a count point"
                ),
                alreadyCountedCount
            ))
        }
        let contested = Set(rows.compactMap(\.exclusiveGroup)).count
        if contested > 0 {
            parts.append(String(
                format: NSLocalizedString(
                    "%1$@; %2$@",
                    comment: "Symbol review summary: the contested places as '3 places match more than one type', the unresolved ones as '2 still need a pick.'"
                ),
                WorkflowPlurals.contestedPlaces(contested), WorkflowPlurals.stillNeedAPick(unresolvedContestedCount)
            ))
        }
        if !tagCounts.isEmpty {
            let symbols = tagCounts.values.reduce(0) { $0 + $1.symbols }
            let tags = tagCounts.values.reduce(0) { $0 + $1.tags }
            let orphans = tagCounts.values.reduce(0) { $0 + $1.orphanTags }
            parts.append(orphans == 0 && symbols == tags
                ? String(
                    format: NSLocalizedString(
                        "Tags agree: %1$@, %2$@.",
                        comment: "Symbol review summary: symbol count equals printed tag count; '6 symbols', '6 tags'"
                    ),
                    WorkflowPlurals.symbols(symbols), WorkflowPlurals.tags(tags)
                )
                : String(
                    format: NSLocalizedString(
                        "%1$@ / %2$@ — %3$@",
                        comment: "Symbol review summary: symbol and tag counts disagree; '6 symbols', '7 tags', '1 tag with no symbol beside it is marked on the sheet.'"
                    ),
                    WorkflowPlurals.symbols(symbols), WorkflowPlurals.tags(tags), WorkflowPlurals.orphanTags(orphans)
                ))
        }
        if !truncatedPages.isEmpty {
            parts.append(String(
                format: NSLocalizedString(
                    "The search stopped early on %@; those pages may hold more.",
                    comment: "Symbol review summary: pages where a cap stopped the search; the page names"
                ),
                truncatedPages.map(\.pageLabel).joined(separator: ", ")
            ))
        }
        if !failedPages.isEmpty {
            parts.append(String(
                format: NSLocalizedString(
                    "Not searched: %@.",
                    comment: "Symbol review summary: pages that could not be searched; the page names"
                ),
                failedPages.map(\.pageLabel).joined(separator: ", ")
            ))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - The two ways out

    public var trimmedDesignation: String { designation.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canAccept: Bool {
        !selectedRowIDs.isEmpty && (isMultiDesignation || !trimmedDesignation.isEmpty) && !isSearching
    }

    public func accept() {
        guard canAccept else { return }
        onAccept(SymbolCountReviewOutcome(
            selectedRowIDs: selectedRowIDs,
            designation: trimmedDesignation,
            saveToLibrary: saveToLibrary && !isMultiDesignation
        ))
    }

    public func cancel() {
        if isSearching { cancelSearch() }
        onCancel()
    }
}
