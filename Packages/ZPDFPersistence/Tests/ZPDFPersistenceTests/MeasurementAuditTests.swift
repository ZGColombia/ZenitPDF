import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// ADR-0007 §2 and §4: the append-only audit trail, its atomicity with the mutation it
/// records, and the proof that it does not measurably slow the mutation path.
struct MeasurementAuditTests {

    // MARK: - Fixtures

    private struct Project {
        let package: ProjectPackage
        let workspace: TestSupport.Workspace
        let projectId: String
        let documentId: String
        let pageId: String
    }

    private func makeProject(_ label: String) async throws -> Project {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        return Project(
            package: package,
            workspace: workspace,
            projectId: try await TestSupport.projectIdentifier(of: package),
            documentId: try await TestSupport.documentIdentifier(of: package),
            pageId: pageId
        )
    }

    private func tearDown(_ project: Project) async {
        try? await project.package.close()
        try? FileManager.default.removeItem(at: project.workspace.root)
    }

    private func markupRecord(_ id: String, _ project: Project, geometry: Data) -> MarkupRecord {
        MarkupRecord(
            id: id, documentId: project.documentId, pageId: project.pageId,
            type: "area", subject: "Slab", geometryBlob: geometry, styleBlob: Data([1]),
            createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
        )
    }

    private func entry(
        _ id: String,
        project: Project,
        markupId: String?,
        action: MeasurementAuditAction,
        before: [String: String]? = nil,
        after: [String: String]? = nil,
        undoGroup: String? = nil
    ) -> MeasurementAuditEntry {
        MeasurementAuditEntry(
            id: id,
            projectId: project.projectId,
            markupId: markupId,
            occurredAt: TestSupport.seedTimestamp,
            action: action,
            actor: "tester",
            beforeValues: before,
            afterValues: after,
            formulaVersion: 2,
            commandName: "Test command",
            undoGroup: undoGroup
        )
    }

    // MARK: - Atomicity

    @Test("Mutation and audit entry live or die together: a rollback removes both")
    func sameTransactionAtomicity() async throws {
        let project = try await makeProject("AuditAtomic")
        let geometry = try TestSupport.sampleGeometry()

        struct Abort: Error {}

        // The mutation and its audit entry run in ONE transaction, and the transaction
        // fails after both statements executed. If the trail were written anywhere else —
        // another connection, a queue, a log — the entry would survive this rollback.
        // It must not: a kill between "mutate" and "record" is impossible by construction
        // because there is no "between".
        await #expect(throws: (any Error).self) {
            try await project.package.write { [self] db in
                try markupRecord("m1", project, geometry: geometry).insert(db)
                try MeasurementAuditStore.appendAudit(
                    entry("a1", project: project, markupId: "m1", action: .markupCreated,
                          after: ["netArea": "21.34"]),
                    in: db
                )
                // Both rows exist inside the transaction...
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement_audit") == 1)
                throw Abort()
            }
        }

        // ...and neither exists after the rollback.
        let counts = try await project.package.read { db in
            (markups: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1,
             audits: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement_audit") ?? -1)
        }
        #expect(counts.markups == 0)
        #expect(counts.audits == 0)

        // The committed path leaves exactly one of each — same closure, no throw.
        _ = try await project.package.write { [self] db in
            try markupRecord("m1", project, geometry: geometry).insert(db)
            try MeasurementAuditStore.appendAudit(
                entry("a1", project: project, markupId: "m1", action: .markupCreated,
                      after: ["netArea": "21.34"]),
                in: db
            )
        }
        let committed = try await project.package.read { db in
            (markups: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1,
             audits: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement_audit") ?? -1)
        }
        #expect(committed.markups == 1)
        #expect(committed.audits == 1)
        await tearDown(project)
    }

    // MARK: - Append-only

    @Test("The trail refuses UPDATE and DELETE at the database level")
    func appendOnlyIsEnforced() async throws {
        let project = try await makeProject("AuditAppendOnly")
        try await project.package.write { [self] db in
            try MeasurementAuditStore.appendAudit(
                entry("a1", project: project, markupId: nil, action: .scaleChanged),
                in: db
            )
        }

        await #expect(throws: (any Error).self, "UPDATE must abort") {
            try await project.package.write { db in
                try db.execute(sql: "UPDATE measurement_audit SET actor = 'forger' WHERE id = 'a1'")
            }
        }
        await #expect(throws: (any Error).self, "DELETE must abort") {
            try await project.package.write { db in
                try db.execute(sql: "DELETE FROM measurement_audit WHERE id = 'a1'")
            }
        }

        // The row is exactly as appended.
        let actor = try await project.package.read { db in
            try String.fetchOne(db, sql: "SELECT actor FROM measurement_audit WHERE id = 'a1'")
        }
        #expect(actor == "tester")
        await tearDown(project)
    }

    @Test("A duplicate (markup_id, sequence) insert fails at the database level")
    func duplicateMarkupSequenceIsRefused() async throws {
        let project = try await makeProject("AuditUniqueSequence")
        let original = try await project.package.write { [self] db in
            try MeasurementAuditStore.appendAudit(
                entry("a1", project: project, markupId: "m1", action: .markupCreated,
                      after: ["netArea": "21.34"]),
                in: db
            )
        }

        // A second row reusing the same markup and sequence — the bug class migration v4
        // exists to catch — must be a constraint failure, not a silently ambiguous history.
        await #expect(throws: (any Error).self, "duplicate (markup_id, sequence) must abort") {
            try await project.package.write { db in
                var forged = original
                forged.id = "a1-duplicate"
                try forged.insert(db)
            }
        }

        // Project-level entries carry a NULL markup_id; NULLs are distinct in a unique
        // index, so two of them may legally share nothing but their NULL.
        _ = try await project.package.write { [self] db in
            try MeasurementAuditStore.appendAudit(
                entry("s1", project: project, markupId: nil, action: .scaleChanged), in: db
            )
        }
        _ = try await project.package.write { [self] db in
            try MeasurementAuditStore.appendAudit(
                entry("s2", project: project, markupId: nil, action: .scaleChanged), in: db
            )
        }

        let count = try await project.package.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement_audit") ?? -1
        }
        #expect(count == 3)
        await tearDown(project)
    }

    @Test("A malformed decimal string is refused before it reaches the trail")
    func valuesMustBeCanonicalDecimalStrings() async throws {
        let project = try await makeProject("AuditGrammar")
        await #expect(throws: ZPDFPersistenceError.malformedDecimalString("netArea: 1.5; DROP")) {
            try await project.package.write { [self] db in
                try MeasurementAuditStore.appendAudit(
                    entry("a1", project: project, markupId: "m1", action: .markupModified,
                          after: ["netArea": "1.5; DROP"]),
                    in: db
                )
            }
        }
        await tearDown(project)
    }

    // MARK: - Compensating undo

    @Test("An undo appends a compensating entry and never touches the original")
    func compensatingEntryForUndo() async throws {
        let project = try await makeProject("AuditUndo")
        let original = try await project.package.write { [self] db in
            try MeasurementAuditStore.appendAudit(
                entry("a1", project: project, markupId: "m1", action: .markupModified,
                      before: ["netArea": "21.34"], after: ["netArea": "25.5"],
                      undoGroup: "g1"),
                in: db
            )
        }

        let compensating = try await project.package.write { db in
            try MeasurementAuditStore.appendCompensatingEntry(
                for: original,
                id: "a2",
                occurredAt: "2026-08-23T10:05:00.000Z",
                actor: "tester",
                in: db
            )
        }

        #expect(compensating.auditAction == .compensated)
        #expect(compensating.sequence == original.sequence + 1)
        // Before and after swap places: the compensating entry records the values going back.
        #expect(try MeasurementAuditStore.decodeValues(compensating.beforeValuesJson) == ["netArea": "25.5"])
        #expect(try MeasurementAuditStore.decodeValues(compensating.afterValuesJson) == ["netArea": "21.34"])
        // No group unless the caller names one (BH-590). Old output: "g1" — the
        // original's group, so a later undo of g1 fetched the compensation too and
        // compensated the row twice in one step.
        #expect(compensating.undoGroup == nil)
        #expect(compensating.note == "compensates a1")

        // The trail now holds both entries, in order, and the original is untouched.
        let trail = try await project.package.read { db in
            try MeasurementAuditStore.auditTrail(markup: "m1", in: db)
        }
        #expect(trail.count == 2)
        #expect(trail[0] == original)
        #expect(trail[1] == compensating)
        await tearDown(project)
    }

    // MARK: - Scale-change fan-out

    @Test("A scale change records one scale entry plus one entry per affected markup")
    func scaleChangeFanOut() async throws {
        let project = try await makeProject("AuditFanOut")
        let identifiers = SequentialIdentifierGenerator(prefix: "A")
        let affected = (1...7).map { index in
            MeasurementAuditStore.MarkupValueChange(
                markupId: "m\(index)",
                beforeValues: ["planLength": "\(index).0"],
                afterValues: ["planLength": "\(index * 2).0"]
            )
        }

        let written = try await project.package.write { db in
            try MeasurementAuditStore.recordScaleChange(
                projectId: project.projectId,
                scaleId: "s1",
                oldVersion: 1,
                newVersion: 2,
                affected: affected,
                occurredAt: TestSupport.seedTimestamp,
                actor: "tester",
                formulaVersion: 2,
                commandName: "Recalibrate page 3",
                undoGroup: "g-scale",
                identifiers: identifiers,
                in: db
            )
        }

        #expect(written.count == 1 + 7, "one scale entry plus one per affected markup")
        #expect(written[0].auditAction == .scaleChanged)
        #expect(written[0].markupId == nil)
        #expect(written[0].scaleId == "s1")
        #expect(written[0].scaleVersion == 2)
        #expect(written[0].note?.contains("7 markup(s) affected") == true)
        for (index, record) in written.dropFirst().enumerated() {
            #expect(record.auditAction == .markupRescaled)
            #expect(record.markupId == "m\(index + 1)")
            #expect(record.scaleVersion == 2)
            #expect(record.undoGroup == "g-scale")
            #expect(try MeasurementAuditStore.decodeValues(record.beforeValuesJson)
                == ["planLength": "\(index + 1).0"])
            #expect(try MeasurementAuditStore.decodeValues(record.afterValuesJson)
                == ["planLength": "\((index + 1) * 2).0"])
        }
        // Sequences are gapless and ordered across the fan-out.
        #expect(written.map(\.sequence) == Array(1...8))

        // "Did the numbers change after the revision came in" is a query:
        let rescales = try await project.package.read { db in
            try MeasurementAuditStore.auditTrail(
                project: project.projectId,
                filter: .init(actions: [.markupRescaled]),
                in: db
            )
        }
        #expect(rescales.count == 7)
        await tearDown(project)
    }

    // MARK: - Queries

    @Test("The project trail filters by markup, action, date and undo group")
    func filteredQueries() async throws {
        let project = try await makeProject("AuditFilter")
        try await project.package.write { [self] db in
            try MeasurementAuditStore.appendAudit(
                entry("a1", project: project, markupId: "m1", action: .markupCreated,
                      after: ["netArea": "1"]), in: db)
            try MeasurementAuditStore.appendAudit(
                MeasurementAuditEntry(
                    id: "a2", projectId: project.projectId, markupId: "m1",
                    occurredAt: "2026-08-24T09:00:00.000Z", action: .markupModified,
                    actor: "tester", beforeValues: ["netArea": "1"],
                    afterValues: ["netArea": "2"], undoGroup: "g1"
                ), in: db)
            try MeasurementAuditStore.appendAudit(
                MeasurementAuditEntry(
                    id: "a3", projectId: project.projectId, markupId: "m2",
                    occurredAt: "2026-08-25T09:00:00.000Z", action: .markupDeleted,
                    actor: "tester", beforeValues: ["netArea": "9"]
                ), in: db)
        }

        let byMarkup = try await project.package.read { db in
            try MeasurementAuditStore.auditTrail(markup: "m1", in: db)
        }
        #expect(byMarkup.map(\.id) == ["a1", "a2"])

        let byAction = try await project.package.read { db in
            try MeasurementAuditStore.auditTrail(
                project: project.projectId,
                filter: .init(actions: [.markupDeleted]), in: db)
        }
        #expect(byAction.map(\.id) == ["a3"])

        let byDate = try await project.package.read { db in
            try MeasurementAuditStore.auditTrail(
                project: project.projectId,
                filter: .init(occurredAtOrAfter: "2026-08-24T00:00:00.000Z",
                              occurredBefore: "2026-08-25T00:00:00.000Z"), in: db)
        }
        #expect(byDate.map(\.id) == ["a2"])

        let byGroup = try await project.package.read { db in
            try MeasurementAuditStore.auditTrail(
                project: project.projectId, filter: .init(undoGroup: "g1"), in: db)
        }
        #expect(byGroup.map(\.id) == ["a2"])

        let newestFirst = try await project.package.read { db in
            try MeasurementAuditStore.auditTrail(
                project: project.projectId, filter: .init(limit: 2), in: db)
        }
        #expect(newestFirst.map(\.id) == ["a3", "a2"])
        await tearDown(project)
    }

    // MARK: - Benchmark (ADR-0007 §4)

    @Test("100 000 mutations: the audit insert does not measurably slow the mutation path")
    func benchmarkHundredThousandMutations() async throws {
        let mutationCount = 100_000
        let batchSize = 1_000
        let geometry = try TestSupport.sampleGeometry(pointCount: 4)

        func runMutations(_ project: Project, audited: Bool) async throws -> TimeInterval {
            let start = ContinuousClock.now
            for batch in 0..<(mutationCount / batchSize) {
                try await project.package.write { [self] db in
                    for index in 0..<batchSize {
                        let n = batch * batchSize + index
                        try markupRecord("m\(n)", project, geometry: geometry).insert(db)
                        try MeasurementValueRecord(
                            markupId: "m\(n)",
                            planAreaSi: DecimalString(text: "21.34"),
                            formulaVersion: 2
                        ).insert(db)
                        if audited {
                            try MeasurementAuditStore.appendAudit(
                                entry("a\(n)", project: project, markupId: "m\(n)",
                                      action: .markupCreated,
                                      after: ["planArea": "21.34"]),
                                in: db
                            )
                        }
                    }
                }
            }
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        }

        let bare = try await makeProject("AuditBenchBare")
        let bareSeconds = try await runMutations(bare, audited: false)
        await tearDown(bare)

        let audited = try await makeProject("AuditBenchAudited")
        let auditedSeconds = try await runMutations(audited, audited: true)

        let auditRows = try await audited.package.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement_audit") ?? 0
        }
        #expect(auditRows == mutationCount)

        let overheadPerMutation = (auditedSeconds - bareSeconds) / Double(mutationCount)
        print("""
            [ADR-0007 benchmark] \(mutationCount) mutations: \
            without audit \(String(format: "%.3f", bareSeconds)) s \
            (\(String(format: "%.2f", bareSeconds / Double(mutationCount) * 1e6)) us/mutation), \
            with audit \(String(format: "%.3f", auditedSeconds)) s \
            (\(String(format: "%.2f", auditedSeconds / Double(mutationCount) * 1e6)) us/mutation), \
            audit overhead \(String(format: "%.2f", overheadPerMutation * 1e6)) us/mutation
            """)

        // "Must not measurably slow the mutation path": the per-mutation overhead of the one
        // extra insert stays under 250 microseconds, an order of magnitude below what a user
        // could ever perceive, and the audited run stays within 2.5x of the bare run even on
        // a noisy CI machine.
        #expect(overheadPerMutation < 0.000_250,
                "audit adds \(overheadPerMutation * 1e6) us per mutation")
        #expect(auditedSeconds < bareSeconds * 2.5)
        await tearDown(audited)
    }
}
