import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Regression tests for the code-review findings in this package that had a fix but no test:
/// CR-76, CR-81, CR-82, CR-86, CR-87, CR-94 and CR-95. Each test states what the old code
/// produced and fails on it.
struct CodeReviewRegressionTests {

    // MARK: - Seeding

    private struct Seeded {
        let workspace: TestSupport.Workspace
        let package: ProjectPackage
        let pageId: String
        let documentId: String
        let geometry: Data
    }

    private func seed(_ label: String) async throws -> Seeded {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        return Seeded(
            workspace: workspace, package: package, pageId: pageId, documentId: documentId,
            geometry: try TestSupport.sampleGeometry()
        )
    }

    private func insertMarkups(_ ids: [String], into seeded: Seeded) async throws {
        let documentId = seeded.documentId
        let pageId = seeded.pageId
        let geometry = seeded.geometry
        try await seeded.package.write { db in
            for id in ids {
                try MarkupRecord(
                    id: id, documentId: documentId, pageId: pageId,
                    type: "count", subject: "Markup \(id)",
                    geometryBlob: geometry, styleBlob: Data([1]),
                    createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
                ).insert(db)
            }
        }
    }

    private func markupCount(in package: ProjectPackage) async throws -> Int {
        try await package.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1
        }
    }

    // MARK: - CR-76: an unencodable geometry must not become an empty blob

    @Test("A geometry that cannot be encoded binds NULL, never an empty blob (CR-76)")
    func unencodableGeometryBindsNull() {
        let broken = GeometryBlob(kind: .polyline, points: [
            GeometryPoint(x: 0, y: 0), GeometryPoint(x: .nan, y: 1), GeometryPoint(x: 2, y: 2)
        ])
        #expect(throws: GeometryBlobError.self) { _ = try broken.encode() }
        // Old output: `.blob(Data())` — a zero-byte blob that satisfied NOT NULL, so the row
        // committed and could never be decoded again.
        #expect(broken.databaseValue == .null)
        #expect(broken.databaseValue != Data().databaseValue)
    }

    @Test("A write whose geometry cannot be encoded aborts and keeps the old row (CR-76)")
    func unencodableGeometryAbortsTheWrite() async throws {
        let seeded = try await seed("CR76")
        defer { try? FileManager.default.removeItem(at: seeded.workspace.root) }
        try await insertMarkups(["m1"], into: seeded)

        // Old output: the UPDATE succeeded with a zero-byte blob, and `geometry()` on the
        // reread row failed with `tooShort(byteCount: 0)` — a permanently unreadable markup.
        await #expect(throws: (any Error).self) {
            try await seeded.package.write { db in
                let broken = GeometryBlob(kind: .polyline, points: [
                    GeometryPoint(x: .nan, y: 0), GeometryPoint(x: 1, y: 1)
                ])
                try db.execute(
                    sql: "UPDATE markup SET geometry_blob = ? WHERE id = ?",
                    arguments: [broken, "m1"]
                )
            }
        }
        let record = try #require(try await seeded.package.read { db in
            try MarkupRecord.fetchOne(db, key: "m1")
        })
        #expect(record.geometryBlob == seeded.geometry)
        #expect(try record.geometry().rings.first?.count == 24)
        try await seeded.package.close()
    }

    // MARK: - CR-81: the health probe must not checkpoint the live database

    @Test("The recovery health probe leaves a database and its WAL byte-for-byte alone (CR-81)")
    func healthProbeDoesNotCheckpointTheLiveDatabase() async throws {
        let seeded = try await seed("CR81")
        defer { try? FileManager.default.removeItem(at: seeded.workspace.root) }
        try await insertMarkups((0..<8).map { "wal-\($0)" }, into: seeded)

        // A crash image: the package copied while the session is still open, so the copy
        // carries an armed crash marker and a WAL with committed, uncheckpointed frames —
        // what a killed process leaves behind. No process is killed; the live package closes
        // cleanly afterwards and only the copy is probed.
        let crashed = seeded.workspace.root.appendingPathComponent("Crashed.zpdfproj", isDirectory: true)
        try FileManager.default.copyItem(at: seeded.workspace.packageURL, to: crashed)
        try await seeded.package.close()

        let database = crashed.member(ProjectPackageLayout.database)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
        let walBytesBefore = try Data(contentsOf: wal)
        #expect(walBytesBefore.count > 32, "precondition: the crash image carries WAL frames")
        let databaseBytesBefore = try Data(contentsOf: database)

        #expect(ProjectPackage.databaseIsHealthyForTesting(at: database))
        let assessment = try await ProjectPackage.assessRecovery(at: crashed)
        #expect(assessment.crashMarkerPresent)

        // Old output: the probe opened `project.sqlite` itself read-write and closing that
        // connection checkpointed it — `-wal` was deleted and the main file grew by the folded
        // pages — before the user had chosen Recover, Discard or Open Read-Only.
        #expect(FileManager.default.fileExists(atPath: wal.path), "the probe deleted the WAL")
        #expect(try Data(contentsOf: wal) == walBytesBefore, "the probe rewrote the WAL")
        #expect(try Data(contentsOf: database) == databaseBytesBefore,
                "the probe checkpointed the database it was only meant to look at")
    }

    // MARK: - CR-82: version rotation must never destroy the backup it is replacing

    /// Makes the version rotation's clone fail after the save has committed: at
    /// `.didAtomicReplace` a dangling symlink is planted in the package — `clonefile(2)` follows
    /// symlinks and fails with ENOENT on it, which `cloneItem` does not fall back from — and at
    /// `.didPreserveVersion` it is removed again, so nothing after the rotation sees it.
    private func rotationFault(in packageURL: URL) -> SaveHooks {
        let link = packageURL.appendingPathComponent("zz-dangling", isDirectory: false)
        let target = packageURL.appendingPathComponent("zz-nowhere", isDirectory: false)
        return SaveHooks { checkpoint in
            switch checkpoint {
            case .didAtomicReplace:
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            case .didPreserveVersion:
                try FileManager.default.removeItem(at: link)
            default:
                break
            }
        }
    }

    @Test("A failed rotation leaves the existing latest version untouched (CR-82)")
    func failedRotationKeepsTheExistingLatestVersion() async throws {
        let seeded = try await seed("CR82Keep")
        defer { try? FileManager.default.removeItem(at: seeded.workspace.root) }

        try await insertMarkups(["first"], into: seeded)
        let first = try await seeded.package.save()
        let latest = try #require(first.latestVersionURL)
        #expect(try TestSupport.markupCount(inPackageAt: latest) == 1)

        try await insertMarkups(["second"], into: seeded)
        let second = try await seeded.package.save(hooks: rotationFault(in: seeded.workspace.packageURL))

        // The save itself committed; only the backup could not be made.
        #expect(try TestSupport.markupCount(inPackageAt: seeded.workspace.packageURL) == 2)
        #expect(try ProjectPackage.verifyIntegrity(at: seeded.workspace.packageURL).isFullyConsistent)

        // Old output: the rotation moved `latest` to `previous` and built the new latest in
        // place; when the clone failed it removed `versions/latest` outright — the slot the
        // receipt still named — so `verifyIntegrity(at: latest)` threw for a missing manifest
        // while `previous` held the first save. A backup destroyed by failing to make one.
        #expect(second.latestVersionURL?.path == latest.path,
                "receipt named \(String(describing: second.latestVersionURL))")
        #expect(second.previousVersionURL == nil)
        #expect(try ProjectPackage.verifyIntegrity(at: latest).isFullyConsistent)
        #expect(try TestSupport.markupCount(inPackageAt: latest) == 1,
                "the surviving backup is the first save, untouched")
        let slots = try FileManager.default
            .contentsOfDirectory(atPath: seeded.package.versionsRootURL.path).sorted()
        #expect(slots == ["latest"], "no staging or discard leftovers: \(slots)")
        try await seeded.package.close()
    }

    @Test("A receipt names a latest version only when one exists (CR-82)")
    func receiptDoesNotNameAMissingVersionSlot() async throws {
        let seeded = try await seed("CR82Receipt")
        defer { try? FileManager.default.removeItem(at: seeded.workspace.root) }

        let receipt = try await seeded.package.save(hooks: rotationFault(in: seeded.workspace.packageURL))
        // Old output: `<package>/versions/latest`, unconditionally, with no such directory.
        #expect(receipt.latestVersionURL == nil)
        #expect(receipt.previousVersionURL == nil)
        let latest = seeded.package.versionsRootURL
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: latest.path))
        #expect(try ProjectPackage.verifyIntegrity(at: seeded.workspace.packageURL).isFullyConsistent)

        // With nothing in the way, the next save produces the backup and says so.
        let next = try await seeded.package.save()
        #expect(next.latestVersionURL?.path == latest.path)
        #expect(FileManager.default.fileExists(atPath: latest.path))
        try await seeded.package.close()
    }

    // MARK: - CR-86: Discard must not pretend when there is nothing to discard back to

    @Test("Discard refuses honestly when the project has never been saved (CR-86)")
    func discardWithoutASavedVersionRefuses() async throws {
        let seeded = try await seed("CR86")
        defer { try? FileManager.default.removeItem(at: seeded.workspace.root) }
        try await insertMarkups(["unsaved-0", "unsaved-1", "unsaved-2"], into: seeded)
        // Never saved; the session dies with its crash marker armed.
        let handle = await seeded.package.database
        try await handle.close()

        let packageURL = seeded.workspace.packageURL
        let latest = ProjectPackage.versionsRootURL(forPackageAt: packageURL)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: latest.path), "precondition: no saved version")
        let before = try await ProjectPackage.assessRecovery(at: packageURL)
        #expect(before.crashMarkerPresent)

        // Old output: the open succeeded, the three WAL-committed markups were still in the
        // live database, and the caller was told the unsaved changes had been discarded.
        await #expect(performing: {
            _ = try await ProjectPackage.open(
                at: packageURL, environment: TestSupport.environment(), resolving: .discard
            )
        }, throws: { error in
            guard case .recoveryFailed = error as? ZPDFPersistenceError else { return false }
            return true
        })

        // Nothing was thrown away and nothing was pretended: the edits and the evidence remain,
        // so the user can still choose Recover and keep the work.
        #expect(try TestSupport.markupCount(inPackageAt: packageURL) == 3)
        let after = try await ProjectPackage.assessRecovery(at: packageURL)
        #expect(after.crashMarkerPresent)
        let recovered = try await ProjectPackage.open(
            at: packageURL, environment: TestSupport.environment(), resolving: .recover
        )
        #expect(try await markupCount(in: recovered) == 3)
        try await recovered.close()
    }

    // MARK: - CR-87: shape checks must constrain the whole string

    private func validationIssueCodes(of error: any Error) -> [String] {
        guard case let .saveValidationFailed(issues) = error as? ZPDFPersistenceError else { return [] }
        return issues.map(\.code)
    }

    @Test("A SHA-256 that starts with a hex digit and continues with junk fails validation (CR-87)")
    func shapeCheckConstrainsTheWholeHash() async throws {
        let seeded = try await seed("CR87Hash")
        defer { try? FileManager.default.removeItem(at: seeded.workspace.root) }
        let original = try #require(try await seeded.package.read { db in
            try String.fetchOne(db, sql: "SELECT sha256 FROM document LIMIT 1")
        })

        let junk = "a" + String(repeating: "Z", count: 63)
        try await seeded.package.write { db in
            try db.execute(sql: "UPDATE document SET sha256 = ?", arguments: [junk])
        }
        // Old output: `NOT GLOB '[0-9a-f]*'` tested the first character only; 'a' passed, the
        // save validated cleanly and committed 63 bytes of junk as a document hash.
        await #expect(performing: {
            _ = try await seeded.package.save()
        }, throws: { error in
            self.validationIssueCodes(of: error).contains("malformed-sha256")
        })

        // The real hash still passes: the check is whole-string, not over-broad.
        try await seeded.package.write { db in
            try db.execute(sql: "UPDATE document SET sha256 = ?", arguments: [original])
        }
        _ = try await seeded.package.save()
        try await seeded.package.close()
    }

    @Test("A measurement text that merely starts like a number fails validation (CR-87)")
    func shapeCheckConstrainsTheWholeDecimal() async throws {
        let seeded = try await seed("CR87Decimal")
        defer { try? FileManager.default.removeItem(at: seeded.workspace.root) }
        try await insertMarkups(["m1"], into: seeded)

        try await seeded.package.write { db in
            try db.execute(
                sql: "INSERT INTO measurement_value (markup_id, count_value, formula_version) VALUES (?, ?, 1)",
                arguments: ["m1", "1; DROP"]
            )
        }
        // Old output: `NOT GLOB '[-+.0-9]*'` tested the first character only; '1' passed and
        // "1; DROP" was committed as a count.
        await #expect(performing: {
            _ = try await seeded.package.save()
        }, throws: { error in
            self.validationIssueCodes(of: error).contains("non-decimal-text")
        })

        // A real decimal, sign and exponent included, still passes.
        try await seeded.package.write { db in
            try db.execute(
                sql: "UPDATE measurement_value SET count_value = ? WHERE markup_id = ?",
                arguments: ["-12.5e1", "m1"]
            )
        }
        _ = try await seeded.package.save()
        try await seeded.package.close()
    }

    // MARK: - CR-94: checkpoint frame counts must use the database's real page size

    @Test("Checkpoint frame counts are derived from the database's own page size (CR-94)")
    func checkpointReportReadsThePageSize() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("CR94")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("project.sqlite", isDirectory: false)

        // A database created with 8 KiB pages. The page size is fixed by the first write and
        // survives the switch to WAL the actor performs on open.
        do {
            let queue = try DatabaseQueue(path: url.path)
            try queue.inDatabase { db in
                try db.execute(sql: "PRAGMA page_size = 8192")
                try db.execute(sql: "CREATE TABLE seed (x)")
                try db.execute(sql: "DROP TABLE seed")
            }
            try queue.close()
        }

        let handle = try await ProjectDatabaseActor.open(at: url)
        let pageSize = try await handle.read { db in try Int.fetchOne(db, sql: "PRAGMA page_size") }
        #expect(pageSize == 8192, "precondition: page size \(String(describing: pageSize))")
        // Leave a good number of frames in the WAL on top of the migration's own.
        try await handle.write { db in
            try db.execute(sql: "CREATE TABLE cr94_frames (x TEXT NOT NULL)")
            for index in 0..<3000 {
                try db.execute(sql: "INSERT INTO cr94_frames (x) VALUES (?)", arguments: ["row-\(index)-padding"])
            }
        }
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let walBytesBefore = try #require(
            FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int
        )
        #expect(walBytesBefore > 32)

        let report = try await handle.checkpoint(.truncate)
        try await handle.close()

        // A WAL is a 32-byte header followed by whole frames of (page size + 24) bytes, so the
        // frame count and the byte count determine each other exactly. Old output: the count
        // was derived with a hard-coded 4096 — (bytes − 32) / 4120, 1.99× the real number of
        // frames for this database, and wrong for every page size but one.
        #expect(report.walFrameCount >= 2)
        #expect(report.walFrameCount * (8192 + 24) + 32 == walBytesBefore,
                "\(report.walFrameCount) frames reported for \(walBytesBefore) WAL bytes")
        #expect(report.checkpointedFrameCount == report.walFrameCount)
        #expect(report.walByteCountAfter == 0)
    }

    // MARK: - CR-95: a missing working PDF is damage, not consistency

    @Test("A missing working PDF is reported as a hash mismatch, not as consistent (CR-95)")
    func missingWorkingPDFIsNotConsistent() async throws {
        let seeded = try await seed("CR95")
        defer { try? FileManager.default.removeItem(at: seeded.workspace.root) }
        _ = try await seeded.package.save()
        try await seeded.package.close()

        let intact = try ProjectPackage.verifyIntegrity(at: seeded.workspace.packageURL)
        #expect(intact.workingPDFHashMatches)
        #expect(intact.isFullyConsistent)

        try FileManager.default.removeItem(
            at: seeded.workspace.packageURL.member(ProjectPackageLayout.workingPDF)
        )
        // Old output: workingPDFHashMatches == true and isFullyConsistent == true — the
        // recorded hash was substituted for the absent file and compared with itself.
        let damaged = try ProjectPackage.verifyIntegrity(at: seeded.workspace.packageURL)
        #expect(!damaged.workingPDFHashMatches)
        #expect(!damaged.isFullyConsistent)
    }
}
