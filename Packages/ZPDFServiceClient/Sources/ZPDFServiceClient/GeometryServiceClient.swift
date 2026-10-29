import Foundation
import ZPDFGeometryServiceCore
import ZPDFServiceWire
import ZPDFVectorExtraction

/// The app's door to vector extraction, whichever process does the work.
///
/// Backends, in the order the app prefers them:
///
/// - `.xpcService` — `GeometryService.xpc` embedded in the app bundle. Parsing a
///   hostile drawing can kill that process; the app survives, this client throws
///   ``ZPDFServiceError/serviceCrashed(service:detail:)`` only after its restart
///   budget is spent, and the restarted service answers the retry.
/// - `.subprocess` — the same service core over stdio pipes; what `swift test`
///   uses, since an `.xpc` bundle cannot launch outside its host app.
/// - `.inProcess` — the existing `VectorExtractor` path, byte-for-byte the code
///   that ran before S15. Dev builds and tests without a service lose isolation,
///   never behaviour.
///
/// `automatic()` picks `.xpcService` when the running bundle embeds the service
/// and `.inProcess` otherwise, so a plain `swift run` keeps working.
public actor ZPDFGeometryServiceClient {

    public enum Backend: Sendable {
        case inProcess
        case subprocess(executableURL: URL)
        case xpcService
    }

    private let backend: Backend
    /// How many times a crashed service is restarted and the request retried
    /// before ``ZPDFServiceError/serviceCrashed(service:detail:)`` reaches the
    /// caller. One by default: a second crash on the same request means the
    /// document, not luck, is killing the worker.
    private let maximumRestarts: Int
    /// The wall clock every request across this boundary races (CR-122). Crash
    /// isolation only ever caught a worker that *died*; a worker that lives and
    /// never answers left the caller's continuation unresumed forever. Injectable
    /// so the regression suite can use a deadline it can actually wait out.
    private let deadline: ZPDFServiceDeadline

    private var subprocess: WireSubprocessConnection?
    private var xpc: GeometryXPCTransport?

    public init(
        backend: Backend,
        maximumRestarts: Int = 1,
        deadline: ZPDFServiceDeadline = .geometry
    ) {
        self.backend = backend
        self.maximumRestarts = maximumRestarts
        self.deadline = deadline
    }

    public static func automatic() -> ZPDFGeometryServiceClient {
        ZPDFGeometryServiceClient(
            backend: GeometryXPCTransport.serviceIsEmbedded ? .xpcService : .inProcess)
    }

    /// Times a worker was spawned (subprocess backend only) — the crash tests
    /// assert restarts through this.
    public var workerLaunchCount: Int {
        get async {
            guard let subprocess else { return 0 }
            return await subprocess.launchCount
        }
    }

    /// The worker's pid, when one is running (subprocess backend only).
    public var workerProcessIdentifier: Int32? {
        get async {
            guard let subprocess else { return nil }
            return await subprocess.processIdentifier
        }
    }

    /// Test hook: SIGKILL the worker (subprocess backend only).
    public func killWorkerForTesting() async {
        await subprocess?.killForTesting()
    }

    public func shutdown() async {
        await subprocess?.shutdown()
        await xpc?.reset()
    }

    // MARK: - Extraction

    /// Extracts one page, wherever the backend runs it. Cancellation of the
    /// calling task is forwarded across the boundary as a cancel request.
    public func extractPageGeometry(
        documentAt url: URL,
        pageIndex: Int,
        options: GeometryWireOptions = GeometryWireOptions(),
        debugDelayMilliseconds: Int = 0
    ) async throws -> VectorPageExtraction {
        let request = GeometryWireRequest(
            pageIndex: pageIndex,
            options: options,
            fileName: url.lastPathComponent,
            debugDelayMilliseconds: debugDelayMilliseconds)
        return try await withRestart {
            if case .inProcess = backend { return try await extractInProcess(request: request, url: url) }
            return try decodeExtraction(try await remote(
                kind: .geometryExtract, xpc: .extract, body: try encodeRequest(request),
                requestID: request.requestID, url: url))
        }
    }

    /// The fallback: exactly the pre-S15 code path, with the same error surface
    /// the remote backends have, so the caller cannot tell where the work ran.
    private func extractInProcess(request: GeometryWireRequest, url: URL) async throws -> VectorPageExtraction {
        if request.debugDelayMilliseconds > 0 {
            do {
                try await Task.sleep(
                    nanoseconds: WireDebugDelay.nanoseconds(forMilliseconds: request.debugDelayMilliseconds))
            } catch {
                throw ZPDFServiceError.cancelled
            }
        }
        let extractor = VectorExtractor(options: GeometryServiceCore.options(from: request.options))
        do {
            return try await extractor.extract(
                documentAt: url, pageIndex: request.pageIndex, password: request.options.password)
        } catch let error as VectorExtractionError {
            if case .cancelled = error { throw ZPDFServiceError.cancelled }
            throw ZPDFServiceError.remoteFailure(
                domain: "ZPDFVectorExtraction", code: 100, message: String(describing: error))
        }
    }

    // MARK: - Rasterisation (S17-02)

    /// Rasterises one page to 8-bit gray, wherever the backend runs it.
    ///
    /// The same restart-once-on-crash policy extraction has, for the same reason:
    /// the page that killed the service is a page an attacker chose.
    public func rasterizePage(
        documentAt url: URL,
        pageIndex: Int,
        box: RasterWireBox,
        scale: Double,
        maximumPixels: Int = 64_000_000,
        debugDelayMilliseconds: Int = 0
    ) async throws -> RasterWirePage {
        let request = RasterWireRequest(
            pageIndex: pageIndex,
            box: box,
            scale: scale,
            maximumPixels: maximumPixels,
            fileName: url.lastPathComponent,
            debugDelayMilliseconds: debugDelayMilliseconds)
        return try await withRestart {
            let data: Data
            if case .inProcess = backend {
                // The fallback, for `swift test` and for a bundle with no service: the same
                // rasteriser the service runs, in this process.
                data = try Self.body(of: await GeometryServiceCore().rasterize(request: request, documentAt: url))
            } else {
                data = try await remote(kind: .geometryRasterize, xpc: .rasterize, body: try encodeRequest(request),
                                        requestID: request.requestID, url: url)
            }
            return try decodeRaster(data, maximumPixels: request.maximumPixels)
        }
    }

    /// One page's box and rotation, with no pixels rendered.
    ///
    /// CR-127: this was once the one operation with no cancellation handler, so a cancelled
    /// page-box read never reached the worker. It now shares ``remote(kind:xpc:body:requestID:url:)``
    /// with every other operation, cancellation forwarding included.
    public func pageBox(
        documentAt url: URL,
        pageIndex: Int,
        box: RasterWireBox,
        debugDelayMilliseconds: Int = 0
    ) async throws -> PageBoxWireReply {
        let request = RasterWireRequest(
            pageIndex: pageIndex, box: box, scale: 1, fileName: url.lastPathComponent,
            debugDelayMilliseconds: debugDelayMilliseconds)
        return try await withRestart {
            let data: Data
            if case .inProcess = backend {
                data = try Self.body(of: await GeometryServiceCore().pageBox(request: request, documentAt: url))
            } else {
                data = try await remote(kind: .geometryPageBox, xpc: .pageBox, body: try encodeRequest(request),
                                        requestID: request.requestID, url: url)
            }
            return try decodePageBox(data)
        }
    }

    private func decodePageBox(_ data: Data) throws -> PageBoxWireReply {
        do {
            return try JSONDecoder().decode(PageBoxWireReply.self, from: data).validated()
        } catch {
            throw ZPDFServiceError.malformedReply(
                service: ZPDFGeometryServiceIdentity.bundleName,
                detail: "page-box payload would not decode: \(String(describing: error))")
        }
    }

    /// `maximumPixels` is the request's own budget: a reply larger than what was
    /// asked for is refused here, before its pixels are copied (BH-656).
    private func decodeRaster(_ data: Data, maximumPixels: Int) throws -> RasterWirePage {
        do {
            return try RasterWireCodec.decode(data, maximumPixels: maximumPixels)
        } catch {
            throw ZPDFServiceError.malformedReply(
                service: ZPDFGeometryServiceIdentity.bundleName,
                detail: "raster payload would not decode: \(String(describing: error))")
        }
    }

    // MARK: - DXF (NL-PLAT-05, round 2)

    /// Converts a `.dxf` to a PDF sheet wherever the backend runs it: in `GeometryService.xpc`
    /// when the bundle embeds it, so the application never parses the untrusted file. The same
    /// restart-once-on-crash policy as extraction.
    public func convertDXF(documentAt url: URL, title: String, debugDelayMilliseconds: Int = 0) async throws -> DXFWireSheet {
        let request = DXFWireRequest(title: title, fileName: url.lastPathComponent, debugDelayMilliseconds: debugDelayMilliseconds)
        return try await withRestart {
            let data: Data
            if case .inProcess = backend {
                // A build with no service bundle (`swift test`, a plain `swift run`): the same core,
                // in this process — isolation is lost, behaviour is not.
                data = try Self.body(of: await GeometryServiceCore().convertDXF(request: request, documentAt: url))
            } else {
                data = try await remote(kind: .geometryDXF, xpc: .convertDXF, body: try encodeRequest(request),
                                        requestID: request.requestID, url: url)
            }
            do {
                return try DXFWireCodec.decode(data)
            } catch {
                throw ZPDFServiceError.malformedReply(
                    service: ZPDFGeometryServiceIdentity.bundleName,
                    detail: "sheet payload would not decode: \(String(describing: error))")
            }
        }
    }

    // MARK: - One boundary, written once (R-213)

    /// Runs `body`, restarting a crashed service and retrying up to ``maximumRestarts`` times —
    /// never for a caller that has cancelled (S-116). The policy is ``withServiceRestart(maximumRestarts:isolation:restart:_:)``,
    /// shared with the repair client.
    private func withRestart<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await withServiceRestart(maximumRestarts: maximumRestarts, restart: { await restartAfterCrash() }, body)
    }

    /// One request to a remote backend: a wire frame over the subprocess worker's pipes, or the
    /// operation over XPC with the document handed over as a read-only descriptor. Cancellation
    /// of the calling task is forwarded across the boundary either way, and the reply body is
    /// returned undecoded.
    private func remote(
        kind: WireRequestKind,
        xpc operation: GeometryXPCOperation,
        body: Data,
        requestID: UUID,
        url: URL
    ) async throws -> Data {
        switch backend {
        case .inProcess:
            throw ZPDFServiceError.serviceUnavailable(
                service: ZPDFGeometryServiceIdentity.bundleName, detail: "no remote backend in process")

        case .subprocess(let executableURL):
            let connection = existingSubprocess(executableURL: executableURL)
            let frame = WireRequestFrame(kind: kind, body: body, filePath: url.path)
            let reply = try await withTaskCancellationHandler {
                try await connection.send(frame, cancelID: requestID)
            } onCancel: {
                Task { await connection.sendCancel(for: requestID) }
            }
            if let failure = reply.failure { throw failure.serviceError }
            guard let data = reply.body else {
                throw ZPDFServiceError.malformedReply(
                    service: ZPDFGeometryServiceIdentity.bundleName, detail: "empty reply body")
            }
            return data

        case .xpcService:
            let transport = existingXPC()
            let handle = try readHandle(for: url)
            defer { try? handle.close() }
            return try await withTaskCancellationHandler {
                try await transport.perform(
                    operation,
                    requestData: body,
                    documentDescriptor: handle.fileDescriptor,
                    requestID: requestID,
                    deadline: deadline.extended(forStagingBytes: ZPDFServiceDeadline.stagingByteCount(of: handle)))
            } onCancel: {
                Task { await transport.cancel(requestID: requestID) }
            }
        }
    }

    /// The in-process core's answer as the remote backends' would be: the body, or the failure.
    private static func body(of outcome: WireReplyOutcome) throws -> Data {
        switch outcome {
        case .success(let data): return data
        case .failure(let failure): throw failure.serviceError
        }
    }

    private func encodeRequest<Request: Encodable>(_ request: Request) throws -> Data {
        do {
            return try JSONEncoder().encode(request)
        } catch {
            throw ZPDFServiceError.malformedReply(
                service: ZPDFGeometryServiceIdentity.bundleName,
                detail: "request would not encode: \(error.localizedDescription)")
        }
    }

    // MARK: - Support

    private func restartAfterCrash() async {
        switch backend {
        case .inProcess:
            break
        case .subprocess:
            // Nothing to tear down: the dead process was already reaped when the
            // reader saw EOF; the next send respawns.
            break
        case .xpcService:
            await xpc?.reset()
        }
    }

    private func existingSubprocess(executableURL: URL) -> WireSubprocessConnection {
        if let subprocess { return subprocess }
        let fresh = WireSubprocessConnection(executableURL: executableURL, deadline: deadline)
        subprocess = fresh
        return fresh
    }

    private func existingXPC() -> GeometryXPCTransport {
        if let xpc { return xpc }
        let fresh = GeometryXPCTransport()
        xpc = fresh
        return fresh
    }

    private func decodeExtraction(_ data: Data) throws -> VectorPageExtraction {
        do {
            return try VectorExtractionCodec.decode(data)
        } catch {
            throw ZPDFServiceError.malformedReply(
                service: ZPDFGeometryServiceIdentity.bundleName,
                detail: "extraction payload would not decode: \(String(describing: error))")
        }
    }

    private func readHandle(for url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw ZPDFServiceError.serviceUnavailable(
                service: ZPDFGeometryServiceIdentity.bundleName,
                detail: "could not open document read-only: \(error.localizedDescription)")
        }
    }
}
