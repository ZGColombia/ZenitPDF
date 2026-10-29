import Foundation
import Testing

/// The floors that stop a gate passing on a scan of nothing — asserted from outside the scripts.
///
/// This repository's oldest standing rule is that *a gate that examined nothing must fail*. Two
/// gates have broken it here already, and the second one broke it while looking correct — `verify-no-armed-recovery-markers.sh` reported `scanned 0`, `denied 0` and
/// exit 0, and the only thing wrong was that nothing had been found. A floor whose own behaviour
/// is never exercised is a comment; these tests exercise it in both directions, because a floor
/// proven only to fail could be an `exit 1` at the top of the file.
///
/// `.appTierSerialised` even though nothing here touches AppKit: every suite in this target
/// carries it, `AppTierSerialGate` enforces that with no exemption, and an exemption granted for
/// "this one is only subprocesses" is exactly the loophole that stops the rule being checkable.
@MainActor
@Suite("Gate non-vacuity floors", .appTierSerialised, .serialized)
struct GateFloorTests {

    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ZenitPDFAppKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Apps/ZenitPDF
        .deletingLastPathComponent()   // Apps
        .deletingLastPathComponent()   // repository root

    /// Runs a repository script and returns its exit status and combined output.
    ///
    /// `ZENIT_WAVE_QUIET` keeps the wave-marker banner out of the captured text; the marker
    /// check itself still runs, because suppressing a gate's own preamble in a test is how a
    /// test stops testing the gate people actually run.
    private func run(
        script: String,
        environment extra: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let url = Self.repositoryRoot.appendingPathComponent(script)
        #expect(FileManager.default.isExecutableFile(atPath: url.path), "\(script) is not executable")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [url.path]
        var environment = ProcessInfo.processInfo.environment
        environment["ZENIT_WAVE_QUIET"] = "1"
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-gate-floor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The armed-marker gate's floor

    /// A scan of a directory holding no project package at all must fail.
    ///
    /// This is the exact shape that was recorded: every root readable, nothing found, and a green
    /// closing line. A renamed extension, a `-maxdepth` that stopped reaching or a `-type d`
    /// that stopped holding all produce this state, and all three are silent.
    @Test("The armed-marker gate fails on a scan that found no project package")
    func armedMarkerGateFailsOnAnEmptyScan() throws {
        let empty = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try run(
            script: "Scripts/verify-no-armed-recovery-markers.sh",
            environment: ["ZENIT_ARMED_SCAN_ROOTS": empty.path]
        )
        #expect(result.status == 1, "a scan of nothing exited \(result.status)\n\(result.output)")
        #expect(result.output.contains("found no project package"))
        #expect(
            !result.output.contains("no project package is left armed"),
            "the gate printed its green line on a scan that examined nothing"
        )
    }

    /// A scan that finds one clean project package must pass.
    ///
    /// The other half, and not a formality: a floor that only ever fails is indistinguishable
    /// from a gate that is simply broken, and would be removed by the first person it blocked.
    @Test("The armed-marker gate passes on a scan that found one clean project package")
    func armedMarkerGatePassesOnACleanProject() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Clean.zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("journal.json"))

        let result = try run(
            script: "Scripts/verify-no-armed-recovery-markers.sh",
            environment: ["ZENIT_ARMED_SCAN_ROOTS": root.path]
        )
        #expect(result.status == 0, "a clean project exited \(result.status)\n\(result.output)")
        #expect(result.output.contains("scanned 1 project package"))
        #expect(result.output.contains("no project package is left armed"))
    }

    /// An armed package still fails, and still outranks everything else.
    ///
    /// The floor is new; the thing the gate is *for* is not, and a floor that quietly changed
    /// the verdict on a real armed marker would be a far worse defect than the one it closes.
    @Test("The armed-marker gate still fails on an armed marker")
    func armedMarkerGateStillFailsOnAnArmedMarker() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Crashed.zpdfproj", isDirectory: true)
        let recovery = package.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try Data("armed".utf8).write(to: recovery.appendingPathComponent("crash-marker"))

        let result = try run(
            script: "Scripts/verify-no-armed-recovery-markers.sh",
            environment: ["ZENIT_ARMED_SCAN_ROOTS": root.path]
        )
        #expect(result.status == 1, "an armed marker exited \(result.status)\n\(result.output)")
        #expect(result.output.contains("crash marker armed"))
        #expect(result.output.contains("Crashed.zpdfproj"))
    }

    /// The canary is a real file the gate makes and deletes, not a constant it prints.
    ///
    /// A normal run — no override — must announce that it found its own canary, and must leave
    /// nothing behind: a gate that littered a `.zpdfproj` per invocation into the temporary
    /// directory would be creating the very artefact this gate exists to catch.
    @Test("The armed-marker gate's canary is created, found and removed")
    func theArmedMarkerCanaryIsCreatedFoundAndRemoved() throws {
        let before = canaryDirectoryCount()
        let result = try run(script: "Scripts/verify-no-armed-recovery-markers.sh")
        // 0 (clean), 1 (something armed) or 75 (a root this process may not enumerate) are all
        // possible on a developer machine and none of them is this test's subject. What is
        // asserted is that the matcher proved itself, which the gate only prints when it did.
        #expect([0, 1, 75].contains(Int(result.status)), "unexpected exit \(result.status)")
        if result.status != 1 {
            #expect(
                result.output.contains("matcher canary: found"),
                "the gate did not prove its walk still matches a .zpdfproj\n\(result.output)"
            )
        }
        #expect(
            canaryDirectoryCount() == before,
            "the gate left a canary directory behind in the temporary directory"
        )
    }

    private func canaryDirectoryCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: NSTemporaryDirectory()
        )) ?? []
        return names.filter { $0.hasPrefix("zenit-armed-canary") }.count
    }

    // MARK: - The property, not the gate

    /// Every gate that counts something must compare that count against a floor.
    ///
    /// This is the deliverable rather than any one number: a gate whose success does not depend
    /// on it having examined something can go green while measuring nothing, and this
    /// repository has shipped that twice. The check is deliberately shaped as "the script
    /// mentions a floor and a `-lt` comparison against it" rather than as a list of expected
    /// constants — a list of constants is a second place to forget.
    @Test("Every counting gate carries a non-vacuity floor")
    func everyCountingGateCarriesAFloor() throws {
        // Gates that count something and must therefore refuse a count of nothing.
        let counting = [
            "Scripts/build-app-package.sh",
            "Scripts/verify-hook-wiring.sh",
            "Scripts/verify-licence-notices.sh",
            "Scripts/verify-test-tier-hygiene.sh",
            "Scripts/verify-viewer-budgets.sh",
            "Scripts/verify-no-uninjected-modals.sh",
            "Scripts/verify-no-armed-recovery-markers.sh",
            "Scripts/verify-multiplatform.sh",
            "Scripts/verify-author-scrub.sh",
            "Scripts/acceptance-core-loop.sh"
        ]
        for script in counting {
            let url = Self.repositoryRoot.appendingPathComponent(script)
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n")
            #expect(
                code.contains("-lt ") || code.contains("-eq 0") || code.contains("-gt 0"),
                "\(script) counts nothing it refuses to pass on"
            )
            #expect(
                code.lowercased().contains("floor")
                    || code.contains("MINIMUM")
                    || code.contains("MIN_")
                    || code.contains("EXPECTED_MINIMUM")
                    || code.contains("scanned nothing")
                    || code.contains("examined nothing")
                    || code.contains("scanned zero")
                    || code.contains("found no"),
                "\(script) has no named non-vacuity floor"
            )
        }
    }
}
