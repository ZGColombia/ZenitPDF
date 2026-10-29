import Foundation
import ZPDFServiceWire

/// How long the application waits for one service request before it stops waiting.
///
/// ## Why this type exists (CR-122)
///
/// Crash isolation and **hang** isolation are different problems and only the
/// first one was solved. A worker that dies is noticed immediately: the reader
/// sees EOF and every waiter is resumed with
/// ``ZPDFServiceError/serviceCrashed(service:detail:)``. A worker that *lives*
/// and never answers — the drawing whose content stream makes the scanner loop
/// instead of trap — produced no event at all, so the caller's continuation was
/// never resumed and the calling task waited forever. An application that hangs
/// because a page is hostile is not isolated from that page.
///
/// Every request across the boundary therefore races a wall clock. When the clock
/// wins the request fails with ``ZPDFServiceError/timedOut(service:detail:)``, the
/// pending entry is dropped so a late reply resumes nothing, and a cancel frame is
/// sent after the worker on the chance it is merely slow and still cooperative.
///
/// ## Where the numbers come from
///
/// `QUALITY_BAR.md` §"Huge content streams" gives extraction a **10 s wall-clock
/// budget per page**, enforced inside the extractor itself, which marks the index
/// `partial(budgetExceeded:)` rather than running on. A deadline out here is the
/// backstop for the case where that budget is never reached because the worker is
/// wedged below it, so it has to sit clear of the budget it backs: three times it,
/// plus room for spawn and IPC. A legitimate page cannot reach 30 s without the
/// extractor having already given up at 10 s and replied.
///
/// Structural repair has no comparable budget — qpdf rewrites the whole file, and
/// a large set legitimately takes minutes — so it gets a much longer one. It is
/// still finite, which is the point.
public struct ZPDFServiceDeadline: Sendable, Hashable {

    /// The wall-clock allowance for one request.
    public var duration: Duration

    public init(_ duration: Duration) {
        self.duration = duration
    }

    /// Vector extraction, rasterisation and page-box reads: 3× the extractor's own
    /// 10 s per-page budget.
    public static let geometry = ZPDFServiceDeadline(.seconds(30))

    /// Structural repair, decrypt and linearize: qpdf rewrites the file.
    public static let repair = ZPDFServiceDeadline(.seconds(300))

    /// The copy throughput ``extended(forStagingBytes:)`` assumes: a USB 2 disk or
    /// a busy SMB share, not an internal SSD.
    public static let stagingBytesPerSecond: Int64 = 25_000_000

    /// This deadline plus the time to copy `bytes` at ``stagingBytesPerSecond``.
    ///
    /// The XPC service copies the whole document into its own temp before it
    /// parses a byte — its sandbox cannot open the user's path — and the flat
    /// geometry deadline budgeted for spawn and IPC only. A 1.5 GB drawing set on
    /// a slow volume spent most of the 30 s copying, then timed out, and a timeout
    /// is never retried (BH-212). The service now reuses its staged copy across
    /// requests, so only the first request on a document actually pays this; the
    /// allowance is on every request because the client cannot know which is first.
    public func extended(forStagingBytes bytes: Int64) -> ZPDFServiceDeadline {
        guard bytes > 0 else { return self }
        let milliseconds = bytes / (Self.stagingBytesPerSecond / 1000)
        return ZPDFServiceDeadline(duration + .milliseconds(milliseconds))
    }

    /// The size of the file behind `handle`, which an XPC service copies in full before it
    /// parses anything; ``extended(forStagingBytes:)`` covers that copy (BH-212, V-091). Zero
    /// when the size cannot be read, which leaves a deadline as it is.
    package static func stagingByteCount(of handle: FileHandle) -> Int64 {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return 0 }
        return Int64(info.st_size)
    }

    /// A deadline a test can actually wait out. Not used by shipping code: the
    /// two constants above are the only ones the app constructs.
    public static func milliseconds(_ value: Int) -> ZPDFServiceDeadline {
        ZPDFServiceDeadline(.milliseconds(value))
    }

    /// Rendered into the error detail, so the log says what was waited for.
    var describedAllowance: String {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.3f s", seconds)
    }
}

/// Runs one boundary request under ``ZPDFServiceDeadline``.
///
/// `body` receives a ``ResumeOnce`` and hands it to whatever callback the
/// transport uses. Whichever arrives first — the reply, a transport error, or the
/// deadline — wins; the rest are no-ops. `onExpiry` runs only on the deadline
/// path, before the caller is resumed, and is where a transport drops its pending
/// entry and tells the worker to stop.
///
/// Both transports go through here, which is the reason it is a free function
/// rather than a method: the XPC path cannot be exercised from `swift test` (an
/// `.xpc` bundle launches only from inside its host app), so the only way its
/// deadline is provable is by sharing the mechanism with the path that can.
///
/// `isolation` keeps `body` in the caller's isolation domain. Both transports are
/// actors and their bodies touch actor state (the live connection, the pending
/// table), so the closure is not `Sendable` and must not be sent anywhere; with
/// the caller's actor forwarded to `withCheckedThrowingContinuation` it never is.
func withServiceDeadline<Value: Sendable>(
    _ deadline: ZPDFServiceDeadline,
    service: String,
    operation: String,
    isolation: isolated (any Actor)? = #isolation,
    onExpiry: @escaping @Sendable () -> Void = {},
    _ body: (ResumeOnce<Value>) -> Void
) async throws -> Value {
    try await withCheckedThrowingContinuation(isolation: isolation) { (continuation: CheckedContinuation<Value, any Error>) in
        let once = ResumeOnce(continuation)
        // Armed before `body` runs, so a transport that fails synchronously has
        // already disarmed it by the time it resumes.
        once.armDeadline(deadline, service: service, operation: operation, onExpiry: onExpiry)
        body(once)
    }
}
