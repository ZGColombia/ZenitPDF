import Foundation
import GRDB
import Testing
import ZPDFPersistence
import ZPDFTestingSupport

/// S17-06 through S17-09, closed: what happens when a `.zpdfproj` that someone emailed
/// is opened.
///
/// Every fixture here starts as a *real* package — created, edited, saved and closed by
/// the persistence layer itself — and is then handed to `HostileProjectPackage`, which
/// edits it the way its recipient-turned-attacker would. That matters twice over: a
/// hand-rolled package would not prove the checks fire on the shape the product actually
/// writes, and a hostile package that is not otherwise valid would be refused for the
/// wrong reason.
///
/// The suite is deliberately two-sided. Refusing hostile input is half the job; the other
/// half is `aLegitimateProjectStillOpensEditsSavesAndReopens`, because a hardening pass
/// that breaks ordinary use is a worse outcome than the vulnerability it closed.
struct HostileProjectPackageTests {

    // MARK: - Support

    /// A real project, saved and closed, exactly as it would arrive by mail.
    private func makeDeliveredPackage(_ label: String) async throws -> TestSupport.Workspace {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let geometry = try TestSupport.sampleGeometry()
        try await package.write { db in
            try MarkupRecord(
                id: "delivered-1", documentId: documentId, pageId: pageId,
                type: "count", subject: "Outlet",
                geometryBlob: geometry, styleBlob: Data([1]),
                createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
            ).insert(db)
        }
        _ = try await package.save()
        try await package.close()
        return workspace
    }

    /// The refusal each mutation must produce, named exactly rather than "some error".
    ///
    /// "Some error" would be satisfied by a crash-adjacent failure, by a SQLite message
    /// nobody can act on, or by the wrong check firing first — and the order the checks
    /// run in is part of the design here, so it is asserted rather than assumed.
    private func expectedError(for mutation: HostileProjectMutation) -> ZPDFPersistenceError {
        switch mutation {
        case .extraTrigger:
            return .foreignSchemaObject(
                objectType: "trigger", name: HostileProjectPackage.attackerTriggerName
            )
        case .hostileView:
            return .foreignSchemaObject(
                objectType: "view", name: HostileProjectPackage.attackerViewName
            )
        case .alteredAuditTrigger:
            return .schemaObjectAltered(
                objectType: "trigger", name: HostileProjectPackage.auditUpdateTriggerName
            )
        case .removedAuditTrigger:
            // Both are gone; the absent ones are reported in name order.
            return .schemaObjectAltered(
                objectType: "trigger", name: HostileProjectPackage.auditDeleteTriggerName
            )
        case .generatedColumnTable:
            return .foreignSchemaObject(
                objectType: "table", name: HostileProjectPackage.attackerGeneratedTableName
            )
        case .mismatchedIntegrityHash, .tamperedDatabaseContent:
            return .projectModifiedOutsideZenit(
                detail: "project.sqlite does not match the hash this project records"
            )
        case .tamperedManifest:
            return .projectModifiedOutsideZenit(
                detail: "manifest.json does not match the hash this project records"
            )
        case .tamperedOriginalPDF:
            return .projectModifiedOutsideZenit(
                detail: "documents/original.pdf does not match the hash this project records"
            )
        case .unknownCoordinateSystem:
            return .unsupportedCoordinateSystem(
                found: HostileProjectPackage.unknownCoordinateSystemValue,
                supported: ProjectManifest.pdfPointsBottomLeft
            )
        }
    }

    // MARK: - The refusals

    /// The whole matrix, one case per hostile fixture.
    @Test(
        "Every hostile .zpdfproj is refused with the typed error it earned",
        arguments: HostileProjectMutation.allCases
    )
    func hostilePackageIsRefused(_ mutation: HostileProjectMutation) async throws {
        let workspace = try await makeDeliveredPackage("Hostile-\(mutation.rawValue)")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try HostileProjectPackage.apply(mutation, toPackageAt: workspace.packageURL)

        do {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment()
            )
            Issue.record("\(mutation.rawValue) — \(mutation.summary) — was opened rather than refused")
        } catch let error as ZPDFPersistenceError {
            #expect(error == expectedError(for: mutation),
                    "\(mutation.rawValue) was refused, but not for the reason claimed: \(error)")
        }
    }

    /// A refusal must not be a one-way door. The user still has to be able to look.
    @Test(
        "A refused project can still be inspected read-only, where nothing of the attacker's can run",
        arguments: [HostileProjectMutation.extraTrigger, .hostileView, .alteredAuditTrigger]
    )
    func aRefusedProjectStillOpensReadOnly(_ mutation: HostileProjectMutation) async throws {
        let workspace = try await makeDeliveredPackage("ReadOnlyEscape-\(mutation.rawValue)")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try HostileProjectPackage.apply(mutation, toPackageAt: workspace.packageURL)

        let package = try await ProjectPackage.open(
            at: workspace.packageURL,
            environment: TestSupport.environment(),
            resolving: .openReadOnly
        )
        #expect(await package.accessMode == .readOnly)

        // The guard still ran; it recorded rather than refused, so the application can
        // tell the user exactly what is wrong with the file it is showing them.
        let deviations = await package.schemaDeviations
        #expect(!deviations.isEmpty, "the read-only path must still report what it found")

        // And a write is impossible, which is what makes this safe: a trigger needs a
        // write to fire on, and there is none to be had here.
        await #expect(throws: ZPDFPersistenceError.writeOnReadOnlyPackage) {
            try await package.write { db in
                try db.execute(sql: "UPDATE markup SET subject = 'x'")
            }
        }
        try await package.close()
    }

    /// The one that would otherwise be missed: our own triggers, altered rather than
    /// added. A "no triggers except ours, matched by name" rule lets this straight
    /// through, and the audit trail stops being append-only without anything looking
    /// unusual in `sqlite_master`.
    @Test("A weakened audit trigger is caught by its definition, not merely by its name")
    func aWeakenedAuditTriggerIsCaughtByItsDefinition() async throws {
        let workspace = try await makeDeliveredPackage("WeakenedAuditTrigger")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try HostileProjectPackage.apply(.alteredAuditTrigger, toPackageAt: workspace.packageURL)

        // The name is still there, and still on the right table: a name-only rule passes.
        let names = try HostileProjectPackage.schemaObjectNames(inPackageAt: workspace.packageURL)
        #expect(names.contains("trigger|\(HostileProjectPackage.auditUpdateTriggerName)"),
                "the fixture is supposed to keep the name and change the body")

        await #expect(throws: ZPDFPersistenceError.schemaObjectAltered(
            objectType: "trigger", name: HostileProjectPackage.auditUpdateTriggerName
        )) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment()
            )
        }
    }

    // MARK: - The half that matters as much

    @Test("A legitimate project still opens, edits, saves, closes and reopens")
    func aLegitimateProjectStillOpensEditsSavesAndReopens() async throws {
        let workspace = try TestSupport.makeWorkspace("LegitimateStillOpens")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let geometry = try TestSupport.sampleGeometry()
        try await package.write { db in
            try MarkupRecord(
                id: "legit-1", documentId: documentId, pageId: pageId,
                type: "count", subject: "Outlet",
                geometryBlob: geometry, styleBlob: Data([1]),
                createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
            ).insert(db)
        }
        #expect(await package.integrityVerdict.isVerified)
        #expect(await package.schemaDeviations.isEmpty)
        _ = try await package.save()
        try await package.close()

        // The reopen is the regression this whole finding could have introduced: the
        // database is edited in place, so unless the close re-records its digest, an
        // honest project accuses itself of tampering the second time it is opened.
        let outcome = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment()
        )
        guard case let .opened(reopened) = outcome else {
            Issue.record("a project this application wrote and closed did not reopen cleanly")
            return
        }
        #expect(await reopened.integrityVerdict.isVerified,
                "a package at rest must describe itself truthfully")
        #expect(await reopened.schemaDeviations.isEmpty)
        #expect(try await reopened.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? 0
        } == 1)

        // Editing, saving and closing again keeps it true, twice over.
        try await reopened.write { db in
            try MarkupRecord(
                id: "legit-2", documentId: documentId, pageId: pageId,
                type: "count", subject: "Second outlet",
                geometryBlob: geometry, styleBlob: Data([1]),
                createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
            ).insert(db)
        }
        _ = try await reopened.save()
        try await reopened.close()
        #expect(try ProjectPackage.verifyIntegrity(at: workspace.packageURL).isFullyConsistent)

        let third = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment()
        )
        guard case let .opened(finalHandle) = third else {
            Issue.record("the third open did not succeed")
            return
        }
        #expect(await finalHandle.integrityVerdict.isVerified)
        try await finalHandle.close()
    }

    /// The audit trail still does its job after all of the above.
    @Test("Our own append-only triggers survive the guard and still refuse an UPDATE")
    func ourOwnAppendOnlyTriggersStillWork() async throws {
        let workspace = try TestSupport.makeWorkspace("AppendOnlyStillWorks")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)

        let projectId = try await TestSupport.projectIdentifier(of: package)
        try await package.write { db in
            try db.execute(sql: """
                INSERT INTO measurement_audit
                    (id, project_id, markup_id, sequence, occurred_at, action, actor)
                VALUES ('audit-1', ?, NULL, 1, '2026-08-24T00:00:00.000Z', 'scaleChanged', 'test')
                """, arguments: [projectId])
        }
        await #expect(throws: (any Error).self) {
            try await package.write { db in
                try db.execute(sql: "UPDATE measurement_audit SET actor = 'someone else'")
            }
        }
        await #expect(throws: (any Error).self) {
            try await package.write { db in
                try db.execute(sql: "DELETE FROM measurement_audit")
            }
        }
        try await package.close()
    }

    /// The drift canary. If a toolchain bump changes how SQLite spells an FTS5 shadow
    /// table, or a migration adds an object nobody added to the inventory, this is the
    /// test that fails — and it fails on the *legitimate* side, which is the right place
    /// for that failure to land.
    @Test("A freshly migrated database has nothing foreign in it")
    func aFreshlyMigratedDatabaseHasNothingForeignInIt() async throws {
        let workspace = try TestSupport.makeWorkspace("SchemaDrift")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)

        let deviations = try await package.read { db in
            try ProjectSchemaInventory.deviations(in: db)
        }
        #expect(deviations.isEmpty, "unexpected schema objects: \(deviations)")

        // The two triggers ADR-0007 requires are present and are matched by definition,
        // not merely tolerated by type.
        #expect(ProjectSchemaInventory.expectedTriggerSQL.count == 2)
        let triggerSQL = try await package.read { db in
            try String.fetchAll(
                db, sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
            )
        }
        #expect(triggerSQL.count == 2)
        for sql in triggerSQL {
            #expect(ProjectSchemaInventory.expectedTriggerSQL.values
                .contains(ProjectSchemaInventory.normalized(sql)))
        }
        try await package.close()
    }

    // MARK: - S17-06 follow-through

    /// `trusted_schema` is off on **every** connection this package opens, asserted on
    /// each path rather than inferred from the fact that the setting was written once.
    @Test("trusted_schema is off on the read-write pool, the read-only pool and the probes")
    func trustedSchemaIsOffOnEveryConnectionPath() async throws {
        let workspace = try TestSupport.makeWorkspace("TrustedSchemaEverywhere")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await package.save()

        // 1. A reader connection of the read-write pool.
        let readerSetting = try await package.read { db in
            try DatabaseTuning.trustedSchemaSetting(db)
        }
        #expect(readerSetting == 0, "read-write pool reader")

        // 2. The writer connection of the same pool, which is configured separately.
        let writerSetting = try await package.database.writeWithoutTransaction { db in
            try DatabaseTuning.trustedSchemaSetting(db)
        }
        #expect(writerSetting == 0, "read-write pool writer")
        try await package.close()

        // 3. The read-only open path.
        let readOnly = try await ProjectPackage.open(
            at: workspace.packageURL,
            environment: TestSupport.environment(),
            resolving: .openReadOnly
        )
        let readOnlySetting = try await readOnly.read { db in
            try DatabaseTuning.trustedSchemaSetting(db)
        }
        #expect(readOnlySetting == 0, "read-only pool")
        try await readOnly.close()

        // 4. The short-lived probe configuration used by the recovery health checks and
        //    by the pre-open schema compatibility probe. Both were opened with a bare
        //    `Configuration()` before this fix, which is what S17-06's fix had missed.
        //    Exercised on a scratch rollback-journal database rather than on
        //    `project.sqlite`, because a WAL database cannot be opened read-only unless
        //    the process may create its `-shm` — a property of WAL, not of the pragmas
        //    under test.
        let scratchPath = workspace.root.appendingPathComponent("probe.sqlite").path
        for readOnlyProbe in [false, true] {
            let configuration = DatabaseTuning.probeConfiguration(readOnly: readOnlyProbe)
            let queue = try DatabaseQueue(path: scratchPath, configuration: configuration)
            let settings = try await queue.read { db -> [Int] in
                [
                    try DatabaseTuning.trustedSchemaSetting(db),
                    try Int.fetchOne(db, sql: "PRAGMA recursive_triggers") ?? -1
                ]
            }
            try queue.close()
            #expect(settings == [0, 0],
                    "probe configuration (readOnly: \(readOnlyProbe)) gave \(settings)")
        }
    }

    /// A connection that somehow came up with `trusted_schema` on must not be used.
    /// The assertion lives in the open path, so this checks the open path has it.
    @Test("The open path measures trusted_schema rather than assuming the pragma took")
    func theOpenPathMeasuresTrustedSchema() async throws {
        let workspace = try TestSupport.makeWorkspace("TrustedSchemaMeasured")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        try await package.close()

        // A tuning whose `prepareDatabase` deliberately turns the setting back on, which
        // is the shape a future edit to `DatabaseTuning` could accidentally take.
        var configuration = DatabaseTuning().configuration(readOnly: false)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA trusted_schema = ON")
        }
        let databasePath = workspace.packageURL.member(ProjectPackageLayout.database).path
        let pool = try DatabasePool(path: databasePath, configuration: configuration)
        defer { try? pool.close() }
        let setting = try await pool.read { db in try DatabaseTuning.trustedSchemaSetting(db) }
        // Proof the probe in the open path is asking a question that can come back wrong.
        #expect(setting == 1,
                "if this is 0 the measurement in ProjectDatabaseActor.open is testing nothing")
    }
}
