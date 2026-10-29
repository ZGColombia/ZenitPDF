import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// The schema is a file format. These tests are the guard against it drifting: a column
/// renamed for tidiness is a project file that a shipped build can no longer read.
struct SchemaTests {

    /// Spec 8.2, transcribed as `table: [column names in declaration order]`.
    static let expectedColumns: [String: [String]] = [
        "project": ["id", "name", "created_at", "modified_at", "schema_version"],
        "document": [
            "id", "project_id", "display_name", "relative_path", "sha256",
            "page_count", "active_revision_id", "created_at", "modified_at"
        ],
        "page": [
            "id", "document_id", "page_index", "page_label",
            "media_x", "media_y", "media_width", "media_height",
            "crop_x", "crop_y", "crop_width", "crop_height",
            "rotation", "geometry_hash"
        ],
        "scale_definition": [
            "id", "page_id", "name", "matrix_a", "matrix_b", "matrix_c", "matrix_d",
            "translation_x", "translation_y", "base_length_unit", "source_type",
            "calibration_json", "precision_mode", "version", "locked",
            "created_at", "modified_at"
        ],
        "scale_region": [
            "id", "page_id", "name", "polygon_blob", "scale_id",
            "priority", "color_rgba", "visible", "locked"
        ],
        "project_zone": [
            "id", "page_id", "name", "polygon_blob", "sort_order",
            "color_rgba", "visible", "locked"
        ],
        "markup": [
            "id", "document_id", "page_id", "type", "subject", "label", "comment",
            "geometry_blob", "style_blob", "scale_id", "scale_version",
            "scale_region_id", "zone_id", "layer_name", "status", "author",
            "locked", "hidden", "created_at", "modified_at", "revision"
        ],
        "measurement_value": [
            "markup_id", "count_value", "plan_length_si", "true_length_si",
            "perimeter_si", "plan_area_si", "true_area_si", "wall_area_si",
            "volume_si", "rise_si", "run_si", "slope_ratio", "slope_percent",
            "slope_angle_radians", "depth_si", "height_si", "radius_si",
            "diameter_si", "formula_version"
        ],
        "custom_column": [
            "id", "project_id", "name", "type", "dimension_json", "currency_code",
            "formula", "choice_values_json", "default_value", "sort_order", "visible",
            // v11 (BH-075): the application's complete column definition.
            "definition_json"
        ],
        "custom_value": ["markup_id", "column_id", "value_text"],
        "tool_preset": [
            "id", "project_id", "name", "category", "markup_type", "style_blob",
            "defaults_json", "symbol_data", "source", "sort_order"
        ],
        "ocr_token": [
            "id", "page_id", "token", "normalized_token", "confidence",
            "bounds_blob", "line_index", "token_index"
        ],
        "search_fts": [
            "project_id", "document_id", "page_id", "source_type", "source_id", "content"
        ],
        "measurement_audit": [
            "id", "project_id", "markup_id", "sequence", "occurred_at", "action", "actor",
            "before_values_json", "after_values_json", "scale_id", "scale_version",
            "formula_version", "command_name", "undo_group", "note"
        ],
        "takeoff_state": ["document_id", "default_scale_id", "saved_at"],
        "markup_extra": [
            "markup_id", "kind", "sort_order", "parent_markup_id", "count_group_id",
            "caption", "printable", "parameters_json", "geometry_json", "custom_values_json",
            "provenance", "derivation_json",
            // v17 (ADR-0031): the capture method of a detector's geometry.
            "capture_json",
            // v18 (ADR-0032): the markup layer; NULL is the default layer.
            "layer_id"
        ],
        "markup_layer": ["project_id", "id", "name", "sort_order", "visible", "locked", "printable"],
        "project_setting": ["project_id", "key", "value_json"],
        "project_zone_extra": ["zone_id", "kind", "parent_zone_id", "spans_pages"],
        "markup_stamp": [
            "markup_id", "template_id", "template_name", "template_revision",
            "artwork_digest", "artwork_kind", "width_points", "height_points",
            "rotation_degrees", "fields_json", "resolved_at"
        ],
        "stamp_artwork": [
            "digest", "kind", "data", "byte_count", "source_name",
            "source_page_index", "pixel_width", "pixel_height",
            "geometry_json", "compiler_version"
        ],
        "markup_symbol": [
            "markup_id", "artwork_digest", "artwork_kind", "built_in_glyph",
            "size_points", "rotation_degrees", "source_name"
        ]
    ]

    private func openMigrated(_ label: String) async throws -> (ProjectDatabaseActor, URL) {
        let directory = try TestSupport.makeTemporaryDirectory(label)
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite")
        )
        return (database, directory)
    }

    @Test("Every table and every column of spec 8.2 is present, by name")
    func columnsMatchTheSpecification() async throws {
        let (database, directory) = try await openMigrated("Schema")
        defer { try? FileManager.default.removeItem(at: directory) }

        for (table, expected) in Self.expectedColumns {
            let actual = try await database.read { db in
                try db.columns(in: table).map(\.name)
            }
            #expect(actual == expected, "column mismatch in \(table)")
        }
        try await database.close()
    }

    @Test("The FTS5 table uses unicode61 with remove_diacritics 2")
    func ftsTokenizerIsExact() async throws {
        let (database, directory) = try await openMigrated("SchemaFTS")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sql = try await database.read { db in
            try String.fetchOne(
                db, sql: "SELECT sql FROM sqlite_master WHERE name = 'search_fts'"
            ) ?? ""
        }
        #expect(sql.contains("USING fts5"))
        #expect(sql.contains("tokenize='unicode61 remove_diacritics 2'"))
        for unindexed in ["project_id UNINDEXED", "document_id UNINDEXED", "page_id UNINDEXED",
                          "source_type UNINDEXED", "source_id UNINDEXED"] {
            #expect(sql.contains(unindexed), "missing \(unindexed)")
        }
        try await database.close()
    }

    @Test("Every declared index exists, and each one has a stated reason")
    func indexesExistAndAreJustified() async throws {
        let (database, directory) = try await openMigrated("SchemaIndex")
        defer { try? FileManager.default.removeItem(at: directory) }

        let present = try await database.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"
            ))
        }
        // v4 replaces v2's plain (markup_id, sequence) index with the UNIQUE one, so the
        // migrated database carries the replacement, not the original.
        let declared = ProjectSchema.indexDefinitions
            + ProjectSchema.auditIndexDefinitions
                .filter { $0.name != "idx_measurement_audit_markup_sequence" }
            + [ProjectSchema.auditUniqueMarkupSequenceIndex]
            + ProjectSchema.layerOverrideIndexDefinitions
            + ProjectSchema.takeoffHydrationIndexDefinitions
            + ProjectSchema.projectStructureIndexDefinitions
            + ProjectSchema.stampIndexDefinitions
            + ProjectSchema.markupSymbolIndexDefinitions
            + ProjectSchema.pageScaleIndexDefinitions
            + ProjectSchema.reviewEntryIndexDefinitions
            + ProjectSchema.documentSetIndexDefinitions
            + ProjectSchema.ledgerSnapshotIndexDefinitions
            + ProjectSchema.authorIndexDefinitions
            + ProjectSchema.automationProposalIndexDefinitions
        for definition in declared {
            #expect(present.contains(definition.name), "missing index \(definition.name)")
            #expect(definition.rationale.count > 40, "\(definition.name) has no real rationale")
        }
        #expect(present.count == declared.count, "undocumented index present")
        try await database.close()
    }

    @Test("The hot queries use an index rather than scanning the table")
    func queryPlansUseIndexes() async throws {
        let (database, directory) = try await openMigrated("SchemaPlan")
        defer { try? FileManager.default.removeItem(at: directory) }

        let plans: [(String, String)] = [
            ("SELECT * FROM markup WHERE page_id = 'p'", "idx_markup_page_id"),
            ("SELECT * FROM markup WHERE document_id = 'd'", "idx_markup_document_page"),
            ("SELECT * FROM markup WHERE zone_id = 'z'", "idx_markup_zone_id"),
            ("SELECT * FROM markup WHERE status = 's'", "idx_markup_status"),
            ("SELECT * FROM custom_value WHERE column_id = 'c'", "idx_custom_value_column_id"),
            ("SELECT * FROM custom_value WHERE markup_id = 'm'", "sqlite_autoindex_custom_value_1"),
            ("SELECT * FROM measurement_value WHERE markup_id = 'm'", "sqlite_autoindex_measurement_value_1")
        ]
        for (sql, expectedIndex) in plans {
            let plan = try await database.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)")
                    .compactMap { $0["detail"] as String? }
                    .joined(separator: " | ")
            }
            #expect(plan.contains(expectedIndex), "\(sql) planned as: \(plan)")
        }
        try await database.close()
    }

    @Test("Foreign keys really cascade")
    func cascadesAreEnforced() async throws {
        let workspace = try TestSupport.makeWorkspace("SchemaCascade")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let geometry = try TestSupport.sampleGeometry()

        try await package.write { db in
            try MarkupRecord(
                id: "m1", documentId: documentId, pageId: pageId, type: "count",
                subject: "Outlet", geometryBlob: geometry, styleBlob: Data([1]),
                createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
            ).insert(db)
            try MeasurementValueRecord(
                markupId: "m1", countValue: DecimalString(text: "1"), formulaVersion: 1
            ).insert(db)
        }
        let afterDelete = try await package.write { db -> Int in
            try db.execute(sql: "DELETE FROM markup WHERE id = 'm1'")
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement_value") ?? -1
        }
        #expect(afterDelete == 0)

        // And the other direction: a measurement row for a markup that does not exist
        // is refused outright.
        await #expect(throws: (any Error).self) {
            try await package.write { db in
                try MeasurementValueRecord(markupId: "ghost", formulaVersion: 1).insert(db)
            }
        }
        try await package.close()
    }
}
