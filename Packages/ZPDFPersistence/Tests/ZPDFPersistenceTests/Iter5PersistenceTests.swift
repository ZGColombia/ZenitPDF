import Darwin
import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// An open whose crash marker cannot be written leaves the
/// package exactly as it found it (V-088).
@Suite("Iteration 5 — persistence", .serialized)
struct Iter5PersistenceTests {

    // MARK: - V-088: the marker is armed before anything writes

    /// Old output: the second open threw `projectModifiedOutsideZenit` — the first open had
    /// opened the pool read-write (GRDB creates and drops `grdb_issue_102` on a pool open that
    /// finds no write-ahead log), then failed to arm the marker and dropped the pool without
    /// `close()`. The last connection's checkpoint folded that write into `project.sqlite`,
    /// nothing re-recorded its digest and no marker explained it, so every read-write open
    /// after that refused a cleanly closed project as tampered.
    @Test("V-088: a marker that cannot be written at open leaves project.sqlite untouched and the next open clean")
    func unwritableMarkerAtOpenLeavesTheDatabaseAlone() async throws {
        let workspace = try await Iter4PersistenceTests.closedPackage("Iter5MarkerAtOpen")
        let recoveryURL = workspace.packageURL.member(ProjectPackageLayout.recovery)
        defer {
            try? Iter4PersistenceTests.chmod(["-N", recoveryURL.path])
            try? FileManager.default.removeItem(at: workspace.root)
        }
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        let bytesBefore = try Data(contentsOf: databaseURL)
        let entriesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: workspace.packageURL.path))

        // Creating a file in `recovery/` is refused, so the marker's temporary cannot be made.
        try Iter4PersistenceTests.chmod(["+a", "everyone deny add_file", recoveryURL.path])
        await #expect(throws: (any Error).self, "an open that cannot say a session is in progress must not open") {
            _ = try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment())
        }
        #expect(try Data(contentsOf: databaseURL) == bytesBefore, "the refused open wrote to project.sqlite")
        #expect(!FileDurability.exists(markerURL))
        let entriesAfter = Set(try FileManager.default.contentsOfDirectory(atPath: workspace.packageURL.path))
        #expect(entriesAfter == entriesBefore, "the refused open left \(entriesAfter.symmetricDifference(entriesBefore))")

        // The fault clears: the project opens for editing as the clean project it is.
        try Iter4PersistenceTests.chmod(["-N", recoveryURL.path])
        switch try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment()) {
        case .opened(let package):
            #expect(await package.integrityVerdict.isVerified)
            try await package.close()
        case .recoveryRequired, .openElsewhere:
            Issue.record("a cleanly closed project whose open was refused must not carry crash evidence")
        }
    }

    /// Old output: the second open threw `projectModifiedOutsideZenit`. The recovery step had
    /// consumed the only crash evidence (the autosave), the read-write pool had written to
    /// `project.sqlite`, and the open then failed on the foreign-key check with no marker left
    /// to explain the changed bytes — the same accusation by another road.
    @Test("V-088: an open that fails after the pool wrote keeps its marker armed, so the next open offers recovery")
    func failedOpenAfterThePoolWroteKeepsCrashEvidence() async throws {
        let workspace = try await Iter4PersistenceTests.closedPackage("Iter5MarkerStandDown")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        // Crash evidence with no marker: an autosave left behind.
        try FileManager.default.copyItem(
            at: databaseURL, to: workspace.packageURL.member(ProjectPackageLayout.autosaveDatabase)
        )
        // Another tool removes the page's document with enforcement off.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try await queue.write { db in try db.execute(sql: "DELETE FROM document") }
        try queue.close()
        #expect(!FileDurability.exists(markerURL))

        await #expect(throws: (any Error).self) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment(), resolving: .recover
            )
        }
        #expect(FileDurability.exists(markerURL), "the changed database must stay explained by a marker")
        switch try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment()) {
        case .recoveryRequired(let assessment):
            #expect(assessment.crashMarkerPresent)
        case .opened(let package):
            try? await package.close()
            Issue.record("a package whose open failed after its pool wrote opened as clean")
        case .openElsewhere:
            Issue.record("this process's own marker is not a live session elsewhere")
        }
    }

    // MARK: - V-095: the durability oracle is the open path's check

    /// Old output: `isFullyConsistent == true` for a package the next read-write open refused
    /// with `projectModifiedOutsideZenit` — `verifyIntegrity` compared only the four members
    /// the record names, never the added drawings or the stored revisions (S-120).
    @Test("V-095: verifyIntegrity calls inconsistent exactly what the next open refuses")
    func verifyIntegrityAgreesWithTheOpen() async throws {
        let project = try await Iter2PersistenceTests.multiDrawingProject("Iter5Oracle")
        defer { try? FileManager.default.removeItem(at: project.workspace.root) }
        let packageURL = project.workspace.packageURL

        let clean = try ProjectPackage.verifyIntegrity(at: packageURL)
        #expect(clean.isFullyConsistent)
        #expect(clean.verdict == .verifiedVerdict)

        try Iter2PersistenceTests.tamper(packageURL.member(project.added))
        let swapped = try ProjectPackage.verifyIntegrity(at: packageURL)
        #expect(!swapped.isFullyConsistent)
        #expect(swapped.verdict.outcome == .modifiedOutsideZenitPDF)
        #expect(swapped.verdict.mismatchedMembers == [project.added])
        // The four record members still match, and each flag says so.
        #expect(swapped.manifestHashMatches && swapped.databaseHashMatches
                && swapped.originalPDFHashMatches && swapped.workingPDFHashMatches)
        // The open refuses the same package with the same verdict.
        await #expect(throws: swapped.verdict.error!) {
            _ = try await ProjectPackage.open(at: packageURL)
        }
    }

    /// Guards the stand-down: the open replaces a crashed session's marker with its own before
    /// the recovery decision, so a decision that fails must put the old marker back as it was.
    @Test("V-088: a recovery decision that fails puts the crashed session's marker back byte for byte")
    func failedRecoveryDecisionRestoresThePriorMarker() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter5MarkerRestore")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        // Created and closed, never saved: there is no saved version to discard back to.
        try await TestSupport.createPackage(workspace).close()
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        let planted = Data(#"{"appVersion":"0.9.0","openedAt":"2026-01-01T08:00:00.000Z","processIdentifier":999}"#.utf8)
        try planted.write(to: markerURL)

        await #expect(throws: ZPDFPersistenceError.self) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment(), resolving: .discard
            )
        }
        #expect(try Data(contentsOf: markerURL) == planted)
        let leftovers = TestSupport.recoveryEntries(in: workspace.packageURL).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "stranded temporaries: \(leftovers)")
    }
}
