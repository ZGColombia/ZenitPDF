import Foundation
import Testing

/// How `Scripts/build-app.sh` signs, driven through the shipping signing library,
/// `Scripts/lib/zenit-codesign.sh`, on throwaway bundles in the temporary directory.
///
/// Two rules are pinned here. A normal build is ad-hoc for everyone: it reads no certificate and
/// no keychain, even when one is configured, and consecutive builds keep one code identity
/// (NL-PLAT-01: a sandboxed app's container and its security-scoped bookmarks are tied to the
/// designated requirement, so a per-build cdhash would make every new build "a different app").
/// The maintainer's certificate is used only under `ZENIT_RELEASE_SIGNING=1`.
///
/// Nothing here signs in release mode — that needs the maintainer's keychain — and nothing
/// reads the keychain: the release-mode test passes an explicit identity and only asks the
/// library which identity it would use.
@Suite("Signing modes of the build", .appTierSerialised)
struct SigningModeTests {

    private struct ToolFailure: Error, CustomStringConvertible { let description: String }

    /// …/Apps/ZenitPDF/Tests/ZenitPDFAppKitTests/SigningModeTests.swift → repository root.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let signingLibrary = repositoryRoot.appendingPathComponent("Scripts/lib/zenit-codesign.sh")

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil,
                            allowFailure: Bool = false) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            throw ToolFailure(description: "\(tool) \(arguments.joined(separator: " ")) → \(process.terminationStatus): \(output)")
        }
        return (process.terminationStatus, output)
    }

    /// The environment of a normal build: no release flag, whatever else the caller's shell has.
    private static func buildEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZENIT_RELEASE_SIGNING")
        environment.removeValue(forKey: "ZENIT_CODESIGN_IDENTITY")
        environment.merge(extra) { _, new in new }
        return environment
    }

    /// Runs `script` with the signing library sourced; `$1…` are `arguments`.
    private static func withLibrary(_ script: String, _ arguments: [String] = [],
                                    environment: [String: String]) throws -> (status: Int32, output: String) {
        try run("/bin/bash", ["-c", "source \"$0\" && \(script)", signingLibrary.path] + arguments,
                environment: environment, allowFailure: true)
    }

    private final class Fixture {
        let root: URL
        let executables: [URL]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zpdf-signing-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Two different programs, so the two "builds" are genuinely different code.
            var made: [URL] = []
            for (index, body) in ["return 0;", "return 1;"].enumerated() {
                let source = root.appendingPathComponent("probe\(index).c")
                try Data("int main(void) { \(body) }\n".utf8).write(to: source)
                let binary = root.appendingPathComponent("probe\(index)")
                try SigningModeTests.run("/usr/bin/xcrun", ["clang", "-o", binary.path, source.path])
                made.append(binary)
            }
            executables = made
        }

        func unsignedBundle(named name: String, build: Int, identifier: String = "com.zenitgroup.zenitpdf") throws -> URL {
            let app = root.appendingPathComponent("\(name)/Zenit PDF.app", isDirectory: true)
            let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: executables[build % 2], to: macOS.appendingPathComponent("ZenitPDF"))
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": "ZenitPDF",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "\(build)",
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }

        /// Signs exactly as a normal `Scripts/build-app.sh` run does — and with a maintainer
        /// identity named in the environment, which a normal build must ignore.
        func signLikeANormalBuild(_ app: URL) throws {
            let environment = SigningModeTests.buildEnvironment(["ZENIT_CODESIGN_IDENTITY": "0000000000000000000000000000000000000000"])
            let result = try SigningModeTests.withLibrary("zenit_codesign_prepare && zenit_sign \"$1\"", [app.path],
                                                          environment: environment)
            guard result.status == 0 else { throw ToolFailure(description: result.output) }
        }

        func requirement(_ app: URL) throws -> String {
            let output = try SigningModeTests.run("/usr/bin/codesign", ["-d", "-r-", app.path]).output
            let line = output.split(separator: "\n").first { $0.contains("designated => ") } ?? ""
            return line.components(separatedBy: "designated => ").last ?? ""
        }

        func cdhash(_ app: URL) throws -> String {
            let output = try SigningModeTests.run("/usr/bin/codesign", ["-dvvv", app.path]).output
            return output.split(separator: "\n").first { $0.hasPrefix("CDHash=") }.map(String.init) ?? ""
        }

        func teamIdentifier(_ app: URL) throws -> String {
            let output = try SigningModeTests.run("/usr/bin/codesign", ["-dvvv", app.path]).output
            return output.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
                .map { String($0.dropFirst("TeamIdentifier=".count)) } ?? ""
        }

        /// Whether `candidate` satisfies `requirement` — the question macOS asks of a new build.
        func satisfies(_ candidate: URL, _ requirement: String) throws -> Bool {
            try SigningModeTests.run("/usr/bin/codesign", ["--verify", "-R=\(requirement)", candidate.path],
                                     allowFailure: true).status == 0
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("A normal build signs ad-hoc with one stable identity, and ignores a configured certificate")
    func normalBuildsAreAdHocAndStable() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let a = try fixture.unsignedBundle(named: "A", build: 1)
        let b = try fixture.unsignedBundle(named: "B", build: 2)
        try fixture.signLikeANormalBuild(a)
        try fixture.signLikeANormalBuild(b)

        #expect(try fixture.cdhash(a) != fixture.cdhash(b), "the two builds must be different code")
        let requirement = try fixture.requirement(a)
        #expect(requirement == "identifier \"com.zenitgroup.zenitpdf\"")
        #expect(try fixture.requirement(b) == requirement)
        #expect(try fixture.teamIdentifier(a) == "not set", "a normal build carries no certificate")
        #expect(try fixture.satisfies(b, requirement),
                "build B must satisfy build A's requirement, or macOS asks on the next launch")
    }

    @Test("The stable ad-hoc requirement still refuses a bundle claiming another identifier")
    func otherIdentifierRefused() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let a = try fixture.unsignedBundle(named: "A", build: 1)
        let impostor = try fixture.unsignedBundle(named: "I", build: 2, identifier: "com.example.other")
        try fixture.signLikeANormalBuild(a)
        try fixture.signLikeANormalBuild(impostor)
        #expect(!(try fixture.satisfies(impostor, try fixture.requirement(a))))
    }

    @Test("Only ZENIT_RELEASE_SIGNING=1 selects a certificate; that mode never falls back to ad-hoc")
    func releaseSigningIsOptIn() throws {
        let identity = "0000000000000000000000000000000000000000"

        let normal = try Self.withLibrary("zenit_codesign_prepare 2>/dev/null; printf '%s|%s' \"$(zenit_codesign_mode)\" \"$(zenit_codesign_identity)\"",
                                          environment: Self.buildEnvironment(["ZENIT_CODESIGN_IDENTITY": identity]))
        #expect(normal.status == 0)
        #expect(normal.output == "adhoc-stable|-", "a normal build used a certificate: \(normal.output)")

        let release = try Self.withLibrary("zenit_codesign_prepare 2>/dev/null; printf '%s|%s' \"$(zenit_codesign_mode)\" \"$(zenit_codesign_identity)\"",
                                           environment: Self.buildEnvironment(["ZENIT_RELEASE_SIGNING": "1",
                                                                               "ZENIT_CODESIGN_IDENTITY": identity]))
        #expect(release.status == 0)
        #expect(release.output == "release|\(identity)", "release signing did not take the named identity: \(release.output)")

        // Certificate mode with an unresolved identity must refuse to sign rather than sign ad-hoc.
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let app = try fixture.unsignedBundle(named: "R", build: 1)
        let unresolved = try Self.withLibrary("zenit_sign \"$1\"", [app.path],
                                              environment: Self.buildEnvironment(["ZENIT_RELEASE_SIGNING": "1"]))
        #expect(unresolved.status != 0, "a release signed without an identity: \(unresolved.output)")
        #expect(unresolved.output.contains("zenit_codesign_prepare"))
    }

    @Test("build-app.sh checks the requirement pin only under ZENIT_RELEASE_SIGNING=1")
    func thePinIsReleaseOnly() throws {
        let script = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        let code = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        // The pin is read inside the release branch and nowhere else.
        let pinReads = code.enumerated().filter { $0.element.contains("DesignatedRequirement.txt") && !$0.element.contains("fail ") }
        let releaseBranch = try #require(code.firstIndex { $0.contains("if zenit_release_signing; then") })
        let elseBranch = try #require(code[releaseBranch...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "else" })
        #expect(!pinReads.isEmpty, "build-app.sh no longer reads the pin at all")
        for read in pinReads {
            #expect(read.offset > releaseBranch && read.offset < elseBranch,
                    "the pin is read outside the release branch: \(read.element)")
        }
        #expect(code.contains { $0.contains("zenit_codesign_prepare") }, "build-app.sh never resolves the signing mode")
    }
}
