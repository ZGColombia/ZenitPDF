import Foundation

/// A hybrid logical clock reading: wall-clock milliseconds, a counter for events inside one
/// millisecond or behind a clock that ran backwards, and the node that took it.
///
/// Total order: physical time, then counter, then node. Two participants therefore agree on the
/// order of every pair of operations without talking to each other, which is what makes the merge
/// deterministic. The node breaks exact ties, so two edits in the same millisecond on two Macs are
/// still ordered the same way on both.
public struct HLCTimestamp: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var physicalMillis: Int64
    public var counter: Int32
    public var node: String

    public init(physicalMillis: Int64, counter: Int32, node: String) {
        self.physicalMillis = physicalMillis
        self.counter = counter
        self.node = node
    }

    public static func < (lhs: HLCTimestamp, rhs: HLCTimestamp) -> Bool {
        if lhs.physicalMillis != rhs.physicalMillis { return lhs.physicalMillis < rhs.physicalMillis }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.node < rhs.node
    }

    public static let zero = HLCTimestamp(physicalMillis: 0, counter: 0, node: "")

    public var description: String { "\(physicalMillis).\(counter)@\(node)" }
}

/// The clock one participant keeps (Kulkarni et al.'s hybrid logical clock, send/receive rules).
///
/// Bounded (R-202). A shared review folder is writable by anybody who can reach it, and the old
/// clock trusted every reading it was shown: one log line with `physicalMillis` near
/// `Int64.max` moved every participant's clock there for good, and a counter near `Int32.max`
/// wrapped to `Int32.min` on the next event, so later edits ordered *before* the ones they
/// followed and last-writer-wins froze. Now a remote reading more than ``maximumDrift`` ahead
/// of this machine's wall clock is not observed (the log decoder already drops such lines), and
/// a counter at its maximum carries into the next millisecond instead of wrapping.
public struct HybridLogicalClock: Codable, Hashable, Sendable {
    public var node: String
    public private(set) var last: HLCTimestamp

    /// How far ahead of this machine's wall clock a remote reading may be and still count:
    /// a day, generous for any real clock skew between two Macs, useless to an attacker.
    public static let maximumDrift: TimeInterval = 24 * 60 * 60

    public init(node: String, last: HLCTimestamp? = nil) {
        self.node = node
        self.last = last ?? HLCTimestamp(physicalMillis: 0, counter: 0, node: node)
    }

    /// Forgets a reading this clock holds that is itself implausible at `now` — more than
    /// ``maximumDrift`` ahead of the wall clock, or negative — and restarts from the wall clock.
    /// Returns whether it did.
    ///
    /// S-115. The clock is persisted with the participant's base, so a Mac whose date was once
    /// set ahead (or a clock poisoned before R-202) kept `last` in the future for good: `tick`
    /// only ever counted up from it, every operation it stamped was dropped as implausible by
    /// every reader, this participant's own log included, and the sync then deleted the markup
    /// the person had just drawn. Every reading this clock gives is now plausible at the `now` it
    /// was given for.
    @discardableResult
    public mutating func discardImplausibleReading(now: Date) -> Bool {
        guard !Self.isPlausible(last, now: now) else { return false }
        last = HLCTimestamp(physicalMillis: 0, counter: 0, node: node)
        return true
    }

    /// A reading for a local event: never earlier than any reading this clock has given or seen,
    /// unless that reading was implausible (``discardImplausibleReading(now:)``).
    public mutating func tick(now: Date) -> HLCTimestamp {
        discardImplausibleReading(now: now)
        let wall = Self.millis(now)
        if wall > last.physicalMillis {
            last = HLCTimestamp(physicalMillis: wall, counter: 0, node: node)
        } else {
            let next = Self.successor(physical: last.physicalMillis, counter: last.counter)
            last = HLCTimestamp(physicalMillis: next.physical, counter: next.counter, node: node)
        }
        return last
    }

    /// Takes a remote reading into account, so the next local event orders after it — unless
    /// the reading claims to be more than ``maximumDrift`` in this machine's future, which no
    /// honest clock does.
    public mutating func observe(_ remote: HLCTimestamp, now: Date) {
        let wall = Self.millis(now)
        discardImplausibleReading(now: now)
        guard remote.physicalMillis <= wall &+ Self.maximumDriftMillis, remote.counter >= 0 else { return }
        let physical = max(wall, last.physicalMillis, remote.physicalMillis)
        let next: (physical: Int64, counter: Int32)
        if physical == last.physicalMillis && physical == remote.physicalMillis {
            next = Self.successor(physical: physical, counter: max(last.counter, remote.counter))
        } else if physical == last.physicalMillis {
            next = Self.successor(physical: physical, counter: last.counter)
        } else if physical == remote.physicalMillis {
            next = Self.successor(physical: physical, counter: remote.counter)
        } else {
            next = (physical, 0)
        }
        last = HLCTimestamp(physicalMillis: next.physical, counter: next.counter, node: node)
    }

    /// Whether a remote reading is within ``maximumDrift`` of `now` and well-formed. The log
    /// decoder skips — and counts as skipped — every operation whose clock is not.
    public static func isPlausible(_ reading: HLCTimestamp, now: Date) -> Bool {
        reading.physicalMillis >= 0 && reading.counter >= 0
            && reading.physicalMillis <= millis(now) &+ maximumDriftMillis
    }

    /// The reading after `physical.counter`: the counter, or at its maximum the next
    /// millisecond with the counter back at zero. Never a wrap: the very last reading
    /// (`Int64.max`, `Int32.max`) is its own successor — equal, never earlier (S-115; the old
    /// `(Int64.max, 0)` ordered before it). Unreachable since readings are bounded by the drift.
    static func successor(physical: Int64, counter: Int32) -> (physical: Int64, counter: Int32) {
        if counter < Int32.max { return (physical, counter + 1) }
        guard physical < Int64.max else { return (physical, counter) }
        return (physical + 1, 0)
    }

    static let maximumDriftMillis = Int64(maximumDrift * 1000)

    static func millis(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard value.isFinite else { return 0 }
        return Int64(exactly: value) ?? (value > 0 ? Int64.max : Int64.min)
    }
}
