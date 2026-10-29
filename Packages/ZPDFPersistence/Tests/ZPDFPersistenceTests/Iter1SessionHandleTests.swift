import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// The database handle a caller caches survives a
/// save (R-186), a swap that fails twice does not strand it (R-190), the health probe and
/// failed saves do not leak staging directories (R-199), and a save neither restamps the
/// session nor fails after it has committed (R-200).
@Suite("Iteration 1 — one database handle per session")
struct Iter1SessionHandleTests {

    private actor SaveGate {
        private var reached = false
        private var released = false
        private var reachWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markReached() {
            reached = true
            reachWaiters.forEach { $0.resume() }
            reachWaiters = []
        }
        func waitUntilReached() async {
            if reached { return }
            await withCheckedContinuation { reachWaiters.append($0) }
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

    private func insertMarkup(
        _ id: String, through database: ProjectDatabaseActor, pageId: String, documentId: String
    ) async throws {
        let geometry = try TestSupport.sampleGeometry()
        try await database.write { db in
            try MarkupRecord(
                id: id, documentId: documentId, pageId: pageId,
                type: "count", subject: id,
                geometryBlob: geometry, styleBlob: Data([1]),
                createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
            ).insert(db)
        }
    }

    private func markupCount(_ package: ProjectPackage) async throws -> Int {
        try await package.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1 }
    }

    private func reopenedMarkupCount(_ workspace: TestSupport.Workspace) async throws -> Int {
        let reopened = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .discard
        )
        let count = try await markupCount(reopened)
        try await reopened.close()
        return count
    }

    // MARK: - R-186

    @Test("R-186: a handle fetched before a save still writes after it, and the row is saved")
    func cachedHandleWritesAfterSave() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1CachedHandle")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)

        // What the History feed, Review and Ledger Snapshots do: fetch once, at mount.
        let cached = await package.database
        try await package.save()
        #expect(await package.database === cached, "the package keeps one handle for the session")

        // Old output: ZPDFPersistenceError.databaseFailure("the database handle is closed")
        // — the save had closed this actor and installed a new one.
        try await insertMarkup("after-first-save", through: cached, pageId: pageId, documentId: documentId)
        try await package.save()
        try await insertMarkup("after-second-save", through: cached, pageId: pageId, documentId: documentId)
        #expect(try await markupCount(package) == 2)
        try await package.save()
        try await package.close()
        #expect(try await reopenedMarkupCount(workspace) == 2)
    }

    @Test("R-186: a write through a cached handle during a save waits for the swap and survives it")
    func cachedHandleWriteDuringSaveSurvives() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1CachedDuringSave")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let cached = await package.database

        // Parked after the database was streamed into the temporary package: a row
        // committed now, unfenced, lands in the file the swap retires.
        let gate = SaveGate()
        let save = Task {
            try await package.save(hooks: SaveHooks { checkpoint in
                if checkpoint == .willAtomicReplace {
                    await gate.markReached()
                    await gate.waitForRelease()
                }
            })
        }
        await gate.waitUntilReached()
        let landed = Flag()
        let write = Task {
            try await insertMarkup("during-save", through: cached, pageId: pageId, documentId: documentId)
            await landed.set()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await !landed.isSet, "a direct write must wait behind the save, not commit into the retiring file")
        // Reads are not fenced: the History pane keeps answering while a save runs.
        #expect(try await cached.read { db in try Int.fetchOne(db, sql: "SELECT 1") } == 1)

        await gate.release()
        _ = try await save.value
        try await write.value
        #expect(try await markupCount(package) == 1)
        try await package.save()
        try await package.close()
        #expect(try await reopenedMarkupCount(workspace) == 1)
    }

    @Test("R-186: a save refused before the swap lifts the write fence")
    func refusedSaveLiftsTheFence() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1RefusedFence")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let cached = await package.database

        struct Stop: Error {}
        await #expect(throws: Stop.self) {
            try await package.save(hooks: SaveHooks { checkpoint in
                if checkpoint == .didHash { throw Stop() }
            })
        }
        // A fence left up would hang this write forever.
        try await insertMarkup("after-refusal", through: cached, pageId: pageId, documentId: documentId)
        #expect(try await markupCount(package) == 1)
        try await package.close()
    }

    // MARK: - R-190

    @Test("R-190: a failed swap whose reopen also fails reports the swap error and leaves a working handle")
    func failedSwapAndFailedReopenDoNotStrandTheHandle() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1SwapAndReopen")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.root.path)
            try? FileManager.default.removeItem(at: workspace.root)
        }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        let root = workspace.root

        // The swap needs write access to the package's parent; the reopen needs the file.
        var thrown: (any Error)?
        do {
            try await package.save(hooks: SaveHooks { checkpoint in
                if checkpoint == .willAtomicReplace {
                    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
                    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: databaseURL.path)
                }
            })
        } catch {
            thrown = error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: databaseURL.path)

        // Old output: `.databaseOpenFailed` — the bare reopen in the catch replaced the
        // swap's own error.
        guard case .atomicReplaceFailed? = thrown as? ZPDFPersistenceError else {
            Issue.record("expected the swap error, got \(String(describing: thrown))")
            try? await package.close()
            return
        }
        // Old output: "the database handle is closed" on this and every later write —
        // the closed actor stayed installed with no reopen pending.
        try await insertMarkup("after-failed-swap", through: await package.database, pageId: pageId, documentId: documentId)
        #expect(try await markupCount(package) == 1)
        try await package.save()
        try await package.close()
        #expect(try await reopenedMarkupCount(workspace) == 1)
    }

    // MARK: - R-199

    /// The directory `.itemReplacementDirectory` creates its per-call directories in.
    private func itemReplacementRoot(for url: URL) throws -> URL {
        let probe = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true
        )
        defer { try? FileManager.default.removeItem(at: probe) }
        return probe.deletingLastPathComponent()
    }

    private func entryCount(_ directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    @Test("R-199: the health probe and a refused save leave no staging directory behind")
    func probeAndRefusedSaveDoNotLeakStagingDirectories() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1StagingLeak")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        try await package.save()
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        let root = try itemReplacementRoot(for: workspace.packageURL)
        let before = entryCount(root)

        let rounds = 12
        for _ in 0..<rounds {
            #expect(ProjectPackage.databaseHealthForTesting(at: databaseURL) == .sound)
        }
        // A rotation that is not a quarter turn is refused at step 1.
        try await package.write { db in
            try db.execute(sql: "UPDATE page SET rotation = 45 WHERE id = ?", arguments: [pageId])
        }
        for _ in 0..<rounds {
            await #expect(throws: ZPDFPersistenceError.self) { try await package.save() }
        }
        try await package.write { db in
            try db.execute(sql: "UPDATE page SET rotation = 0 WHERE id = ?", arguments: [pageId])
        }
        try await package.close()

        // Old output: 24 more — one empty NSIRD directory per probe and per refused save.
        // Other suites run in parallel in this process and may hold one or two of their
        // own for a moment; a leak adds one per round.
        let grown = entryCount(root) - before
        #expect(grown < rounds / 2, "\(grown) item-replacement directories left behind")
    }

    // MARK: - R-200

    @Test("R-200: a save keeps the session's openedAt and journals no second session-opened")
    func saveKeepsTheSessionStart() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1SessionStart")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        let opened = try #require(ProjectPackage.CrashMarker.read(from: markerURL))

        try await package.save()
        try await package.save()

        let afterSave = try #require(ProjectPackage.CrashMarker.read(from: markerURL))
        // Old output: the second save's clock reading — armCrashMarker() restamped it.
        #expect(afterSave.openedAt == opened.openedAt)
        #expect(afterSave.sessionID == opened.sessionID)
        let journal = RecoveryJournal.read(
            from: workspace.packageURL.member(ProjectPackageLayout.recoveryJournal)
        )
        // Old output: a `session-opened` line after every save's `didPreserveVersion`.
        #expect(journal.entries.filter { $0.kind == .sessionOpened }.isEmpty,
                "the swapped-in journal must not claim a new session")
        #expect(journal.entries.last?.checkpoint == .didComplete)
        try await package.close()
    }

    @Test("R-200: a marker that cannot be rewritten after the commit does not fail the save")
    func markerFailureAfterCommitDoesNotFailTheSave() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter1MarkerAfterCommit")
        let recoveryURL = workspace.packageURL.member(ProjectPackageLayout.recovery)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recoveryURL.path)
            try? FileManager.default.removeItem(at: workspace.root)
        }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        try await insertMarkup("saved", through: await package.database, pageId: pageId, documentId: documentId)

        // After the swap `recovery/` is the new package's; make it refuse the marker.
        let receipt = try await package.save(hooks: SaveHooks { checkpoint in
            if checkpoint == .didPreserveVersion {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recoveryURL.path)
            }
        })
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recoveryURL.path)

        // Old output: the save threw a posix failure from `writeCrashMarker`, although the
        // package on disk already was the new state.
        #expect(await package.manifest == receipt.manifest)
        #expect(try ProjectPackage.verifyIntegrity(at: workspace.packageURL).isFullyConsistent)
        // The marker the temporary package carried through the swap is still armed.
        let marker = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try await package.close()
        #expect(try await reopenedMarkupCount(workspace) == 1)
    }
}
