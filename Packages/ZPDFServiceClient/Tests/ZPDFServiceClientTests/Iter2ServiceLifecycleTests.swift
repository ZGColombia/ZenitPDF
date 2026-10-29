import Foundation
import Testing
import ZPDFServiceWire
@testable import ZPDFGeometryServiceCore
@testable import ZPDFRepairServiceCore
@testable import ZPDFServiceClient

/// Iteration 2: a cancelled request is not relaunched (S-116), the repair service
/// cleans up after its watchdog and stages off its actor (S-117, S-127), and the geometry
/// service keeps a staged set larger than its byte cap for the next page (S-128).
@Suite("Iteration 2 — service lifecycle", .serialized)
struct Iter2ServiceLifecycleTests {

    /// A worker that reads nothing and answers nothing, like a service wedged in qpdf.
    static func silentWorker() throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iter2-silent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("silent-worker")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, directory)
    }

    /// Polls `condition` for up to ten seconds and records an issue if it never holds, so a
    /// loaded machine that is slow to spawn the worker makes the test wait rather than carry on
    /// with the request not yet in flight — the scenario the test exists for.
    static func waitUntil(
        _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the condition did not hold within 10 s", sourceLocation: sourceLocation)
    }

    // MARK: - S-116

    /// Old output: `.timedOut` after the 1.5 s deadline, and `workerLaunchCount == 2` — the
    /// crash read as a reason to relaunch and resend the request the caller had cancelled.
    @Test("S-116: a geometry request cancelled and then ended by a crash is not relaunched")
    func cancelledGeometryRequestIsNotRelaunched() async throws {
        let worker = try Self.silentWorker()
        defer { ServiceTestSupport.remove(worker.directory) }
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: worker.url), maximumRestarts: 1, deadline: .milliseconds(1_500))
        let request = Task { try await client.pageBox(documentAt: fixture.url, pageIndex: 0, box: .crop) }
        try await Self.waitUntil { await client.workerLaunchCount == 1 }
        request.cancel()
        try await Task.sleep(for: .milliseconds(100))
        // The service ends itself on the cancel (the R-198 wedge exit); here, the kill.
        await client.killWorkerForTesting()
        let result = await request.result
        #expect(throws: ZPDFServiceError.cancelled) { try result.get() }
        #expect(await client.workerLaunchCount == 1, "the cancelled request was sent to a relaunched worker")
        await client.shutdown()
    }

    /// The same rule when the cancel arrives *before* the request is dispatched — the case the
    /// test above meets on a loaded machine, where the request task has not reached the client
    /// yet when the test cancels it. Old output: the client spawned the worker, sent the request
    /// anyway and waited out the whole deadline, so a request its caller had already stopped
    /// came back `.timedOut` after 1.5 s instead of `.cancelled` at once.
    @Test("S-116: a geometry request cancelled before it is dispatched is never sent")
    func geometryRequestCancelledBeforeDispatchIsNeverSent() async throws {
        let worker = try Self.silentWorker()
        defer { ServiceTestSupport.remove(worker.directory) }
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: worker.url), maximumRestarts: 1, deadline: .milliseconds(1_500))
        let request = Task {
            // Hold the call back until the task is cancelled, so the request reaches the client
            // already cancelled whatever the scheduler does.
            while !Task.isCancelled { await Task.yield() }
            return try await client.pageBox(documentAt: fixture.url, pageIndex: 0, box: .crop)
        }
        request.cancel()
        let started = ContinuousClock.now
        let result = await request.result
        #expect(throws: ZPDFServiceError.cancelled) { try result.get() }
        #expect(ContinuousClock.now - started < .milliseconds(1_000), "a cancelled request waited for its deadline")
        #expect(await client.workerLaunchCount == 0, "a worker was spawned for a request its caller had cancelled")
        await client.shutdown()
    }

    @Test("S-116: a repair cancelled before it is dispatched is never sent, and writes nothing")
    func repairCancelledBeforeDispatchIsNeverSent() async throws {
        let worker = try Self.silentWorker()
        defer { ServiceTestSupport.remove(worker.directory) }
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let output = fixture.directory.appendingPathComponent("repaired.pdf")
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: worker.url), maximumRestarts: 1, deadline: .milliseconds(1_500))
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        let request = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await client.repair(input: fixture.url, output: output)
        }
        request.cancel()
        let started = ContinuousClock.now
        let result = await request.result
        #expect(throws: ZPDFServiceError.cancelled) { try result.get() }
        #expect(ContinuousClock.now - started < .milliseconds(1_000), "a cancelled repair waited for its deadline")
        #expect(await client.workerLaunchCount == 0, "a worker was spawned for a repair its caller had cancelled")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == before)
        await client.shutdown()
    }

    /// Old output: `workerLaunchCount == 2`, then `.timedOut` — the repair was staged and sent
    /// again to a fresh service for a job the caller had stopped.
    @Test("S-116: a repair cancelled and then ended by a crash is not relaunched, and writes nothing")
    func cancelledRepairIsNotRelaunched() async throws {
        // Silent like `silentWorker()`, but it keeps the frames it is sent, so the test can read
        // the staging path the client handed the worker (V-051: no longer beside the output).
        let worker = try ServiceTestSupport.frameRecordingSilentWorker()
        defer { ServiceTestSupport.remove(worker.directory) }
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let output = fixture.directory.appendingPathComponent("repaired.pdf")
        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: worker.url), maximumRestarts: 1, deadline: .milliseconds(1_500))
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        let request = Task { try await client.repair(input: fixture.url, output: output) }
        try await Self.waitUntil { await client.workerLaunchCount == 1 }
        func stagingPath() -> String? {
            ServiceTestSupport.requestFrames(in: worker.frames).first { $0.kind == .repairPerform }?.outputPath
        }
        try await Self.waitUntil { stagingPath() != nil }
        let staging = stagingPath()
        let stagingFolder = staging.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        // The control: while the request is in flight the folder is there, so "gone" below is a
        // removal, not a path that never existed.
        let existedInFlight = stagingFolder.map { FileManager.default.fileExists(atPath: $0.path) }
        request.cancel()
        try await Task.sleep(for: .milliseconds(100))
        await client.killWorkerForTesting()
        let result = await request.result
        await client.shutdown()
        #expect(throws: ZPDFServiceError.cancelled) { try result.get() }
        #expect(await client.workerLaunchCount == 1)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == before)
        let folder = try #require(stagingFolder, "the worker never received the repair frame")
        #expect(existedInFlight == true, "the frame's output path is not the live staging")
        #expect(folder.standardizedFileURL.resolvingSymlinksInPath().path
                != fixture.directory.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "staging left behind after cancel and crash: \(folder.path)")
    }

    /// Writes its output, then finishes without looking at cancellation — as qpdf does.
    struct UncooperativeRepair: RepairInProcessExecuting {
        func perform(request: RepairWireRequest, inputAt input: URL, outputPath: String?) async -> RepairReplyOutcome {
            if let outputPath { FileManager.default.createFile(atPath: outputPath, contents: Data("%PDF-1.7\n".utf8)) }
            let end = Date().addingTimeInterval(0.4)
            while Date() < end { usleep(5_000) }
            return .success(RepairWireReply(message: "repaired", warnings: [], warningCount: 0, outputByteCount: 9))
        }
    }

    /// Old output: `.success`, and repaired.pdf written for a job that had been stopped.
    @Test("S-116: a job stopped while the service finished does not promote its output")
    func cancelledJobDoesNotPromote() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let output = fixture.directory.appendingPathComponent("repaired.pdf")
        let staged = ServiceTestSupport.RepairStagingLog()
        let client = ZPDFRepairServiceClient(backend: .inProcess(
            ServiceTestSupport.RecordingRepairExecutor(wrapped: UncooperativeRepair(), log: staged)))
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        let request = Task { try await client.repair(input: fixture.url, output: output) }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()
        let result = await request.result
        #expect(throws: ZPDFServiceError.cancelled) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == before)
        // The service wrote its output into the private staging folder (V-051); a stopped job
        // removes the folder and the file in it.
        let staging = try #require(await staged.outputPaths.first, "the executor was handed no output path")
        let stagingFolder = URL(fileURLWithPath: staging).deletingLastPathComponent()
        #expect(await staged.folderExistedDuringCall == [true], "the recorded path was not the live staging")
        #expect(!FileManager.default.fileExists(atPath: stagingFolder.path), "staging left behind after cancel-while-finishing: \(staging)")
    }

    // MARK: - S-117

    /// Old output: the repair service had no sweep; every one of these outlived the run that
    /// made it (the watchdog's `_exit` runs no `defer`).
    @Test("S-117: the repair service sweeps its stale staged inputs, outputs and page-group folders")
    func repairSweep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iter2-repair-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hourAgo = Date().addingTimeInterval(-3_600)
        func file(_ name: String, stale: Bool) throws -> URL {
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
            if stale { try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: url.path) }
            return url
        }
        let stale = try [
            file("repair-in-\(UUID().uuidString).pdf", stale: true),
            file("repair-\(UUID().uuidString).pdf", stale: true),
            file("transform-\(UUID().uuidString).pdf", stale: true)
        ]
        let groups = directory.appendingPathComponent("repair-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: groups, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: groups.appendingPathComponent("part-1.pdf").path, contents: Data([1]))
        try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: groups.path)
        let fresh = try file("repair-in-\(UUID().uuidString).pdf", stale: false)
        let other = try file("drawing.pdf", stale: true)

        #expect(RepairServiceCore.sweepStaleStagedFiles(in: directory) == 4)
        for url in stale + [groups] { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) kept") }
        #expect(FileManager.default.fileExists(atPath: fresh.path), "a live run's copy is young")
        #expect(FileManager.default.fileExists(atPath: other.path), "only the service's own names")
    }

    /// Old output: the repair core's own stage left a zero-byte `repair-in-<UUID>.pdf` behind.
    @Test("S-117: a staging copy that fails part-way leaves no file behind")
    func failedStageRemovesPartial() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iter2-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A directory's descriptor opens and seeks, and every read fails (EISDIR).
        let source = open(directory.path, O_RDONLY)
        #expect(source >= 0)
        defer { close(source) }
        #expect(throws: (any Error).self) {
            _ = try ServiceStaging.stage(fileDescriptor: source, prefix: RepairServiceCore.stagedInputPrefix, in: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    // MARK: - S-127

    /// Old code: the copy ran inside the actor method, so a cancel waited behind a large copy for
    /// its whole length. With this pipe the old stage never even blocked — its seek failed at once
    /// (ESPIPE) — so the old run fails the second expectation, not the first.
    @Test("S-127: a repair staging a large input does not hold the core; a cancel is served at once")
    func repairStagesOffTheActor() async throws {
        let core = RepairServiceCore()
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
        defer { close(readEnd) }
        let started = ContinuousClock.now
        let staging = Task {
            _ = await core.perform(request: RepairWireRequest(operation: .inspect, fileName: "pipe.pdf"),
                                   inputDescriptor: readEnd, outputDescriptor: nil)
            return ContinuousClock.now - started
        }
        let closer = Task {
            try? await Task.sleep(for: .seconds(3))
            close(writeEnd)
        }
        try await Task.sleep(for: .milliseconds(200))
        let cancelStarted = ContinuousClock.now
        await core.cancel(UUID())
        let cancelElapsed = ContinuousClock.now - cancelStarted
        #expect(cancelElapsed < .milliseconds(1_500), "the cancel waited \(cancelElapsed) behind the copy")
        _ = await closer.value
        let stagingElapsed = await staging.value
        #expect(stagingElapsed >= .milliseconds(2_500), "the copy did not block on the pipe (\(stagingElapsed)), so the test proved nothing")
    }

    // MARK: - S-128

    /// Old output: `stagingCopyCount == 2` — the sole copy exceeded the byte cap on its own and
    /// was deleted the moment the first request released it.
    @Test("S-128: a staged set larger than the byte cap is kept for the next page")
    func oversizedSoleCopyIsKept() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let core = GeometryServiceCore(stagingIdleExpiry: .seconds(120), stagedByteCapacity: 1)
        let handle = try FileHandle(forReadingFrom: fixture.url)
        defer { try? handle.close() }
        let request = RasterWireRequest(pageIndex: 0, box: .crop, scale: 1, fileName: fixture.url.lastPathComponent)
        for _ in 0..<2 {
            guard case .success = await core.pageBox(request: request, fileDescriptor: handle.fileDescriptor) else {
                Issue.record("the page box must be answered"); return
            }
        }
        #expect(await core.stagingCopyCount == 1)
        #expect(await core.stagedDocumentCount == 1)
        await core.removeIdleStagedDocuments()
    }

    @Test("S-128: the byte cap still makes room for another document")
    func byteCapMakesRoomForAnother() async throws {
        let first = try ServiceTestSupport.makeFixture(.rectangle)
        let second = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(first.directory); ServiceTestSupport.remove(second.directory) }
        let core = GeometryServiceCore(stagingIdleExpiry: .seconds(120), stagedByteCapacity: 1)
        for fixture in [first, second] {
            let handle = try FileHandle(forReadingFrom: fixture.url)
            defer { try? handle.close() }
            let request = RasterWireRequest(pageIndex: 0, box: .crop, scale: 1, fileName: fixture.url.lastPathComponent)
            guard case .success = await core.pageBox(request: request, fileDescriptor: handle.fileDescriptor) else {
                Issue.record("the page box must be answered"); return
            }
        }
        // The first, idle and least recently used, went for the bytes; the second stays.
        #expect(await core.stagingCopyCount == 2)
        #expect(await core.stagedDocumentCount == 1)
        await core.removeIdleStagedDocuments()
    }
}
