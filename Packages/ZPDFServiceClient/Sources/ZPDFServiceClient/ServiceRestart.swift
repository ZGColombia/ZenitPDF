import Foundation
import ZPDFServiceWire

/// Runs one boundary request, restarting a crashed service and retrying up to
/// `maximumRestarts` times — the one restart policy both facades share.
///
/// S-116: each facade carried its own copy of this loop (R-213 had folded the geometry
/// client's four into one, the repair client kept a fifth), and neither asked whether the
/// caller had stopped. A cancel during a long qpdf call makes the repair service end itself
/// (the R-198 wedge exit), which reaches the client as ``ZPDFServiceError/serviceCrashed(service:detail:)``;
/// the loop then relaunched the service and sent the cancelled request again, and the repair
/// could run to completion and be written. A crash while the calling task is cancelled is now
/// the cancel it was: ``ZPDFServiceError/cancelled``, no restart, no retry.
///
/// The same holds before an attempt starts. A task cancelled before its request was dispatched
/// used to get a worker spawned, the request sent and the whole deadline waited out, and came
/// back ``ZPDFServiceError/timedOut(service:detail:)`` — its cancellation handler fired before
/// anything was in flight to forward the cancel to. Every attempt therefore begins by asking
/// whether the caller is still there, and a cancelled caller gets ``ZPDFServiceError/cancelled``
/// at once: nothing is spawned, staged or sent.
///
/// `isolation` keeps `body` and `restart` on the calling actor, whose state they touch.
func withServiceRestart<Value: Sendable>(
    maximumRestarts: Int,
    isolation: isolated (any Actor)? = #isolation,
    restart: () async -> Void,
    _ body: () async throws -> Value
) async throws -> Value {
    var restartsUsed = 0
    while true {
        if Task.isCancelled { throw ZPDFServiceError.cancelled }
        do {
            return try await body()
        } catch let error as ZPDFServiceError {
            guard case .serviceCrashed = error else { throw error }
            if Task.isCancelled { throw ZPDFServiceError.cancelled }
            guard restartsUsed < maximumRestarts else { throw error }
            restartsUsed += 1
            await restart()
        }
    }
}
