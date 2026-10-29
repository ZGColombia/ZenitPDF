import CryptoKit
import Foundation
import GRDB
import Testing
import ZPDFPersistence
import ZPDFTestingSupport

/// Bug hunt 2, persistence: the database-actor, value and hostile-package findings,
/// grouped in one suite. Each test names its ID and the old output.
struct Fix2LowBugTests {

    // MARK: - Support

    private func sha256(_ url: URL) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: url))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A real project, saved and closed, exactly as it would arrive by mail.
    private func makeDeliveredPackage(_ label: String) async throws -> TestSupport.Workspace {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        _ = try await package.save()
        try await package.close()
        return workspace
    }

    // MARK: - BH-182: a refused open leaves the bytes alone

    @Test("BH-182: a schema-guard refusal does not rewrite project.sqlite, so the second attempt says the same thing")
    func refusedOpenLeavesTheFileUntouched() async throws {
        let workspace = try await makeDeliveredPackage("Fix2RefusalBytes")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try HostileProjectPackage.apply(.extraTrigger, toPackageAt: workspace.packageURL)
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        let before = try sha256(databaseURL)
        let expected = ZPDFPersistenceError.foreignSchemaObject(
            objectType: "trigger", name: HostileProjectPackage.attackerTriggerName
        )

        for attempt in 1...2 {
            // Old output on attempt 2: projectModifiedOutsideZenit("project.sqlite does
            // not match…") — attempt 1 had built the pool read-write, primed the WAL and
            // checkpointed it into the file it was refusing.
            await #expect(throws: expected, "attempt \(attempt)") {
                _ = try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment())
            }
            #expect(try sha256(databaseURL) == before, "attempt \(attempt) changed the bytes it refused")
        }
    }

    // MARK: - BH-183: the probe's failures are typed

    @Test("BH-183: a probe that cannot read the file surfaces as databaseOpenFailed, not a raw engine error")
    func probeFailureIsTyped() async throws {
        let root = try TestSupport.makeTemporaryDirectory("Fix2ProbeTyped")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.sqlite")
        // A plausible header followed by noise: openable, unreadable.
        var bytes = Array("SQLite format 3\0".utf8)
        bytes.append(contentsOf: (0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try Data(bytes).write(to: url)

        do {
            _ = try await ProjectDatabaseActor.open(at: url)
            Issue.record("a file that is not a database must be refused")
        } catch let error as ZPDFPersistenceError {
            guard case .databaseOpenFailed = error else {
                Issue.record("unexpected typed error: \(error)")
                return
            }
        } catch {
            // Old output: GRDB.DatabaseError SQLITE_NOTADB out of the probe read.
            Issue.record("untyped error escaped open(): \(type(of: error)) \(error)")
        }
    }

    // MARK: - BH-592 / BH-593: tuning values that cannot be honoured are clamped

    @Test("BH-592/BH-593: a reader count of zero and an autocheckpoint of zero are clamped, not trapped or disabled")
    func tuningIsClamped() async throws {
        // Old output: GRDB precondition failure "maximumReaderCount must be at least 1"
        // — a trap the open path's catch could not turn into an error.
        let tuning = DatabaseTuning(maximumReaderCount: 0, checkpointPolicy: .automatic(pages: 0))
        #expect(tuning.configuration(readOnly: false).maximumReaderCount == 1)

        let root = try TestSupport.makeTemporaryDirectory("Fix2Tuning")
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try await ProjectDatabaseActor.open(at: root.appendingPathComponent("project.sqlite"), tuning: tuning)
        let autocheckpoint = try await handle.writeWithoutTransaction { db in
            try Int.fetchOne(db, sql: "PRAGMA wal_autocheckpoint")
        }
        // Old output: 0 — "automatic" silently meant manual-only.
        #expect(autocheckpoint == 1)
        try await handle.close()
    }

    // MARK: - BH-594: the guard is a property of writing

    @Test("BH-594: enforceSchemaGuard: false on a read-write open still refuses a foreign schema")
    func guardCannotBeDroppedOnAReadWriteOpen() async throws {
        let workspace = try await makeDeliveredPackage("Fix2GuardTied")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try HostileProjectPackage.apply(.extraTrigger, toPackageAt: workspace.packageURL)
        // Old output: a read-write handle, the migrator run, the trigger live.
        await #expect(throws: ZPDFPersistenceError.foreignSchemaObject(
            objectType: "trigger", name: HostileProjectPackage.attackerTriggerName
        )) {
            _ = try await ProjectDatabaseActor.open(
                at: workspace.packageURL.member(ProjectPackageLayout.database),
                readOnly: false, enforceSchemaGuard: false
            )
        }
    }

    // MARK: - BH-595 / BH-596: checkpoint reporting

    @Test("BH-595: a checkpoint on a closed handle is reported as a closed handle, not a failed checkpoint")
    func checkpointOnClosedHandleIsTyped() async throws {
        let root = try TestSupport.makeTemporaryDirectory("Fix2ClosedCheckpoint")
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try await ProjectDatabaseActor.open(at: root.appendingPathComponent("project.sqlite"))
        try await handle.close()
        // Old output: walCheckpointFailed("the database handle is closed") after three retries.
        await #expect(throws: ZPDFPersistenceError.databaseFailure(
            message: "the database handle is closed", resultCode: 0
        )) {
            try await handle.checkpoint(.truncate)
        }
    }

    @Test("BH-596: a passive checkpoint reports the frames it folded, and a truncate reports the frames it had")
    func checkpointCountsAreReal() async throws {
        let root = try TestSupport.makeTemporaryDirectory("Fix2CheckpointCounts")
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try await ProjectDatabaseActor.open(
            at: root.appendingPathComponent("project.sqlite"),
            tuning: DatabaseTuning(checkpointPolicy: .manualOnly)
        )
        try await handle.write { db in
            try db.execute(sql: "CREATE TABLE frames (x TEXT NOT NULL)")
            for index in 0..<500 {
                try db.execute(sql: "INSERT INTO frames (x) VALUES (?)", arguments: ["row-\(index)-padding"])
            }
        }
        let passive = try await handle.checkpoint(.passive)
        // Old output: checkpointedFrameCount 0 — derived from a -wal size that PASSIVE
        // never shrinks.
        #expect(passive.walFrameCount >= 2)
        #expect(passive.checkpointedFrameCount == passive.walFrameCount)

        try await handle.write { db in
            for index in 0..<200 {
                try db.execute(sql: "INSERT INTO frames (x) VALUES (?)", arguments: ["more-\(index)"])
            }
        }
        let truncate = try await handle.checkpoint(.truncate)
        #expect(truncate.walFrameCount >= 1)
        #expect(truncate.checkpointedFrameCount == truncate.walFrameCount)
        #expect(truncate.walByteCountAfter == 0)
        try await handle.close()
    }

    // MARK: - BH-597: containment is case-sensitive

    @Test("BH-597: 'Documents/plan.pdf' is outside documents/")
    func containmentIsCaseSensitive() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2CaseSensitive")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let issues = try await package.write { db in
            try db.execute(sql: "UPDATE document SET relative_path = 'Documents/original.pdf'")
            return try DomainValidation.validate(db)
        }
        // Old output: [] — SQLite's LIKE is ASCII-case-insensitive, so the row passed.
        #expect(issues.contains { $0.code == "relative-path-outside-package" })
        try await package.write { db in
            try db.execute(sql: "UPDATE document SET relative_path = 'documents/original.pdf'")
        }
        try await package.close()
    }

    // MARK: - BH-598 / BH-600: members that are not regular files

    @Test("BH-598: a manifest.json that is a symbolic link is refused before it is read")
    func symlinkedManifestIsRefused() async throws {
        let workspace = try await makeDeliveredPackage("Fix2ManifestLink")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let manifestURL = workspace.packageURL.member(ProjectPackageLayout.manifest)
        let elsewhere = workspace.root.appendingPathComponent("manifest-elsewhere.json")
        try FileManager.default.moveItem(at: manifestURL, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: elsewhere)

        // Old output: opened — the cap was measured on the link's own bytes and the read
        // followed it.
        await #expect(throws: ZPDFPersistenceError.packageMalformed(
            reason: "manifest.json is not a regular file"
        )) {
            _ = try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment())
        }
    }

    @Test("BH-600: a working.pdf linked to a device is refused instead of hashed forever", .timeLimit(.minutes(1)))
    func deviceLinkedMemberIsRefused() async throws {
        let workspace = try await makeDeliveredPackage("Fix2DeviceLink")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let workingURL = workspace.packageURL.member(ProjectPackageLayout.workingPDF)
        try FileManager.default.removeItem(at: workingURL)
        try FileManager.default.createSymbolicLink(
            at: workingURL, withDestinationURL: URL(fileURLWithPath: "/dev/zero")
        )
        // Old output: the open never returned — sha256 read /dev/zero until an end of
        // file that never comes.
        do {
            _ = try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment())
            Issue.record("a member that is not a regular file must be refused")
        } catch let error as ZPDFPersistenceError {
            guard case .projectDamaged = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    // MARK: - BH-590 / BH-591: the audit trail

    @Test("BH-591: an empty actions filter selects nothing")
    func emptyActionsFilterSelectsNothing() async throws {
        let workspace = try TestSupport.makeWorkspace("Fix2EmptyFilter")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        let projectId = try await TestSupport.projectIdentifier(of: package)
        try await package.write { db in
            _ = try MeasurementAuditStore.appendAudit(
                MeasurementAuditEntry(
                    id: "a1", projectId: projectId, markupId: nil,
                    occurredAt: TestSupport.seedTimestamp, action: .scaleChanged, actor: "tester"
                ),
                in: db
            )
        }
        let (all, none) = try await package.read { db in
            (
                try MeasurementAuditStore.auditTrail(project: projectId, in: db).count,
                try MeasurementAuditStore.auditTrail(
                    project: projectId,
                    filter: MeasurementAuditStore.AuditFilter(actions: []),
                    in: db
                ).count
            )
        }
        #expect(all == 1)
        // Old output: 1 — the empty set dropped the IN clause and meant "all actions".
        #expect(none == 0)
        try await package.close()
    }

    // MARK: - BH-607: the timestamp parser is strict about ranges

    @Test("BH-607: out-of-range timestamp fields are rejected rather than normalised")
    func timestampParserRejectsOverflow() {
        // Old output: a Date around 2027-02-15 — Calendar rolled the overflow forward.
        #expect(PersistenceTimestamp.date(from: "2026-13-45T25:61:61.999Z") == nil)
        #expect(PersistenceTimestamp.date(from: "2026-02-30T00:00:00.000Z") == nil)
        #expect(PersistenceTimestamp.date(from: "2026-00-10T00:00:00.000Z") == nil)
        let valid = "2026-08-23T10:00:00.000Z"
        let parsed = PersistenceTimestamp.date(from: valid)
        #expect(parsed.map(PersistenceTimestamp.string(from:)) == valid)
    }

    // MARK: - BH-608 / BH-609: DecimalString

    @Test("BH-608: a finite Decimal with a large exponent is representable")
    func largeExponentDecimalIsRepresentable() throws {
        let tiny = try #require(Decimal(string: "1e-100"))
        // Old output: nil — NSDecimalString spelled it as 102 plain digits, past the cap.
        let wrapped = try #require(DecimalString(tiny))
        #expect(wrapped.value == tiny)
        #expect(wrapped.canonicalText.utf8.count <= 96)
        // Round-trips through the strict text parser to the same value.
        #expect(DecimalString(text: wrapped.canonicalText)?.value == tiny)
        let huge = try #require(Decimal(string: "-7.5e120"))
        #expect(DecimalString(huge)?.value == huge)
        // Ordinary values keep their plain rendering.
        #expect(DecimalString(Decimal(string: "12.5")!)?.canonicalText == "12.5")
    }

    @Test("BH-609: adding() is nil when the exact sum needs more digits than Decimal holds, and exact otherwise")
    func additionIsExactOrNil() throws {
        let big = try #require(DecimalString(text: "12345678901234.5678"))
        let precise = try #require(DecimalString(text: "0.3333333333333333333333333333"))
        #expect(big.adding(precise) == nil, "42 significant digits cannot be an exact Decimal sum")
        #expect(big.adding(DecimalString(text: "0.0002")!)?.canonicalText == "12345678901234.568")
    }

    // MARK: - BH-610: reserved flags

    @Test("BH-610: a geometry blob with a reserved flag set is refused; version-1 blobs still decode")
    func reservedFlagsAreEnforced() throws {
        let blob = try TestSupport.sampleGeometry(pointCount: 4)
        #expect(try GeometryBlob.decode(blob).rings.first?.count == 4)
        var flagged = blob
        flagged[8] = 1
        // Old output: decoded, flag ignored.
        #expect(throws: GeometryBlobError.reservedFlagsSet(flags: 1)) {
            _ = try GeometryBlob.decode(flagged)
        }
    }

    // MARK: - BH-611: PackedRGBA storage class

    @Test("BH-611: a REAL in a colour column is rejected, an INTEGER is read")
    func packedColourRefusesReal() {
        // Old output: #FF0000FF — GRDB rounded 4278190335.7 toward zero.
        #expect(PackedRGBA.fromDatabaseValue(4278190335.7.databaseValue) == nil)
        #expect(PackedRGBA.fromDatabaseValue(Int64(0xFF00_00FF).databaseValue)?.packedValue == 0xFF00_00FF)
        #expect(PackedRGBA.fromDatabaseValue("4278190335".databaseValue) == nil)
    }

    // MARK: - BH-612: the harness refuses a valueless flag

    @Test("BH-612: the save harness refuses a trailing flag with no value")
    func harnessRefusesValuelessFlag() throws {
        let result = try TestSupport.runHarness(["save", "--package", "/nowhere", "--kill-at"])
        // Old output: exit 2 with "no package at /nowhere" — the flag was dropped and a
        // full save attempted; a real package would have been saved where a kill was expected.
        #expect(result.exitStatus == 2)
        #expect(result.standardError.contains("usage"), Comment(rawValue: result.standardError))
    }

    // MARK: - IM-007: engine errors read as sentences

    @Test("IM-007: a persistence error bridged to NSError keeps its sentence")
    func errorsAreLocalized() {
        let error = ZPDFPersistenceError.packageSchemaTooNew(found: 9, supported: 1)
        let bridged = error as NSError
        // Old output: "The operation couldn't be completed. (ZPDFPersistence.ZPDFPersistenceError error 6.)"
        #expect(bridged.localizedDescription.contains("newer version"))
        #expect(!bridged.localizedDescription.contains("couldn't be completed"))
        #expect(bridged.localizedRecoverySuggestion?.isEmpty == false)
    }
}
