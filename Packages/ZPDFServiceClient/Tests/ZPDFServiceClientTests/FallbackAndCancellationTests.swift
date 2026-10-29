import Foundation
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport
import ZPDFRepairServiceCore
import ZPDFServiceClient

/// The in-process fallback is the pre-S15 code path with the same surface, so a
/// dev build without service bundles regresses nothing; and cancellation crosses
/// the boundary in both directions.
struct FallbackAndCancellationTests {

    @Test("In-process fallback and the worker produce identical geometry for the same file")
    func fallbackMatchesWorker() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.polygonThreeHoles)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let inProcess = ZPDFGeometryServiceClient(backend: .inProcess)
        let worker = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()))

        let local = try await inProcess.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)
        let remote = try await worker.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)

        #expect(!local.primitives.isEmpty)
        #expect(local.primitives == remote.primitives,
                "where the work ran must not change what came out")
        #expect(local.availability == remote.availability)
        #expect(local.pageTransform == remote.pageTransform)
        await worker.shutdown()
    }

    @Test("automatic() without an app bundle around it falls back to in-process and works")
    func automaticFallsBackInProcess() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }

        // `swift test` has no Contents/XPCServices, so this must be the fallback.
        let client = ZPDFGeometryServiceClient.automatic()
        let extraction = try await client.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)
        #expect(!extraction.primitives.isEmpty)
    }

    @Test("Cancelling the calling task surfaces ZPDFServiceError.cancelled — in-process backend")
    func cancellationInProcess() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let client = ZPDFGeometryServiceClient(backend: .inProcess)
        let task = Task {
            try await client.extractPageGeometry(
                documentAt: fixture.url, pageIndex: 0, debugDelayMilliseconds: 5000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled extraction cannot return a result")
        } catch let error as ZPDFServiceError {
            #expect(error == .cancelled)
        }
    }

    @Test("Cancelling the calling task is forwarded to the worker as a cancel frame")
    func cancellationCrossesTheBoundary() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }

        let client = ZPDFGeometryServiceClient(
            backend: .subprocess(executableURL: try ServiceTestSupport.geometryWorkerURL()))
        let task = Task {
            try await client.extractPageGeometry(
                documentAt: fixture.url, pageIndex: 0, debugDelayMilliseconds: 10_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled extraction cannot return a result")
        } catch let error as ZPDFServiceError {
            #expect(error == .cancelled, "the worker's cancellation must come back typed")
        }

        // The worker did not die from the cancel: same process answers the next request.
        let before = await client.workerLaunchCount
        let extraction = try await client.extractPageGeometry(documentAt: fixture.url, pageIndex: 0)
        #expect(!extraction.primitives.isEmpty)
        #expect(await client.workerLaunchCount == before, "cancel must not cost a respawn")
        await client.shutdown()
    }

    @Test("Repair in-process fallback: broken-xref repair end to end, atomic into place")
    func repairFallbackInProcess() async throws {
        let broken = try ServiceTestSupport.makeFixture(.brokenXref)
        defer { ServiceTestSupport.remove(broken.directory) }

        // S17-03: the fallback still exists for `swift test`, but it has to be
        // handed the executor explicitly, and the only conformance lives in
        // `ZPDFRepairServiceCore` — a target the application does not link.
        let staged = ServiceTestSupport.RepairStagingLog()
        let client = ZPDFRepairServiceClient(backend: .inProcess(
            ServiceTestSupport.RecordingRepairExecutor(wrapped: RepairServiceCore(), log: staged)))
        let output = broken.directory.appendingPathComponent("repaired.pdf")
        let before = try FileManager.default.contentsOfDirectory(atPath: broken.directory.path)
        let reply = try await client.repair(input: broken.url, output: output)
        #expect(reply.outputByteCount > 0)
        let verdict = try await client.inspect(output)
        #expect(verdict.isDamaged == false)

        // Nothing half-written is left behind: not beside the destination, and not in the
        // private folder the output was staged in (V-051 moved it there; a listing of the
        // destination's folder alone could no longer fail).
        #expect(try FileManager.default.contentsOfDirectory(atPath: broken.directory.path).sorted()
                == (before + ["repaired.pdf"]).sorted())
        let stagingPath = try #require(await staged.outputPaths.first, "the executor was handed no output path")
        let stagingFolder = URL(fileURLWithPath: stagingPath).deletingLastPathComponent()
        #expect(await staged.folderExistedDuringCall == [true], "the recorded path was not the live staging")
        #expect(stagingFolder.standardizedFileURL.resolvingSymlinksInPath().path
                != broken.directory.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(!FileManager.default.fileExists(atPath: stagingFolder.path),
                "the staging folder must not survive a completed operation")
    }
}
