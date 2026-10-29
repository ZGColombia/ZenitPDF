import Foundation
import SQLite3
import Testing
import ZPDFPersistence
import ZenitCLICore

/// Iteration 5: `zenit verify` refuses every project the application refuses, because both
/// call one refusal rule (V-094).
@Suite("zenit CLI — iteration 5", .serialized)
struct Iter5CLITests {

    private typealias E2E = ZenitCLIEndToEndTests

    /// A saved project that carries crash evidence (an autosave left behind) and whose database
    /// another tool edited with foreign keys off: its pages are gone, its markups are not.
    ///
    /// Old output: `isSound == true`, and `zenit verify` printed "ok: CLI Fixture.zpdfproj opens;
    /// the last session did not close cleanly" with status 0 — its own copy of the refusal rule
    /// never counted foreign-key violations — while the application's read-write open refused
    /// the same project with "6 foreign-key violation(s)".
    @Test("V-094: verify refuses a project with crash evidence and foreign-key violations, as the open does")
    func verifyRefusesForeignKeyViolationsLikeTheOpen() async throws {
        let saved = try await E2E.makeSaved()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let databaseURL = saved.package.appendingPathComponent(ProjectPackageLayout.database)
        try FileManager.default.copyItem(
            at: databaseURL, to: saved.package.appendingPathComponent(ProjectPackageLayout.autosaveDatabase)
        )
        var database: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        let deleted = sqlite3_exec(database, "PRAGMA foreign_keys = OFF; DELETE FROM page;", nil, nil, nil)
        sqlite3_close(database)
        try #require(deleted == SQLITE_OK)

        let verification = try await ProjectReader.verify(saved.package)
        #expect(!verification.closedCleanly)
        #expect(verification.integrity.outcome == .damaged, "precondition: damage the recovery flow would accept")
        #expect(verification.integrity.refusal(carriesCrashEvidence: true) == nil)
        // Hand-derived from the fixture's one page and what hangs off it: three markups, the one
        // scale calibrated on it (a scale_definition row and the page_scale row that names it)
        // and its place in the set (a page_set_entry row) — 3 + 1 + 1 + 1 = 6.
        #expect(verification.foreignKeyViolations == 6)
        #expect(!verification.isSound)
        #expect(verification.problems.contains("integrity: 6 foreign-key violation(s)"), "\(verification.problems)")

        let tool = try E2E.productsDirectory().appendingPathComponent("zenit")
        let (status, output) = try E2E.run(tool, ["verify", saved.package.path])
        #expect(status == 1)
        #expect(!output.contains("ok:"))

        // The application refuses the same project, with the same sentence.
        await #expect(throws: ZPDFPersistenceError.foreignKeyRefusal(violationCount: 6)!) {
            _ = try await ProjectPackage.open(at: saved.package, resolving: .recover)
        }
    }

    @Test("V-094: a verified project closed cleanly is not walked for foreign keys, by either path")
    func cleanProjectIsNotWalked() async throws {
        let saved = try await E2E.makeSaved()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let verification = try await ProjectReader.verify(saved.package)
        #expect(verification.closedCleanly)
        #expect(verification.integrity.needsFullCheck(carriesCrashEvidence: false) == false)
        #expect(verification.foreignKeyViolations == 0)
        #expect(verification.isSound, "\(verification.problems)")
    }
}
