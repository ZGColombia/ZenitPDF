import Foundation
import GRDB

/// Spec 6.5: autosave, a recovery journal, a last-good manifest, a crash marker, and the
/// three outcomes `Recover`, `Open Read-Only` and `Discard`.
///
/// The invariant that runs through all of it: `documents/original.pdf` is never written,
/// never replaced and never deleted by any recovery path. Recovery only ever swaps
/// `project.sqlite`, only ever for a snapshot that passed `PRAGMA integrity_check`, and
/// only ever after moving the state it supersedes somewhere the user can still get at.
extension ProjectPackage {

    /// What the crash marker holds. Enough to tell the user which session died — and, since
    /// NL-COLLAB-13, whether it died at all.
    ///
    /// The five host fields are optional and additive: a marker written by an older build
    /// decodes with them `nil` and is read exactly as it always was, as crash evidence.
    public struct CrashMarker: Sendable, Hashable, Codable {
        public var processIdentifier: Int32
        public var openedAt: String
        public var appVersion: String
        /// ``SessionHost/machineID`` of the machine that armed the marker.
        public var hostID: String?
        /// ``SessionHost/displayName`` of that machine.
        public var hostName: String?
        /// ``SessionHost/userName`` on that machine.
        public var userName: String?
        /// One per open session; unchanged by the heartbeat and by saves.
        public var sessionID: String?
        /// Refreshed on a timer while the session lives. A fresh heartbeat from another
        /// machine means "open elsewhere", not "crashed".
        public var heartbeatAt: String?

        public init(
            processIdentifier: Int32,
            openedAt: String,
            appVersion: String,
            hostID: String? = nil,
            hostName: String? = nil,
            userName: String? = nil,
            sessionID: String? = nil,
            heartbeatAt: String? = nil
        ) {
            self.processIdentifier = processIdentifier
            self.openedAt = openedAt
            self.appVersion = appVersion
            self.hostID = hostID
            self.hostName = hostName
            self.userName = userName
            self.sessionID = sessionID
            self.heartbeatAt = heartbeatAt
        }

        /// The largest marker read. A real one is a few hundred bytes.
        static let maximumByteCount = 64 * 1024

        /// Reads a marker file. A missing, oversized or unreadable marker is `nil`: its
        /// *presence* is still crash evidence, and the assessment keeps treating it so.
        ///
        /// A symbolic link, FIFO or device is unreadable in that sense (U-098): the cap is
        /// measured on the descriptor, never on the path, so a marker linked to `/dev/zero`
        /// can no longer exhaust memory, nor a FIFO block the open in `open(2)`.
        public static func read(from url: URL) -> CrashMarker? {
            guard FileDurability.exists(url),
                  let data = try? FileDurability.readRegularFile(
                      at: url, limit: maximumByteCount, what: "recovery/crash-marker"
                  )
            else { return nil }
            return try? JSONDecoder().decode(CrashMarker.self, from: data)
        }
    }

    // MARK: - Assessment

    /// Reads the crash evidence a package carries, without modifying anything.
    ///
    /// Safe to call on a package the user has not agreed to touch yet — which matters,
    /// because the read-only outcome exists precisely for the user who wants to look
    /// first. The one thing this does open is the autosave snapshot, read-only, to find
    /// out whether it is worth offering.
    public static func assessRecovery(
        at url: URL,
        environment: PersistenceEnvironment = PersistenceEnvironment()
    ) async throws -> RecoveryAssessment {
        guard FileDurability.exists(url) else {
            throw ZPDFPersistenceError.packageNotFound(path: url.path)
        }
        guard FileDurability.isDirectory(url) else {
            throw ZPDFPersistenceError.packageNotADirectory(path: url.path)
        }

        let markerURL = url.member(ProjectPackageLayout.crashMarker)
        let markerPresent = FileDurability.exists(markerURL)
        // NL-COLLAB-13: a marker whose heartbeat is fresh and whose host is another machine
        // (or another living process on this one) is a session in progress, not a crash.
        let foreign: ForeignSession? = markerPresent
            ? CrashMarker.read(from: markerURL).flatMap {
                ForeignSessionPolicy.foreignSession(
                    in: $0,
                    localHost: environment.sessionHost,
                    localProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                    now: environment.clock.now(),
                    timeToLive: environment.foreignSessionTimeToLive
                )
            }
            : nil
        let journal = RecoveryJournal.read(from: url.member(ProjectPackageLayout.recoveryJournal))

        // Positional (BH-030, BH-190): a save is in flight only when its checkpoint line
        // is the journal's *last* line. A recovery already applied, a session closed
        // cleanly after a refused save, or an autosave taken since are all proof the
        // process went on, and `lastSave` — which scanned back to the newest save line
        // whatever followed it — read every one of them as a crash.
        var interrupted: InterruptedSave?
        if let inFlight = journal.saveInFlight {
            interrupted = InterruptedSave(
                token: inFlight.token, lastCheckpoint: inFlight.checkpoint, timestamp: inFlight.timestamp
            )
        }

        var autosave: AutosaveInfo?
        let autosaveURL = url.member(ProjectPackageLayout.autosaveDatabase)
        if FileDurability.exists(autosaveURL) {
            // The journal's own line first; failing that, the snapshot file's modification
            // time (BH-605). The clock reading at open used to stand in when the journal
            // had lost the line — a corrupt or rotated journal — which told the user the
            // snapshot was taken the moment they opened the project.
            let timestamp = journal.entries.last { $0.kind == .autosave }?.timestamp
                ?? FileDurability.modificationDate(of: autosaveURL).map(PersistenceTimestamp.string(from:))
                ?? PersistenceTimestamp.string(from: environment.clock.now())
            autosave = AutosaveInfo(
                timestamp: timestamp,
                byteCount: FileDurability.byteCount(of: autosaveURL),
                passesIntegrityCheck: databaseHealth(at: autosaveURL) == .sound
            )
        }

        let lastGood = try? ProjectManifest.read(from: url.member(ProjectPackageLayout.lastGoodManifest))

        return RecoveryAssessment(
            crashMarkerPresent: markerPresent,
            interruptedSave: interrupted,
            autosave: autosave,
            lastGoodManifest: lastGood,
            reclaimableLeftovers: leftoverNames(besides: url),
            foreignSession: foreign
        )
    }

    /// What the health probe could establish about a database file.
    ///
    /// Three answers, not two (BH-187): a probe that could not be *made* — no room for
    /// the copy, a scratch directory that refused to be created — says nothing about the
    /// database, and reporting it as damage made `Recover` push aside a sound live
    /// database in favour of an older autosave, dropping every edit committed since.
    public enum DatabaseHealth: Sendable, Hashable {
        /// `quick_check` returned `ok` on a copy.
        case sound
        /// `quick_check` reported damage, or the file could not be opened as a database.
        case damaged
        /// The probe copy could not be made; the database itself was not examined.
        case unknown
    }

    /// Where the health probe stages its copy, per database file. Tests only: a test
    /// answers for its own package, to make the copy impossible and watch what recovery
    /// does about it, and `nil` for everybody else's.
    public nonisolated(unsafe) static var healthProbeScratchDirectoryForTesting:
        (@Sendable (URL) -> URL?)?

    /// The health probe: `PRAGMA quick_check` over a database file, without adopting it
    /// and without touching it.
    ///
    /// Probes a **copy** (CR-81). The old version opened `url` itself read-write: for the live
    /// `project.sqlite`, which has a `-wal` beside it during recovery, that open checkpointed the
    /// database — mutating the file before the user had chosen `Recover`, `Discard` or
    /// `Open Read-Only`, the exact opposite of what the comment promised. A read-only open is not
    /// an option either: a WAL database with a pending log cannot be opened read-only without
    /// writing its `-shm`. So the database and its `-wal` are copied into a scratch directory and
    /// the copy is opened read-write; SQLite recovers and quick-checks the copy while the live
    /// trio stays byte-for-byte as it was.
    ///
    /// `quick_check` rather than `integrity_check`: it catches the structural damage that matters
    /// here and does not walk every index on a multi-gigabyte database while the user waits.
    static func databaseHealth(at url: URL) -> DatabaseHealth {
        guard FileDurability.exists(url) else { return .damaged }
        // Only a regular file is a snapshot of this package (U-098). A symbolic link used to be
        // followed by the clone below, so an autosave linked to a sound database anywhere on
        // the disk was offered as this project's recovery point.
        guard FileDurability.identity(of: url) != nil else { return .damaged }

        // Beside the package first, on its own volume, where `clonefile` is O(1) and
        // costs no space for a multi-gigabyte database; the temporary directory — a
        // different volume for a project on an external disk, hence a full copy — only
        // as the fallback.
        //
        // `stagingDirectory` creates a fresh item-replacement directory on every call, so
        // one made here is this probe's own and goes with it (R-199). The old defer took
        // only the `zpdf-health-` child away and left its empty parent behind — one per
        // autosave tick, since every autosave runs this probe.
        var ownedParent: URL?
        let probeParent: URL
        if let injected = healthProbeScratchDirectoryForTesting?(url) {
            probeParent = injected
        } else if let staging = try? stagingDirectory(appropriateFor: url) {
            probeParent = staging
            ownedParent = staging
        } else {
            probeParent = FileManager.default.temporaryDirectory
        }
        let probeDirectory = probeParent
            .appendingPathComponent("zpdf-health-\(UUID().uuidString)", isDirectory: true)
        defer {
            FileDurability.removeIfPresent(probeDirectory)
            if let ownedParent { FileDurability.removeIfPresent(ownedParent) }
        }
        guard (try? FileDurability.createDirectory(at: probeDirectory)) != nil else { return .unknown }

        let probeURL = probeDirectory.appendingPathComponent("probe.sqlite", isDirectory: false)
        do {
            try FileDurability.cloneItem(at: url, to: probeURL)
            // The `-wal` is copied so a crashed session's committed-but-uncheckpointed frames are
            // recovered in the probe. `-shm` is intentionally not copied: it is a rebuildable
            // index, and SQLite recreates it beside the copy.
            let walURL = URL(fileURLWithPath: url.path + "-wal")
            if FileDurability.exists(walURL) {
                try FileDurability.cloneItem(at: walURL, to: URL(fileURLWithPath: probeURL.path + "-wal"))
            }
        } catch {
            return .unknown
        }
        return quickCheckPasses(at: probeURL) ? .sound : .damaged
    }

    /// `PRAGMA quick_check` on a database file, opened read-write in place. Only ever run
    /// on a probe copy, or on the live database once the user has chosen `Recover` —
    /// the point past which the ordinary open would write to it anyway.
    private static func quickCheckPasses(at url: URL) -> Bool {
        // Hardened like every other connection (S17-06 follow-through): a snapshot inside a
        // package that arrived from outside is no more ours than `project.sqlite` is.
        let configuration = DatabaseTuning.probeConfiguration(readOnly: false)
        guard let queue = try? DatabaseQueue(path: url.path, configuration: configuration) else {
            return false
        }
        let rows = (try? queue.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }) ?? []
        try? queue.close()
        return rows == ["ok"]
    }

    /// The same probe, named for the place it is used: an autosave or a saved version.
    static func snapshotPassesIntegrityCheck(at url: URL) -> Bool {
        databaseHealth(at: url) == .sound
    }

    /// The health probe, exposed so a test can state the precondition it is setting up.
    public static func databaseIsHealthyForTesting(at url: URL) -> Bool {
        databaseHealth(at: url) == .sound
    }

    /// The three-way probe, exposed so a test can see an inconclusive answer for what it is.
    public static func databaseHealthForTesting(at url: URL) -> DatabaseHealth {
        databaseHealth(at: url)
    }

    /// The `latest` version slot's database: inside the package since 12.5, with the
    /// legacy pre-12.5 sibling read as a fallback for packages saved by older builds.
    static func latestVersionDatabaseURL(forPackageAt url: URL) -> URL {
        let internalURL = versionsRootURL(forPackageAt: url)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
            .member(ProjectPackageLayout.database)
        if FileDurability.exists(internalURL) { return internalURL }
        let legacyURL = legacyVersionsRootURL(forPackageAt: url)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
            .member(ProjectPackageLayout.database)
        return FileDurability.exists(legacyURL) ? legacyURL : internalURL
    }

    // MARK: - Leftovers

    static func leftoverNames(besides url: URL) -> [String] {
        let parent = url.deletingLastPathComponent()
        let packageName = url.lastPathComponent
        return FileDurability.directoryEntryNames(at: parent).filter {
            ProjectPackageLayout.isReclaimableLeftover(name: $0, packageName: packageName)
        }
    }

    /// Deletes the temporary and discard siblings a crashed save can strand.
    ///
    /// It never touches the previous-version sibling, and it never touches anything
    /// whose name it did not write itself.
    @discardableResult
    static func reclaimLeftovers(besides url: URL) -> [String] {
        let parent = url.deletingLastPathComponent()
        let names = leftoverNames(besides: url)
        for name in names {
            FileDurability.removeIfPresent(parent.appendingPathComponent(name))
        }
        // Inside the package: a restore staging file a crash left in the root (BH-606)
        // and a version rotation a crash left half-done (BH-603). Both are named by a
        // token nothing will ever ask for again, and both were being cloned into every
        // later save and every saved version.
        for name in FileDurability.directoryEntryNames(at: url)
        where ProjectPackageLayout.isStrandedRestoreFile(name: name) {
            FileDurability.removeIfPresent(url.appendingPathComponent(name))
        }
        let versionsRoot = versionsRootURL(forPackageAt: url)
        for name in FileDurability.directoryEntryNames(at: versionsRoot)
        where ProjectPackageLayout.isStrandedVersionRotation(name: name) {
            FileDurability.removeIfPresent(versionsRoot.appendingPathComponent(name))
        }
        return names
    }

    // MARK: - Decisions

    /// Applies the user's choice, before the database is opened for the session.
    ///
    /// ### What the three outcomes actually mean
    ///
    /// The live `project.sqlite` is edited in place, and SQLite's write-ahead log makes
    /// every committed edit survive a crash on its own. So after a crash the live
    /// database normally already holds everything the user did, and the interesting
    /// question is not "how do we get the work back" but "which state does the user
    /// want".
    ///
    /// - ``RecoveryDecision/recover``: keep everything. The live database is checked and,
    ///   if it is sound, opened as it is — the write-ahead log has already done the work.
    ///   Only when the live database is damaged does the autosave snapshot get adopted,
    ///   and only when that snapshot passes its own check; failing that, the last saved
    ///   version is restored. If none of the three is usable, this throws rather than
    ///   opening something it cannot vouch for.
    /// - ``RecoveryDecision/openReadOnly``: nothing is written at all. Not the crash
    ///   marker, not the journal, not a leftover reclaim. The evidence is left exactly as
    ///   found so the user can look first and choose afterwards.
    /// - ``RecoveryDecision/discard``: throw away everything since the last save. The
    ///   database is restored from the `latest` saved version and the autosave is
    ///   deleted, which leaves the package matching its own integrity record again.
    ///
    /// In all three, `documents/original.pdf` is never touched.
    static func applyRecoveryDecision(
        _ decision: RecoveryDecision,
        at url: URL,
        environment: PersistenceEnvironment
    ) throws {
        guard decision != .openReadOnly else { return }

        let liveURL = url.member(ProjectPackageLayout.database)
        let autosaveURL = url.member(ProjectPackageLayout.autosaveDatabase)
        let latestVersionDatabase = latestVersionDatabaseURL(forPackageAt: url)
        let token = environment.identifiers.nextIdentifier()
        let timestamp = PersistenceTimestamp.string(from: environment.clock.now())

        func note(_ detail: String) {
            appendJournal(
                at: url, token: token, kind: .recovery,
                detail: detail, timestamp: timestamp, changeCount: 0
            )
        }

        switch decision {
        case .openReadOnly:
            return

        case .recover:
            // An inconclusive probe is not damage (BH-187). The user has chosen `Recover`,
            // and the open that follows this decision writes to the live database anyway,
            // so when no copy could be made the live file is checked where it is rather
            // than pushed aside for an older snapshot.
            let liveHealth: DatabaseHealth = {
                let probed = databaseHealth(at: liveURL)
                guard probed == .unknown else { return probed }
                return quickCheckPasses(at: liveURL) ? .sound : .damaged
            }()
            if liveHealth == .sound {
                note("live database sound, kept as is")
                // The snapshot has been superseded by the database it was taken from.
                // Leaving it behind would make every later launch look like a crash.
                if FileDurability.exists(autosaveURL) {
                    FileDurability.removeIfPresent(autosaveURL)
                    note("redundant autosave removed")
                }
            } else if FileDurability.exists(autosaveURL), snapshotPassesIntegrityCheck(at: autosaveURL) {
                note("live database damaged, adopting autosave")
                try replaceLiveDatabase(at: url, with: autosaveURL, move: true, token: token)
                note("autosave adopted")
            } else if FileDurability.exists(latestVersionDatabase),
                      snapshotPassesIntegrityCheck(at: latestVersionDatabase) {
                note("live database and autosave damaged, restoring the last saved version")
                try replaceLiveDatabase(at: url, with: latestVersionDatabase, move: false, token: token)
                note("last saved version restored")
            } else {
                throw ZPDFPersistenceError.recoveryFailed(
                    reason: "neither the project database, the autosave snapshot nor the last "
                        + "saved version passes an integrity check"
                )
            }

        case .discard:
            if FileDurability.exists(latestVersionDatabase),
               snapshotPassesIntegrityCheck(at: latestVersionDatabase) {
                note("discarding unsaved changes, restoring the last saved version")
                try replaceLiveDatabase(at: url, with: latestVersionDatabase, move: false, token: token)
            } else {
                // No saved version to roll back to. Discard cannot honestly return the project to
                // a prior state; the old path silently kept every WAL-committed edit in the live
                // database while telling the user the changes were discarded (CR-86). Refuse, and
                // say why, rather than lie about what happened. `documents/original.pdf` is
                // untouched, as it is on every recovery path.
                throw ZPDFPersistenceError.recoveryFailed(
                    reason: "there is no saved version to discard back to; the project has not been saved"
                )
            }
            if FileDurability.exists(autosaveURL) {
                FileDurability.removeIfPresent(autosaveURL)
                note("autosave discarded")
            }
        }

        // The crashed session's marker is not removed here: the open armed this session's
        // marker over it before the decision was applied (V-088), so from the first rename
        // above to the open's return the package says "a session is in progress", and a crash
        // in between is still read as one.
        try? FileDurability.syncDirectory(at: url.member(ProjectPackageLayout.recovery))
        try? FileDurability.syncDirectory(at: url)
    }

    /// Swaps a snapshot into `project.sqlite`, keeping what it replaced.
    ///
    /// The superseded trio is renamed into `recovery/`, never deleted: if the snapshot
    /// turns out to be worse than what it replaced, the bytes are still on disk. Renames
    /// are atomic, so a crash part-way through leaves either the old database or the new
    /// one in place, and the journal says which step was reached.
    private static func replaceLiveDatabase(
        at url: URL,
        with source: URL,
        move: Bool,
        token: String
    ) throws {
        let liveURL = url.member(ProjectPackageLayout.database)
        let recoveryURL = url.member(ProjectPackageLayout.recovery)
        try FileDurability.createDirectory(at: recoveryURL)

        if FileDurability.exists(liveURL) {
            try FileDurability.rename(
                liveURL,
                to: recoveryURL.appendingPathComponent(
                    ProjectPackageLayout.supersededDatabaseName(token: token), isDirectory: false
                )
            )
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = url.member(ProjectPackageLayout.database + suffix)
            guard FileDurability.exists(sidecar) else { continue }
            try FileDurability.rename(
                sidecar,
                to: recoveryURL.appendingPathComponent(
                    ProjectPackageLayout.supersededDatabaseName(token: token, suffix: suffix),
                    isDirectory: false
                )
            )
        }

        if move {
            try FileDurability.rename(source, to: liveURL)
        } else {
            let staged = url.appendingPathComponent(
                ProjectPackageLayout.restoreStagingName(token: token), isDirectory: false
            )
            FileDurability.removeIfPresent(staged)
            try FileDurability.cloneItem(at: source, to: staged)
            try FileDurability.syncFile(at: staged)
            try FileDurability.rename(staged, to: liveURL)
        }
        try FileDurability.syncFile(at: liveURL)
        try FileDurability.syncDirectory(at: url)
    }

    // MARK: - Crash marker

    /// Journals this session's start. The marker itself is armed by the open before the
    /// handle exists (V-088), in ``armSessionMarker(at:environment:sessionID:)``.
    func journalSessionOpened() {
        appendJournal(kind: .sessionOpened, token: currentProjectId, detail: nil)
    }

    /// What the open found at the marker's path before it armed its own (V-088), so an open
    /// that fails after the arm can put the package back as it found it.
    enum PriorCrashMarker: Sendable {
        case absent
        case bytes(Data)
        /// Present, but not a regular file this build can read back byte for byte.
        case unreadable
    }

    /// Arms a new session's marker on a package about to be opened read-write, and answers
    /// what was there before, with the `openedAt` it recorded.
    ///
    /// V-088: this runs **before anything writes to the package** — before a leftover is
    /// reclaimed, before a recovery decision swaps `project.sqlite`, and before the read-write
    /// pool exists, which changes `project.sqlite` on every open (GRDB creates and drops
    /// `grdb_issue_102` when it finds no write-ahead log). The arm used to come last, after
    /// all of that. A marker that could not be written — a full volume, an SMB hiccup, a
    /// refused create in `recovery/` — then threw out of the open with the pool dropped
    /// without `close()`; its final checkpoint folded the write into `project.sqlite`, nothing
    /// re-recorded the digest, no marker explained the change, and every later read-write
    /// open refused the cleanly closed project as modified outside Zenit PDF. Armed first, a
    /// failed write leaves the package exactly as it was: the write is atomic, so even a
    /// crashed session's marker it was replacing is still in place.
    ///
    /// W-094: atomic up to the rename, not after it. The flush of `recovery/` that follows
    /// the rename can still throw — a `recovery/` this process may search and write but not
    /// read (`everyone deny list`), an SMB mount that refuses `F_FULLFSYNC` on a directory —
    /// and it used to throw with this session's marker already in place over whatever was
    /// there: the next open here read a crash of a session that never wrote, another Mac read
    /// a live session for fifteen minutes, and a crashed session's marker was gone. A throw
    /// now undoes the arm (``undoSessionMarkerArm(at:prior:sessionID:)``) before it leaves.
    ///
    /// X-053: `recovery/` is made first when it is missing. `validateStructure` does not
    /// require it, and nothing else on the open path creates it, so a package without one —
    /// a sent copy unpacked by a tool that drops empty folders, a package kept in version
    /// control, a recovery folder deleted by hand — failed every read-write open with ENOENT
    /// on the marker's temporary file while the read-only open went through. An empty
    /// standard folder is the only thing this adds; it holds no project data.
    static func armSessionMarker(
        at url: URL, environment: PersistenceEnvironment, sessionID: String
    ) throws -> (prior: PriorCrashMarker, openedAt: String) {
        let recoveryURL = url.member(ProjectPackageLayout.recovery)
        if !FileDurability.isDirectory(recoveryURL) {
            try FileDurability.createDirectory(at: recoveryURL)
            try? FileDurability.syncDirectory(at: url)
        }
        let markerURL = url.member(ProjectPackageLayout.crashMarker)
        let prior: PriorCrashMarker
        var status = stat()
        if lstat(markerURL.path, &status) != 0, errno == ENOENT {
            prior = .absent
        } else if let data = try? FileDurability.readRegularFile(
            at: markerURL, limit: CrashMarker.maximumByteCount, what: "recovery/crash-marker"
        ) {
            prior = .bytes(data)
        } else {
            prior = .unreadable
        }
        let openedAt = PersistenceTimestamp.string(from: environment.clock.now())
        do {
            try writeCrashMarker(
                crashMarker(environment: environment, sessionID: sessionID, openedAt: openedAt),
                into: url, token: sessionID
            )
        } catch {
            undoSessionMarkerArm(at: markerURL, prior: prior, sessionID: sessionID)
            throw error
        }
        return (prior, openedAt)
    }

    /// Takes back an arm whose write threw (W-094). Nothing else has written to the package
    /// yet, so the package goes back to exactly what the arm found.
    ///
    /// Only when this session's marker actually landed: a write that failed before its rename
    /// left the previous marker, or none, in place, and there is nothing to undo. A marker
    /// that was there is put back byte for byte; where there was none, this session's comes
    /// down. One the arm could not read back has no bytes to restore, and this session's
    /// marker stays in its place — its presence is crash evidence either way.
    static func undoSessionMarkerArm(at markerURL: URL, prior: PriorCrashMarker, sessionID: String) {
        guard CrashMarker.read(from: markerURL)?.sessionID == sessionID else { return }
        switch prior {
        case .bytes(let data):
            // The bytes are back once the rename has run; the directory flush that may throw
            // again after it is best effort here, as in `close()` and the heartbeat.
            try? FileDurability.writeFileAtomically(data, to: markerURL, token: sessionID)
        case .absent:
            FileDurability.removeIfPresent(markerURL)
            try? FileDurability.syncDirectory(at: markerURL.deletingLastPathComponent())
        case .unreadable:
            return
        }
    }

    /// Stands down the marker of an open that failed after arming it (V-088).
    ///
    /// A marker that was there before is put back byte for byte — a crashed session's, or a
    /// live one's on another Mac — so the evidence reads exactly as it did. Where there was
    /// none, this session's marker comes down only while `project.sqlite` still matches its
    /// record: then the package is as it was found. When it does not match — the recovery
    /// decision swapped it, or the read-write pool wrote to it before the open failed — the
    /// marker stays armed on purpose, so the next open reads the change as crash evidence and
    /// offers recovery, instead of refusing the project as modified outside Zenit PDF. The
    /// rule is the one ``close()`` follows when it cannot refresh the record.
    static func standDownSessionMarker(
        at url: URL, prior: PriorCrashMarker, integrity: IntegrityRecord, sessionID: String
    ) {
        let markerURL = url.member(ProjectPackageLayout.crashMarker)
        switch prior {
        case .bytes(let data):
            if (try? FileDurability.writeFileAtomically(data, to: markerURL, token: sessionID)) != nil { return }
        case .absent:
            let digest = try? FileDurability.sha256(ofFileAt: url.member(ProjectPackageLayout.database))
            guard digest == integrity.databaseSha256 else { return }
            FileDurability.removeIfPresent(markerURL)
            try? FileDurability.syncDirectory(at: url.member(ProjectPackageLayout.recovery))
        case .unreadable:
            return
        }
    }

    /// Refreshes the marker's heartbeat, so another machine reading the package through a
    /// shared folder sees a live session rather than a crash (NL-COLLAB-13).
    ///
    /// Answers `false` once there is nothing to beat for — a closed or read-only handle — so
    /// the caller's timer can stop. This package holds no timers itself.
    ///
    /// A beat that fails to write still answers `true` (U-097). The failure is transient by
    /// nature — an SMB hiccup, a full disk, an `fsync` refused by a network mount — and the
    /// previous marker is still in place, because the write is atomic; the next tick tries
    /// again. Answering `false` used to end the caller's loop for the rest of the session,
    /// and after the time-to-live the stale marker read as a crash on every other Mac.
    @discardableResult
    public func refreshSessionHeartbeat() async -> Bool {
        guard !isClosed, accessMode == .readWrite else { return false }
        await drainActiveSave()
        guard !isClosed else { return false }
        try? writeCrashMarker(into: url)
        return true
    }

    /// What a session's marker says. One builder for the open, which arms the marker before
    /// the handle exists (V-088), and for every rewrite after it — the heartbeat, the save and
    /// the autosave — which keep the session's identity and `openedAt` unchanged.
    static func crashMarker(
        environment: PersistenceEnvironment, sessionID: String, openedAt: String?
    ) -> CrashMarker {
        let now = PersistenceTimestamp.string(from: environment.clock.now())
        let host = environment.sessionHost
        return CrashMarker(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            openedAt: openedAt ?? now,
            appVersion: environment.appVersion,
            hostID: host.machineID,
            hostName: host.displayName,
            userName: host.userName,
            sessionID: sessionID,
            heartbeatAt: now
        )
    }

    /// Writes a marker into a package root — the live one, or the temporary one the save
    /// pipeline is building.
    ///
    /// Through a temporary sibling and a rename (U-097), so a write that fails leaves the
    /// previous marker exactly where it was. It used to remove the marker first and then
    /// create a new one: a failed create left the package with no marker at all, and another
    /// Mac opened it read-write with no "open elsewhere" warning over a live session. Same two
    /// device flushes as before — the temporary file, then `recovery/`.
    static func writeCrashMarker(_ marker: CrashMarker, into packageRoot: URL, token: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(marker)) ?? Data("{}".utf8)
        let markerURL = packageRoot.member(ProjectPackageLayout.crashMarker)
        try FileDurability.writeFileAtomically(data, to: markerURL, token: token)
    }

    /// Rewrites this session's marker into a package root, with a fresh heartbeat.
    func writeCrashMarker(into packageRoot: URL) throws {
        try Self.writeCrashMarker(
            Self.crashMarker(environment: environment, sessionID: sessionIdentifier, openedAt: sessionOpenedAt),
            into: packageRoot, token: sessionIdentifier
        )
    }

    // MARK: - Autosave

    /// Writes a crash-recoverable snapshot of the database into `recovery/`.
    ///
    /// Autosave is deliberately *not* a save: it never touches `manifest.json`, never
    /// touches the PDFs, never bumps a version and never resets the change count. It
    /// writes one file, fsyncs it, and renames it into place, so the snapshot on disk is
    /// always a complete database and never a partial one.
    ///
    /// Call it on a timer owned by the app layer — this package holds no timers, because
    /// a timer inside a document is a source of non-determinism a test cannot pin.
    @discardableResult
    public func writeAutosave() async throws -> AutosaveInfo {
        guard accessMode == .readWrite else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        // Behind an in-flight save, like every other write: the pipeline closes the
        // handle around the swap, and a snapshot of the package it is retiring is a
        // snapshot of nothing.
        await drainActiveSave()
        let token = environmentIdentifiers.nextIdentifier()
        let timestamp = PersistenceTimestamp.string(from: environmentClock.now())

        let recoveryURL = url.member(ProjectPackageLayout.recovery)
        let temporaryURL = recoveryURL.appendingPathComponent(".autosave-\(token).tmp", isDirectory: false)
        FileDurability.removeIfPresent(temporaryURL)
        // Through SQLite's online backup, from one read snapshot (BH-189). The old path
        // truncated the WAL and then streamed `project.sqlite` byte by byte with the
        // pool open and auto-checkpoint on: a commit landing during the copy could fold
        // new pages into the main file while earlier pages had already been read, and
        // the snapshot mixed two generations in a way `quick_check` cannot see.
        do {
            try await databaseHandle.backup(to: temporaryURL)
        } catch {
            FileDurability.removeIfPresent(temporaryURL)
            throw error
        }
        try FileDurability.syncFile(at: temporaryURL)
        let destination = url.member(ProjectPackageLayout.autosaveDatabase)
        try FileDurability.rename(temporaryURL, to: destination)
        try FileDurability.syncDirectory(at: recoveryURL)

        // Check the snapshot now, while it is fresh, rather than guessing at its worth
        // after a crash.
        let healthy = Self.snapshotPassesIntegrityCheck(at: destination)
        appendJournal(kind: .autosave, token: token, detail: healthy ? "snapshot" : "snapshot (unsound)")
        // An autosave is proof of life too (NL-COLLAB-13).
        try? writeCrashMarker(into: url)
        return AutosaveInfo(
            timestamp: timestamp,
            byteCount: FileDurability.byteCount(of: destination),
            passesIntegrityCheck: healthy
        )
    }

    // MARK: - Journal

    func appendJournal(kind: JournalEventKind, token: String, detail: String?) {
        Self.appendJournal(
            at: url,
            token: token,
            kind: kind,
            detail: detail,
            timestamp: PersistenceTimestamp.string(from: environmentClock.now()),
            changeCount: changeCount
        )
    }

    package func appendSaveJournal(token: String, checkpoint: SaveCheckpoint, detail: String? = nil) {
        Self.appendJournal(
            at: url,
            token: token,
            kind: .save,
            checkpoint: checkpoint,
            detail: detail,
            timestamp: PersistenceTimestamp.string(from: environmentClock.now()),
            changeCount: changeCount
        )
    }

    /// Appends one line, durably.
    ///
    /// The save pipeline needs each journal line on the platter *before* the step it
    /// announces, or a crash during that step leaves no evidence of it. The atomic write
    /// already guarantees that: `F_FULLFSYNC` on the temporary file, the rename onto
    /// `journal.json`, `F_FULLFSYNC` on `recovery/` — two device flushes per line. Every line
    /// takes that path, not only the save's: the journal is rewritten whole, so a line written
    /// less carefully could lose the durable lines before it.
    ///
    /// T-084: the save's lines used to be flushed a second time — the same inode and the same
    /// directory, four device flushes where two do the job, about 26 redundant `F_FULLFSYNC`
    /// per save on the ~13 checkpoint lines.
    @discardableResult
    static func appendJournal(
        at url: URL,
        token: String,
        kind: JournalEventKind,
        checkpoint: SaveCheckpoint? = nil,
        detail: String?,
        timestamp: String,
        changeCount: Int
    ) -> Bool {
        let journalURL = url.member(ProjectPackageLayout.recoveryJournal)
        var journal = RecoveryJournal.read(from: journalURL)
        journal.append(RecoveryJournalEntry(
            token: token, kind: kind, checkpoint: checkpoint,
            detail: detail, timestamp: timestamp, changeCount: changeCount
        ))
        guard let data = try? journal.encoded() else { return false }
        do {
            try FileDurability.writeFileAtomically(data, to: journalURL, token: token)
            return true
        } catch {
            // A journal that cannot be written is a degraded recovery story, not a
            // reason to fail the user's save. The save itself is still atomic.
            return false
        }
    }
}
