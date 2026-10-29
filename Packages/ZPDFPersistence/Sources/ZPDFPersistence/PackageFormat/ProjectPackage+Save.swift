import Foundation
import GRDB

/// Spec 6.4, step for step:
///
/// ```text
/// validate domain model
/// → commit transaction
/// → checkpoint WAL
/// → write temporary package in the item replacement directory (12.5)
/// → hash manifest/database/PDF
/// → fsync files and directory
/// → atomic replace
/// → preserve backup/version
/// → update NSDocument change count
/// ```
///
/// The shape of the guarantee: until the atomic replace in step 7, nothing outside the
/// staged temporary package has been modified, so a crash anywhere before it leaves the
/// project exactly as it was. The swap itself is a single filesystem transaction. After
/// it, the project is the new state and the only work left is housekeeping. There is no
/// third outcome — which is what the kill-during-save suite exists to demonstrate rather
/// than assert.
extension ProjectPackage {

    /// Runs the save pipeline. Returns what was written.
    ///
    /// - Parameter hooks: production passes ``SaveHooks/none``. The durability tests
    ///   pass hooks that `SIGKILL` the process at a named checkpoint.
    @discardableResult
    public func save(hooks: SaveHooks = .none) async throws -> SaveReceipt {
        // One pipeline at a time. The actor is reentrant, so two concurrent `save`
        // calls — or a `close` racing a save — would otherwise interleave at any of
        // the pipeline's suspension points. The pipeline runs as one registered task;
        // a second save queues behind it, and `close()` drains it before it appends
        // `session-closed` (the save-then-quit marker race).
        await drainActiveSave()
        guard accessMode == .readWrite else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        guard !isClosed else {
            throw ZPDFPersistenceError.packageMalformed(reason: "the package handle is closed")
        }
        saveGeneration += 1
        let generation = saveGeneration
        let pipeline = Task { try await self.runSavePipeline(hooks: hooks) }
        activeSave = (generation, pipeline)
        defer { if activeSave?.generation == generation { activeSave = nil } }
        return try await pipeline.value
    }

    /// The 6.4 pipeline itself. Entered only through ``save(hooks:)``, which serializes
    /// it against concurrent saves and closes.
    private func runSavePipeline(hooks: SaveHooks) async throws -> SaveReceipt {
        // The temporary package is staged in the item replacement directory — same
        // volume, always writable, never a sibling the powerbox grant does not cover
        // under the App Sandbox. The versions live inside the package for the same reason.
        let stagingParent = try Self.stagingDirectory(appropriateFor: url)
        do {
            return try await runSavePipeline(hooks: hooks, stagingParent: stagingParent)
        } catch {
            // Whatever threw, the database handle leaves the save open for everybody's
            // writes again (R-186) — a handle left fenced or suspended would hang every
            // later access — and the per-save staging directory does not outlive the
            // save that made it (R-199: one empty directory per failed save, before).
            await databaseHandle.endSaveFence()
            FileDurability.removeIfPresent(stagingParent)
            throw error
        }
    }

    private func runSavePipeline(hooks: SaveHooks, stagingParent: URL) async throws -> SaveReceipt {

        let token = environmentIdentifiers.nextIdentifier()
        let parent = url.deletingLastPathComponent()
        let packageName = url.lastPathComponent
        let temporaryURL = stagingParent.appendingPathComponent(
            ProjectPackageLayout.temporaryName(for: packageName, token: token), isDirectory: true
        )
        let versionsRoot = url.member(ProjectPackageLayout.versions)

        // Steps 1–7 leave the project untouched if they throw. The journal has to say
        // so (BH-190): the pipeline writes its checkpoint line *before* each step, so a
        // save refused by validation, a full disk or a changed original used to leave
        // `willValidate` or `didHash` as the journal's last save line, which the next
        // open read as a session that died mid-save — a recovery sheet for a crash that
        // never happened. An aborted save closes its own entry instead.
        let receiptParts: (manifest: ProjectManifest, integrity: IntegrityRecord, databaseByteCount: Int)
        let directorySyncConfirmed: Bool
        do {
            (receiptParts, directorySyncConfirmed) = try await stageAndSwap(
                token: token, temporaryURL: temporaryURL, stagingParent: stagingParent,
                parent: parent, hooks: hooks
            )
        } catch {
            appendSaveAbortJournal(token: token, error: error)
            throw error
        }
        // From here the user's project *is* saved. Everything below is housekeeping,
        // and a crash in it costs nothing.

        // ── 8. Preserve the previous version ────────────────────────────────────────
        // `temporaryURL` now names the directory the package used to occupy. It is not
        // the previous *version*: the live database was edited in place, so that
        // directory holds the new rows under the old manifest. It is discarded, and the
        // version slots are rotated with a clone of what this save actually wrote.
        // The per-save staging directory goes with it — the system would purge it
        // eventually, but one empty NSIRD directory per save is still litter.
        FileDurability.removeIfPresent(temporaryURL)
        FileDurability.removeIfPresent(stagingParent)
        rotateSavedVersions(versionsRoot: versionsRoot, token: token)
        appendSaveJournal(token: token, checkpoint: .didPreserveVersion)
        try await hooks.onCheckpoint(.didPreserveVersion)

        // ── 9. Update the change count ──────────────────────────────────────────────
        // The package on disk is the new state whatever happens to the handle below, so
        // the in-memory record says so *first* (BH-185). The old order reassigned the
        // manifest and the integrity record only after a successful reopen: a transient
        // failure there — the sandbox refusing the `-shm`, an EACCES that clears itself
        // — left a closed handle behind every later write, and a `close()` that wrote
        // the previous save's record over the new `integrity.json`, so the next open
        // refused the project as modified outside this application.
        currentManifest = receiptParts.manifest
        currentIntegrity = receiptParts.integrity
        currentChangeCount = 0
        // The PDFs in the swapped-in package are the clones the identity check just
        // vouched for; they carry the same bytes under new inodes (IM-006).
        rememberDigests(after: receiptParts.integrity)
        // The same actor reopens its pool on the swapped-in package (R-186), so every
        // caller holding `database` keeps a live handle. If the reopen fails the save has
        // still committed; only the pool is missing, and the next access retries it
        // rather than failing on a handle that stays closed (BH-185).
        if let reopenError = await databaseHandle.endSaveFence() {
            appendSaveJournal(
                token: token, checkpoint: .didPreserveVersion,
                detail: "database reopen deferred: \(reopenError)"
            )
        }
        // The session is still open, so the new package needs its own crash marker — the
        // same session's, rewritten, not a new one (R-200). `armCrashMarker()` used to run
        // here: it restamped `openedAt` with the save time, so another Mac's open-elsewhere
        // sheet named the last save as the session start, and it journaled a
        // `session-opened` for a session that never closed. It could also throw, which made
        // a save that had already committed report itself as failed. The temporary package
        // carries this same marker through the swap, so a failure here is journaled, not
        // thrown.
        do {
            try writeCrashMarker(into: url)
        } catch {
            appendSaveJournal(
                token: token, checkpoint: .didPreserveVersion,
                detail: "crash marker rewrite failed: \(error)"
            )
        }
        appendSaveJournal(token: token, checkpoint: .didComplete)
        try await hooks.onCheckpoint(.didComplete)

        let previousSlot = versionsRoot.appendingPathComponent(
            ProjectPackageLayout.previousVersion, isDirectory: true
        )
        let latestSlot = versionsRoot.appendingPathComponent(
            ProjectPackageLayout.latestVersion, isDirectory: true
        )
        return SaveReceipt(
            token: token,
            manifest: receiptParts.manifest,
            integrity: receiptParts.integrity,
            // Guarded by existence: a rotation that could not produce a backup must not be
            // reported as one (CR-82).
            latestVersionURL: FileDurability.exists(latestSlot) ? latestSlot : nil,
            previousVersionURL: FileDurability.exists(previousSlot) ? previousSlot : nil,
            changeCount: 0,
            databaseByteCount: receiptParts.databaseByteCount,
            directorySyncConfirmed: directorySyncConfirmed
        )
    }

    /// Steps 1–7: everything that can still be abandoned, ending with the swap.
    private func stageAndSwap(
        token: String,
        temporaryURL: URL,
        stagingParent: URL,
        parent: URL,
        hooks: SaveHooks
    ) async throws -> (
        parts: (manifest: ProjectManifest, integrity: IntegrityRecord, databaseByteCount: Int),
        directorySyncConfirmed: Bool
    ) {
        let handle = databaseHandle

        // ── 1. Validate the domain model ────────────────────────────────────────────
        appendSaveJournal(token: token, checkpoint: .willValidate)
        try await hooks.onCheckpoint(.willValidate)
        // Without the foreign-key walk (IM-194): every connection this package opens
        // enforces foreign keys, so a write of ours cannot leave a violation; the open
        // path checks the packages that could have received one from outside.
        let issues = try await handle.read { db in
            try DomainValidation.validate(db, checkForeignKeys: false)
        }
        guard issues.isEmpty else {
            throw ZPDFPersistenceError.saveValidationFailed(issues: issues)
        }
        appendSaveJournal(token: token, checkpoint: .didValidate)
        try await hooks.onCheckpoint(.didValidate)
        try Task.checkCancellation()

        // From the commit stamp to the reopen in step 9, every write but the pipeline's
        // own waits (R-186). `ProjectPackage.write` already queues behind a save (BH-029);
        // this covers the callers that hold `database` directly, whose rows would
        // otherwise commit after the checkpoint into the database the swap retires.
        // Lifted by `endSaveFence()` on every path out: step 9, or the catch in
        // `runSavePipeline(hooks:)`.
        await handle.beginSaveFence()

        // ── 2. Commit the transaction ───────────────────────────────────────────────
        // Everything the user did is already committed by `write`; this stamps the
        // project row so `modified_at` and the manifest agree, and gives the pipeline a
        // single well-defined commit point.
        let savedAt = PersistenceTimestamp.string(from: environmentClock.now())
        try await handle.writeInsideSaveFence { db in
            try db.execute(sql: "UPDATE project SET modified_at = ?", arguments: [savedAt])
        }
        appendSaveJournal(token: token, checkpoint: .didCommit)
        try await hooks.onCheckpoint(.didCommit)

        // ── 3. Checkpoint the WAL ───────────────────────────────────────────────────
        // TRUNCATE, so the temporary package receives one self-contained file. Retried,
        // because a long-running reader can hold it off and the right answer is to wait
        // rather than to abandon the user's save.
        try await checkpointForSave()
        appendSaveJournal(token: token, checkpoint: .didCheckpointWAL)
        try await hooks.onCheckpoint(.didCheckpointWAL)
        try Task.checkCancellation()

        // ── 4. Write the temporary package in the staging directory ─────────────────
        appendSaveJournal(token: token, checkpoint: .willWriteTemporaryPackage)
        try await hooks.onCheckpoint(.willWriteTemporaryPackage)

        FileDurability.removeIfPresent(temporaryURL)
        do {
            try await buildTemporaryPackage(at: temporaryURL, token: token, hooks: hooks)
        } catch {
            FileDurability.removeIfPresent(temporaryURL)
            throw error
        }
        appendSaveJournal(token: token, checkpoint: .didWriteTemporaryPackage)
        try await hooks.onCheckpoint(.didWriteTemporaryPackage)

        // ── 5. Hash the manifest, the database and the PDFs ─────────────────────────
        let receiptParts: (manifest: ProjectManifest, integrity: IntegrityRecord, databaseByteCount: Int)
        do {
            receiptParts = try writeManifestAndIntegrity(
                into: temporaryURL, token: token, savedAt: savedAt
            )
        } catch {
            FileDurability.removeIfPresent(temporaryURL)
            throw error
        }
        appendSaveJournal(token: token, checkpoint: .didHash)
        try await hooks.onCheckpoint(.didHash)

        // ── 6. fsync every file, then the directories that name them ────────────────
        // The directory that names the temporary is its staging parent; the package's
        // own parent is synced (best effort — the sandbox may not grant it) after the
        // swap, which is the rename that actually concerns it.
        do {
            try FileDurability.syncTree(at: temporaryURL)
            try FileDurability.syncDirectory(at: stagingParent)
        } catch {
            FileDurability.removeIfPresent(temporaryURL)
            throw error
        }
        appendSaveJournal(token: token, checkpoint: .didFsync)
        try await hooks.onCheckpoint(.didFsync)
        try Task.checkCancellation()

        // ── 7. Atomic replace ───────────────────────────────────────────────────────
        // The pool has to let go first: after the swap, `<package>/project.sqlite`
        // resolves to a different inode, and a descriptor opened before the swap would
        // keep writing into the copy that is on its way to the previous-version sibling.
        appendSaveJournal(token: token, checkpoint: .willAtomicReplace)
        try await hooks.onCheckpoint(.willAtomicReplace)

        await handle.suspendForSwap()
        do {
            try FileDurability.atomicReplace(temporaryURL, into: url)
        } catch {
            // Nothing was replaced. Reopen the pool on the untouched package so the user
            // keeps working on exactly what they had. A reopen that fails too must not
            // replace the swap's error nor strand the handle (R-190): the old branch did
            // `try await ProjectDatabaseActor.open(...)` bare, so its failure escaped
            // instead of the swap error, skipped the cleanup below, and left the closed
            // handle installed with no reopen pending — every later write failed. Now
            // the actor keeps the reopen pending and retries it on the next access.
            if let reopenError = await handle.endSaveFence() {
                appendSaveJournal(
                    token: token, checkpoint: .willAtomicReplace,
                    detail: "database reopen deferred: \(reopenError)"
                )
            }
            FileDurability.removeIfPresent(temporaryURL)
            throw error
        }
        // From here the user's project *is* saved. Everything below is housekeeping,
        // and a crash in it costs nothing.
        // Best effort, but not silent: a swallowed failure here is the difference
        // between "saved" and "saved unless the power goes out", and the classic way
        // that difference goes unnoticed is a bare `try?`.
        var directorySyncConfirmed = true
        do {
            try FileDurability.syncDirectory(at: parent)
        } catch {
            directorySyncConfirmed = false
            appendSaveJournal(
                token: token,
                checkpoint: .didAtomicReplace,
                detail: "parent directory fsync failed: \(error)"
            )
        }
        appendSaveJournal(token: token, checkpoint: .didAtomicReplace)
        try await hooks.onCheckpoint(.didAtomicReplace)
        return (receiptParts, directorySyncConfirmed)
    }

    // MARK: - Stages

    /// `TRUNCATE`, retried, then verified against the file on disk.
    private func checkpointForSave() async throws {
        var lastError: ZPDFPersistenceError?
        for attempt in 0..<3 {
            do {
                let report = try await databaseHandle.checkpoint(.truncate)
                if report.walByteCountAfter == 0 { return }
                lastError = .walCheckpointFailed(
                    reason: "wal still \(report.walByteCountAfter) bytes after attempt \(attempt + 1)"
                )
            } catch let error as ZPDFPersistenceError {
                lastError = error
            }
            // A reader is holding an old snapshot. Yield and try again rather than
            // failing a save the user asked for.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw lastError ?? .walCheckpointFailed(reason: "unknown")
    }

    /// Builds the sibling package: everything cloned, the database streamed.
    ///
    /// Clone-on-write handles the bulk of the package in constant time, which is what
    /// makes saving a project with a 400 MB drawing set cost the size of the database
    /// rather than the size of the project. The database itself is streamed rather than
    /// cloned so the pipeline has one honest partial-write window — the one the kill
    /// tests aim at.
    private func buildTemporaryPackage(at temporaryURL: URL, token: String, hooks: SaveHooks) async throws {
        try FileDurability.createDirectory(at: temporaryURL)

        // Members the new package rewrites, plus SQLite's sidecars, which are stale the
        // moment the main file is copied.
        let excluded: Set<String> = [
            ProjectPackageLayout.database,
            ProjectPackageLayout.database + "-wal",
            ProjectPackageLayout.database + "-shm",
            ProjectPackageLayout.manifest,
            ProjectPackageLayout.integrity,
            ProjectPackageLayout.recovery
        ]
        for name in FileDurability.directoryEntryNames(at: url)
        where !excluded.contains(name) && !ProjectPackageLayout.isStrandedRestoreFile(name: name) {
            try FileDurability.cloneItem(
                at: url.appendingPathComponent(name),
                to: temporaryURL.appendingPathComponent(name)
            )
        }
        for directory in ProjectPackageLayout.directories
        where !FileDurability.exists(temporaryURL.member(directory)) {
            try FileDurability.createDirectory(at: temporaryURL.member(directory))
        }
        // The recovery directory is rebuilt fresh, with one exception: the databases a
        // recovery parked there are carried forward (BH-186, BH-188). `replaceLiveDatabase`
        // promises that a superseded `project.sqlite` is never deleted, so that a snapshot
        // which turned out worse than what it replaced can still be got at; excluding the
        // whole directory meant the very next save retired it with the old package.
        let liveRecovery = url.member(ProjectPackageLayout.recovery)
        for name in FileDurability.directoryEntryNames(at: liveRecovery)
        where ProjectPackageLayout.isSupersededDatabaseFile(name: name) {
            try FileDurability.cloneItem(
                at: liveRecovery.appendingPathComponent(name),
                to: temporaryURL.member(ProjectPackageLayout.recovery).appendingPathComponent(name)
            )
        }
        // A saved version's slots are cloned with the package, but a rotation that a
        // crash interrupted leaves a staging or discard directory nobody names again
        // (BH-603). Not cloned, and reclaimed at the next rotation.
        let temporaryVersions = temporaryURL.member(ProjectPackageLayout.versions)
        for name in FileDurability.directoryEntryNames(at: temporaryVersions)
        where ProjectPackageLayout.isStrandedVersionRotation(name: name) {
            FileDurability.removeIfPresent(temporaryVersions.appendingPathComponent(name))
        }

        // A fresh recovery directory: no crash marker, no autosave, and a journal whose
        // only line says this package was saved cleanly. The evidence of the save in
        // progress stays in the live package, where a crash can still be seen.
        var journal = RecoveryJournal()
        journal.append(RecoveryJournalEntry(
            token: token, kind: .save, checkpoint: .didComplete,
            detail: nil,
            timestamp: PersistenceTimestamp.string(from: environmentClock.now()),
            changeCount: 0
        ))
        try FileDurability.writeNewFile(
            try journal.encoded(), to: temporaryURL.member(ProjectPackageLayout.recoveryJournal)
        )

        // The session does not end when the save does, so the temporary package carries a
        // crash marker of its own. Without it there would be a window — between the
        // atomic swap and the marker being re-armed on the other side — in which a crash
        // left a package that looked cleanly closed. Small window, real consequence: the
        // next launch would not tell the user their last session died.
        try writeCrashMarker(into: temporaryURL)

        try await FileDurability.copyFile(
            from: url.member(ProjectPackageLayout.database),
            to: temporaryURL.member(ProjectPackageLayout.database),
            onProgress: { [hooks] fraction in
                if fraction >= 0.5 {
                    try await hooks.onCheckpoint(.midTemporaryPackageWrite)
                }
            }
        )
    }

    /// Step 5: hash what was written, and record it.
    private func writeManifestAndIntegrity(
        into temporaryURL: URL,
        token: String,
        savedAt: String
    ) throws -> (manifest: ProjectManifest, integrity: IntegrityRecord, databaseByteCount: Int) {
        let originalHash = try memberDigest(
            of: ProjectPackageLayout.originalPDF, clonedInto: temporaryURL
        )
        // The original PDF is carried forward by clone (or a copy where the volume cannot
        // clone) and is never opened for writing. If its hash has moved, something outside
        // this package edited it, and continuing would launder that edit into a signed
        // manifest.
        guard originalHash == currentManifest.originalPdfSha256 else {
            throw ZPDFPersistenceError.originalPDFModified(
                expected: currentManifest.originalPdfSha256, found: originalHash
            )
        }

        // A working copy that has gone missing is a damaged package, and the save says
        // so now (BH-602). The old path recorded the original's hash in its place, so
        // the save reported success and the *next open* refused the project as damaged.
        guard FileDurability.exists(temporaryURL.member(ProjectPackageLayout.workingPDF)) else {
            throw ZPDFPersistenceError.packageMemberMissing(relativePath: ProjectPackageLayout.workingPDF)
        }
        let workingHash = try memberDigest(
            of: ProjectPackageLayout.workingPDF, clonedInto: temporaryURL
        )

        var manifest = currentManifest
        manifest.modifiedAt = savedAt
        manifest.appVersion = environment.appVersion
        manifest.databaseSchema = ProjectSchema.currentVersion
        manifest.originalPdfSha256 = originalHash
        manifest.workingPdfSha256 = workingHash
        manifest.minimumReaderVersion = environment.minimumReaderVersion

        let manifestData = try manifest.encoded()
        let manifestURL = temporaryURL.member(ProjectPackageLayout.manifest)
        FileDurability.removeIfPresent(manifestURL)
        try FileDurability.writeNewFile(manifestData, to: manifestURL)
        try FileDurability.writeNewFile(
            manifestData, to: temporaryURL.member(ProjectPackageLayout.lastGoodManifest)
        )

        let databaseURL = temporaryURL.member(ProjectPackageLayout.database)
        let integrity = IntegrityRecord(
            manifestSha256: FileDurability.sha256(of: manifestData),
            databaseSha256: try FileDurability.sha256(ofFileAt: databaseURL),
            originalPdfSha256: originalHash,
            workingPdfSha256: workingHash,
            saveToken: token,
            savedAt: savedAt,
            generation: (currentIntegrity?.generation ?? 0) + 1
        )
        try FileDurability.writeNewFile(
            try integrity.encoded(), to: temporaryURL.member(ProjectPackageLayout.integrity)
        )
        return (manifest, integrity, FileDurability.byteCount(of: databaseURL))
    }

    /// Step 8. Best effort by design: the save is already committed, and a failure here
    /// costs the user a backup, not their work.
    ///
    /// `previous` ← `latest` ← a fresh clone of the package this save just wrote. The
    /// clone is copy-on-write, so it costs the blocks that changed since the last save
    /// rather than the size of the project, and it shares the original PDF's blocks with
    /// the live package instead of copying a drawing set twice.
    ///
    /// The versions live inside the package (12.5), so the clone is taken member by
    /// member with `versions` itself excluded — a slot must never nest another slot.
    private func rotateSavedVersions(versionsRoot: URL, token: String) {
        guard (try? FileDurability.createDirectory(at: versionsRoot)) != nil else { return }
        let latest = versionsRoot.appendingPathComponent(
            ProjectPackageLayout.latestVersion, isDirectory: true
        )
        let previous = versionsRoot.appendingPathComponent(
            ProjectPackageLayout.previousVersion, isDirectory: true
        )
        let staging = versionsRoot.appendingPathComponent("staging-\(token)", isDirectory: true)
        let discard = versionsRoot.appendingPathComponent("discard-\(token)", isDirectory: true)

        // 1. Build the new latest in a staging directory FIRST. If any of the clone fails, the
        //    existing `latest` is still the most recent backup and is left completely untouched.
        //    The old code built the new latest in place after moving the previous one aside, so a
        //    failed clone deleted `versions/latest` outright — destroying the most recent backup
        //    by failing to make a new one, while the receipt still named it (CR-82).
        // A rotation an earlier crash interrupted can have stranded a staging or discard
        // directory under its own token; nothing else ever names it again (BH-603).
        for name in FileDurability.directoryEntryNames(at: versionsRoot)
        where ProjectPackageLayout.isStrandedVersionRotation(name: name) {
            FileDurability.removeIfPresent(versionsRoot.appendingPathComponent(name))
        }
        FileDurability.removeIfPresent(staging)
        var staged = false
        do {
            try FileDurability.createDirectory(at: staging)
            for name in FileDurability.directoryEntryNames(at: url)
            where name != ProjectPackageLayout.versions
                && !ProjectPackageLayout.isStrandedRestoreFile(name: name) {
                try FileDurability.cloneItem(
                    at: url.appendingPathComponent(name),
                    to: staging.appendingPathComponent(name)
                )
            }
            // The clone carries this session's crash marker. A saved version is not a session, so
            // the marker is stripped: restoring from it must not look like a crash that never
            // happened.
            FileDurability.removeIfPresent(staging.member(ProjectPackageLayout.crashMarker))
            FileDurability.removeIfPresent(staging.member(ProjectPackageLayout.autosaveDatabase))
            FileDurability.removeIfPresent(staging.member(ProjectPackageLayout.database + "-wal"))
            FileDurability.removeIfPresent(staging.member(ProjectPackageLayout.database + "-shm"))
            // Nor are the databases a recovery parked in the live package part of a
            // version: a slot is the package as the save wrote it, nothing older.
            let stagedRecovery = staging.member(ProjectPackageLayout.recovery)
            for name in FileDurability.directoryEntryNames(at: stagedRecovery)
            where ProjectPackageLayout.isSupersededDatabaseFile(name: name) {
                FileDurability.removeIfPresent(stagedRecovery.appendingPathComponent(name))
            }
            // The live journal at this point ends at `didAtomicReplace` — the save is
            // committed but its last two lines are still to come — and a slot restored by
            // copying it back over the package would have read as a crashed save
            // (BH-604). A slot is a completed save, so its journal says exactly that.
            var journal = RecoveryJournal()
            journal.append(RecoveryJournalEntry(
                token: token, kind: .save, checkpoint: .didComplete,
                detail: "saved version",
                timestamp: PersistenceTimestamp.string(from: environmentClock.now()),
                changeCount: 0
            ))
            let stagedJournal = staging.member(ProjectPackageLayout.recoveryJournal)
            FileDurability.removeIfPresent(stagedJournal)
            try FileDurability.writeNewFile(try journal.encoded(), to: stagedJournal)
            staged = true
        } catch {
            FileDurability.removeIfPresent(staging)
        }

        guard staged else {
            // Nothing rotated; the existing latest/previous slots are intact.
            try? FileDurability.syncDirectory(at: versionsRoot)
            return
        }

        // 2. Only now that a complete new latest is ready, rotate previous ← latest.
        if FileDurability.exists(previous) {
            if (try? FileDurability.rename(previous, to: discard)) == nil {
                FileDurability.removeIfPresent(previous)
            }
        }
        if FileDurability.exists(latest) {
            try? FileDurability.rename(latest, to: previous)
        }

        // 3. Place the staged clone as the new latest (atomic rename on the same volume). If it
        //    cannot be placed, restore the prior latest from `previous` so `latest` still resolves
        //    to a backup rather than to nothing.
        if (try? FileDurability.rename(staging, to: latest)) == nil {
            FileDurability.removeIfPresent(staging)
            if !FileDurability.exists(latest), FileDurability.exists(previous) {
                try? FileDurability.rename(previous, to: latest)
            }
        }

        try? FileDurability.syncDirectory(at: versionsRoot)
        FileDurability.removeIfPresent(discard)
    }

    // MARK: - Digest reuse (IM-006)

    /// The SHA-256 of a PDF member as cloned into the temporary package, reusing the
    /// digest taken at open or at the last save while the live file's identity — device,
    /// inode, size, nanosecond modification time — is the one it was computed over.
    ///
    /// The identity is read *after* the clone: if it still matches, no write reached the
    /// live file between the moment it was hashed and the moment it was cloned, so the
    /// clone carries the hashed bytes. Any mismatch, and any member with no cached
    /// digest, is hashed from the clone the way every member used to be.
    private func memberDigest(of relativePath: String, clonedInto temporaryURL: URL) throws -> String {
        let clonedURL = temporaryURL.member(relativePath)
        if let cached = memberDigests[relativePath],
           let liveIdentity = FileDurability.identity(of: url.member(relativePath)),
           liveIdentity == cached.identity,
           FileDurability.identity(of: clonedURL)?.byteCount == cached.identity.byteCount {
            return cached.sha256
        }
        let sha256 = try FileDurability.sha256(ofFileAt: clonedURL)
        if let identity = FileDurability.identity(of: url.member(relativePath)) {
            memberDigests[relativePath] = MemberDigest(identity: identity, sha256: sha256)
        } else {
            memberDigests[relativePath] = nil
        }
        return sha256
    }

    /// After the swap the live PDFs are the clones the save hashed, under new inodes:
    /// their digests are re-keyed to the identities they now have.
    private func rememberDigests(after integrity: IntegrityRecord) {
        for (relativePath, sha256) in [
            (ProjectPackageLayout.originalPDF, integrity.originalPdfSha256),
            (ProjectPackageLayout.workingPDF, integrity.workingPdfSha256)
        ] {
            if let identity = FileDurability.identity(of: url.member(relativePath)) {
                memberDigests[relativePath] = MemberDigest(identity: identity, sha256: sha256)
            } else {
                memberDigests[relativePath] = nil
            }
        }
    }

    /// Closes an aborted save's journal entry (BH-190): a `save` line with no checkpoint,
    /// so ``RecoveryJournal/saveInFlight`` no longer reads the checkpoint reached before
    /// the refusal as a save that was cut off.
    private func appendSaveAbortJournal(token: String, error: any Error) {
        let reason = (error as? ZPDFPersistenceError).map(String.init(describing:))
            ?? String(describing: error)
        Self.appendJournal(
            at: url,
            token: token,
            kind: .save,
            checkpoint: nil,
            detail: "aborted before the swap: \(reason.prefix(200))",
            timestamp: PersistenceTimestamp.string(from: environmentClock.now()),
            changeCount: changeCount
        )
    }
}
