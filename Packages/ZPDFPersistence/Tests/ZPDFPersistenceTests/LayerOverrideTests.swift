import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// The `layer_override` table (schema v3): round trips, the no-op-row guard, the
/// dictionary shapes the bridge's effective-visibility rule consumes, cascade on
/// document deletion, and survival across a full save/reopen cycle.
struct LayerOverrideTests {

    private func identifiers(of package: ProjectPackage) async throws -> (project: String, document: String) {
        let ids = try await package.read { db -> [String] in
            let project = try String.fetchOne(db, sql: "SELECT id FROM project LIMIT 1") ?? ""
            let document = try String.fetchOne(db, sql: "SELECT id FROM document LIMIT 1") ?? ""
            return [project, document]
        }
        #expect(ids.count == 2 && !ids[0].isEmpty && !ids[1].isEmpty)
        return (ids[0], ids[1])
    }

    @Test("Overrides round-trip, upsert replaces, and removal restores the default")
    func roundTrip() async throws {
        let workspace = try TestSupport.makeWorkspace("LayerOverride")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let (projectId, documentId) = try await identifiers(of: package)

        let hideWalls = LayerOverrideRecord(
            projectId: projectId, documentId: documentId, layerId: "ocg:0",
            visible: false, locked: nil
        )
        let showGrid = LayerOverrideRecord(
            projectId: projectId, documentId: documentId, layerId: "ocg:2",
            visible: true, locked: false
        )
        try await package.write { db in
            try LayerOverrideStore.upsert(db, hideWalls)
            try LayerOverrideStore.upsert(db, showGrid)
        }

        let fetched = try await package.read { db in
            try LayerOverrideStore.overrides(db, projectId: projectId, documentId: documentId)
        }
        #expect(fetched == [hideWalls, showGrid], "ordered by layer_id, values intact")

        // Upsert replaces in place: same key, new values, still one row.
        var flippedDraft = hideWalls
        flippedDraft.visible = true
        flippedDraft.locked = true
        let flipped = flippedDraft
        try await package.write { db in try LayerOverrideStore.upsert(db, flipped) }
        let afterFlip = try await package.read { db in
            try LayerOverrideStore.overrides(db, projectId: projectId, documentId: documentId)
        }
        #expect(afterFlip == [flipped, showGrid])

        // Removing an override returns that layer to the document default.
        try await package.write { db in
            try LayerOverrideStore.remove(
                db, projectId: projectId, documentId: documentId, layerId: "ocg:0"
            )
        }
        let afterRemove = try await package.read { db in
            try LayerOverrideStore.overrides(db, projectId: projectId, documentId: documentId)
        }
        #expect(afterRemove == [showGrid])
        try await package.close()
    }

    @Test("A row that overrides nothing is never stored, by store rule and by CHECK")
    func noOpRowsAreRefused() async throws {
        let workspace = try TestSupport.makeWorkspace("LayerOverrideNoOp")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let (projectId, documentId) = try await identifiers(of: package)

        // The store writes a both-nil upsert as a removal.
        try await package.write { db in
            try LayerOverrideStore.upsert(db, LayerOverrideRecord(
                projectId: projectId, documentId: documentId, layerId: "ocg:1",
                visible: true, locked: nil
            ))
            try LayerOverrideStore.upsert(db, LayerOverrideRecord(
                projectId: projectId, documentId: documentId, layerId: "ocg:1",
                visible: nil, locked: nil
            ))
        }
        let rows = try await package.read { db in
            try LayerOverrideStore.overrides(db, projectId: projectId, documentId: documentId)
        }
        #expect(rows.isEmpty, "a no-op override is indistinguishable from absence and must not persist")

        // The database itself refuses a raw both-NULL insert.
        await #expect(throws: (any Error).self) {
            try await package.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO layer_override (project_id, document_id, layer_id, visible, locked)
                        VALUES (?, ?, 'ocg:9', NULL, NULL)
                        """,
                    arguments: [projectId, documentId]
                )
            }
        }
        try await package.close()
    }

    @Test("Visibility overrides come out in the shape the bridge consumes; lock overrides are stored beside them")
    func dictionaryShapes() async throws {
        let workspace = try TestSupport.makeWorkspace("LayerOverrideShapes")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let (projectId, documentId) = try await identifiers(of: package)

        try await package.write { db in
            // Visibility only.
            try LayerOverrideStore.upsert(db, LayerOverrideRecord(
                projectId: projectId, documentId: documentId, layerId: "ocg:0",
                visible: false, locked: nil
            ))
            // Lock only.
            try LayerOverrideStore.upsert(db, LayerOverrideRecord(
                projectId: projectId, documentId: documentId, layerId: "ocg:1",
                visible: nil, locked: true
            ))
            // Both.
            try LayerOverrideStore.upsert(db, LayerOverrideRecord(
                projectId: projectId, documentId: documentId, layerId: "ocg:2",
                visible: true, locked: false
            ))
        }

        let visibility = try await package.read { db in
            try LayerOverrideStore.visibilityOverrides(db, projectId: projectId, documentId: documentId)
        }
        #expect(visibility == ["ocg:0": false, "ocg:2": true],
                "lock-only rows must not appear as visibility overrides")

        // Read back through the rows themselves (V-097: the `[layerId: locked]` helper had no
        // caller outside this test).
        let rows = try await package.read { db in
            try LayerOverrideStore.overrides(db, projectId: projectId, documentId: documentId)
        }
        #expect(rows.map(\.layerId) == ["ocg:0", "ocg:1", "ocg:2"])
        #expect(rows.map(\.locked) == [nil, true, false])
        try await package.close()
    }

    @Test("Deleting the document cascades its overrides away")
    func documentCascade() async throws {
        let workspace = try TestSupport.makeWorkspace("LayerOverrideCascade")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let (projectId, documentId) = try await identifiers(of: package)

        try await package.write { db in
            try LayerOverrideStore.upsert(db, LayerOverrideRecord(
                projectId: projectId, documentId: documentId, layerId: "ocg:0",
                visible: false, locked: nil
            ))
        }
        try await package.write { db in
            try db.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [documentId])
        }
        let remaining = try await package.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM layer_override") ?? -1
        }
        #expect(remaining == 0)
        #expect(try await package.database.foreignKeyViolationCount() == 0)
        try await package.close()
    }

    @Test("Overrides survive save, close and reopen")
    func saveAndReopen() async throws {
        let workspace = try TestSupport.makeWorkspace("LayerOverrideSave")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let (projectId, documentId) = try await identifiers(of: package)

        let records = [
            LayerOverrideRecord(
                projectId: projectId, documentId: documentId, layerId: "ocg:0",
                visible: false, locked: nil
            ),
            LayerOverrideRecord(
                projectId: projectId, documentId: documentId, layerId: "ocg:2",
                visible: true, locked: true
            )
        ]
        try await package.write { db in
            for record in records { try LayerOverrideStore.upsert(db, record) }
        }
        try await package.save()
        try await package.close()

        switch try await ProjectPackage.open(at: workspace.packageURL) {
        case let .opened(reopened):
            let fetched = try await reopened.read { db in
                try LayerOverrideStore.overrides(db, projectId: projectId, documentId: documentId)
            }
            #expect(fetched == records)
            try await reopened.close()
        case let .recoveryRequired(report), let .openElsewhere(_, report):
            Issue.record("clean save should reopen without recovery: \(report)")
        }
    }
}
