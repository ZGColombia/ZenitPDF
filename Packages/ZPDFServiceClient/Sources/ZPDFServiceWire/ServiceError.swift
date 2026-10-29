import Foundation

/// The one error type the app-side facade throws for boundary failures.
///
/// Failures *inside* the work (a truncated PDF, a wrong password) come back as
/// ``remoteFailure`` carrying the service-side error's domain and message: typed,
/// Sendable, and honest about which process produced them. Failures *of* the
/// boundary itself — the worker died, the reply was garbage — get their own cases,
/// because the caller's recovery differs: a crashed service is retried after a
/// restart, a malformed PDF is not.
public enum ZPDFServiceError: Error, Sendable, Hashable {
    /// No transport could be established at all (missing service bundle when XPC
    /// was demanded, worker binary absent, spawn failure).
    case serviceUnavailable(service: String, detail: String)
    /// The service process died while a request was in flight. The client's
    /// restart policy has already been exhausted when the caller sees this.
    case serviceCrashed(service: String, detail: String)
    /// The service accepted the request and then produced no reply inside the
    /// caller's deadline (CR-122).
    ///
    /// Distinct from ``serviceCrashed(service:detail:)`` because the worker is
    /// *alive*. Crash isolation catches a worker that dies; this catches one that
    /// never comes back — a drawing that makes the parser loop rather than trap
    /// used to leave the caller's continuation unresumed forever, which is a hung
    /// application, not an isolated one. Never retried automatically: a deadline
    /// that expired once on a page will expire again on the same page, and the
    /// second wait costs the user the deadline a second time.
    case timedOut(service: String, detail: String)
    /// The service replied, but with bytes that do not decode. Treated as fatal
    /// for the request, never retried: garbage is not transient.
    case malformedReply(service: String, detail: String)
    /// The service executed the request and it failed for a reason that is the
    /// document's fault, not the boundary's.
    case remoteFailure(domain: String, code: Int, message: String)
    /// The request was cancelled, on either side of the boundary.
    case cancelled
}

/// The Codable projection of a service-side error, sent inside a reply frame.
public struct WireFailure: Sendable, Codable, Hashable {
    public var domain: String
    public var code: Int
    public var message: String
    public var isCancellation: Bool

    public init(domain: String, code: Int, message: String, isCancellation: Bool = false) {
        self.domain = domain
        self.code = code
        self.message = message
        self.isCancellation = isCancellation
    }

    public var serviceError: ZPDFServiceError {
        isCancellation ? .cancelled : .remoteFailure(domain: domain, code: code, message: message)
    }

    /// NSError bridge for the XPC reply path, which is `(Data?, NSError?)`.
    public var nsError: NSError {
        NSError(domain: domain, code: code, userInfo: [
            NSLocalizedDescriptionKey: message,
            Self.cancellationKey: isCancellation
        ])
    }

    public static let cancellationKey = "ZPDFWireFailureIsCancellation"

    public init(nsError: NSError) {
        self.domain = nsError.domain
        self.code = nsError.code
        self.message = nsError.localizedDescription
        self.isCancellation = (nsError.userInfo[Self.cancellationKey] as? Bool) ?? false
    }
}
