import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFCollaboration

/// S-115: a participant whose persisted clock once ran more than a day ahead had its own new
/// markups deleted on every sync. `tick` only counted up from the future reading, every reader
/// (this participant included) dropped those operations as implausible, and `localChanges`
/// removed each local markup the merge no longer held.
@Suite("Shared Review Folder — a clock that ran ahead (S-115)")
struct Iter2ClockRecoveryTests {

    static let now = Date(timeIntervalSince1970: 1_790_500_000)
    static let nowMillis: Int64 = 1_790_500_000_000
    static let twoDaysAhead: Int64 = nowMillis + 48 * 3_600_000

    @Test("A clock whose reading is beyond the drift bound restarts from the wall clock")
    func clockRestarts() {
        var clock = HybridLogicalClock(node: "ada", last: HLCTimestamp(physicalMillis: Self.twoDaysAhead, counter: 5, node: "ada"))
        // Old output: (twoDaysAhead, 6) — implausible to every reader, forever.
        #expect(clock.tick(now: Self.now) == HLCTimestamp(physicalMillis: Self.nowMillis, counter: 0, node: "ada"))

        var observer = HybridLogicalClock(node: "bo", last: HLCTimestamp(physicalMillis: Self.twoDaysAhead, counter: 0, node: "bo"))
        observer.observe(HLCTimestamp(physicalMillis: Self.nowMillis - 1_000, counter: 2, node: "ada"), now: Self.now)
        // Old output: last stayed at twoDaysAhead (counter 1).
        #expect(observer.last == HLCTimestamp(physicalMillis: Self.nowMillis, counter: 0, node: "bo"))

        // A clock an hour ahead is real skew and is kept.
        var skewed = HybridLogicalClock(node: "cy", last: HLCTimestamp(physicalMillis: Self.nowMillis + 3_600_000, counter: 0, node: "cy"))
        let discarded = skewed.discardImplausibleReading(now: Self.now)
        #expect(!discarded)
        #expect(skewed.tick(now: Self.now) == HLCTimestamp(physicalMillis: Self.nowMillis + 3_600_000, counter: 1, node: "cy"))
    }

    @Test("The very last reading is its own successor, never one that orders before it")
    func successorSaturates() {
        let next = HybridLogicalClock.successor(physical: Int64.max, counter: Int32.max)
        // Old output: (Int64.max, 0), which orders before (Int64.max, Int32.max).
        #expect(next.physical == Int64.max && next.counter == Int32.max)
    }

    @Test("A base clock two days ahead: the markup just drawn and those agreed while it was ahead are kept")
    func ownMarkupsSurvive() throws {
        let (folder, url) = try SharedReviewTests.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let participant = "ada-mac"
        let future = HLCTimestamp(physicalMillis: Self.twoDaysAhead, counter: 0, node: participant)

        // Agreed while the clock was ahead: one markup and one withdrawn reply, published at
        // clocks no reader accepts.
        let earlier = SharedReviewTests.cloud(label: "earlier")
        let reply = SharedReply(id: UUID(), markupID: earlier.id, authorName: "Ada", body: "see RFI", createdAt: Self.now)
        try folder.append([
            ReviewOperation(clock: future, participantID: participant, authorName: "Ada", payload: .putMarkup(MarkupRegisters(record: earlier))),
            ReviewOperation(clock: HLCTimestamp(physicalMillis: Self.twoDaysAhead, counter: 1, node: participant), participantID: participant,
                            authorName: "Ada", payload: .addReply(reply)),
            ReviewOperation(clock: HLCTimestamp(physicalMillis: Self.twoDaysAhead, counter: 2, node: participant), participantID: participant,
                            authorName: "Ada", payload: .setReplyRetracted(reply.id, true))
        ], participant: participant)
        var base = SharedReviewBase(participantID: participant)
        base.clock = HybridLogicalClock(node: participant, last: HLCTimestamp(physicalMillis: Self.twoDaysAhead, counter: 2, node: participant))
        base.markups = [earlier.id: MarkupRegisters(record: earlier)]
        base.replies = [reply.id: true]

        // The person draws a new markup, then syncs.
        let drawn = SharedReviewTests.cloud(label: "just drawn")
        let local = [earlier, drawn]
        let localReplies = [SharedReviewSyncPlanner.LocalReply(reply: reply, retracted: true)]
        let before = folder.readAll(now: Self.now)
        #expect(before.operations.isEmpty && before.skippedLines == 3, "the folder holds nothing readable of Ada's yet")
        let publish = SharedReviewSyncPlanner.operationsToPublish(
            local: local, localReplies: localReplies, base: &base,
            observed: MergedReview.merge(before.operations).latestClock,
            participantID: participant, authorName: "Ada", now: Self.now)
        // Old output: every published clock was (twoDaysAhead, 3…) — implausible.
        #expect(!publish.isEmpty && publish.allSatisfy { HybridLogicalClock.isPlausible($0.clock, now: Self.now) })
        try folder.append(publish, participant: participant)

        let read = folder.readAll(now: Self.now)
        let merged = MergedReview.merge(read.operations)
        let known = Set(base.markups.keys).union(local.map(\.id))
        let changes = SharedReviewSyncPlanner.localChanges(merged: merged, local: local, localReplies: localReplies, known: known)
        // Old output: removed == both ids (the new markup and the earlier one), merged empty.
        #expect(changes.removed.isEmpty)
        #expect(Set(merged.markups.keys) == [earlier.id, drawn.id])
        #expect(merged.replies[reply.id]?.retracted == true, "the withdrawn reply stays withdrawn")
        #expect(changes.retractions.isEmpty && changes.newReplies.isEmpty)
        #expect(base.clock.last.physicalMillis == Self.nowMillis)
    }

    @Test("A void agreement still publishes the removals it implies")
    func removalsStillPublished() throws {
        let participant = "ada-mac"
        let gone = SharedReviewTests.cloud(label: "deleted here")
        var base = SharedReviewBase(participantID: participant)
        base.clock = HybridLogicalClock(node: participant, last: HLCTimestamp(physicalMillis: Self.twoDaysAhead, counter: 0, node: participant))
        base.markups = [gone.id: MarkupRegisters(record: gone)]
        let publish = SharedReviewSyncPlanner.operationsToPublish(
            local: [], localReplies: [], base: &base, observed: .zero,
            participantID: participant, authorName: "Ada", now: Self.now)
        #expect(publish.map(\.payload) == [.removeMarkup(gone.id)])
        // observe(.zero) after the restart sets (now, 0); the removal's tick is the next reading.
        // Old output: (twoDaysAhead, 1).
        #expect(publish.first?.clock == HLCTimestamp(physicalMillis: Self.nowMillis, counter: 1, node: participant))
    }
}
