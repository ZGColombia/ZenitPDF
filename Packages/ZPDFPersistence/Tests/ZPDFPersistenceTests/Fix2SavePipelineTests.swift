import CryptoKit
import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Bug hunt 2, persistence: the save pipeline and recovery findings. Every test
/// names the ID it pins and says in a comment what the old code produced.
struct Fix2SavePipelineTests {

    // MARK: - Support

    /// A gate the save hook parks on, so a test controls exactly when the pipeline resumes.
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

    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    private func sha256(_ url: URL) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: url))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func hooks(parkingAt checkpoint: SaveCheckpoint, on gate: SaveGate) -> SaveHooks {
        SaveHooks { reached in
            if reached == checkpoint {
                await gate.markReached()
                await gate.waitForRelease()
            }
        }
    }

    private func markupCount(_ package: ProjectPackage) async throws -> Int {
        try await package.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1 }
    }

    private func insertMarkups(
        _ range: Range<Int>, prefix: String, into package: ProjectPackage, pageId: String, documentId: String
    ) async throws {
        let geometry = try TestSupport.sampleGeometry()
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

    // MARK: - BH-029: a write during a save waits for the swap

    @Test("BH-029: a row written while a save is in flight survives the save")
    func writeDuringSaveLandsInTheSavedPackage() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2WriteDuringSave")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)

        // Park the pipeline after the database has been streamed into the temporary
        // package and before the swap: the widest window for a row to be lost in.
        let gate = SaveGate()
        let save = Task { try await package.save(hooks: hooks(parkingAt: .willAtomicReplace, on: gate)) }
        await gate.waitUntilReached()

        let landed = Flag()
        let write = Task {
            try await insertMarkups(0..<3, prefix: "late", into: package, pageId: pageId, documentId: documentId)
            await landed.set()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await !landed.isSet, "the write must queue behind the save, not commit into the retiring database")

        await gate.release()
        _ = try await save.value
        try await write.value

        // Old output: 0 — the rows were committed into the database the swap retired
        // and step 8 deleted, while `write` had returned success.
        #expect(try await markupCount(package) == 3)
        try await package.close()
        let reopened = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .discard
        )
        #expect(try await markupCount(reopened) == 3, "the rows must be in the package on disk")
        try await reopened.close()
    }

    @Test("BH-184: a drawing added while a save is in flight survives the save")
    func addDocumentDuringSaveSurvives() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2AddDuringSave")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)

        let gate = SaveGate()
        let save = Task { try await package.save(hooks: hooks(parkingAt: .willAtomicReplace, on: gate)) }
        await gate.waitUntilReached()
        let add = Task {
            try await package.addDocument(originalPDF: workspace.sourcePDF, displayName: "Second sheet")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()
        _ = try await save.value
        let documentId = try await add.value

        // Old output: the row and the copied PDF both vanished with the retired
        // directory while `addDocument` had returned the id.
        let row = try await package.read { db in
            try DocumentRecord.fetchOne(db, key: documentId)
        }
        #expect(row != nil)
        let copied = workspace.packageURL.member(ProjectPackageLayout.addedDocumentPath(id: documentId))
        #expect(FileManager.default.fileExists(atPath: copied.path))
        try await package.close()
    }

    // MARK: - BH-030 / BH-190: the journal's crash story is positional

    @Test("BH-030: a recovery applied once does not re-prompt on every later open")
    func appliedRecoveryDoesNotReprompt() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2Reprompt")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let environment = TestSupport.environment()
        let package = try await TestSupport.createPackage(workspace, environment: environment)
        _ = try await TestSupport.insertPage(into: package)
        try await package.save()

        // The state a process killed at `didHash` leaves: the checkpoint line is the
        // journal's last line and the crash marker is armed.
        let journalURL = workspace.packageURL.member(ProjectPackageLayout.recoveryJournal)
        var journal = RecoveryJournal.read(from: journalURL)
        journal.append(RecoveryJournalEntry(
            token: "killed-save", kind: .save, checkpoint: .didHash,
            timestamp: TestSupport.seedTimestamp, changeCount: 1
        ))
        try journal.encoded().write(to: journalURL)
        let handle = await package.database
        try await handle.close()

        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.interruptedSave?.lastCheckpoint == .didHash, "precondition: the crash is seen")

        let recovered = try await ProjectPackage.open(
            at: workspace.packageURL, environment: environment, resolving: .recover
        )
        // Edit and close without a full save: the edits are WAL-committed in place.
        _ = try await TestSupport.insertPage(into: recovered, pageIndex: 1, identifier: "page-after-recovery")
        try await recovered.close()

        // Old output: interruptedSave = didHash again — `lastSave` scanned back past the
        // recovery notes to the pre-crash line — so every later open re-prompted, and
        // `Discard` on that sheet threw the in-place edits away.
        let after = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(after.interruptedSave == nil)
        #expect(after.isClean, "a recovered, cleanly closed project must open without a sheet")
        switch try await ProjectPackage.open(at: workspace.packageURL, environment: environment) {
        case let .opened(reopened):
            let pages = try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page") }
            #expect(pages == 2, "the in-place edits after recovery must still be there")
            try await reopened.close()
        case .recoveryRequired, .openElsewhere:
            Issue.record("the recovery sheet came back for a crash that had already been dealt with")
        }
    }

    @Test("BH-190: a save refused before the swap is not reported as a crashed save")
    func refusedSaveIsNotACrash() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2RefusedSave")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let environment = TestSupport.environment()
        let package = try await TestSupport.createPackage(workspace, environment: environment)
        let pageId = try await TestSupport.insertPage(into: package)

        // A rotation that is not a quarter turn is refused by validation, step 1.
        try await package.write { db in
            try db.execute(sql: "UPDATE page SET rotation = 45 WHERE id = ?", arguments: [pageId])
        }
        await #expect(throws: (any Error).self) { try await package.save() }
        try await package.write { db in
            try db.execute(sql: "UPDATE page SET rotation = 0 WHERE id = ?", arguments: [pageId])
        }
        try await package.close()

        // Old output: `.recoveryRequired`, summary "save T… stopped at willValidate" —
        // the refused save's first checkpoint line was read as a session that died.
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.interruptedSave == nil)
        #expect(assessment.isClean)
        switch try await ProjectPackage.open(at: workspace.packageURL, environment: environment) {
        case let .opened(reopened): try await reopened.close()
        case .recoveryRequired, .openElsewhere: Issue.record("a refused save must not produce a recovery sheet")
        }
    }

    // MARK: - BH-185: a reopen failure after the swap

    @Test("BH-185: a database that cannot be reopened after the swap does not strand the handle or the record")
    func reopenFailureAfterSwapIsRecoverable() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2ReopenFailure")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let environment = TestSupport.environment()
        let package = try await TestSupport.createPackage(workspace, environment: environment)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)

        // Make the swapped-in database unopenable exactly when step 9 reopens it.
        let receipt = try await package.save(hooks: SaveHooks { checkpoint in
            if checkpoint == .didPreserveVersion {
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: databaseURL.path)
            }
        })
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: databaseURL.path)

        // The save committed, and the package says so.
        #expect(await package.manifest == receipt.manifest)
        #expect(await package.integrity == receipt.integrity)
        // Old output: every later write threw "the database handle is closed".
        try await insertMarkups(0..<2, prefix: "after", into: package, pageId: pageId, documentId: documentId)
        #expect(try await markupCount(package) == 2)
        try await package.close()

        // Old output: `.projectModifiedOutsideZenit` — close() had written the previous
        // save's record (old manifest hash, old token) over the new integrity.json.
        let reopened = try await ProjectPackage.open(
            at: workspace.packageURL, environment: environment, resolving: .discard
        )
        #expect(await reopened.integrityVerdict.isVerified)
        #expect(try await markupCount(reopened) == 2)
        try await reopened.close()
    }

    // MARK: - BH-186 / BH-188: a superseded database survives the next save

    private func makeCrashedPackage(
        _ label: String,
        savedMarkups: Int,
        unsavedBeforeAutosave: Int,
        unsavedAfterAutosave: Int = 0
    ) async throws -> (workspace: TestSupport.Workspace, environment: PersistenceEnvironment) {
        let workspace = try TestSupport.makeWorkspace(label)
        let environment = TestSupport.environment()
        let package = try await TestSupport.createPackage(workspace, environment: environment)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        try await insertMarkups(0..<savedMarkups, prefix: "saved", into: package, pageId: pageId, documentId: documentId)
        try await package.save()
        try await insertMarkups(0..<unsavedBeforeAutosave, prefix: "unsaved", into: package, pageId: pageId, documentId: documentId)
        _ = try await package.writeAutosave()
        try await insertMarkups(0..<unsavedAfterAutosave, prefix: "later", into: package, pageId: pageId, documentId: documentId)
        // A crash: the handle goes away, the marker stays armed.
        let handle = await package.database
        try await handle.close()
        return (workspace, environment)
    }

    /// Overwrites a stretch of a database's page data, past the header.
    private func scribble(over url: URL) throws {
        var bytes = try Data(contentsOf: url)
        guard bytes.count > 8_192 else { return }
        for offset in 4_096..<min(8_192, bytes.count) { bytes[offset] = 0xAA }
        try bytes.write(to: url)
    }

    @Test("BH-186/BH-188: the database a recovery parked in recovery/ is still there after the next save")
    func supersededDatabaseSurvivesTheNextSave() async throws {
        let (workspace, environment) = try await makeCrashedPackage(
            "Fix2Superseded", savedMarkups: 4, unsavedBeforeAutosave: 2
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try scribble(over: workspace.packageURL.member(ProjectPackageLayout.database))

        let recovered = try await ProjectPackage.open(
            at: workspace.packageURL, environment: environment, resolving: .recover
        )
        let parked = TestSupport.recoveryEntries(in: workspace.packageURL).filter { $0.hasPrefix("superseded-") }
        #expect(!parked.isEmpty, "precondition: the damaged database was parked, not deleted")

        try await recovered.save()
        // Old output: [] — recovery/ was rebuilt fresh in the temporary package and the
        // parked database went with the retired directory.
        let afterSave = TestSupport.recoveryEntries(in: workspace.packageURL).filter { $0.hasPrefix("superseded-") }
        #expect(afterSave == parked)
        // A saved version is the package as the save wrote it; it does not carry older
        // databases along.
        let latestRecovery = ProjectPackage.versionsRootURL(forPackageAt: workspace.packageURL)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
            .member(ProjectPackageLayout.recovery)
        let inVersion = (try? FileManager.default.contentsOfDirectory(atPath: latestRecovery.path)) ?? []
        #expect(!inVersion.contains { $0.hasPrefix("superseded-") })
        try await recovered.close()
    }

    // MARK: - BH-187: an inconclusive probe is not damage

    @Test("BH-187: Recover keeps a sound live database when the health probe copy cannot be made")
    func inconclusiveProbeDoesNotAdoptTheAutosave() async throws {
        let (workspace, environment) = try await makeCrashedPackage(
            "Fix2ProbeUnknown", savedMarkups: 5, unsavedBeforeAutosave: 3, unsavedAfterAutosave: 2
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        // A scratch "directory" that is a regular file: the probe copy cannot be staged.
        let blocker = workspace.root.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("x".utf8).write(to: blocker)
        let packagePath = workspace.packageURL.path
        ProjectPackage.healthProbeScratchDirectoryForTesting = { url in
            url.path.hasPrefix(packagePath) ? blocker : nil
        }
        defer { ProjectPackage.healthProbeScratchDirectoryForTesting = nil }

        let liveURL = workspace.packageURL.member(ProjectPackageLayout.database)
        #expect(ProjectPackage.databaseHealthForTesting(at: liveURL) == .unknown, "precondition: the probe is inconclusive")

        let recovered = try await ProjectPackage.open(
            at: workspace.packageURL, environment: environment, resolving: .recover
        )
        // Old output: 8 — the inconclusive probe was read as damage, the older autosave
        // was adopted, and the two markups committed after it were gone.
        #expect(try await markupCount(recovered) == 10)
        try await recovered.close()
    }

    // MARK: - BH-189: the autosave is one read snapshot

    @Test("BH-189: the autosave is taken through the backup API and leaves the live WAL alone")
    func autosaveIsASnapshotNotAFileCopy() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2AutosaveBackup")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        try await insertMarkups(0..<200, prefix: "m", into: package, pageId: pageId, documentId: documentId)

        // Commits keep landing while the snapshot is taken.
        let writer = Task {
            for batch in 0..<20 {
                try await insertMarkups(
                    (batch * 10)..<(batch * 10 + 10), prefix: "concurrent",
                    into: package, pageId: pageId, documentId: documentId
                )
            }
        }
        let info = try await package.writeAutosave()
        try await writer.value
        #expect(info.passesIntegrityCheck)

        // Old output: the -wal was 0 bytes here — writeAutosave TRUNCATE-checkpointed the
        // live database before streaming the main file. The snapshot is now taken from a
        // read transaction and never needs the log folded first.
        let autosaveURL = workspace.packageURL.member(ProjectPackageLayout.autosaveDatabase)
        let queue = try DatabaseQueue(path: autosaveURL.path)
        let snapshotCount = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1 }
        let quick = try await queue.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
        try queue.close()
        #expect(quick == ["ok"])
        // Every committed batch is ten rows, so a consistent snapshot holds a multiple
        // of ten on top of the seed — never a torn batch.
        #expect(snapshotCount >= 200 && (snapshotCount - 200) % 10 == 0, "snapshot holds \(snapshotCount) rows")
        try await package.close()
    }

    // MARK: - BH-602: a missing working copy fails the save

    @Test("BH-602: a save with documents/working.pdf missing is refused instead of recording the original's hash")
    func missingWorkingCopyFailsTheSave() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2MissingWorking")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        try FileManager.default.removeItem(at: workspace.packageURL.member(ProjectPackageLayout.workingPDF))

        // Old output: the save succeeded with workingPdfSha256 = originalPdfSha256, and the
        // next open refused the clean package as damaged.
        await #expect(throws: ZPDFPersistenceError.packageMemberMissing(
            relativePath: ProjectPackageLayout.workingPDF
        )) {
            try await package.save()
        }
        try await package.close()
    }

    // MARK: - BH-603 / BH-606: stranded restore and rotation litter is reclaimed

    @Test("BH-603/BH-606: a stranded restore file and a half-done rotation are reclaimed at open")
    func strandedLitterIsReclaimed() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2Litter")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let environment = TestSupport.environment()
        let package = try await TestSupport.createPackage(workspace, environment: environment)
        _ = try await TestSupport.insertPage(into: package)
        try await package.save()
        try await package.close()

        let restore = workspace.packageURL.appendingPathComponent(".restore-old.sqlite", isDirectory: false)
        try Data(repeating: 0, count: 4096).write(to: restore)
        let versions = ProjectPackage.versionsRootURL(forPackageAt: workspace.packageURL)
        let staging = versions.appendingPathComponent("staging-old", isDirectory: true)
        let discard = versions.appendingPathComponent("discard-old", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: discard, withIntermediateDirectories: true)

        let reopened = try await ProjectPackage.open(
            at: workspace.packageURL, environment: environment, resolving: .discard
        )
        // Old output: all three still present, and cloned into every later save and
        // saved version.
        #expect(!FileManager.default.fileExists(atPath: restore.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: discard.path))
        try await reopened.close()
    }

    // MARK: - BH-604: a saved version's journal says "completed"

    @Test("BH-604: versions/latest carries a journal that reads as a completed save")
    func savedVersionJournalIsClean() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2VersionJournal")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        let receipt = try await package.save()
        let latest = try #require(receipt.latestVersionURL)
        let journal = RecoveryJournal.read(from: latest.member(ProjectPackageLayout.recoveryJournal))
        // Old output: didAtomicReplace — the slot was cloned between that line and
        // didComplete, so a package restored from it raised the recovery sheet.
        #expect(journal.lastSave?.checkpoint == .didComplete)
        #expect(journal.saveInFlight == nil)
        try await package.close()
    }

    // MARK: - BH-605: the autosave's date is the file's, not the clock's

    @Test("BH-605: an autosave without a journal line is dated by its file, not by the open")
    func autosaveTimestampFallsBackToTheFile() async throws {
        let (workspace, _) = try await makeCrashedPackage(
            "Fix2AutosaveDate", savedMarkups: 1, unsavedBeforeAutosave: 1
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try FileManager.default.removeItem(at: workspace.packageURL.member(ProjectPackageLayout.recoveryJournal))
        let autosaveURL = workspace.packageURL.member(ProjectPackageLayout.autosaveDatabase)
        let modified = try #require(
            FileManager.default.attributesOfItem(atPath: autosaveURL.path)[.modificationDate] as? Date
        )

        // A clock far from the file's time, so the two answers cannot coincide.
        let environment = PersistenceEnvironment(
            clock: SteppingClock(start: Date(timeIntervalSince1970: 2_000_000_000)),
            identifiers: SequentialIdentifierGenerator(prefix: "D")
        )
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL, environment: environment)
        // Old output: "2033-05-18T03:33:20.000Z" — the clock reading at open.
        #expect(assessment.autosave?.timestamp == PersistenceTimestamp.string(from: modified))
    }

    // MARK: - IM-006: digests are reused while the bytes are provably unchanged

    @Test("IM-006: the second save hashes only the database, and a touched original is still caught")
    func secondSaveReusesThePDFDigests() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2DigestCache")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        try await package.save()

        _ = try await TestSupport.insertPage(into: package, pageIndex: 1, identifier: "page-1")
        let (_, counts) = try await FileDurability.Statistics.measure { try await package.save() }
        // Old output: 3 file hashes per save — original.pdf, working.pdf, project.sqlite.
        #expect(counts.fileHashCount == 1, "hashed \(counts.fileHashCount) files; only project.sqlite should be read")

        // The cache is keyed by the file's identity, so an edit outside the package is
        // still caught by the save, exactly as before.
        let originalURL = workspace.packageURL.member(ProjectPackageLayout.originalPDF)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: originalURL.path)
        let handle = try FileHandle(forWritingTo: originalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n%tampered".utf8))
        try handle.close()
        do {
            try await package.save()
            Issue.record("a save must refuse an original PDF whose bytes moved")
        } catch let error as ZPDFPersistenceError {
            guard case .originalPDFModified = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        try? await package.close()
    }

    // MARK: - IM-075: one device flush per tree

    @Test("IM-075: syncTree issues one full sync for a whole tree")
    func syncTreeFlushesTheDeviceOnce() async throws {
        let root = try TestSupport.makeTemporaryDirectory("Fix2SyncTree")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in 0..<5 {
            let sub = root.appendingPathComponent("d\(directory)", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for file in 0..<10 {
                try Data("\(directory)-\(file)".utf8).write(to: sub.appendingPathComponent("f\(file)"))
            }
        }
        let (_, counts) = try await FileDurability.Statistics.measure {
            try FileDurability.syncTree(at: root)
        }
        // Old output: 56 — one F_FULLFSYNC per file and per directory.
        #expect(counts.fullSyncCount == 1, "\(counts.fullSyncCount) full syncs for one tree")
    }

    // MARK: - IM-194: foreign-key violations are caught at open, not walked at every save

    @Test("IM-194: a package carrying crash evidence and a foreign-key violation is refused at open")
    func foreignKeyViolationIsRefusedAtOpen() async throws {
        let (workspace, environment) = try await makeCrashedPackage(
            "Fix2ForeignKey", savedMarkups: 2, unsavedBeforeAutosave: 1
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        // Another tool deletes the page the markups hang off, with enforcement off.
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try await queue.write { db in try db.execute(sql: "DELETE FROM page") }
        try queue.close()

        // Old output: opened, and the violation surfaced only at the next save.
        await #expect(throws: ZPDFPersistenceError.integrityCheckFailed(
            detail: "3 foreign-key violation(s)"
        )) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: environment, resolving: .recover
            )
        }
    }

    @Test("IM-194/IM-074: measured — validation without the foreign-key walk, and quick_check against integrity_check")
    func measureValidationAndChecks() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2Measure")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        try await insertMarkups(0..<20_000, prefix: "m", into: package, pageId: pageId, documentId: documentId)
        let bounds = try TestSupport.sampleGeometry(pointCount: 2)
        try await package.write { db in
            for index in 0..<20_000 {
                try db.execute(
                    sql: """
                        INSERT INTO ocr_token
                            (page_id, token, normalized_token, confidence, bounds_blob, line_index, token_index)
                        VALUES (?, ?, ?, 1, ?, ?, 0)
                        """,
                    arguments: [pageId, "Token\(index)", "token\(index)", bounds, index]
                )
            }
        }

        func time(_ body: () async throws -> Void) async rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try await body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        // Best of five each: the suites run in parallel, so one reading measures the
        // neighbours as much as the query.
        var withWalk = Double.infinity
        var withoutWalk = Double.infinity
        for _ in 0..<5 {
            withWalk = min(withWalk, try await time {
                _ = try await package.read { db in try DomainValidation.validate(db, checkForeignKeys: true) }
            })
            withoutWalk = min(withoutWalk, try await time {
                _ = try await package.read { db in try DomainValidation.validate(db, checkForeignKeys: false) }
            })
        }
        let handle = await package.database
        // Best of three each: the suites run in parallel, so a single reading is as
        // much a measurement of the neighbours as of the check.
        var full = Double.infinity
        var quick = Double.infinity
        for _ in 0..<3 {
            full = min(full, try await time { try await handle.integrityCheck() })
            quick = min(quick, try await time { try await handle.quickCheck() })
        }
        print("IM-194 validate: with foreign_key_check \(withWalk) ms, without \(withoutWalk) ms (best of 5)")
        print("IM-074 integrity_check \(full) ms, quick_check \(quick) ms (best of 3)")
        // Timings are reported, not asserted: under a parallel suite they measure load.
        // What is asserted is structural — the save's validation really skips the walk:
        // a violation it cannot see without it is invisible with `checkForeignKeys: false`.
        let (seen, skipped) = try await package.write { db -> (Bool, Bool) in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try db.execute(
                sql: "UPDATE markup SET page_id = 'no-such-page' WHERE id = 'm-0'"
            )
            let with = try DomainValidation.validate(db, checkForeignKeys: true)
            let without = try DomainValidation.validate(db, checkForeignKeys: false)
            try db.execute(sql: "UPDATE markup SET page_id = ? WHERE id = 'm-0'", arguments: [pageId])
            return (
                with.contains { $0.code == "foreign-key-violation" },
                !without.contains { $0.code == "foreign-key-violation" }
            )
        }
        #expect(seen && skipped)
        try await package.close()
    }
}
