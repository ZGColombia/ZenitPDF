import Foundation
import Testing
import ZPDFServiceWire
@testable import ZPDFServiceClient

/// CR-134 — a respawn that beats the dying worker's reader.
struct RespawnHygieneTests {

    /// A worker that exits at once but hands its stdout to a long-lived
    /// grandchild. The direct child is gone — so `ensureRunning` respawns — while
    /// the pipe's write end stays open, so the reader for that generation is
    /// still blocked on a read that will never return EOF. That is exactly the
    /// race in the finding: the respawn reaches `ensureRunning` before the dying
    /// reader reaches `readerFinished`.
    private func makeAbandoningWorker(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("abandoning-worker.sh")
        try """
        #!/bin/sh
        # Keep this generation's stdout write end open in a process that outlives
        # us, then leave: the parent sees a dead child and a reader that cannot
        # see EOF.
        sleep 30 &
        exit 0
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// Old code (measured with the retire step replaced by the bare
    /// `generation += 1` it used to be):
    /// `Expectation failed: (growth → 24) < (cycles → 8)` —
    /// `descriptors grew by 24 across 8 respawns (7 → 31)`. Three descriptors per
    /// crash cycle, held by a reader nobody could reach any more.
    @Test("Respawning after a crash retires the previous generation's descriptor and reader")
    func respawnDoesNotAbandonTheReader() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-respawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = try makeAbandoningWorker(in: directory)

        let connection = WireSubprocessConnection(
            executableURL: worker, arguments: [], deadline: .milliseconds(150))

        // One spawn to settle whatever the first request allocates once.
        _ = try? await connection.send(WireRequestFrame(kind: .ping))
        let cycles = 8
        let before = openDescriptorCount()
        for _ in 0..<cycles {
            _ = try? await connection.send(WireRequestFrame(kind: .ping))
        }
        // Give a retired reader a moment to unwind and drop its descriptor.
        try await Task.sleep(for: .milliseconds(500))
        let after = openDescriptorCount()

        // Not every cycle is guaranteed to respawn: under load `Process.isRunning` can
        // still report the exited worker as alive when the next send arrives, and that
        // cycle reuses it. The claim being tested is about what a respawn leaves behind,
        // so it only needs enough respawns to be meaningful.
        let launches = await connection.launchCount
        #expect(launches >= 3, "the cycles must actually respawn; launched \(launches) times")
        let growth = after - before
        // Every retired generation gives its descriptors back, so the table does
        // not grow at all across the cycles. One is allowed for measurement noise
        // (the directory read itself); eight would be one per crash cycle.
        #expect(growth <= 1,
                "descriptors grew by \(growth) across \(cycles) respawns (\(before) → \(after)): the previous generation was abandoned")
        await connection.shutdown()
    }
}
