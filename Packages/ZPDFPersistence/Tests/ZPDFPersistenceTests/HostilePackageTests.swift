import Foundation
import GRDB
import Testing
import ZPDFPersistence
import ZPDFTestingSupport

/// S17 security review — what a `.zpdfproj` that came from someone else can do.
///
/// A project package is a *document*. Users mail them, drop them in shared folders and
/// download them from tender portals, exactly as they do PDFs. The difference is that a
/// PDF is parsed by a parser we distrust on purpose, while `project.sqlite` is handed to
/// SQLite and then believed. These tests establish what the open path actually does with
/// a package built by an attacker rather than by us, and pin the behaviour so it cannot
/// regress silently.
///
/// The bar is deliberately modest and honest: **a hostile package must be refused or
/// survived, never crash the process and never reach outside its own directory.** Where
/// a check does not exist, the test says so in its name rather than pretending.
struct HostilePackageTests {

    // MARK: - Support

    /// A real, valid package, then handed to the attacker.
    private func makeVictimPackage(_ label: String) async throws -> TestSupport.Workspace {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        try await TestSupport.insertPage(into: package)
        _ = try await package.save()
        try await package.close()
        return workspace
    }

    private func rewriteDatabase(
        at workspace: TestSupport.Workspace,
        _ body: (Database) throws -> Void
    ) throws {
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        // Any WAL/SHM left beside the file would shadow the edits made here.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            try? FileManager.default.removeItem(at: sidecar)
        }
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in try body(db) }
        try queue.close()
    }

    // MARK: - Bytes that are not a database

    @Test("project.sqlite that is not a database at all is refused, not crashed on")
    func garbageDatabaseIsRefused() async throws {
        let workspace = try await makeVictimPackage("HostileGarbage")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
        // A plausible-looking header followed by noise: the shape a fuzzer produces.
        var bytes = Array("SQLite format 3\0".utf8)
        bytes.append(contentsOf: (0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try Data(bytes).write(to: databaseURL)

        await #expect(throws: (any Error).self) {
            _ = try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment())
        }
    }

    @Test("A structurally corrupted page is caught by the integrity check on open")
    func corruptedPageIsCaught() async throws {
        let workspace = try await makeVictimPackage("HostileCorrupt")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
        var bytes = [UInt8](try Data(contentsOf: databaseURL))
        #expect(bytes.count > 12_000, "the victim database is smaller than expected")
        // Scribble over the interior of page 3 and onwards, past the header SQLite reads
        // first, so the damage is only visible to a real structural check.
        for index in 8_192..<min(bytes.count, 12_288) {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 131 &+ 17)
        }
        try Data(bytes).write(to: databaseURL)

        await #expect(throws: (any Error).self) {
            _ = try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment())
        }
    }

    // MARK: - A well-formed database with an attacker's schema

    /// S17-09, closed. `PRAGMA integrity_check` answers "are the b-trees intact", not
    /// "did we write this schema", so before this fix an attacker-authored trigger
    /// survived the open and fired inside our transactions, on our thread, against the
    /// user's takeoff rows. It is now refused by ``ProjectSchemaInventory``, which
    /// compares `sqlite_master` against exactly what the migrations create.
    ///
    /// `HostileProjectPackageTests` carries the full matrix; this one stays because it
    /// is the original reproduction, written against the raw SQLite the finding used.
    @Test("An attacker's trigger in a hostile package is refused on open")
    func hostileTriggerIsRefused() async throws {
        let workspace = try await makeVictimPackage("HostileTrigger")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        try rewriteDatabase(at: workspace) { db in
            try db.execute(sql: """
                CREATE TRIGGER zpdf_attacker_trigger AFTER INSERT ON markup
                BEGIN
                    UPDATE markup SET label = 'owned' WHERE id = new.id;
                END
                """)
        }
        // A competent attacker leaves the package self-consistent, so that the schema
        // guard is what has to catch this rather than the hash check.
        try HostileProjectPackage.refreshDatabaseHash(inPackageAt: workspace.packageURL)

        await #expect(throws: ZPDFPersistenceError.foreignSchemaObject(
            objectType: "trigger", name: "zpdf_attacker_trigger"
        )) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment()
            )
        }
        // Refused, and refused without touching the file: the trigger is still there,
        // which is what lets the user take the package to whoever sent it.
        let names = try HostileProjectPackage.schemaObjectNames(inPackageAt: workspace.packageURL)
        #expect(names.contains("trigger|zpdf_attacker_trigger"),
                "a refusal must leave the evidence on disk exactly as it was")
    }

    /// What SQLite is configured to believe about a schema it did not write.
    ///
    /// Recorded rather than asserted-as-good: `trusted_schema` defaults to on, which is
    /// SQLite's own "this database is one of ours" setting. The recommendation for a
    /// database that arrived from outside is `PRAGMA trusted_schema = OFF` plus
    /// `SQLITE_DBCONFIG_DEFENSIVE`. This test prints the real values so the security
    /// report quotes measurements rather than assumptions.
    @Test("Recorded: the SQLite trust settings a hostile package is opened under")
    func recordSQLiteTrustSettings() async throws {
        let workspace = try await makeVictimPackage("HostileSettings")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let outcome = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment()
        )
        guard case let .opened(package) = outcome else {
            Issue.record("the victim package did not open")
            return
        }
        let report = try await package.read { db -> String in
            let trusted = try Int.fetchOne(db, sql: "PRAGMA trusted_schema") ?? -1
            let recursive = try Int.fetchOne(db, sql: "PRAGMA recursive_triggers") ?? -1
            let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1
            let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "?"
            let loadExtensionAvailable: Bool
            do {
                _ = try Int.fetchOne(db, sql: "SELECT load_extension('/nonexistent') IS NULL")
                loadExtensionAvailable = true
            } catch {
                loadExtensionAvailable = false
            }
            let fts3TokenizerAvailable: Bool
            do {
                _ = try Data.fetchOne(db, sql: "SELECT fts3_tokenizer('simple')")
                fts3TokenizerAvailable = true
            } catch {
                fts3TokenizerAvailable = false
            }
            return """
                sqlite_version=\(version) trusted_schema=\(trusted) recursive_triggers=\(recursive) \
                foreign_keys=\(foreignKeys) load_extension_callable=\(loadExtensionAvailable) \
                fts3_tokenizer_callable=\(fts3TokenizerAvailable)
                """
        }
        print("S17 SQLite trust settings: \(report)")
        // The three that must hold whatever else is true.
        #expect(report.contains("recursive_triggers=0"))
        #expect(report.contains("load_extension_callable=false"))
        #expect(report.contains("trusted_schema=0"),
                "the project database is opened from a document; its schema is not ours to trust")
        try await package.close()
    }

    // MARK: - The manifest

    /// S17-08, closed. `coordinateSystem` documents itself as existing "so a future
    /// coordinate convention is a data change rather than a silent reinterpretation of
    /// old files", and until this fix nothing compared it: a package could claim any
    /// convention and have every coordinate in it read as bottom-left points anyway.
    /// For a takeoff application that is a wrong quantity on an invoice which looks
    /// exactly like a right one, so an unknown value is now a refusal rather than a
    /// guess.
    @Test("A manifest claiming an unknown coordinate system is refused")
    func unknownCoordinateSystemIsRefused() async throws {
        let workspace = try await makeVictimPackage("HostileManifest")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let manifestURL = workspace.packageURL.member(ProjectPackageLayout.manifest)
        var manifest = try ProjectManifest.read(from: manifestURL)
        manifest.coordinateSystem = "ATTACKER_CHOSEN_SPACE"
        try manifest.encoded().write(to: manifestURL)
        // Keep the recorded manifest hash honest, so the coordinate check is what fires.
        try HostileProjectPackage.mutateJSONObject(
            at: workspace.packageURL.member(ProjectPackageLayout.integrity),
            relativePath: ProjectPackageLayout.integrity
        ) { record in
            record["manifestSha256"] = FileDurability.sha256(of: (try? manifest.encoded()) ?? Data())
        }

        await #expect(throws: ZPDFPersistenceError.unsupportedCoordinateSystem(
            found: "ATTACKER_CHOSEN_SPACE", supported: ProjectManifest.pdfPointsBottomLeft
        )) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment()
            )
        }
        // The one value this build implements still opens.
        #expect(throws: Never.self) {
            var honest = manifest
            honest.coordinateSystem = ProjectManifest.pdfPointsBottomLeft
            try honest.assertReadable()
        }
    }

    /// S17-07, closed. The integrity record is the package's own claim about its
    /// contents, it was read on the open path, and it was never checked — so a package
    /// could state any hashes it liked and be believed. It is now verified before SQLite
    /// is handed the file, and a mismatch is a typed refusal naming the member that did
    /// not match.
    @Test("A lying integrity record is refused on open, naming what did not match")
    func lyingIntegrityRecordIsRefusedOnOpen() async throws {
        let workspace = try await makeVictimPackage("HostileIntegrity")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let integrityURL = workspace.packageURL.member(ProjectPackageLayout.integrity)
        var record = try IntegrityRecord.read(from: integrityURL)
        record.originalPdfSha256 = String(repeating: "0", count: 64)
        try record.encoded().write(to: integrityURL)

        do {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment()
            )
            Issue.record("a package whose integrity record is fiction was opened")
        } catch let error as ZPDFPersistenceError {
            #expect(error == .projectModifiedOutsideZenit(
                detail: "documents/original.pdf does not match the hash this project records"
            ), "unexpected refusal: \(error)")
        }
        // The explicit verification agrees, and still says which member it was.
        let verification = try ProjectPackage.verifyIntegrity(at: workspace.packageURL)
        #expect(!verification.isFullyConsistent)
        #expect(!verification.originalPDFHashMatches)
        #expect(verification.databaseHashMatches,
                "the close re-records the database digest, so a package at rest matches its own record")
    }

    // MARK: - Package members

    @Test("A package missing a required member is refused before SQLite sees anything")
    func missingMemberIsRefused() async throws {
        let workspace = try await makeVictimPackage("HostileMissing")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        try FileManager.default.removeItem(
            at: workspace.packageURL.member(ProjectPackageLayout.originalPDF)
        )
        await #expect(throws: (any Error).self) {
            _ = try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment())
        }
    }

    @Test("A multi-megabyte manifest is refused before it is parsed")
    func oversizedManifestIsRefused() async throws {
        let workspace = try await makeVictimPackage("HostileBigManifest")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let manifestURL = workspace.packageURL.member(ProjectPackageLayout.manifest)
        let padding = String(repeating: "A", count: ProjectManifest.maximumByteCount + 1024)
        try Data("{\"displayName\":\"\(padding)\"}".utf8).write(to: manifestURL)

        #expect(throws: ZPDFPersistenceError.self) {
            _ = try ProjectManifest.read(from: manifestURL)
        }
    }
}
