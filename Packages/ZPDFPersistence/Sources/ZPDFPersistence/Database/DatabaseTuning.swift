import Foundation
import GRDB

/// When the write-ahead log is folded back into the main database file.
public enum CheckpointPolicy: Sendable, Hashable {
    /// SQLite runs a `PASSIVE` checkpoint whenever the WAL passes `pages` frames.
    ///
    /// This is the editing-session policy. `PASSIVE` never blocks a reader and never
    /// blocks a writer; it simply does as much as it can and gives up on the rest.
    case automatic(pages: Int)
    /// No automatic checkpoint at all: the WAL only folds back when this package asks.
    case manualOnly
}

/// Connection settings for the project database.
public struct DatabaseTuning: Sendable, Hashable {

    /// How long a connection waits for a lock before it gives up.
    ///
    /// Five seconds, not zero. A `SQLITE_BUSY` thrown into the UI during a save is a
    /// worse outcome than a pause: the contended windows here are short (a `TRUNCATE`
    /// checkpoint waiting for a long report query to finish), and waiting them out is
    /// almost always right.
    public var busyTimeout: TimeInterval = 5

    /// Concurrent reader connections in the pool.
    ///
    /// Five: the canvas, the ledger, a background thumbnail pass, a search, and one
    /// spare for an export, all reading while the user keeps drawing.
    public var maximumReaderCount: Int = 5

    /// See ``CheckpointPolicy``. 1 000 pages of 4 KiB is roughly 4 MB of WAL.
    public var checkpointPolicy: CheckpointPolicy = .automatic(pages: 1_000)

    /// `PRAGMA synchronous`.
    ///
    /// `FULL`, deliberately, against SQLite's own WAL-mode recommendation of `NORMAL`.
    /// `NORMAL` in WAL mode means a committed transaction can be lost if the *machine*
    /// loses power (the process crashing is still safe). For a scratch cache that is a
    /// fine trade. For a document that holds days of a quantity surveyor's work it is
    /// not: the user pressed Cmd-S, and the only acceptable meaning of that is that the
    /// bytes are on the platter. The cost is one extra fsync per commit, which the save
    /// pipeline pays once rather than per keystroke.
    public var synchronous: Synchronous = .full

    public enum Synchronous: String, Sendable, Hashable {
        case normal = "NORMAL"
        case full = "FULL"
    }

    public init(
        busyTimeout: TimeInterval = 5,
        maximumReaderCount: Int = 5,
        checkpointPolicy: CheckpointPolicy = .automatic(pages: 1_000),
        synchronous: Synchronous = .full
    ) {
        self.busyTimeout = busyTimeout
        self.maximumReaderCount = maximumReaderCount
        self.checkpointPolicy = checkpointPolicy
        self.synchronous = synchronous
    }

    /// The GRDB configuration this tuning describes.
    ///
    /// `DatabasePool` puts the file into WAL itself, so `journal_mode` is not set here;
    /// ``ProjectDatabaseActor`` verifies afterwards that the file really is in WAL
    /// rather than trusting that it worked.
    public func configuration(readOnly: Bool) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readOnly
        // Foreign keys are enforced, always. A takeoff whose measurement rows outlive
        // their markups is a corrupt takeoff that still opens, which is the worst kind.
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(busyTimeout)
        // GRDB aborts the process on a reader count below one — a precondition, which no
        // `catch` on the open path can turn into an error (BH-592). A tuning value this
        // package cannot honour is clamped to the smallest pool that works, never trapped
        // on at document open.
        configuration.maximumReaderCount = max(1, maximumReaderCount)

        let autocheckpointPages: Int? = {
            guard !readOnly else { return nil }
            switch checkpointPolicy {
            // SQLite reads zero or a negative threshold as "auto-checkpoint off", which
            // would make a tuning that *says* automatic behave as `manualOnly` and let the
            // WAL grow for the whole session (BH-593). The smallest honest threshold is
            // one page.
            case let .automatic(pages): return max(1, pages)
            case .manualOnly: return 0
            }
        }()

        configuration.prepareDatabase { db in
            if !readOnly {
                if let pages = autocheckpointPages {
                    try db.execute(sql: "PRAGMA wal_autocheckpoint = \(pages)")
                }
            }
            try Self.applyUntrustedSchemaPragmas(db)
        }
        return configuration
    }

    /// The pragmas that say "the schema in this file is not ours to trust".
    ///
    /// Applied on **every** connection this package opens, without exception: the pool's
    /// readers and writer, the read-only compatibility probe that runs before a
    /// read-write open, and the recovery health probes that look at an autosave snapshot
    /// or a saved version (S17-06 follow-through). One function, called from every
    /// configuration factory in this file, so there is one place to read and one place
    /// to change — and ``ProjectDatabaseActor`` asserts the measured value afterwards
    /// rather than trusting that the call took.
    ///
    /// - `recursive_triggers = OFF`: none are used, and a schema that adds one later
    ///   should have to say so explicitly.
    /// - `trusted_schema = OFF` (S17-06): a `.zpdfproj` is a document, it travels by mail
    ///   and by shared folder exactly as a PDF does, so `project.sqlite` may have been
    ///   written by anyone. SQLite's own answer for a database from outside is to stop
    ///   treating SQL *stored in the schema* — views, triggers, CHECK constraints, index
    ///   expressions, generated columns — as trusted enough to call functions that are
    ///   not marked innocuous. Measured cost: none. `Fts3TokenizerProbeTests` shows FTS5,
    ///   which is the product's search index, keeps working under it.
    ///
    /// It stops schema SQL calling non-innocuous *functions*; it does not stop a trigger
    /// running `INSERT`/`UPDATE`/`DELETE`/`RAISE`. That half is ``ProjectSchemaInventory``.
    public static func applyUntrustedSchemaPragmas(_ db: Database) throws {
        try db.execute(sql: "PRAGMA recursive_triggers = OFF")
        try db.execute(sql: "PRAGMA trusted_schema = OFF")
    }

    /// The measured value of `trusted_schema` on a connection. Zero is the only
    /// acceptable answer, and every open asserts it rather than assuming it.
    public static func trustedSchemaSetting(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA trusted_schema") ?? -1
    }

    /// The configuration for the short-lived probe connections: the read-only schema
    /// compatibility check, and the recovery health checks on a snapshot.
    ///
    /// These open document-supplied SQLite files too — a `recovery/autosave.sqlite` or a
    /// `versions/latest/project.sqlite` inside a package that arrived from outside is no
    /// more ours than `project.sqlite` is — so they get the same pragmas. They were the
    /// paths S17-06's fix originally missed.
    ///
    /// - Parameter busyTimeout: how long the probe waits for a lock. The compatibility
    ///   probe that precedes a read-write open passes the pool's own timeout, so a
    ///   neighbour's WAL cleanup is waited out there exactly as the pool would (BH-183);
    ///   `nil` keeps GRDB's default of failing immediately.
    public static func probeConfiguration(readOnly: Bool, busyTimeout: TimeInterval? = nil) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readOnly
        if let busyTimeout {
            configuration.busyMode = .timeout(busyTimeout)
        }
        configuration.prepareDatabase { db in
            try applyUntrustedSchemaPragmas(db)
        }
        return configuration
    }

    /// Pragmas that have to be applied to the writer connection *after* the pool exists.
    ///
    /// `synchronous` is one of them. GRDB switches the file into WAL after running
    /// `prepareDatabase`, and its WAL setup ends with `PRAGMA synchronous = NORMAL`
    /// following SQLite's own recommendation — so anything set earlier is quietly
    /// overwritten. Setting it here, once, on the pool's single writer connection, is
    /// what actually makes a commit durable across a power loss. Reader connections keep
    /// `NORMAL`, which costs nothing: a reader never fsyncs.
    public func applyWriterPragmas(_ db: Database) throws {
        try db.execute(sql: "PRAGMA synchronous = \(synchronous.rawValue)")
    }
}
