import Foundation
import ZPDFPDFKitBridge
import ZPDFServiceWire
import ZPDFVectorExtraction

/// The geometry service's request handler — the same object behind the `.xpc`
/// listener and the stdio test worker, so the tested code is the shipped code.
///
/// An actor: it owns the table of in-flight tasks that ``cancel(_:)`` needs, and
/// `VectorExtractor` is created per request (one document per request; the
/// service holds no document cache — the app-side cache in `ZPDFVectorExtraction`
/// already de-duplicates by digest).
public actor GeometryServiceCore {

    /// Bumped when the wire contract changes incompatibly. Returned by `ping`.
    public static let protocolVersion = 1

    private var inFlight: [UUID: Task<Data, Error>] = [:]

    /// Cancels that arrived before the request they name was registered (BH-658).
    ///
    /// A request frame and its cancel are dispatched as independent tasks, and
    /// which reaches this actor first is not ordered; nor is a cancel that lands
    /// while the request is still staging its document. The cancel used to be a
    /// plain lookup that did nothing on a miss, so the work then ran to
    /// completion for a caller who had already walked away. A miss is remembered
    /// here instead and honoured at registration. Bounded, oldest dropped: a
    /// cancel for a request that already finished (a deadline abandon racing the
    /// reply) names a UUID that will never be registered again.
    private var earlyCancels: [UUID] = []
    static let earlyCancelCapacity = 256

    /// Staged copies of inherited documents, reused across requests (BH-212).
    private var staged: [StagingKey: StagedDocument] = [:]
    private var stagingClock: UInt64 = 0
    private let stagingIdleExpiry: Duration

    /// Whole-file copies made by ``stage(fileDescriptor:)`` since this core was
    /// created. The staging-reuse test asserts that one document costs one copy.
    private(set) var stagingCopyCount = 0

    /// At most this many staged documents are kept for reuse, and at most
    /// ``stagedByteCapacity`` bytes of them. Two, because Revision Compare
    /// alternates between exactly two documents; the per-page extraction loop
    /// needs one.
    static let stagedDocumentCapacity = 2
    static let defaultStagedByteCapacity: Int64 = 2 * 1024 * 1024 * 1024
    /// The byte cap. It makes room for another document; it never evicts the most recently
    /// used copy on its own (S-128). Injectable so a test can use a small one.
    let stagedByteCapacity: Int64

    /// Copies in progress, keyed like ``staged`` (R-211), so concurrent requests for one
    /// document share one copy while the actor stays free for cancels and other documents.
    private var stagingInFlight: [StagingKey: Task<URL, Error>] = [:]

    /// R-198: what a wedged cancelled request does to this process — `nil` (the default, and
    /// always in the application's in-process fallback) leaves it running; the service entry
    /// points pass ``ServiceWedgeWatchdog/exitProcess``.
    private let onWedgedCancellation: (@Sendable () -> Void)?
    private let wedgeGrace: Duration
    private var watchdogs: [UUID: ServiceWedgeWatchdog] = [:]

    public init() {
        self.init(stagingIdleExpiry: .seconds(120))
    }

    /// The core a service process runs (R-198): a request that is cancelled and still running
    /// `grace` later ends the process through `onWedgedCancellation`.
    public init(onWedgedCancellation: @escaping @Sendable () -> Void, grace: Duration = ServiceWedgeWatchdog.defaultGrace) {
        self.init(stagingIdleExpiry: .seconds(120), onWedgedCancellation: onWedgedCancellation, wedgeGrace: grace)
    }

    /// `stagingIdleExpiry`: how long a staged copy nobody is using survives before
    /// it is deleted. Injectable so a test can wait it out.
    init(
        stagingIdleExpiry: Duration,
        onWedgedCancellation: (@Sendable () -> Void)? = nil,
        wedgeGrace: Duration = ServiceWedgeWatchdog.defaultGrace,
        stagedByteCapacity: Int64 = GeometryServiceCore.defaultStagedByteCapacity
    ) {
        self.stagingIdleExpiry = stagingIdleExpiry
        self.stagedByteCapacity = stagedByteCapacity
        self.onWedgedCancellation = onWedgedCancellation
        self.wedgeGrace = wedgeGrace
    }

    // MARK: - Entry points

    /// XPC path: the document is an inherited read-only descriptor. The bytes are
    /// staged into the service's own container temp — `CGPDFDocument` wants a URL,
    /// and the service's sandbox has no right to the original path, by design.
    public func extract(request: GeometryWireRequest, fileDescriptor: Int32) async -> WireReplyOutcome {
        let lease: StagingLease
        switch await acquireStagedDocument(fileDescriptor: fileDescriptor) {
        case .success(let value): lease = value
        case .failure(let failure): return .failure(failure)
        }
        defer { releaseStagedDocument(lease) }
        return await extract(request: request, documentAt: lease.url)
    }

    /// Stdio path (tests) and shared implementation.
    public func extract(request: GeometryWireRequest, documentAt url: URL) async -> WireReplyOutcome {
        await run(
            requestID: request.requestID,
            debugDelayMilliseconds: request.debugDelayMilliseconds,
            failure: Self.extractionFailure(from:)
        ) {
            let extractor = VectorExtractor(options: Self.options(from: request.options))
            // The password (BH-069) is used for this one call and goes out of scope with
            // `request`; nothing here stores, logs or caches it.
            let extraction = try await extractor.extract(
                documentAt: url, pageIndex: request.pageIndex, password: request.options.password)
            return VectorExtractionCodec.encode(extraction)
        }
    }

    // MARK: - Rasterisation (S17-02)

    /// XPC path for Revision Compare's page raster: the revision drawing arrives as
    /// an inherited read-only descriptor and is staged, exactly as extraction is.
    public func rasterize(request: RasterWireRequest, fileDescriptor: Int32) async -> WireReplyOutcome {
        let lease: StagingLease
        switch await acquireStagedDocument(fileDescriptor: fileDescriptor) {
        case .success(let value): lease = value
        case .failure(let failure): return .failure(failure)
        }
        defer { releaseStagedDocument(lease) }
        return await rasterize(request: request, documentAt: lease.url)
    }

    /// Stdio path (tests) and shared implementation.
    public func rasterize(request: RasterWireRequest, documentAt url: URL) async -> WireReplyOutcome {
        await run(
            requestID: request.requestID,
            debugDelayMilliseconds: request.debugDelayMilliseconds,
            failure: Self.rasterFailure(from:)
        ) {
            try await GeometryRasterizer.rasterize(request: request, documentAt: url)
        }
    }

    /// XPC path for the pixel-free page-box query.
    public func pageBox(request: RasterWireRequest, fileDescriptor: Int32) async -> WireReplyOutcome {
        let lease: StagingLease
        switch await acquireStagedDocument(fileDescriptor: fileDescriptor) {
        case .success(let value): lease = value
        case .failure(let failure): return .failure(failure)
        }
        defer { releaseStagedDocument(lease) }
        return await pageBox(request: request, documentAt: lease.url)
    }

    /// Stdio path (tests) and shared implementation.
    public func pageBox(request: RasterWireRequest, documentAt url: URL) async -> WireReplyOutcome {
        // The same test hook the other two operations carry: without it the
        // page-box path could not be held open long enough for a cancellation
        // test to reach it (CR-127).
        await run(
            requestID: request.requestID,
            debugDelayMilliseconds: request.debugDelayMilliseconds,
            failure: Self.rasterFailure(from:)
        ) {
            try await GeometryRasterizer.pageBox(request: request, documentAt: url)
        }
    }

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

    // MARK: - Shared runner

    /// Runs one request's work in its own task, registered for ``cancel(_:)``.
    ///
    /// Two cancellation sources reach the work, not one. The cancel table serves
    /// the remote transports; the caller's own cancellation is forwarded too,
    /// because the work runs in an unstructured task that does not inherit it —
    /// without that, an in-process raster or page-box ran to completion for a
    /// cancelled caller (BH-654). And once the request *was* cancelled, whatever
    /// the work throws on the way out is reported as a cancellation: PDFKit's
    /// provider throws its own `PDFBridgeError.cancelled`, not a
    /// `CancellationError`, and that used to reach the caller as a document
    /// failure (BH-211).
    func run(   // internal: the DXF conversion (GeometryServiceCore+DXF.swift) runs through it too
        requestID: UUID,
        debugDelayMilliseconds: Int,
        failure: @Sendable (Error) -> WireFailure,
        work: @escaping @Sendable () async throws -> Data
    ) async -> WireReplyOutcome {
        let task = Task<Data, Error> {
            if debugDelayMilliseconds > 0 {
                try await Task.sleep(
                    nanoseconds: WireDebugDelay.nanoseconds(forMilliseconds: debugDelayMilliseconds))
            }
            return try await work()
        }
        inFlight[requestID] = task
        let watchdog = ServiceWedgeWatchdog()
        watchdogs[requestID] = watchdog
        defer {
            // `task.value` below returns only once the work has, cancelled or not.
            watchdog.markFinished()
            inFlight[requestID] = nil
            watchdogs[requestID] = nil
        }
        if let index = earlyCancels.firstIndex(of: requestID) {
            earlyCancels.remove(at: index)
            task.cancel()
            armWedgeWatchdog(requestID)
        }
        do {
            let data = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return .success(data)
        } catch {
            if task.isCancelled { return .failure(Self.cancellationFailure) }
            return .failure(failure(error))
        }
    }

    /// Starts the wedge watchdog of a request that was just cancelled (R-198). Nothing happens
    /// in a core that was not given `onWedgedCancellation`.
    private func armWedgeWatchdog(_ requestID: UUID) {
        guard let onWedgedCancellation, let watchdog = watchdogs[requestID] else { return }
        watchdog.arm(grace: wedgeGrace, onWedged: onWedgedCancellation)
    }

    // MARK: - Mapping

    /// The extraction options a wire request asks for, applied over ``VectorExtractionOptions/standard``.
    /// The one mapping both the service and the client's in-process fallback use.
    public static func options(from wire: GeometryWireOptions) -> VectorExtractionOptions {
        var options = VectorExtractionOptions.standard
        if let value = wire.flatness { options.flatness = value }
        if let value = wire.emitsClipDerivedPrimitives { options.emitsClipDerivedPrimitives = value }
        if let value = wire.excludesGeometryOutsideClip { options.excludesGeometryOutsideClip = value }
        if let value = wire.emitsShapePrimitives { options.emitsShapePrimitives = value }
        if let value = wire.includesHiddenOptionalContent { options.includesHiddenOptionalContent = value }
        return options
    }

    static let cancellationFailure = WireFailure(
        domain: "ZPDFGeometryService", code: 1, message: "cancelled", isCancellation: true)

    static func failure(from error: VectorExtractionError) -> WireFailure {
        if case .cancelled = error {
            return WireFailure(domain: "ZPDFVectorExtraction", code: 1, message: "cancelled", isCancellation: true)
        }
        return WireFailure(domain: "ZPDFVectorExtraction", code: 100, message: String(describing: error))
    }

    static func extractionFailure(from error: Error) -> WireFailure {
        if let error = error as? VectorExtractionError { return failure(from: error) }
        if error is CancellationError { return cancellationFailure }
        return WireFailure(domain: "ZPDFGeometryService", code: 2, message: String(describing: error))
    }

    /// Raster and page-box failures. Every cancellation spelling the work can
    /// produce maps to a cancellation: Swift's, and the PDFKit provider's own
    /// (BH-211).
    static func rasterFailure(from error: Error) -> WireFailure {
        if error is CancellationError { return cancellationFailure }
        if let bridge = error as? PDFBridgeError, case .cancelled = bridge { return cancellationFailure }
        return WireFailure(domain: "ZPDFGeometryRaster", code: 100, message: String(describing: error))
    }

    // MARK: - Staging (BH-212)

    /// Identifies the file behind an inherited descriptor well enough to reuse a
    /// staged copy of it: device, inode, size and modification time. A rewrite of
    /// the file changes size or mtime and so stages afresh. A descriptor that is
    /// not a regular file gets a `nonce` and is never reused.
    struct StagingKey: Hashable, Sendable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
        var nonce: UUID?
    }

    struct StagedDocument: Sendable {
        let url: URL
        let byteCount: Int64
        var users: Int
        var lastUse: UInt64
    }

    struct StagingLease: Sendable {
        let key: StagingKey
        let url: URL
    }

    enum StagingOutcome: Sendable {
        case success(StagingLease)
        case failure(WireFailure)
    }

    /// The staged copy of the document behind `fileDescriptor`, copied only when
    /// no reusable copy exists.
    ///
    /// Every request used to copy the whole file into the service temp and delete
    /// it afterwards, and the app extracts one page per request: a 1.5 GB set on a
    /// USB disk or an SMB share paid a full-file copy per page, inside a deadline
    /// that did not budget for even one. Now one document costs one copy for as
    /// long as it is in use, plus ``stagingIdleExpiry`` after.
    ///
    /// The copy runs off this actor (R-211). It used to be a synchronous 4 MB read/write loop
    /// inside an actor method, so for the length of a large copy every cancel and every other
    /// document's request waited behind it. Requests for a document whose copy is already under
    /// way share that copy.
    func acquireStagedDocument(fileDescriptor: Int32) async -> StagingOutcome {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            return .failure(Self.stagingFailure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF)))
        }
        let isRegular = (info.st_mode & S_IFMT) == S_IFREG
        let key = StagingKey(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
            nonce: isRegular ? nil : UUID())
        stagingClock += 1
        if var entry = staged[key], FileManager.default.fileExists(atPath: entry.url.path) {
            entry.users += 1
            entry.lastUse = stagingClock
            staged[key] = entry
            Self.touch(entry.url)
            return .success(StagingLease(key: key, url: entry.url))
        }
        let copy: Task<URL, Error>
        if let running = stagingInFlight[key] {
            copy = running
        } else {
            copy = Task.detached(priority: .userInitiated) { try Self.stage(fileDescriptor: fileDescriptor) }
            stagingInFlight[key] = copy
        }
        let url: URL
        do {
            url = try await copy.value
        } catch {
            if stagingInFlight[key] == copy { stagingInFlight[key] = nil }
            return .failure(Self.stagingFailure(error))
        }
        if stagingInFlight[key] == copy { stagingInFlight[key] = nil }
        stagingClock += 1
        // Every sharer of one copy comes through here; the first to arrive registers it. A copy
        // made because the registered one vanished replaces it outright: the replaced entry's
        // outstanding leases name the vanished file, and their releases are ignored (T-085).
        if var entry = staged[key], entry.url == url {
            entry.users += 1
            entry.lastUse = stagingClock
            staged[key] = entry
        } else {
            stagingCopyCount += 1
            staged[key] = StagedDocument(
                url: url, byteCount: Int64(info.st_size), users: 1, lastUse: stagingClock)
        }
        return .success(StagingLease(key: key, url: url))
    }

    /// Stamps a staged copy as in use now (T-085).
    ///
    /// A second copy of the application starts a second service instance on the same
    /// container, and its startup sweep deletes every staged copy not modified for ten minutes.
    /// A copy kept its creation time for as long as BH-212 reused it, so the sweep took copies a
    /// live instance was still reusing, and each of its next requests paid a whole-file copy.
    /// Touched at every lease and every release, a copy in use is never that old.
    static func touch(_ url: URL) {
        _ = utimes(url.path, nil)
    }

    /// The name prefix of every staged copy this core makes.
    static let stagedNamePrefix = "geometry-"

    /// Deletes staged copies a previous run of the service left behind (R-211): a service that
    /// was killed, or wedged and ended by its watchdog, never ran its idle expiry. Only entries
    /// named the way ``stage(fileDescriptor:)`` names them and not modified for `age`; the
    /// sweep is ``ServiceStaging/sweepStale(prefixes:in:olderThan:now:)``, shared with the
    /// repair service (S-117).
    ///
    /// Called by the XPC service's listener at start, where the temporary directory is the
    /// service container's own. Never from a core inside the application or the test worker,
    /// whose temporary directory other processes share.
    @discardableResult
    static func sweepStaleStagedDocuments(in directory: URL = FileManager.default.temporaryDirectory,
                                          olderThan age: TimeInterval = 600, now: Date = Date()) -> Int {
        ServiceStaging.sweepStale(prefixes: [stagedNamePrefix], in: directory, olderThan: age, now: now)
    }

    /// Ends a lease. A lease on a copy that has since been replaced — it vanished, and a later
    /// request staged the document again under the same key — is not the current entry's, and
    /// used to take one user off it: the new copy could then read as idle while still in use
    /// and be evicted or expired under its reader (T-085).
    func releaseStagedDocument(_ lease: StagingLease) {
        guard var entry = staged[lease.key], entry.url == lease.url else { return }
        Self.touch(entry.url)
        entry.users -= 1
        staged[lease.key] = entry
        evictStagedDocuments()
        if entry.users == 0, staged[lease.key] != nil {
            let stamp = entry.lastUse
            let expiry = stagingIdleExpiry
            Task { [weak self] in
                try? await Task.sleep(for: expiry)
                await self?.expireStagedDocument(lease.key, ifUnusedSince: stamp)
            }
        }
    }

    /// Drops idle copies beyond the count and byte caps, least recently used
    /// first, and every idle copy that can never be reused.
    ///
    /// The byte cap makes room for another document and nothing more (S-128). It used to
    /// evict the sole copy of a set larger than the cap the moment its request released it,
    /// so every page request of a 2.5 GiB set copied the whole set again — the per-page copy
    /// BH-212 removed. The most recently used copy now stays for bytes alone; the idle expiry
    /// still removes it.
    private func evictStagedDocuments() {
        for (key, entry) in staged where key.nonce != nil && entry.users == 0 {
            removeStagedDocument(key)
        }
        while true {
            let overCount = staged.count > Self.stagedDocumentCapacity
            let overBytes = staged.values.reduce(0, { $0 + $1.byteCount }) > stagedByteCapacity
            guard overCount || overBytes else { return }
            let newest = staged.max(by: { $0.value.lastUse < $1.value.lastUse })?.key
            guard let victim = staged
                .filter({ $0.value.users == 0 && (overCount || $0.key != newest) })
                .min(by: { $0.value.lastUse < $1.value.lastUse })
            else { return }
            removeStagedDocument(victim.key)
        }
    }

    private func expireStagedDocument(_ key: StagingKey, ifUnusedSince stamp: UInt64) {
        guard let entry = staged[key], entry.users == 0, entry.lastUse == stamp else { return }
        removeStagedDocument(key)
    }

    private func removeStagedDocument(_ key: StagingKey) {
        guard let entry = staged.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(at: entry.url)
    }

    /// How many staged copies exist right now. Test observability.
    var stagedDocumentCount: Int { staged.count }

    /// Deletes every idle staged copy now. Tests call it so a copy of a fixture
    /// does not outlive the test process's idle expiry.
    func removeIdleStagedDocuments() {
        for (key, entry) in staged where entry.users == 0 { removeStagedDocument(key) }
    }

    private static func stagingFailure(_ error: Error) -> WireFailure {
        WireFailure(
            domain: "ZPDFGeometryService", code: 3,
            message: "could not stage inherited descriptor: \(error.localizedDescription)")
    }

    /// Copies an inherited descriptor into the service container's temp directory as
    /// `geometry-<UUID>.pdf` — ``ServiceStaging/stage(fileDescriptor:prefix:in:)``, shared with
    /// the repair service (S-117), which never carries the request's `fileName` (BH-650,
    /// BH-651) and removes a partial copy on failure.
    static func stage(fileDescriptor: Int32) throws -> URL {
        try ServiceStaging.stage(fileDescriptor: fileDescriptor, prefix: stagedNamePrefix)
    }
}

/// A reply body or a wire failure; `Result` with Codable-friendly halves.
public enum WireReplyOutcome: Sendable {
    case success(Data)
    case failure(WireFailure)
}
