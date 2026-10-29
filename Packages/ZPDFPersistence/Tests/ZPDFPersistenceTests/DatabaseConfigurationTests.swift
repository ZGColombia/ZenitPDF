import Foundation
import GRDB
import Testing
import ZPDFPersistence

struct DatabaseConfigurationTests {

    @Test("The connection is WAL, foreign keys on, synchronous FULL, with a busy timeout")
    func pragmasAreWhatWeAskedFor() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("Pragma")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite"),
            tuning: DatabaseTuning(busyTimeout: 3, maximumReaderCount: 4)
        )
        // Read from the writer connection: GRDB gives pool *readers* their own
        // 10-second busy timeout, which is fine — a reader waiting on a lock is never
        // what blocks a writer — but it is not the value under test here.
        let journalMode = try await database.writeWithoutTransaction { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
        let numbers = try await database.writeWithoutTransaction { db -> [String: Int] in
            var values: [String: Int] = [:]
            for name in ["foreign_keys", "synchronous", "wal_autocheckpoint", "busy_timeout"] {
                values[name] = try Int.fetchOne(db, sql: "PRAGMA \(name)")
            }
            return values
        }
        #expect(journalMode == "wal")
        #expect(numbers["foreign_keys"] == 1)
        #expect(numbers["synchronous"] == 2)            // 2 == FULL
        #expect(numbers["wal_autocheckpoint"] == 1000)
        #expect(numbers["busy_timeout"] == 3000)
        try await database.close()
    }

    /// The claim in ``ProjectDatabaseActor``'s documentation, tested rather than asserted.
    ///
    /// A read is started and held open with a deliberately slow query. While it is still
    /// running, a write is issued. If the actor were serialising database access, the
    /// write could not finish before the read; the assertion is that it does.
    @Test("A long read does not block a write")
    func readsDoNotBlockWrites() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("Concurrency")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite")
        )
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO probe VALUES (1, 0)")
        }

        let readStarted = SignalBox()
        let writeFinished = SignalBox()

        async let slowRead: Int = database.read { db in
            readStarted.signal()
            // A query that takes real time inside SQLite, on its own connection.
            var total = 0
            for _ in 0..<400 {
                total += try Int.fetchOne(db, sql: """
                    WITH RECURSIVE counter(x) AS (
                        SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 4000
                    ) SELECT COUNT(*) FROM counter
                    """) ?? 0
            }
            return total
        }

        while !readStarted.isSignalled {
            try await Task.sleep(nanoseconds: 200_000)
        }
        try await database.write { db in
            try db.execute(sql: "UPDATE probe SET value = 42 WHERE id = 1")
        }
        writeFinished.signal()
        let readIsStillRunning = !Task.isCancelled

        let total = try await slowRead
        #expect(total > 0)
        #expect(readIsStillRunning)
        #expect(writeFinished.isSignalled)

        // And the write really landed.
        let value = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM probe WHERE id = 1")
        }
        #expect(value == 42)
        try await database.close()
    }

    @Test("A truncate checkpoint leaves the WAL at zero bytes")
    func checkpointTruncatesTheLog() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("Checkpoint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("project.sqlite")
        let database = try await ProjectDatabaseActor.open(at: url)

        try await database.write { db in
            try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
            for index in 0..<2_000 {
                try db.execute(
                    sql: "INSERT INTO probe VALUES (?, ?)",
                    arguments: [index, Data(repeating: 0x41, count: 512)]
                )
            }
        }
        let walBefore = FileDurabilityProbe.byteCount(directory.appendingPathComponent("project.sqlite-wal"))
        let report = try await database.checkpoint(.truncate)
        #expect(walBefore > 0)
        #expect(report.walByteCountAfter == 0)
        try await database.close()
    }

    @Test("A write on a read-only handle is a typed refusal")
    func readOnlyRefusesWrites() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("ReadOnly")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("project.sqlite")
        let writable = try await ProjectDatabaseActor.open(at: url)
        try await writable.close()

        let readOnly = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        await #expect(throws: ZPDFPersistenceError.writeOnReadOnlyPackage) {
            try await readOnly.write { db in try db.execute(sql: "DELETE FROM project") }
        }
        await #expect(throws: ZPDFPersistenceError.writeOnReadOnlyPackage) {
            _ = try await readOnly.checkpoint(.truncate)
        }
        try await readOnly.close()
    }
}

/// A one-shot flag two tasks can share without an actor hop in the hot path.
final class SignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func signal() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSignalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// File sizes for tests, without exposing more of `FileDurability` than production needs.
enum FileDurabilityProbe {
    static func byteCount(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}
