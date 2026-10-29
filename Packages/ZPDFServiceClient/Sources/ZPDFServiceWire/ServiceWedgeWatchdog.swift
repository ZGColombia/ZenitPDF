import Foundation
import os

/// Ends a service process whose cancelled request does not finish (R-198).
///
/// Cancellation reaches a request's work cooperatively. Work that never checks — a content
/// stream that makes a parser loop, a DXF expansion before it had a budget — keeps a thread of
/// the service's cooperative pool for the rest of the process's life, and every later request
/// queues behind what is left. The client's deadline stops *waiting* for such a request; this
/// stops the *work*: once a request has been cancelled and has had `grace` to wind down, a
/// request still running means the process is wedged, and it exits so launchd (or the client,
/// for the stdio worker) starts a clean one.
///
/// The timer runs on a Dispatch queue, not in a Swift task: when wedged work holds cooperative
/// threads, a task-based watchdog could be starved by exactly the thing it is watching for.
///
/// One per request. Only the service entry points arm it; a core running inside the
/// application (the in-process fallback) never exits the application.
public final class ServiceWedgeWatchdog: Sendable {

    private let finished = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    /// The request's work has returned, cancelled or not.
    public func markFinished() {
        finished.withLock { $0 = true }
    }

    public var isFinished: Bool { finished.withLock { $0 } }

    /// After `grace`, runs `onWedged` unless the work has finished by then.
    public func arm(grace: Duration, onWedged: @escaping @Sendable () -> Void) {
        let components = grace.components
        let nanoseconds = max(0, components.seconds) * 1_000_000_000
            + max(0, components.attoseconds) / 1_000_000_000
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { [self] in
            if !isFinished { onWedged() }
        }
    }

    /// What the service entry points pass as `onWedged`: the process ends at once. `_exit`, not
    /// `exit`, because a wedged thread may hold a lock an `atexit` handler would wait on.
    public static let exitProcess: @Sendable () -> Void = { _exit(70) }   // EX_SOFTWARE

    /// How long a cancelled request has to finish before its process is judged wedged.
    public static let defaultGrace: Duration = .seconds(2)
}
