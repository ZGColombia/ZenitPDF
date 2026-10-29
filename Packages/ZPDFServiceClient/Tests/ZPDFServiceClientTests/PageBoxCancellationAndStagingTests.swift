import Foundation
import Testing
import ZPDFServiceWire
import ZPDFRepairServiceCore
@testable import ZPDFServiceClient

/// CR-127 and CR-136: the two places where a failure was thrown away rather than
/// forwarded — a cancel that never left the app, and an open error that was
/// replaced by a misleading one.
struct PageBoxCancellationAndStagingTests {

    /// CR-127. `pageBoxOnce` was the only operation without
    /// `withTaskCancellationHandler`, so cancelling the caller left the worker
    /// parsing a document the user had already walked away from.
    ///
    /// Old code: the cancel never crossed the boundary, the worker finished its
    /// delay and answered, and `task.value` returned a perfectly good
    /// `PageBoxWireReply` — `Issue recorded: a cancelled page-box read cannot
    /// return a result`.
    @Test("Cancelling a page-box read is forwarded to the worker as a cancel frame")
    func pageBoxCancellationCrossesTheBoundary() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()))
        let task = Task {
            try await client.pageBox(
                documentAt: fixture.url, pageIndex: 0, box: .crop,
                debugDelayMilliseconds: 10_000)
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("a cancelled page-box read cannot return a result")
        } catch let error as ZPDFServiceError {
            #expect(error == .cancelled, "the worker's cancellation must come back typed")
        }

        // The worker took the cancel and lived: the next request is answered by
        // the same process, so no restart was spent.
        let before = await client.workerLaunchCount
        let box = try await client.pageBox(documentAt: fixture.url, pageIndex: 0, box: .crop)
        #expect(box.boxWidth > 0 && box.boxHeight > 0)
        #expect(await client.workerLaunchCount == before, "cancel must not cost a respawn")
        await client.shutdown()
    }

    /// CR-136, after V-051. The failure a person meets when the destination folder cannot be
    /// written must name the real cause, not a boundary failure.
    ///
    /// CR-136 was a staging file beside the destination that would not open, turned by `try?`
    /// into a nil descriptor and reported from the far side of the boundary as
    /// "Couldn’t communicate with a helper application.". V-051 moved staging into a private
    /// folder (`StagedFileReplacement.stagingDirectory`), so an unwritable destination folder no
    /// longer stops staging: the repair runs, and the failure is the final move into the folder.
    /// The old version of this test still expected a staging failure and, through the XPC
    /// backend that `swift test` cannot reach, read that boundary message instead (sweep 11, I-26).
    @Test("An unwritable destination folder reports the output handoff, and leaves nothing behind")
    func unwritableDestinationReportsTheHandoff() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.brokenXref)
        defer { ServiceTestSupport.remove(fixture.directory) }

        // A destination folder the process may read but not write: a full volume, a read-only
        // mount, a folder the sandbox did not grant.
        let locked = fixture.directory.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let staged = ServiceTestSupport.RepairStagingLog()
        let client = ZPDFRepairServiceClient(backend: .inProcess(
            ServiceTestSupport.RecordingRepairExecutor(wrapped: RepairServiceCore(), log: staged)))
        do {
            _ = try await client.repair(
                input: fixture.url, output: locked.appendingPathComponent("repaired.pdf"))
            Issue.record("repair into an unwritable folder cannot succeed")
        } catch let error as ZPDFServiceError {
            guard case .malformedReply(_, let detail) = error else {
                Issue.record("expected the output handoff failure, got \(error)")
                return
            }
            #expect(detail.contains("output handoff failed"), "the detail names what failed: \(detail)")
            #expect(!detail.contains("helper application"), "a boundary message hides the cause: \(detail)")
        }
        // The repair itself ran against a private staging file, which is gone again, and the
        // locked folder holds nothing.
        let stagingPath = try #require(await staged.outputPaths.first, "the repair never ran")
        #expect(!FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: stagingPath).deletingLastPathComponent().path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).isEmpty)
        await client.shutdown()
    }
}
