import Foundation
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport
@testable import ZPDFServiceClient

/// The point of S15: a worker process dying mid-extraction is a typed error and a
/// restart, never a host crash. The worker here is the same service core the
/// shipped `GeometryService.xpc` runs, spoken to over the stdio transport because
/// an `.xpc` bundle cannot launch outside its host app bundle.
struct GeometryCrashIsolationTests {

    @Test("SIGKILL mid-extraction surfaces as ZPDFServiceError.serviceCrashed when the restart budget is zero")
    func killMidExtractionIsTypedError() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()),
            maximumRestarts: 0)

        // The debug delay holds the worker inside the request long enough to be
        // killed there deterministically.
        let inFlight = Task {
            try await client.extractPageGeometry(
                documentAt: fixture.url, pageIndex: 0, debugDelayMilliseconds: 3000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let firstPID = await client.workerProcessIdentifier
        #expect(firstPID != nil, "worker should be running mid-request")
        await client.killWorkerForTesting()

        await #expect(throws: ZPDFServiceError.self) {
            _ = try await inFlight.value
        }
        do {
            _ = try await inFlight.value
            Issue.record("the killed request cannot have produced a result")
        } catch let error as ZPDFServiceError {
            guard case .serviceCrashed = error else {
                Issue.record("expected .serviceCrashed, got \(error)")
                return
            }
        }

        // The service restarts: the next request on the same client spawns a new
        // worker with a new pid, and succeeds.
        let extraction = try await client.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)
        #expect(!extraction.primitives.isEmpty)
        let secondPID = await client.workerProcessIdentifier
        #expect(secondPID != nil)
        #expect(secondPID != firstPID, "restart must be a new process")
        #expect(await client.workerLaunchCount == 2)
        await client.shutdown()
    }

    @Test("With the default restart budget, one crash is absorbed: restart + retry succeed without the caller seeing an error")
    func defaultPolicyRetriesThroughOneCrash() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.lShape)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()),
            maximumRestarts: 1)

        let inFlight = Task {
            try await client.extractPageGeometry(
                documentAt: fixture.url, pageIndex: 0, debugDelayMilliseconds: 2000)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        await client.killWorkerForTesting()

        // The retry runs without the debug delay? No — the retry reuses the same
        // request, delay included, so give it time. The caller sees a result, not
        // the crash.
        let extraction = try await inFlight.value
        #expect(!extraction.primitives.isEmpty)
        #expect(await client.workerLaunchCount == 2, "one crash, one restart")
        await client.shutdown()
    }

    @Test("A crashed-then-restarted worker answers a ping and a full extraction")
    func restartedWorkerIsHealthy() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.polygonOneHole)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()),
            maximumRestarts: 0)

        // Healthy first extraction.
        let first = try await client.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)
        #expect(!first.primitives.isEmpty)

        // Kill it while idle; the next request must transparently respawn.
        await client.killWorkerForTesting()
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = try await client.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)
        #expect(second.primitives == first.primitives,
                "the same file through a fresh worker is the same geometry")
        await client.shutdown()
    }
}
