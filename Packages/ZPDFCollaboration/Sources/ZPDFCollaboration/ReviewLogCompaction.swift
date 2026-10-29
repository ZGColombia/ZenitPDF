import Foundation
import ZPDFContracts

/// The shortest log that merges exactly like a participant's whole log (T-079).
///
/// A log is only ever appended to, so a long review grows it without bound, and a reader refuses
/// a log over ``OperationLogCodec/maximumLogBytes``. When an append would pass that size, the
/// participant's own operations are compacted first and the log is replaced by the result.
///
/// ### Why the result merges the same
///
/// ``MergedReview/merge(_:)`` keeps, per state it tracks, one winning operation: the newest write
/// of each markup register, the newest put and the newest removal of each markup, the *oldest*
/// add of each reply, the newest withdrawal flag of each reply, the newest scale of each page;
/// the newest clock overall; and the name signed on the newest line. Every operation this keeps is
/// the winner of at least one of those among the participant's own operations; everything it
/// drops lost every one of them to an operation it keeps. Another participant's operation that
/// beats a dropped one therefore meets the kept one it lost to instead, and is compared with the
/// same clock order — so the merge of everybody's logs does not change, whoever else wrote what.
///
/// ### Clocks the reader judges
///
/// A reader skips an operation whose clock is more than a day ahead of its own wall clock
/// (R-202), and a winner it skips would let an older, dropped operation stand. So winners are
/// chosen only among *settled* operations — clocks at or before `now` — which every reader whose
/// clock is not a day behind this one accepts. An operation clocked after `now` is kept as it is,
/// and one with a negative clock, which no reader ever accepts, is dropped.
public enum ReviewLogCompaction {

    /// The operations of one participant's log worth keeping, in clock order.
    public static func compact(_ operations: [ReviewOperation], now: Date) -> [ReviewOperation] {
        let nowMillis = HybridLogicalClock.millis(now)
        var seen: Set<UUID> = []
        var settled: [ReviewOperation] = []
        var kept: [ReviewOperation] = []
        for operation in operations where seen.insert(operation.id).inserted {
            guard operation.clock.physicalMillis >= 0, operation.clock.counter >= 0 else { continue }
            if operation.clock.physicalMillis > nowMillis {
                kept.append(operation)
            } else {
                settled.append(operation)
            }
        }
        settled.sort(by: Self.precedes)

        // Walk newest first: the first operation seen for a "newest wins" slot is its winner.
        var keep = Set<UUID>()
        var registerWinners = Set<RegisterSlot>()
        var putWinners = Set<MarkupID>()
        var removeWinners = Set<MarkupID>()
        var retractionWinners = Set<UUID>()
        var scaleWinners = Set<PageID>()
        if let newest = settled.last { keep.insert(newest.id) }
        for operation in settled.reversed() {
            switch operation.payload {
            case .putMarkup(let put):
                if putWinners.insert(put.id).inserted { keep.insert(operation.id) }
                for key in put.values.keys where registerWinners.insert(RegisterSlot(markup: put.id, key: key)).inserted {
                    keep.insert(operation.id)
                }
            case .setRegisters(let id, let values):
                for key in values.keys where registerWinners.insert(RegisterSlot(markup: id, key: key)).inserted {
                    keep.insert(operation.id)
                }
            case .removeMarkup(let id):
                if removeWinners.insert(id).inserted { keep.insert(operation.id) }
            case .addReply:
                break
            case .setReplyRetracted(let id, _):
                if retractionWinners.insert(id).inserted { keep.insert(operation.id) }
            case .setPageScale(let scale):
                if scaleWinners.insert(scale.pageID).inserted { keep.insert(operation.id) }
            }
        }
        // A reply's first add wins, so oldest first.
        var replyWinners = Set<UUID>()
        for operation in settled {
            if case .addReply(let reply) = operation.payload, replyWinners.insert(reply.id).inserted {
                keep.insert(operation.id)
            }
        }
        kept.append(contentsOf: settled.filter { keep.contains($0.id) })
        return kept.sorted(by: Self.precedes)
    }

    /// The merge's own order: clock, then id.
    static func precedes(_ lhs: ReviewOperation, _ rhs: ReviewOperation) -> Bool {
        lhs.clock != rhs.clock ? lhs.clock < rhs.clock : lhs.id.uuidString < rhs.id.uuidString
    }

    private struct RegisterSlot: Hashable {
        var markup: MarkupID
        var key: RegisterKey
    }
}
