import Foundation
import os
import ZPDFServiceWire

/// Resumes a continuation exactly once, whichever of the XPC reply, the XPC error
/// handler and the request deadline fires first (on a crashed service both of the
/// first two can, and on a wedged one only the third ever will).
final class ResumeOnce<Value: Sendable>: Sendable {

    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, any Error>?
        /// The armed deadline, cancelled by whichever resume happens first so a
        /// completed request does not leave a sleeping task behind for the rest
        /// of the allowance.
        var watchdog: Task<Void, Never>?
    }

    private let box: OSAllocatedUnfairLock<State>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        box = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
    }

    /// Starts the wall clock for this request (CR-122).
    ///
    /// `onExpiry` runs on the deadline path only, before the caller is resumed:
    /// the transport uses it to drop its pending entry and to send the worker a
    /// cancel, so a reply that arrives late resumes nothing and lands nowhere.
    func armDeadline(
        _ deadline: ZPDFServiceDeadline,
        service: String,
        operation: String,
        onExpiry: @escaping @Sendable () -> Void
    ) {
        let watchdog = Task { [self] in
            // A cancelled sleep throws, and a cancelled watchdog is a request that
            // already finished: leave.
            do { try await Task.sleep(for: deadline.duration) } catch { return }
            onExpiry()
            resume(throwing: ZPDFServiceError.timedOut(
                service: service,
                detail: "\(operation) produced no reply within \(deadline.describedAllowance)"))
        }
        let alreadyResumed = box.withLock { state -> Bool in
            guard state.continuation != nil else { return true }
            state.watchdog = watchdog
            return false
        }
        if alreadyResumed { watchdog.cancel() }
    }

    func resume(returning value: Value) {
        let taken = take()
        taken.watchdog?.cancel()
        taken.continuation?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        let taken = take()
        taken.watchdog?.cancel()
        taken.continuation?.resume(throwing: error)
    }

    private func take() -> State {
        box.withLock { state -> State in
            defer { state = State() }
            return state
        }
    }
}

/// What an `NSXPCConnection` error handler's error means for the caller (BH-214).
///
/// `NSXPCConnectionInterrupted` is the remote process dying with the message in
/// flight: a crash, which the facades answer with one restart and a retry.
/// `NSXPCConnectionInvalid` is a connection that could not be established or no
/// longer exists — above all a service name the bundle does not embed. Every error
/// used to be reported as a crash, so a build without the service bundle spent a
/// restart on a service that does not exist and then told the user it had
/// crashed; both facades document that case as ``ZPDFServiceError/serviceUnavailable(service:detail:)``,
/// which is not retried.
func xpcBoundaryError(_ error: any Error, service: String) -> ZPDFServiceError {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSXPCConnectionInvalid {
        return .serviceUnavailable(service: service, detail: nsError.localizedDescription)
    }
    return .serviceCrashed(service: service, detail: nsError.localizedDescription)
}

/// `NSXPCConnection` to `GeometryService.xpc`, embedded in the app bundle.
///
/// Restart-on-crash is two layers deep here: launchd relaunches an XPC service on
/// demand by itself, and this actor drops its interrupted connection so the next
/// call builds a fresh one. The facade's retry policy sits above both.
actor GeometryXPCTransport {
    private var connection: NSXPCConnection?

    init() {}

    /// True when the running app bundle embeds the geometry service.
    static var serviceIsEmbedded: Bool {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/\(ZPDFGeometryServiceIdentity.bundleName).xpc")
            .isReachableDirectory
    }

    /// One geometry operation over the connection (R-213): the four operations differ only in
    /// the proxy method they call, so the connection, the deadline, the error handler, the
    /// descriptor hand-over and the reply decoding are written once here. They used to be
    /// written four times, and a fix at this boundary had to be made in four places.
    func perform(
        _ operation: GeometryXPCOperation,
        requestData: Data,
        documentDescriptor: Int32,
        requestID: UUID,
        deadline: ZPDFServiceDeadline
    ) async throws -> Data {
        let connection = ensureConnection()
        let service = ZPDFGeometryServiceIdentity.bundleName
        return try await withServiceDeadline(
            deadline, service: service, operation: operation.name,
            onExpiry: { [weak self] in Task { await self?.cancel(requestID: requestID) } }
        ) { once in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(throwing: xpcBoundaryError(error, service: service))
            }) as? ZPDFGeometryXPCProtocol else {
                once.resume(throwing: ZPDFServiceError.serviceUnavailable(
                    service: service, detail: "proxy does not conform to the geometry protocol"))
                return
            }
            let handle = FileHandle(fileDescriptor: documentDescriptor, closeOnDealloc: false)
            operation.invoke(proxy, requestData, handle) { data, error in
                if let data {
                    once.resume(returning: data)
                } else if let error {
                    once.resume(throwing: WireFailure(nsError: error).serviceError)
                } else {
                    once.resume(throwing: ZPDFServiceError.malformedReply(
                        service: service, detail: "reply carried neither data nor error"))
                }
            }
        }
    }

    func cancel(requestID: UUID) {
        guard let connection else { return }
        (connection.remoteObjectProxy as? ZPDFGeometryXPCProtocol)?
            .cancelRequest(requestID.uuidString)
    }

    /// Drops the current connection so the next request reconnects — the client's
    /// restart action after a crash.
    func reset() {
        connection?.invalidate()
        connection = nil
    }

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let fresh = NSXPCConnection(serviceName: ZPDFGeometryServiceIdentity.bundleIdentifier)
        fresh.remoteObjectInterface = NSXPCInterface(with: ZPDFGeometryXPCProtocol.self)
        fresh.resume()
        connection = fresh
        return fresh
    }
}

/// The geometry service's operations, as ``GeometryXPCTransport/perform(_:requestData:documentDescriptor:requestID:deadline:)``
/// calls them.
enum GeometryXPCOperation: Sendable {
    case extract
    case rasterize
    case pageBox
    /// NL-PLAT-05 (round 2): the `.dxf` crosses as a descriptor; the sheet comes back.
    case convertDXF

    /// The proxy method's name, which the deadline's error detail names.
    var name: String {
        switch self {
        case .extract: return "extractPageGeometry"
        case .rasterize: return "rasterizePage"
        case .pageBox: return "pageBox"
        case .convertDXF: return "convertDXF"
        }
    }

    func invoke(
        _ proxy: ZPDFGeometryXPCProtocol,
        _ requestData: Data,
        _ handle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        switch self {
        case .extract: proxy.extractPageGeometry(requestData, fileHandle: handle, reply: reply)
        case .rasterize: proxy.rasterizePage(requestData, fileHandle: handle, reply: reply)
        case .pageBox: proxy.pageBox(requestData, fileHandle: handle, reply: reply)
        case .convertDXF: proxy.convertDXF(requestData, fileHandle: handle, reply: reply)
        }
    }
}

/// `NSXPCConnection` to `RepairService.xpc`.
actor RepairXPCTransport {
    private var connection: NSXPCConnection?

    init() {}

    static var serviceIsEmbedded: Bool {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/\(ZPDFRepairServiceIdentity.bundleName).xpc")
            .isReachableDirectory
    }

    func perform(
        requestData: Data,
        inputDescriptor: Int32,
        outputDescriptor: Int32?,
        requestID: UUID,
        deadline: ZPDFServiceDeadline
    ) async throws -> Data {
        let connection = ensureConnection()
        let service = ZPDFRepairServiceIdentity.bundleName
        return try await withServiceDeadline(
            deadline, service: service, operation: "performOperation",
            onExpiry: { [weak self] in Task { await self?.cancel(requestID: requestID) } }
        ) { once in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(throwing: xpcBoundaryError(error, service: service))
            }) as? ZPDFRepairXPCProtocol else {
                once.resume(throwing: ZPDFServiceError.serviceUnavailable(
                    service: service, detail: "proxy does not conform to the repair protocol"))
                return
            }
            let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: false)
            let output = outputDescriptor.map { FileHandle(fileDescriptor: $0, closeOnDealloc: false) }
            proxy.performOperation(requestData, input: input, output: output) { data, error in
                if let data {
                    once.resume(returning: data)
                } else if let error {
                    once.resume(throwing: WireFailure(nsError: error).serviceError)
                } else {
                    once.resume(throwing: ZPDFServiceError.malformedReply(
                        service: service, detail: "reply carried neither data nor error"))
                }
            }
        }
    }

    func cancel(requestID: UUID) {
        guard let connection else { return }
        (connection.remoteObjectProxy as? ZPDFRepairXPCProtocol)?
            .cancelRequest(requestID.uuidString)
    }

    func reset() {
        connection?.invalidate()
        connection = nil
    }

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let fresh = NSXPCConnection(serviceName: ZPDFRepairServiceIdentity.bundleIdentifier)
        fresh.remoteObjectInterface = NSXPCInterface(with: ZPDFRepairXPCProtocol.self)
        fresh.resume()
        connection = fresh
        return fresh
    }
}

extension URL {
    var isReachableDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
