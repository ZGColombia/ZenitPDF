import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Schema v10 (ADR-0012): the two provenance columns on `markup_extra`.
@Suite("Provenance columns, v10")
struct ProvenanceMigrationTests {

    @Test("v10 adds the two nullable columns, and a pre-v10 row reads as nil — measured")
    func columnsExistAndOldRowsReadNil() throws {
        let queue = try DatabaseQueue()
        try ProjectSchema.migrator().migrate(queue)

        try queue.write { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(markup_extra)")
                .map { $0["name"] as String }
            #expect(columns.contains("provenance"))
            #expect(columns.contains("derivation_json"))
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == ProjectSchema.currentVersion)

            // A row written the pre-v10 way — no provenance, no derivation — is a measured
            // row, exactly as an absent key is in the JSON contract. Nothing is backfilled.
            try db.execute(sql: """
                INSERT INTO project (id, name, created_at, modified_at, schema_version)
                VALUES ('p', 'P', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 10)
                """)
            try db.execute(sql: """
                INSERT INTO document (id, project_id, display_name, relative_path, sha256,
                                      page_count, created_at, modified_at)
                VALUES ('d', 'p', 'D.pdf', 'documents/original.pdf',
                        '0000000000000000000000000000000000000000000000000000000000000000',
                        1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO page (id, document_id, page_index, page_label,
                                  media_x, media_y, media_width, media_height,
                                  crop_x, crop_y, crop_width, crop_height, rotation, geometry_hash)
                VALUES ('pg', 'd', 0, '1', 0, 0, 612, 792, 0, 0, 612, 792, 0, 'hash')
                """)
            try db.execute(sql: """
                INSERT INTO markup (id, document_id, page_id, type, subject, label, comment,
                                    geometry_blob, style_blob, status, author, locked, hidden,
                                    created_at, modified_at, revision)
                VALUES ('m', 'd', 'pg', 'area', 'S', '', '',
                        x'00', x'00', NULL, '', 0, 0,
                        '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)
                """)
            try db.execute(sql: """
                INSERT INTO markup_extra (markup_id, kind, sort_order, printable)
                VALUES ('m', 'measurement', 0, 1)
                """)
            let extra = try MarkupExtraRecord.fetchOne(db, key: "m")
            #expect(extra?.provenance == nil)
            #expect(extra?.derivationJson == nil)
        }
    }
}
