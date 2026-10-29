import Foundation
import os
import Testing
import ZPDFServiceWire
@testable import ZPDFGeometryServiceCore
@testable import ZPDFServiceClient

/// Iteration 1: a wedged worker is ended rather than left running (R-198), and
/// a large staging copy no longer holds the geometry core's actor (R-211).
struct Iter1ServiceBoundaryTests {

    private final class Counter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    /// Gone, or a zombie waiting to be reaped: either way no longer running.
    private static func isDead(_ pid: Int32) throws -> Bool {
        guard kill(pid, 0) == 0 else { return true }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "stat=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = Pipe()
        try ps.run()
        let state = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.contains("Z")
    }

    // MARK: - R-198, client side

    /// Old output: `wedgedWorkersKilled` did not exist; the stub kept its pid for its whole
    /// 30 s life and the second request was written to the same wedged process
    /// (`launchCount == 1`).
    @Test("R-198: a worker that never answers a timed-out request's cancel is killed; the next request gets a new one")
    func wedgedSubprocessWorkerIsKilled() async throws {
        let connection = WireSubprocessConnection(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            deadline: .milliseconds(300),
            wedgeGrace: .milliseconds(300))
        await #expect(throws: ZPDFServiceError.self) {
            _ = try await connection.send(WireRequestFrame(kind: .ping), cancelID: UUID())
        }
        let wedgedPID = try #require(await connection.processIdentifier)
        // Deadline 300 ms, then 300 ms of grace; allow generously for a loaded machine.
        var waited = 0
        while await connection.wedgedWorkersKilled == 0, waited < 50 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        #expect(await connection.wedgedWorkersKilled == 1)
        #expect(await connection.processIdentifier == nil, "the wedged worker is gone")
        #expect(try Self.isDead(wedgedPID), "process \(wedgedPID) is still running")

        await #expect(throws: ZPDFServiceError.self) {
            _ = try await connection.send(WireRequestFrame(kind: .ping), cancelID: UUID())
        }
        #expect(await connection.launchCount == 2, "the next request was sent to a fresh worker")
        #expect(await connection.processIdentifier != wedgedPID)
        await connection.shutdown()
    }

    @Test("R-198: a worker that answers its cancel within the grace is kept, and serves the next request")
    func cooperativeWorkerIsKept() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()),
            maximumRestarts: 0,
            deadline: .milliseconds(400))
        await #expect(throws: ZPDFServiceError.self) {
            _ = try await client.pageBox(documentAt: fixture.url, pageIndex: 0, box: .crop, debugDelayMilliseconds: 5_000)
        }
        let pid = await client.workerProcessIdentifier
        // Past the default 2 s grace: the cooperative worker answered "cancelled" long before.
        try await Task.sleep(for: .milliseconds(2_600))
        #expect(await client.workerProcessIdentifier == pid, "a worker that came back is not killed")
        let box = try await client.pageBox(documentAt: fixture.url, pageIndex: 0, box: .crop)
        #expect(box.boxWidth > 0)
        #expect(await client.workerLaunchCount == 1)
        await client.shutdown()
    }

    // MARK: - R-198, service side

    @Test("R-198: a cancelled request whose work ignores cancellation trips the service's wedge watchdog")
    func serviceWatchdogFiresOnWedgedWork() async throws {
        let wedged = Counter()
        let core = GeometryServiceCore(
            stagingIdleExpiry: .seconds(120),
            onWedgedCancellation: { wedged.increment() },
            wedgeGrace: .milliseconds(200))
        let id = UUID()
        let request = Task {
            await core.run(requestID: id, debugDelayMilliseconds: 0, failure: { _ in
                WireFailure(domain: "test", code: 0, message: "failed")
            }) {
                // Work that never checks for cancellation: one second of spinning.
                let end = Date().addingTimeInterval(1.0)
                while Date() < end {}
                return Data()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        await core.cancel(id)
        try await Task.sleep(for: .milliseconds(600))
        // Old output: no watchdog existed; the work ran on, and in a service process it could
        // run for the rest of the session.
        #expect(wedged.count == 1)
        _ = await request.value
    }

    @Test("R-198: cooperative work that stops when cancelled does not trip it, nor does a core without the hook")
    func serviceWatchdogSparesCooperativeWork() async throws {
        let wedged = Counter()
        let core = GeometryServiceCore(
            stagingIdleExpiry: .seconds(120),
            onWedgedCancellation: { wedged.increment() },
            wedgeGrace: .milliseconds(200))
        let id = UUID()
        let request = Task {
            await core.run(requestID: id, debugDelayMilliseconds: 10_000, failure: { _ in
                WireFailure(domain: "test", code: 0, message: "failed")
            }) { Data() }
        }
        try await Task.sleep(for: .milliseconds(100))
        await core.cancel(id)
        guard case .failure(let failure) = await request.value else {
            Issue.record("a cancelled request must fail"); return
        }
        #expect(failure.isCancellation)
        try await Task.sleep(for: .milliseconds(400))
        #expect(wedged.count == 0)
    }

    // MARK: - R-211

    @Test("R-211: a staging copy that is still reading does not hold the core; another document is answered")
    func stagingRunsOffTheActor() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let core = GeometryServiceCore()
        // A pipe nobody writes to yet: staging reads it until the write end closes.
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
        defer { close(readEnd) }
        let staging = Task {
            await core.pageBox(request: RasterWireRequest(pageIndex: 0, box: .crop, scale: 1, fileName: "pipe.pdf"),
                               fileDescriptor: readEnd)
        }
        // Old code: `acquireStagedDocument` copied synchronously on the actor, so this call
        // waited for the pipe to close, 3 s later.
        let closer = Task {
            try? await Task.sleep(for: .seconds(3))
            close(writeEnd)
        }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        let other = await core.pageBox(
            request: RasterWireRequest(pageIndex: 0, box: .crop, scale: 1, fileName: fixture.url.lastPathComponent),
            documentAt: fixture.url)
        let elapsed = ContinuousClock.now - started
        guard case .success = other else { Issue.record("the other document must be answered"); return }
        #expect(elapsed < .milliseconds(1_500), "answered after \(elapsed), behind the copy")
        _ = await closer.value
        _ = await staging.value
        await core.removeIdleStagedDocuments()
    }

    @Test("R-211: two concurrent requests on one document share one staged copy")
    func concurrentRequestsShareOneCopy() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let core = GeometryServiceCore()
        let first = try FileHandle(forReadingFrom: fixture.url)
        let second = try FileHandle(forReadingFrom: fixture.url)
        defer { try? first.close(); try? second.close() }
        let request = RasterWireRequest(pageIndex: 0, box: .crop, scale: 1, fileName: fixture.url.lastPathComponent)
        async let a = core.pageBox(request: request, fileDescriptor: first.fileDescriptor)
        async let b = core.pageBox(request: request, fileDescriptor: second.fileDescriptor)
        let (ra, rb) = await (a, b)
        guard case .success = ra, case .success = rb else { Issue.record("both must be answered"); return }
        #expect(await core.stagingCopyCount == 1)
        await core.removeIdleStagedDocuments()
        #expect(await core.stagedDocumentCount == 0)
    }

    @Test("R-211: stale staged copies from an earlier run are swept; fresh ones and other files are kept")
    func staleStagedCopiesAreSwept() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iter1-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = directory.appendingPathComponent("geometry-\(UUID().uuidString).pdf")
        let fresh = directory.appendingPathComponent("geometry-\(UUID().uuidString).pdf")
        let other = directory.appendingPathComponent("drawing.pdf")
        for url in [stale, fresh, other] { FileManager.default.createFile(atPath: url.path, contents: Data([1])) }
        let hourAgo = Date().addingTimeInterval(-3_600)
        try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: other.path)

        #expect(GeometryServiceCore.sweepStaleStagedDocuments(in: directory) == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path), "a copy in use by a live run is young")
        #expect(FileManager.default.fileExists(atPath: other.path), "only the service's own names")
    }
}
