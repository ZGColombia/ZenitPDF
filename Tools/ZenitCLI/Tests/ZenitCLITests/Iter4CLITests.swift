import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPersistence
import ZPDFTestingSupport
@testable import ZenitCLICore

/// Iteration 4: `zenit totals`, `export` and `info` refuse a project that `zenit verify`
/// fails, unless asked not to (U-101), and never read a drawing from outside the package.
@Suite("zenit CLI — iteration 4", .serialized)
struct Iter4CLITests {

    private typealias E2E = ZenitCLIEndToEndTests

    /// The saved fixture with `documents/working.pdf` changed by another program.
    static func tamperedProject() async throws -> ZenitCLIEndToEndTests.Saved {
        let saved = try await E2E.makeSaved()
        let working = saved.package.appendingPathComponent(ProjectPackageLayout.workingPDF)
        let handle = try FileHandle(forWritingTo: working)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n% appended by another program\n".utf8))
        try handle.close()
        return saved
    }

    /// Runs `zenit`, returning its exit status, standard output and standard error.
    static func run(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = try E2E.productsDirectory().appendingPathComponent("zenit")
        process.arguments = arguments
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outputData, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }

    /// Old output: `load()` returned the takeoff; `zenit totals --json` printed the totals and
    /// exited 0, `info` printed the project and exited 0, `export` wrote the file and exited 0 —
    /// while `zenit verify` on the same package exited 1 with "integrity: modifiedOutsideZenitPDF".
    @Test("U-101: totals, export and info refuse a project verify fails, with exit code 1")
    func unverifiedProjectIsRefused() async throws {
        let saved = try await Self.tamperedProject()
        defer { try? FileManager.default.removeItem(at: saved.directory) }

        do {
            _ = try await ProjectReader(url: saved.package).load()
            Issue.record("a project that fails verification was loaded")
        } catch let ProjectReader.Failure.unverified(path, problems) {
            #expect(path == saved.package.path)
            #expect(problems.contains { $0.hasPrefix("integrity: modifiedOutsideZenitPDF") }, "\(problems)")
        }

        let totals = try Self.run(["totals", saved.package.path, "--json"])
        #expect(totals.status == 1)
        #expect(totals.output.isEmpty, "no number reaches standard output: \(totals.output)")
        #expect(totals.error.contains("fails verification"))
        #expect(totals.error.contains("--allow-unverified"))

        #expect(try Self.run(["info", saved.package.path]).status == 1)

        let destination = saved.directory.appendingPathComponent("ledger.csv")
        let export = try Self.run(["export", saved.package.path, "--format", "csv", "--output", destination.path])
        #expect(export.status == 1)
        #expect(!FileManager.default.fileExists(atPath: destination.path), "nothing is exported")
    }

    @Test("U-101: --allow-unverified reports the numbers and names the problems on standard error")
    func allowUnverifiedReportsWithAWarning() async throws {
        let saved = try await Self.tamperedProject()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let live = ProjectReader.totals(try await E2E.applicationProjection(saved.session, name: saved.name))

        let loaded = try await ProjectReader(url: saved.package, allowUnverified: true).load()
        #expect(loaded.verificationProblems.contains { $0.hasPrefix("integrity: modifiedOutsideZenitPDF") })

        let totals = try Self.run(["totals", saved.package.path, "--json", "--allow-unverified"])
        #expect(totals.status == 0)
        #expect(totals.error.contains("warning:"), "the problems are said: \(totals.error)")
        #expect(totals.error.contains("integrity: modifiedOutsideZenitPDF"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(totals.output.utf8)) as? [String: Any])
        let rows = try #require(object["totals"] as? [[String: String]])
        #expect(rows.map { $0["value"] ?? "" } == live.map(\.value))
    }

    @Test("U-101: a sound project loads with no problems and no warning")
    func soundProjectHasNoProblems() async throws {
        let saved = try await E2E.makeSaved()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let loaded = try await ProjectReader(url: saved.package).load()
        #expect(loaded.verificationProblems.isEmpty)
        let totals = try Self.run(["totals", saved.package.path])
        #expect(totals.status == 0)
        #expect(!totals.error.contains("warning:"))
    }

    // MARK: - A drawing row that points out of the package

    /// Old output: the second drawing was read from the planted PDF outside the package — the
    /// snapshot's `documents/` joined with the row's `../…` path — and `load()` answered two
    /// drawings. Now, even under `--allow-unverified`, the row is refused.
    @Test("U-101: a drawing row whose path leaves documents/ is refused, even when unverified is allowed")
    func drawingOutsideThePackageIsRefused() async throws {
        let project = try await Iter1CLITests.makeTwoDrawingProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let planted = try ZPDFFixtures.make(.singleLine, in: project.directory.appendingPathComponent("planted")).url
        let traversal = "documents/" + String(repeating: "../", count: 40) + planted.path.dropFirst()
        let database = project.package.appendingPathComponent(ProjectPackageLayout.database)
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [database.path, "UPDATE document SET relative_path = '\(traversal)' WHERE relative_path LIKE 'documents/added-%';"]
        try sqlite.run()
        sqlite.waitUntilExit()
        try #require(sqlite.terminationStatus == 0)

        // Verification refuses first: the database no longer matches its integrity record.
        await #expect(throws: ProjectReader.Failure.self) {
            _ = try await ProjectReader(url: project.package).load()
        }
        do {
            _ = try await ProjectReader(url: project.package, allowUnverified: true).load()
            Issue.record("a drawing outside the package was read")
        } catch let ProjectReader.Failure.drawingOutsidePackage(path) {
            #expect(path == traversal)
        }
    }

    @Test("U-101: the drawing-member rule — the working copy for the primary, documents/ only for the rest")
    func drawingMemberRule() throws {
        #expect(try ProjectReader.drawingMember(relativePath: "documents/original.pdf", isPrimary: true) == ProjectPackageLayout.workingPDF)
        #expect(try ProjectReader.drawingMember(relativePath: "documents/added-7.pdf", isPrimary: false) == "documents/added-7.pdf")
        for hostile in ["../outside.pdf", "documents/../../x.pdf", "/etc/hosts", "project.sqlite", "documentsX/a.pdf"] {
            #expect(throws: ProjectReader.Failure.self, "\(hostile)") {
                _ = try ProjectReader.drawingMember(relativePath: hostile, isPrimary: false)
            }
        }
    }
}
