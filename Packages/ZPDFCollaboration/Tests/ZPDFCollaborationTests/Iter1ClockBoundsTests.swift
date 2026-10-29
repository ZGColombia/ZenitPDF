import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFCollaboration

/// R-202: one bad clock or hostile log line cannot freeze last-writer-wins for everybody.
@Suite("Shared Review Folder — clock bounds (R-202)")
struct Iter1ClockBoundsTests {

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let t0Millis: Int64 = 1_790_000_000_000

    private static func removal(_ clock: HLCTimestamp, participant: String = "mallory") -> ReviewOperation {
        ReviewOperation(clock: clock, participantID: participant, authorName: participant,
                        payload: .removeMarkup(MarkupID(UUID())))
    }

    @Test("A log line from far in the future, or with a negative clock, is skipped and counted")
    func implausibleLinesAreSkipped() throws {
        let honest = Self.removal(HLCTimestamp(physicalMillis: Self.t0Millis - 60_000, counter: 3, node: "ada"),
                                  participant: "ada")
        let skewed = Self.removal(HLCTimestamp(physicalMillis: Self.t0Millis + 3_600_000, counter: 0, node: "bo"),
                                  participant: "bo")                       // an hour fast: real skew
        let hostile = Self.removal(HLCTimestamp(physicalMillis: Int64.max - 1, counter: 0, node: "mallory"))
        let twoDays = Self.removal(HLCTimestamp(physicalMillis: Self.t0Millis + 48 * 3_600_000, counter: 0, node: "mallory"))
        let negative = Self.removal(HLCTimestamp(physicalMillis: 5, counter: -4, node: "mallory"))
        let data = try OperationLogCodec.encode([honest, skewed, hostile, twoDays, negative])
        let decoded = OperationLogCodec.decode(data, now: Self.t0)
        // Old output: five operations, zero skipped — the Int64.max line then moved every
        // participant's clock to the end of time.
        #expect(decoded.operations.map(\.id) == [honest.id, skewed.id])
        #expect(decoded.skipped == 3)
    }

    @Test("Observing a reading beyond the drift bound leaves the clock where it was")
    func farFutureObservationIsIgnored() {
        var clock = HybridLogicalClock(node: "ada")
        let before = clock.tick(now: Self.t0)
        clock.observe(HLCTimestamp(physicalMillis: Int64.max - 1, counter: 0, node: "mallory"), now: Self.t0)
        // Old output: `last.physicalMillis == Int64.max - 1`, so every later local edit carried
        // that timestamp and nothing anybody did afterwards could be ordered after it honestly.
        #expect(clock.last == before)
        let next = clock.tick(now: Self.t0.addingTimeInterval(1))
        #expect(next.physicalMillis == Self.t0Millis + 1_000)
    }

    @Test("A counter at Int32.max carries into the next millisecond instead of wrapping")
    func counterSaturates() {
        // The clock is ahead of the wall (a remote reading it observed), so ticks count up.
        var clock = HybridLogicalClock(node: "ada", last: HLCTimestamp(
            physicalMillis: Self.t0Millis + 10_000, counter: Int32.max - 1, node: "ada"))
        let a = clock.tick(now: Self.t0)
        let b = clock.tick(now: Self.t0)
        // Old output: b.counter == Int32.min, so b < a — a later edit ordered before an earlier one.
        #expect(a < b)
        #expect(b == HLCTimestamp(physicalMillis: Self.t0Millis + 10_001, counter: 0, node: "ada"))

        // The same on the receive side: a remote reading at the maximum counter.
        var other = HybridLogicalClock(node: "bo")
        let remote = HLCTimestamp(physicalMillis: Self.t0Millis, counter: Int32.max, node: "mallory")
        other.observe(remote, now: Self.t0)
        let after = other.tick(now: Self.t0)
        #expect(after > remote, "the next local edit orders after what was observed")
    }
}
