import CryptoKit
import Foundation
import GRDB
import Testing
import ZPDFPersistence
import ZPDFTestingSupport

struct PackageLifecycleTests {

    private func sha256(_ url: URL) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: url))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test("A created package has the layout spec 6.3 describes")
    func createProducesTheSpecifiedLayout() async throws {
        let workspace = try TestSupport.makeWorkspace("Create")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)

        for member in [ProjectPackageLayout.manifest, ProjectPackageLayout.database,
                       ProjectPackageLayout.originalPDF, ProjectPackageLayout.workingPDF,
                       ProjectPackageLayout.integrity] {
            #expect(FileManager.default.fileExists(atPath: workspace.packageURL.member(member).path),
                    "missing \(member)")
        }
        for directory in ProjectPackageLayout.directories {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: workspace.packageURL.member(directory).path, isDirectory: &isDirectory
            )
            #expect(exists && isDirectory.boolValue, "missing directory \(directory)")
        }
        try await package.close()
    }

    @Test("The original PDF is byte-identical to the source and read-only")
    func originalIsPreservedVerbatim() async throws {
        let workspace = try TestSupport.makeWorkspace("Original")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let sourceHash = try sha256(workspace.sourcePDF)
        let package = try await TestSupport.createPackage(workspace)

        let originalURL = workspace.packageURL.member(ProjectPackageLayout.originalPDF)
        #expect(try sha256(originalURL) == sourceHash)
        let permissions = try FileManager.default.attributesOfItem(atPath: originalURL.path)[.posixPermissions]
        #expect((permissions as? NSNumber)?.intValue == 0o444)
        #expect(await package.manifest.originalPdfSha256 == sourceHash)
        try await package.close()
    }

    @Test("A save leaves a consistent package, a previous version, and an untouched original")
    func saveIsConsistentAndKeepsHistory() async throws {
        let workspace = try TestSupport.makeWorkspace("Save")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let originalHash = try sha256(workspace.sourcePDF)

        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let geometry = try TestSupport.sampleGeometry()
        try await package.write { db in
            for index in 0..<10 {
                try MarkupRecord(
                    id: "m\(index)", documentId: documentId, pageId: pageId,
                    type: "count", subject: "Outlet \(index)",
                    geometryBlob: geometry, styleBlob: Data([1]),
                    createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
                ).insert(db)
            }
        }
        #expect(await package.changeCount > 0)

        let receipt = try await package.save()
        #expect(await package.changeCount == 0, "a save is the definition of no unsaved changes")
        #expect(receipt.integrity.generation == 2)

        let verification = try ProjectPackage.verifyIntegrity(at: workspace.packageURL)
        #expect(verification.isFullyConsistent)
        #expect(verification.integrity.originalPdfSha256 == originalHash)
        #expect(try sha256(workspace.packageURL.member(ProjectPackageLayout.originalPDF)) == originalHash)

        // The saved version is a complete, verifiable package of its own. The receipt names
        // it only because it exists (CR-82).
        let latestURL = try #require(receipt.latestVersionURL)
        #expect(FileManager.default.fileExists(atPath: latestURL.path))
        let latestVerification = try ProjectPackage.verifyIntegrity(at: latestURL)
        #expect(latestVerification.isFullyConsistent)
        #expect(try TestSupport.markupCount(inPackageAt: latestURL) == 10)
        #expect(try TestSupport.markupCount(inPackageAt: workspace.packageURL) == 10)
        // There has only been one save, so there is nothing to go back to yet.
        #expect(receipt.previousVersionURL == nil)

        try await package.close()
    }

    @Test("Two saves in a row keep exactly one previous version")
    func repeatedSavesRotateOneBackup() async throws {
        let workspace = try TestSupport.makeWorkspace("SaveTwice")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let geometry = try TestSupport.sampleGeometry()

        var lastReceipt: ProjectPackage.SaveReceipt?
        for generation in 0..<3 {
            try await package.write { db in
                try MarkupRecord(
                    id: "gen\(generation)", documentId: documentId, pageId: pageId,
                    type: "count", subject: "Generation \(generation)",
                    geometryBlob: geometry, styleBlob: Data([1]),
                    createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
                ).insert(db)
            }
            lastReceipt = try await package.save()
        }
        #expect(try TestSupport.markupCount(inPackageAt: workspace.packageURL) == 3)

        let receipt = try #require(lastReceipt)
        let latestURL = try #require(receipt.latestVersionURL)
        #expect(try TestSupport.markupCount(inPackageAt: latestURL) == 3)
        let previousURL = try #require(receipt.previousVersionURL)
        #expect(try TestSupport.markupCount(inPackageAt: previousURL) == 2)
        #expect(try ProjectPackage.verifyIntegrity(at: previousURL).isFullyConsistent)

        // Exactly two slots, and no temporary or discard leftovers.
        let versionSlots = try FileManager.default
            .contentsOfDirectory(atPath: package.versionsRootURL.path).sorted()
        #expect(versionSlots == ["latest", "previous"], "version slots: \(versionSlots)")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
        #expect(!siblings.contains { $0.contains(".save-") || $0.contains(".discard-") },
                "leftovers: \(siblings)")
        try await package.close()
    }

    @Test("A save is refused when the domain model is invalid, and writes nothing")
    func invalidModelBlocksTheSave() async throws {
        let workspace = try TestSupport.makeWorkspace("Validate")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        try await package.save()
        let generationBefore = await package.integrity?.generation

        // A page rotated 47 degrees is not something a PDF can express.
        let documentId = try await TestSupport.documentIdentifier(of: package)
        try await package.write { db in
            try PageRecord(
                id: "bad", documentId: documentId, pageIndex: 7,
                mediaX: 0, mediaY: 0, mediaWidth: 100, mediaHeight: 100,
                cropX: 0, cropY: 0, cropWidth: 100, cropHeight: 100,
                rotation: 47
            ).insert(db)
        }
        // The exact refusal, not merely "some error": the pipeline must stop at
        // validation and name the page it objected to.
        do {
            _ = try await package.save()
            Issue.record("the save should have been refused")
        } catch let error as ZPDFPersistenceError {
            guard case let .saveValidationFailed(issues) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(issues.contains { $0.code == "rotation-not-quarter-turn" })
        }
        #expect(await package.integrity?.generation == generationBefore)
        #expect(try ProjectPackage.verifyIntegrity(at: workspace.packageURL).isFullyConsistent)
        try await package.close()
    }

    @Test("A package opened read-only refuses every write")
    func readOnlyPackageRefusesWrites() async throws {
        let workspace = try TestSupport.makeWorkspace("PackageReadOnly")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        try await package.save()
        try await package.close()

        let readOnly = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .openReadOnly
        )
        #expect(readOnly.accessMode == .readOnly)
        await #expect(throws: ZPDFPersistenceError.writeOnReadOnlyPackage) {
            try await readOnly.write { db in try db.execute(sql: "DELETE FROM project") }
        }
        await #expect(throws: ZPDFPersistenceError.writeOnReadOnlyPackage) { try await readOnly.save() }
        await #expect(throws: ZPDFPersistenceError.writeOnReadOnlyPackage) { _ = try await readOnly.writeAutosave() }
        // Read-only opens leave no trace at all.
        #expect(!FileManager.default.fileExists(
            atPath: workspace.packageURL.member(ProjectPackageLayout.crashMarker).path
        ))
        try await readOnly.close()
    }

    @Test("Opening something that is not a package is a typed error, not a crash")
    func malformedPackagesAreRefused() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("Malformed")
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("Nope.zpdfproj")
        do {
            _ = try await ProjectPackage.open(at: missing)
            Issue.record("opening a package that is not there should fail")
        } catch let error as ZPDFPersistenceError {
            #expect(error == .packageNotFound(path: missing.path))
        }

        let file = directory.appendingPathComponent("NotAPackage.zpdfproj")
        try Data("hello".utf8).write(to: file)
        await #expect(throws: ZPDFPersistenceError.packageNotADirectory(path: file.path)) {
            _ = try await ProjectPackage.open(at: file)
        }

        let empty = directory.appendingPathComponent("Empty.zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await #expect(throws: ZPDFPersistenceError.packageMemberMissing(
            relativePath: ProjectPackageLayout.manifest
        )) {
            _ = try await ProjectPackage.open(at: empty, resolving: .discard)
        }
    }

    @Test("Creating over an existing item is refused before anything is written")
    func createRefusesToOverwrite() async throws {
        let workspace = try TestSupport.makeWorkspace("CreateTwice")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        try await package.close()

        await #expect(throws: ZPDFPersistenceError.packageAlreadyExists(path: workspace.packageURL.path)) {
            _ = try await TestSupport.createPackage(workspace)
        }
    }

    @Test("addDocument copies the drawing in read-only, inserts its row, and survives a save")
    func addDocumentRecordsASecondDrawing() async throws {
        let workspace = try TestSupport.makeWorkspace("AddDocument")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)

        let second = try TestSupport.makeSourcePDF(
            in: workspace.root.appendingPathComponent("second", isDirectory: true),
            kind: .singleLine
        )
        let secondHash = try sha256(second)
        let changeCountBefore = await package.changeCount

        let documentId = try await package.addDocument(originalPDF: second, displayName: "Second")

        // The copy is inside the package, byte-identical, and evidence: read-only.
        let relativePath = ProjectPackageLayout.addedDocumentPath(id: documentId)
        let copyURL = workspace.packageURL.member(relativePath)
        #expect(try sha256(copyURL) == secondHash)
        let permissions = try FileManager.default.attributesOfItem(atPath: copyURL.path)[.posixPermissions]
        #expect((permissions as? NSNumber)?.intValue == 0o444)
        #expect(await package.changeCount == changeCountBefore + 1, "recording a document is an edit")

        // The row is real and complete.
        let row = try await package.read { db in
            try DocumentRecord.fetchOne(db, key: documentId)
        }
        let record = try #require(row)
        #expect(record.displayName == "Second")
        #expect(record.relativePath == relativePath)
        #expect(record.sha256 == secondHash)

        // The added drawing survives the save pipeline and a reopen.
        _ = try await package.save()
        try await package.close()
        let reopened = try await ProjectPackage.open(at: workspace.packageURL, resolving: .discard)
        #expect(try sha256(workspace.packageURL.member(relativePath)) == secondHash)
        let names = try await reopened.read { db in
            try DocumentRecord.fetchAll(db).map(\.displayName).sorted()
        }
        #expect(names.count == 2)
        #expect(names.contains("Second"))
        try await reopened.close()
    }

    @Test("addDocument refuses on a read-only package and on a missing source")
    func addDocumentRefusals() async throws {
        let workspace = try TestSupport.makeWorkspace("AddDocumentRefuse")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)

        // A missing source is named, and nothing lands in the package.
        let ghost = workspace.root.appendingPathComponent("ghost.pdf")
        await #expect(throws: ZPDFPersistenceError.packageNotFound(path: ghost.path)) {
            _ = try await package.addDocument(originalPDF: ghost, displayName: "Ghost")
        }
        let rowsAfterGhost = try await package.read { db in try DocumentRecord.fetchCount(db) }
        #expect(rowsAfterGhost == 1)

        _ = try await package.save()
        try await package.close()

        let readOnly = try await ProjectPackage.open(at: workspace.packageURL, resolving: .openReadOnly)
        await #expect(throws: ZPDFPersistenceError.writeOnReadOnlyPackage) {
            _ = try await readOnly.addDocument(originalPDF: workspace.sourcePDF, displayName: "Nope")
        }
        try await readOnly.close()
    }
}
