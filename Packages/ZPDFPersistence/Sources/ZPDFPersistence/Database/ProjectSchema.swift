import Foundation
import GRDB

/// The project database schema, as ordered GRDB migrations.
///
/// The `CREATE TABLE` statements are the spec 8.2 statements verbatim — same tables,
/// same column names, same order, same constraints — because the schema is a file
/// format, and a column renamed for tidiness is a file format that no longer matches
/// its own specification. Indexes are added separately, after the tables, and each one
/// carries the query it exists for.
public enum ProjectSchema {

    /// The number of migrations this build knows. Recorded in `manifest.databaseSchema`
    /// and in `PRAGMA user_version`.
    public static let currentVersion = 18

    /// Migration identifiers in application order. This array *is* the history: a new
    /// schema appends to it and never edits an earlier entry.
    public static let identifiers: [String] = [
        "v1-core-schema",
        "v2-measurement-audit",
        "v3-layer-overrides",
        "v4-audit-unique-markup-sequence",
        "v5-takeoff-hydration",
        "v6-project-structure",
        "v7-stamps",
        "v8-artwork-geometry",
        "v9-page-scale",
        "v10-quantity-provenance",
        "v11-custom-column-definition",
        "v12-review-entries",
        "v13-document-set",
        "v14-ledger-snapshots",
        "v15-page-view-crop",
        "v16-author-directory",
        "v17-automation-proposal-and-capture",
        "v18-markup-layers"
    ]

    /// The migrator this build applies to a project database.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Never erase on schema change. The whole point of this package is that the
        // user's days of work survive a version bump.
        migrator.registerMigration(identifiers[0]) { db in
            try createCoreTables(db)
            try createIndexes(db)
            try db.execute(sql: "PRAGMA user_version = 1")
        }
        // ADR-0007: the append-only measurement audit trail.
        migrator.registerMigration(identifiers[1]) { db in
            try createAuditTable(db)
            try db.execute(sql: "UPDATE project SET schema_version = 2")
            try db.execute(sql: "PRAGMA user_version = 2")
        }
        // Per-project PDF layer visibility overrides.
        migrator.registerMigration(identifiers[2]) { db in
            try createLayerOverrideTable(db)
            try db.execute(sql: "UPDATE project SET schema_version = 3")
            try db.execute(sql: "PRAGMA user_version = 3")
        }
        // ADR-0007 §4 hardening: (markup_id, sequence) becomes UNIQUE, enforced by the
        // database rather than by the append path's discipline.
        migrator.registerMigration(identifiers[3]) { db in
            try upgradeAuditMarkupSequenceIndex(db)
            try db.execute(sql: "UPDATE project SET schema_version = 4")
            try db.execute(sql: "PRAGMA user_version = 4")
        }
        // ADR-0009: the takeoff-hydration companion tables — what spec 8.2's markup
        // columns cannot carry but a faithful reopen needs.
        migrator.registerMigration(identifiers[4]) { db in
            try createTakeoffHydrationTables(db)
            try db.execute(sql: "UPDATE project SET schema_version = 5")
            try db.execute(sql: "PRAGMA user_version = 5")
        }
        // Scale Regions and Project Zones: the two facts spec 8.2's `project_zone` row
        // cannot carry, in the additive companion the v5 migration established.
        migrator.registerMigration(identifiers[5]) { db in
            try createProjectStructureTables(db)
            try db.execute(sql: "UPDATE project SET schema_version = 6")
            try db.execute(sql: "PRAGMA user_version = 6")
        }
        // Stamps: a placed stamp's frozen field values, and the artwork bytes they
        // are drawn over, stored once per digest rather than once per stamp.
        migrator.registerMigration(identifiers[6]) { db in
            try createStampTables(db)
            try db.execute(sql: "UPDATE project SET schema_version = 7")
            try db.execute(sql: "PRAGMA user_version = 7")
        }
        // ADR-0011: imported artwork, compiled once and stored compiled, and the symbol a
        // markup draws itself as.
        migrator.registerMigration(identifiers[7]) { db in
            try createArtworkGeometryColumns(db)
            try createMarkupSymbolTable(db)
            try db.execute(sql: "UPDATE project SET schema_version = 8")
            try db.execute(sql: "PRAGMA user_version = 8")
        }
        // Per-page scale: which of a page's scales *is* the page's scale. Backfilled from what
        // the file already records rather than guessed at open time — see `createPageScaleTable`.
        migrator.registerMigration(identifiers[8]) { db in
            try createPageScaleTable(db)
            try backfillPageScaleFromDocumentDefault(db)
            try db.execute(sql: "UPDATE project SET schema_version = 9")
            try db.execute(sql: "PRAGMA user_version = 9")
        }
        // ADR-0012: which claim a row's quantity makes. Two nullable columns on the v5
        // companion table: `provenance` (absent means `measured`, exactly as absent means
        // `measured` in the JSON contract — no backfill, no guessing) and the derivation,
        // stored as the contract's own JSON so the OCR text a `read` row was read from
        // survives byte for byte.
        migrator.registerMigration(identifiers[9]) { db in
            try db.execute(sql: "ALTER TABLE markup_extra ADD COLUMN provenance TEXT")
            try db.execute(sql: "ALTER TABLE markup_extra ADD COLUMN derivation_json TEXT")
            try db.execute(sql: "UPDATE project SET schema_version = 10")
            try db.execute(sql: "PRAGMA user_version = 10")
        }
        // BH-075: spec 8.2's `custom_column` stores a name and a type but not a
        // column's key, precision, display unit or editability, so an imported ledger column
        // could not round-trip without changing identity. One nullable column holds the
        // application's complete definition as JSON. Additive: an older row has none and
        // reads exactly as before; nothing is backfilled.
        migrator.registerMigration(identifiers[10]) { db in
            try db.execute(sql: "ALTER TABLE custom_column ADD COLUMN definition_json TEXT")
            try db.execute(sql: "UPDATE project SET schema_version = 11")
            try db.execute(sql: "PRAGMA user_version = 11")
        }
        // ADR-0021 (collaboration), NL-COLLAB-01: review threads — replies on a markup, each
        // with its own author and time. A new table only: nothing existing is altered or
        // backfilled, so an older project gains an empty thread for every markup.
        migrator.registerMigration(identifiers[11]) { db in
            try createReviewEntryTable(db)
            try db.execute(sql: "UPDATE project SET schema_version = 12")
            try db.execute(sql: "PRAGMA user_version = 12")
        }
        // ADR-0022 (documents), NL-DOCS-02/04/05/11: a page's place in the set and its sheet
        // identity, a document's place in a multi-drawing project, and persisted revisions.
        // New tables only; nothing is backfilled — a page without an entry keeps its PDF order.
        migrator.registerMigration(identifiers[12]) { db in
            try createDocumentSetTables(db)
            try db.execute(sql: "UPDATE project SET schema_version = 13")
            try db.execute(sql: "PRAGMA user_version = 13")
        }
        // NL-QTY-16: named takeoff snapshots for the quantity-change report.
        // One new table; nothing existing is touched or backfilled.
        migrator.registerMigration(identifiers[13]) { db in
            try createLedgerSnapshotTable(db)
            try db.execute(sql: "UPDATE project SET schema_version = 14")
            try db.execute(sql: "PRAGMA user_version = 14")
        }
        // NL-DOCS-16: a per-page view crop beside the view rotation.
        // One nullable column; nothing is backfilled — a page without a crop shows its crop box.
        migrator.registerMigration(identifiers[14]) { db in
            try db.execute(sql: pageViewCropColumnStatement)
            try db.execute(sql: "UPDATE project SET schema_version = 15")
            try db.execute(sql: "PRAGMA user_version = 15")
        }
        // NL-COLLAB-05: the project's author directory — a stable id, name,
        // initials, colour and company per person. A new table only; nothing is backfilled, so an
        // older project's people appear as they next sign something.
        migrator.registerMigration(identifiers[15]) { db in
            try createAuthorTable(db)
            try db.execute(sql: "UPDATE project SET schema_version = 16")
            try db.execute(sql: "PRAGMA user_version = 16")
        }
        // NL-AUTO-16: the Takeoff Assistant's inbox of proposals per page, and
        // NL-AUTO-18 (ADR-0031): the capture method of a markup's geometry, which the session
        // recomputes every measurement without, so it is kept beside the geometry. A new table and
        // one nullable column; nothing is backfilled — an older markup reads as drawn by hand.
        migrator.registerMigration(identifiers[16]) { db in
            try createAutomationProposalTable(db)
            try db.execute(sql: "ALTER TABLE markup_extra ADD COLUMN capture_json TEXT")
            try db.execute(sql: "UPDATE project SET schema_version = 17")
            try db.execute(sql: "PRAGMA user_version = 17")
        }
        // ADR-0032: a project's markup layers, the layer each markup belongs to, and
        // project settings (display units, active layer). Two new tables and one nullable column;
        // every project gets its default layer row, and no markup is rewritten — NULL is the
        // default layer.
        migrator.registerMigration(identifiers[17]) { db in
            try createMarkupLayerTables(db)
            try db.execute(sql: "UPDATE project SET schema_version = 18")
            try db.execute(sql: "PRAGMA user_version = 18")
        }
        return migrator
    }

    // MARK: - Compatibility

    /// Refuses a database that was migrated past what this build understands.
    ///
    /// GRDB records every applied migration by identifier in `grdb_migrations`. An
    /// identifier we have never heard of means the file was written by a newer Zenit
    /// PDF, and the only safe response is to stop before opening it for writing — a
    /// forward migration we do not have cannot be reversed by guessing.
    public static func assertCompatible(_ db: Database) throws {
        guard try db.tableExists("grdb_migrations") else { return }
        let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        let known = Set(identifiers)
        if let unknown = applied.first(where: { !known.contains($0) }) {
            throw ZPDFPersistenceError.databaseSchemaTooNew(found: unknown, supported: currentVersion)
        }
        let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        if userVersion > currentVersion {
            throw ZPDFPersistenceError.databaseSchemaTooNew(
                found: "user_version \(userVersion)",
                supported: currentVersion
            )
        }
    }

    // MARK: - v1

    /// Spec 8.2, reproduced statement for statement.
    public static let coreTableStatements: [String] = [
        """
        CREATE TABLE project (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            modified_at TEXT NOT NULL,
            schema_version INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE document (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            display_name TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            page_count INTEGER NOT NULL,
            active_revision_id TEXT,
            created_at TEXT NOT NULL,
            modified_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE page (
            id TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL,
            page_label TEXT,
            media_x REAL NOT NULL,
            media_y REAL NOT NULL,
            media_width REAL NOT NULL,
            media_height REAL NOT NULL,
            crop_x REAL NOT NULL,
            crop_y REAL NOT NULL,
            crop_width REAL NOT NULL,
            crop_height REAL NOT NULL,
            rotation INTEGER NOT NULL,
            geometry_hash TEXT,
            UNIQUE(document_id, page_index)
        )
        """,
        """
        CREATE TABLE scale_definition (
            id TEXT PRIMARY KEY NOT NULL,
            page_id TEXT NOT NULL REFERENCES page(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            matrix_a TEXT NOT NULL,
            matrix_b TEXT NOT NULL,
            matrix_c TEXT NOT NULL,
            matrix_d TEXT NOT NULL,
            translation_x TEXT NOT NULL,
            translation_y TEXT NOT NULL,
            base_length_unit TEXT NOT NULL,
            source_type TEXT NOT NULL,
            calibration_json TEXT,
            precision_mode TEXT NOT NULL,
            version INTEGER NOT NULL,
            locked INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            modified_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE scale_region (
            id TEXT PRIMARY KEY NOT NULL,
            page_id TEXT NOT NULL REFERENCES page(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            polygon_blob BLOB NOT NULL,
            scale_id TEXT NOT NULL REFERENCES scale_definition(id),
            priority INTEGER NOT NULL,
            color_rgba INTEGER NOT NULL,
            visible INTEGER NOT NULL DEFAULT 1,
            locked INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE project_zone (
            id TEXT PRIMARY KEY NOT NULL,
            page_id TEXT NOT NULL REFERENCES page(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            polygon_blob BLOB NOT NULL,
            sort_order INTEGER NOT NULL,
            color_rgba INTEGER NOT NULL,
            visible INTEGER NOT NULL DEFAULT 1,
            locked INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE markup (
            id TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
            page_id TEXT NOT NULL REFERENCES page(id) ON DELETE CASCADE,
            type TEXT NOT NULL,
            subject TEXT NOT NULL,
            label TEXT,
            comment TEXT,
            geometry_blob BLOB NOT NULL,
            style_blob BLOB NOT NULL,
            scale_id TEXT REFERENCES scale_definition(id),
            scale_version INTEGER,
            scale_region_id TEXT REFERENCES scale_region(id),
            zone_id TEXT REFERENCES project_zone(id),
            layer_name TEXT,
            status TEXT,
            author TEXT,
            locked INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            modified_at TEXT NOT NULL,
            revision INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE measurement_value (
            markup_id TEXT PRIMARY KEY NOT NULL REFERENCES markup(id) ON DELETE CASCADE,
            count_value TEXT,
            plan_length_si TEXT,
            true_length_si TEXT,
            perimeter_si TEXT,
            plan_area_si TEXT,
            true_area_si TEXT,
            wall_area_si TEXT,
            volume_si TEXT,
            rise_si TEXT,
            run_si TEXT,
            slope_ratio TEXT,
            slope_percent TEXT,
            slope_angle_radians TEXT,
            depth_si TEXT,
            height_si TEXT,
            radius_si TEXT,
            diameter_si TEXT,
            formula_version INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE custom_column (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            dimension_json TEXT,
            currency_code TEXT,
            formula TEXT,
            choice_values_json TEXT,
            default_value TEXT,
            sort_order INTEGER NOT NULL,
            visible INTEGER NOT NULL DEFAULT 1
        )
        """,
        """
        CREATE TABLE custom_value (
            markup_id TEXT NOT NULL REFERENCES markup(id) ON DELETE CASCADE,
            column_id TEXT NOT NULL REFERENCES custom_column(id) ON DELETE CASCADE,
            value_text TEXT,
            PRIMARY KEY(markup_id, column_id)
        )
        """,
        """
        CREATE TABLE tool_preset (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT REFERENCES project(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            category TEXT NOT NULL,
            markup_type TEXT NOT NULL,
            style_blob BLOB NOT NULL,
            defaults_json TEXT NOT NULL,
            symbol_data BLOB,
            source TEXT NOT NULL,
            sort_order INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE ocr_token (
            id INTEGER PRIMARY KEY,
            page_id TEXT NOT NULL REFERENCES page(id) ON DELETE CASCADE,
            token TEXT NOT NULL,
            normalized_token TEXT NOT NULL,
            confidence REAL NOT NULL,
            bounds_blob BLOB NOT NULL,
            line_index INTEGER NOT NULL,
            token_index INTEGER NOT NULL
        )
        """,
        """
        CREATE VIRTUAL TABLE search_fts USING fts5(
            project_id UNINDEXED,
            document_id UNINDEXED,
            page_id UNINDEXED,
            source_type UNINDEXED,
            source_id UNINDEXED,
            content,
            tokenize='unicode61 remove_diacritics 2'
        )
        """
    ]

    static func createCoreTables(_ db: Database) throws {
        for statement in coreTableStatements {
            try db.execute(sql: statement)
        }
    }

    /// One entry per index: the SQL, and the query pattern that pays for it.
    ///
    /// Every index is a tax on every insert. The 100 000-markup import in the
    /// performance suite pays it eight times per row, so an index that no query uses is
    /// not neutral — it is a measurable regression. These are the ones that earn it.
    public struct IndexDefinition: Sendable, Hashable {
        public let name: String
        public let sql: String
        /// Why this index exists, in terms of a real query.
        public let rationale: String
    }

    public static let indexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_markup_page_id",
            sql: "CREATE INDEX idx_markup_page_id ON markup(page_id)",
            rationale: """
                Markup by page. The canvas draws exactly one page and needs every markup \
                on it; without this, turning a page on a 100 000-markup project is a full \
                table scan. This is the single hottest query in the application.
                """
        ),
        .init(
            name: "idx_markup_document_page",
            sql: "CREATE INDEX idx_markup_document_page ON markup(document_id, page_id)",
            rationale: """
                Markup by document. The ledger loads a whole document, and the leading \
                column also serves the ON DELETE CASCADE from document. The trailing \
                page_id lets a document-wide load come back already grouped by page, \
                which is the order the ledger and every export walk it in.
                """
        ),
        .init(
            name: "idx_markup_zone_id",
            sql: "CREATE INDEX idx_markup_zone_id ON markup(zone_id)",
            rationale: """
                Markup by zone. Zone subtotals in the ledger and the zone filter both \
                select on this column, and it is the parent-key lookup that project_zone \
                deletion needs; without it SQLite scans markup once per deleted zone.
                """
        ),
        .init(
            name: "idx_markup_status",
            sql: "CREATE INDEX idx_markup_status ON markup(status)",
            rationale: """
                Markup by status. The review workflow filters on status, which is NULL \
                for most rows in a fresh project — exactly the low-cardinality-with-a-hot- \
                minority shape a b-tree index handles well.
                """
        ),
        .init(
            name: "idx_markup_scale_id",
            sql: "CREATE INDEX idx_markup_scale_id ON markup(scale_id)",
            rationale: """
                Foreign-key support. Editing a scale must find every markup that depends \
                on it to bump scale_version and recompute; SQLite has no automatic index \
                for a child key, so without this a scale edit scans the whole table.
                """
        ),
        .init(
            name: "idx_markup_scale_region_id",
            sql: "CREATE INDEX idx_markup_scale_region_id ON markup(scale_region_id)",
            rationale: "Foreign-key support, for the same reason as idx_markup_scale_id."
        ),
        .init(
            name: "idx_custom_value_column_id",
            sql: "CREATE INDEX idx_custom_value_column_id ON custom_value(column_id)",
            rationale: """
                custom_value by column. The composite primary key (markup_id, column_id) \
                already indexes by markup on its leading column, so "by markup" needs \
                nothing further; "by column" needs this one, and it is also what makes \
                deleting a custom column O(matching rows) instead of O(table).
                """
        ),
        .init(
            name: "idx_document_project_id",
            sql: "CREATE INDEX idx_document_project_id ON document(project_id)",
            rationale: "Every document in the project, and the cascade from project."
        ),
        .init(
            name: "idx_scale_definition_page_id",
            sql: "CREATE INDEX idx_scale_definition_page_id ON scale_definition(page_id)",
            rationale: "The scales available on the page the user is looking at."
        ),
        .init(
            name: "idx_scale_region_page_id",
            sql: "CREATE INDEX idx_scale_region_page_id ON scale_region(page_id)",
            rationale: "Scale-region hit testing loads the regions of the current page."
        ),
        .init(
            name: "idx_scale_region_scale_id",
            sql: "CREATE INDEX idx_scale_region_scale_id ON scale_region(scale_id)",
            rationale: "Foreign-key support: which regions block deleting a scale."
        ),
        .init(
            name: "idx_project_zone_page_id",
            sql: "CREATE INDEX idx_project_zone_page_id ON project_zone(page_id)",
            rationale: "Zone overlays are drawn per page, in sort_order."
        ),
        .init(
            name: "idx_custom_column_project_id",
            sql: "CREATE INDEX idx_custom_column_project_id ON custom_column(project_id)",
            rationale: "The ledger's column set is fetched per project on every open."
        ),
        .init(
            name: "idx_tool_preset_project_id",
            sql: "CREATE INDEX idx_tool_preset_project_id ON tool_preset(project_id)",
            rationale: "Project-scoped presets, plus the cascade from project."
        ),
        .init(
            name: "idx_ocr_token_page_id",
            sql: "CREATE INDEX idx_ocr_token_page_id ON ocr_token(page_id)",
            rationale: """
                OCR tokens are read one page at a time for text selection and for the \
                snap layer, and the table is the largest in the database on a scanned \
                drawing set.
                """
        ),
        .init(
            name: "idx_ocr_token_normalized",
            sql: "CREATE INDEX idx_ocr_token_normalized ON ocr_token(normalized_token)",
            rationale: """
                Exact-token lookup that does not go through FTS5 — used to jump from a \
                search hit to the token's bounds, and as the fallback when a query is a \
                single token and the FTS index has not been rebuilt yet.
                """
        )
    ]

    // Indexes SQLite creates for us, noted here so nobody adds a duplicate later — a redundant
    // index costs write throughput and buys nothing. (V-097: this used to be a public
    // dictionary no code read.)
    // - `measurement_value` by markup: `markup_id` is the `TEXT PRIMARY KEY`, so
    //   `sqlite_autoindex_measurement_value_1` already answers it, uniquely.
    // - `custom_value` by markup: leading column of `PRIMARY KEY(markup_id, column_id)`.
    // - `page` by document: leading column of `UNIQUE(document_id, page_index)`.

    static func createIndexes(_ db: Database) throws {
        for definition in indexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    // MARK: - v2 (ADR-0007: measurement audit trail)

    /// The ADR-0007 §2 statement, column for column.
    ///
    /// Deliberately **no foreign keys**: the trail must outlive what it describes. Deleting
    /// a markup is itself an audited event, and the history of a project is complete even
    /// where the current state is not — that is the point. `before_values_json` and
    /// `after_values_json` hold `{field: decimal string}` objects using the same canonical
    /// decimal strings the ledger stores, so a history row and a ledger row compare directly.
    public static let auditTableStatement = """
        CREATE TABLE measurement_audit (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            markup_id TEXT,
            sequence INTEGER NOT NULL,
            occurred_at TEXT NOT NULL,
            action TEXT NOT NULL,
            actor TEXT NOT NULL,
            before_values_json TEXT,
            after_values_json TEXT,
            scale_id TEXT,
            scale_version INTEGER,
            formula_version INTEGER,
            command_name TEXT,
            undo_group TEXT,
            note TEXT
        )
        """

    /// Append-only, enforced by the database itself rather than by convention: an UPDATE or
    /// a DELETE against the trail aborts, whoever issues it. An undo appends a compensating
    /// entry instead (ADR-0007 §2).
    public static let auditTriggerStatements: [String] = [
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
    ]

    /// The two indexes ADR-0007 §4 names, created with the table in migration v2.
    public static let auditIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_measurement_audit_markup_sequence",
            sql: """
                CREATE INDEX idx_measurement_audit_markup_sequence \
                ON measurement_audit(markup_id, sequence)
                """,
            rationale: """
                One markup's own change list, in order — the inspector's per-markup history \
                and the compensating-entry lookup both walk exactly this path (ADR-0007 §4).
                """
        ),
        .init(
            name: "idx_measurement_audit_project_occurred",
            sql: """
                CREATE INDEX idx_measurement_audit_project_occurred \
                ON measurement_audit(project_id, occurred_at)
                """,
            rationale: """
                The History pane: a project's whole trail filtered by date, newest first, \
                without scanning rows that belong to another project (ADR-0007 §4).
                """
        ),
        .init(
            name: "idx_measurement_audit_project_sequence",
            sql: """
                CREATE INDEX idx_measurement_audit_project_sequence \
                ON measurement_audit(project_id, sequence)
                """,
            rationale: """
                Sequence allocation: every append reads MAX(sequence) for the project, and \
                without this index that read scans the whole trail — measured at 3.2 ms per \
                mutation at 100 000 rows, which is exactly the slowdown ADR-0007 §4 forbids. \
                With it the read is one b-tree descent and the project-ordered trail query \
                is index order.
                """
        )
    ]

    static func createAuditTable(_ db: Database) throws {
        try db.execute(sql: auditTableStatement)
        for statement in auditTriggerStatements {
            try db.execute(sql: statement)
        }
        for definition in auditIndexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    // MARK: - v4 (ADR-0007 §4: UNIQUE(markup_id, sequence) on the audit trail)

    /// The unique index that replaces v2's plain `idx_measurement_audit_markup_sequence`.
    ///
    /// `sequence` is allocated project-wide inside the writing transaction, so a
    /// `(markup_id, sequence)` pair can never legitimately repeat. Making the index UNIQUE
    /// turns the one bug class that could corrupt a markup's ordered change list — a
    /// duplicated insert reusing a sequence number — into an immediate constraint failure
    /// instead of a silently ambiguous history. Rows with a NULL `markup_id` (project-level
    /// entries such as a scale change) are unaffected: SQLite treats NULLs as distinct in a
    /// unique index.
    public static let auditUniqueMarkupSequenceIndex = IndexDefinition(
        name: "uidx_measurement_audit_markup_sequence",
        sql: """
            CREATE UNIQUE INDEX uidx_measurement_audit_markup_sequence \
            ON measurement_audit(markup_id, sequence)
            """,
        rationale: """
            One markup's own change list, in order, exactly as v2's non-unique index served \
            it — plus the guarantee that no two entries of one markup can share a sequence \
            number, so the inspector's history can never render an ambiguous order.
            """
    )

    static func upgradeAuditMarkupSequenceIndex(_ db: Database) throws {
        // The unique index answers every query the plain one did, so keeping both would
        // only tax the insert path twice for the same b-tree shape.
        try db.execute(sql: "DROP INDEX IF EXISTS idx_measurement_audit_markup_sequence")
        try db.execute(sql: auditUniqueMarkupSequenceIndex.sql)
    }

    // MARK: - v3 (per-project PDF layer visibility overrides)

    /// One row per (project, document, layer) whose visibility or lock state the
    /// project overrides. **No row means "use the document default"** — the effective
    /// state is always `override ?? documentDefault`, resolved in the PDFKit bridge's
    /// `PDFLayerTree`, so a document revision that renames or reorders its layers
    /// degrades to defaults instead of misapplying stale rows.
    ///
    /// `layer_id` is the bridge's stable `PDFLayerID.rawValue` (`"ocg:<index>"`, the
    /// group's position in `/OCProperties /OCGs`), never the display name: layer names
    /// are legally duplicable inside one document.
    ///
    /// `visible` and `locked` are nullable so one row can override either dimension
    /// alone; the CHECK refuses a row that overrides neither, because such a row is
    /// indistinguishable from its own absence and would only accumulate.
    public static let layerOverrideTableStatement = """
        CREATE TABLE layer_override (
            project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
            layer_id TEXT NOT NULL,
            visible INTEGER,
            locked INTEGER,
            PRIMARY KEY(project_id, document_id, layer_id),
            CHECK (visible IS NOT NULL OR locked IS NOT NULL)
        )
        """

    /// The one index v3 adds. The composite primary key already serves the hot query
    /// ("every override for this document in this project") through its two leading
    /// columns; what it cannot serve is the child-key lookup for `document` deletion.
    public static let layerOverrideIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_layer_override_document_id",
            sql: "CREATE INDEX idx_layer_override_document_id ON layer_override(document_id)",
            rationale: """
                Foreign-key support: deleting a document must find its override rows, \
                and document_id is not a leading column of the primary key, so without \
                this SQLite scans layer_override once per deleted document.
                """
        )
    ]

    static func createLayerOverrideTable(_ db: Database) throws {
        try db.execute(sql: layerOverrideTableStatement)
        for definition in layerOverrideIndexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    // MARK: - v5 (ADR-0009: takeoff hydration)

    /// The two companion tables that make a saved takeoff fully reopenable.
    ///
    /// Spec 8.2's `markup` row carries everything a foreign reader needs, but not
    /// everything the session holds: the markup *kind* behind the tool, the in-document
    /// draw order, the cutout parent link, the measurement parameters, and — for count
    /// markups — the count points' stable identities. Widening the frozen `markup` table
    /// would change spec 8.2's shape for every reader; these companions are additive and
    /// keyed by `markup_id`, so a reader that ignores them still reads a valid project.
    ///
    /// `takeoff_state` records the one per-document fact no row carries: which scale is
    /// the document default. Absent row means "no takeoff has been saved by a v5+ build",
    /// which is how hydration tells an old package from an empty one.
    public static let takeoffHydrationTableStatements: [String] = [
        """
        CREATE TABLE takeoff_state (
            document_id TEXT PRIMARY KEY NOT NULL REFERENCES document(id) ON DELETE CASCADE,
            default_scale_id TEXT,
            saved_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE markup_extra (
            markup_id TEXT PRIMARY KEY NOT NULL REFERENCES markup(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            parent_markup_id TEXT REFERENCES markup(id) ON DELETE CASCADE,
            count_group_id TEXT,
            caption TEXT,
            printable INTEGER NOT NULL DEFAULT 1,
            parameters_json TEXT,
            geometry_json TEXT,
            custom_values_json TEXT
        )
        """
    ]

    /// The one index v5 adds: the child-key lookup for deleting a cutout's parent.
    /// The primary key already serves "extras of this markup".
    public static let takeoffHydrationIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_markup_extra_parent",
            sql: "CREATE INDEX idx_markup_extra_parent ON markup_extra(parent_markup_id)",
            rationale: """
                Foreign-key support: deleting a parent markup cascades into its cutouts' \
                extras, and parent_markup_id is not a leading key column, so without this \
                SQLite scans markup_extra once per deleted markup.
                """
        )
    ]

    static func createTakeoffHydrationTables(_ db: Database) throws {
        for statement in takeoffHydrationTableStatements {
            try db.execute(sql: statement)
        }
        for definition in takeoffHydrationIndexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    // MARK: - v6 (Scale Regions and Project Zones)

    /// The companion that makes a Project Zone reopenable as the person created it.
    ///
    /// Spec 8.2's `project_zone` row carries the polygon, the colour, the sort order and
    /// the visibility, but not two facts the panel lets a person state: **what the zone
    /// represents** (room, floor, trade area — `ProjectZoneKind`) and **which zone it is
    /// nested inside**. Widening the frozen table would change spec 8.2's shape for every
    /// reader, so this is additive and keyed by `zone_id`, exactly as `markup_extra` is
    /// keyed by `markup_id`: a reader that ignores it still reads a valid project.
    ///
    /// `spans_pages` exists because `project_zone.page_id` is `NOT NULL` while a zone
    /// legitimately has no page at all — "Phase 2" spans the whole set. Such a zone is
    /// written against the first page with an empty polygon and this flag set, and the
    /// flag is what stops a reopen from claiming the zone lives on a page nobody put it on.
    public static let projectStructureTableStatements: [String] = [
        """
        CREATE TABLE project_zone_extra (
            zone_id TEXT PRIMARY KEY NOT NULL REFERENCES project_zone(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            parent_zone_id TEXT REFERENCES project_zone(id) ON DELETE SET NULL,
            spans_pages INTEGER NOT NULL DEFAULT 0
        )
        """
    ]

    /// The one index v6 adds: the child-key lookup a zone deletion needs.
    public static let projectStructureIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_project_zone_extra_parent",
            sql: "CREATE INDEX idx_project_zone_extra_parent ON project_zone_extra(parent_zone_id)",
            rationale: """
                Foreign-key support: deleting a zone must find the rows that name it as \
                parent, and parent_zone_id is not the primary key, so without this SQLite \
                scans project_zone_extra once per deleted zone.
                """
        )
    ]

    static func createProjectStructureTables(_ db: Database) throws {
        for statement in projectStructureTableStatements {
            try db.execute(sql: statement)
        }
        for definition in projectStructureIndexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    // MARK: - v7 (stamps)

    /// What a placed stamp needs in order to reopen saying exactly what it said.
    ///
    /// Two additions, both in the additive companion style ADR-0009 established, so a
    /// reader that ignores them still reads a valid project.
    ///
    /// - **`markup_stamp`**, keyed by `markup_id`: the template the stamp came from and the
    ///   dynamic-field values that were resolved at placement and frozen. The values are
    ///   stored as text, not as a recipe — the rule is that a stamp that says 2026-08-24
    ///   must still say that next year, and a row that stored `"date"` and re-derived it
    ///   on read would break that on the first reopen.
    ///
    /// - **`stamp_artwork`**, keyed by the artwork's SHA-256: the bytes, once. A batch that
    ///   puts one stamp on 312 sheets writes 312 `markup_stamp` rows and **one**
    ///   `stamp_artwork` row. Storing artwork per markup instead would multiply an imported
    ///   PDF page by the page count, which is how a 4 MB seal becomes a 1.2 GB project.
    ///
    /// `stamp_artwork` deliberately carries no foreign key to `markup`: artwork outlives the
    /// stamps that reference it (a preset still points at it) and a cascade would delete the
    /// bytes the moment the last stamp using them was undone.
    public static let stampTableStatements: [String] = [
        """
        CREATE TABLE markup_stamp (
            markup_id TEXT PRIMARY KEY NOT NULL REFERENCES markup(id) ON DELETE CASCADE,
            template_id TEXT NOT NULL,
            template_name TEXT NOT NULL,
            template_revision INTEGER NOT NULL DEFAULT 1,
            artwork_digest TEXT,
            artwork_kind TEXT NOT NULL,
            width_points REAL NOT NULL,
            height_points REAL NOT NULL,
            rotation_degrees REAL NOT NULL DEFAULT 0,
            fields_json TEXT NOT NULL,
            resolved_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE stamp_artwork (
            digest TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            data BLOB NOT NULL,
            byte_count INTEGER NOT NULL,
            source_name TEXT,
            source_page_index INTEGER,
            pixel_width INTEGER,
            pixel_height INTEGER
        )
        """
    ]

    /// The one index v7 adds.
    public static let stampIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_markup_stamp_template",
            sql: "CREATE INDEX idx_markup_stamp_template ON markup_stamp(template_id)",
            rationale: """
                The scoped batch apply's skip rule asks "which pages already carry this \
                stamp?" once per batch, and a batch preview must stay interactive on a \
                1 000-page set. Without this the answer is a full scan of markup_stamp.
                """
        )
    ]

    static func createStampTables(_ db: Database) throws {
        for statement in stampTableStatements {
            try db.execute(sql: statement)
        }
        for definition in stampIndexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    // MARK: - v8

    /// The two columns v8 adds to `stamp_artwork`.
    ///
    /// # Why the compiled geometry is stored and not re-derived
    ///
    /// `stamp_artwork` already held the **source bytes** — an imported PDF page or an image.
    /// Drawing from those would mean re-scanning an untrusted PDF on every open of every
    /// project that ever embedded it, and it would make the picture a function of the build:
    /// a stamp signed off last year would be redrawn by this year's compiler. So the row now
    /// holds all three things — the bytes, the geometry compiled from them, and the version of
    /// the compiler that did it — and the bytes are provenance and a re-compilation input,
    /// never a rendering input (ADR-0011 §2.2).
    ///
    /// `compiler_version` is what makes a future change safe: a build that compiles artwork
    /// differently can tell which rows it produced and which it inherited, and can decide
    /// per row rather than for the whole file.
    public static let artworkGeometryColumnStatements: [String] = [
        "ALTER TABLE stamp_artwork ADD COLUMN geometry_json TEXT",
        "ALTER TABLE stamp_artwork ADD COLUMN compiler_version INTEGER"
    ]

    /// Largest compiled-geometry document this schema will store, in UTF-8 bytes.
    ///
    /// A second bound, deliberately coarse and deliberately here. The semantic limits — how
    /// many contours, how many points — belong to the contract and are enforced where the
    /// artwork is compiled and wherever it is decoded. This one is the storage layer's own
    /// question, "how big may a row get?", and it is answered independently so that a defect
    /// in the compiler cannot write a project file that no build can open.
    public static let maximumArtworkGeometryBytes = 4 * 1024 * 1024

    /// The v8 companion for `MarkupRecord.symbol`.
    ///
    /// The same shape, and the same reasoning, as `markup_stamp`: the authority is the field
    /// on the record, and this table is its projection, so the two cannot disagree. A count
    /// mark's glyph reaches disk by the same route its geometry does, and a reader that
    /// ignores this table still reads a valid project (the ADR-0009 property).
    ///
    /// `artwork_digest` is deliberately **not** a foreign key into `stamp_artwork`: artwork
    /// outlives the marks that reference it, and a cascade would delete the picture the moment
    /// the last mark using it was undone.
    public static let markupSymbolTableStatement = """
        CREATE TABLE markup_symbol (
            markup_id TEXT PRIMARY KEY NOT NULL REFERENCES markup(id) ON DELETE CASCADE,
            artwork_digest TEXT,
            artwork_kind TEXT NOT NULL,
            built_in_glyph TEXT,
            size_points REAL NOT NULL,
            rotation_degrees REAL NOT NULL DEFAULT 0,
            source_name TEXT
        )
        """

    /// The one index v8 adds.
    public static let markupSymbolIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_markup_symbol_digest",
            sql: "CREATE INDEX idx_markup_symbol_digest ON markup_symbol(artwork_digest)",
            rationale: """
                "Is this artwork still referenced by anything?" is the question a reachability \
                sweep asks before it deletes bytes, and it must not be a full scan of every \
                mark in the project.
                """
        )
    ]

    /// `stamp_artwork` as SQLite stores it **after** the v8 columns are added.
    ///
    /// `ALTER TABLE ADD COLUMN` does not re-emit a table's definition; it edits the stored text,
    /// replacing the closing parenthesis with `, <column>)`. So the v8 spelling is the v7
    /// statement with that edit applied twice, and it is written out here rather than guessed
    /// at, because `ProjectSchemaInventory` compares this string against a real database and
    /// refuses to open one that does not match. `artworkColumnsMatchTheDeclaredV8Spelling`
    /// asserts the two against a migrated file, so a change in SQLite's rewrite fails a test
    /// rather than making every project look hostile.
    public static let stampArtworkTableStatementAfterV8 = """
        CREATE TABLE stamp_artwork (
            digest TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            data BLOB NOT NULL,
            byte_count INTEGER NOT NULL,
            source_name TEXT,
            source_page_index INTEGER,
            pixel_width INTEGER,
            pixel_height INTEGER
        , geometry_json TEXT, compiler_version INTEGER)
        """

    /// `markup_extra` as SQLite re-spells it after v10's two `ALTER TABLE ADD COLUMN`s
    /// (ADR-0012). The integrity guard runs before the migrator, so both the v5 spelling
    /// (a genuine pre-v10 project) and this one must be in the accepted set.
    /// `custom_column` as SQLite stores it after v11's `ALTER TABLE ADD COLUMN`. The schema
    /// guard accepts it beside the v1 spelling, since a project written before v11 still
    /// carries that one when the guard runs.
    public static let customColumnTableStatementAfterV11 = """
        CREATE TABLE custom_column (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            dimension_json TEXT,
            currency_code TEXT,
            formula TEXT,
            choice_values_json TEXT,
            default_value TEXT,
            sort_order INTEGER NOT NULL,
            visible INTEGER NOT NULL DEFAULT 1
        , definition_json TEXT)
        """

    // MARK: - v12 (ADR-0021 (collaboration): review threads)

    /// One entry in a markup's review thread (NL-COLLAB-01).
    ///
    /// `markup_id` carries **no foreign key**, for the reason `measurement_audit.markup_id` has
    /// none: the thread outlives the markup. `project_id` has none either, exactly as the audit's
    /// does, because a Quick PDF takeoff keeps its threads in a container database that has no
    /// `project` row until Create Project carries them into a package. Deleting a markup leaves its conversation on disk
    /// as a record of what was said about it, and an undo of the deletion finds it still there.
    ///
    /// `author_name` is signed at write time, like the audit's `actor`, and never rewritten.
    /// `retracted` is a tombstone: a withdrawn reply keeps its row. `origin` and `lamport` are
    /// reserved for the Shared Review Folder's merge (NL-COLLAB-12) and are `NULL` for a reply
    /// written on this machine.
    public static let reviewEntryTableStatement = """
        CREATE TABLE review_entry (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            markup_id TEXT NOT NULL,
            parent_entry_id TEXT,
            kind TEXT NOT NULL,
            author_id TEXT,
            author_name TEXT NOT NULL,
            body TEXT NOT NULL,
            status_from TEXT,
            status_to TEXT,
            created_at TEXT NOT NULL,
            edited_at TEXT,
            retracted INTEGER NOT NULL DEFAULT 0,
            origin TEXT,
            lamport INTEGER
        )
        """

    /// The one index v12 adds: a markup's thread, oldest first.
    public static let reviewEntryIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_review_entry_markup",
            sql: "CREATE INDEX idx_review_entry_markup ON review_entry(project_id, markup_id, created_at)",
            rationale: """
                The Comments tab reads one markup's thread in time order on every selection \
                change; without this SQLite scans every reply in the project to find them.
                """
        )
    ]

    // MARK: - v13 document set (ADR-0022)

    /// The four v13 tables.
    ///
    /// - `page_set_entry`: a page's position in the set (NL-DOCS-02 — the page's `page_index`
    ///   stays its index in its own PDF), its sheet number, title and discipline and where they
    ///   came from (NL-DOCS-05), and the display-only arrangement (NL-DOCS-07: view rotation,
    ///   exclusion from the set). Cascades with its page.
    /// - `document_set_entry`: a document's place among the drawings of a project (NL-DOCS-04).
    /// - `revision_entry`: a revision of a document, its file copied read-only under
    ///   `documents/revisions/` and hashed (NL-DOCS-11). Before v13 a dropped revision lived in
    ///   the session only and was lost on close.
    /// - `revision_sheet`: which set page each revision page is paired with, and the evidence
    ///   the pairing rests on (`label`, `position`, `manual`), so a pairing is never silent.
    public static let documentSetTableStatements: [String] = [
        """
        CREATE TABLE page_set_entry (
            page_id TEXT PRIMARY KEY NOT NULL REFERENCES page(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            sheet_number TEXT,
            sheet_title TEXT,
            discipline TEXT,
            name_source TEXT,
            view_rotation INTEGER NOT NULL DEFAULT 0,
            excluded INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE document_set_entry (
            document_id TEXT PRIMARY KEY NOT NULL REFERENCES document(id) ON DELETE CASCADE,
            sort_order INTEGER NOT NULL,
            role TEXT NOT NULL DEFAULT 'drawing'
        )
        """,
        """
        CREATE TABLE revision_entry (
            id TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            page_count INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            added_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE revision_sheet (
            revision_id TEXT NOT NULL REFERENCES revision_entry(id) ON DELETE CASCADE,
            revision_page_index INTEGER NOT NULL,
            page_id TEXT,
            evidence TEXT NOT NULL,
            PRIMARY KEY (revision_id, revision_page_index)
        )
        """
    ]

    /// v15 (NL-DOCS-16): the page's view crop, a JSON rectangle in page space, display only.
    public static let pageViewCropColumnStatement =
        "ALTER TABLE page_set_entry ADD COLUMN crop_json TEXT"

    /// `page_set_entry` as SQLite stores it after v15's `ALTER TABLE ADD COLUMN`.
    public static let pageSetEntryTableStatementAfterV15 = """
        CREATE TABLE page_set_entry (
            page_id TEXT PRIMARY KEY NOT NULL REFERENCES page(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            sheet_number TEXT,
            sheet_title TEXT,
            discipline TEXT,
            name_source TEXT,
            view_rotation INTEGER NOT NULL DEFAULT 0,
            excluded INTEGER NOT NULL DEFAULT 0
        , crop_json TEXT)
        """

    /// The one index v13 adds: a document's revisions in order.
    public static let documentSetIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_revision_entry_document",
            sql: "CREATE INDEX idx_revision_entry_document ON revision_entry(document_id, sort_order)",
            rationale: """
                Opening a project lists each document's revisions in order; without this SQLite \
                scans every revision in the project per document.
                """
        )
    ]

    static func createDocumentSetTables(_ db: Database) throws {
        for statement in documentSetTableStatements { try db.execute(sql: statement) }
        for definition in documentSetIndexDefinitions { try db.execute(sql: definition.sql) }
    }

    static func createReviewEntryTable(_ db: Database) throws {
        try db.execute(sql: reviewEntryTableStatement)
        for definition in reviewEntryIndexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    /// `markup_extra` as SQLite stores it after v17's `capture_json` column (ADR-0031).
    public static let markupExtraTableStatementAfterV17 = """
        CREATE TABLE markup_extra (
            markup_id TEXT PRIMARY KEY NOT NULL REFERENCES markup(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            parent_markup_id TEXT REFERENCES markup(id) ON DELETE CASCADE,
            count_group_id TEXT,
            caption TEXT,
            printable INTEGER NOT NULL DEFAULT 1,
            parameters_json TEXT,
            geometry_json TEXT,
            custom_values_json TEXT
        , provenance TEXT, derivation_json TEXT, capture_json TEXT)
        """

    public static let markupExtraTableStatementAfterV10 = """
        CREATE TABLE markup_extra (
            markup_id TEXT PRIMARY KEY NOT NULL REFERENCES markup(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            parent_markup_id TEXT REFERENCES markup(id) ON DELETE CASCADE,
            count_group_id TEXT,
            caption TEXT,
            printable INTEGER NOT NULL DEFAULT 1,
            parameters_json TEXT,
            geometry_json TEXT,
            custom_values_json TEXT
        , provenance TEXT, derivation_json TEXT)
        """

    static func createArtworkGeometryColumns(_ db: Database) throws {
        for statement in artworkGeometryColumnStatements {
            try db.execute(sql: statement)
        }
    }

    static func createMarkupSymbolTable(_ db: Database) throws {
        try db.execute(sql: markupSymbolTableStatement)
        for definition in markupSymbolIndexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    // MARK: - v9 (per-page scale)

    /// Which of a page's scales is **the page's own** scale.
    ///
    /// `scale_definition.page_id` has been `NOT NULL` since schema v1, so the file has always
    /// recorded which page a scale sits on. What it has never recorded is which of them a
    /// measurement on that page resolves to when it is not inside a Scale Region: a sheet can
    /// hold a page scale *and* two region scales, and they are all rows on the same page. This
    /// table is that one fact, one row per page, and it is what makes the resolution order —
    /// Scale Region, else the page's own scale, else refuse — expressible in the file rather
    /// than only in the session.
    ///
    /// `ON DELETE CASCADE` on both keys: deleting the page takes the assignment with it, and a
    /// scale that is deleted cannot leave a page pointing at a row that is gone.
    public static let pageScaleTableStatement = """
        CREATE TABLE page_scale (
            page_id TEXT PRIMARY KEY NOT NULL REFERENCES page(id) ON DELETE CASCADE,
            scale_id TEXT NOT NULL REFERENCES scale_definition(id) ON DELETE CASCADE,
            migrated INTEGER NOT NULL DEFAULT 0
        )
        """

    /// The one index v9 adds.
    public static let pageScaleIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_page_scale_scale_id",
            sql: "CREATE INDEX idx_page_scale_scale_id ON page_scale(scale_id)",
            rationale: """
                Foreign-key support, and the question the scale panel asks: which pages use \
                this scale? Without it, deleting a scale scans page_scale once per deletion \
                and "pages measuring at 1:50" is a full table scan.
                """
        )
    ]

    static func createPageScaleTable(_ db: Database) throws {
        try db.execute(sql: pageScaleTableStatement)
        for definition in pageScaleIndexDefinitions {
            try db.execute(sql: definition.sql)
        }
    }

    /// Gives every pre-v9 project the only page assignment its own bytes justify.
    ///
    /// Before v9 the session held **one** document-wide default scale, and the writer parked
    /// every scale row on the document's first page — `TakeoffArchive.write` said so in as many
    /// words. So the honest reading of an old file is *"the default scale was calibrated on the
    /// page it is recorded against, and no other page has one"*, and that is exactly what this
    /// statement writes: one row, for the page `takeoff_state.default_scale_id`'s row already
    /// names, and nothing for any other page.
    ///
    /// Two properties this deliberately has:
    ///
    /// - **It never invents a page.** Scales that are not the document default — a Scale
    ///   Region's own calibration — get no `page_scale` row. They stay reachable through
    ///   `scale_region.scale_id`, which is where they were always resolved from.
    /// - **It runs once, at migration, not at open.** A project that opened with silently
    ///   reassigned scales is the failure per-page scale exists to prevent; a project whose
    ///   assignment was decided by a migration carries the decision in the file, where the next
    ///   build reads it rather than re-deriving it. `migrated = 1` records that this row is the
    ///   upgrade's reading of an older file and not a person's calibration, so a disclosure can
    ///   say so.
    static func backfillPageScaleFromDocumentDefault(_ db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO page_scale (page_id, scale_id, migrated)
            SELECT scale_definition.page_id, scale_definition.id, 1
            FROM scale_definition
            JOIN takeoff_state ON takeoff_state.default_scale_id = scale_definition.id
            """)
    }
}
