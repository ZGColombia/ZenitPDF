import Foundation
import GRDB

/// The one door to the project database.
///
/// ### Why an actor, and why reads still do not block writes
///
/// The obvious way to write this — an actor with a synchronous `DatabasePool` inside —
/// would be wrong. A synchronous `pool.read { }` inside an actor method occupies the
/// actor's executor for the whole query, so a 300 ms report read would stall the next
/// write behind it and WAL's central promise would be thrown away at the Swift layer.
///
/// So every method here goes through GRDB's **async** `read`/`write`, which suspends the
/// actor rather than blocking it. The actor is a gate on the handle — one place that
/// owns the pool, closes it once, and turns SQLite errors into ``ZPDFPersistenceError`` —
/// not a lock on the database. Concurrency is still SQLite's: many readers on their own
/// connections against a WAL snapshot, one writer, nobody waiting on anybody.
///
/// `ConcurrencyTests.readsDoNotBlockWrites` holds a slow read open and proves a write
/// starts and finishes underneath it.
public actor ProjectDatabaseActor {

    /// The result of a WAL checkpoint.
    public struct CheckpointReport: Sendable, Hashable {
        /// Frames in the WAL before the checkpoint.
        public let walFrameCount: Int
        /// Frames actually folded into the main file.
        public let checkpointedFrameCount: Int
        /// Size of `-wal` on disk afterwards. Zero after a successful `TRUNCATE`.
        public let walByteCountAfter: Int
    }

    /// The open pool. `nil` only while a save has the file swapped out from under it
    /// (``suspendForSwap()``), after a reopen that failed (``endSaveFence()``), or once
    /// the handle is closed.
    private var pool: DatabasePool?
    private var isClosed = false

    // R-186. One actor for the whole session. The save pipeline used to close this actor
    // around the atomic swap and install a *new* one, and every caller that had fetched
    // `ProjectPackage.database` once — the History feed, Review, Ledger Snapshots — kept
    // the closed one: from the first ⌘S on, their writes failed with "the database handle
    // is closed" and were discarded. Now the pipeline closes and reopens the *pool* inside
    // this actor, so a cached handle stays live across every save.

    /// Set from the save's commit stamp until the swap is done: writes from anybody but
    /// the pipeline wait, because a row committed after the WAL checkpoint would land in
    /// the database the swap retires (the BH-029 loss, for a caller holding the handle).
    private var writesFenced = false
    /// Set while the pool is closed for the swap: every access waits.
    private var poolSuspended = false
    /// Set when a reopen failed (BH-185): the next access retries it instead of failing
    /// forever on a handle that stays closed.
    private var reopenPending = false
    private var reopenTask: Task<DatabasePool, any Error>?
    private var inFlightCount = 0
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let tuning: DatabaseTuning
    private let migratesOnOpen: Bool
    private let enforcesSchemaGuard: Bool

    /// Absolute path of the `project.sqlite` file.
    public nonisolated let path: String
    /// Whether this handle refuses writes.
    public nonisolated let isReadOnly: Bool
    /// What ``ProjectSchemaInventory`` found in this file's schema at open (S17-09).
    ///
    /// Empty on every read-write handle — a non-empty result is a refusal there. On a
    /// read-only handle it is the evidence the caller shows the user about the project
    /// it just let them look at.
    public nonisolated let schemaDeviations: [ProjectSchemaInventory.Deviation]

    private init(
        pool: DatabasePool,
        path: String,
        isReadOnly: Bool,
        schemaDeviations: [ProjectSchemaInventory.Deviation],
        tuning: DatabaseTuning,
        migratesOnOpen: Bool,
        enforcesSchemaGuard: Bool
    ) {
        self.pool = pool
        self.path = path
        self.isReadOnly = isReadOnly
        self.schemaDeviations = schemaDeviations
        self.tuning = tuning
        self.migratesOnOpen = migratesOnOpen
        self.enforcesSchemaGuard = enforcesSchemaGuard
    }

    // MARK: - Opening

    /// Opens the database, applies pending migrations, and refuses a future schema.
    ///
    /// - Parameter migrate: `false` opens the file without touching it, which is what
    ///   read-only recovery needs: a user who opens tomorrow's project must get their
    ///   bytes back untouched, not a half-applied migration.
    /// - Parameter enforceSchemaGuard: whether a schema object the migrations never
    ///   created is a refusal (S17-09). `true` on every read-write open, because a write
    ///   of ours is exactly what makes somebody else's trigger fire. `false` on the
    ///   read-only path, which is the deliberate escape hatch: a project this guard
    ///   refuses must still be *inspectable*, and on a read-only connection there is no
    ///   write for a trigger to hang off. Either way the deviations are recorded on the
    ///   returned handle, so a read-only caller can tell the user what it found.
    public static func open(
        at url: URL,
        tuning: DatabaseTuning = DatabaseTuning(),
        readOnly: Bool = false,
        migrate: Bool = true,
        enforceSchemaGuard: Bool = true
    ) async throws -> ProjectDatabaseActor {
        let (pool, schemaDeviations) = try await makePool(
            path: url.path, tuning: tuning, readOnly: readOnly,
            migrate: migrate, enforceSchemaGuard: enforceSchemaGuard
        )
        return ProjectDatabaseActor(
            pool: pool, path: url.path, isReadOnly: readOnly, schemaDeviations: schemaDeviations,
            tuning: tuning, migratesOnOpen: migrate, enforcesSchemaGuard: enforceSchemaGuard
        )
    }

    /// Opens, checks and migrates one pool: the whole of ``open(at:tuning:readOnly:migrate:enforceSchemaGuard:)``
    /// except the actor, so a save can reopen the pool inside the actor it already has.
    private static func makePool(
        path: String,
        tuning: DatabaseTuning,
        readOnly: Bool,
        migrate: Bool,
        enforceSchemaGuard: Bool
    ) async throws -> (DatabasePool, [ProjectSchemaInventory.Deviation]) {
        var schemaDeviations: [ProjectSchemaInventory.Deviation] = []
        // The guard is a property of *writing*, not a parameter a caller may drop: a
        // read-write handle always enforces it, whatever was passed. `false` only means
        // something on the read-only escape hatch, where no write of ours can fire a
        // trigger (BH-594).
        let guardEnforced = enforceSchemaGuard || !readOnly

        // Refuse a future schema — and, since BH-182, a foreign schema — *before* opening
        // the file for writing. Constructing a DatabasePool read-write converts the
        // journal mode, primes the WAL with a throwaway table, and the closing checkpoint
        // folds that into the main file: three writes into a file we may be about to
        // refuse, and enough to move it off the digest `integrity.json` records, so the
        // *next* attempt would be refused as tampered instead of as foreign. A user who
        // opens tomorrow's project with today's build, or a project somebody else's tool
        // has been in, must get their bytes back exactly as they were, so both checks run
        // on a read-only connection first.
        //
        // The probe's own failures are typed like every other open failure (BH-183): a
        // `SQLITE_BUSY` or `SQLITE_NOTADB` here used to leave `open()` as a raw engine
        // error the document layer never recognised.
        if !readOnly, FileManager.default.fileExists(atPath: path) {
            do {
                try probeSchemaCompatibility(
                    path: path, busyTimeout: tuning.busyTimeout, enforceSchemaGuard: guardEnforced
                )
            } catch let error as ZPDFPersistenceError {
                throw error
            } catch {
                throw ZPDFPersistenceError.databaseOpenFailed(path: path, reason: String(describing: error))
            }
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: tuning.configuration(readOnly: readOnly))
        } catch {
            throw ZPDFPersistenceError.databaseOpenFailed(path: path, reason: String(describing: error))
        }

        do {
            if !readOnly {
                _ = try await pool.writeWithoutTransaction { db -> Bool in
                    try tuning.applyWriterPragmas(db)
                    return true
                }
            }
            try await pool.read { db in
                try ProjectSchema.assertCompatible(db)
            }
            // S17-09. Before the migrator runs, before `applyWriterPragmas` has taken
            // effect on anything that matters, and before a single row of ours is
            // written: the schema in this file is an input, so it is checked like one.
            // The read-only probe above has normally already refused a deviation on a
            // read-write open; this pass is what records the deviations on a read-only
            // handle, and what still stands guard when the probe could not open the file.
            schemaDeviations = try await pool.read { db in
                try ProjectSchemaInventory.deviations(in: db)
            }
            if guardEnforced, let first = schemaDeviations.first {
                throw first.error
            }
            if migrate && !readOnly {
                try ProjectSchema.migrator().migrate(pool)
            }
            if !readOnly {
                // Trust nothing: confirm the file really is in WAL and really has
                // foreign keys on, rather than assuming the configuration took.
                let journalMode = try await pool.read { db in
                    try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
                }
                guard journalMode.lowercased() == "wal" else {
                    throw ZPDFPersistenceError.databaseOpenFailed(
                        path: path,
                        reason: "journal_mode is \(journalMode), expected wal"
                    )
                }
            }
            let foreignKeys = try await pool.read { db in
                try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
            }
            guard foreignKeys == 1 else {
                throw ZPDFPersistenceError.databaseOpenFailed(path: path, reason: "foreign_keys is off")
            }
            // S17-06 follow-through: measured, not assumed, and measured on *this*
            // connection rather than on the one a test happened to look at. Reader and
            // writer connections are configured by the same `prepareDatabase` block, so
            // reading it back through the pool is reading it back through a real
            // connection of the pool.
            let trustedSchema = try await pool.read { db in
                try DatabaseTuning.trustedSchemaSetting(db)
            }
            guard trustedSchema == 0 else {
                throw ZPDFPersistenceError.databaseOpenFailed(
                    path: path,
                    reason: "trusted_schema is \(trustedSchema); a document-supplied schema is not trusted"
                )
            }
        } catch let error as ZPDFPersistenceError {
            // Close the pool directly: the actor's close() checkpoints, and a refused
            // open must not write to the file it is refusing.
            try? pool.close()
            throw error
        } catch {
            try? pool.close()
            throw ZPDFPersistenceError.databaseOpenFailed(path: path, reason: String(describing: error))
        }
        return (pool, schemaDeviations)
    }

    /// Reads `grdb_migrations` and `user_version`, and takes the S17-09 schema inventory,
    /// over a read-only connection — before anything has been written to the file.
    private static func probeSchemaCompatibility(
        path: String,
        busyTimeout: TimeInterval,
        enforceSchemaGuard: Bool
    ) throws {
        // Hardened like every other connection (S17-06 follow-through): this one opens a
        // document-supplied file before anything else in the process has looked at it.
        // It waits out a lock the same way the pool would (BH-183): a standalone queue
        // has no busy handler by default, so a neighbour's WAL cleanup used to surface as
        // an immediate `SQLITE_BUSY` where the pool would simply have waited.
        let configuration = DatabaseTuning.probeConfiguration(readOnly: true, busyTimeout: busyTimeout)
        guard let queue = try? DatabaseQueue(path: path, configuration: configuration) else {
            // Not openable read-only (a brand-new file, or a permissions problem). The
            // real open below will produce the proper error.
            return
        }
        defer { try? queue.close() }
        try queue.read { db in
            try ProjectSchema.assertCompatible(db)
            if enforceSchemaGuard, let first = try ProjectSchemaInventory.deviations(in: db).first {
                throw first.error
            }
        }
    }

    // MARK: - Access

    /// A read against a WAL snapshot. Concurrent with writes and with other reads.
    public func read<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await perform(.read) { pool in try await pool.read(body) }
    }

    /// A write inside a transaction, committed when `body` returns.
    public func write<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard !isReadOnly else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        return try await perform(.write) { pool in try await pool.write(body) }
    }

    /// The save pipeline's own commit stamp, which runs inside the write fence it set.
    func writeInsideSaveFence<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard !isReadOnly else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        return try await perform(.pipeline) { pool in try await pool.write(body) }
    }

    /// A write barrier with no implicit transaction, for statements SQLite refuses to
    /// run inside one — `PRAGMA wal_checkpoint`, `VACUUM`, the snapshot copy at save.
    public func writeWithoutTransaction<T: Sendable>(
        _ body: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        guard !isReadOnly else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        return try await perform(.write) { pool in try await pool.writeWithoutTransaction(body) }
    }

    // MARK: - Transaction observation

    /// Registers a GRDB transaction observer on the writer connection.
    ///
    /// Spec 8.1 lists transaction observation alongside WAL and migrations, and this is
    /// where it belongs: one place that knows which connection is the writer. The
    /// observer lives until the pool is closed, which means a save — the pipeline closes
    /// and reopens the pool around the atomic swap, inside this same actor — drops it. Callers that need an
    /// observation across a save re-register it from the ``SaveReceipt``.
    /// The observer must be `Sendable`: it is handed to the writer connection, which
    /// runs on GRDB's own dispatch queue, not on this actor.
    public func addTransactionObserver(
        _ observer: some TransactionObserver & Sendable,
        extent: Database.TransactionObservationExtent = .observerLifetime
    ) async throws {
        guard !isReadOnly else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        _ = try await perform(.write) { pool in
            try await pool.writeWithoutTransaction { db -> Bool in
                db.add(transactionObserver: observer, extent: extent)
                return true
            }
        }
    }

    // MARK: - Maintenance

    /// Folds the write-ahead log back into `project.sqlite`.
    ///
    /// ### Checkpoint policy
    ///
    /// 1. **During editing**, SQLite checkpoints itself `PASSIVE` every 1 000 WAL frames
    ///    (``DatabaseTuning/checkpointPolicy``). Passive never blocks anyone, so the
    ///    user never feels it; the WAL simply stays around 4 MB instead of growing all
    ///    session.
    /// 2. **Before every autosave snapshot and every save**, this method runs with
    ///    `.truncate`. That is the only mode that leaves `-wal` at zero bytes, and the
    ///    save pipeline needs exactly that: the sibling temporary package must contain
    ///    one self-contained `project.sqlite`, not a database plus a log whose pairing
    ///    a future reader has to reconstruct.
    /// 3. **At clean close**, `.truncate` again, so a project sitting in a Dropbox or
    ///    iCloud folder syncs one file rather than three.
    /// 4. **Never from a read path.** A checkpoint is a write; running one to "tidy up"
    ///    inside a query is how a read starts blocking a write.
    ///
    /// `TRUNCATE` needs every reader to have moved past the frames it is folding, so it
    /// can return `SQLITE_BUSY`. The busy timeout absorbs the usual case; a genuine
    /// timeout is reported as ``ZPDFPersistenceError/walCheckpointFailed(reason:)`` and the
    /// caller decides — the save pipeline retries and then aborts, leaving the project
    /// exactly as it was.
    @discardableResult
    public func checkpoint(_ mode: Database.CheckpointMode = .truncate) async throws -> CheckpointReport {
        guard !isReadOnly else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        // The same two answers `perform` gives every other call (BH-595): a closed handle
        // and a cancelled task are reported as what they are, not as a checkpoint that
        // failed — which the save pipeline would otherwise retry three times and then
        // blame on the WAL.
        // A checkpoint adds no rows, so it runs inside a save's write fence — the pipeline's
        // own step 3 is one — but still waits out a swap and retries a pending reopen.
        let pool: DatabasePool
        do {
            pool = try await acquirePool(for: .pipeline)
        } catch is CancellationError {
            throw ZPDFPersistenceError.cancelled
        }
        inFlightCount += 1
        defer { leave() }
        // `sqlite3_wal_checkpoint_v2` reports the log's frame count and the number it
        // folded in — except for `TRUNCATE`, which resets the log header before it
        // answers and so reports zero for both. For that mode, the one the save pipeline
        // uses, the counts are taken from the WAL's own layout *before* the call: a
        // 32-byte header followed by whole frames of (page size + 24) bytes, and a
        // successful truncate has by definition folded every one of them.
        let walBytesBefore = Self.fileByteCount(path + "-wal")
        var counts: (walFrameCount: Int, checkpointedFrameCount: Int)
        do {
            counts = try await pool.writeWithoutTransaction { db in
                let reported = try db.checkpoint(mode)
                guard mode == .truncate else { return reported }
                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
                let frames = max(0, (walBytesBefore - 32) / (pageSize + 24))
                return (walFrameCount: frames, checkpointedFrameCount: frames)
            }
        } catch let error as ZPDFPersistenceError {
            throw error
        } catch is CancellationError {
            throw ZPDFPersistenceError.cancelled
        } catch let error as DatabaseError {
            throw ZPDFPersistenceError.walCheckpointFailed(reason: error.message ?? "\(error.resultCode)")
        } catch {
            throw ZPDFPersistenceError.walCheckpointFailed(reason: String(describing: error))
        }
        // For every other mode the frame counts are what `sqlite3_wal_checkpoint_v2`
        // itself reported (BH-596). Deriving them from the `-wal` size was only right for
        // `.truncate`, the one mode that shrinks the file; `.passive`, `.full` and
        // `.restart` leave it at its old length and used to report zero frames
        // checkpointed whatever happened. The byte count after is still measured, because
        // it is the one number the save pipeline acts on: a temporary package must
        // receive a self-contained file.
        return CheckpointReport(
            walFrameCount: max(0, counts.walFrameCount),
            checkpointedFrameCount: max(0, counts.checkpointedFrameCount),
            walByteCountAfter: Self.fileByteCount(path + "-wal")
        )
    }

    /// `PRAGMA integrity_check`. Run on any copy this package recovers from.
    public func integrityCheck() async throws {
        let rows = try await perform(.read) { pool in
            try await pool.read { db in
                try String.fetchAll(db, sql: "PRAGMA integrity_check")
            }
        }
        guard rows == ["ok"] else {
            throw ZPDFPersistenceError.integrityCheckFailed(detail: rows.prefix(8).joined(separator: "; "))
        }
    }

    /// `PRAGMA quick_check`: the structural half of ``integrityCheck()``, without the
    /// index-content cross-check that dominates on a database with many OCR tokens.
    ///
    /// The open path runs this instead of the full check when the database bytes were
    /// just proven identical to those recorded at the last clean close (IM-074): the
    /// full walk then re-verifies a file this build wrote and hashed itself. Crash
    /// evidence, a hash mismatch and recovery still get `integrity_check`.
    public func quickCheck() async throws {
        let rows = try await perform(.read) { pool in
            try await pool.read { db in
                try String.fetchAll(db, sql: "PRAGMA quick_check")
            }
        }
        guard rows == ["ok"] else {
            throw ZPDFPersistenceError.integrityCheckFailed(detail: rows.prefix(8).joined(separator: "; "))
        }
    }

    /// Writes a transactionally consistent copy of the database to `destination`,
    /// through SQLite's online backup API, from one read snapshot.
    ///
    /// This is how the autosave takes its snapshot (BH-189). Copying `project.sqlite`
    /// byte by byte was only sound while nothing wrote to it: a commit landing during the
    /// copy — the writer's `wal_autocheckpoint` folding new pages into the main file
    /// while earlier pages had already been read — produced a file mixing two
    /// generations, which `quick_check` cannot see because every page in it is
    /// well-formed. The backup runs inside a reader's WAL snapshot, so every page it
    /// copies belongs to the same committed state, and it neither blocks the writer nor
    /// needs the WAL checkpointed first.
    ///
    /// `destination` must not exist. The file it produces is a self-contained database in
    /// rollback-journal mode, with no `-wal`; the next read-write open converts it.
    public func backup(to destination: URL) async throws {
        try await perform(.read) { pool in
            try await pool.read { source in
                let configuration = DatabaseTuning.probeConfiguration(readOnly: false)
                let target = try DatabaseQueue(path: destination.path, configuration: configuration)
                defer { try? target.close() }
                try target.writeWithoutTransaction { destinationDb in
                    try source.backup(to: destinationDb)
                }
            }
        }
    }

    /// `PRAGMA foreign_key_check`, as a count of violations.
    public func foreignKeyViolationCount() async throws -> Int {
        try await perform(.read) { pool in
            try await pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? 0
            }
        }
    }

    /// The number of migrations applied to this file.
    public func appliedMigrationCount() async throws -> Int {
        try await perform(.read) { pool in
            try await pool.read { db in
                guard try db.tableExists("grdb_migrations") else { return 0 }
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
            }
        }
    }

    /// Closes the pool. Idempotent, and final: unlike the save's suspension, nothing
    /// reopens a closed handle.
    public func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        reopenPending = false
        // Anybody waiting out a swap wakes to a closed handle rather than waiting forever.
        releaseGateWaiters()
        guard let pool else { return }
        self.pool = nil
        await Self.checkpointAndClose(pool, readOnly: isReadOnly)
    }

    // MARK: - The save pipeline's side (R-186)

    /// Holds every write but the pipeline's own until ``endSaveFence()``. Reads go on.
    func beginSaveFence() {
        writesFenced = true
    }

    /// Closes the pool for the atomic swap, after every access in flight has finished.
    ///
    /// After a `RENAME_SWAP` the path names a different inode, and a descriptor opened
    /// before it would keep writing into the copy on its way out; so the pool lets go
    /// here and ``endSaveFence()`` opens a fresh one on the same path. Every access that
    /// arrives in between waits for that.
    func suspendForSwap() async {
        writesFenced = true
        poolSuspended = true
        while inFlightCount > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        guard let pool else { return }
        self.pool = nil
        await Self.checkpointAndClose(pool, readOnly: isReadOnly)
    }

    /// Reopens the pool a swap suspended and lifts the write fence. Idempotent.
    ///
    /// Never throws: the save has committed or has been abandoned by the time this runs,
    /// and either way the user's work is on disk. A reopen that fails leaves the handle
    /// pending a reopen that the next access retries (BH-185), and the error is returned
    /// for the journal.
    @discardableResult
    func endSaveFence() async -> (any Error)? {
        var failure: (any Error)?
        if poolSuspended, !isClosed, pool == nil {
            do {
                pool = try await Self.makePool(
                    path: path, tuning: tuning, readOnly: isReadOnly,
                    migrate: migratesOnOpen, enforceSchemaGuard: enforcesSchemaGuard
                ).0
                reopenPending = false
            } catch {
                reopenPending = true
                failure = error
            }
        }
        poolSuspended = false
        writesFenced = false
        releaseGateWaiters()
        return failure
    }

    // MARK: - Internals

    private enum Access {
        /// Reads: go on inside a write fence, wait out a swap.
        case read
        /// Writes from any caller: wait out a write fence and a swap.
        case write
        /// The save pipeline itself, and checkpoints: inside its own fence, never a swap.
        case pipeline
    }

    private static let closedError = ZPDFPersistenceError.databaseFailure(
        message: "the database handle is closed", resultCode: 0
    )

    /// The pool, once it may be used for `access`: after any swap, outside a write fence
    /// for an ordinary write, and reopened first if a reopen is pending.
    private func acquirePool(for access: Access) async throws -> DatabasePool {
        while true {
            guard !isClosed else { throw Self.closedError }
            if poolSuspended || (access == .write && writesFenced) {
                await withCheckedContinuation { gateWaiters.append($0) }
                continue
            }
            if let pool { return pool }
            guard reopenPending else { throw Self.closedError }
            return try await reopenPool()
        }
    }

    /// One reopen, however many accesses are waiting for it.
    private func reopenPool() async throws -> DatabasePool {
        let task: Task<DatabasePool, any Error>
        if let reopenTask {
            task = reopenTask
        } else {
            task = Task { [path, tuning, isReadOnly, migratesOnOpen, enforcesSchemaGuard] in
                try await Self.makePool(
                    path: path, tuning: tuning, readOnly: isReadOnly,
                    migrate: migratesOnOpen, enforceSchemaGuard: enforcesSchemaGuard
                ).0
            }
            reopenTask = task
        }
        let reopened: DatabasePool
        do {
            reopened = try await task.value
        } catch {
            if reopenTask == task { reopenTask = nil }
            throw error
        }
        if reopenTask == task { reopenTask = nil }
        if isClosed {
            try? reopened.close()
            throw Self.closedError
        }
        if pool == nil {
            pool = reopened
            reopenPending = false
        }
        return pool ?? reopened
    }

    private func releaseGateWaiters() {
        let waiters = gateWaiters
        gateWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func leave() {
        inFlightCount -= 1
        guard inFlightCount == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private static func checkpointAndClose(_ pool: DatabasePool, readOnly: Bool) async {
        if !readOnly {
            // Best effort: a failed final checkpoint leaves a valid database plus a
            // valid WAL, which SQLite recovers on next open. It is not worth failing
            // a close over.
            _ = try? await pool.writeWithoutTransaction { db -> Bool in
                try db.checkpoint(.truncate)
                return true
            }
        }
        try? pool.close()
    }

    private func perform<T: Sendable>(
        _ access: Access,
        _ body: (DatabasePool) async throws -> T
    ) async throws -> T {
        do {
            let pool = try await acquirePool(for: access)
            inFlightCount += 1
            defer { leave() }
            return try await body(pool)
        } catch let error as ZPDFPersistenceError {
            throw error
        } catch let error as DatabaseError {
            throw ZPDFPersistenceError.databaseFailure(
                message: error.message ?? String(describing: error),
                resultCode: error.resultCode.rawValue
            )
        } catch is CancellationError {
            throw ZPDFPersistenceError.cancelled
        } catch {
            throw ZPDFPersistenceError.databaseFailure(message: String(describing: error), resultCode: 0)
        }
    }

    private static func fileByteCount(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}
