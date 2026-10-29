import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFSnapScenario

/// `QUALITY_BAR` S15 and 3.4: the same path must produce the same decision log, in one process
/// and across twenty fresh ones.
///
/// This is not a formality. `Hasher` is randomly seeded per process, so any ordering that
/// reaches into a `Set` or a `Dictionary` differs between runs and produces a snap engine that
/// behaves differently on Tuesday. The 20-process run is the only thing that can catch it, and
/// it is run with `SWIFT_DETERMINISTIC_HASHING` **unset** — forcing it on defeats the test and
/// is forbidden by 3.4 rule 4.
@Suite("Snap determinism (QUALITY_BAR 3.4, S15)")
struct SnapDeterminismTests {

    @Test("The same path produces the same log across 100 repeats in one process")
    func repeatedInProcess() throws {
        let reference = try SnapDeterminismScenario.decisionLog()
        #expect(reference.count > 300)
        for _ in 0..<100 {
            #expect(try SnapDeterminismScenario.decisionLog() == reference)
        }
    }

    @Test("Shuffling the order geometry is inserted does not change one byte of the log")
    func insertionOrderIsNotObservable() throws {
        let reference = try SnapDeterminismScenario.decisionLog(insertionSeed: 0)
        for seed in UInt64(1)...32 {
            let shuffled = try SnapDeterminismScenario.decisionLog(insertionSeed: seed)
            #expect(shuffled == reference, "insertion seed \(seed) changed the log" as Comment)
        }
    }

    @Test("Twenty freshly spawned processes produce byte-identical logs")
    func twentyFreshProcesses() throws {
        let executable = try #require(
            Self.locateDecisionLogExecutable(),
            "the zpdf-snap-decision-log executable was not found next to the test bundle"
        )

        var outputs: [String] = []
        for run in 0..<20 {
            let process = Process()
            process.executableURL = executable
            process.arguments = []
            // The environment is inherited *except* for the hashing override: 3.4 rule 4
            // requires the run to happen with per-process random hash seeding in force, and a
            // developer with SWIFT_DETERMINISTIC_HASHING exported in their shell would
            // otherwise silently turn this test into a no-op.
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING")
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0, "run \(run) exited \(process.terminationStatus)" as Comment)
            outputs.append(String(decoding: data, as: UTF8.self))
        }

        #expect(outputs.count == 20)
        let first = try #require(outputs.first)
        #expect(!first.isEmpty)
        #expect(first.split(separator: "\n").count > 300)
        for (run, output) in outputs.enumerated() {
            #expect(output == first, "process \(run) produced a different decision log" as Comment)
        }
    }

    /// Finds the built `zpdf-snap-decision-log` binary.
    ///
    /// The test bundle lives in the same build directory as the executable, so the bundle's own
    /// location is the reliable anchor; the `.build` walk is a fallback for a layout that puts
    /// them elsewhere.
    static func locateDecisionLogExecutable() -> URL? {
        let name = "zpdf-snap-decision-log"
        final class BundleAnchor {}
        let bundleDirectory = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        let direct = bundleDirectory.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: direct.path) { return direct }

        // Walk up from this source file to the package root and search its build directory.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let manifest = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) {
                let build = directory.appendingPathComponent(".build")
                guard let walker = FileManager.default.enumerator(
                    at: build,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { return nil }
                var found: [URL] = []
                for case let url as URL in walker where url.lastPathComponent == name {
                    if FileManager.default.isExecutableFile(atPath: url.path) { found.append(url) }
                }
                // Sort so the choice does not depend on directory enumeration order.
                return found.sorted { $0.path < $1.path }.first
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
