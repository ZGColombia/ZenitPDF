import Foundation
import ZPDFPDFKitBridge
import ZPDFServiceWire

/// The app's door to qpdf structural operations — repair, decrypt, linearize,
/// inspect — run out of process when `RepairService.xpc` is embedded.
///
/// The output discipline: the original is never touched, the
/// service writes into a staging file in a private folder on the destination's
/// volume (`StagedFileReplacement.stagingDirectory`), and only a fully written
/// result is renamed into place. A crash anywhere leaves the destination untouched.
/// The staging file used to be a hidden sibling of the destination, which a
/// sandboxed save panel does not grant, so every write to a chosen file failed in
/// the shipped app (V-051, the C-09 shape).
public actor ZPDFRepairServiceClient {

    public enum Backend: Sendable {
        /// The fallback, and the only way to reach qpdf without a service process.
        /// It carries its executor rather than calling `ZPDFQPDF` directly: this
        /// target does not link qpdf at all any more, so a binary that links only
        /// `ZPDFServiceClient` — which is exactly what `Zenit PDF.app` links —
        /// cannot construct this case. See ``RepairInProcessExecuting`` (S17-03).
        case inProcess(any RepairInProcessExecuting)
        case subprocess(executableURL: URL)
        case xpcService
    }

    private let backend: Backend
    private let maximumRestarts: Int
    /// The wall clock every request across this boundary races (CR-122). qpdf
    /// legitimately takes minutes on a large set, so this one is long — but it is
    /// finite, which is the whole point: a wedged worker used to leave the
    /// caller's continuation unresumed forever. Injectable so the regression
    /// suite can use a deadline it can actually wait out.
    private let deadline: ZPDFServiceDeadline

    private var subprocess: WireSubprocessConnection?
    private var xpc: RepairXPCTransport?

    public init(
        backend: Backend,
        maximumRestarts: Int = 1,
        deadline: ZPDFServiceDeadline = .repair
    ) {
        self.backend = backend
        self.maximumRestarts = maximumRestarts
        self.deadline = deadline
    }

    /// The application's constructor. Always the XPC service — there is no
    /// silent in-process fallback here any more, and there cannot be one: the
    /// executor type that would perform it is not linked into this target.
    ///
    /// When the service bundle is missing the request fails with a typed
    /// ``ZPDFServiceError/serviceUnavailable(service:detail:)`` rather than
    /// quietly handing a hostile document to qpdf inside the application. A
    /// shipped bundle always embeds the service — it is inside the sealed, signed
    /// bundle — so this changes nothing that ships and everything that could
    /// regress.
    public static func automatic() -> ZPDFRepairServiceClient {
        ZPDFRepairServiceClient(backend: .xpcService)
    }

    /// `swift test`'s constructor: the same preference order the app used to
    /// have, with the in-process fallback supplied explicitly by a caller that
    /// links `ZPDFRepairServiceCore`.
    public static func automatic(
        inProcessFallback: any RepairInProcessExecuting
    ) -> ZPDFRepairServiceClient {
        ZPDFRepairServiceClient(
            backend: RepairXPCTransport.serviceIsEmbedded
                ? .xpcService : .inProcess(inProcessFallback))
    }

    public var workerLaunchCount: Int {
        get async {
            guard let subprocess else { return 0 }
            return await subprocess.launchCount
        }
    }

    public func killWorkerForTesting() async {
        await subprocess?.killForTesting()
    }

    public func shutdown() async {
        await subprocess?.shutdown()
        await xpc?.reset()
    }

    // MARK: - Operations

    /// Parse-and-report; writes nothing.
    public func inspect(
        _ input: URL,
        password: String? = nil,
        debugDelayMilliseconds: Int = 0
    ) async throws -> RepairWireReply {
        try await perform(
            RepairWireRequest(
                operation: .inspect,
                password: password,
                fileName: input.lastPathComponent,
                debugDelayMilliseconds: debugDelayMilliseconds),
            input: input,
            output: nil)
    }

    /// Rebuild `input` into a structurally correct copy at `output` (never in place).
    @discardableResult
    public func repair(
        input: URL, output: URL, password: String? = nil, debugDelayMilliseconds: Int = 0
    ) async throws -> RepairWireReply {
        try await perform(
            RepairWireRequest(
                operation: .repair,
                password: password,
                fileName: input.lastPathComponent,
                debugDelayMilliseconds: debugDelayMilliseconds),
            input: input,
            output: output)
    }

    /// Write a decrypted copy using the user-authorised password.
    @discardableResult
    public func decrypt(
        input: URL, output: URL, password: String?, debugDelayMilliseconds: Int = 0
    ) async throws -> RepairWireReply {
        try await perform(
            RepairWireRequest(
                operation: .decrypt,
                password: password,
                fileName: input.lastPathComponent,
                debugDelayMilliseconds: debugDelayMilliseconds),
            input: input,
            output: output)
    }

    /// Write a linearized copy.
    @discardableResult
    public func linearize(
        input: URL, output: URL, password: String? = nil, debugDelayMilliseconds: Int = 0
    ) async throws -> RepairWireReply {
        try await perform(
            RepairWireRequest(
                operation: .linearize,
                password: password,
                fileName: input.lastPathComponent,
                debugDelayMilliseconds: debugDelayMilliseconds),
            input: input,
            output: output)
    }

    /// Write a flattened, compressed, sanitised and/or encrypted copy (NL-PDF-08, NL-PDF-09).
    @discardableResult
    public func transform(
        input: URL, output: URL, password: String? = nil, transform: RepairWireTransform,
        debugDelayMilliseconds: Int = 0
    ) async throws -> RepairWireReply {
        try await perform(
            RepairWireRequest(
                operation: .transform,
                password: password,
                fileName: input.lastPathComponent,
                debugDelayMilliseconds: debugDelayMilliseconds,
                transform: transform),
            input: input,
            output: output)
    }

    /// Write the pages `pageIndices` names (zero-based, in that order) to `output` as a new
    /// document, with their page labels and the document's layer definitions, by qpdf in the
    /// repair service (NL-DOCS-08). The input is never written.
    @discardableResult
    public func extractPages(
        input: URL, output: URL, pageIndices: [Int], password: String? = nil, debugDelayMilliseconds: Int = 0
    ) async throws -> RepairWireReply {
        try await perform(
            RepairWireRequest(
                operation: .extractPages,
                password: password,
                fileName: input.lastPathComponent,
                debugDelayMilliseconds: debugDelayMilliseconds,
                pageIndices: pageIndices),
            input: input,
            output: output)
    }

    /// Write each group of `pageGroups` (zero-based pages, in order) to the matching URL of
    /// `outputs`, as ``extractPages(input:output:pageIndices:password:debugDelayMilliseconds:)``
    /// writes one, from one parse of `input` in the repair service (Split into Sheets,
    /// NL-DOCS-08). All or nothing: when anything fails, no output is left. The input is never
    /// written.
    @discardableResult
    public func extractPageGroups(
        input: URL, outputs: [URL], pageGroups: [[Int]], password: String? = nil
    ) async throws -> RepairWireReply {
        guard let first = outputs.first, outputs.count == pageGroups.count,
              !outputs.contains(where: { $0.standardizedFileURL.path == input.standardizedFileURL.path }) else {
            throw ZPDFServiceError.remoteFailure(
                domain: "ZPDFRepairServiceClient", code: 1,
                message: "extractPageGroups needs one output per group, none of them the input")
        }
        let joinedFolder = try Self.stagingFolder(for: first)
        let joined = joinedFolder.appendingPathComponent("zpdf-groups-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: joinedFolder) }
        let reply = try await perform(
            RepairWireRequest(
                operation: .extractPageGroups,
                password: password,
                fileName: input.lastPathComponent,
                pageGroups: pageGroups),
            input: input,
            output: joined)
        let size = (try? FileManager.default.attributesOfItem(atPath: joined.path)[.size] as? Int64) ?? -1
        guard let parts = reply.partByteCounts, parts.count == outputs.count, parts.allSatisfy({ $0 > 0 }),
              parts.reduce(0, +) == size else {
            throw ZPDFServiceError.malformedReply(
                service: ZPDFRepairServiceIdentity.bundleName,
                detail: "the page groups' sizes do not add up to the output")
        }
        var written: [URL] = []
        do {
            let source = try FileHandle(forReadingFrom: joined)
            defer { try? source.close() }
            for (url, part) in zip(outputs, parts) {
                let data = try source.read(upToCount: Int(part)) ?? Data()
                guard data.count == Int(part) else {
                    throw ZPDFServiceError.malformedReply(
                        service: ZPDFRepairServiceIdentity.bundleName, detail: "a page group ended early")
                }
                try data.write(to: url, options: .atomic)
                written.append(url)
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return reply
    }

    // MARK: - Dispatch

    private func perform(
        _ request: RepairWireRequest,
        input: URL,
        output: URL?
    ) async throws -> RepairWireReply {
        // The restart policy the geometry client uses, cancellation included (S-116): a cancel
        // that ends the service is reported as the cancel, never retried.
        try await withServiceRestart(
            maximumRestarts: maximumRestarts,
            restart: { if case .xpcService = backend { await xpc?.reset() } }
        ) {
            try await performOnce(request: request, input: input, output: output)
        }
    }

    private func performOnce(
        request: RepairWireRequest,
        input: URL,
        output: URL?
    ) async throws -> RepairWireReply {
        // Stage in a private folder on the destination's volume, so the final rename is atomic,
        // and never beside the destination: a sandboxed save panel grants the chosen file and
        // nothing next to it (V-051).
        let stagingFolder = try output.map { try Self.stagingFolder(for: $0) }
        let staging = stagingFolder?.appendingPathComponent("zpdf-staging-\(UUID().uuidString).pdf")
        defer { if let stagingFolder { try? FileManager.default.removeItem(at: stagingFolder) } }

        let reply: RepairWireReply
        switch backend {
        case .inProcess(let executor):
            reply = try await performInProcess(
                executor: executor, request: request, input: input, staging: staging)

        case .subprocess(let executableURL):
            let connection = existingSubprocess(executableURL: executableURL)
            let frame = WireRequestFrame(
                kind: .repairPerform,
                body: try encode(request),
                filePath: input.path,
                outputPath: staging?.path)
            let wireReply = try await withTaskCancellationHandler {
                try await connection.send(frame, cancelID: request.requestID)
            } onCancel: {
                let requestID = request.requestID
                Task { await connection.sendCancel(for: requestID) }
            }
            if let failure = wireReply.failure { throw failure.serviceError }
            guard let body = wireReply.body else {
                throw ZPDFServiceError.malformedReply(
                    service: ZPDFRepairServiceIdentity.bundleName, detail: "empty reply body")
            }
            reply = try decodeReply(body)

        case .xpcService:
            let transport = existingXPC()
            let inputHandle = try readHandle(for: input)
            defer { try? inputHandle.close() }
            var outputHandle: FileHandle?
            if let staging {
                // CR-136: `try?` here turned "the staging file would not open"
                // into a nil descriptor, and the service then reported "no output
                // descriptor supplied" — a message about our own request, with the
                // real cause (a full or read-only volume, a sandbox denial)
                // discarded at the point it was known. Fail with what happened.
                guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
                    throw ZPDFServiceError.serviceUnavailable(
                        service: ZPDFRepairServiceIdentity.bundleName,
                        detail: "could not create the staging file at \(staging.path)")
                }
                do {
                    outputHandle = try FileHandle(forWritingTo: staging)
                } catch {
                    throw ZPDFServiceError.serviceUnavailable(
                        service: ZPDFRepairServiceIdentity.bundleName,
                        detail: "could not open the staging file for writing: "
                            + error.localizedDescription)
                }
            }
            defer { try? outputHandle?.close() }
            let data = try await withTaskCancellationHandler {
                try await transport.perform(
                    requestData: try encode(request),
                    inputDescriptor: inputHandle.fileDescriptor,
                    outputDescriptor: outputHandle?.fileDescriptor,
                    requestID: request.requestID,
                    deadline: Self.xpcDeadline(deadline, input: inputHandle))
            } onCancel: {
                let requestID = request.requestID
                Task { await transport.cancel(requestID: requestID) }
            }
            reply = try decodeReply(data)
        }

        // Atomic handoff: promote the staging file only after a clean reply, and only for a
        // caller that still wants it — a job stopped while the service finished leaves no
        // output (S-116; the staging file goes with the defer above).
        if let staging, let output {
            if Task.isCancelled { throw ZPDFServiceError.cancelled }
            do {
                try StagedFileReplacement.place(staging, at: output)
            } catch {
                throw ZPDFServiceError.malformedReply(
                    service: ZPDFRepairServiceIdentity.bundleName,
                    detail: "output handoff failed: \(error.localizedDescription)")
            }
        }
        return reply
    }

    /// The allowance for one request through the XPC service (V-091): `base` plus the time to
    /// copy the input in and an output of about the input's size back out.
    ///
    /// The service stages the whole input into its own temporary folder before qpdf reads a
    /// byte, and copies the file it produced back through the output descriptor after qpdf is
    /// done — two full copies the flat 300 s never budgeted for. On a large set on a slow volume
    /// they could spend most of it, and a timeout is never retried: the client cancels and the
    /// watchdog ends the service (R-198). Geometry has had the same extension since BH-212.
    package static func xpcDeadline(_ base: ZPDFServiceDeadline, input handle: FileHandle) -> ZPDFServiceDeadline {
        base.extended(forStagingBytes: 2 * ZPDFServiceDeadline.stagingByteCount(of: handle))
    }

    /// The fallback: the *service's own* handler, run in this process by an
    /// executor the caller injected. Same staging discipline, same typed error
    /// surface as the remote backends — and no qpdf symbol in this file.
    private func performInProcess(
        executor: any RepairInProcessExecuting,
        request: RepairWireRequest,
        input: URL,
        staging: URL?
    ) async throws -> RepairWireReply {
        if request.debugDelayMilliseconds > 0 {
            do {
                try await Task.sleep(
                    nanoseconds: WireDebugDelay.nanoseconds(forMilliseconds: request.debugDelayMilliseconds))
            } catch {
                throw ZPDFServiceError.cancelled
            }
        }
        if request.operation != .inspect, staging == nil {
            throw ZPDFServiceError.malformedReply(
                service: ZPDFRepairServiceIdentity.bundleName,
                detail: "write operation without an output URL")
        }
        switch await executor.perform(
            request: request, inputAt: input, outputPath: staging?.path
        ) {
        case .success(let reply):
            return reply
        case .failure(let failure):
            throw failure.serviceError
        }
    }

    // MARK: - Support

    /// A new private folder to stage a file bound for `output` in: the one staging rule every
    /// writer shares, with its failure named as this client's.
    private static func stagingFolder(for output: URL) throws -> URL {
        do {
            return try StagedFileReplacement.stagingDirectory(appropriateFor: output)
        } catch {
            throw ZPDFServiceError.serviceUnavailable(
                service: ZPDFRepairServiceIdentity.bundleName,
                detail: "could not create a staging folder for \(output.lastPathComponent): "
                    + error.localizedDescription)
        }
    }

    private func existingSubprocess(executableURL: URL) -> WireSubprocessConnection {
        if let subprocess { return subprocess }
        let fresh = WireSubprocessConnection(executableURL: executableURL, deadline: deadline)
        subprocess = fresh
        return fresh
    }

    private func existingXPC() -> RepairXPCTransport {
        if let xpc { return xpc }
        let fresh = RepairXPCTransport()
        xpc = fresh
        return fresh
    }

    private func encode(_ request: RepairWireRequest) throws -> Data {
        do {
            return try JSONEncoder().encode(request)
        } catch {
            throw ZPDFServiceError.malformedReply(
                service: ZPDFRepairServiceIdentity.bundleName,
                detail: "request would not encode: \(error.localizedDescription)")
        }
    }

    private func decodeReply(_ data: Data) throws -> RepairWireReply {
        do {
            return try JSONDecoder().decode(RepairWireReply.self, from: data)
        } catch {
            throw ZPDFServiceError.malformedReply(
                service: ZPDFRepairServiceIdentity.bundleName,
                detail: "reply would not decode: \(error.localizedDescription)")
        }
    }

    private func readHandle(for url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw ZPDFServiceError.serviceUnavailable(
                service: ZPDFRepairServiceIdentity.bundleName,
                detail: "could not open document read-only: \(error.localizedDescription)")
        }
    }
}
