import Foundation
import GRDB
import ZPDFContracts
import ZPDFPersistence

/// The seam between the live takeoff and spec 8.2's tables (ADR-0009).
///
/// One writer, one reader, both total over what the app can produce:
///
/// - **Write** turns ``TakeoffSession/TakeoffState`` into the schema rows — `page`,
///   `scale_definition`, `markup`, `measurement_value` — plus the v5 companions
///   (`markup_extra`, `takeoff_state`), and lands them in **one transaction**: the same
///   discipline the audit trail already keeps, so a kill mid-save leaves old-or-new,
///   never a ledger without its scale.
/// - **Read** turns the rows back into hydration inputs. Measurements are *not* read
///   back as values: the session recomputes them through the pure engine, and the
///   round-trip suite asserts the recomputed values equal the stored
///   `measurement_value` strings digit for digit.
///
/// Identity is stable across save/open: page rows keep the session's page UUIDs, and a
/// reopened document adopts the stored page ids (``adoptingStoredPageIDs(_:stored:)``)
/// so a markup's geometry references the same page identity it was saved under — which
/// is also what keeps the audit trail's `markup_id`s pointing at real markups after a
/// reopen.
public enum TakeoffArchive {

    /// What a package holds for its primary document, in contract vocabulary.
    public struct StoredTakeoff: Sendable {
        /// `page_index` → stored page id (UUID string) — for adopting stored identity.
        public let pageIDsByIndex: [Int: UUID]
        /// Stored page id → position in the set (`page_set_entry.position`, schema v13). Empty
        /// for an archive written before v13, whose pages keep their PDF order.
        public var pagePositions: [UUID: Int] = [:]
        /// Named sheets (NL-DOCS-05), keyed by stored page id; empty before v13. Install with
        /// ``TakeoffSession/restoreSheetIdentities(_:)`` after adopting the stored page ids.
        public var sheetIdentities: [PageID: SheetIdentity] = [:]
        /// Pages removed from the set (NL-DOCS-07), keyed by stored page id; empty before v13.
        /// Install with ``TakeoffSession/restoreArrangement(excluded:views:)`` after hydrating.
        public var excludedPageIDs: Set<PageID> = []
        /// Each sheet's view (NL-DOCS-07/16), keyed by stored page id.
        public var pageViews: [PageID: PageViewSettings] = [:]
        /// Every stored scale, each carrying the page it belongs to.
        public let scales: [ScaleTransform]
        /// Which scale is each page's own scale, from `page_scale`.
        ///
        /// For a project written before schema v9 this is what the v9 migration backfilled from
        /// the file's own bytes: the document-wide default scale belonged to the page it was
        /// recorded against — page one, always, because that is where the old writer parked
        /// every scale row — and to no other page. Nothing is inferred here at open time.
        public let pageScaleIDs: [PageID: ScaleID]
        /// The calibration evidence behind each hand-calibrated stored scale (ADR-0007).
        public let calibrationEvidence: [ScaleID: CalibrationEvidence]
        /// Markups in stored draw order, ready for ``TakeoffSession/hydrate(markups:scales:defaultScaleID:)``.
        public let markups: [ZPDFContracts.MarkupRecord]
        /// True when a v5+ build has saved a takeoff into this package. False means an
        /// older or empty package: nothing to hydrate, and nothing to warn about.
        public let hasSavedTakeoff: Bool
        /// Stored Scale Regions, ready for ``TakeoffSession/hydrate(markups:scales:defaultScaleID:scaleRegions:projectZones:)``.
        public let scaleRegions: [ScaleRegionDefinition]
        /// Stored Project Zones.
        public let projectZones: [ProjectZoneDefinition]
        /// The runtime ledger columns — a table import's — with their full definitions (key,
        /// precision, display unit), in the order they were added. Empty for an archive written
        /// before schema v11 or without imported columns (BH-075). Install them with
        /// ``TakeoffSession/restoreCustomColumns(_:)`` before hydrating.
        public var customColumns: [LedgerColumnDefinition] = []
        /// Identifiers of stored markups this build could not decode. They are not in
        /// ``markups`` — this build cannot measure them — but they are kept in the file by the
        /// next save, and the caller can say how many there are.
        public var unreadableMarkupIDs: [String] = []
        /// ADR-0032: the project's markup layers, empty for a package written before
        /// schema v18. Install with ``TakeoffSession/restoreMarkupLayers(_:active:)``.
        public var markupLayers: [MarkupLayer] = []
        /// ADR-0032: the layer new markups went to when the project was saved.
        public var activeMarkupLayerID: LayerID?
        /// ADR-0032: the display units the project was saved in, or `nil` before schema v18.
        public var displayUnits: DisplayUnitSelection?
        /// NL-QTY-07-UI: the project's own assembly recipes. Install with
        /// ``TakeoffSession/restoreProjectAssemblyRecipes(_:)``.
        public var projectAssemblyRecipes: ProjectAssemblyRecipes = .none
        /// The package document row this takeoff belongs to (K-03). A page with no stored id
        /// adopts ``ZPDFPersistence/StablePageIdentity/pageID(documentId:pageIndex:)`` under it,
        /// so every copy of a project names its unsaved pages alike.
        public var documentRowID: String?

        public init(
            pageIDsByIndex: [Int: UUID],
            scales: [ScaleTransform],
            pageScaleIDs: [PageID: ScaleID],
            calibrationEvidence: [ScaleID: CalibrationEvidence] = [:],
            markups: [ZPDFContracts.MarkupRecord],
            hasSavedTakeoff: Bool,
            scaleRegions: [ScaleRegionDefinition] = [],
            projectZones: [ProjectZoneDefinition] = []
        ) {
            self.pageIDsByIndex = pageIDsByIndex
            self.scales = scales
            self.pageScaleIDs = pageScaleIDs
            self.calibrationEvidence = calibrationEvidence
            self.markups = markups
            self.hasSavedTakeoff = hasSavedTakeoff
            self.scaleRegions = scaleRegions
            self.projectZones = projectZones
        }
    }

    // MARK: - Write

    /// Writes the whole takeoff into the package's database, one transaction.
    ///
    /// Replaces the document's previous takeoff rows outright: the tables mirror the
    /// session, and the session is the truth while the document is open. The audit
    /// trail is untouched — it has no foreign keys, by ADR-0007 design.
    ///
    /// `documentId` names the package document row the takeoff belongs to; `nil` is the
    /// primary drawing. A project of several drawings writes each through ``writeSet``.
    public static func write(
        _ unfolded: TakeoffSession.TakeoffState,
        into package: ProjectPackage,
        documentId explicitDocumentId: String? = nil
    ) async throws {
        let prepared = try await prepareWrite(unfolded, into: package, documentId: explicitDocumentId)
        try await package.write { db in try prepared.apply(db, nil) }
    }

    /// One drawing's save, every row built and nothing written yet (U-029).
    ///
    /// `apply` runs inside a transaction the caller opens. With `setZoneIDs` `nil` it replaces
    /// the drawing's own Project Zones, as a project of one drawing always has. With the set's
    /// zone identities it leaves `project_zone` alone: ``writeSet`` writes every drawing's share
    /// in one transaction and the set's zones once, after them all.
    struct PreparedWrite: Sendable {
        let apply: @Sendable (_ db: Database, _ setZoneIDs: Set<String>?) throws -> Void
    }

    static func prepareWrite(
        _ unfolded: TakeoffSession.TakeoffState,
        into package: ProjectPackage,
        documentId explicitDocumentId: String? = nil
    ) async throws -> PreparedWrite {
        // Sheets removed from the set (NL-DOCS-07) are written with their markups, flagged.
        let state = unfolded.foldingArrangement()
        let documentId: String
        if let explicitDocumentId {
            documentId = explicitDocumentId
        } else {
            documentId = try await primaryDocumentIdentifier(of: package)
        }
        let projectId = try await ToolPresetArchive.projectIdentifier(of: package)
        let insertCustomColumns = state.customColumns
        // ADR-0032: the layer list, active layer and units, when this state carries them.
        let layerRows = try MarkupLayerArchive.rows(of: state, project: projectId)
        let recipeRow = try ProjectAssemblyRecipeArchive.row(of: state)   // NL-QTY-07-UI
        let savedAt = PersistenceTimestamp.string(from: Date())

        // Build every row outside the transaction; fail before touching the database.
        let pageRows = state.pages.map { page in
            PageRecord(
                id: page.id.rawValue.uuidString,
                documentId: documentId,
                pageIndex: page.index,
                pageLabel: page.label.isEmpty ? nil : page.label,
                mediaX: page.boxes.media.origin.x,
                mediaY: page.boxes.media.origin.y,
                mediaWidth: page.boxes.media.size.width,
                mediaHeight: page.boxes.media.size.height,
                cropX: page.boxes.crop.origin.x,
                cropY: page.boxes.crop.origin.y,
                cropWidth: page.boxes.crop.size.width,
                cropHeight: page.boxes.crop.size.height,
                rotation: page.rotation.rawValue
            )
        }
        guard let firstPage = pageRows.first else {
            // A document with no pages has no takeoff to write; record the state row
            // only, so "saved by a v5 build" stays true.
            let stateRow = TakeoffStateRecord(documentId: documentId, defaultScaleId: nil, savedAt: savedAt)
            return PreparedWrite { db, _ in
                try db.execute(sql: "DELETE FROM page WHERE document_id = ?", arguments: [documentId])
                try stateRow.delete(db)
                try stateRow.insert(db)
            }
        }

        // A scale is written against the page it belongs to. It used to be written against the
        // *first* page whatever page it was calibrated on, and hydrated document-wide again —
        // which is how one sheet's calibration became every sheet's. A scale that somehow
        // reaches here with no page is refused rather than parked on page one; the session
        // cannot produce one, and a save is the wrong place to invent an answer.
        let scaleRows = try state.scales.map { scale -> ScaleDefinitionRecord in
            guard let page = scale.pageID else {
                throw ZPDFPersistenceError.packageMalformed(
                    reason: "scale \(scale.id.rawValue) names no page and cannot be written"
                )
            }
            let declared = state.pages.first { $0.id == page }?.userUnit ?? 1
            return try scaleRecord(
                from: scale,
                pageId: page.rawValue.uuidString,
                savedAt: savedAt,
                evidence: state.calibrationEvidence[scale.id],
                userUnit: (declared.isFinite && declared > 0) ? declared : 1
            )
        }
        // The page->scale assignment: which of a page's scales is the page's own.
        let pageScaleRows = state.pageScaleIDs
            .map { PageScaleRecord(pageId: $0.key.rawValue.uuidString, scaleId: $0.value.rawValue.uuidString) }
            .sorted { $0.pageId < $1.pageId }

        var markupRows: [ZPDFPersistence.MarkupRecord] = []
        var valueRows: [MeasurementValueRecord] = []
        var extraRows: [MarkupExtraRecord] = []
        var stampRows: [MarkupStampRecord] = []
        var symbolRows: [MarkupSymbolRecord] = []
        markupRows.reserveCapacity(state.markups.count)
        for (order, record) in state.markups.enumerated() {
            let encoded = try TakeoffGeometryCodec.encode(record.geometry)
            markupRows.append(ZPDFPersistence.MarkupRecord(
                id: record.id.rawValue.uuidString,
                documentId: documentId,
                pageId: record.pageID.rawValue.uuidString,
                type: record.tool?.rawValue ?? record.kind.rawValue,
                subject: record.subject,
                label: record.label.isEmpty ? nil : record.label,
                comment: record.comment.isEmpty ? nil : record.comment,
                geometryBlob: encoded.blob,
                styleBlob: try TakeoffStyleCodec.encode(record),  // ADR-0029: style + group/link
                scaleId: record.scaleID?.rawValue.uuidString,
                scaleVersion: record.scaleVersion,
                scaleRegionId: record.scaleRegionID?.rawValue.uuidString,
                zoneId: record.zoneID?.rawValue.uuidString,
                layerName: nil,
                status: record.status == .none ? nil : record.status.rawValue,
                author: record.author.isEmpty ? nil : record.author,
                locked: record.locked,
                hidden: record.hidden,
                createdAt: PersistenceTimestamp.string(from: record.createdAt),
                modifiedAt: PersistenceTimestamp.string(from: record.modifiedAt),
                revision: 1
            ))
            if let valueRow = try measurementValueRecord(of: record) {
                valueRows.append(valueRow)
            }
            extraRows.append(MarkupExtraRecord(
                markupId: record.id.rawValue.uuidString,
                kind: record.kind.rawValue,
                sortOrder: order,
                parentMarkupId: record.parentMarkupID?.rawValue.uuidString,
                countGroupId: record.countGroupID?.rawValue.uuidString,
                caption: record.caption,
                printable: record.printable,
                parametersJson: try parametersJSON(of: record.parameters),
                geometryJson: encoded.json,
                customValuesJson: try customValuesJSON(of: record.customValues),
                provenance: record.provenance == .measured ? nil : record.provenance.rawValue,
                derivationJson: try derivationJSON(of: record.derivation),
                // ADR-0031: a detector's capture, kept beside the geometry it describes.
                captureJson: try CaptureArchive.json(of: record, setAside: state.uncalibratedCaptures[record.id]),
                layerId: record.layerID?.rawValue.uuidString   // ADR-0032: NULL is the default layer
            ))
            if let stamp = record.stamp {
                stampRows.append(try stampRecord(of: stamp, markupId: record.id.rawValue.uuidString))
            }
            if let symbol = record.symbol {
                symbolRows.append(symbolRecord(of: symbol, markupId: record.id.rawValue.uuidString))
            }
        }

        // Scale Regions and Project Zones are written *before* the markups that reference
        // them: `markup.scale_region_id` and `markup.zone_id` are foreign keys, and SQLite
        // checks them at statement time inside the transaction. Written after, a takeoff with
        // one region-assigned measurement would fail the whole save.
        let regionRows = state.scaleRegions.map { $0.persistenceRow() }
        let (zoneRows, zoneExtraRows) = Self.zoneRows(of: state.projectZones, anchorPageId: firstPage.id)

        // `takeoff_state.default_scale_id` is now a **legacy** column: the resolution order
        // lives in `page_scale`. It is still written, holding the first page's own scale, so a
        // build older than schema v9 opening this package finds the same scale it always did on
        // the sheet it always found it on, rather than none at all.
        let firstPageID = state.pages.first?.id
        let stateRow = TakeoffStateRecord(
            documentId: documentId,
            defaultScaleId: firstPageID
                .flatMap { state.pageScaleIDs[$0] }?.rawValue.uuidString,
            savedAt: savedAt
        )

        let insertMarkups = markupRows
        let insertValues = valueRows
        let insertExtras = extraRows
        let insertRegions = regionRows
        let insertPageScales = pageScaleRows
        let insertZones = zoneRows
        let insertZoneExtras = zoneExtraRows
        let insertStamps = stampRows
        let insertSymbols = symbolRows
        let livePageIDs = pageRows.map(\.id)
        return PreparedWrite { db, setZoneIDs in
            // The takeoff tables are replaced; the page rows are **kept**. This used to be
            // `DELETE FROM page WHERE document_id = ?` followed by a re-insert, and
            // `ocr_token.page_id … ON DELETE CASCADE` took every recognised token with it
            // while `search_fts` kept its rows — so after the first save every OCR hit had no
            // token and no confidence, and was dropped as low-confidence (CR-121). The children
            // the cascade used to clear are cleared by name, in foreign-key order: markups
            // (and with them measurement_value, markup_extra, custom_value, markup_stamp and
            // markup_symbol), then the regions and zones that reference scales, then the
            // page→scale assignment, then the scales.
            // Rows this build could not read at open are carried through the save rather than
            // deleted with the rest (BH-097). They were never in the session, so they are not in
            // `insertMarkups`; without this a markup written by a newer build — one parameter
            // case this build lacks — was skipped at open and then erased for good, for the
            // newer build too, by the very next save.
            let preserved = try Self.unreadableMarkupRows(
                in: db,
                documentId: documentId,
                excluding: Set(insertMarkups.map(\.id)),
                alsoKeeping: Set(state.heldMarkupIDs)
            )
            // Markup rows are written incrementally (IM-054): the structure below is still
            // replaced, but a markup whose rows are byte-identical to what the file holds is
            // left alone, so a one-markup edit on a 5 000-markup takeoff writes one markup's
            // rows instead of deleting and re-inserting all of them — the WAL, the database
            // copy streamed into the staging package and the version clone's divergent blocks
            // all shrink with it. Foreign keys are checked at commit rather than per statement
            // for this transaction only, because kept markups keep naming the scale, region and
            // zone rows that are deleted and re-inserted under the same identities just below.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try db.execute(
                sql: "DELETE FROM scale_region WHERE page_id IN (SELECT id FROM page WHERE document_id = ?)",
                arguments: [documentId]
            )
            // A drawing of a set leaves its zones to `writeSet`, which writes the set's once (U-029).
            if setZoneIDs == nil {
                try db.execute(
                    sql: "DELETE FROM project_zone WHERE page_id IN (SELECT id FROM page WHERE document_id = ?)",
                    arguments: [documentId]
                )
            }
            try db.execute(
                sql: "DELETE FROM page_scale WHERE page_id IN (SELECT id FROM page WHERE document_id = ?)",
                arguments: [documentId]
            )
            try db.execute(
                sql: "DELETE FROM scale_definition WHERE page_id IN (SELECT id FROM page WHERE document_id = ?)",
                arguments: [documentId]
            )
            try db.execute(sql: "DELETE FROM takeoff_state WHERE document_id = ?", arguments: [documentId])
            // Only a page that left the document goes — and its tokens with it, which is right.
            // A page a carried-through markup still stands on stays, or the cascade would erase
            // the very row that was carried through.
            let keptPageIDs = livePageIDs + Set(preserved.map(\.pageId))
                .subtracting(livePageIDs).sorted()
            let placeholders = Array(repeating: "?", count: keptPageIDs.count).joined(separator: ", ")
            try db.execute(
                sql: "DELETE FROM page WHERE document_id = ? AND id NOT IN (\(placeholders))",
                arguments: StatementArguments([documentId] + keptPageIDs)
            )
            // `UNIQUE(document_id, page_index)`: a reorder that swaps two indices would trip
            // it half-way through the updates, so every kept row is parked on a negative index
            // first. The geometry hash is the search index's, not the takeoff's; it survives.
            try db.execute(
                sql: "UPDATE page SET page_index = -(page_index + 1) WHERE document_id = ?",
                arguments: [documentId]
            )
            var geometryHashes: [String: String] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT id, geometry_hash FROM page WHERE document_id = ?", arguments: [documentId]
            ) {
                if let hash: String = row["geometry_hash"] { geometryHashes[row["id"]] = hash }
            }
            for row in pageRows {
                var kept = row
                kept.geometryHash = geometryHashes[row.id]
                try kept.save(db)
            }
            // The set order (ADR-0022): `page_index` is the page's index in its own PDF and
            // never moves; the position in the set is the page's place in `state.pages`.
            // Upserted, so the sheet identity the entry also carries is left as it is.
            // The sheet identity (NL-DOCS-05) is the session's, written with it; view rotation
            // and exclusion are left as they are.
            for (offset, row) in pageRows.enumerated() {
                let pageID = UUID(uuidString: row.id).map(PageID.init)
                let identity = pageID.flatMap { state.sheetIdentities[$0] }
                // The set-wide position when several drawings share one set (NL-DOCS-04).
                let position = pageID.flatMap { state.setPositions[$0] } ?? offset
                // The arrangement (NL-DOCS-07/16): view rotation, crop and removal from the set.
                let view = pageID.flatMap { state.pageViews[$0] } ?? PageViewSettings()
                let removed = pageID.map { state.excludedPageIDs.contains($0) } ?? false
                try db.execute(
                    sql: """
                        INSERT INTO page_set_entry (page_id, position, sheet_number, sheet_title, discipline, name_source,
                            view_rotation, excluded, crop_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(page_id) DO UPDATE SET position = excluded.position,
                            sheet_number = excluded.sheet_number, sheet_title = excluded.sheet_title,
                            discipline = excluded.discipline, name_source = excluded.name_source,
                            view_rotation = excluded.view_rotation, excluded = excluded.excluded,
                            crop_json = excluded.crop_json
                        """,
                    arguments: [
                        row.id, position, identity?.number, identity?.title,
                        identity?.discipline, identity?.source.rawValue,
                        view.rotation, removed, view.cropJSON
                    ]
                )
            }
            for row in scaleRows { try row.insert(db) }
            // After the scales: `page_scale.scale_id` is a foreign key, checked at statement
            // time inside the transaction.
            for row in insertPageScales { try row.insert(db) }
            for row in insertRegions { try row.insert(db) }
            if setZoneIDs == nil {
                for row in insertZones { try row.insert(db) }
                for row in insertZoneExtras { try row.insert(db) }
            }
            // The artwork rows are not written here — they are content-addressed and shared,
            // so they are inserted once when the artwork is imported. `markup_symbol` is the
            // *projection* of `MarkupRecord.symbol` and never its authority (ADR-0011 §2.3), so
            // it is rewritten with the markup it belongs to and never holds a symbol the record
            // does not.
            try Self.writeMarkupsIncrementally(
                MarkupRows(
                    markups: insertMarkups,
                    values: insertValues,
                    extras: insertExtras,
                    stamps: insertStamps,
                    symbols: insertSymbols
                ),
                documentId: documentId,
                keeping: Set(preserved.map(\.id)),
                in: db
            )
            try Self.clearDanglingReferences(
                ofKept: preserved.map(\.id),
                scaleIDs: Set(scaleRows.map(\.id)),
                regionIDs: Set(insertRegions.map(\.id)),
                zoneIDs: setZoneIDs ?? Set(insertZones.map(\.id)),
                in: db
            )
            try stateRow.insert(db)
            try Self.writeCustomColumns(insertCustomColumns, project: projectId, in: db)
            try MarkupLayerArchive.write(layerRows, project: projectId, in: db)   // ADR-0032
            try ProjectAssemblyRecipeArchive.write(recipeRow, project: projectId, in: db)   // NL-QTY-07-UI
        }
    }

    /// Writes the session's runtime ledger columns into `custom_column` with their complete
    /// definition (schema v11, BH-075), and removes the ones this writer wrote earlier that the
    /// session no longer has — an import that was undone. A column row without a definition was
    /// not written here and is left alone.
    static func writeCustomColumns(
        _ definitions: [LedgerColumnDefinition],
        project projectId: String,
        in db: Database
    ) throws {
        let columns = definitions.enumerated().map { order, definition in
            CustomColumnStore.Column(
                id: definition.id.rawValue.uuidString,
                name: definition.title,
                type: definition.kind.rawValue,
                sortOrder: order,
                visible: definition.isVisible,
                definition: definition
            )
        }
        let live = Set(columns.map(\.id))
        let stale = try CustomColumnStore.columns(project: projectId, as: LedgerColumnDefinition.self, in: db)
            .filter { $0.definition != nil && !live.contains($0.id) }
            .map(\.id)
        try CustomColumnStore.remove(ids: stale, project: projectId, in: db)
        try CustomColumnStore.upsert(columns, project: projectId, in: db)
    }

    /// Every row a save writes for the markups, grouped for the incremental writer.
    struct MarkupRows {
        let markups: [ZPDFPersistence.MarkupRecord]
        let values: [MeasurementValueRecord]
        let extras: [MarkupExtraRecord]
        let stamps: [MarkupStampRecord]
        let symbols: [MarkupSymbolRecord]
    }

    /// Writes the markup rows that differ from what the file holds, and deletes the markups
    /// the session no longer has (IM-054).
    ///
    /// A markup is left untouched when its `markup` row and every child row — measurement
    /// values, extra, stamp, symbol — equal the stored ones. A changed markup's own row is
    /// *updated*, never deleted and re-inserted: `markup_extra.parent_markup_id` cascades, so
    /// deleting a parent to rewrite it would take its unchanged cutouts' extra rows with it.
    /// Its child rows are replaced. The result is the same database a full rewrite produces;
    /// the round-trip tests assert it.
    static func writeMarkupsIncrementally(
        _ rows: MarkupRows,
        documentId: String,
        keeping preserved: Set<String>,
        in db: Database
    ) throws {
        let scope = "SELECT id FROM markup WHERE document_id = ?"
        let arguments: StatementArguments = [documentId]
        let storedMarkups = Dictionary(
            try ZPDFPersistence.MarkupRecord.fetchAll(db, sql: "SELECT * FROM markup WHERE document_id = ?", arguments: arguments)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func stored<R: FetchableRecord & Hashable>(_ type: R.Type, _ table: String, key: (R) -> String) throws -> [String: [R]] {
            Dictionary(grouping: try R.fetchAll(
                db, sql: "SELECT * FROM \(table) WHERE markup_id IN (\(scope))", arguments: arguments
            ), by: key)
        }
        let storedValues = try stored(MeasurementValueRecord.self, "measurement_value") { $0.markupId }
        let storedExtras = try stored(MarkupExtraRecord.self, "markup_extra") { $0.markupId }
        let storedStamps = try stored(MarkupStampRecord.self, "markup_stamp") { $0.markupId }
        let storedSymbols = try stored(MarkupSymbolRecord.self, "markup_symbol") { $0.markupId }
        let newValues = Dictionary(grouping: rows.values, by: \.markupId)
        let newExtras = Dictionary(grouping: rows.extras, by: \.markupId)
        let newStamps = Dictionary(grouping: rows.stamps, by: \.markupId)
        let newSymbols = Dictionary(grouping: rows.symbols, by: \.markupId)

        // `custom_value` is not a projection this writer owns; a full rewrite cleared it
        // through the markup cascade on every save, and so does this.
        try db.execute(sql: "DELETE FROM custom_value WHERE markup_id IN (\(scope))", arguments: arguments)

        let live = Set(rows.markups.map(\.id))
        for id in storedMarkups.keys where !live.contains(id) && !preserved.contains(id) {
            try db.execute(sql: "DELETE FROM markup WHERE id = ?", arguments: [id])
        }
        for markup in rows.markups {
            let id = markup.id
            let unchanged = storedMarkups[id] == markup
                && (storedValues[id] ?? []) == (newValues[id] ?? [])
                && (storedExtras[id] ?? []) == (newExtras[id] ?? [])
                && (storedStamps[id] ?? []) == (newStamps[id] ?? [])
                && (storedSymbols[id] ?? []) == (newSymbols[id] ?? [])
            guard !unchanged else { continue }
            if storedMarkups[id] != nil {
                try markup.update(db)
                for table in ["measurement_value", "markup_extra", "markup_stamp", "markup_symbol"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE markup_id = ?", arguments: [id])
                }
            } else {
                try markup.insert(db)
            }
            for row in newValues[id] ?? [] { try row.insert(db) }
            for row in newExtras[id] ?? [] { try row.insert(db) }
            for row in newStamps[id] ?? [] { try row.insert(db) }
            for row in newSymbols[id] ?? [] { try row.insert(db) }
        }
    }

    /// Clears the references a kept, undecodable markup holds to a scale, region or zone the
    /// save removed, so the deferred foreign keys hold at commit.
    static func clearDanglingReferences(
        ofKept ids: [String],
        scaleIDs: Set<String>,
        regionIDs: Set<String>,
        zoneIDs: Set<String>,
        in db: Database
    ) throws {
        for id in ids {
            guard let row = try Row.fetchOne(
                db, sql: "SELECT scale_id, scale_region_id, zone_id FROM markup WHERE id = ?", arguments: [id]
            ) else { continue }
            if let scale: String = row["scale_id"], !scaleIDs.contains(scale) {
                try db.execute(sql: "UPDATE markup SET scale_id = NULL WHERE id = ?", arguments: [id])
            }
            if let region: String = row["scale_region_id"], !regionIDs.contains(region) {
                try db.execute(sql: "UPDATE markup SET scale_region_id = NULL WHERE id = ?", arguments: [id])
            }
            if let zone: String = row["zone_id"], !zoneIDs.contains(zone) {
                try db.execute(sql: "UPDATE markup SET zone_id = NULL WHERE id = ?", arguments: [id])
            }
        }
    }

    /// One stored markup the save carries through untouched: which row, on which page. Its rows
    /// stay in the file as they are — nothing copies them — so nothing more is read (S-041: the
    /// row and every child row used to be fetched into a field no code read).
    struct PreservedMarkupRows {
        let id: String
        let pageId: String
    }

    /// The stored markups of a document that the session does not hold **and** that this
    /// build cannot decode — the rows `read` skipped. A row that decodes and is not in the
    /// session was deleted by the person, and is deleted.
    ///
    /// `alsoKeeping` names rows the session refused at hydration although they decode — a
    /// markup on a page this drawing no longer has. They are
    /// carried through like the undecodable ones instead of being deleted as if the person had.
    static func unreadableMarkupRows(
        in db: Database,
        documentId: String,
        excluding written: Set<String>,
        alsoKeeping held: Set<String> = []
    ) throws -> [PreservedMarkupRows] {
        let candidates = try ZPDFPersistence.MarkupRecord.fetchAll(
            db, sql: "SELECT * FROM markup WHERE document_id = ?", arguments: [documentId]
        ).filter { !written.contains($0.id) }
        guard !candidates.isEmpty else { return [] }
        var preserved: [PreservedMarkupRows] = []
        for candidate in candidates {
            let extra = try? MarkupExtraRecord.fetchOne(db, key: candidate.id)
            let stamp = try? MarkupStampRecord.fetchOne(db, key: candidate.id)
            let symbol = try? MarkupSymbolRecord.fetchOne(db, key: candidate.id)
            let decodes = (try? markupRecord(
                from: candidate, extra: extra ?? nil, cutouts: [], stamp: stamp ?? nil, symbol: symbol ?? nil
            )) != nil
            guard !decodes || held.contains(candidate.id) else { continue }
            preserved.append(PreservedMarkupRows(id: candidate.id, pageId: candidate.pageId))
        }
        return preserved
    }


    /// The `project_zone` and `project_zone_extra` rows for `zones`, the extras parents first so
    /// `project_zone_extra.parent_zone_id` never names a row that has not been inserted yet.
    ///
    /// A zone with no drawn boundary belongs to no page, but `project_zone.page_id` is NOT NULL.
    /// Such a zone is anchored to `anchorPageId` with an empty polygon and the v6 companion's
    /// `spans_pages` flag; the flag is what stops a reopen from claiming the zone lives on a page
    /// nobody put it on.
    static func zoneRows(
        of zones: [ProjectZoneDefinition],
        anchorPageId: String
    ) -> (zones: [ProjectZoneRecord], extras: [ProjectZoneExtraRecord]) {
        var zoneRows: [ProjectZoneRecord] = []
        var zoneExtraRows: [ProjectZoneExtraRecord] = []
        for (order, zone) in zones.enumerated() {
            zoneRows.append(zone.persistenceRow(sortOrder: order, anchorPageId: anchorPageId))
            zoneExtraRows.append(zone.persistenceExtraRow())
        }
        let unsortedZoneExtras = zoneExtraRows
        zoneExtraRows.sort { left, right in
            let leftDepth = zoneDepth(of: left.zoneId, in: unsortedZoneExtras)
            let rightDepth = zoneDepth(of: right.zoneId, in: unsortedZoneExtras)
            return leftDepth == rightDepth ? left.zoneId < right.zoneId : leftDepth < rightDepth
        }
        return (zoneRows, zoneExtraRows)
    }

    /// How deep a zone sits in the nesting tree, so parents are inserted before children.
    /// A cycle — which the panel's own guard makes unreachable — is bounded rather than
    /// looped forever.
    private static func zoneDepth(of zoneId: String, in extras: [ProjectZoneExtraRecord]) -> Int {
        var depth = 0
        var current = extras.first { $0.zoneId == zoneId }?.parentZoneId
        var remaining = extras.count
        while let parent = current, remaining > 0 {
            depth += 1
            remaining -= 1
            current = extras.first { $0.zoneId == parent }?.parentZoneId
        }
        return depth
    }



    // MARK: - Read

    /// Reads the stored takeoff of the package's primary document, or `nil` when the
    /// package predates v5 saves (no `takeoff_state` row and no markups).
    ///
    /// `documentId` names another drawing of a multi-drawing project (NL-DOCS-04); `nil` is the
    /// primary drawing.
    public static func read(
        from package: ProjectPackage,
        documentId explicitDocumentId: String? = nil
    ) async throws -> StoredTakeoff? {
        let documentId: String
        if let explicitDocumentId {
            documentId = explicitDocumentId
        } else {
            documentId = try await primaryDocumentIdentifier(of: package)
        }
        let raw = try await package.read { db -> RawRows in
            RawRows(
                state: try TakeoffStateRecord.fetchOne(db, key: documentId),
                pages: try PageRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM page WHERE document_id = ? ORDER BY page_index",
                    arguments: [documentId]
                ),
                scales: try ScaleDefinitionRecord.fetchAll(
                    db,
                    sql: """
                        SELECT scale_definition.* FROM scale_definition
                        JOIN page ON page.id = scale_definition.page_id
                        WHERE page.document_id = ?
                        ORDER BY scale_definition.created_at, scale_definition.id
                        """,
                    arguments: [documentId]
                ),
                markups: try MarkupRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM markup WHERE document_id = ?",
                    arguments: [documentId]
                ),
                extras: try MarkupExtraRecord.fetchAll(
                    db,
                    sql: """
                        SELECT markup_extra.* FROM markup_extra
                        JOIN markup ON markup.id = markup_extra.markup_id
                        WHERE markup.document_id = ?
                        """,
                    arguments: [documentId]
                ),
                pageScales: try PageScaleRecord.fetchAll(
                    db,
                    sql: """
                        SELECT page_scale.* FROM page_scale
                        JOIN page ON page.id = page_scale.page_id
                        WHERE page.document_id = ?
                        ORDER BY page.page_index
                        """,
                    arguments: [documentId]
                ),
                regions: try ScaleRegionRecord.fetchAll(
                    db,
                    sql: """
                        SELECT scale_region.* FROM scale_region
                        JOIN page ON page.id = scale_region.page_id
                        WHERE page.document_id = ?
                        ORDER BY scale_region.priority DESC, scale_region.name
                        """,
                    arguments: [documentId]
                ),
                zones: try ProjectZoneRecord.fetchAll(
                    db,
                    sql: """
                        SELECT project_zone.* FROM project_zone
                        JOIN page ON page.id = project_zone.page_id
                        WHERE page.document_id = ?
                        ORDER BY project_zone.sort_order, project_zone.id
                        """,
                    arguments: [documentId]
                ),
                zoneExtras: try ProjectZoneExtraRecord.fetchAll(
                    db,
                    sql: """
                        SELECT project_zone_extra.* FROM project_zone_extra
                        JOIN project_zone ON project_zone.id = project_zone_extra.zone_id
                        JOIN page ON page.id = project_zone.page_id
                        WHERE page.document_id = ?
                        """,
                    arguments: [documentId]
                ),
                stamps: try MarkupStampRecord.fetchAll(
                    db,
                    sql: """
                        SELECT markup_stamp.* FROM markup_stamp
                        JOIN markup ON markup.id = markup_stamp.markup_id
                        WHERE markup.document_id = ?
                        """,
                    arguments: [documentId]
                ),
                symbols: try MarkupSymbolRecord.fetchAll(
                    db,
                    sql: """
                        SELECT markup_symbol.* FROM markup_symbol
                        JOIN markup ON markup.id = markup_symbol.markup_id
                        WHERE markup.document_id = ?
                        """,
                    arguments: [documentId]
                )
            )
        }
        guard raw.state != nil || !raw.markups.isEmpty else { return nil }

        var pageIDsByIndex: [Int: UUID] = [:]
        for page in raw.pages {
            guard let id = UUID(uuidString: page.id) else { continue }
            pageIDsByIndex[page.pageIndex] = id
        }

        // The page a scale belongs to comes off the row it has always been stored on
        // (`scale_definition.page_id`, NOT NULL since schema v1). The reader used to drop it;
        // reading it is what turns the pre-v9 file's own bytes into the page-1-only assignment
        // rather than a guess made at open time.
        let scales = raw.scales.compactMap { try? scaleTransform(from: $0) }
        var storedEvidence: [ScaleID: CalibrationEvidence] = [:]
        for row in raw.scales {
            guard let uuid = UUID(uuidString: row.id),
                  let evidence = calibrationEvidence(from: row) else { continue }
            storedEvidence[ScaleID(uuid)] = evidence
        }
        var pageScaleIDs: [PageID: ScaleID] = [:]
        let heldByID = Dictionary(scales.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in raw.pageScales {
            guard let pageUUID = UUID(uuidString: row.pageId),
                  let scaleUUID = UUID(uuidString: row.scaleId) else { continue }
            let page = PageID(pageUUID)
            let scaleID = ScaleID(scaleUUID)
            // A row whose scale is missing, or whose scale belongs to a different page, is
            // dropped: the page reopens uncalibrated and says so, which is the one honest
            // outcome. Adopting it anyway would be the silent reassignment this exists to stop.
            guard heldByID[scaleID]?.pageID == page else { continue }
            pageScaleIDs[page] = scaleID
        }

        let extrasByMarkup = Dictionary(uniqueKeysWithValues: raw.extras.map { ($0.markupId, $0) })
        let stampsByMarkup = Dictionary(
            raw.stamps.map { ($0.markupId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let symbolsByMarkup = Dictionary(
            raw.symbols.map { ($0.markupId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let ordered = raw.markups.sorted { left, right in
            let lo = extrasByMarkup[left.id]?.sortOrder ?? Int.max
            let ro = extrasByMarkup[right.id]?.sortOrder ?? Int.max
            return lo == ro ? left.id < right.id : lo < ro
        }

        // Cutout children per parent, in stored draw order.
        var cutoutsByParent: [String: [MarkupID]] = [:]
        for row in ordered {
            guard let extra = extrasByMarkup[row.id],
                  let parent = extra.parentMarkupId,
                  let childUUID = UUID(uuidString: row.id) else { continue }
            cutoutsByParent[parent, default: []].append(MarkupID(childUUID))
        }

        var records: [ZPDFContracts.MarkupRecord] = []
        var unreadable: [String] = []
        records.reserveCapacity(ordered.count)
        for row in ordered {
            guard let record = try? markupRecord(
                from: row,
                extra: extrasByMarkup[row.id],
                cutouts: cutoutsByParent[row.id] ?? [],
                stamp: stampsByMarkup[row.id],
                symbol: symbolsByMarkup[row.id]
            ) else {
                // Said, not skipped in silence: the caller can tell the person the ledger opened
                // short, and `write` keeps the row in the file (BH-097).
                unreadable.append(row.id)
                continue
            }
            // NL-COLLAB-18: a text box from an earlier build carries its words in `comment`;
            // they move to `caption` once, and the note starts empty.
            records.append(MarkupVisibleText.migratingLegacy(record))
        }

        let heldScaleIDs = Set(scales.map(\.id))
        let regions: [ScaleRegionDefinition] = raw.regions.compactMap { row -> ScaleRegionDefinition? in
            guard let region = ScaleRegionDefinition(persistenceRow: row) else { return nil }
            // A region naming a scale the document no longer holds is dropped rather than
            // shown against a scale nobody defined. The command path cannot produce one.
            return heldScaleIDs.contains(region.scaleID) ? region : nil
        }

        let zoneExtrasByID = Dictionary(uniqueKeysWithValues: raw.zoneExtras.map { ($0.zoneId, $0) })
        let zones: [ProjectZoneDefinition] = raw.zones.compactMap { row -> ProjectZoneDefinition? in
            ProjectZoneDefinition(persistenceRow: row, extra: zoneExtrasByID[row.id])
        }

        var stored = StoredTakeoff(
            pageIDsByIndex: pageIDsByIndex,
            scales: scales,
            pageScaleIDs: pageScaleIDs,
            calibrationEvidence: storedEvidence,
            markups: records,
            hasSavedTakeoff: raw.state != nil,
            scaleRegions: regions,
            projectZones: zones
        )
        stored.unreadableMarkupIDs = unreadable
        // Additive: an archive written before schema v11 has no definitions and loads as before.
        let projectId = try await ToolPresetArchive.projectIdentifier(of: package)
        stored.customColumns = try await package.read { db in
            try CustomColumnStore.columns(project: projectId, as: LedgerColumnDefinition.self, in: db)
                .compactMap(\.definition)
        }
        // ADR-0032: project-level layers, active layer and units; empty before schema v18.
        let layerFacts = try await package.read { db in try MarkupLayerArchive.read(project: projectId, in: db) }
        stored.markupLayers = layerFacts.layers
        stored.activeMarkupLayerID = layerFacts.activeLayerID
        stored.displayUnits = layerFacts.displayUnits
        stored.projectAssemblyRecipes = try await package.read { db in
            try ProjectAssemblyRecipeArchive.read(project: projectId, in: db)   // NL-QTY-07-UI
        }
        stored.documentRowID = documentId
        // Additive: an archive written before schema v13 has no set entries and keeps its PDF
        // order (ADR-0022).
        let entries = try await package.read { db in
            try DocumentSetStore.pageEntries(document: documentId, in: db)
        }
        for (id, entry) in entries {
            guard let uuid = UUID(uuidString: id) else { continue }
            stored.pagePositions[uuid] = entry.position
            // The arrangement (NL-DOCS-07/16).
            if entry.excluded { stored.excludedPageIDs.insert(PageID(uuid)) }
            let view = PageViewSettings(
                rotation: entry.viewRotation,
                crop: PageViewSettings.crop(fromJSON: entry.cropJSON)
            )
            if !view.isIdentity { stored.pageViews[PageID(uuid)] = view }
            if entry.sheetNumber != nil || entry.sheetTitle != nil {
                let identity = SheetIdentity(
                    number: entry.sheetNumber,
                    title: entry.sheetTitle,
                    discipline: entry.discipline,
                    source: entry.nameSource.flatMap(SheetNameSource.init(rawValue:)) ?? .manual
                )
                if !identity.isEmpty { stored.sheetIdentities[PageID(uuid)] = identity }
            }
        }
        return stored
    }

    /// The takeoff of a project that has never been saved (K-03): nothing to hydrate, but it
    /// names the primary document row, so ``adoptingStoredPageIDs(_:stored:)`` gives the fresh
    /// pages the identities every copy of the project derives alike. Read it when
    /// ``read(from:documentId:)`` answers `nil`.
    public static func unsavedTakeoff(of package: ProjectPackage) async throws -> StoredTakeoff {
        var stored = StoredTakeoff(
            pageIDsByIndex: [:], scales: [], pageScaleIDs: [:], markups: [], hasSavedTakeoff: false
        )
        stored.documentRowID = try await primaryDocumentIdentifier(of: package)
        return stored
    }

    /// Replaces freshly minted page ids with the stored ones, matched by page index, so
    /// a reopened document keeps the identity its markups were saved under.
    ///
    /// A page the package has no row for yet takes the stable id of its document row and
    /// index (K-03). A freshly minted random id used to stand, so two copies of a project that
    /// was never saved named the same sheet differently, and markups from one landed on a page
    /// the other did not have.
    public static func adoptingStoredPageIDs(
        _ pages: [ZPDFContracts.PageDescriptor],
        stored: StoredTakeoff
    ) -> [ZPDFContracts.PageDescriptor] {
        let adopted = pages.map { page in
            var adopted = page
            if let storedID = stored.pageIDsByIndex[page.index] {
                adopted.id = PageID(storedID)
            } else if let row = stored.documentRowID {
                adopted.id = PageID(StablePageIdentity.pageID(documentId: row, pageIndex: page.index))
            }
            return adopted
        }
        // The stored set order (ADR-0022, NL-DOCS-02). Stable: a page without a stored
        // position keeps its place relative to the others, after the positioned ones.
        guard !stored.pagePositions.isEmpty else { return adopted }
        return adopted.enumerated().sorted { lhs, rhs in
            let l = stored.pagePositions[lhs.element.id.rawValue] ?? Int.max
            let r = stored.pagePositions[rhs.element.id.rawValue] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Row codecs

    private struct RawRows: Sendable {
        let state: TakeoffStateRecord?
        let pages: [PageRecord]
        let scales: [ScaleDefinitionRecord]
        let markups: [ZPDFPersistence.MarkupRecord]
        let extras: [MarkupExtraRecord]
        let pageScales: [PageScaleRecord]
        let regions: [ScaleRegionRecord]
        let zones: [ProjectZoneRecord]
        let zoneExtras: [ProjectZoneExtraRecord]
        let stamps: [MarkupStampRecord]
        let symbols: [MarkupSymbolRecord]
    }

    /// The package's first document row — the drawing the takeoff belongs to.
    static func primaryDocumentIdentifier(of package: ProjectPackage) async throws -> String {
        guard let id = try await package.read({ db in
            try String.fetchOne(db, sql: "SELECT id FROM document ORDER BY created_at, id LIMIT 1")
        }) else {
            throw ZPDFPersistenceError.packageMalformed(reason: "the package has no document row")
        }
        return id
    }

    /// `calibration_json`: the scale facts the fixed columns cannot carry.
    ///
    /// `evidence` is optional and was added with per-page scale: the column has always been
    /// called `calibration_json` and has never carried the calibration. Without it a reopened
    /// project could still say *"1:50, calibrated on page 3"* — the ratio and the page are on
    /// the row — but not *which two points* were picked, so the derivation lost half of ADR-0007
    /// §1's evidence at the first save. Absent for a preset or inherited scale, and absent in
    /// every project written before this build, where it decodes as `nil`.
    private struct ScaleSidecar: Codable {
        var unitPolicy: ScaleUnitPolicy
        var label: String?
        var evidence: CalibrationEvidence?
    }

    static func scaleRecord(
        from scale: ScaleTransform,
        pageId: String,
        savedAt: String,
        evidence: CalibrationEvidence? = nil,
        userUnit: Double = 1
    ) throws -> ScaleDefinitionRecord {
        func decimal(_ value: Decimal, _ field: String) throws -> ZPDFPersistence.DecimalString {
            guard let text = ZPDFPersistence.DecimalString(value) else {
                throw ZPDFPersistenceError.malformedDecimalString("\(field): \(value)")
            }
            return text
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sidecar = String(
            decoding: try encoder.encode(
                ScaleSidecar(unitPolicy: scale.units, label: scale.label, evidence: evidence)
            ),
            as: UTF8.self
        )
        return ScaleDefinitionRecord(
            id: scale.id.rawValue.uuidString,
            pageId: pageId,
            // The page's `/UserUnit`, so the stored name is the ratio the sheet is drawn at
            // rather than 1:200 for a 1:100 scale on a `/UserUnit 2` page (BH-092).
            name: scale.label ?? ScaleBridge.ratioText(for: scale, userUnit: userUnit),
            matrixA: try decimal(scale.matrix.a, "matrix_a"),
            matrixB: try decimal(scale.matrix.b, "matrix_b"),
            matrixC: try decimal(scale.matrix.c, "matrix_c"),
            matrixD: try decimal(scale.matrix.d, "matrix_d"),
            translationX: try decimal(scale.matrix.tx, "translation_x"),
            translationY: try decimal(scale.matrix.ty, "translation_y"),
            baseLengthUnit: scale.units.length.rawValue,
            sourceType: scale.source.rawValue,
            calibrationJson: sidecar,
            precisionMode: precisionText(scale.units.precision),
            version: scale.version,
            locked: false,
            createdAt: savedAt,
            modifiedAt: savedAt
        )
    }

    /// The calibration evidence stored in a scale row's sidecar, when it has any.
    static func calibrationEvidence(from record: ScaleDefinitionRecord) -> CalibrationEvidence? {
        guard let json = record.calibrationJson else { return nil }
        return try? JSONDecoder().decode(ScaleSidecar.self, from: Data(json.utf8)).evidence
    }

    static func scaleTransform(from record: ScaleDefinitionRecord) throws -> ScaleTransform {
        guard let id = UUID(uuidString: record.id) else {
            throw ZPDFPersistenceError.packageMalformed(reason: "scale_definition.id is not a UUID: \(record.id)")
        }
        let matrix = AffineScaleMatrix(
            a: record.matrixA.value,
            b: record.matrixB.value,
            c: record.matrixC.value,
            d: record.matrixD.value,
            tx: record.translationX.value,
            ty: record.translationY.value
        )
        var units: ScaleUnitPolicy
        var label: String?
        if let json = record.calibrationJson,
           let sidecar = try? JSONDecoder().decode(ScaleSidecar.self, from: Data(json.utf8)) {
            units = sidecar.unitPolicy
            label = sidecar.label
        } else {
            // A foreign writer that filled only the fixed columns: derive what they hold.
            units = .metric
            if let length = LengthUnit(rawValue: record.baseLengthUnit) {
                units = ScaleUnitPolicy(
                    length: length, area: units.area, volume: units.volume,
                    angle: units.angle, precision: precision(fromText: record.precisionMode)
                )
            }
            label = record.name.isEmpty ? nil : record.name
        }
        return ScaleTransform(
            id: ScaleID(id),
            pageID: UUID(uuidString: record.pageId).map(PageID.init),
            version: record.version,
            matrix: matrix,
            units: units,
            source: ScaleSource(rawValue: record.sourceType) ?? .inherited,
            label: label
        )
    }

    /// `precision_mode` as text: `decimalPlaces:3` / `imperialFraction:16`.
    static func precisionText(_ mode: PrecisionMode) -> String {
        switch mode {
        case .decimalPlaces(let places): "decimalPlaces:\(places)"
        case .imperialFraction(let denominator): "imperialFraction:\(denominator.rawValue)"
        }
    }

    static func precision(fromText text: String) -> PrecisionMode {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let number = Int(parts[1]) else { return .defaultMetric }
        switch parts[0] {
        case "decimalPlaces": return .decimalPlaces(min(max(number, 0), 12))
        case "imperialFraction":
            return ImperialFractionDenominator(rawValue: number).map(PrecisionMode.imperialFraction)
                ?? .defaultImperial
        default: return .defaultMetric
        }
    }

    /// The 17 spec columns of `measurement_value`, from a result's values map. Fields the
    /// spec has no column for (netArea, truePerimeter, …) are recomputed on hydration —
    /// stored values are the cross-check, never the only copy of a number the spec names.
    static func measurementValueRecord(of record: ZPDFContracts.MarkupRecord) throws -> MeasurementValueRecord? {
        guard let measurement = record.measurement, !measurement.values.isEmpty else { return nil }
        func text(_ field: MeasurementField) throws -> ZPDFPersistence.DecimalString? {
            guard let quantity = measurement.values[field] else { return nil }
            guard let canonical = ZPDFPersistence.DecimalString(quantity.value) else {
                throw ZPDFPersistenceError.malformedDecimalString("\(field.rawValue): \(quantity.value)")
            }
            return canonical
        }
        return MeasurementValueRecord(
            markupId: record.id.rawValue.uuidString,
            countValue: try text(.count),
            planLengthSi: try text(.planLength),
            trueLengthSi: try text(.trueLength),
            perimeterSi: try text(.perimeter),
            planAreaSi: try text(.planArea),
            trueAreaSi: try text(.trueArea),
            wallAreaSi: try text(.wallArea),
            volumeSi: try text(.volume),
            riseSi: try text(.rise),
            runSi: try text(.run),
            slopeRatio: try text(.slopeRatio),
            slopePercent: try text(.slopePercent),
            slopeAngleRadians: try text(.slopeAngle),
            depthSi: try text(.depth),
            heightSi: try text(.height),
            radiusSi: try text(.radius),
            diameterSi: try text(.diameter),
            formulaVersion: measurement.formulaVersion
        )
    }

    /// `parameters_json`, written only when the parameters differ from the defaults —
    /// the common case never routes a `Decimal` through JSON at all.
    static func parametersJSON(of parameters: MeasurementParameters?) throws -> String? {
        guard let parameters, parameters != .default else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(parameters), as: UTF8.self)
    }

    /// `custom_values_json`, written only when the markup carries custom ledger cells.
    static func customValuesJSON(of values: [ColumnID: LedgerCellValue]) throws -> String? {
        guard !values.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(values), as: UTF8.self)
    }

    /// ADR-0012: the derivation of a `derived` or `read` row, as the contract's own JSON.
    /// Sorted keys, so the stored text of an unchanged derivation is stable across saves.
    static func derivationJSON(of derivation: QuantityDerivation?) throws -> String? {
        guard let derivation else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(derivation), as: UTF8.self)
    }

    /// The `markup_stamp` row for a placed stamp.
    ///
    /// The field values go out as JSON text, sorted, because the row is the *record* of
    /// what the stamp said — the freezing rule is kept here, at the write, not
    /// hoped for at the read.
    static func stampRecord(of stamp: StampInstance, markupId: String) throws -> MarkupStampRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return MarkupStampRecord(
            markupId: markupId,
            templateId: stamp.templateID.uuidString,
            templateName: stamp.templateName,
            templateRevision: stamp.templateRevision,
            artworkDigest: stamp.artworkDigest,
            artworkKind: stamp.artworkKind.rawValue,
            widthPoints: stamp.widthPoints,
            heightPoints: stamp.heightPoints,
            rotationDegrees: stamp.rotationDegrees,
            fieldsJson: String(decoding: try encoder.encode(stamp.fields), as: UTF8.self),
            resolvedAt: PersistenceTimestamp.string(from: stamp.resolvedAt)
        )
    }

    /// The placed stamp a `markup_stamp` row describes.
    ///
    /// Field text is read back verbatim. Nothing here consults a clock, an author or a page
    /// label, which is exactly the property that makes a stamp placed in 2026 still say 2026
    /// when the project is reopened in 2027.
    static func stampInstance(from row: MarkupStampRecord) throws -> StampInstance? {
        guard let templateID = UUID(uuidString: row.templateId) else { return nil }
        let fields = (try? JSONDecoder().decode([StampFieldValue].self, from: Data(row.fieldsJson.utf8))) ?? []
        return StampInstance(
            templateID: templateID,
            templateName: row.templateName,
            templateRevision: row.templateRevision,
            artworkDigest: row.artworkDigest,
            artworkKind: StampArtworkKind(rawValue: row.artworkKind) ?? .none,
            widthPoints: row.widthPoints,
            heightPoints: row.heightPoints,
            rotationDegrees: row.rotationDegrees,
            fields: fields,
            resolvedAt: PersistenceTimestamp.date(from: row.resolvedAt) ?? Date(timeIntervalSince1970: 0)
        )
    }

    /// The `markup_symbol` row for a mark that carries a symbol.
    ///
    /// A reference and a size, never bytes: the digest addresses the project's own artwork
    /// store, so the row is a few dozen characters however large the picture is, and 312 marks
    /// made from one seal cost one copy of it (ADR-0011 §2.1).
    static func symbolRecord(of symbol: MarkupSymbol, markupId: String) -> MarkupSymbolRecord {
        MarkupSymbolRecord(
            markupId: markupId,
            artworkDigest: symbol.artworkDigest,
            artworkKind: symbol.kind.rawValue,
            builtInGlyph: symbol.builtInGlyph,
            sizePoints: symbol.sizePoints,
            rotationDegrees: symbol.rotationDegrees,
            sourceName: symbol.sourceName.isEmpty ? nil : symbol.sourceName
        )
    }

    /// The symbol a `markup_symbol` row describes.
    ///
    /// An unreadable `artwork_kind` reads as ``StampArtworkKind/none`` rather than throwing: a
    /// glyph this build does not recognise still draws — the renderer falls back to a filled
    /// circle and says so — and a count of forty that reopens as thirty-nine because one row
    /// would not parse is the failure worth avoiding.
    static func markupSymbol(from row: MarkupSymbolRecord) -> MarkupSymbol {
        MarkupSymbol(
            artworkDigest: row.artworkDigest,
            kind: ZPDFContracts.StampArtworkKind(rawValue: row.artworkKind) ?? .none,
            builtInGlyph: row.builtInGlyph,
            sizePoints: row.sizePoints,
            rotationDegrees: row.rotationDegrees,
            sourceName: row.sourceName ?? ""
        )
    }

    static func markupRecord(
        from row: ZPDFPersistence.MarkupRecord,
        extra: MarkupExtraRecord?,
        cutouts: [MarkupID],
        stamp: MarkupStampRecord? = nil,
        symbol: MarkupSymbolRecord? = nil
    ) throws -> ZPDFContracts.MarkupRecord {
        guard let id = UUID(uuidString: row.id), let pageUUID = UUID(uuidString: row.pageId) else {
            throw ZPDFPersistenceError.packageMalformed(reason: "markup row \(row.id) has a non-UUID id")
        }
        let pageID = PageID(pageUUID)
        let tool = MeasurementTool(rawValue: row.type)
        let kind = extra.flatMap { MarkupKind(rawValue: $0.kind) }
            ?? (tool != nil ? .measurement : (MarkupKind(rawValue: row.type) ?? .measurement))
        let geometry = try TakeoffGeometryCodec.decode(
            blob: row.geometryBlob,
            json: extra?.geometryJson,
            pageID: pageID,
            tool: tool
        )
        let parameters = try extra?.parametersJson.map { json in
            try JSONDecoder().decode(MeasurementParameters.self, from: Data(json.utf8))
        }
        let customValues = try extra?.customValuesJson.map { json in
            try JSONDecoder().decode([ColumnID: LedgerCellValue].self, from: Data(json.utf8))
        } ?? [:]
        // ADR-0012: a NULL provenance column is a measured row, exactly as an absent key is
        // in the JSON contract. A `derived`/`read` row rehydrating as `.measured` would be a
        // silent upgrade of its claim — the exact thing the field exists to prevent.
        let provenance = extra?.provenance.flatMap(QuantityProvenance.init(rawValue:)) ?? .measured
        let derivation = try extra?.derivationJson.map { json in
            try JSONDecoder().decode(QuantityDerivation.self, from: Data(json.utf8))
        }
        // One decode of the blob's extras for both keys (R-067: it used to run twice).
        let styleExtras = TakeoffStyleCodec.extras(row.styleBlob)
        // ADR-0031: a detector's capture rides back in as a capture stamp, which
        // the session's recompute keeps while the geometry is the one it describes.
        var restored = CaptureArchive.restoring(json: extra?.captureJson, into: ZPDFContracts.MarkupRecord(
            id: MarkupID(id),
            documentID: DocumentID(UUID()),  // restamped by the session on hydrate
            pageID: pageID,
            kind: kind,
            tool: tool,
            subject: row.subject,
            label: row.label ?? "",
            comment: row.comment ?? "",
            author: row.author ?? "",
            status: row.status.flatMap(MarkupStatus.init(rawValue:)) ?? .none,
            style: TakeoffStyleCodec.decode(row.styleBlob),
            caption: extra?.caption,
            layerID: extra?.layerId.flatMap(UUID.init(uuidString:)).map(LayerID.init),   // ADR-0032
            zoneID: row.zoneId.flatMap(UUID.init(uuidString:)).map(ZoneID.init),
            scaleRegionID: row.scaleRegionId.flatMap(UUID.init(uuidString:)).map(ScaleRegionID.init),
            scaleID: row.scaleId.flatMap(UUID.init(uuidString:)).map(ScaleID.init),
            scaleVersion: row.scaleVersion,
            locked: row.locked,
            hidden: row.hidden,
            printable: extra?.printable ?? true,
            geometry: geometry,
            parameters: parameters,
            measurement: nil,  // recomputed by the session on hydrate, unless kept (below)
            parentMarkupID: extra?.parentMarkupId
                .flatMap(UUID.init(uuidString:))
                .map(MarkupID.init),
            cutoutMarkupIDs: cutouts,
            countGroupID: extra?.countGroupId
                .flatMap(UUID.init(uuidString:))
                .map(CountGroupID.init),
            customValues: customValues,
            stamp: try stamp.flatMap(stampInstance(from:)),
            symbol: symbol.map(markupSymbol(from:)),
            provenance: provenance,
            derivation: derivation,
            groupID: styleExtras.groupID,
            link: styleExtras.link,
            createdAt: PersistenceTimestamp.date(from: row.createdAt) ?? Date(),
            modifiedAt: PersistenceTimestamp.date(from: row.modifiedAt) ?? Date()
        ))
        // ADR-0034 (appcore): a value kept under an older scale version comes back whole — its
        // values, its stale flag and its provenance (a detector's capture method included) — so
        // hydration opens it as saved instead of re-measuring it under the new scale (R-046).
        if let kept = styleExtras.keptMeasurement { restored.measurement = kept }
        return restored
    }
}

// MARK: - Geometry codec

/// `MeasurementGeometry` ↔ the ZPG1 `geometry_blob`, with a JSON sidecar for the shapes
/// the blob cannot express exactly (ADR-0009).
///
/// The two common shapes — a polyline of points, a single closed polygon with holes, each
/// with straight edges only — round-trip through the blob alone, bit-exact (`Float64` bit
/// patterns). Everything else (count points with stable identities, arcs, arc edges carried
/// as bulges, circles, segments, multi-polygon compounds) is carried whole in `markup_extra.geometry_json`, written in the same
/// transaction, while the blob still holds an honest projection for foreign readers.
enum TakeoffGeometryCodec {

    struct Encoded {
        let blob: Data
        let json: String?
    }

    static func encode(_ geometry: MeasurementGeometry?) throws -> Encoded {
        guard let geometry else {
            // A markup without geometry still needs the NOT NULL blob: an empty polyline.
            return Encoded(blob: try GeometryBlob(kind: .polyline, rings: [[]]).encode(), json: nil)
        }

        // The blob holds x and y only. A chain or ring with arc edges (`pointBulges`,
        // `PolygonRing.bulges`, ADR-0030 §5) goes through the JSON sidecar, or its arcs would
        // reopen as chords and every area and length on them be re-measured on the chords (U-084).
        let onlyPoints = !geometry.points.isEmpty && geometry.pointBulges == nil
            && geometry.segments.isEmpty
            && geometry.polygons.isEmpty && geometry.arcs.isEmpty
            && geometry.circles.isEmpty && geometry.countPoints.isEmpty
        if onlyPoints {
            let ring = geometry.points.map { GeometryPoint(x: $0.x, y: $0.y) }
            return Encoded(blob: try GeometryBlob(kind: .polyline, rings: [ring]).encode(), json: nil)
        }

        let onlyOneClosedPolygon = geometry.polygons.count == 1 && geometry.points.isEmpty
            && geometry.segments.isEmpty && geometry.arcs.isEmpty
            && geometry.circles.isEmpty && geometry.countPoints.isEmpty
            && geometry.polygons[0].outer.isClosed
            && geometry.polygons[0].holes.allSatisfy(\.isClosed)
            && geometry.polygons[0].outer.bulges == nil
            && geometry.polygons[0].holes.allSatisfy { $0.bulges == nil }
        if onlyOneClosedPolygon {
            let polygon = geometry.polygons[0]
            var rings = [polygon.outer.points.map { GeometryPoint(x: $0.x, y: $0.y) }]
            rings.append(contentsOf: polygon.holes.map { $0.points.map { GeometryPoint(x: $0.x, y: $0.y) } })
            let kind: GeometryBlobKind = polygon.holes.isEmpty ? .polygon : .polygonWithHoles
            return Encoded(blob: try GeometryBlob(kind: kind, rings: rings).encode(), json: nil)
        }

        // Everything else: full fidelity in JSON, honest projection in the blob.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(geometry), as: UTF8.self)

        let blob: GeometryBlob
        if !geometry.countPoints.isEmpty, geometry.polygons.isEmpty, geometry.points.isEmpty,
           geometry.segments.isEmpty, geometry.arcs.isEmpty, geometry.circles.isEmpty {
            blob = GeometryBlob(
                kind: .point,
                rings: [geometry.countPoints.map { GeometryPoint(x: $0.position.x, y: $0.position.y) }]
            )
        } else {
            var rings: [[GeometryPoint]] = []
            if !geometry.points.isEmpty {
                rings.append(geometry.points.map { GeometryPoint(x: $0.x, y: $0.y) })
            }
            for segment in geometry.segments {
                rings.append([
                    GeometryPoint(x: segment.start.x, y: segment.start.y),
                    GeometryPoint(x: segment.end.x, y: segment.end.y)
                ])
            }
            for polygon in geometry.polygons {
                rings.append(polygon.outer.points.map { GeometryPoint(x: $0.x, y: $0.y) })
                rings.append(contentsOf: polygon.holes.map { $0.points.map { GeometryPoint(x: $0.x, y: $0.y) } })
            }
            if !geometry.countPoints.isEmpty {
                rings.append(geometry.countPoints.map { GeometryPoint(x: $0.position.x, y: $0.position.y) })
            }
            blob = GeometryBlob(kind: .freeform, rings: rings.isEmpty ? [[]] : rings)
        }
        return Encoded(blob: try blob.encode(), json: json)
    }

    static func decode(
        blob data: Data,
        json: String?,
        pageID: PageID,
        tool: MeasurementTool?
    ) throws -> MeasurementGeometry? {
        if let json {
            return try JSONDecoder().decode(MeasurementGeometry.self, from: Data(json.utf8))
        }
        let blob: GeometryBlob
        do {
            blob = try GeometryBlob.decode(data)
        } catch {
            throw ZPDFPersistenceError.malformedGeometryBlob(error)
        }
        switch blob.kind {
        case .polyline:
            let points = (blob.rings.first ?? []).map { PDFPoint(x: $0.x, y: $0.y) }
            guard !points.isEmpty else { return nil }
            let geometry = MeasurementGeometry(pageID: pageID, points: points)
            // A count saved with its marks in `points` — placed from a preset before V-031 —
            // reopens with them in `countPoints`, so Continue and Number Marks see them.
            return tool == .count ? geometry.countMarksInCountPoints() : geometry
        case .polygon, .polygonWithHoles, .rectangle:
            guard let outer = blob.rings.first else { return nil }
            return MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(
                    outer: PolygonRing(points: outer.map { PDFPoint(x: $0.x, y: $0.y) }, isClosed: true),
                    holes: blob.rings.dropFirst().map {
                        PolygonRing(points: $0.map { PDFPoint(x: $0.x, y: $0.y) }, isClosed: true)
                    }
                )]
            )
        case .point:
            // A count blob written without its JSON sidecar (foreign writer): the
            // positions survive; identities are minted fresh.
            let points = (blob.rings.first ?? []).map { PDFPoint(x: $0.x, y: $0.y) }
            guard !points.isEmpty else { return nil }
            return MeasurementGeometry(
                pageID: pageID,
                countPoints: points.map { CountPoint(id: CountPointID(UUID()), position: $0) }
            )
        case .ellipse, .cubicPath, .freeform:
            // Projection-only blob whose sidecar is missing: keep the vertices as a
            // polyline rather than inventing a shape.
            let points = blob.rings.flatMap { $0.map { PDFPoint(x: $0.x, y: $0.y) } }
            guard !points.isEmpty else { return nil }
            return MeasurementGeometry(pageID: pageID, points: points)
        }
    }
}

// MARK: - Style codec

/// `style_blob` is the JSON encoding of the frozen `MarkupStyle` contract, deterministic
/// key order. A blob that fails to decode falls back to the default style — a markup
/// with the wrong ink is recoverable, a markup refused at open is not.
enum TakeoffStyleCodec {

    static func encode(_ style: MarkupStyle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(style)
    }

    static func decode(_ data: Data) -> MarkupStyle {
        (try? JSONDecoder().decode(MarkupStyle.self, from: data)) ?? .default
    }

    /// ADR-0029: the record's `groupID` and `link` ride in the same `style_blob` JSON object,
    /// under two keys `MarkupStyle` does not have. No schema change: an old build's decoder
    /// ignores unknown keys, and an ungrouped, unlinked markup writes exactly the old blob.
    ///
    /// ADR-0034 (appcore): `keptMeasurement` is the whole result of a value kept under an older
    /// scale version (ADR-0030 §2). Hydration recomputes every other record, so this is the only
    /// place the kept number survives a reopen. Written only for a record whose measurement
    /// carries ``MeasurementWarning/Code/staleScaleVersion``; every other markup writes exactly
    /// the blob it wrote before.
    struct Extras: Codable, Equatable {
        var groupID: MarkupGroupID?
        var link: MarkupLinkTarget?
        var keptMeasurement: MeasurementResult?
    }

    private enum ExtraKeys: String, CodingKey { case groupID, link, keptMeasurement }

    private struct Envelope: Encodable {
        let style: MarkupStyle
        let extras: Extras
        func encode(to encoder: any Encoder) throws {
            try style.encode(to: encoder)
            var container = encoder.container(keyedBy: ExtraKeys.self)
            try container.encodeIfPresent(extras.groupID, forKey: .groupID)
            try container.encodeIfPresent(extras.link, forKey: .link)
            try container.encodeIfPresent(extras.keptMeasurement, forKey: .keptMeasurement)
        }
    }

    static func encode(_ record: ZPDFContracts.MarkupRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Envelope(style: record.style, extras: Extras(
            groupID: record.groupID, link: record.link, keptMeasurement: keptMeasurement(of: record)
        )))
    }

    /// The measurement a record keeps under an older scale version, or `nil` (ADR-0034).
    static func keptMeasurement(of record: ZPDFContracts.MarkupRecord) -> MeasurementResult? {
        guard let measurement = record.measurement, !measurement.values.isEmpty,
              measurement.warnings.contains(where: { $0.code == .staleScaleVersion }) else { return nil }
        return measurement
    }

    static func extras(_ data: Data) -> Extras {
        (try? JSONDecoder().decode(Extras.self, from: data)) ?? Extras()
    }
}
