import Foundation

/// One row of the Review List: every markup, not only the ones that make a quantity
/// (NL-COLLAB-04). Clouds, callouts and text boxes without a subject were in no list at all.
public struct ReviewListRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let pageLabel: String
    public let pageIndex: Int
    public let kind: MarkupKind
    public let kindName: String
    public let subject: String
    /// The note's first line.
    public let note: String
    public let author: String
    public let status: MarkupStatus
    public let replyCount: Int
    /// The newest of: the markup's own change, its note, a reply, a status change.
    public let lastActivity: Date
    /// Anything the Review List is searched by: subject, label, note, drawn text, author.
    public let searchText: String
    /// Who the markup is assigned to, and by when (NL-COLLAB-17).
    public let assignee: String
    public let due: Date?
    /// Changed by somebody else since this person last looked (NL-COLLAB-14).
    public let isNew: Bool

    public init(
        id: UUID, pageLabel: String, pageIndex: Int, kind: MarkupKind, kindName: String, subject: String,
        note: String, author: String, status: MarkupStatus, replyCount: Int, lastActivity: Date, searchText: String,
        assignee: String = "", due: Date? = nil, isNew: Bool = false
    ) {
        self.id = id
        self.pageLabel = pageLabel
        self.pageIndex = pageIndex
        self.kind = kind
        self.kindName = kindName
        self.subject = subject
        self.note = note
        self.author = author
        self.status = status
        self.replyCount = replyCount
        self.lastActivity = lastActivity
        self.searchText = searchText
        self.assignee = assignee
        self.due = due
        self.isNew = isNew
    }
}

/// What the Review List shows (NL-COLLAB-04). Every condition set narrows; all of them together
/// is "status = Open AND author = X AND …".
public struct ReviewListFilter: Hashable, Sendable {
    /// Empty means every status.
    public var statuses: Set<MarkupStatus> = []
    /// Empty means every author.
    public var authors: Set<String> = []
    public var text: String = ""
    public var onlyWithReplies = false
    /// `nil` means every page.
    public var pageIndex: Int?
    /// Only markups assigned to one of these names — "Assigned to me" passes every name this
    /// person has signed with.
    public var assignedTo: Set<String>?
    /// Only markups whose due date has passed.
    public var onlyOverdue = false
    /// The day "overdue" is counted against; `nil`, the default, is the day the list is built.
    ///
    /// The default used to be `Date()` captured when the filter was made, and the Review List
    /// keeps its filter for as long as the pane is open, so past midnight the Overdue filter and
    /// the red due date both went on counting against the day before (T-061).
    public var today: Date?
    /// Only markups changed by somebody else since this person last looked.
    public var onlyNew = false
    /// Only these markups — a round comparison's touched set (NL-COLLAB-19).
    public var onlyIDs: Set<UUID>?

    public init(
        statuses: Set<MarkupStatus> = [], authors: Set<String> = [], text: String = "",
        onlyWithReplies: Bool = false, pageIndex: Int? = nil
    ) {
        self.statuses = statuses
        self.authors = authors
        self.text = text
        self.onlyWithReplies = onlyWithReplies
        self.pageIndex = pageIndex
    }

    public var isEmpty: Bool {
        statuses.isEmpty && authors.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty
            && !onlyWithReplies && pageIndex == nil && assignedTo == nil && !onlyOverdue && !onlyNew && onlyIDs == nil
    }

    public func matches(_ row: ReviewListRow) -> Bool {
        if !statuses.isEmpty, !statuses.contains(row.status) { return false }
        if !authors.isEmpty, !authors.contains(row.author) { return false }
        if onlyWithReplies, row.replyCount == 0 { return false }
        if let pageIndex, row.pageIndex != pageIndex { return false }
        if let assignedTo, !assignedTo.contains(row.assignee) { return false }
        if onlyNew, !row.isNew { return false }
        if let onlyIDs, !onlyIDs.contains(row.id) { return false }
        if onlyOverdue, !ReviewAssignment.isOverdue(due: row.due, today: today ?? Date()) { return false }
        let needle = text.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, row.searchText.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }
}

/// How the Review List is ordered.
public enum ReviewListSort: String, CaseIterable, Hashable, Sendable, Identifiable {
    case page
    case lastActivity
    case status
    case author

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .page: return NSLocalizedString("Page", comment: "Review List sort: by page")
        case .lastActivity: return NSLocalizedString("Last Activity", comment: "Review List sort: newest activity first")
        case .status: return NSLocalizedString("Status", comment: "Review List sort: by review status")
        case .author: return NSLocalizedString("Author", comment: "Review List sort: by author")
        }
    }
}

public enum ReviewList {

    /// The rows for a document's markups, with reply counts and last activity from their threads.
    @MainActor
    public static func rows(markups: [MarkupSummary], threads: (any ReviewThreadPresenting)?) -> [ReviewListRow] {
        let changed = threads?.changedSinceLastLook ?? []
        return markups.map { markup in
            let thread = threads?.thread(for: markup)
            let latest = ([markup.modified] + (thread?.items.compactMap(\.date) ?? [])).max() ?? markup.modified
            // L-83: a text box or callout keeps what it says in its drawn text, not in a note,
            // so its row showed an empty Note — the list never said what a note says. The
            // markup's own note first, its drawn text when it has none.
            let firstLine = Self.firstLine(of: markup.comment).nonEmpty ?? Self.firstLine(of: markup.drawnText ?? "")
            let search = [markup.subject, markup.label, markup.comment, markup.drawnText ?? "", markup.author]
                .joined(separator: "\n")
            // One lookup per row: the row asked twice, once for the assignee and once for the
            // due date, on every render of the pane (T-059).
            let assignment = threads?.assignment(for: markup.id)
            return ReviewListRow(
                id: markup.id,
                pageLabel: markup.pageLabel,
                pageIndex: markup.pageIndex,
                kind: markup.kind,
                kindName: markup.kind.displayName,
                // A markup with no subject is named by its label, when it has one (L-83).
                subject: markup.subject.isEmpty ? markup.label : markup.subject,
                note: firstLine,
                author: markup.author,
                status: markup.status,
                replyCount: thread?.replyCount ?? 0,
                lastActivity: latest,
                searchText: search,
                assignee: assignment?.assignee ?? "",
                due: assignment?.due,
                isNew: changed.contains(markup.id)
            )
        }
    }

    /// The first non-blank line of `text`, trimmed.
    static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// - Parameter now: the day an unset ``ReviewListFilter/today`` means, read once for the
    ///   whole list so every row is judged against the same day.
    public static func visible(
        _ rows: [ReviewListRow],
        filter: ReviewListFilter,
        sort: ReviewListSort,
        now: Date = Date()
    ) -> [ReviewListRow] {
        var filter = filter
        if filter.today == nil { filter.today = now }
        let kept = rows.filter(filter.matches)
        let statusOrder = Dictionary(uniqueKeysWithValues: MarkupStatus.allCases.enumerated().map { ($1, $0) })
        return kept.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            switch sort {
            case .page:
                if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
            case .lastActivity:
                if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            case .status:
                let left = statusOrder[a.status] ?? 0, right = statusOrder[b.status] ?? 0
                if left != right { return left < right }
            case .author:
                if a.author != b.author { return a.author.localizedStandardCompare(b.author) == .orderedAscending }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Every author in the rows, sorted, for the filter menu.
    public static func authors(in rows: [ReviewListRow]) -> [String] {
        Array(Set(rows.map(\.author))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private extension String {
    /// `nil` when empty, so a fallback can follow with `??`.
    var nonEmpty: String? { isEmpty ? nil : self }
}
