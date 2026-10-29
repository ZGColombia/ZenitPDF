import Foundation

/// A reply from a repair operation, or the typed failure that replaced it.
///
/// Declared here rather than beside `RepairServiceCore` because both the service
/// core (which produces it) and the client facade (which consumes it, on the
/// fallback path) must name the type without either one linking the other — and,
/// critically, without the client linking qpdf. See ``RepairInProcessExecuting``.
public enum RepairReplyOutcome: Sendable {
    case success(RepairWireReply)
    case failure(WireFailure)
}

/// The seam that keeps qpdf's C++ out of the application binary (finding S17-03).
///
/// `ZPDFRepairServiceClient` used to call `ZPDFQPDF` directly on its `.inProcess`
/// fallback. That made the vendored C++ parser a link-time dependency of every
/// binary that linked the client — including `Zenit PDF.app`, the one process the
/// service exists to keep qpdf *out* of. A parser the architecture claims is
/// isolated must not be present in the address space it is isolated from.
///
/// So the fallback is now an injected dependency rather than a call. The only
/// conformance in the repository is `RepairServiceCore`, which lives in
/// `ZPDFRepairServiceCore` — a target the two service executables and the test
/// suite link, and the application does not. `swift test` keeps the fallback by
/// passing that core in; the application literally cannot construct one, because
/// the symbol it would need is not in anything it links.
///
/// The requirement is deliberately shaped like `RepairServiceCore`'s own stdio
/// entry point, so the conformance is empty and the fallback runs the same code
/// the service runs.
public protocol RepairInProcessExecuting: Sendable {
    func perform(
        request: RepairWireRequest,
        inputAt input: URL,
        outputPath: String?
    ) async -> RepairReplyOutcome
}
