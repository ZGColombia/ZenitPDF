import Foundation
import ZPDFQPDF
import ZPDFServiceWire

/// The repair service's request handler: qpdf structural operations on a staged
/// copy, output written to a staged temp in this process's container, handed over
/// only when qpdf finished cleanly.
///
/// qpdf calls are synchronous C; each request runs in its own `Task` so a `cancel`
/// or a second request cannot be starved. The staged-output discipline makes the
/// output an atomic handoff: the caller's output file receives either
/// zero bytes or a complete document, never a torn write.
public actor RepairServiceCore {

    public static let protocolVersion = 1

    private var inFlight: [UUID: Task<RepairWireReply, Error>] = [:]
    private var earlyCancels: [UUID] = []
    static let earlyCancelCapacity = 256

    /// R-198: qpdf is synchronous C and never sees a cancellation, so a cancelled or timed-out
    /// repair used to run to its end in the service. The service entry points pass
    /// ``ServiceWedgeWatchdog/exitProcess``; `nil` (the default) leaves the process running.
    private let onWedgedCancellation: (@Sendable () -> Void)?
    private let wedgeGrace: Duration
    private var watchdogs: [UUID: ServiceWedgeWatchdog] = [:]

    public init() {
        self.onWedgedCancellation = nil
        self.wedgeGrace = ServiceWedgeWatchdog.defaultGrace
    }

    /// The core a service process runs: a request cancelled and still running `grace` later
    /// ends the process through `onWedgedCancellation`.
    public init(onWedgedCancellation: @escaping @Sendable () -> Void, grace: Duration = .seconds(5)) {
        self.onWedgedCancellation = onWedgedCancellation
        self.wedgeGrace = grace
    }

    private func armWedgeWatchdog(_ requestID: UUID) {
        guard let onWedgedCancellation, let watchdog = watchdogs[requestID] else { return }
        watchdog.arm(grace: wedgeGrace, onWedged: onWedgedCancellation)
    }

    // MARK: - Entry points

    /// XPC path: input arrives as an inherited read-only descriptor, output (when
    /// the operation writes) as a writable descriptor on an app-container temp file.
    public func perform(
        request: RepairWireRequest,
        inputDescriptor: Int32,
        outputDescriptor: Int32?
    ) async -> RepairReplyOutcome {
        let staged: URL
        do {
            // Off this actor (S-127): a multi-gigabyte copy used to hold the core, so cancels
            // for other repairs and every second request waited behind it.
            staged = try await ServiceStaging.stageDetached(fileDescriptor: inputDescriptor, prefix: Self.stagedInputPrefix)
        } catch {
            return .failure(WireFailure(
                domain: "ZPDFRepairService", code: 3,
                message: "could not stage inherited descriptor: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        return await perform(request: request, inputAt: staged) { producedOutput in
            guard let outputDescriptor else {
                throw WireStageError("operation produced output but no output descriptor was supplied")
            }
            let out = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
            let source = try FileHandle(forReadingFrom: producedOutput)
            defer { try? source.close() }
            var total: Int64 = 0
            while let chunk = try source.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
                total += Int64(chunk.count)
            }
            return total
        }
    }

    /// Stdio path (tests): paths instead of descriptors, same staging discipline.
    public func perform(
        request: RepairWireRequest,
        inputAt input: URL,
        outputPath: String?
    ) async -> RepairReplyOutcome {
        await perform(request: request, inputAt: input) { producedOutput in
            guard let outputPath else {
                throw WireStageError("operation produced output but no output path was supplied")
            }
            let destination = URL(fileURLWithPath: outputPath)
            // Atomic on the same volume; the caller sees nothing until it is whole.
            let partial = destination.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.copyItem(at: producedOutput, to: partial)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64
            return size ?? 0
        }
    }

    /// A cancel that arrives before its request registers is remembered and
    /// honoured at registration, as in the geometry core (BH-658): the stdio loop
    /// dispatches a request and its cancel as independent tasks, so their order of
    /// arrival here is not guaranteed.
    public func cancel(_ requestID: UUID) {
        if let task = inFlight[requestID] {
            task.cancel()
            armWedgeWatchdog(requestID)
            return
        }
        guard !earlyCancels.contains(requestID) else { return }
        earlyCancels.append(requestID)
        if earlyCancels.count > Self.earlyCancelCapacity {
            earlyCancels.removeFirst(earlyCancels.count - Self.earlyCancelCapacity)
        }
    }

    // MARK: - Shared implementation

    /// Runs the qpdf operation against `input`, staging any output in this
    /// process's temp; `handoff` moves the finished bytes to the caller.
    private func perform(
        request: RepairWireRequest,
        inputAt input: URL,
        handoff: @escaping @Sendable (URL) throws -> Int64
    ) async -> RepairReplyOutcome {
        let task = Task<RepairWireReply, Error> {
            if request.debugDelayMilliseconds > 0 {
                try await Task.sleep(
                    nanoseconds: WireDebugDelay.nanoseconds(forMilliseconds: request.debugDelayMilliseconds))
            }
            try Task.checkCancellation()

            switch request.operation {
            case .inspect:
                let inventory = try QPDF.inspect(input, password: request.password)
                return RepairWireReply(
                    message: "inspected",
                    warnings: inventory.report.warnings,
                    warningCount: inventory.report.warningCount,
                    pageCount: Int(inventory.pageCount),
                    isEncrypted: inventory.isEncrypted,
                    isDamaged: inventory.damage.needsRepair)

            case .repair:
                return try Self.writeCopy(input: input, request: request, handoff: handoff) {
                    try QPDF.repair(input: $0, output: $1, password: $2)
                }
            case .decrypt:
                return try Self.writeCopy(input: input, request: request, handoff: handoff) {
                    try QPDF.decrypt(input: $0, output: $1, password: $2)
                }
            case .linearize:
                return try Self.writeCopy(input: input, request: request, handoff: handoff) {
                    try QPDF.linearize(input: $0, output: $1, password: $2)
                }
            case .transform:
                return try Self.transformCopy(input: input, request: request, handoff: handoff)
            case .extractPages:
                guard let indices = request.pageIndices, !indices.isEmpty else {
                    throw QPDFError.invalidArgument("extractPages names no pages")
                }
                return try Self.writeCopy(input: input, request: request, handoff: handoff) {
                    try QPDF.extractPages(input: $0, output: $1, pageIndices: indices, password: $2)
                }
            case .extractPageGroups:
                guard let groups = request.pageGroups, !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }) else {
                    throw QPDFError.invalidArgument("extractPageGroups names no pages")
                }
                return try Self.writeGroups(input: input, request: request, groups: groups, handoff: handoff)
            }
        }
        inFlight[request.requestID] = task
        let watchdog = ServiceWedgeWatchdog()
        watchdogs[request.requestID] = watchdog
        defer {
            watchdog.markFinished()
            inFlight[request.requestID] = nil
            watchdogs[request.requestID] = nil
        }
        if let index = earlyCancels.firstIndex(of: request.requestID) {
            earlyCancels.remove(at: index)
            task.cancel()
            armWedgeWatchdog(request.requestID)
        }
        do {
            return .success(try await task.value)
        } catch let error as QPDFError {
            return .failure(WireFailure(domain: "ZPDFQPDF", code: 100, message: String(describing: error)))
        } catch is CancellationError {
            return .failure(WireFailure(domain: "ZPDFRepairService", code: 1, message: "cancelled", isCancellation: true))
        } catch {
            return .failure(WireFailure(domain: "ZPDFRepairService", code: 2, message: String(describing: error)))
        }
    }

    /// One qpdf write operation, staged then handed off.
    private static func writeCopy(
        input: URL,
        request: RepairWireRequest,
        handoff: (URL) throws -> Int64,
        operation: (URL, URL, String?) throws -> QPDFReport
    ) throws -> RepairWireReply {
        let stagedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("repair-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: stagedOutput) }
        let report = try operation(input, stagedOutput, request.password)
        try Task.checkCancellation()
        let written = try handoff(stagedOutput)
        return RepairWireReply(
            message: report.message,
            warnings: report.warnings,
            warningCount: report.warningCount,
            outputByteCount: written)
    }

    /// Page groups (Split into Sheets, NL-DOCS-08): one parse, one staged file per group, then
    /// the files one after another as the single output, each one's size in the reply — the
    /// wire carries one output, and a call per sheet parsed the drawing once per sheet.
    private static func writeGroups(
        input: URL,
        request: RepairWireRequest,
        groups: [[Int]],
        handoff: (URL) throws -> Int64
    ) throws -> RepairWireReply {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("repair-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try QPDF.extractPageGroups(
            input: input, outputDirectory: folder, basename: "part", pageGroups: groups, password: request.password)
        try Task.checkCancellation()
        let joined = folder.appendingPathComponent("joined.pdf")
        guard FileManager.default.createFile(atPath: joined.path, contents: nil) else {
            throw WireStageError("could not stage the joined page groups")
        }
        var sizes: [Int64] = []
        let out = try FileHandle(forWritingTo: joined)
        do {
            defer { try? out.close() }
            for file in files {
                let source = try FileHandle(forReadingFrom: file)
                defer { try? source.close() }
                var size: Int64 = 0
                while let chunk = try source.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                    try out.write(contentsOf: chunk)
                    size += Int64(chunk.count)
                }
                sizes.append(size)
            }
        }
        try Task.checkCancellation()
        let written = try handoff(joined)
        return RepairWireReply(
            message: "\(files.count) documents",
            warnings: [],
            warningCount: 0,
            outputByteCount: written,
            partByteCounts: sizes)
    }

    /// A transform (NL-PDF-08, NL-PDF-09), staged then handed off like every write.
    private static func transformCopy(
        input: URL,
        request: RepairWireRequest,
        handoff: (URL) throws -> Int64
    ) throws -> RepairWireReply {
        guard let wire = request.transform else {
            throw QPDFError.invalidArgument("a transform request carries no transform")
        }
        let stagedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("transform-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: stagedOutput) }
        let protection = wire.protection.map {
            QPDFTransform.Protection(
                openPassword: $0.openPassword,
                permissionsPassword: $0.permissionsPassword,
                printing: QPDFTransform.Printing(rawValue: Int32($0.printing)) ?? .full,
                allowsChanges: $0.allowsChanges,
                allowsCopying: $0.allowsCopying,
                allowsAnnotating: $0.allowsAnnotating
            )
        }
        let result = try QPDF.transform(
            input: input,
            output: stagedOutput,
            password: request.password,
            transform: QPDFTransform(
                flattensAnnotations: wire.flattensAnnotations,
                compresses: wire.compresses,
                sanitizes: wire.sanitizes,
                protection: protection,
                linearizes: wire.linearizes,
                downsampling: wire.pictureTargetDPI.map { QPDFImageDownsampling(targetDPI: $0) }
            )
        )
        try Task.checkCancellation()
        let written = try handoff(stagedOutput)
        return RepairWireReply(
            message: result.report.message,
            warnings: result.report.warnings,
            warningCount: result.report.warningCount,
            outputByteCount: written,
            transformSummary: RepairWireTransformSummary(
                flattenedAnnotationCount: result.flattenedAnnotationCount,
                removedJavaScript: result.removedJavaScript,
                removedEmbeddedFiles: result.removedEmbeddedFiles,
                removedActionCount: result.removedActionCount,
                removedMetadata: result.removedMetadata,
                inputByteCount: result.inputByteCount,
                downsampledImageCount: result.downsampledImageCount,
                offeredImageCount: result.offeredImageCount
            )
        )
    }

    /// The staged input's name prefix. The name is the service's own and never carries the
    /// request's `fileName` (BH-650, BH-651); ``ServiceStaging/stage(fileDescriptor:prefix:in:)``
    /// removes a partial copy on a read or write error (S-117).
    static let stagedInputPrefix = "repair-in-"

    /// Every name this core stages under in its temporary directory: the input
    /// (`repair-in-<UUID>.pdf`), a write's output (`repair-<UUID>.pdf`), a transform's
    /// (`transform-<UUID>.pdf`) and page groups (`repair-groups-<UUID>/`).
    static let stagedNamePrefixes = ["repair-", "transform-"]

    /// Deletes what an earlier run of the service left behind (S-117): every staged file above
    /// is removed only by a `defer`, and the wedge watchdog's `_exit` runs none. Called by the
    /// XPC listener at start, where the temporary directory is the service container's own —
    /// never by the stdio test worker, whose temporary directory other processes share.
    @discardableResult
    static func sweepStaleStagedFiles(in directory: URL = FileManager.default.temporaryDirectory,
                                      olderThan age: TimeInterval = 600, now: Date = Date()) -> Int {
        ServiceStaging.sweepStale(prefixes: stagedNamePrefixes, in: directory, olderThan: age, now: now)
    }
}

/// The one conformance in the repository. `RepairServiceCore`'s stdio entry point
/// already has the required shape, so the fallback the tests use is byte-for-byte
/// the code the service runs — and the target that carries it, and with it qpdf, is
/// one the application does not link. See ``RepairInProcessExecuting`` (S17-03).
extension RepairServiceCore: RepairInProcessExecuting {}

struct WireStageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
