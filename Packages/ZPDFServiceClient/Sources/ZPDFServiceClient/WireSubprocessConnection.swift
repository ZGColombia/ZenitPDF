import Foundation
import os
import ZPDFServiceWire

/// A wire-frame client over a spawned worker process.
///
/// This is the transport `swift test` uses: an `.xpc` bundle only launches from
/// inside its host app, so the tests spawn the same service core as a plain
/// subprocess and speak ``WireFraming`` frames over its pipes. It is also the
/// crash-isolation rig — ``killForTesting()`` SIGKILLs the worker mid-request so
/// the tests can prove the failure surfaces as a typed error and a restart heals.
///
/// One actor per worker. Requests may overlap (cancel frames must); replies are
/// matched to callers by frame id.
public actor WireSubprocessConnection {

    private let executableURL: URL
    private let arguments: [String]

    /// The wall clock every request over this transport races (CR-122).
    private let deadline: ZPDFServiceDeadline

    private var process: Process?
    private var stdinHandle: FileHandle?
    /// The reader owns the worker's stdout descriptor through a `DispatchIO`
    /// channel rather than a `Task`, because a task blocked on `read(2)` cannot
    /// be unblocked by cancelling it: a pipe whose write end is still open
    /// somewhere never returns EOF, and the task — and its descriptor — stay
    /// alive for as long as that write end does. `close(flags: .stop)` ends the
    /// outstanding read and runs the cleanup handler, which is deterministic.
    private var readerChannel: DispatchIO?
    /// Waiters, keyed by frame id. ``ResumeOnce`` rather than a bare continuation
    /// because three things now compete to finish a request — the reply, the
    /// reader's EOF, and the deadline — and exactly one may resume the caller.
    private var pending: [UUID: ResumeOnce<WireReplyFrame>] = [:]
    /// Bumped per spawn, so a stale reader loop cannot fail the next generation's requests.
    private var generation = 0

    /// How many times a worker process has been spawned. The crash test asserts
    /// this grows across a kill.
    public private(set) var launchCount = 0

    /// Requests abandoned because their deadline expired. The hang-isolation test
    /// asserts the entry was dropped rather than left waiting for a reply that a
    /// wedged worker will never send.
    public private(set) var timedOutRequests = 0

    /// Abandoned requests the worker has not answered yet, by frame id, with the generation
    /// they were sent to (R-198). A reply — even "cancelled" — proves the worker came back.
    private var abandoned: [UUID: Int] = [:]
    /// How long an abandoned request's worker has to answer its cancel before it is killed.
    private let wedgeGrace: Duration

    /// Workers killed because a timed-out request never answered its cancel (R-198).
    public private(set) var wedgedWorkersKilled = 0

    public init(
        executableURL: URL,
        arguments: [String] = ["--stdio"],
        deadline: ZPDFServiceDeadline = .geometry,
        wedgeGrace: Duration = ServiceWedgeWatchdog.defaultGrace
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.deadline = deadline
        self.wedgeGrace = wedgeGrace
        // A worker dying while the app writes to its pipe must be an error return,
        // not a SIGPIPE termination of the *host* — that would defeat the point.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Requests

    /// Sends one frame and waits for its reply, for no longer than ``deadline``.
    ///
    /// `cancelID` is the *request's* id inside the encoded body, which is what the
    /// worker's cancel table is keyed by — distinct from `frame.id`, which keys
    /// this side's pending table. When the deadline wins, the pending entry is
    /// dropped (a late reply then resumes nothing) and a cancel goes after the
    /// worker in case it is merely slow and still reading its stdin.
    public func send(_ frame: WireRequestFrame, cancelID: UUID? = nil) async throws -> WireReplyFrame {
        try ensureRunning()
        guard let stdinHandle else {
            throw ZPDFServiceError.serviceUnavailable(
                service: executableURL.lastPathComponent, detail: "no stdin after spawn")
        }
        let encoded: Data
        do {
            encoded = try WireFraming.encode(frame)
        } catch {
            throw ZPDFServiceError.malformedReply(
                service: executableURL.lastPathComponent,
                detail: "request would not encode: \(error.localizedDescription)")
        }
        let frameID = frame.id
        return try await withServiceDeadline(
            deadline,
            service: executableURL.lastPathComponent,
            operation: frame.kind.rawValue,
            onExpiry: { [weak self] in
                Task { await self?.abandon(frameID: frameID, cancelID: cancelID) }
            }
        ) { once in
            pending[frameID] = once
            do {
                try stdinHandle.write(contentsOf: encoded)
            } catch {
                pending[frameID] = nil
                once.resume(throwing: ZPDFServiceError.serviceCrashed(
                    service: executableURL.lastPathComponent,
                    detail: "write failed: \(error.localizedDescription)"))
            }
        }
    }

    /// The deadline path: forget the request, tell the worker to stop, and give it
    /// ``wedgeGrace`` to show it did.
    ///
    /// R-198: the old path stopped at the cancel. A worker whose work ignores cancellation —
    /// a parser loop, a DXF expansion before it had a budget — kept running, a core spent for
    /// the rest of the session, and every later request queued behind it. A worker that has
    /// not answered by the end of the grace is killed and the next request starts a new one.
    private func abandon(frameID: UUID, cancelID: UUID?) {
        guard pending.removeValue(forKey: frameID) != nil else { return }
        timedOutRequests += 1
        if let cancelID { sendCancel(for: cancelID) }
        let sentTo = generation
        abandoned[frameID] = sentTo
        let grace = wedgeGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.killIfStillWedged(frameID: frameID, generation: sentTo)
        }
    }

    private func killIfStillWedged(frameID: UUID, generation sentTo: Int) {
        guard abandoned.removeValue(forKey: frameID) == sentTo, sentTo == generation else { return }
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            wedgedWorkersKilled += 1
        }
        // A restart, like a crash: whatever else was waiting on this worker fails now and the
        // client's restart policy retries it; the next send spawns a clean process.
        retirePreviousGeneration()
        failAllPending(detail: "worker did not answer a cancelled request and was restarted")
    }

    /// Fire-and-forget cancel for an in-flight request id.
    public func sendCancel(for requestID: UUID) {
        guard let stdinHandle else { return }
        let frame = WireRequestFrame(kind: .cancel, body: Data(requestID.uuidString.utf8))
        if let data = try? WireFraming.encode(frame) {
            try? stdinHandle.write(contentsOf: data)
        }
        // The cancel's own reply is dropped in the reader: no continuation is registered.
    }

    // MARK: - Lifecycle

    /// The worker's pid, for tests that assert a restart produced a new process.
    public var processIdentifier: Int32? {
        process?.isRunning == true ? process?.processIdentifier : nil
    }

    /// SIGKILL the worker. Test-only by intent: this is the crash injection.
    public func killForTesting() {
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    public func shutdown() {
        if let process, process.isRunning { process.terminate() }
        retirePreviousGeneration()
        failAllPending(detail: "connection shut down")
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        // Whatever was pending against a dead process fails now, before respawn.
        failAllPending(detail: "worker process is not running")
        // CR-134: a respawn can beat the dying worker's reader to the actor — the
        // process is already gone, but the reader is still blocked on a read that
        // has not yet returned EOF, so `readerFinished` has not run. Assigning the
        // new generation's handles on top of the old ones abandoned a live task and
        // a descriptor per crash cycle. Retire the previous generation here instead
        // of hoping the reader gets there first; `readerFinished` is generation
        // -guarded, so the old reader arriving afterwards is a no-op.
        retirePreviousGeneration()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ZPDFServiceError.serviceUnavailable(
                service: executableURL.lastPathComponent,
                detail: "spawn failed: \(error.localizedDescription)")
        }
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.launchCount += 1
        // The reader gets its own descriptor: a dup'ed fd keeps the read end alive
        // independently of the Pipe object's lifetime, and hands this actor a
        // descriptor it can retire on its own terms. The Pipe's own read end is
        // closed straight after the dup — `Process` retains the Pipe for as long
        // as it retains itself, so leaving that copy open cost one FIFO per
        // spawn that nothing in this actor could ever reach (CR-134).
        let readEnd = stdoutPipe.fileHandleForReading
        let reader = dup(readEnd.fileDescriptor)
        try? readEnd.close()
        startReader(descriptor: reader, generation: generation)
    }

    private func startReader(descriptor: Int32, generation: Int) {
        let queue = DispatchQueue(label: "com.zenitgroup.zenitpdf.wire-reader.\(generation)")
        // The cleanup handler is the only place the descriptor is closed, and it
        // runs once the channel is closed and its operations have finished — so
        // the fd number can never be recycled under a read that is still running.
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            close(descriptor)
        }
        channel.setLimit(lowWater: 1)
        readerChannel = channel

        let accumulator = WireFrameAccumulator()
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, _ in
            if let data, !data.isEmpty {
                guard let frames = accumulator.accept(Data(data)) else {
                    // Garbage on the wire: the worker is talking nonsense. Stop
                    // reading it and fail every waiter as a crash.
                    channel.close(flags: .stop)
                    Task { await self?.readerFinished(generation: generation) }
                    return
                }
                if !frames.isEmpty {
                    Task { await self?.deliver(frames) }
                }
            }
            if done {
                // EOF, a read error, or our own `.stop`. Either way this
                // generation is finished; `readerFinished` is generation-guarded,
                // so a retired reader arriving late changes nothing.
                Task { await self?.readerFinished(generation: generation) }
            }
        }
    }

    private func deliver(_ replies: [WireReplyFrame]) {
        for reply in replies {
            // A late answer to an abandoned request: the worker is alive and listening.
            abandoned[reply.id] = nil
            guard let waiter = pending.removeValue(forKey: reply.id) else { continue }
            waiter.resume(returning: reply)
        }
    }

    /// Closes and stops whatever the previous spawn left behind. Idempotent:
    /// safe when the reader already ran `readerFinished`, safe on a first spawn.
    ///
    /// The generation is bumped first, so anything still in flight from the
    /// outgoing generation — a queued `readerFinished`, a late `deliver` — is
    /// already stale by the time it reaches the actor and cannot touch the
    /// handles the next spawn is about to install.
    private func retirePreviousGeneration() {
        generation += 1
        readerChannel?.close(flags: .stop)
        readerChannel = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
    }

    private func readerFinished(generation: Int) {
        guard generation == self.generation else { return }
        failAllPending(detail: "worker process died mid-request")
        readerChannel?.close(flags: .stop)
        readerChannel = nil
        process = nil
        try? stdinHandle?.close()
        stdinHandle = nil
    }

    private func failAllPending(detail: String) {
        let waiting = pending
        pending = [:]
        for waiter in waiting.values {
            waiter.resume(throwing: ZPDFServiceError.serviceCrashed(
                service: executableURL.lastPathComponent, detail: detail))
        }
    }
}

/// Reassembles length-prefixed reply frames from a byte stream that arrives in
/// arbitrary chunks. One instance per reader generation; the lock is there
/// because `DispatchIO` hands the chunks over on its own queue.
private final class WireFrameAccumulator: Sendable {

    private let buffer = OSAllocatedUnfairLock(initialState: Data())

    /// The frames these bytes completed, or `nil` for a protocol violation — a
    /// zero or oversized length field, or a body that will not decode. The caller
    /// treats `nil` as "the worker is talking nonsense" and stops reading.
    func accept(_ chunk: Data) -> [WireReplyFrame]? {
        buffer.withLock { pendingBytes -> [WireReplyFrame]? in
            pendingBytes.append(chunk)
            var frames: [WireReplyFrame] = []
            while pendingBytes.count >= 4 {
                let start = pendingBytes.startIndex
                let length = pendingBytes[start..<(start + 4)]
                    .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).byteSwapped }
                guard length > 0, Int(length) <= WireFraming.maximumBodyBytes else { return nil }
                guard pendingBytes.count >= 4 + Int(length) else { break }
                let body = pendingBytes[(start + 4)..<(start + 4 + Int(length))]
                guard let frame = try? WireFraming.decodeBody(WireReplyFrame.self, from: Data(body)) else {
                    return nil
                }
                pendingBytes.removeFirst(4 + Int(length))
                frames.append(frame)
            }
            return frames
        }
    }
}
