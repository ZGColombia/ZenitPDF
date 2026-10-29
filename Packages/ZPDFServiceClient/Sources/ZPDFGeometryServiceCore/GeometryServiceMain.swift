import Foundation
import ZPDFServiceWire

// MARK: - Stdio handler (test worker path)

/// The geometry core speaking wire frames. Used by `zpdf-geometry-worker` and by
/// `Apps/GeometryService` when launched with `--stdio` for diagnosis.
public struct GeometryStdioHandler: StdioRequestHandler {
    private let core: GeometryServiceCore

    public init(core: GeometryServiceCore = GeometryServiceCore()) {
        self.core = core
    }

    public func handle(_ frame: WireRequestFrame) async -> WireReplyFrame {
        switch frame.kind {
        case .ping:
            return WireReplyFrame(id: frame.id, body: Data("\(GeometryServiceCore.protocolVersion)".utf8))
        case .cancel:
            if let id = UUID(uuidString: String(decoding: frame.body, as: UTF8.self)) {
                await core.cancel(id)
            }
            return WireReplyFrame(id: frame.id, body: Data())
        case .geometryExtract:
            guard let request = try? WireFraming.decodeBody(GeometryWireRequest.self, from: frame.body),
                  let path = frame.filePath
            else {
                return WireReplyFrame(id: frame.id, failure: WireFailure(
                    domain: "ZPDFGeometryService", code: 4, message: "malformed geometryExtract frame"))
            }
            let outcome = await core.extract(request: request, documentAt: URL(fileURLWithPath: path))
            switch outcome {
            case .success(let data): return WireReplyFrame(id: frame.id, body: data)
            case .failure(let failure): return WireReplyFrame(id: frame.id, failure: failure)
            }
        case .geometryRasterize:
            guard let request = try? WireFraming.decodeBody(RasterWireRequest.self, from: frame.body),
                  let path = frame.filePath
            else {
                return WireReplyFrame(id: frame.id, failure: WireFailure(
                    domain: "ZPDFGeometryService", code: 4, message: "malformed geometryRasterize frame"))
            }
            let outcome = await core.rasterize(request: request, documentAt: URL(fileURLWithPath: path))
            switch outcome {
            case .success(let data): return WireReplyFrame(id: frame.id, body: data)
            case .failure(let failure): return WireReplyFrame(id: frame.id, failure: failure)
            }
        case .geometryPageBox:
            guard let request = try? WireFraming.decodeBody(RasterWireRequest.self, from: frame.body),
                  let path = frame.filePath
            else {
                return WireReplyFrame(id: frame.id, failure: WireFailure(
                    domain: "ZPDFGeometryService", code: 4, message: "malformed geometryPageBox frame"))
            }
            switch await core.pageBox(request: request, documentAt: URL(fileURLWithPath: path)) {
            case .success(let data): return WireReplyFrame(id: frame.id, body: data)
            case .failure(let failure): return WireReplyFrame(id: frame.id, failure: failure)
            }
        case .geometryDXF:
            guard let request = try? WireFraming.decodeBody(DXFWireRequest.self, from: frame.body),
                  let path = frame.filePath
            else {
                return WireReplyFrame(id: frame.id, failure: WireFailure(
                    domain: "ZPDFGeometryService", code: 4, message: "malformed geometryDXF frame"))
            }
            switch await core.convertDXF(request: request, documentAt: URL(fileURLWithPath: path)) {
            case .success(let data): return WireReplyFrame(id: frame.id, body: data)
            case .failure(let failure): return WireReplyFrame(id: frame.id, failure: failure)
            }
        case .repairPerform:
            return WireReplyFrame(id: frame.id, failure: WireFailure(
                domain: "ZPDFGeometryService", code: 5, message: "repairPerform is not a geometry operation"))
        }
    }
}

// MARK: - XPC listener path (.xpc bundle)

/// Exported object for one `NSXPCConnection`. The methods are called on XPC's own
/// queues; each hops onto the shared core actor immediately, carrying only
/// Sendable values (the descriptor is dup'ed synchronously — the `FileHandle`
/// argument dies with the XPC message).
final class GeometryXPCExported: NSObject, ZPDFGeometryXPCProtocol {
    private let core: GeometryServiceCore

    init(core: GeometryServiceCore) {
        self.core = core
    }

    func extractPageGeometry(
        _ requestData: Data,
        fileHandle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        guard let request = try? JSONDecoder().decode(GeometryWireRequest.self, from: requestData) else {
            reply(nil, WireFailure(
                domain: "ZPDFGeometryService", code: 4, message: "malformed request payload").nsError)
            return
        }
        let fd = dup(fileHandle.fileDescriptor)
        guard fd >= 0 else {
            reply(nil, WireFailure(
                domain: "ZPDFGeometryService", code: 3, message: "could not dup inherited descriptor").nsError)
            return
        }
        let core = self.core
        Task {
            defer { close(fd) }
            switch await core.extract(request: request, fileDescriptor: fd) {
            case .success(let data): reply(data, nil)
            case .failure(let failure): reply(nil, failure.nsError)
            }
        }
    }

    func rasterizePage(
        _ requestData: Data,
        fileHandle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        guard let request = try? JSONDecoder().decode(RasterWireRequest.self, from: requestData) else {
            reply(nil, WireFailure(
                domain: "ZPDFGeometryService", code: 4, message: "malformed request payload").nsError)
            return
        }
        let fd = dup(fileHandle.fileDescriptor)
        guard fd >= 0 else {
            reply(nil, WireFailure(
                domain: "ZPDFGeometryService", code: 3, message: "could not dup inherited descriptor").nsError)
            return
        }
        let core = self.core
        Task {
            defer { close(fd) }
            switch await core.rasterize(request: request, fileDescriptor: fd) {
            case .success(let data): reply(data, nil)
            case .failure(let failure): reply(nil, failure.nsError)
            }
        }
    }

    func pageBox(
        _ requestData: Data,
        fileHandle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        guard let request = try? JSONDecoder().decode(RasterWireRequest.self, from: requestData) else {
            reply(nil, WireFailure(
                domain: "ZPDFGeometryService", code: 4, message: "malformed request payload").nsError)
            return
        }
        let fd = dup(fileHandle.fileDescriptor)
        guard fd >= 0 else {
            reply(nil, WireFailure(
                domain: "ZPDFGeometryService", code: 3, message: "could not dup inherited descriptor").nsError)
            return
        }
        let core = self.core
        Task {
            defer { close(fd) }
            switch await core.pageBox(request: request, fileDescriptor: fd) {
            case .success(let data): reply(data, nil)
            case .failure(let failure): reply(nil, failure.nsError)
            }
        }
    }

    func convertDXF(
        _ requestData: Data,
        fileHandle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        guard let request = try? JSONDecoder().decode(DXFWireRequest.self, from: requestData) else {
            reply(nil, WireFailure(
                domain: "ZPDFGeometryService", code: 4, message: "malformed request payload").nsError)
            return
        }
        let fd = dup(fileHandle.fileDescriptor)
        guard fd >= 0 else {
            reply(nil, WireFailure(
                domain: "ZPDFGeometryService", code: 3, message: "could not dup inherited descriptor").nsError)
            return
        }
        let core = self.core
        Task {
            defer { close(fd) }
            switch await core.convertDXF(request: request, fileDescriptor: fd) {
            case .success(let data): reply(data, nil)
            case .failure(let failure): reply(nil, failure.nsError)
            }
        }
    }

    func cancelRequest(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        let core = self.core
        Task { await core.cancel(id) }
    }

    func ping(reply: @escaping @Sendable (Int) -> Void) {
        reply(GeometryServiceCore.protocolVersion)
    }
}

/// Listener delegate: allow-lists the exported interface and nothing else.
final class GeometryListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// A request cancelled and still running after the grace ends this process (R-198);
    /// launchd starts a clean one for the next request.
    private let core = GeometryServiceCore(onWedgedCancellation: ServiceWedgeWatchdog.exitProcess)

    override init() {
        // Staged copies an earlier run of this service left when it was killed (R-211).
        _ = GeometryServiceCore.sweepStaleStagedDocuments()
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ZPDFGeometryXPCProtocol.self)
        newConnection.exportedObject = GeometryXPCExported(core: core)
        newConnection.resume()
        return true
    }
}

// MARK: - Entry point

/// What `Apps/GeometryService/Sources/GeometryService/main.swift` calls. `--stdio` runs the frame loop for
/// tests and diagnosis; otherwise this process is an XPC service and serves its
/// listener until launchd ends it.
public enum GeometryServiceMain {
    public static func run() -> Never {
        if CommandLine.arguments.contains("--stdio") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await StdioServiceLoop.run(handler: GeometryStdioHandler(
                    core: GeometryServiceCore(onWedgedCancellation: ServiceWedgeWatchdog.exitProcess)))
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        let delegate = GeometryListenerDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume() // never returns for a service listener
        exit(0)
    }
}
