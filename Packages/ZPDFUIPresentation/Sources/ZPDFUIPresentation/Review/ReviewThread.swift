import Foundation

/// One line of a markup's review thread, as the Comments tab shows it (NL-COLLAB-01/02).
///
/// Three kinds, in time order: the markup's own note (its `comment`), the replies written on it,
/// and the status changes the History recorded for it. A status change reads "N set status
/// Open → Accepted" with a glyph and words, never colour alone.
public struct ReviewThreadItem: Identifiable, Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// The markup's note — the Inspector's Notes field.
        case note
        /// A reply written on the markup.
        case reply
        /// A status change, from the History. `reverted` when it was an undo or a redo.
        case statusChange(from: MarkupStatus?, to: MarkupStatus?, reverted: Bool)
        /// The markup was assigned to someone, with an optional due date (NL-COLLAB-17). An
        /// empty assignee clears the assignment.
        case assignment(assignee: String, due: Date?)
    }

    public let id: String
    public let kind: Kind
    /// Who wrote it, as signed at the time. Empty when the document never recorded it — a note
    /// written by a build before review history existed.
    public let author: String
    /// When it was written; `nil` when the document never recorded it.
    public let date: Date?
    public let text: String
    /// A withdrawn reply keeps its place and reads as withdrawn.
    public let isRetracted: Bool
    /// The reply id to withdraw, for a reply that can be withdrawn.
    public let replyID: UUID?

    public init(
        id: String,
        kind: Kind,
        author: String,
        date: Date?,
        text: String,
        isRetracted: Bool = false,
        replyID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.author = author
        self.date = date
        self.text = text
        self.isRetracted = isRetracted
        self.replyID = replyID
    }
}

/// A markup's whole review thread, plus its History entries.
public struct ReviewThread: Hashable, Sendable {
    public let markupID: UUID
    /// Note, replies and status changes, oldest first.
    public let items: [ReviewThreadItem]
    /// Every History entry for the markup, oldest first.
    public let history: [LedgerAuditEvent]

    public init(markupID: UUID, items: [ReviewThreadItem], history: [LedgerAuditEvent]) {
        self.markupID = markupID
        self.items = items
        self.history = history
    }

    /// Replies that have not been withdrawn.
    public var replyCount: Int {
        items.filter { $0.kind == .reply && !$0.isRetracted }.count
    }

    public static func empty(_ markupID: UUID) -> ReviewThread {
        ReviewThread(markupID: markupID, items: [], history: [])
    }
}

/// The review-thread surface the Comments tab reads and writes (NL-COLLAB-01/02).
///
/// Implemented by the app tier over the project database; the shell holds it as an optional,
/// so a window without one shows the note alone rather than crashing.
@MainActor
public protocol ReviewThreadPresenting: AnyObject {
    /// Bumped on every change a thread could show — a reply, an undo, a History entry. The
    /// Comments tab reads it so it re-renders without notification plumbing of its own.
    var threadRevision: Int { get }

    /// The thread for one markup.
    func thread(for markup: MarkupSummary) -> ReviewThread

    /// Every markup of the document, on every page — what the Review List lists (NL-COLLAB-04).
    var reviewMarkups: [MarkupSummary] { get }

    /// Appends a reply signed with the current author, as one undoable step. Answers the new
    /// reply's id, or `nil` when the body was blank or nothing could be written.
    @discardableResult
    func addReply(_ body: String, to markupID: UUID) -> UUID?

    /// Withdraws a reply, as one undoable step. The reply keeps its place, marked withdrawn.
    func retractReply(_ replyID: UUID)

    /// Assigns markups to a person, with an optional due date, as one undoable step
    /// (NL-COLLAB-17). An empty assignee clears the assignment.
    func assign(_ markupIDs: Set<UUID>, to assignee: String, due: Date?)

    /// The markup's current assignment, or `nil`.
    func assignment(for markupID: UUID) -> ReviewAssignment?

    /// The name this person signs with.
    var currentAuthor: String { get }

    /// Every name this person has signed with, the current one included (NL-COLLAB-05): "me" in
    /// the filters, and one colour, whatever they were called when they wrote it.
    var myNames: Set<String> { get }

    /// Markups somebody else changed since this person last opened the project, or that a
    /// shared-review sync or an import brought in (NL-COLLAB-14).
    var changedSinceLastLook: Set<UUID> { get }

    /// Clears ``changedSinceLastLook``: everything on screen now counts as seen.
    func markAllSeen()

    /// What other people did that concerns this person, newest first (NL-COLLAB-15).
    var activity: [ReviewActivityItem] { get }

    /// Marks every activity item read.
    func markActivityRead()

    /// The review rounds closed so far, oldest first (NL-COLLAB-19).
    var rounds: [ReviewRound] { get }

    /// Closes a round: a named checkpoint of the review as it stands, one undoable step.
    func closeRound(named name: String)

    /// What changed since a round closed: markups added, removed and changed, status
    /// transitions, and the quantity each subject gained or lost.
    func changes(since round: ReviewRound) -> ReviewRoundDiff
}

/// A named checkpoint of a review (NL-COLLAB-19).
public struct ReviewRound: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let closedAt: Date
    public let closedBy: String
    /// The History position the round closed at.
    public let historySequence: Int

    public init(id: UUID, name: String, closedAt: Date, closedBy: String, historySequence: Int) {
        self.id = id
        self.name = name
        self.closedAt = closedAt
        self.closedBy = closedBy
        self.historySequence = historySequence
    }
}

/// What changed between a round and now (NL-COLLAB-19).
public struct ReviewRoundDiff: Hashable, Sendable {
    public struct StatusTransition: Hashable, Sendable {
        public let markupID: UUID
        public let from: MarkupStatus
        public let to: MarkupStatus
        public init(markupID: UUID, from: MarkupStatus, to: MarkupStatus) {
            self.markupID = markupID
            self.from = from
            self.to = to
        }
    }

    /// One subject's change in one measured quantity, already formatted with its unit.
    public struct QuantityDelta: Hashable, Sendable {
        public let subject: String
        public let field: String
        public let delta: Decimal
        public let deltaText: String
        public init(subject: String, field: String, delta: Decimal, deltaText: String) {
            self.subject = subject
            self.field = field
            self.delta = delta
            self.deltaText = deltaText
        }
    }

    public var added: Set<UUID> = []
    public var removed: Set<UUID> = []
    public var changed: Set<UUID> = []
    public var statusTransitions: [StatusTransition] = []
    public var quantityDeltas: [QuantityDelta] = []

    public init() {}

    public var touched: Set<UUID> { added.union(removed).union(changed) }

    /// "3 added, 1 removed, 5 changed; 4 accepted; Slab Plan Area +3.4 m²".
    public var summary: String {
        var parts = [String(
            format: NSLocalizedString("%1$lld added, %2$lld removed, %3$lld changed", comment: "Review round comparison: counts"),
            added.count, removed.count, changed.count
        )]
        let byTarget = Dictionary(grouping: statusTransitions, by: \.to)
        for status in MarkupStatus.allCases where status != .none {
            guard let moved = byTarget[status], !moved.isEmpty else { continue }
            parts.append(String(
                format: NSLocalizedString("%1$lld now %2$@", comment: "Review round comparison: markups moved to a status; count, status"),
                moved.count, status.displayName
            ))
        }
        for delta in quantityDeltas {
            parts.append("\(delta.subject) \(delta.field) \(delta.deltaText)")
        }
        return parts.joined(separator: "; ")
    }
}

/// Who a markup is assigned to, and by when (NL-COLLAB-17).
public struct ReviewAssignment: Hashable, Sendable {
    public var assignee: String
    public var due: Date?
    public var assignedBy: String
    public var assignedAt: Date

    public init(assignee: String, due: Date?, assignedBy: String, assignedAt: Date) {
        self.assignee = assignee
        self.due = due
        self.assignedBy = assignedBy
        self.assignedAt = assignedAt
    }

    /// Whether the due date has passed, counted by calendar day.
    public func isOverdue(today: Date, calendar: Calendar = .current) -> Bool {
        Self.isOverdue(due: due, today: today, calendar: calendar)
    }

    /// The one overdue rule: a due date is overdue once its calendar day is before today's. Due
    /// today is not overdue. The Review List's Overdue filter reads it too, so the assignment
    /// and the list cannot disagree about a date (S-096).
    public static func isOverdue(due: Date?, today: Date, calendar: Calendar = .current) -> Bool {
        guard let due else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: today)
    }
}


/// Something another person did that concerns this person (NL-COLLAB-15): a reply on their markup
/// or in a thread they joined, an @-mention of their name, a status change on their markup.
public struct ReviewActivityItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case reply
        case mention
        case statusChange
    }

    public let id: UUID
    public let markupID: UUID
    public let kind: Kind
    public let author: String
    public let text: String
    public let date: Date
    public var isRead: Bool

    public init(id: UUID = UUID(), markupID: UUID, kind: Kind, author: String, text: String, date: Date, isRead: Bool = false) {
        self.id = id
        self.markupID = markupID
        self.kind = kind
        self.author = author
        self.text = text
        self.date = date
        self.isRead = isRead
    }

    /// "Bo replied: Agreed", "Bo mentioned you: @Ada can you check", "Bo set your markup to Accepted".
    public var sentence: String {
        switch kind {
        case .reply:
            return String(format: NSLocalizedString("%1$@ replied: %2$@", comment: "Activity: a reply; who, the reply"), author, text)
        case .mention:
            return String(format: NSLocalizedString("%1$@ mentioned you: %2$@", comment: "Activity: an @-mention; who, the reply"), author, text)
        case .statusChange:
            return String(format: NSLocalizedString("%1$@ set your markup to %2$@", comment: "Activity: a status change on the person's markup; who, the status"), author, text)
        }
    }
}
