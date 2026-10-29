import CryptoKit
import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Spec 6.5. Every case here checks the same background invariant as well as its own
/// subject: `documents/original.pdf` comes out with the SHA-256 it went in with.
struct RecoveryTests {

    private func sha256(_ url: URL) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: url))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Builds a package, adds `savedMarkups`, saves, then adds `unsavedMarkups` and
    /// autosaves — the state a session is in when the power goes out.
    private func makeCrashedPackage(
        _ label: String,
        savedMarkups: Int,
        unsavedMarkups: Int,
        writeAutosave: Bool
    ) async throws -> (workspace: TestSupport.Workspace, originalHash: String) {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let geometry = try TestSupport.sampleGeometry()

        func insert(_ range: Range<Int>, prefix: String) async throws {
            try await package.write { db in
                for index in range {
                    try MarkupRecord(
                        id: "\(prefix)-\(index)", documentId: documentId, pageId: pageId,
                        type: "count", subject: "\(prefix) \(index)",
                        geometryBlob: geometry, styleBlob: Data([1]),
                        createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
                    ).insert(db)
                }
            }
        }

        try await insert(0..<savedMarkups, prefix: "saved")
        try await package.save()
        try await insert(0..<unsavedMarkups, prefix: "unsaved")
        if writeAutosave {
            _ = try await package.writeAutosave()
        }
        // Simulate a crash: let go of the database without disarming the crash marker,
        // which is exactly the state a killed process leaves behind.
        let handle = await package.database
        try await handle.close()

        let originalHash = try sha256(workspace.packageURL.member(ProjectPackageLayout.originalPDF))
        return (workspace, originalHash)
    }

    @Test("A clean close leaves no crash marker and opens without a decision")
    func cleanCloseOpensDirectly() async throws {
        let workspace = try TestSupport.makeWorkspace("RecoveryClean")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        try await package.save()
        try await package.close()

        #expect(!FileManager.default.fileExists(
            atPath: workspace.packageURL.member(ProjectPackageLayout.crashMarker).path
        ))
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.isClean)

        switch try await ProjectPackage.open(at: workspace.packageURL) {
        case let .opened(reopened):
            #expect(reopened.accessMode == .readWrite)
            try await reopened.close()
        case .recoveryRequired, .openElsewhere:
            Issue.record("a cleanly closed package should not ask for a recovery decision")
        }
    }

    @Test("A crashed session is detected and open() asks for a decision")
    func crashIsDetected() async throws {
        let (workspace, _) = try await makeCrashedPackage(
            "RecoveryDetect", savedMarkups: 5, unsavedMarkups: 3, writeAutosave: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.crashMarkerPresent)
        #expect(assessment.autosave?.passesIntegrityCheck == true)
        #expect(assessment.lastGoodManifest != nil)
        #expect(assessment.recommended == .recover)
        #expect(!assessment.isClean)

        switch try await ProjectPackage.open(at: workspace.packageURL) {
        case .opened:
            Issue.record("a crashed package must not open without a decision")
        case let .recoveryRequired(reported):
            #expect(reported.crashMarkerPresent)
        case .openElsewhere:
            Issue.record("a crash in this very process is not a session elsewhere")
        }
    }

    @Test("Recover keeps every committed edit, saved or not")
    func recoverKeepsEverything() async throws {
        let (workspace, originalHash) = try await makeCrashedPackage(
            "RecoveryRecover", savedMarkups: 5, unsavedMarkups: 3, writeAutosave: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let recovered = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .recover
        )
        let count = try await recovered.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1
        }
        #expect(count == 8,
                "recover should return the 5 saved markups plus the 3 that were only committed")
        #expect(try sha256(workspace.packageURL.member(ProjectPackageLayout.originalPDF)) == originalHash)

        // The recovered session arms its own crash marker, and clears it on a clean
        // close — so the next launch sees a clean package rather than the old crash.
        #expect(FileManager.default.fileExists(
            atPath: workspace.packageURL.member(ProjectPackageLayout.crashMarker).path
        ))
        try await recovered.close()
        #expect(try await ProjectPackage.assessRecovery(at: workspace.packageURL).isClean)
    }

    @Test("Discard throws the unsaved work away and returns the last saved state")
    func discardReturnsTheLastSavedState() async throws {
        let (workspace, originalHash) = try await makeCrashedPackage(
            "RecoveryDiscard", savedMarkups: 5, unsavedMarkups: 3, writeAutosave: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let opened = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .discard
        )
        let count = try await opened.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1
        }
        #expect(count == 5, "discard should roll the database back to the last save")
        #expect(!FileManager.default.fileExists(
            atPath: workspace.packageURL.member(ProjectPackageLayout.autosaveDatabase).path
        ))
        // Rolling back to the last save makes the package match its own record again.
        #expect(try ProjectPackage.verifyIntegrity(at: workspace.packageURL).isFullyConsistent)
        #expect(try sha256(workspace.packageURL.member(ProjectPackageLayout.originalPDF)) == originalHash)
        try await opened.close()
    }

    @Test("Open Read-Only shows what was committed and changes nothing on disk")
    func openReadOnlyLeavesEverythingAlone() async throws {
        let (workspace, originalHash) = try await makeCrashedPackage(
            "RecoveryReadOnly", savedMarkups: 5, unsavedMarkups: 3, writeAutosave: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let before = try snapshotPackageBytes(workspace.packageURL)
        let readOnly = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .openReadOnly
        )
        let count = try await readOnly.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1
        }
        #expect(count == 8, "read-only shows the database as it is, including unsaved edits")
        try await readOnly.close()

        let after = try snapshotPackageBytes(workspace.packageURL)
        #expect(after == before, "read-only opened the package and still modified it")
        #expect(try sha256(workspace.packageURL.member(ProjectPackageLayout.originalPDF)) == originalHash)

        // The evidence is still there, so the user can still choose Recover afterwards.
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.crashMarkerPresent)
        #expect(assessment.autosave != nil)
    }

    @Test("A damaged live database falls back to the autosave")
    func damagedLiveDatabaseFallsBackToTheAutosave() async throws {
        let (workspace, originalHash) = try await makeCrashedPackage(
            "RecoveryFallback", savedMarkups: 5, unsavedMarkups: 3, writeAutosave: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        try scribble(over: workspace.packageURL.member(ProjectPackageLayout.database))
        #expect(!ProjectPackage.databaseIsHealthyForTesting(
            at: workspace.packageURL.member(ProjectPackageLayout.database)
        ))

        let recovered = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .recover
        )
        let count = try await recovered.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1
        }
        #expect(count == 8, "the autosave should have supplied all eight markups")
        // What it replaced was kept, not deleted.
        let kept = TestSupport.recoveryEntries(in: workspace.packageURL)
        #expect(kept.contains { $0.hasPrefix("superseded-") })
        #expect(try sha256(workspace.packageURL.member(ProjectPackageLayout.originalPDF)) == originalHash)
        try await recovered.close()
    }

    @Test("Recover is refused when nothing on disk passes an integrity check")
    func recoverRefusesWhenEverySourceIsDamaged() async throws {
        let (workspace, originalHash) = try await makeCrashedPackage(
            "RecoveryAllCorrupt", savedMarkups: 5, unsavedMarkups: 3, writeAutosave: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        try scribble(over: workspace.packageURL.member(ProjectPackageLayout.database))
        try scribble(over: workspace.packageURL.member(ProjectPackageLayout.autosaveDatabase))
        let versions = ProjectPackage.versionsRootURL(forPackageAt: workspace.packageURL)
        try scribble(over: versions
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
            .member(ProjectPackageLayout.database))

        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.autosave?.passesIntegrityCheck == false)
        do {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment(), resolving: .recover
            )
            Issue.record("recovering from nothing but damaged sources should be refused")
        } catch let error as ZPDFPersistenceError {
            guard case .recoveryFailed = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        // A refusal must not have damaged the one thing that was still intact.
        #expect(try sha256(workspace.packageURL.member(ProjectPackageLayout.originalPDF)) == originalHash)
    }

    /// Overwrites a stretch of a database's page data, past the header, so the file is
    /// still openable and `quick_check` still has something to object to.
    private func scribble(over url: URL) throws {
        var bytes = try Data(contentsOf: url)
        guard bytes.count > 8_192 else { return }
        for offset in 4_096..<min(8_192, bytes.count) { bytes[offset] = 0xAA }
        try bytes.write(to: url)
    }

    @Test("The journal records how far an interrupted save got")
    func journalRecordsTheInterruptedPhase() async throws {
        let workspace = try TestSupport.makeWorkspace("RecoveryJournal")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)

        // Stop the pipeline dead at a named checkpoint, without killing the process.
        struct Stop: Error {}
        await #expect(throws: (any Error).self) {
            try await package.save(hooks: SaveHooks { checkpoint in
                if checkpoint == .didHash { throw Stop() }
            })
        }
        let handle = await package.database
        try await handle.close()

        // The journal still says how far the pipeline got before it was refused…
        let journal = RecoveryJournal.read(
            from: workspace.packageURL.member(ProjectPackageLayout.recoveryJournal)
        )
        #expect(journal.lastSave?.checkpoint == .didHash)
        // …but a save that *threw* was abandoned, not cut off (BH-190): it closed its own
        // entry, and the next open must not read it as a session that died mid-save.
        // Old output: interruptedSave = didHash, so the recovery sheet came up for a save
        // the user had been told was refused.
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.interruptedSave == nil)
        #expect(journal.saveInFlight == nil)
    }

    /// Every file in the package, by content hash.
    ///
    /// `-shm` is excluded, and only `-shm`. It is SQLite's shared-memory index — scratch
    /// that any reader rebuilds and touches, including a strictly read-only one. Nothing
    /// a user could lose lives there. Every other file, `-wal` included, is compared.
    private func snapshotPackageBytes(_ url: URL) throws -> [String: String] {
        var snapshot: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        while let relative = enumerator?.nextObject() as? String {
            guard !relative.hasSuffix("-shm") else { continue }
            let item = url.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            snapshot[relative] = try sha256(item)
        }
        return snapshot
    }

    // MARK: - The save-then-quit marker race

    /// A gate the save hook parks on, so the test controls exactly when the pipeline
    /// resumes — the deterministic form of "⌘S then an immediate ⌘Q".
    private actor SaveGate {
        private var reached = false
        private var released = false
        private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markReached() {
            reached = true
            reachedWaiters.forEach { $0.resume() }
            reachedWaiters = []
        }

        func waitUntilReached() async {
            if reached { return }
            await withCheckedContinuation { reachedWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters = []
        }

        func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    @Test("A close during a save waits for it: the journal ends session-closed, the marker is down")
    func closeDuringSaveLandsAfterTheSave() async throws {
        let workspace = try TestSupport.makeWorkspace("MarkerRace")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)

        // Park the pipeline just before the atomic replace — the widest, worst window:
        // the close's session-closed line would land in the directory the swap retires.
        let gate = SaveGate()
        let hooks = SaveHooks { checkpoint in
            if checkpoint == .willAtomicReplace {
                await gate.markReached()
                await gate.waitForRelease()
            }
        }
        let save = Task { try await package.save(hooks: hooks) }
        await gate.waitUntilReached()

        // The quit arrives mid-save. It must queue behind the pipeline, not interleave.
        let close = Task { try await package.close() }
        // Give the close every chance to run first if it wrongly could.
        try await Task.sleep(nanoseconds: 200_000_000)
        await gate.release()
        _ = try await save.value
        try await close.value

        let marker = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "a save-then-quit left the crash marker armed — the false recovery prompt")
        let journal = RecoveryJournal.read(
            from: workspace.packageURL.member(ProjectPackageLayout.recoveryJournal)
        )
        #expect(journal.entries.last?.kind == .sessionClosed,
                "the journal's last word must be session-closed, got \(String(describing: journal.entries.last?.kind))")
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.isClean, "a cleanly-quit project must reopen without a prompt")
    }
}
