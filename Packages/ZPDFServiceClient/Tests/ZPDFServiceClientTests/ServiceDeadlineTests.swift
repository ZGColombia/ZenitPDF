import Foundation
import Testing
import ZPDFServiceWire
@testable import ZPDFServiceClient

/// CR-122 — hang isolation.
///
/// Crash isolation was solved and hang isolation was not: a worker that *dies* is
/// noticed (EOF fails every waiter), a worker that *lives and never answers* used
/// to produce no event at all, so the caller's continuation was never resumed and
/// the calling task waited forever. These tests wedge a worker on purpose.
struct ServiceDeadlineTests {

    /// A stub worker that accepts the request and never replies: `/bin/sleep`
    /// reads nothing from its stdin and writes nothing to its stdout. It is given
    /// a short life so the test cannot hang the suite if the deadline regresses —
    /// which is also what makes the old behaviour visible rather than eternal.
    ///
    /// Old code (no deadline anywhere in `WireSubprocessConnection.send`): the
    /// call sat in `withCheckedThrowingContinuation` until the stub exited five
    /// seconds later and the reader saw EOF, and the caller got
    /// `serviceCrashed(service: "sleep", detail: "worker process died mid-request")`
    /// after 5 s. Measured before the fix; a wedged worker with no exit produced
    /// no error at all.
    @Test("A worker that never replies fails with .timedOut, not by waiting forever")
    func stubTransportThatNeverRepliesTimesOut() async throws {
        let connection = WireSubprocessConnection(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            deadline: .milliseconds(300))

        let started = ContinuousClock.now
        var caught: ZPDFServiceError?
        do {
            _ = try await connection.send(WireRequestFrame(kind: .ping))
            Issue.record("a worker that never replies must not produce a reply")
        } catch let error as ZPDFServiceError {
            caught = error
        }
        let elapsed = ContinuousClock.now - started

        guard case .timedOut(_, let detail) = caught else {
            Issue.record("expected .timedOut, got \(String(describing: caught))")
            await connection.shutdown()
            return
        }
        #expect(detail.contains("ping"), "the detail names the operation: \(detail)")
        // The deadline won, not the stub's own exit five seconds later.
        #expect(elapsed < .seconds(3), "returned after \(elapsed)")
        // The pending entry is dropped, so a late reply would resume nothing.
        #expect(await connection.timedOutRequests == 1)
        await connection.shutdown()
    }

    /// The same guarantee at the client's own door, with the real service core as
    /// the worker: the request is genuinely in flight inside a *live* process.
    ///
    /// Old code (measured with the deadline disarmed): the client had no
    /// deadline, so this call blocked for the whole 3 s debug delay and then
    /// returned a perfectly good `VectorPageExtraction` —
    /// `Issue recorded: the wedged request cannot have produced an extraction`.
    /// A drawing that wedges the scanner has no 3 s bound, and that is the hang.
    @Test("Geometry extraction that outruns its deadline throws .timedOut and leaves the worker alive")
    func geometryExtractionHonoursItsDeadline() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()),
            maximumRestarts: 0,
            deadline: .milliseconds(400))

        do {
            _ = try await client.extractPageGeometry(
                documentAt: fixture.url, pageIndex: 0, debugDelayMilliseconds: 3000)
            Issue.record("the wedged request cannot have produced an extraction")
        } catch let error as ZPDFServiceError {
            guard case .timedOut = error else {
                Issue.record("expected .timedOut, got \(error)")
                await client.shutdown()
                return
            }
        }
        // Hang isolation, not crash isolation: the worker is still there. A
        // timeout that only ever fired on a dead process would be the old case
        // wearing a new name.
        #expect(await client.workerProcessIdentifier != nil, "the worker is alive, merely wedged")
        await client.shutdown()
    }

    /// Repair goes over the same mechanism, with its own much longer default.
    ///
    /// Old code: `ZPDFRepairServiceClient` had no `deadline` parameter at all, so
    /// this initialiser did not compile; measured with the deadline disarmed, the
    /// call returned a successful `RepairWireReply` after 3 s and promoted the
    /// staging file —
    /// `Issue recorded: the wedged repair cannot have produced a reply` plus
    /// `Expectation failed: !(…fileExists(atPath: …/repaired.pdf) → true)`.
    @Test("Repair perform honours its deadline")
    func repairPerformHonoursItsDeadline() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let output = fixture.directory.appendingPathComponent("repaired.pdf")

        let client = ZPDFRepairServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.repairWorkerURL()),
            maximumRestarts: 0,
            deadline: .milliseconds(400))

        do {
            _ = try await client.repair(
                input: fixture.url, output: output, debugDelayMilliseconds: 3000)
            Issue.record("the wedged repair cannot have produced a reply")
        } catch let error as ZPDFServiceError {
            guard case .timedOut = error else {
                Issue.record("expected .timedOut, got \(error)")
                await client.shutdown()
                return
            }
        }
        // Staging discipline survives the timeout: nothing was promoted.
        #expect(!FileManager.default.fileExists(atPath: output.path))
        await client.shutdown()
    }
}
