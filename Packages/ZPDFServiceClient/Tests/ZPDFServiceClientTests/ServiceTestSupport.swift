import Foundation
import Testing
import ZPDFServiceWire
import ZPDFTestingSupport

/// Locates the worker executables `swift build --build-tests` put next to the
/// test bundle, and stages fixtures.
enum ServiceTestSupport {

    /// The build products directory containing `zpdf-geometry-worker` and
    /// `zpdf-repair-worker`.
    ///
    /// Swift Testing does not promise an `.xctest` bundle in `Bundle.allBundles`,
    /// so this walks up from the running binary until the workers appear.
    static func productsDirectory() throws -> URL {
        var candidates: [URL] = []
        // The most reliable anchor: the on-disk location of this test module
        // itself, via the loader. Everything the build emitted sits a few levels
        // above it.
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let name = info.dli_fname {
            candidates.append(URL(fileURLWithPath: String(cString: name)).deletingLastPathComponent())
        }
        candidates.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent())
        }

        for start in candidates {
            var directory = start.standardizedFileURL
            for _ in 0..<6 {
                let probe = directory.appendingPathComponent("zpdf-geometry-worker")
                if FileManager.default.fileExists(atPath: probe.path) { return directory }
                directory.deleteLastPathComponent()
            }
        }
        Issue.record("could not locate the build products directory from \(candidates)")
        throw CocoaError(.fileNoSuchFile)
    }

    static func geometryWorkerURL() throws -> URL {
        let url = try productsDirectory().appendingPathComponent("zpdf-geometry-worker")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "zpdf-geometry-worker is not built next to the test bundle")
        return url
    }

    static func repairWorkerURL() throws -> URL {
        let url = try productsDirectory().appendingPathComponent("zpdf-repair-worker")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "zpdf-repair-worker is not built next to the test bundle")
        return url
    }

    /// Writes one fixture into a fresh temp directory; caller removes the directory.
    static func makeFixture(_ kind: FixtureKind) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-service-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = try ZPDFFixtures.make(kind, in: directory)
        return (handle.url, directory)
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Where the repair client staged its output

/// The repair client stages every output in a private folder on the destination's volume and
/// removes that folder when the call ends (V-051). The folder is no longer beside the
/// destination, so a listing of the destination's folder cannot see a leak; a test has to ask
/// where the client told its service to write. These record exactly that.
extension ServiceTestSupport {

    /// The staging paths an executor was handed, and whether each one's folder existed at that
    /// moment — the control that proves the path is the live staging, so "gone afterwards" means
    /// "removed", not "never there".
    actor RepairStagingLog {
        private(set) var outputPaths: [String] = []
        private(set) var folderExistedDuringCall: [Bool] = []

        func record(_ outputPath: String?) {
            guard let outputPath else { return }
            outputPaths.append(outputPath)
            folderExistedDuringCall.append(
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: outputPath).deletingLastPathComponent().path))
        }
    }

    /// Records the output path the client hands its executor, then lets `wrapped` do the work.
    struct RecordingRepairExecutor: RepairInProcessExecuting {
        let wrapped: any RepairInProcessExecuting
        let log: RepairStagingLog

        func perform(request: RepairWireRequest, inputAt input: URL, outputPath: String?) async -> RepairReplyOutcome {
            await log.record(outputPath)
            return await wrapped.perform(request: request, inputAt: input, outputPath: outputPath)
        }
    }

    /// A worker that reads every frame it is sent into `frames` and answers nothing, like a
    /// service wedged in qpdf. Caller removes `directory`.
    ///
    /// `exec 3>&1` keeps the reply pipe open in the one process: redirecting standard output to
    /// the capture alone closes it, and the client reads that end-of-file as a crash.
    static func frameRecordingSilentWorker() throws -> (url: URL, directory: URL, frames: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-recording-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = directory.appendingPathComponent("frames.bin")
        let url = directory.appendingPathComponent("recording-worker")
        try Data("#!/bin/sh\nexec 3>&1\nexec /bin/cat > '\(frames.path)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, directory, frames)
    }

    /// The whole request frames in a recording worker's capture, in the order they were sent.
    static func requestFrames(in capture: URL) -> [WireRequestFrame] {
        guard let data = try? Data(contentsOf: capture) else { return [] }
        let bytes = [UInt8](data)
        var frames: [WireRequestFrame] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard offset + 4 + length <= bytes.count,
                  let frame = try? WireFraming.decodeBody(
                      WireRequestFrame.self, from: Data(bytes[offset + 4..<offset + 4 + length]))
            else { break }
            frames.append(frame)
            offset += 4 + length
        }
        return frames
    }
}
