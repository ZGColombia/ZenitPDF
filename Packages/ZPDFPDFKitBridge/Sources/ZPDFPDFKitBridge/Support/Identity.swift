import Foundation
import os

/// Supplies document handle identifiers.
///
/// Injected rather than calling `UUID()`, so a test can assert that the second document
/// opened is `#2` and that closing and reopening never reuses an identifier.
public protocol HandleIDGenerating: Sendable {
    func next() -> UInt64
}

/// The production generator: `1, 2, 3, …` for the lifetime of one provider.
///
/// The counter sits in an `OSAllocatedUnfairLock`, which is itself `Sendable`, so the
/// generator is safely shared without `@unchecked Sendable` anywhere in this package.
public struct MonotonicHandleIDGenerator: HandleIDGenerating {
    private let counter: OSAllocatedUnfairLock<UInt64>

    public init(startingAt first: UInt64 = 0) {
        counter = OSAllocatedUnfairLock(initialState: first)
    }

    public func next() -> UInt64 {
        counter.withLock { value in
            value &+= 1
            return value
        }
    }
}

/// A generator that hands out a fixed sequence and then keeps counting, for tests that
/// want to name the handles they expect.
public struct FixedHandleIDGenerator: HandleIDGenerating {
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var scripted: [UInt64]
        var cursor: Int
        var fallback: UInt64
    }

    public init(_ scripted: [UInt64], continuingFrom fallback: UInt64 = 1000) {
        state = OSAllocatedUnfairLock(initialState: State(scripted: scripted, cursor: 0, fallback: fallback))
    }

    public func next() -> UInt64 {
        state.withLock { state in
            if state.cursor < state.scripted.count {
                defer { state.cursor += 1 }
                return state.scripted[state.cursor]
            }
            state.fallback &+= 1
            return state.fallback
        }
    }
}
