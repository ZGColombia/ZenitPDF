import Foundation
import SQLite3
import Testing
import ZPDFTestingSupport

/// The hostile `.zpdfproj` mutators, tested on their own.
///
/// `ZPDFPersistence` is where these fixtures earn their keep — it is the package that
/// opens a project and has to refuse the hostile ones — but a fixture that silently does
/// nothing turns a security test green for the wrong reason. So the mutations are
/// asserted here, against a stand-in package this test builds itself, with no dependency
/// on the package under attack.
///
/// The property that matters most is the least obvious one: after a mutation that
/// changes `project.sqlite`, `integrity.json` is left **consistent again**. An attacker
/// who plants a trigger and forgets to refresh the recorded digest is caught by the hash
/// check rather than by the schema check, and the downstream test would then prove
/// nothing about schema checking at all.
struct HostileProjectPackageFixtureTests {

    // MARK: - A stand-in package

    /// Builds the smallest thing the mutators need: a database with the two tables they
    /// touch, a manifest, and an integrity record that matches both.
    private func makeStandInPackage(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(ProcessInfo.processInfo.globallyUniqueString)",
                                    isDirectory: true)
        let packageURL = root.appendingPathComponent("StandIn.zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("documents", isDirectory: true),
            withIntermediateDirectories: true
        )

        let databaseURL = packageURL.appendingPathComponent("project.sqlite")
        FileManager.default.createFile(atPath: databaseURL.path, contents: Data())
        try HostileProjectPackage.executeSQL(inPackageAt: packageURL, [
            "CREATE TABLE markup (id TEXT PRIMARY KEY NOT NULL, label TEXT)",
            "CREATE TABLE measurement_audit (id TEXT PRIMARY KEY NOT NULL, actor TEXT NOT NULL)",
            """
            CREATE TRIGGER measurement_audit_no_update
            BEFORE UPDATE ON measurement_audit
            BEGIN SELECT RAISE(ABORT, 'measurement_audit is append-only'); END
            """,
            """
            CREATE TRIGGER measurement_audit_no_delete
            BEFORE DELETE ON measurement_audit
            BEGIN SELECT RAISE(ABORT, 'measurement_audit is append-only'); END
            """
        ])

        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "coordinateSystem": "PDF_POINTS_BOTTOM_LEFT",
            "displayName": "Stand-in"
        ]
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        try JSONSerialization
            .data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
            .write(to: manifestURL)

        let pdfURL = packageURL
            .appendingPathComponent("documents", isDirectory: true)
            .appendingPathComponent("original.pdf")
        try Data("%PDF-1.7\n% stand-in\n".utf8).write(to: pdfURL)

        let integrity: [String: Any] = [
            "manifestSha256": try HostileProjectPackage.sha256OfFile(at: manifestURL),
            "databaseSha256": try HostileProjectPackage.sha256OfFile(at: databaseURL),
            "originalPdfSha256": try HostileProjectPackage.sha256OfFile(at: pdfURL),
            "workingPdfSha256": String(repeating: "0", count: 64),
            "saveToken": "stand-in",
            "savedAt": "2026-08-24T00:00:00.000Z",
            "generation": 1
        ]
        try JSONSerialization
            .data(withJSONObject: integrity, options: [.sortedKeys, .prettyPrinted])
            .write(to: packageURL.appendingPathComponent("integrity.json"))
        return packageURL
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let decoded = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return decoded as? [String: Any] ?? [:]
    }

    // MARK: - Tests

    @Test("Every schema mutation lands, and leaves the integrity record consistent again",
          arguments: [HostileProjectMutation.extraTrigger, .hostileView,
                      .alteredAuditTrigger, .removedAuditTrigger, .generatedColumnTable])
    func schemaMutationsLandAndStaySelfConsistent(_ mutation: HostileProjectMutation) throws {
        let packageURL = try makeStandInPackage("SchemaMutation")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        // Definitions, not names: `alteredAuditTrigger` changes only a body, and a
        // name-only comparison would call that "changed nothing".
        let before = try HostileProjectPackage.schemaObjectDefinitions(inPackageAt: packageURL)
        try HostileProjectPackage.apply(mutation, toPackageAt: packageURL)
        let after = try HostileProjectPackage.schemaObjectDefinitions(inPackageAt: packageURL)
        #expect(before != after, "\(mutation.rawValue) — \(mutation.summary) — changed nothing")
        let names = try HostileProjectPackage.schemaObjectNames(inPackageAt: packageURL)

        switch mutation {
        case .extraTrigger:
            #expect(names.contains("trigger|\(HostileProjectPackage.attackerTriggerName)"))
        case .hostileView:
            #expect(names.contains("view|\(HostileProjectPackage.attackerViewName)"))
        case .alteredAuditTrigger:
            // Same name, different body: the case a name-only rule would wave through.
            #expect(names.contains("trigger|\(HostileProjectPackage.auditUpdateTriggerName)"))
            #expect(names.contains("trigger|\(HostileProjectPackage.auditDeleteTriggerName)"))
        case .removedAuditTrigger:
            #expect(!names.contains("trigger|\(HostileProjectPackage.auditUpdateTriggerName)"))
            #expect(!names.contains("trigger|\(HostileProjectPackage.auditDeleteTriggerName)"))
        case .generatedColumnTable:
            #expect(names.contains("table|\(HostileProjectPackage.attackerGeneratedTableName)"))
        default:
            Issue.record("\(mutation.rawValue) is not a schema mutation")
        }

        let recorded = try jsonObject(
            at: packageURL.appendingPathComponent("integrity.json")
        )["databaseSha256"] as? String
        let actual = try HostileProjectPackage.sha256OfFile(
            at: packageURL.appendingPathComponent("project.sqlite")
        )
        #expect(recorded == actual,
                "a schema mutation must not double as a hash mutation, or the downstream test proves nothing")
    }

    @Test("The hash mutations leave a genuine mismatch behind")
    func hashMutationsLeaveAMismatch() throws {
        let packageURL = try makeStandInPackage("HashMutation")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        try HostileProjectPackage.apply(.mismatchedIntegrityHash, toPackageAt: packageURL)
        let recorded = try jsonObject(
            at: packageURL.appendingPathComponent("integrity.json")
        )["databaseSha256"] as? String
        let actual = try HostileProjectPackage.sha256OfFile(
            at: packageURL.appendingPathComponent("project.sqlite")
        )
        #expect(recorded == String(repeating: "a", count: 64))
        #expect(recorded != actual)
    }

    @Test("Editing rows changes the database without touching the schema")
    func tamperedContentLeavesTheSchemaAlone() throws {
        let packageURL = try makeStandInPackage("ContentMutation")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        // The stand-in has no `project` or `document` table, so the realistic mutation is
        // spelled here against the tables it does have — same shape, same consequence.
        let databaseURL = packageURL.appendingPathComponent("project.sqlite")
        let before = try HostileProjectPackage.sha256OfFile(at: databaseURL)
        let schemaBefore = try HostileProjectPackage.schemaObjectNames(inPackageAt: packageURL)
        try HostileProjectPackage.executeSQL(inPackageAt: packageURL, [
            "INSERT INTO markup (id, label) VALUES ('rewritten', 'by someone else')"
        ])
        #expect(try HostileProjectPackage.sha256OfFile(at: databaseURL) != before)
        #expect(try HostileProjectPackage.schemaObjectNames(inPackageAt: packageURL) == schemaBefore,
                "a data edit must leave the schema untouched — that is the whole point of it")
    }

    @Test("A manifest edit that keeps the recorded hash honest, and one that does not")
    func manifestMutations() throws {
        let packageURL = try makeStandInPackage("ManifestMutation")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let integrityURL = packageURL.appendingPathComponent("integrity.json")

        // The competent attacker: the manifest changes and its digest is refreshed, so
        // the only fault left is the coordinate system itself.
        try HostileProjectPackage.apply(.unknownCoordinateSystem, toPackageAt: packageURL)
        #expect(try jsonObject(at: manifestURL)["coordinateSystem"] as? String
                == HostileProjectPackage.unknownCoordinateSystemValue)
        #expect(try jsonObject(at: integrityURL)["manifestSha256"] as? String
                == (try HostileProjectPackage.sha256OfFile(at: manifestURL)))

        // The careless one: the manifest changes and the digest is left as it was.
        try HostileProjectPackage.apply(.tamperedManifest, toPackageAt: packageURL)
        #expect(try jsonObject(at: manifestURL)["displayName"] as? String
                == "Rewritten by someone else")
        #expect(try jsonObject(at: integrityURL)["manifestSha256"] as? String
                != (try HostileProjectPackage.sha256OfFile(at: manifestURL)))
    }

    @Test("A mutation against a package that is not there is a typed error, not a crash")
    func missingMembersAreTypedErrors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Empty-\(ProcessInfo.processInfo.globallyUniqueString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: HostileProjectFixtureError.packageMemberMissing(
            relativePath: HostileProjectPackage.databasePath
        )) {
            try HostileProjectPackage.apply(.extraTrigger, toPackageAt: root)
        }
        #expect(throws: HostileProjectFixtureError.packageMemberMissing(
            relativePath: HostileProjectPackage.integrityPath
        )) {
            try HostileProjectPackage.apply(.mismatchedIntegrityHash, toPackageAt: root)
        }
    }
}
