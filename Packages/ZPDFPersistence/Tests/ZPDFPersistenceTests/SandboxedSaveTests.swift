import Foundation
import Testing
import ZPDFPersistence

/// The proof that a save works under the App Sandbox, which the unsandboxed suite could not
/// give.
///
/// In the assembled app a save panel's powerbox grant covers the chosen URL and nothing
/// beside it, so a pipeline that stages hidden *sibling* temporaries fails at every
/// destination a user can pick — which is exactly how the bug shipped past twelve green
/// gates. This suite reproduces that grant shape with a seatbelt profile: the harness
/// process may write **inside** the package and nowhere else in the package's parent
/// directory, the way `sandbox-exec` enforces it, and the save must still succeed.
///
/// The profile is proven to bite before it is trusted: a control write of a sibling file
/// under the same profile must fail, or the test would be a formality (a gate that checks
/// nothing must fail).
struct SandboxedSaveTests {

    /// `realpath(3)`: seatbelt matches against the vnode's canonical path, and
    /// `URL.resolvingSymlinksInPath()` deliberately renders `/private/var` as `/var` —
    /// the opposite of what the kernel sees. Both spellings go into the profile anyway.
    private func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let result = realpath(url.path, &buffer) else { return url.path }
        return String(cString: result)
    }

    /// Builds the powerbox-shaped profile: everything allowed except writes into the
    /// package's parent directory, with the package subtree itself re-allowed. Each path
    /// appears in both its literal and canonical spellings, because the kernel evaluates
    /// canonical paths and the tests hand out `/var/…` ones.
    private func powerboxProfile(parent: URL, granted: URL) -> String {
        let parentPaths = Set([parent.path, canonicalPath(parent)])
        // The granted URL may not exist yet (first create); anchor its canonical form on
        // the parent's canonical form instead.
        let grantedPaths = Set(parentPaths.map { "\($0)/\(granted.lastPathComponent)" })
        let denies = parentPaths
            .map { "(deny file-write* (subpath \"\($0)\"))" }
            .joined(separator: "\n")
        let allows = grantedPaths
            .map { "(allow file-write* (subpath \"\($0)\"))" }
            .joined(separator: "\n")
        return """
        (version 1)
        (allow default)
        \(denies)
        \(allows)
        """
    }

    /// Runs a command line under `sandbox-exec` with the given profile.
    private func runSandboxed(profile: String, executable: URL, arguments: [String]) throws -> TestSupport.ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, executable.path] + arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return TestSupport.ProcessResult(
            exitStatus: process.terminationStatus,
            terminatingSignal: process.terminationReason == .uncaughtSignal
                ? process.terminationStatus
                : nil,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }

    @Test("A save succeeds where the sandbox denies every sibling write — the 12.5 grant shape")
    func saveSucceedsUnderAPowerboxShapedSandbox() async throws {
        let workspace = try TestSupport.makeWorkspace("SandboxedSave")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        // Built and saved once, unsandboxed, so the sandboxed run is a *re*-save of a
        // real package — the operation that failed live at every chosen location.
        let created = try TestSupport.runHarness([
            "create",
            "--package", workspace.packageURL.path,
            "--pdf", workspace.sourcePDF.path,
            "--seed", "50"
        ])
        #expect(created.exitStatus == 0, "create failed: \(created.standardError)")
        let countBefore = try TestSupport.markupCount(inPackageAt: workspace.packageURL)

        let profile = powerboxProfile(parent: workspace.root, granted: workspace.packageURL)

        // ── The profile must actually deny sibling writes, or this test proves nothing ──
        let probe = try runSandboxed(
            profile: profile,
            executable: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [workspace.root.appendingPathComponent("sibling-probe").path]
        )
        #expect(probe.exitStatus != 0, "the profile failed to deny a sibling write")
        #expect(
            !FileManager.default.fileExists(
                atPath: workspace.root.appendingPathComponent("sibling-probe").path
            ),
            "the sibling probe file exists — the profile is not enforcing anything"
        )

        // ── The save itself, under exactly that grant ───────────────────────────────
        let saved = try runSandboxed(
            profile: profile,
            executable: try TestSupport.harnessExecutableURL(),
            arguments: [
                "save",
                "--package", workspace.packageURL.path,
                "--insert", "25",
                "--kill-at", "none"
            ]
        )
        #expect(saved.exitStatus == 0,
                "the sandboxed save failed — the 12.5 grant shape is still fatal: \(saved.standardError)")
        #expect(saved.standardOutput.contains("saved generation"),
                "no completed save reported: \(saved.standardOutput) \(saved.standardError)")

        // The rows arrived, the saved state is coherent, and the version slot rotated —
        // all of it inside the granted package, none of it beside it.
        #expect(try TestSupport.markupCount(inPackageAt: workspace.packageURL) == countBefore + 25)
        let verification = try ProjectPackage.verifyIntegrity(at: workspace.packageURL)
        #expect(verification.manifestHashMatches)
        #expect(verification.originalPDFHashMatches)
        let latest = ProjectPackage.versionsRootURL(forPackageAt: workspace.packageURL)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
        #expect(try ProjectPackage.verifyIntegrity(at: latest).isFullyConsistent,
                "the rotated version slot is not self-consistent")
        #expect(try TestSupport.markupCount(inPackageAt: latest) == countBefore + 25)

        // No sibling of any kind appeared next to the package.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
            .filter { $0 != workspace.packageURL.lastPathComponent && $0 != "source" }
        #expect(siblings.isEmpty, "the save left siblings behind: \(siblings)")
    }

    @Test("Creating a package succeeds where only the destination itself is writable")
    func createSucceedsUnderAPowerboxShapedSandbox() async throws {
        let workspace = try TestSupport.makeWorkspace("SandboxedCreate")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        // The grant covers the (not yet existing) package path only. `touch` of another
        // sibling under the same profile must fail, proving the shape.
        let profile = powerboxProfile(parent: workspace.root, granted: workspace.packageURL)
        let probe = try runSandboxed(
            profile: profile,
            executable: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [workspace.root.appendingPathComponent("create-probe").path]
        )
        #expect(probe.exitStatus != 0, "the profile failed to deny a sibling write")

        let created = try runSandboxed(
            profile: profile,
            executable: try TestSupport.harnessExecutableURL(),
            arguments: [
                "create",
                "--package", workspace.packageURL.path,
                "--pdf", workspace.sourcePDF.path,
                "--seed", "5"
            ]
        )
        #expect(created.exitStatus == 0,
                "the sandboxed create failed: \(created.standardError)")
        #expect(try TestSupport.markupCount(inPackageAt: workspace.packageURL) == 5)
        #expect(try ProjectPackage.verifyIntegrity(at: workspace.packageURL).manifestHashMatches)
    }
}
