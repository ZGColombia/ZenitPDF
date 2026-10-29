import Foundation
import GRDB
import Testing
import ZPDFPersistence
import ZPDFTestingSupport

/// S17 probe — is the `fts3_tokenizer` pointer primitive reachable from a schema the
/// attacker wrote?
///
/// Background, in one paragraph. SQLite's `fts3_tokenizer(name)` returns a **raw C
/// pointer** to a tokenizer as a blob, and its two-argument form
/// `fts3_tokenizer(name, blob)` *installs* the pointer in that blob as a tokenizer. That
/// is a function-pointer write, so SQLite treats the function as not "innocuous": with
/// `SQLITE_DBCONFIG_TRUSTED_SCHEMA` on (the default), SQL stored in the *schema* — a
/// view, a trigger, a CHECK constraint, an index expression — may call it; with
/// trusted_schema off, it may not. The project database is opened from a file that may
/// have come from anyone. These probes establish which of those two worlds we are in,
/// with output rather than reasoning.
///
/// **Measured answer, 2026-08-24, SQLite 3.51.0 as shipped in macOS:** the escalation is
/// closed by the library, not by us. The two-argument form refuses a pointer written as
/// SQL literal at all ("fts3_tokenizer requires bound parameters"), and any call reached
/// from a schema object is rejected with "unsafe use of fts3_tokenizer()" *even with
/// `trusted_schema` on*. So the honest severity of `trusted_schema = 1` here is low: what
/// remains is an attacker's own SQL logic running against the user's own project data,
/// and the day somebody registers a custom SQL function on this connection. These tests
/// stay as regression guards, because both halves of that sentence are one SQLite
/// version away from changing.
struct Fts3TokenizerProbeTests {

    private func scratchDatabase(_ label: String) throws -> (URL, DatabaseQueue) {
        let directory = try TestSupport.makeTemporaryDirectory(label)
        let url = directory.appendingPathComponent("probe.sqlite")
        return (directory, try DatabaseQueue(path: url.path))
    }

    /// Step 1: can the one-argument (read) form be called at all from ordinary SQL?
    @Test("Recorded: the fts3_tokenizer read form from ordinary statement SQL")
    func readFormFromStatementSQL() throws {
        let (directory, queue) = try scratchDatabase("Fts3Read")
        defer { try? FileManager.default.removeItem(at: directory) }
        var outcome = "unavailable"
        try queue.read { db in
            do {
                let blob = try Data.fetchOne(db, sql: "SELECT fts3_tokenizer('simple')")
                outcome = "callable, \(blob?.count ?? -1) bytes returned"
            } catch {
                outcome = "refused: \(error)"
            }
        }
        print("S17 fts3_tokenizer(name) from statement SQL: \(outcome)")
    }

    /// Step 2: the dangerous form. If this is refused, the primitive is off at the
    /// library level and nothing downstream matters.
    @Test("Recorded: the fts3_tokenizer write form from ordinary statement SQL")
    func writeFormFromStatementSQL() throws {
        let (directory, queue) = try scratchDatabase("Fts3Write")
        defer { try? FileManager.default.removeItem(at: directory) }
        var outcome = "unavailable"
        try queue.read { db in
            do {
                // A deliberately null pointer: if the write form is enabled this either
                // succeeds or fails with a *tokenizer* error, not "wrong number of
                // arguments". It is never dereferenced here.
                _ = try Data.fetchOne(
                    db,
                    sql: "SELECT fts3_tokenizer('zpdfprobe', x'0000000000000000')"
                )
                outcome = "ACCEPTED — the two-argument pointer-installing form is enabled"
            } catch {
                outcome = "refused: \(error)"
            }
        }
        print("S17 fts3_tokenizer(name, blob) from statement SQL: \(outcome)")
    }

    /// Step 3: the one that decides the severity. Statement SQL is *our* SQL — we never
    /// write that call. The attacker's SQL lives in the schema. This asks whether a
    /// trigger the attacker stored in the file can call it when we write to the table.
    @Test("Recorded: whether an attacker's trigger may call fts3_tokenizer")
    func writeFormFromAttackerTrigger() throws {
        let (directory, queue) = try scratchDatabase("Fts3Trigger")
        defer { try? FileManager.default.removeItem(at: directory) }

        var creation = "not attempted"
        var firing = "not attempted"
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE victim (id INTEGER PRIMARY KEY, note TEXT)")
            try db.execute(sql: "CREATE TABLE spoils (blob BLOB)")
            do {
                try db.execute(sql: """
                    CREATE TRIGGER attacker AFTER INSERT ON victim
                    BEGIN
                        INSERT INTO spoils (blob) VALUES (fts3_tokenizer('simple'));
                    END
                    """)
                creation = "accepted"
            } catch {
                creation = "refused: \(error)"
            }
        }
        guard creation == "accepted" else {
            print("S17 attacker trigger calling fts3_tokenizer: creation \(creation)")
            return
        }
        try queue.write { db in
            do {
                try db.execute(sql: "INSERT INTO victim (note) VALUES ('ordinary application write')")
                let stolen = try Data.fetchOne(db, sql: "SELECT blob FROM spoils LIMIT 1")
                firing = stolen == nil
                    ? "fired but produced nothing"
                    : "FIRED — the trigger obtained a \(stolen!.count)-byte raw tokenizer pointer"
            } catch {
                firing = "blocked at execution: \(error)"
            }
        }
        print("S17 attacker trigger calling fts3_tokenizer: creation \(creation); \(firing)")
        // The guard: whatever else changes, a raw tokenizer pointer must never reach SQL
        // that came out of the schema of a file we did not write.
        #expect(!firing.hasPrefix("FIRED"),
                "a schema-stored call to fts3_tokenizer obtained a function pointer — this is code execution from a document")
    }

    /// Step 4: does the documented mitigation actually work here, and does it cost us
    /// anything? `PRAGMA trusted_schema = OFF` is SQLite's own answer for a database that
    /// arrived from outside. A recommendation nobody measured is not a recommendation.
    @Test("Recorded: trusted_schema = OFF blocks the schema path and leaves FTS5 working")
    func trustedSchemaOffBlocksTheSchemaPath() throws {
        let (directory, queue) = try scratchDatabase("Fts3Mitigated")
        defer { try? FileManager.default.removeItem(at: directory) }

        var blocked = "not attempted"
        var fts5StillWorks = false
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE victim (id INTEGER PRIMARY KEY, note TEXT)")
            try db.execute(sql: "CREATE TABLE spoils (blob BLOB)")
            try db.execute(sql: """
                CREATE TRIGGER attacker AFTER INSERT ON victim
                BEGIN
                    INSERT INTO spoils (blob) VALUES (fts3_tokenizer('simple'));
                END
                """)
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
            do {
                try db.execute(sql: "INSERT INTO victim (note) VALUES ('ordinary application write')")
                let stolen = try Data.fetchOne(db, sql: "SELECT blob FROM spoils LIMIT 1")
                blocked = stolen == nil ? "no value reached the attacker" : "STILL FIRED"
            } catch {
                blocked = "blocked: \(error)"
            }
            // The cost side: the product's own search index is FTS5, so the mitigation is
            // only usable if FTS5 keeps working under it.
            do {
                try db.execute(sql: "CREATE VIRTUAL TABLE probe_fts USING fts5(body)")
                try db.execute(sql: "INSERT INTO probe_fts (body) VALUES ('concrete slab reinforcement')")
                let hits = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe_fts WHERE probe_fts MATCH 'slab'") ?? 0
                fts5StillWorks = hits == 1
            } catch {
                fts5StillWorks = false
                print("S17 FTS5 under trusted_schema=OFF: FAILED \(error)")
            }
        }
        print("S17 trusted_schema=OFF: attacker trigger \(blocked); fts5 usable = \(fts5StillWorks)")
        #expect(fts5StillWorks, "the mitigation must not cost the product its search index")
    }
}
