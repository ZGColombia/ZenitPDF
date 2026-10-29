import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v12 (ADR-0021 (collaboration), NL-COLLAB-01): the `review_entry` table.
@Suite("Review entries, v12")
struct ReviewEntryMigrationTests {

    private let seedSQL = [
        """
        INSERT INTO project (id, name, created_at, modified_at, schema_version)
        VALUES ('p', 'P', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 11)
        """
    ]

    /// A project database exactly as a v11 build left it.
    private func makeV11Database(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("project.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v11-custom-column-definition")
        try queue.write { db in
            for statement in seedSQL { try db.execute(sql: statement) }
            #expect(try !db.tableExists("review_entry"), "precondition: a genuine v11 database")
        }
        try queue.close()
        return url
    }

    @Test("A v11 project opens read-only unmigrated, and migrates to an empty review_entry table")
    func oldProjectMigrates() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("V12OldSchema")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeV11Database(in: directory)

        let readOnly = try await ProjectDatabaseActor.open(at: url, readOnly: true, migrate: false)
        #expect(readOnly.schemaDeviations.isEmpty)
        try await readOnly.close()

        let migrated = try await ProjectDatabaseActor.open(at: url)
        let (userVersion, exists, count) = try await migrated.read { db in
            (
                try Int.fetchOne(db, sql: "PRAGMA user_version"),
                try db.tableExists("review_entry"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_entry")
            )
        }
        #expect(userVersion == ProjectSchema.currentVersion) // 12 when written; v13 (documents) follows
        #expect(exists)
        #expect(count == 0, "nothing is backfilled")
        #expect(migrated.schemaDeviations.isEmpty)
        try await migrated.close()
    }

    @Test("Entries round-trip, a redo upsert restores a removed reply, and a retraction is a tombstone")
    func entriesRoundTrip() async throws {
        let workspace = try TestSupport.makeWorkspace("V12RoundTrip")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let projectId = try await TestSupport.projectIdentifier(of: package)
        let first = ReviewEntryRecord(
            id: "r1", projectId: projectId, markupId: "m1",
            authorName: "Ada", body: "Is this the slab edge?", createdAt: "2026-09-23T10:00:00.000Z"
        )
        let second = ReviewEntryRecord(
            id: "r2", projectId: projectId, markupId: "m1", parentEntryId: "r1",
            authorName: "Bo", body: "Yes, per A-201.", createdAt: "2026-09-23T10:05:00.000Z"
        )
        try await package.write { db in
            try ReviewEntryStore.upsert(second, in: db)
            try ReviewEntryStore.upsert(first, in: db)
        }
        var read = try await package.read { db in try ReviewEntryStore.entries(project: projectId, markup: "m1", in: db) }
        #expect(read.map(\.id) == ["r1", "r2"], "oldest first, whatever the insert order")

        try await package.write { db in try ReviewEntryStore.remove(id: "r2", in: db) }
        try await package.write { db in try ReviewEntryStore.upsert(second, in: db) }
        try await package.write { db in
            try ReviewEntryStore.setRetracted(id: "r1", retracted: true, editedAt: "2026-09-23T11:00:00.000Z", in: db)
        }
        try await package.save()
        try await package.close()

        guard case let .opened(reopened) = try await ProjectPackage.open(at: workspace.packageURL) else {
            Issue.record("a cleanly closed package must open without a decision")
            return
        }
        read = try await reopened.read { db in try ReviewEntryStore.entries(project: projectId, in: db) }
        #expect(read.count == 2)
        #expect(read.first?.retracted == true, "withdrawn, not deleted")
        #expect(read.first?.body == "Is this the slab edge?")
        #expect(read.last == second)
        try await reopened.close()
    }

    @Test("A body over the cap is refused")
    func oversizedBodyIsRefused() async throws {
        let workspace = try TestSupport.makeWorkspace("V12Cap")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let projectId = try await TestSupport.projectIdentifier(of: package)
        let huge = ReviewEntryRecord(
            id: "big", projectId: projectId, markupId: "m", authorName: "X",
            body: String(repeating: "a", count: ReviewEntryStore.maximumBodyBytes + 1),
            createdAt: "2026-09-23T10:00:00.000Z"
        )
        await #expect(throws: ZPDFPersistenceError.self) {
            try await package.write { db in try ReviewEntryStore.upsert(huge, in: db) }
        }
        try await package.close()
    }

    @Test("Review values are accepted as text under the review. prefix; other keys stay decimals")
    func auditAcceptsReviewText() async throws {
        let workspace = try TestSupport.makeWorkspace("V12AuditReview")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let projectId = try await TestSupport.projectIdentifier(of: package)
        let entry = MeasurementAuditEntry(
            id: "a1", projectId: projectId, markupId: "m1",
            occurredAt: "2026-09-23T10:00:00.000Z", action: .markupModified, actor: "Ada",
            beforeValues: ["review.status": "open"], afterValues: ["review.status": "accepted"]
        )
        try await package.write { db in try MeasurementAuditStore.appendAudit(entry, in: db) }
        let row = try await package.read { db in
            try MeasurementAuditStore.auditTrail(project: projectId, in: db).first
        }
        #expect(row?.beforeValuesJson == #"{"review.status":"open"}"#)
        #expect(row?.afterValuesJson == #"{"review.status":"accepted"}"#)
        #expect(MeasurementAuditStore.measuredValues(["review.status": "open", "planArea": "1"]) == ["planArea": "1"])

        let bad = MeasurementAuditEntry(
            id: "a2", projectId: projectId, markupId: "m1",
            occurredAt: "2026-09-23T10:00:00.000Z", action: .markupModified, actor: "Ada",
            beforeValues: ["status": "open"], afterValues: nil
        )
        await #expect(throws: ZPDFPersistenceError.self) {
            try await package.write { db in try MeasurementAuditStore.appendAudit(bad, in: db) }
        }
        try await package.close()
    }
}

/// Every timestamp this package writes parses back.
@Suite("Timestamp round trip")
struct TimestampRoundTripTests {
    /// Old output: `PersistenceTimestamp.date(from: "…T…:51.746Z")` was `nil` for roughly one
    /// millisecond value in three, because the re-format truncated `.745999…` to `.745`. The
    /// History dated those rows `distantPast`.
    @Test("Every millisecond of a second round-trips through string and back")
    func everyMillisecondRoundTrips() throws {
        let base = 1_790_191_671.0
        var failures: [String] = []
        for millisecond in 0..<1_000 {
            let date = Date(timeIntervalSince1970: base + Double(millisecond) / 1_000)
            let text = PersistenceTimestamp.string(from: date)
            guard let parsed = PersistenceTimestamp.date(from: text) else { failures.append(text); continue }
            #expect(PersistenceTimestamp.string(from: parsed.addingTimeInterval(0.000_5)) == text)
        }
        #expect(failures.isEmpty, "\(failures.count) timestamps did not parse, first \(failures.first ?? "")")
        #expect(PersistenceTimestamp.date(from: "2026-13-45T25:61:61.999Z") == nil, "BH-607 still refuses overflow")
    }
}
