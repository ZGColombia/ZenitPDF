import Foundation
import GRDB
import Testing
import ZPDFSpreadsheet
import ZPDFPersistence
import ZPDFTestingSupport

/// Send Project leaves out the previous save's pictures and
/// totals (S-118); added drawings and stored revisions are checked against their recorded
/// digests on open (S-120); a failed read-only open of an older project leaves no staging
/// directory (S-123).
@Suite("Iteration 2 — persistence", .serialized)
struct Iter2PersistenceTests {

    // MARK: - S-118

    /// Old output: the zip carried `thumbnails/package.png`, `thumbnails/preview.png`,
    /// `thumbnails/summary.json` and `QuickLook/Thumbnail.png` — the pictures and totals the
    /// app wrote after the save *before* this one, which step 8 had cloned into `latest`.
    @Test("S-118: Send Project leaves out the Quick Look pictures and totals the app writes after a save")
    func sendArchiveLeavesOutPostSavePreviews() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter2SendPreview")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        _ = try await package.save()
        // What the app writes after the first save returns…
        let thumbnails = workspace.packageURL.member(ProjectPackageLayout.thumbnails)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        for name in ["package.png", "preview.png", "summary.json"] {
            try Data("first save".utf8).write(to: thumbnails.appendingPathComponent(name))
        }
        let finder = workspace.packageURL.member(ProjectPackageLayout.finderQuickLook)
        try FileManager.default.createDirectory(at: finder, withIntermediateDirectories: true)
        try Data("first save".utf8).write(to: finder.appendingPathComponent("Thumbnail.png"))
        // …is cloned into `latest` by the second save, beside the second save's database.
        _ = try await package.save()
        let latest = workspace.packageURL.member(ProjectPackageLayout.versions)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: latest.appendingPathComponent("thumbnails/summary.json").path),
                "the precondition: latest carries the earlier save's summary")

        let archive = workspace.root.appendingPathComponent("Project.zip")
        let written = try await package.writeSendArchive(to: archive, packageName: "Project.zpdfproj")
        try await package.close()
        #expect(!written.contains { $0.hasPrefix("thumbnails/") || $0.hasPrefix("QuickLook/") }, "\(written)")
        let reader = try ZipArchiveReader(data: try Data(contentsOf: archive))
        #expect(!reader.entries.contains { $0.name.hasPrefix("Project.zpdfproj/QuickLook") })
        #expect(!reader.entries.contains { $0.name.hasPrefix("Project.zpdfproj/thumbnails/") && !$0.name.hasSuffix("/") })
        // The standard directory still travels, empty, so the copy has the shape `open` expects.
        #expect(reader.entry(named: "Project.zpdfproj/thumbnails/") != nil)
        #expect(written.contains(ProjectPackageLayout.database))
    }

    // MARK: - S-120

    /// A saved, closed project with one added drawing and one stored revision.
    static func multiDrawingProject(_ label: String) async throws -> (workspace: TestSupport.Workspace, added: String, revision: String) {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        let second = try TestSupport.makeSourcePDF(in: workspace.root.appendingPathComponent("second", isDirectory: true), kind: .rectangle)
        let addedID = try await package.addDocument(originalPDF: second, displayName: "Second")
        let primary = try await TestSupport.documentIdentifier(of: package)
        let revision = try await package.addRevision(pdf: second, documentId: primary, label: "Rev B", pageCount: 1)
        _ = try await package.save()
        try await package.close()
        return (workspace, ProjectPackageLayout.addedDocumentPath(id: addedID), revision.relativePath)
    }

    /// Replaces a read-only package member with other bytes, as an editor outside Zenit PDF would.
    static func tamper(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        var bytes = try Data(contentsOf: url)
        bytes.append(Data("% swapped outside Zenit PDF\n".utf8))
        try bytes.write(to: url)
    }

    @Test("S-120: a clean multi-drawing project still opens read-write, twice")
    func cleanSetOpens() async throws {
        let project = try await Self.multiDrawingProject("Iter2CleanSet")
        defer { try? FileManager.default.removeItem(at: project.workspace.root) }
        for _ in 0..<2 {
            guard case .opened(let package) = try await ProjectPackage.open(at: project.workspace.packageURL) else {
                Issue.record("a clean project must open"); return
            }
            #expect(await package.integrityVerdict.isVerified)
            _ = try await package.save()
            try await package.close()
        }
    }

    /// Old output: `.opened` with a verified verdict — only the primary pair was compared.
    @Test("S-120: an added drawing swapped outside Zenit PDF is refused on a read-write open")
    func tamperedAddedDrawingRefused() async throws {
        let project = try await Self.multiDrawingProject("Iter2TamperAdded")
        defer { try? FileManager.default.removeItem(at: project.workspace.root) }
        try Self.tamper(project.workspace.packageURL.member(project.added))
        do {
            _ = try await ProjectPackage.open(at: project.workspace.packageURL)
            Issue.record("the swapped drawing was opened read-write")
        } catch let ZPDFPersistenceError.projectModifiedOutsideZenit(detail) {
            #expect(detail.contains(project.added), "\(detail)")
        }
        // The escape hatch still opens, and says what it found.
        let readOnly = try await ProjectPackage.open(at: project.workspace.packageURL, resolving: .openReadOnly)
        let verdict = await readOnly.integrityVerdict
        #expect(verdict.outcome == .modifiedOutsideZenitPDF)
        #expect(verdict.mismatchedMembers == [project.added])
        try await readOnly.close()
    }

    /// Old output: `.opened` with a verified verdict.
    @Test("S-120: a stored revision swapped outside Zenit PDF is refused on a read-write open")
    func tamperedRevisionRefused() async throws {
        let project = try await Self.multiDrawingProject("Iter2TamperRevision")
        defer { try? FileManager.default.removeItem(at: project.workspace.root) }
        try Self.tamper(project.workspace.packageURL.member(project.revision))
        await #expect(throws: ZPDFPersistenceError.self) {
            _ = try await ProjectPackage.open(at: project.workspace.packageURL)
        }
        let readOnly = try await ProjectPackage.open(at: project.workspace.packageURL, resolving: .openReadOnly)
        #expect(await readOnly.integrityVerdict.mismatchedMembers == [project.revision])
        try await readOnly.close()
    }

    @Test("S-120: a symbolic link in a drawing's place counts as modified; a missing drawing is left to the load path")
    func linkRefusedMissingTolerated() async throws {
        let project = try await Self.multiDrawingProject("Iter2LinkSet")
        defer { try? FileManager.default.removeItem(at: project.workspace.root) }
        let added = project.workspace.packageURL.member(project.added)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: added.path)
        let elsewhere = project.workspace.root.appendingPathComponent("elsewhere.pdf")
        try FileManager.default.moveItem(at: added, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: added, withDestinationURL: elsewhere)
        await #expect(throws: ZPDFPersistenceError.self) {
            _ = try await ProjectPackage.open(at: project.workspace.packageURL)
        }
        try FileManager.default.removeItem(at: added)
        guard case .opened(let package) = try await ProjectPackage.open(at: project.workspace.packageURL) else {
            Issue.record("a project missing an added drawing still opens, as before"); return
        }
        try await package.close()
    }

    // MARK: - S-123

    /// The directory that holds item-replacement directories for `url`, found by making one.
    static func itemReplacementRoot(for url: URL) throws -> URL {
        let probe = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        return probe.deletingLastPathComponent()
    }

    /// How many entries a directory holds, from its link count (APFS: 2 + entries). A
    /// sandboxed test process may `stat` the item-replacement root but not list it — the
    /// listing the R-199 test counts with comes back empty there.
    static func entryCount(of directory: URL) -> Int {
        var status = stat()
        guard lstat(directory.path, &status) == 0 else { return -1 }
        return Int(status.st_nlink) - 2
    }

    /// Old output: one more empty `NSIRD_…` directory after every such open — the scratch copy
    /// was removed, its per-open parent was not — so 40 opens grew the root by 40.
    @Test("S-123: a failed read-only open of an older-schema project leaves no staging directory behind")
    func failedReadOnlyOpenLeavesNoStaging() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter2ReadOnlyFail")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let created = try await TestSupport.createPackage(workspace)
        try await created.close()

        // A v8 database (older than the current schema, so the read-only open migrates a
        // private copy) that is structurally damaged in a way the migration never reads:
        // one page past the end that no b-tree and no free list owns. The migration of the
        // copy succeeds and the check on the copy fails — the branch that leaked.
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        try FileManager.default.removeItem(at: databaseURL)
        let queue = try DatabaseQueue(path: databaseURL.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v8-artwork-geometry")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO project (id, name, created_at, modified_at, schema_version) VALUES ('p', 'Old', 'x', 'x', 8)")
        }
        try queue.close()
        var bytes = try Data(contentsOf: databaseURL)
        let rawPageSize = Int(bytes[16]) << 8 | Int(bytes[17])
        let pageSize = rawPageSize == 1 ? 65_536 : rawPageSize
        let pageCount = bytes[28..<32].reduce(0) { $0 << 8 | Int($1) }
        #expect(bytes[24..<28] == bytes[92..<96], "the header's page count is the one SQLite trusts")
        #expect(pageCount * pageSize == bytes.count)
        let grown = pageCount + 1
        bytes.replaceSubrange(28..<32, with: [UInt8(grown >> 24 & 0xFF), UInt8(grown >> 16 & 0xFF), UInt8(grown >> 8 & 0xFF), UInt8(grown & 0xFF)])
        bytes.append(Data(count: pageSize))
        try bytes.write(to: databaseURL)

        let root = try Self.itemReplacementRoot(for: workspace.packageURL)
        let before = Self.entryCount(of: root)
        #expect(before >= 0)
        let opens = 40
        for _ in 0..<opens {
            do {
                let package = try await ProjectPackage.open(at: workspace.packageURL, resolving: .openReadOnly)
                try await package.close()
                Issue.record("the damaged database opened")
                return
            } catch let ZPDFPersistenceError.integrityCheckFailed(detail) {
                #expect(detail.contains("never used"), "\(detail)")
            }
        }
        // Other suites' saves in flight create and remove their own staging directories while
        // this runs; they move the count by a handful at most, never by `opens / 2`.
        let growth = Self.entryCount(of: root) - before
        #expect(growth < opens / 2, "the item-replacement root grew by \(growth) over \(opens) failed opens")
    }

    @Test("S-123: removing a read-only scratch removes its per-open parent, and never a shared or non-empty one")
    func scratchRemoval() throws {
        let root = try TestSupport.makeTemporaryDirectory("Iter2Scratch")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("per-open", isDirectory: true)
        let scratch = parent.appendingPathComponent("zpdf-readonly-x", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data([1]).write(to: scratch.appendingPathComponent(ProjectPackageLayout.database))
        ProjectPackage.removeReadOnlyScratch(scratch)
        #expect(!FileManager.default.fileExists(atPath: parent.path))

        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let other = shared.appendingPathComponent("someone-else")
        let second = shared.appendingPathComponent("zpdf-readonly-y", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data([1]).write(to: other)
        ProjectPackage.removeReadOnlyScratch(second)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: other.path), "a parent that holds anything else stays")
    }
}
