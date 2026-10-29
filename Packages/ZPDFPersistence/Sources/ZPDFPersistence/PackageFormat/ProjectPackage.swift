import Foundation
import GRDB

/// A `.zpdfproj` document package: the database, the drawings, and the crash-safe
/// machinery that gets a change from memory onto a platter without a window in which
/// the user's project is neither the old thing nor the new thing.
public actor ProjectPackage {

    /// Whether this handle may write.
    public enum AccessMode: String, Sendable, Hashable {
        case readWrite
        case readOnly
    }

    /// What a completed save produced.
    public struct SaveReceipt: Sendable, Hashable {
        public let token: String
        public let manifest: ProjectManifest
        public let integrity: IntegrityRecord
        /// A clone of the package exactly as this save wrote it, or `nil` when the version
        /// rotation could not produce one (CR-82). The save itself has still committed; only the
        /// backup is absent, and the receipt says so honestly rather than naming a slot that does
        /// not exist.
        public let latestVersionURL: URL?
        /// A clone of the package as the previous save wrote it, once there is one.
        public let previousVersionURL: URL?
        /// Zero. A save is the definition of "no unsaved changes".
        public let changeCount: Int
        public let databaseByteCount: Int
        /// Whether the `fsync` of the *parent directory* after the atomic swap succeeded.
        ///
        /// The swap makes the new package visible; the parent directory's `fsync` is what
        /// makes that visibility survive a power cut. Every other sync in the pipeline
        /// happens before the swap and therefore says nothing about the swap itself.
        ///
        /// It is reported rather than thrown because by the time it runs the user's work
        /// is already committed — the on-disk state is whole either way, and failing the
        /// save here would tell the user their work was lost when it was not. `false`
        /// means "saved, but a power cut in the next moment could roll the directory
        /// entry back to the previous save". A caller that must not lose the save can
        /// retry the sync or warn.
        public let directorySyncConfirmed: Bool
    }

    /// The result of verifying a package on disk against its own integrity record.
    ///
    /// Read off the open path's own verdict (V-095), so a package this calls consistent is
    /// one the next ``open(at:environment:)`` accepts without a word, and nothing else.
    public struct IntegrityVerification: Sendable, Hashable {
        public let manifest: ProjectManifest
        public let integrity: IntegrityRecord
        /// What the open path concludes about the package as it stands, taken as carrying no
        /// crash evidence — so any difference at all is a mismatch.
        public let verdict: IntegrityVerdict

        public var manifestHashMatches: Bool { matches(ProjectPackageLayout.manifest) }
        public var databaseHashMatches: Bool { matches(ProjectPackageLayout.database) }
        public var originalPDFHashMatches: Bool { matches(ProjectPackageLayout.originalPDF) }
        public var workingPDFHashMatches: Bool { matches(ProjectPackageLayout.workingPDF) }

        /// Every member the open path compares matches: the four the record names, the drawings
        /// added after creation and the stored revisions (S-120).
        public var isFullyConsistent: Bool { verdict.isVerified }

        private func matches(_ member: String) -> Bool { !verdict.mismatchedMembers.contains(member) }
    }

    // MARK: Stored state

    /// The package directory. Stable for the lifetime of the handle: the save swaps the
    /// directory's *contents*, never its name.
    public nonisolated let url: URL
    public nonisolated let accessMode: AccessMode

    let environment: PersistenceEnvironment
    /// The database handle. One actor for the whole session (R-186): a save suspends and
    /// reopens the pool inside it, and a reopen that failed after the swap (BH-185) is retried
    /// by the actor itself on the next access.
    let databaseHandle: ProjectDatabaseActor
    var currentManifest: ProjectManifest
    var currentIntegrity: IntegrityRecord?
    /// What ``verifyAgainstIntegrityRecordCollectingDigests(at:integrity:carriesCrashEvidence:)`` concluded
    /// at open (S17-07). Always ``IntegrityVerdict/Outcome/verified`` on a read-write
    /// handle — anything else is a refusal there — and the evidence a read-only caller
    /// shows the user about the project it just let them look at.
    var currentIntegrityVerdict: IntegrityVerdict
    var currentChangeCount: Int
    var isClosed = false
    /// The scratch directory of a read-only handle's migrated database copy (R-197), removed
    /// at ``close()``. `nil` when the handle reads the package's own `project.sqlite`.
    var readOnlyScratchDirectory: URL?
    /// The save pipeline in flight, if any, with a generation so a waiter can tell
    /// "the task I awaited finished" from "another save has started since".
    ///
    /// This exists because the actor is reentrant: `save(hooks:)` suspends many times,
    /// and without it a `close()` arriving between two of those suspensions would run
    /// in the *middle* of the pipeline — its `session-closed` journal line and marker
    /// removal landing in the package the atomic swap is about to retire, after which
    /// step 9 re-arms the crash marker and the process exits claiming a crash that
    /// never happened (the save-then-quit false recovery prompt).
    var activeSave: (generation: Int, task: Task<SaveReceipt, any Error>)?
    var saveGeneration = 0

    /// The digests of the two PDFs, keyed by package-relative path, with the identity
    /// of the bytes each was computed over (IM-006).
    ///
    /// Seeded at open from the S17-07 verification (which hashes both PDFs anyway) and
    /// at create. The save pipeline reuses a digest only while the live member's
    /// device, inode, size and nanosecond modification time are the ones recorded; a
    /// page operation rewriting `working.pdf`, or any editor touching `original.pdf`,
    /// changes at least one of them and forces a fresh hash. `project.sqlite` and
    /// `manifest.json` are never cached: they change on every save by definition.
    var memberDigests: [String: MemberDigest] = [:]

    /// This session's identity in the crash marker, and when it opened (NL-COLLAB-13). The
    /// heartbeat and every save rewrite the marker with these two unchanged. Chosen by the
    /// open, which arms the marker before this handle exists (V-088).
    let sessionIdentifier: String
    let sessionOpenedAt: String?

    /// Awaits the in-flight save pipeline, if any, including one started while waiting.
    func drainActiveSave() async {
        while let inFlight = activeSave {
            let generation = inFlight.generation
            _ = try? await inFlight.task.value
            if activeSave?.generation == generation { activeSave = nil }
        }
    }

    private init(
        url: URL,
        accessMode: AccessMode,
        environment: PersistenceEnvironment,
        database: ProjectDatabaseActor,
        manifest: ProjectManifest,
        integrity: IntegrityRecord?,
        integrityVerdict: IntegrityVerdict,
        memberDigests: [String: MemberDigest] = [:],
        sessionIdentifier: String,
        sessionOpenedAt: String?
    ) {
        self.url = url
        self.accessMode = accessMode
        self.environment = environment
        self.databaseHandle = database
        self.currentManifest = manifest
        self.currentIntegrity = integrity
        self.currentIntegrityVerdict = integrityVerdict
        self.currentChangeCount = 0
        self.memberDigests = memberDigests
        self.sessionIdentifier = sessionIdentifier
        self.sessionOpenedAt = sessionOpenedAt
    }

    // MARK: - Accessors

    public var manifest: ProjectManifest { currentManifest }
    public var integrity: IntegrityRecord? { currentIntegrity }

    /// The S17-07 verdict this package was opened under.
    public var integrityVerdict: IntegrityVerdict { currentIntegrityVerdict }

    /// The S17-09 schema deviations this package was opened under.
    ///
    /// Empty on a read-write handle. Non-empty only on the read-only escape hatch, where
    /// a project the schema guard refuses can still be inspected safely.
    public var schemaDeviations: [ProjectSchemaInventory.Deviation] {
        databaseHandle.schemaDeviations
    }

    /// The NSDocument-style change count: edits since the last save.
    ///
    /// This package does not import AppKit, so it keeps the number and the app layer
    /// mirrors it into `NSDocument.updateChangeCount(_:)`. A save sets it to zero, which
    /// is the only definition of "saved" the rest of the app should trust.
    public var changeCount: Int { currentChangeCount }

    /// The live database handle, the same actor for as long as this package is open.
    ///
    /// Safe to cache across saves (R-186). The pipeline still closes the *pool* before it
    /// swaps the package directory, because an open file descriptor keeps pointing at the
    /// *old* inode after a `RENAME_SWAP` and every write through it would land in the
    /// discarded copy — but it does so inside this actor and reopens it on the new
    /// package, holding every other caller's writes from the commit stamp to the reopen.
    /// The old pipeline installed a new actor instead, and the History feed, Review and
    /// Ledger Snapshots, which fetch this once at mount, wrote into a closed handle from
    /// the first save on.
    public var database: ProjectDatabaseActor { databaseHandle }

    // Internal accessors, so the save and recovery extensions in other files can reach
    // the injected environment without making it public API.
    var environmentClock: any PersistenceClock { environment.clock }
    var environmentIdentifiers: any IdentifierGenerator { environment.identifiers }
    var currentProjectId: String { currentManifest.projectId }

    /// The directory holding the saved versions of this package — `versions/` inside the
    /// package since the 12.5 fix, so a powerbox grant on the package covers it.
    public nonisolated var versionsRootURL: URL {
        url.member(ProjectPackageLayout.versions)
    }

    /// The package as the most recent completed save wrote it, if there has been one.
    public nonisolated var latestVersionURL: URL {
        versionsRootURL.appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
    }

    /// The package as the save before that wrote it, if there has been one.
    public nonisolated var previousVersionURL: URL {
        versionsRootURL.appendingPathComponent(ProjectPackageLayout.previousVersion, isDirectory: true)
    }

    /// Static form, for callers that have a path but no open package.
    public nonisolated static func versionsRootURL(forPackageAt url: URL) -> URL {
        url.member(ProjectPackageLayout.versions)
    }

    /// The legacy pre-12.5 sibling versions directory, read as a recovery fallback for
    /// packages last saved by an older build. Never written to.
    nonisolated static func legacyVersionsRootURL(forPackageAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ProjectPackageLayout.versionsName(for: url.lastPathComponent), isDirectory: true
        )
    }

    /// Where a save or create stages its temporary package — never as a sibling, which the
    /// App Sandbox's save-panel grant does not cover.
    ///
    /// `FileManager.url(for: .itemReplacementDirectory, appropriateFor:)` is designed for
    /// exactly this: it returns a writable directory *on the same volume* as the
    /// destination, which is what keeps the final rename atomic, and it is always
    /// writable relative to a powerbox-granted URL — unlike a hidden sibling, which the
    /// sandbox rightly refuses. The destination itself may not exist yet (first create),
    /// so its parent is offered as a fallback anchor.
    nonisolated static func stagingDirectory(appropriateFor destination: URL) throws -> URL {
        for anchor in [destination, destination.deletingLastPathComponent()] {
            if let staging = try? FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: anchor,
                create: true
            ) {
                return staging
            }
        }
        throw ZPDFPersistenceError.temporaryPackageWriteFailed(
            reason: "no item replacement directory for \(destination.lastPathComponent)"
        )
    }

    /// One edit happened.
    public func registerEdit(count: Int = 1) {
        currentChangeCount += max(0, count)
    }

    /// Convenience forwarding so callers do not have to hold the database handle.
    public func read<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await databaseHandle.read(body)
    }

    /// A write, committed when `body` returns.
    ///
    /// A write that arrives while a save pipeline is in flight **waits for the save**
    /// (BH-029). The actor is reentrant and the pipeline suspends at every checkpoint,
    /// so without the wait a row could commit into the database the pipeline had already
    /// streamed into the temporary package: step 7 would fold it into the *old* file,
    /// the swap would retire that file, and step 8 would delete it — a write that
    /// returned success and left nothing behind. After the wait the row lands in the
    /// swapped-in database, where the next save finds it.
    public func write<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard accessMode == .readWrite else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        await drainActiveSave()
        let result = try await databaseHandle.write(body)
        currentChangeCount += 1
        return result
    }

    // MARK: - Create

    /// Builds a new package around an existing PDF.
    ///
    /// The PDF is *copied into* the package and then made read-only. From this moment
    /// the original is evidence: nothing in this package ever opens
    /// `documents/original.pdf` for writing, and the save pipeline carries it forward by
    /// cloning (`clonefile(2)`, a full copy only on a volume that cannot clone) so that
    /// not even a byte-identical rewrite occurs.
    /// `documents/working.pdf` is the copy that may be flattened, rotated or annotated.
    ///
    /// The package is built in a hidden sibling and renamed into place, so an
    /// interrupted create leaves a leftover to reclaim rather than a half-package that
    /// looks openable.
    public static func create(
        at url: URL,
        displayName: String,
        originalPDF: URL,
        pageCount: Int = 0,
        environment: PersistenceEnvironment = PersistenceEnvironment()
    ) async throws -> ProjectPackage {
        guard !FileDurability.exists(url) else {
            throw ZPDFPersistenceError.packageAlreadyExists(path: url.path)
        }
        guard FileDurability.exists(originalPDF) else {
            throw ZPDFPersistenceError.packageNotFound(path: originalPDF.path)
        }

        let parent = url.deletingLastPathComponent()
        let packageName = url.lastPathComponent
        let token = environment.identifiers.nextIdentifier()
        // Staged in the item replacement directory, never as a sibling: under the App
        // Sandbox a save panel's grant covers the chosen URL and nothing next to it
        // Same volume, so the rename into place stays atomic.
        let buildURL = try stagingDirectory(appropriateFor: url).appendingPathComponent(
            ProjectPackageLayout.temporaryName(for: packageName, token: token),
            isDirectory: true
        )
        FileDurability.removeIfPresent(buildURL)

        do {
            try FileDurability.createDirectory(at: buildURL)
            for directory in ProjectPackageLayout.directories {
                try FileDurability.createDirectory(at: buildURL.member(directory))
            }

            let originalDestination = buildURL.member(ProjectPackageLayout.originalPDF)
            try FileDurability.cloneItem(at: originalPDF, to: originalDestination)
            try FileDurability.makeReadOnly(originalDestination)
            let originalHash = try FileDurability.sha256(ofFileAt: originalDestination)

            // The working copy starts as a clone of the original: copy-on-write, so it
            // costs nothing until something actually edits it.
            let workingDestination = buildURL.member(ProjectPackageLayout.workingPDF)
            try FileDurability.cloneItem(at: originalDestination, to: workingDestination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: workingDestination.path
            )

            let now = environment.clock.now()
            let timestamp = PersistenceTimestamp.string(from: now)
            let projectId = environment.identifiers.nextIdentifier()
            let documentId = environment.identifiers.nextIdentifier()

            let database = try await ProjectDatabaseActor.open(
                at: buildURL.member(ProjectPackageLayout.database),
                tuning: environment.tuning
            )
            try await database.write { db in
                try ProjectRecord(
                    id: projectId,
                    name: displayName,
                    createdAt: timestamp,
                    modifiedAt: timestamp,
                    schemaVersion: ProjectSchema.currentVersion
                ).insert(db)
                try DocumentRecord(
                    id: documentId,
                    projectId: projectId,
                    displayName: originalPDF.lastPathComponent,
                    relativePath: ProjectPackageLayout.originalPDF,
                    sha256: originalHash,
                    pageCount: pageCount,
                    createdAt: timestamp,
                    modifiedAt: timestamp
                ).insert(db)
            }
            try await database.checkpoint(.truncate)
            try await database.close()

            let manifest = ProjectManifest(
                projectId: projectId,
                displayName: displayName,
                createdAt: timestamp,
                modifiedAt: timestamp,
                appVersion: environment.appVersion,
                databaseSchema: ProjectSchema.currentVersion,
                originalPdfSha256: originalHash,
                workingPdfSha256: originalHash,
                minimumReaderVersion: environment.minimumReaderVersion
            )
            let manifestData = try manifest.encoded()
            try FileDurability.writeNewFile(manifestData, to: buildURL.member(ProjectPackageLayout.manifest))
            try FileDurability.writeNewFile(
                manifestData, to: buildURL.member(ProjectPackageLayout.lastGoodManifest)
            )

            let integrity = IntegrityRecord(
                manifestSha256: FileDurability.sha256(of: manifestData),
                databaseSha256: try FileDurability.sha256(
                    ofFileAt: buildURL.member(ProjectPackageLayout.database)
                ),
                originalPdfSha256: originalHash,
                workingPdfSha256: originalHash,
                saveToken: token,
                savedAt: timestamp,
                generation: 1
            )
            try FileDurability.writeNewFile(
                try integrity.encoded(), to: buildURL.member(ProjectPackageLayout.integrity)
            )

            var journal = RecoveryJournal()
            journal.append(RecoveryJournalEntry(
                token: token, kind: .save, checkpoint: .didComplete,
                detail: "create", timestamp: timestamp, changeCount: 0
            ))
            try FileDurability.writeNewFile(
                try journal.encoded(), to: buildURL.member(ProjectPackageLayout.recoveryJournal)
            )

            try FileDurability.syncTree(at: buildURL)
            try FileDurability.rename(buildURL, to: url)
            FileDurability.removeIfPresent(buildURL.deletingLastPathComponent())
            // Best effort: under the sandbox the powerbox grant covers the created item,
            // not its parent directory, so the parent may refuse to be opened for the
            // fsync. The package itself is already fully synced; what a failure here
            // costs is only the directory entry's durability against an immediate power
            // cut, and failing the create over that would delete a package that exists.
            try? FileDurability.syncDirectory(at: parent)
        } catch {
            FileDurability.removeIfPresent(buildURL)
            // Its item-replacement parent was made for this create alone (R-199).
            FileDurability.removeIfPresent(buildURL.deletingLastPathComponent())
            throw error
        }

        switch try await open(at: url, environment: environment) {
        case let .opened(package):
            return package
        case let .recoveryRequired(assessment), let .openElsewhere(_, assessment):
            // Cannot happen: the package was just written clean. Reported rather than
            // trapped, because "cannot happen" is not a durability guarantee.
            throw ZPDFPersistenceError.recoveryDecisionRequired(assessment: assessment)
        }
    }

    // MARK: - Open

    /// Opens a package, or reports that the user has to choose a recovery outcome first.
    public static func open(
        at url: URL,
        environment: PersistenceEnvironment = PersistenceEnvironment()
    ) async throws -> OpenOutcome {
        let assessment = try await assessRecovery(at: url, environment: environment)
        if assessment.isClean {
            let package = try await openResolved(
                at: url, environment: environment, decision: .discard, assessment: assessment
            )
            return .opened(package)
        }
        // NL-COLLAB-13: checked before crash evidence, and instead of it. A session alive on
        // another Mac is not a crash, and offering Recover or Discard over it is how one
        // person's save overwrites another's.
        if let foreign = assessment.foreignSession {
            return .openElsewhere(foreign, assessment)
        }
        return .recoveryRequired(assessment)
    }

    /// Opens a package that ``open(at:environment:)`` reported as open elsewhere.
    ///
    /// - ``ForeignSessionDecision/openReadOnly``: nothing is written, exactly the recovery
    ///   flow's read-only escape hatch.
    /// - ``ForeignSessionDecision/openAnyway``: read-write, **no recovery step** — the other
    ///   session's autosave and journal are left alone, because they belong to a session that
    ///   is alive — and this session's marker replaces the other one.
    /// - ``ForeignSessionDecision/cancel``: throws `CancellationError`.
    ///
    /// If the marker has gone stale or been cleared since the first assessment, the package
    /// is assessed again and opened as that assessment says; a crash that surfaced in the
    /// meantime still needs its own decision and is reported as
    /// ``ZPDFPersistenceError/recoveryDecisionRequired(assessment:)``.
    public static func open(
        at url: URL,
        environment: PersistenceEnvironment = PersistenceEnvironment(),
        foreignSession decision: ForeignSessionDecision
    ) async throws -> ProjectPackage {
        if decision == .cancel { throw CancellationError() }
        let assessment = try await assessRecovery(at: url, environment: environment)
        if decision == .openReadOnly {
            return try await openResolved(
                at: url, environment: environment, decision: .openReadOnly, assessment: assessment
            )
        }
        if assessment.foreignSession == nil, !assessment.isClean {
            throw ZPDFPersistenceError.recoveryDecisionRequired(assessment: assessment)
        }
        return try await openResolved(
            at: url, environment: environment, decision: .discard, assessment: assessment,
            applyingRecoveryDecision: false
        )
    }

    /// Opens a package having been told what to do about the crash evidence.
    public static func open(
        at url: URL,
        environment: PersistenceEnvironment = PersistenceEnvironment(),
        resolving decision: RecoveryDecision
    ) async throws -> ProjectPackage {
        let assessment = try await assessRecovery(at: url, environment: environment)
        return try await openResolved(
            at: url, environment: environment, decision: decision, assessment: assessment
        )
    }

    private static func openResolved(
        at url: URL,
        environment: PersistenceEnvironment,
        decision: RecoveryDecision,
        assessment: RecoveryAssessment,
        applyingRecoveryDecision: Bool = true
    ) async throws -> ProjectPackage {
        try validateStructure(at: url)
        let manifest = try ProjectManifest.read(from: url.member(ProjectPackageLayout.manifest))
        // Bounds the two version numbers and, since S17-08, the coordinate system. This
        // runs first because a manifest we cannot interpret makes every later question
        // about the package moot.
        try manifest.assertReadable()

        let readOnly = decision == .openReadOnly

        // S17-07. Before the recovery decision is applied — that step rewrites
        // `project.sqlite` — and before SQLite is handed the file for writing, because the
        // whole point is to know whether these are the bytes the package claims.
        let integrity = try IntegrityRecord.read(from: url.member(ProjectPackageLayout.integrity))
        let verified = verifyAgainstIntegrityRecordCollectingDigests(
            at: url, integrity: integrity, carriesCrashEvidence: !assessment.isClean
        )
        var verdict = verified.verdict
        let digests = verified.digests
        // S-120. The drawings added after creation and the stored revisions, against the
        // digests their rows record. Read through a read-only probe of the same file, so the
        // refusal below still comes before anything writes to the package: opening the pool
        // read-write moves `project.sqlite` away from its record, and a refused open must
        // leave the package as it found it.
        let setMismatches = drawingSetMismatches(at: url, databaseAt: url.member(ProjectPackageLayout.database))
        if !setMismatches.isEmpty { verdict = verdict.addingModified(setMismatches) }
        // Read-only is the escape hatch and is deliberately not refused: a user whose project
        // has been altered still needs to be able to look at it, and nothing in a read-only
        // session adopts, rewrites or executes any of it. Which mismatches a read-write open
        // refuses is one rule, shared with `zenit verify` (V-094).
        if !readOnly, let refusal = verdict.refusal(carriesCrashEvidence: !assessment.isClean) {
            throw refusal
        }
        // V-088. Armed before anything below writes to the package — the leftover reclaim,
        // the recovery decision and, above all, the read-write pool, which changes
        // `project.sqlite` on every open. A marker that cannot be written now throws with the
        // package exactly as it was found.
        let sessionIdentifier = UUID().uuidString
        let armed = readOnly
            ? nil
            : try armSessionMarker(at: url, environment: environment, sessionID: sessionIdentifier)
        do {
            if !readOnly {
                // A crashed save can strand a sibling. It is only ever a temporary or a
                // discard directory of *this* package, never a saved version.
                // Not when opening over a live session elsewhere (NL-COLLAB-13): a temporary
                // sibling may be that session's save in flight.
                if applyingRecoveryDecision { reclaimLeftovers(besides: url) }
                // A decision is only applied when there is something to decide about.
                // `discard` on a cleanly closed project must not roll the database back to
                // the last save — there is nothing unsaved, and the ordinary open path
                // passes `discard` precisely because it means "nothing to recover".
                if !assessment.isClean, applyingRecoveryDecision {
                    try applyRecoveryDecision(decision, at: url, environment: environment)
                }
            }

            // R-197. A read-only handle never migrates the package's own file, so a project last
            // written by an older build used to open with tables missing, and every reader that
            // assumes the current schema — the takeoff archive's companion tables, the CLI, the
            // application's Open Read-Only — failed on "no such table". It reads a migrated
            // private copy instead; the package's bytes stay exactly as they were.
            var databaseURL = url.member(ProjectPackageLayout.database)
            var readOnlyScratch: URL?
            if readOnly, let migrated = await migratedReadOnlyCopy(of: databaseURL, package: url, tuning: environment.tuning) {
                databaseURL = migrated.database
                readOnlyScratch = migrated.scratch
            }
            let database: ProjectDatabaseActor
            do {
                database = try await ProjectDatabaseActor.open(
                    at: databaseURL,
                    tuning: environment.tuning,
                    readOnly: readOnly,
                    migrate: !readOnly,
                    // S17-09. Enforced on every read-write open; recorded, not enforced, on the
                    // read-only escape hatch, where no write exists for a trigger to fire on.
                    enforceSchemaGuard: !readOnly
                )
            } catch {
                if let readOnlyScratch { Self.removeReadOnlyScratch(readOnlyScratch) }
                throw error
            }
            do {
                if !verdict.needsFullCheck(carriesCrashEvidence: !assessment.isClean) {
                    // The database bytes were just proven identical to those recorded at the
                    // last clean close, by a build that ran the full check before it wrote
                    // them. The structural walk is enough here (IM-074); a package carrying
                    // crash evidence, a mismatch or a recovery still gets `integrity_check`.
                    try await database.quickCheck()
                } else {
                    try await database.integrityCheck()
                    if !readOnly {
                        // Foreign keys are enforced on every connection this package opens, so
                        // a violation can only arrive from outside — through exactly the
                        // packages that reach this branch. The save pipeline no longer walks
                        // every child table for it on each save (IM-194); this is where the
                        // check moved to.
                        let violations = try await database.foreignKeyViolationCount()
                        if let refusal = ZPDFPersistenceError.foreignKeyRefusal(violationCount: violations) {
                            throw refusal
                        }
                    }
                }
            } catch {
                try? await database.close()
                if let readOnlyScratch { Self.removeReadOnlyScratch(readOnlyScratch) }
                throw error
            }

            let package = ProjectPackage(
                url: url,
                accessMode: readOnly ? .readOnly : .readWrite,
                environment: environment,
                database: database,
                manifest: manifest,
                integrity: integrity,
                integrityVerdict: verdict,
                memberDigests: digests.filter {
                    $0.key == ProjectPackageLayout.originalPDF || $0.key == ProjectPackageLayout.workingPDF
                },
                sessionIdentifier: sessionIdentifier,
                sessionOpenedAt: armed?.openedAt
            )

            if !readOnly {
                // The marker was armed before anything wrote (V-088); from then until close()
                // the package says, on disk, "a session is in progress", and a launch that finds
                // this is a launch after a crash.
                await package.journalSessionOpened()
            } else if let readOnlyScratch {
                await package.adoptReadOnlyScratch(readOnlyScratch)
            }
            return package
        } catch {
            if let armed {
                standDownSessionMarker(
                    at: url, prior: armed.prior, integrity: integrity, sessionID: sessionIdentifier
                )
            }
            throw error
        }
    }

    private func adoptReadOnlyScratch(_ scratch: URL) {
        readOnlyScratchDirectory = scratch
    }

    /// A private copy of an older-schema `project.sqlite`, migrated to the current schema, for
    /// a read-only handle (R-197) — or `nil`, and the handle reads the file as it is: when the
    /// schema is already current, when it is from a future build (the open refuses that with
    /// its own sentence), when the version cannot be read, or when the copy cannot be made or
    /// migrated (a foreign schema object, which the read-write migration refuses; the
    /// read-only handle still records it as the evidence it is).
    ///
    /// The copy is cloned beside the package where the volume allows (O(1) on APFS) and falls
    /// back to the temporary directory; its `-wal` travels with it, so frames committed by a
    /// session that is still open, or that crashed, are read as they were committed.
    private static func migratedReadOnlyCopy(
        of database: URL, package: URL, tuning: DatabaseTuning
    ) async -> (database: URL, scratch: URL)? {
        guard let version = userVersion(of: database), version < ProjectSchema.currentVersion else { return nil }
        let parent = (try? stagingDirectory(appropriateFor: package)) ?? FileManager.default.temporaryDirectory
        let scratch = parent.appendingPathComponent("zpdf-readonly-\(UUID().uuidString)", isDirectory: true)
        let copy = scratch.appendingPathComponent(ProjectPackageLayout.database, isDirectory: false)
        do {
            try FileDurability.createDirectory(at: scratch)
            try FileDurability.cloneItem(at: database, to: copy)
            let wal = URL(fileURLWithPath: database.path + "-wal")
            if FileDurability.exists(wal) {
                try FileDurability.cloneItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
            let migrated = try await ProjectDatabaseActor.open(at: copy, tuning: tuning, readOnly: false, migrate: true)
            try await migrated.close()
            return (copy, scratch)
        } catch {
            removeReadOnlyScratch(scratch)
            return nil
        }
    }

    /// Removes a read-only handle's scratch copy (R-197) and the per-open item-replacement
    /// directory that holds it — the one clean-up for every way the copy ends.
    ///
    /// S-123: `close()` and the copy's own failure removed both, but the two failures after
    /// the copy was made — the database open and the structural check — removed only the
    /// scratch, and every failed read-only open of an older project left an empty staging
    /// directory behind (the R-199 pattern again). The parent is removed only when it is
    /// empty and is not the shared temporary directory.
    package nonisolated static func removeReadOnlyScratch(_ scratch: URL) {
        FileDurability.removeIfPresent(scratch)
        let parent = scratch.deletingLastPathComponent().standardizedFileURL
        guard parent.path != FileManager.default.temporaryDirectory.standardizedFileURL.path else { return }
        _ = rmdir(parent.path)
    }

    /// `PRAGMA user_version` over a read-only connection, or `nil` when the file cannot be
    /// opened that way.
    private static func userVersion(of database: URL) -> Int? {
        let configuration = DatabaseTuning.probeConfiguration(readOnly: true)
        guard let queue = try? DatabaseQueue(path: database.path, configuration: configuration) else { return nil }
        defer { try? queue.close() }
        return try? queue.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") }
    }

    private static func validateStructure(at url: URL) throws {
        guard FileDurability.exists(url) else {
            throw ZPDFPersistenceError.packageNotFound(path: url.path)
        }
        guard FileDurability.isDirectory(url) else {
            throw ZPDFPersistenceError.packageNotADirectory(path: url.path)
        }
        for member in ProjectPackageLayout.requiredMembers {
            guard FileDurability.exists(url.member(member)) else {
                throw ZPDFPersistenceError.packageMemberMissing(relativePath: member)
            }
        }
    }

    // MARK: - Verification

    /// Re-hashes a package on disk and compares it with its own integrity record.
    ///
    /// This verifies a package **as saved**. A package that has been opened for editing
    /// since its last save will not match, and that is correct rather than a defect:
    /// `project.sqlite` is edited in place, so every committed edit moves it away from
    /// the hash the last save recorded. Even opening and closing a package with no edits
    /// at all moves it — GRDB creates and drops a table on any pool open that finds an
    /// empty write-ahead log, and the following checkpoint folds that into the file.
    ///
    /// The artefacts this is unconditionally true of are the saved version clones under
    /// ``versionsRootURL``, which are never opened, and a package in the instant after
    /// ``save(hooks:)`` returns. Those are what the durability suite asserts against.
    ///
    /// V-095: this is the open path's own check — the same hashing through regular-file
    /// descriptors, the same drawing-set comparison (S-120) — with no crash evidence to excuse
    /// a difference. It used to be a second check of its own, which read `manifest.json`
    /// through a symbolic link the open refuses and never compared the added drawings or the
    /// stored revisions, so the durability suites could call consistent a package the next
    /// open refused.
    public static func verifyIntegrity(at url: URL) throws -> IntegrityVerification {
        try validateStructure(at: url)
        let manifest = try ProjectManifest.read(from: url.member(ProjectPackageLayout.manifest))
        let integrity = try IntegrityRecord.read(from: url.member(ProjectPackageLayout.integrity))
        var verdict = verifyAgainstIntegrityRecordCollectingDigests(
            at: url, integrity: integrity, carriesCrashEvidence: false
        ).verdict
        let setMismatches = drawingSetMismatches(at: url, databaseAt: url.member(ProjectPackageLayout.database))
        if !setMismatches.isEmpty { verdict = verdict.addingModified(setMismatches) }
        return IntegrityVerification(manifest: manifest, integrity: integrity, verdict: verdict)
    }

    // MARK: - Closing

    /// Closes the database and disarms the crash marker.
    ///
    /// A close that arrives while a save pipeline is in flight **waits for the save**
    /// before doing anything. The actor is reentrant, so without this wait a ⌘S
    /// followed immediately by ⌘Q would interleave: the close's `session-closed` line
    /// and marker removal land in the directory the save's atomic swap then retires,
    /// the pipeline re-arms the marker on the swapped-in package, and the next launch
    /// shows the "was not closed properly" prompt for a cleanly-quit project
    /// After the wait, this close is the last word: the journal's
    /// final entry is `session-closed` and the marker is down.
    public func close() async throws {
        await drainActiveSave()
        guard !isClosed else { return }
        isClosed = true
        // A handle a save could not reopen (BH-185) has no pool to checkpoint, and the
        // record refreshed below is the one that save wrote.
        try await databaseHandle.close()
        if let readOnlyScratchDirectory {
            // The migrated copy a read-only handle read (R-197), and its per-open parent.
            Self.removeReadOnlyScratch(readOnlyScratchDirectory)
            self.readOnlyScratchDirectory = nil
        }
        guard accessMode == .readWrite else { return }
        appendJournal(kind: .sessionClosed, token: currentManifest.projectId, detail: nil)
        // S17-07. `project.sqlite` is edited in place, so by now it no longer hashes to
        // what the last save recorded; the final TRUNCATE checkpoint above has just given
        // it the shape the next reader will find. Re-recording the digest here is what
        // makes "a package at rest describes itself truthfully" true, and therefore what
        // makes the check on the open path able to tell tampering from ordinary use.
        let recordRefreshed = refreshIntegrityRecordAtRest()
        // A cleanly closed document has nothing to recover: the crash marker comes down
        // and the autosave snapshot goes with it, so the next launch is a clean open
        // rather than a recovery sheet about a crash that did not happen.
        //
        // Unless the record could not be refreshed — a package directory that has gone
        // unwritable under us. Then the marker stays armed on purpose, so the next open
        // reads the mismatch as crash evidence and offers recovery, instead of accusing
        // the user of editing their own project behind our back.
        if recordRefreshed {
            FileDurability.removeIfPresent(url.member(ProjectPackageLayout.crashMarker))
            FileDurability.removeIfPresent(url.member(ProjectPackageLayout.autosaveDatabase))
        }
        try? FileDurability.syncDirectory(at: url.member(ProjectPackageLayout.recovery))
    }
}
