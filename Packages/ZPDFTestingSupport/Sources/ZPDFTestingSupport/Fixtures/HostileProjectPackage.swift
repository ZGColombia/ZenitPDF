import CryptoKit
import Foundation
import SQLite3

/// Hostile `.zpdfproj` project packages, for the S17 security suite.
///
/// A `.zpdfproj` is a *document*: it travels by mail and by shared folder exactly as a
/// PDF does, so every byte in it — including the SQLite schema — may have been written
/// by whoever sent it. ``HostileFixtures`` covers the PDF half of that problem; this
/// covers the package half.
///
/// ### Why these are mutations rather than whole packages
///
/// A believable hostile project has to be a *real* project first: a valid manifest, a
/// migrated database, a genuine PDF inside. Only `ZPDFPersistence` can produce one, and
/// this package deliberately depends on nothing (not even on `ZPDFPersistence`, which
/// depends on *it*). So a hostile fixture here is the attacker's half of the work: take
/// a legitimate package that the persistence layer just wrote and closed, and edit it
/// the way someone who received it and wanted more out of it would.
///
/// Everything below is done with the platform's own SQLite and `JSONSerialization`, so
/// no dependency is added to this package and no schema definition is duplicated from
/// `ZPDFPersistence` — a duplicate would drift, and a drifted fixture proves nothing.
///
/// ### The attacker is assumed to be competent
///
/// After a mutation that changes `project.sqlite`, the integrity record is rewritten so
/// that the package is *self-consistent again*. That matters: an attacker who plants a
/// trigger and forgets to refresh `integrity.json` would be caught by the hash check
/// rather than by the schema check, and the test would pass for the wrong reason. Only
/// the fixtures whose whole point is a hash mismatch leave one behind.
public enum HostileProjectMutation: String, Sendable, Hashable, CaseIterable {

    /// An attacker-authored trigger on the `markup` table.
    ///
    /// The realistic payload: it fires inside one of *our* transactions, on our thread,
    /// and rewrites the user's own takeoff rows as they are created.
    case extraTrigger

    /// An attacker-authored view. SQL text stored in the schema, evaluated whenever
    /// anything selects from it, and — before `trusted_schema = OFF` — a route to
    /// functions SQLite does not mark innocuous.
    case hostileView

    /// Our own append-only audit triggers, subtly altered.
    ///
    /// `measurement_audit_no_update` is re-created with a `WHEN` clause that makes the
    /// `RAISE(ABORT)` fire only for rows the attacker does not care about, which leaves
    /// a trigger of the right name and the right shape that no longer enforces
    /// append-only. This is the case a "no triggers except ours, by name" rule misses.
    case alteredAuditTrigger

    /// Our append-only audit triggers dropped outright, leaving the trail writable.
    case removedAuditTrigger

    /// An extra table carrying a generated column — an expression stored in the schema
    /// and evaluated on every read of the table.
    case generatedColumnTable

    /// `integrity.json` claims a `databaseSha256` that matches nothing.
    case mismatchedIntegrityHash

    /// The database's *rows* edited behind the app's back, with the integrity record
    /// left as it was. No schema object is added, so only the hash notices.
    case tamperedDatabaseContent

    /// `manifest.json` edited after the fact, with its recorded hash left as it was.
    case tamperedManifest

    /// `documents/original.pdf` — the evidence copy this package never rewrites —
    /// replaced, with the integrity record left as it was.
    case tamperedOriginalPDF

    /// A manifest declaring a coordinate convention this build has never heard of,
    /// with `manifestSha256` refreshed so the manifest hash still matches.
    case unknownCoordinateSystem

    /// A one-line description, used in test names and in the security report.
    public var summary: String {
        switch self {
        case .extraTrigger: return "an attacker-authored trigger fires inside our transactions"
        case .hostileView: return "an attacker-authored view stores SQL in the schema"
        case .alteredAuditTrigger: return "our append-only audit trigger, silently weakened"
        case .removedAuditTrigger: return "our append-only audit triggers, dropped"
        case .generatedColumnTable: return "a generated column stores an expression in the schema"
        case .mismatchedIntegrityHash: return "integrity.json claims a database hash that matches nothing"
        case .tamperedDatabaseContent: return "database rows edited outside Zenit PDF"
        case .tamperedManifest: return "manifest.json edited outside Zenit PDF"
        case .tamperedOriginalPDF: return "documents/original.pdf replaced"
        case .unknownCoordinateSystem: return "manifest declares an unknown coordinate system"
        }
    }
}

/// Everything that can go wrong while *building* a hostile fixture.
///
/// Building one is ordinary file and SQLite work; it either succeeds or the fixture is
/// not a fixture. These are separate from ``FixtureError`` because a project package is
/// not a PDF and conflating the two would make a failing test ambiguous.
public enum HostileProjectFixtureError: Error, Sendable, Equatable, CustomStringConvertible {
    case packageMemberMissing(relativePath: String)
    case sqliteOpenFailed(path: String, code: Int32)
    case sqliteStatementFailed(sql: String, message: String)
    case jsonUnreadable(relativePath: String, reason: String)
    case jsonNotAnObject(relativePath: String)

    public var description: String {
        switch self {
        case let .packageMemberMissing(path):
            return "the package has no \(path)"
        case let .sqliteOpenFailed(path, code):
            return "sqlite could not open \(path) (code \(code))"
        case let .sqliteStatementFailed(sql, message):
            return "sqlite refused \(sql): \(message)"
        case let .jsonUnreadable(path, reason):
            return "\(path) could not be read: \(reason)"
        case let .jsonNotAnObject(path):
            return "\(path) is not a JSON object"
        }
    }
}

/// Applies ``HostileProjectMutation`` to a real `.zpdfproj` on disk.
public enum HostileProjectPackage {

    // MARK: - Layout
    //
    // These four strings mirror `ProjectPackageLayout` in `ZPDFPersistence`. They are
    // repeated rather than imported because that package depends on this one, so the
    // dependency cannot run the other way. `ManifestConsistencyTests` in this package
    // is where a drift would be caught.

    public static let manifestPath = "manifest.json"
    public static let integrityPath = "integrity.json"
    public static let databasePath = "project.sqlite"
    public static let originalPDFPath = "documents/original.pdf"

    /// The coordinate system string a hostile manifest claims.
    public static let unknownCoordinateSystemValue = "ATTACKER_CHOSEN_SPACE"

    /// The name of the trigger ``HostileProjectMutation/extraTrigger`` plants.
    public static let attackerTriggerName = "zpdf_attacker_trigger"
    /// The name of the view ``HostileProjectMutation/hostileView`` plants.
    public static let attackerViewName = "zpdf_attacker_view"
    /// The name of the table ``HostileProjectMutation/generatedColumnTable`` plants.
    public static let attackerGeneratedTableName = "zpdf_attacker_generated"
    /// The audit trigger ``HostileProjectMutation/alteredAuditTrigger`` rewrites.
    public static let auditUpdateTriggerName = "measurement_audit_no_update"
    /// The audit trigger dropped alongside it by ``HostileProjectMutation/removedAuditTrigger``.
    public static let auditDeleteTriggerName = "measurement_audit_no_delete"

    // MARK: - Entry point

    /// Turns a legitimate, closed `.zpdfproj` into a hostile one.
    ///
    /// The package must be closed: SQLite is opened directly on `project.sqlite`. A `-wal`
    /// left beside it is replayed, not deleted, and checkpointed into the main file after
    /// the edits (BH-686), so the edits land in the file a later reader actually opens.
    public static func apply(_ mutation: HostileProjectMutation, toPackageAt url: URL) throws {
        switch mutation {
        case .extraTrigger:
            // Hung off a table the schema already has and writing only into that table,
            // so the trigger is the *only* thing foreign about this package. An attacker
            // who also had to add a table would be caught by the table, and the test
            // would then prove nothing about triggers.
            try executeSQL(inPackageAt: url, [
                """
                CREATE TRIGGER \(attackerTriggerName) AFTER INSERT ON markup
                BEGIN
                    UPDATE markup SET label = 'owned' WHERE id = new.id;
                END
                """
            ])
            try refreshDatabaseHash(inPackageAt: url)

        case .hostileView:
            try executeSQL(inPackageAt: url, [
                """
                CREATE VIEW \(attackerViewName) AS
                SELECT id, subject, hex(randomblob(16)) AS payload FROM markup
                """
            ])
            try refreshDatabaseHash(inPackageAt: url)

        case .alteredAuditTrigger:
            // Same name, same table, same timing, same RAISE — and a WHEN clause that
            // means it never actually fires for the rows the attacker wants to rewrite.
            try executeSQL(inPackageAt: url, [
                "DROP TRIGGER IF EXISTS \(auditUpdateTriggerName)",
                """
                CREATE TRIGGER \(auditUpdateTriggerName)
                BEFORE UPDATE ON measurement_audit
                WHEN old.actor = 'nobody'
                BEGIN SELECT RAISE(ABORT, 'measurement_audit is append-only'); END
                """
            ])
            try refreshDatabaseHash(inPackageAt: url)

        case .removedAuditTrigger:
            try executeSQL(inPackageAt: url, [
                "DROP TRIGGER IF EXISTS \(auditUpdateTriggerName)",
                "DROP TRIGGER IF EXISTS \(auditDeleteTriggerName)"
            ])
            try refreshDatabaseHash(inPackageAt: url)

        case .generatedColumnTable:
            try executeSQL(inPackageAt: url, [
                """
                CREATE TABLE \(attackerGeneratedTableName) (
                    id INTEGER PRIMARY KEY,
                    raw TEXT,
                    derived TEXT GENERATED ALWAYS AS (upper(raw) || '-owned') VIRTUAL
                )
                """
            ])
            try refreshDatabaseHash(inPackageAt: url)

        case .mismatchedIntegrityHash:
            try mutateJSONObject(at: url.fixtureMember(integrityPath), relativePath: integrityPath) {
                $0["databaseSha256"] = String(repeating: "a", count: 64)
            }

        case .tamperedDatabaseContent:
            // No schema object, no new table: only the bytes of rows the user owns.
            try executeSQL(inPackageAt: url, [
                "UPDATE project SET name = 'Rewritten by someone else'",
                "UPDATE document SET display_name = 'Rewritten by someone else'"
            ])

        case .tamperedManifest:
            try mutateJSONObject(at: url.fixtureMember(manifestPath), relativePath: manifestPath) {
                $0["displayName"] = "Rewritten by someone else"
            }

        case .tamperedOriginalPDF:
            let pdfURL = url.fixtureMember(originalPDFPath)
            guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                throw HostileProjectFixtureError.packageMemberMissing(relativePath: originalPDFPath)
            }
            var bytes = try Data(contentsOf: pdfURL)
            // Append rather than truncate: still a parseable PDF, different bytes. The
            // file is written read-only by the create path, so permissions come back
            // first and go back afterwards.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pdfURL.path)
            bytes.append(contentsOf: Array("\n% appended by someone else\n".utf8))
            try bytes.write(to: pdfURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: pdfURL.path)

        case .unknownCoordinateSystem:
            let manifestURL = url.fixtureMember(manifestPath)
            try mutateJSONObject(at: manifestURL, relativePath: manifestPath) {
                $0["coordinateSystem"] = unknownCoordinateSystemValue
            }
            // A competent attacker keeps the package self-consistent, so the only fault
            // left is the coordinate system itself.
            let manifestHash = try sha256OfFile(at: manifestURL)
            try mutateJSONObject(at: url.fixtureMember(integrityPath), relativePath: integrityPath) {
                $0["manifestSha256"] = manifestHash
            }
        }
    }

    // MARK: - Building blocks

    /// Runs statements against `project.sqlite` with the platform's own SQLite.
    ///
    /// A `-wal` left by a writer that was killed holds *committed* transactions that
    /// are newer than `project.sqlite`, so it is never deleted: SQLite replays it on
    /// open, the statements run on top of it, and a `wal_checkpoint(TRUNCATE)` folds
    /// everything into the main file before the connection closes. The main file then
    /// holds the whole state, which is what `refreshDatabaseHash` and a later reader
    /// hash and open.
    public static func executeSQL(inPackageAt url: URL, _ statements: [String]) throws {
        let databaseURL = url.fixtureMember(databasePath)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw HostileProjectFixtureError.packageMemberMissing(relativePath: databasePath)
        }

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw HostileProjectFixtureError.sqliteOpenFailed(path: databaseURL.path, code: openResult)
        }
        defer { sqlite3_close_v2(database) }

        for statement in statements {
            var raw: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, statement, nil, nil, &raw)
            guard result == SQLITE_OK else {
                let message = raw.map { String(cString: $0) } ?? "sqlite result \(result)"
                sqlite3_free(raw)
                throw HostileProjectFixtureError.sqliteStatementFailed(sql: statement, message: message)
            }
            sqlite3_free(raw)
        }

        // A no-op for a rollback-journal database; for a WAL database it moves every
        // committed frame, including any replayed from a killed writer, into the main file.
        let checkpoint = "PRAGMA wal_checkpoint(TRUNCATE)"
        var raw: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, checkpoint, nil, nil, &raw)
        guard result == SQLITE_OK else {
            let message = raw.map { String(cString: $0) } ?? "sqlite result \(result)"
            sqlite3_free(raw)
            throw HostileProjectFixtureError.sqliteStatementFailed(sql: checkpoint, message: message)
        }
        sqlite3_free(raw)
    }

    /// Reads a JSON object member of the package, hands it to `body`, writes it back.
    public static func mutateJSONObject(
        at url: URL,
        relativePath: String,
        _ body: (inout [String: Any]) -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HostileProjectFixtureError.packageMemberMissing(relativePath: relativePath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HostileProjectFixtureError.jsonUnreadable(
                relativePath: relativePath, reason: error.localizedDescription
            )
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HostileProjectFixtureError.jsonUnreadable(
                relativePath: relativePath, reason: error.localizedDescription
            )
        }
        guard var object = decoded as? [String: Any] else {
            throw HostileProjectFixtureError.jsonNotAnObject(relativePath: relativePath)
        }
        body(&object)
        let encoded = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        )
        try encoded.write(to: url)
    }

    /// Rewrites `integrity.json`'s `databaseSha256` to whatever the database now hashes
    /// to, so a schema mutation is not also, accidentally, a hash mutation.
    public static func refreshDatabaseHash(inPackageAt url: URL) throws {
        let hash = try sha256OfFile(at: url.fixtureMember(databasePath))
        try mutateJSONObject(at: url.fixtureMember(integrityPath), relativePath: integrityPath) {
            $0["databaseSha256"] = hash
        }
    }

    /// Lowercase-hex SHA-256 of a file, streamed. Same shape as the persistence
    /// package's own hash, so a value written here is comparable with one written there.
    public static func sha256OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Names of every schema object in the package's database, as `type|name` pairs.
    ///
    /// Used by the assertions that a refusal happened for the reason claimed, and by
    /// the legitimate-package test that says the guard found nothing to object to.
    public static func schemaObjectNames(inPackageAt url: URL) throws -> [String] {
        try schemaRows(inPackageAt: url, sql:
            "SELECT type || '|' || name FROM sqlite_master ORDER BY type, name")
    }

    /// The same list, with each object's definition attached as `type|name|sql`.
    ///
    /// The distinction matters for exactly one fixture:
    /// ``HostileProjectMutation/alteredAuditTrigger`` leaves the *names* untouched and
    /// changes only a body, which is precisely why a name-only rule would miss it.
    public static func schemaObjectDefinitions(inPackageAt url: URL) throws -> [String] {
        try schemaRows(inPackageAt: url, sql: """
            SELECT type || '|' || name || '|' || COALESCE(replace(sql, char(10), ' '), '')
            FROM sqlite_master ORDER BY type, name
            """)
    }

    private static func schemaRows(inPackageAt url: URL, sql: String) throws -> [String] {
        let databaseURL = url.fixtureMember(databasePath)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw HostileProjectFixtureError.packageMemberMissing(relativePath: databasePath)
        }
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw HostileProjectFixtureError.sqliteOpenFailed(path: databaseURL.path, code: openResult)
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            let message = String(cString: sqlite3_errmsg(database))
            throw HostileProjectFixtureError.sqliteStatementFailed(sql: sql, message: message)
        }
        defer { sqlite3_finalize(prepared) }
        var names: [String] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            if let text = sqlite3_column_text(prepared, 0) {
                names.append(String(cString: text))
            }
        }
        return names
    }
}

extension URL {
    /// Resolves a package-relative path, splitting on `/` and appending component by
    /// component. Mirrors `URL.member(_:)` in `ZPDFPersistence`, which this package
    /// cannot import.
    func fixtureMember(_ relativePath: String) -> URL {
        var url = self
        for component in relativePath.split(separator: "/") {
            url = url.appendingPathComponent(String(component))
        }
        return url
    }
}
