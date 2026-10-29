// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation
import Observation

/// An in-memory ``ReviewThreadPresenting`` for previews and shell tests: replies kept in a list,
/// signed with a fixed author and stamped with an injectable clock.
@MainActor
@Observable
public final class MockReviewThreadPresenter: ReviewThreadPresenting {

    public private(set) var threadRevision = 0
    public var author: String
    public var now: () -> Date
    /// Status changes and notes a test wants in a thread, keyed by markup.
    public var seededItems: [UUID: [ReviewThreadItem]] = [:]
    public var seededHistory: [UUID: [LedgerAuditEvent]] = [:]
    public private(set) var replies: [UUID: [ReviewThreadItem]] = [:]
    /// What the Review List lists.
    public var reviewMarkups: [MarkupSummary] = []

    public init(author: String = "Reviewer", now: @escaping () -> Date = { Date() }) {
        self.author = author
        self.now = now
    }

    public func thread(for markup: MarkupSummary) -> ReviewThread {
        _ = threadRevision
        let items = (seededItems[markup.id] ?? []) + (replies[markup.id] ?? [])
        return ReviewThread(markupID: markup.id, items: items, history: seededHistory[markup.id] ?? [])
    }

    @discardableResult
    public func addReply(_ body: String, to markupID: UUID) -> UUID? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let id = UUID()
        replies[markupID, default: []].append(ReviewThreadItem(
            id: "reply-\(id.uuidString)", kind: .reply, author: author, date: now(), text: text, replyID: id
        ))
        threadRevision += 1
        return id
    }

    public private(set) var assignments: [UUID: ReviewAssignment] = [:]
    public var currentAuthor: String { author }
    public var formerNames: [String] = []
    public var myNames: Set<String> { Set([author] + formerNames) }
    public var changedSinceLastLook: Set<UUID> = []
    public var activity: [ReviewActivityItem] = []
    public func markActivityRead() {
        for index in activity.indices { activity[index].isRead = true }
        threadRevision += 1
    }

    public private(set) var rounds: [ReviewRound] = []
    public var diffs: [UUID: ReviewRoundDiff] = [:]
    public func closeRound(named name: String) {
        rounds.append(ReviewRound(id: UUID(), name: name, closedAt: now(), closedBy: author, historySequence: rounds.count))
        threadRevision += 1
    }
    public func changes(since round: ReviewRound) -> ReviewRoundDiff { diffs[round.id] ?? ReviewRoundDiff() }

    public func markAllSeen() {
        changedSinceLastLook = []
        threadRevision += 1
    }

    public func assign(_ markupIDs: Set<UUID>, to assignee: String, due: Date?) {
        for id in markupIDs {
            let name = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
            assignments[id] = name.isEmpty ? nil : ReviewAssignment(assignee: name, due: due, assignedBy: author, assignedAt: now())
        }
        threadRevision += 1
    }

    /// How many times ``assignment(for:)`` was asked. Test evidence for T-059.
    @ObservationIgnored public private(set) var assignmentLookupCount = 0

    public func assignment(for markupID: UUID) -> ReviewAssignment? {
        assignmentLookupCount += 1
        return assignments[markupID]
    }

    public func retractReply(_ replyID: UUID) {
        for (markup, items) in replies {
            guard let index = items.firstIndex(where: { $0.replyID == replyID }) else { continue }
            let old = items[index]
            replies[markup]?[index] = ReviewThreadItem(
                id: old.id, kind: old.kind, author: old.author, date: old.date, text: old.text,
                isRetracted: true, replyID: old.replyID
            )
            threadRevision += 1
            return
        }
    }
}
#endif
