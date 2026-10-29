import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v9: a scale belongs to a page, and an existing project is **migrated** to say so
/// rather than reinterpreted every time it is opened.
///
/// The honest reading of a pre-v9 file is fixed by what the old writer did: it parked every
/// `scale_definition` row on the document's first page and pointed
/// `takeoff_state.default_scale_id` at the one the whole document shared. So the document
/// default belonged to page one, and to no other page. These tests hold the migration to
/// exactly that reading — no more pages, no fewer — because a project that opens with silently
/// reassigned scales is the failure per-page scale exists to prevent.
struct PageScaleMigrationTests {

    /// A database migrated to v8 only, carrying the shape a pre-per-page-scale build wrote:
    /// four pages, one scale recorded against page one, and a `takeoff_state` row naming it.
    private func makePreV9Database(
        _ label: String,
        extraScaleOnFirstPage: Bool = false
    ) throws -> (DatabaseQueue, URL, pageIDs: [String], scaleID: String, extraScaleID: String) {
        let directory = try TestSupport.makeTemporaryDirectory(label)
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("pre-v9.sqlite").path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v8-artwork-geometry")

        let projectID = UUID().uuidString
        let documentID = UUID().uuidString
        let pageIDs = (0..<4).map { _ in UUID().uuidString }
        let scaleID = UUID().uuidString
        let extraScaleID = UUID().uuidString
        let stamp = "2026-08-01T00:00:00.000Z"

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO project (id, name, created_at, modified_at, schema_version)
                    VALUES (?, 'Pre v9', ?, ?, 8)
                    """,
                arguments: [projectID, stamp, stamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO document
                        (id, project_id, display_name, relative_path, sha256, page_count,
                         created_at, modified_at)
                    VALUES (?, ?, 'Set', 'Drawings/set.pdf', 'sha', 4, ?, ?)
                    """,
                arguments: [documentID, projectID, stamp, stamp]
            )
            for (index, pageID) in pageIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO page
                            (id, document_id, page_index, page_label,
                             media_x, media_y, media_width, media_height,
                             crop_x, crop_y, crop_width, crop_height, rotation)
                        VALUES (?, ?, ?, ?, 0, 0, 612, 792, 0, 0, 612, 792, 0)
                        """,
                    arguments: [pageID, documentID, index, "A-10\(index)"]
                )
            }
            func insertScale(_ id: String, _ name: String) throws {
                try db.execute(
                    sql: """
                        INSERT INTO scale_definition
                            (id, page_id, name, matrix_a, matrix_b, matrix_c, matrix_d,
                             translation_x, translation_y, base_length_unit, source_type,
                             precision_mode, version, created_at, modified_at)
                        VALUES (?, ?, ?, '0.01', '0', '0', '0.01', '0', '0', 'metre',
                                'calibrationTwoPoint', 'decimalPlaces:3', 1, ?, ?)
                        """,
                    arguments: [id, pageIDs[0], name, stamp, stamp]
                )
            }
            try insertScale(scaleID, "1:28")
            if extraScaleOnFirstPage {
                // A Scale Region's own calibration: a second scale, on the same page, that was
                // never the document default.
                try insertScale(extraScaleID, "Detail 1:5")
            }
            try db.execute(
                sql: """
                    INSERT INTO takeoff_state (document_id, default_scale_id, saved_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [documentID, scaleID, stamp]
            )
        }
        return (queue, directory, pageIDs, scaleID, extraScaleID)
    }

    @Test("A pre-v9 project's document-wide scale becomes page one's scale, and no other page's")
    func documentDefaultBecomesPageOneOnly() throws {
        let (queue, directory, pageIDs, scaleID, _) = try makePreV9Database("PageScaleV9")
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try queue.read { try $0.tableExists("page_scale") }
        #expect(before == false, "page_scale must not exist before v9")

        try ProjectSchema.migrator().migrate(queue)

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT page_id, scale_id, migrated FROM page_scale")
        }
        #expect(rows.count == 1, "the migration invented an assignment for a page nobody calibrated")
        let row = try #require(rows.first)
        #expect(row["page_id"] as String? == pageIDs[0])
        #expect(row["scale_id"] as String? == scaleID)
        #expect(row["migrated"] as Int? == 1,
                "the row must record that it is the upgrade's reading, not a person's calibration")

        // Pages two to four have no scale, which is what an uncalibrated sheet is. Before this,
        // all four resolved to page one's ratio.
        for pageID in pageIDs.dropFirst() {
            let count = try queue.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM page_scale WHERE page_id = ?", arguments: [pageID]
                )
            }
            #expect(count == 0)
        }
        #expect(
            try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
                == ProjectSchema.currentVersion
        )
    }

    @Test("A Scale Region's own scale is not promoted to the page scale by the migration")
    func regionScaleIsNotPromoted() throws {
        let (queue, directory, pageIDs, scaleID, extraScaleID) =
            try makePreV9Database("PageScaleV9Region", extraScaleOnFirstPage: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try ProjectSchema.migrator().migrate(queue)

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT page_id, scale_id FROM page_scale")
        }
        #expect(rows.count == 1)
        #expect(rows.first?["scale_id"] as String? == scaleID,
                "the document default, not whichever scale the page also holds")
        #expect(rows.contains { $0["scale_id"] as String? == extraScaleID } == false)
        #expect(rows.first?["page_id"] as String? == pageIDs[0])
    }

    @Test("A project that was never calibrated gains no page scale at all")
    func uncalibratedProjectGainsNothing() throws {
        let directory = try TestSupport.makeTemporaryDirectory("PageScaleV9Empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("empty.sqlite").path)
        try ProjectSchema.migrator().migrate(queue, upTo: "v8-artwork-geometry")
        try ProjectSchema.migrator().migrate(queue)

        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_scale") }
        #expect(count == 0, "a page scale was invented for a project with no scale")
    }
}
