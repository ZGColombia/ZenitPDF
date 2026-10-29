import Foundation
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport
@testable import ZPDFServiceClient

/// Same crash discipline for the repair worker: a killed qpdf process is a typed
/// error, a restart, and a destination file that was never touched.
struct RepairCrashIsolationTests {

    @Test("SIGKILL mid-repair: typed error with no restart budget, then a fresh worker repairs on retry")
    func killMidRepairIsTypedErrorThenRetrySucceeds() async throws {
        let broken = try ServiceTestSupport.makeFixture(.brokenXref)
        defer { ServiceTestSupport.remove(broken.directory) }
        let output = broken.directory.appendingPathComponent("repaired.pdf")

        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 0)

        let inFlight = Task {
            try await client.repair(input: broken.url, output: output, debugDelayMilliseconds: 3000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await client.killWorkerForTesting()

        do {
            _ = try await inFlight.value
            Issue.record("the killed request cannot have produced a result")
        } catch let error as ZPDFServiceError {
            guard case .serviceCrashed = error else {
                Issue.record("expected .serviceCrashed, got \(error)")
                return
            }
        }
        // Atomic handoff held: the destination does not exist half-written.
        #expect(!FileManager.default.fileExists(atPath: output.path),
                "a crashed repair must leave no destination file")

        // Retry on the same client: new worker, real repair.
        let reply = try await client.repair(input: broken.url, output: output)
        #expect(reply.outputByteCount > 0)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(await client.workerLaunchCount == 2)
        await client.shutdown()
    }
}
