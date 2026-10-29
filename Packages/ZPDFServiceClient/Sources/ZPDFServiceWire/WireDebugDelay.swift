import Foundation

/// The one place a `debugDelayMilliseconds` test hook becomes a sleep duration.
///
/// The field is a plain `Int` on every request type and arrives from a decoder that
/// bounds nothing, and every consumer used to compute `UInt64(value) * 1_000_000`
/// itself. A value near `Int.max` — the natural thing for a test to pass when it
/// means "never finish", or what a hostile stdio frame sends — overflowed that
/// multiply and trapped, and on the in-process fallback the trap is in the
/// application (BH-655). Clamped here, so no consumer multiplies anything.
public enum WireDebugDelay {

    /// Ten minutes. Longer than any deadline the client races (the repair deadline
    /// is five), so a test that wants "never" still gets it, and far below the
    /// point where the nanosecond conversion could overflow.
    public static let maximumMilliseconds = 600_000

    /// The requested delay in nanoseconds, clamped to `0...maximumMilliseconds`.
    /// A negative value is no delay rather than a `UInt64` conversion trap.
    public static func nanoseconds(forMilliseconds value: Int) -> UInt64 {
        let clamped = min(max(value, 0), maximumMilliseconds)
        return UInt64(clamped) * 1_000_000
    }
}
