import Foundation
import Testing
import ZPDFPersistence

/// NL-PLAT-10: "Send Project…" writes one zip of the last saved state, without `recovery/` or the
/// crash marker, and it opens on the other side as a clean project.
@Suite("Send Project archive — NL-PLAT-10")
struct SendArchiveTests {

    private func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archive.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("The archive holds the saved package, never recovery/ or versions/, and opens with no recovery prompt")
    func archiveOpensClean() async throws {
        let workspace = try TestSupport.makeWorkspace("SendArchive")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let second = try TestSupport.makeSourcePDF(in: workspace.root.appendingPathComponent("second", isDirectory: true), kind: .singleLine)
        _ = try await package.addDocument(originalPDF: second, displayName: "Second")
        _ = try await package.save()
        // The project is still open: its crash marker is armed on disk right now.
        let archive = workspace.root.appendingPathComponent("Project.zip")
        let written = try await package.writeSendArchive(to: archive, packageName: "Project.zpdfproj")
        #expect(written.contains(ProjectPackageLayout.manifest))
        #expect(written.contains(ProjectPackageLayout.database))
        #expect(!written.contains { $0.hasPrefix("recovery/") || $0.hasPrefix("versions/") })
        try await package.close()

        let other = workspace.root.appendingPathComponent("colleague", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try unzip(archive, into: other)
        let received = other.appendingPathComponent("Project.zpdfproj", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: received.member(ProjectPackageLayout.crashMarker).path))
        // Nothing to recover: the recipient is never asked "was not closed properly".
        let assessment = try await ProjectPackage.assessRecovery(at: received)
        #expect(assessment.isClean, "\(assessment)")
        let reopened = try await ProjectPackage.open(at: received, resolving: .discard)
        let names = try await reopened.read { db in try DocumentRecord.fetchAll(db).map(\.displayName).sorted() }
        #expect(names.count == 2 && names.contains("Second"))
        try await reopened.close()
    }

    @Test("An unsaved project is refused with a sentence rather than sent half-written")
    func unsavedRefused() async throws {
        let workspace = try TestSupport.makeWorkspace("SendArchiveUnsaved")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let versions = workspace.packageURL.member(ProjectPackageLayout.versions)
        try? FileManager.default.removeItem(at: versions.appendingPathComponent("latest"))
        await #expect(throws: ProjectPackage.SendArchiveError.notSavedYet) {
            try await package.writeSendArchive(to: workspace.root.appendingPathComponent("x.zip"), packageName: "P.zpdfproj")
        }
        try await package.close()
    }
}
