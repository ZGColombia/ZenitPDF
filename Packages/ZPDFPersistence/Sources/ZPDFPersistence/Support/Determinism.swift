import Foundation
import os

// MARK: - Clock

/// The only source of wall-clock time this package uses.
///
/// Nothing in the save pipeline, the journal or the manifest calls `Date()` directly:
/// timestamps are inputs, so a test can pin them and compare bytes.
public protocol PersistenceClock: Sendable {
    func now() -> Date
}

/// The production clock.
public struct SystemPersistenceClock: PersistenceClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// A clock that returns a fixed instant, then advances by a fixed step on each read.
///
/// The default step is one second, which is enough to make `createdAt` and `modifiedAt`
/// distinguishable in a test without making the values unpredictable.
/// The instant is held in an `OSAllocatedUnfairLock`, which is itself `Sendable`, so the
/// clock is shared across tasks without `@unchecked Sendable`. An unchecked conformance
/// is a promise the compiler cannot read; this one it can.
public final class SteppingClock: PersistenceClock, Sendable {
    private let current: OSAllocatedUnfairLock<Date>
    private let step: TimeInterval

    public init(start: Date, step: TimeInterval = 1) {
        self.current = OSAllocatedUnfairLock(initialState: start)
        self.step = step
    }

    public func now() -> Date {
        current.withLock { [step] instant in
            let value = instant
            instant = instant.addingTimeInterval(step)
            return value
        }
    }
}

// MARK: - Identifiers

/// The only source of new identifiers this package uses.
///
/// Row identifiers, save tokens and temporary-package names all come from here, so a
/// test can make an entire save byte-reproducible.
public protocol IdentifierGenerator: Sendable {
    func nextIdentifier() -> String
}

/// The production generator: uppercase RFC 4122 UUID strings.
public struct UUIDIdentifierGenerator: IdentifierGenerator {
    public init() {}
    public func nextIdentifier() -> String { UUID().uuidString }
}

/// A generator that emits `prefix-00000001`, `prefix-00000002`, …
/// Same pattern as ``SteppingClock``: the counter lives in an `OSAllocatedUnfairLock`, so
/// the conformance is checked rather than asserted.
public final class SequentialIdentifierGenerator: IdentifierGenerator, Sendable {
    private let prefix: String
    private let counter: OSAllocatedUnfairLock<UInt64>

    public init(prefix: String = "ID", start: UInt64 = 1) {
        self.prefix = prefix
        self.counter = OSAllocatedUnfairLock(initialState: start)
    }

    public func nextIdentifier() -> String {
        let value = counter.withLock { current -> UInt64 in
            let issued = current
            current &+= 1
            return issued
        }
        return String(format: "%@-%08llu", prefix, value)
    }
}

// MARK: - Timestamps

/// The single timestamp format used by every `TEXT` date column and by the manifest.
///
/// ISO 8601, UTC, milliseconds, `Z` suffix — sortable as a plain string, which is why
/// `ORDER BY modified_at` on a `TEXT` column is correct rather than merely convenient.
public enum PersistenceTimestamp {
    /// Formats an instant as `2026-08-23T10:11:16.000Z`.
    public static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return "1970-01-01T00:00:00.000Z" }
        calendar.timeZone = utc
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let milliseconds = (parts.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
            milliseconds
        )
    }

    /// Parses a timestamp produced by ``string(from:)``. Returns `nil` for anything else.
    ///
    /// Deliberately strict: a lenient parser here would let a corrupt manifest through.
    public static func date(from string: String) -> Date? {
        let scalars = Array(string.utf8)
        guard scalars.count == 24 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = scalars[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard scalars[4] == UInt8(ascii: "-"), scalars[7] == UInt8(ascii: "-"),
              scalars[10] == UInt8(ascii: "T"), scalars[13] == UInt8(ascii: ":"),
              scalars[16] == UInt8(ascii: ":"), scalars[19] == UInt8(ascii: "."),
              scalars[23] == UInt8(ascii: "Z"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16),
              let second = number(17..<19), let millisecond = number(20..<23)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = millisecond * 1_000_000
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        // `Calendar.date(from:)` normalises overflow — month 13 rolls into the next
        // year, hour 25 into the next day — so a corrupt or hand-edited timestamp used to
        // parse as a plausible wrong date (BH-607). Strict means the fields must round-trip.
        guard month >= 1, month <= 12, day >= 1, day <= 31,
              hour <= 23, minute <= 59, second <= 59,
              let date = calendar.date(from: components),
              // Half a millisecond on before re-formatting: a `Date` is a binary double, so
              // `.746` comes back as `.745999…`, and `string(from:)` truncates to milliseconds.
              // Without the nudge about one timestamp in three failed its own round trip and
              // parsed as `nil` — the History pane dated those rows `distantPast` and the review
              // thread could not order them. The overflow check BH-607 needs
              // (month 13, hour 25) is untouched: those fields still have to come back equal.
              Self.string(from: date.addingTimeInterval(0.000_5)) == string
        else { return nil }
        return date
    }
}

// MARK: - Environment

/// Everything the persistence layer needs from the outside world, in one value.
public struct PersistenceEnvironment: Sendable {
    public var clock: any PersistenceClock
    public var identifiers: any IdentifierGenerator
    /// Recorded verbatim in `manifest.appVersion`.
    public var appVersion: String
    /// Recorded verbatim in `manifest.minimumReaderVersion`.
    public var minimumReaderVersion: String
    /// Connection tuning for the project database.
    public var tuning: DatabaseTuning
    /// The machine this process runs on, written into the crash marker (NL-COLLAB-13).
    public var sessionHost: SessionHost
    /// How old another machine's heartbeat may be and still mean "open elsewhere".
    public var foreignSessionTimeToLive: TimeInterval

    public init(
        clock: any PersistenceClock = SystemPersistenceClock(),
        identifiers: any IdentifierGenerator = UUIDIdentifierGenerator(),
        appVersion: String = "1.0.0",
        minimumReaderVersion: String = "1.0.0",
        tuning: DatabaseTuning = DatabaseTuning(),
        sessionHost: SessionHost = .current,
        foreignSessionTimeToLive: TimeInterval = ForeignSessionPolicy.defaultTimeToLive
    ) {
        self.clock = clock
        self.identifiers = identifiers
        self.appVersion = appVersion
        self.minimumReaderVersion = minimumReaderVersion
        self.tuning = tuning
        self.sessionHost = sessionHost
        self.foreignSessionTimeToLive = foreignSessionTimeToLive
    }
}
