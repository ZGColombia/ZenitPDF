import Foundation
import ZPDFCollaboration
import ZPDFContracts
import ZPDFUIPresentation

/// The activity feed (NL-COLLAB-15): what arrived from other people — through a Shared Review
/// Folder sync or an import — that concerns this person. Never this person's own operations.
extension AppReviewPresenter {

    /// Works out the activity items a set of incoming changes makes for this person, adds them to
    /// the feed and hands them to ``onActivity`` (the app's notification poster). Answers them.
    @discardableResult
    public func recordActivity(from changes: SharedReviewSyncPlanner.LocalChanges, markups: [ZPDFContracts.MarkupRecord], now: Date = Date()) -> [ReviewActivityItem] {
        let me = myNames
        let lowered = me.map { $0.lowercased() }
        let authorOf = Dictionary(markups.map { ($0.id.rawValue, $0.author) }, uniquingKeysWith: { first, _ in first })
        // Threads this person has written in.
        let joined = Set(entries.filter { me.contains($0.authorName) }.compactMap { UUID(uuidString: $0.markupId) })
        var items: [ReviewActivityItem] = []
        for reply in changes.newReplies where !me.contains(reply.authorName) {
            let body = reply.body.lowercased()
            let mentioned = lowered.contains { !$0.isEmpty && body.contains("@" + $0) }
            let mine = authorOf[reply.markupID.rawValue].map(me.contains) ?? false
            if mentioned {
                items.append(ReviewActivityItem(markupID: reply.markupID.rawValue, kind: .mention, author: reply.authorName, text: reply.body, date: reply.createdAt))
            } else if mine || joined.contains(reply.markupID.rawValue) {
                items.append(ReviewActivityItem(markupID: reply.markupID.rawValue, kind: .reply, author: reply.authorName, text: reply.body, date: reply.createdAt))
            }
        }
        for change in changes.changed where change.keys.contains(.status) && me.contains(change.record.author) {
            items.append(ReviewActivityItem(
                markupID: change.record.id.rawValue, kind: .statusChange,
                author: NSLocalizedString("Someone", comment: "Activity: a change whose author the log does not name per register"),
                text: ZPDFUIPresentation.MarkupStatus(domain: change.record.status).displayName, date: now
            ))
        }
        guard !items.isEmpty else { return [] }
        activityItems.insert(contentsOf: items.sorted { $0.date > $1.date }, at: 0)
        bumpActivity()
        onActivity?(items)
        return items
    }
}
