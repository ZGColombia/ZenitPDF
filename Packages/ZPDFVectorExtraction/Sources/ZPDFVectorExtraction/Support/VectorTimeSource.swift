import Foundation
import os

/// The clock the extractor reads, injected so nothing in the engine calls the wall
/// clock directly.
///
/// The scanner runs inside synchronous CoreGraphics callbacks, so the reading must be
/// synchronous: an `async` clock cannot be consulted from inside a `CGPDFOperatorCallback`.
/// The value is a monotonically non-decreasing nanosecond counter with an arbitrary
/// origin; only differences are ever used.
public struct VectorTimeSource: Sendable {
    public let nanoseconds: @Sendable () -> UInt64

    public init(nanoseconds: @escaping @Sendable () -> UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// The machine's monotonic uptime clock. Unaffected by the user changing the date.
    public static let system = VectorTimeSource { DispatchTime.now().uptimeNanoseconds }

    /// A clock that never advances: elapsed time is always zero, so the wall-clock
    /// budget can never fire. Use it to prove a result does not depend on timing.
    public static func frozen(at value: UInt64 = 0) -> VectorTimeSource {
        VectorTimeSource { value }
    }

    /// A clock that advances by `step` nanoseconds on every reading, starting at
    /// `start + step`.
    ///
    /// Deterministic and thread-safe without `@unchecked Sendable`: the counter lives in
    /// an `OSAllocatedUnfairLock`, which is a `Sendable` value type wrapping shared
    /// state.
    public static func stepping(start: UInt64 = 0, step: UInt64) -> VectorTimeSource {
        let state = OSAllocatedUnfairLock(initialState: start)
        return VectorTimeSource {
            state.withLock { current in
                current = current &+ step
                return current
            }
        }
    }
}
