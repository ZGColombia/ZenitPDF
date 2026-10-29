import Foundation
import ZPDFContracts
import GRDB
import ZPDFPersistence

/// A project of several drawings (NL-DOCS-04, ADR-0027 (documents)): one set, one session, the
/// rows of each drawing under its own `document` row.
///
/// Pages already carry the drawing they come from (`PageDescriptor.documentID`) and keep their
/// index in that drawing's own PDF (ADR-0022), so the set is the session's page order and the
/// archive writes each drawing's share of the takeoff under its document row.
extension TakeoffArchive {

    /// The package's drawings in set order: `document_set_entry.sort_order`, then creation.
    public static func documentRows(of package: ProjectPackage) async throws -> [String] {
        try await package.read { db in
            try String.fetchAll(db, sql: """
                SELECT document.id FROM document
                LEFT JOIN document_set_entry ON document_set_entry.document_id = document.id
                ORDER BY COALESCE(document_set_entry.sort_order, 2147483647), document.created_at, document.id
                """)
        }
    }

    /// One drawing of a project, as the package records it (NL-DOCS-04).
    public struct DrawingRow: Sendable, Equatable {
        /// The `document.id`.
        public let id: String
        /// Relative to the package root: `documents/original.pdf` for the drawing the project
        /// was created from, `documents/added-<id>.pdf` for one added later.
        public let relativePath: String
        public let displayName: String
        /// Whether this is the drawing the project was created from, opened through the
        /// package's working copy.
        public let isPrimary: Bool
    }

    /// The package's drawings in set order, the primary one marked.
    public static func drawingRows(of package: ProjectPackage) async throws -> [DrawingRow] {
        let primary = try await primaryDocumentIdentifier(of: package)
        let order = try await documentRows(of: package)
        let rows = try await package.read { db in
            try Row.fetchAll(db, sql: "SELECT id, relative_path, display_name FROM document").map { row in
                DrawingRow(
                    id: row["id"],
                    relativePath: row["relative_path"],
                    displayName: row["display_name"],
                    isPrimary: false
                )
            }
        }
        var byID: [String: DrawingRow] = [:]
        for row in rows {
            byID[row.id] = DrawingRow(
                id: row.id, relativePath: row.relativePath, displayName: row.displayName,
                isPrimary: row.id == primary
            )
        }
        return order.compactMap { byID[$0] }
    }

    /// Writes a set: each drawing's pages, markups, scales and regions under its own document
    /// row, with set-wide page positions. `documentRows` maps each runtime drawing identity to
    /// its package row; a page whose drawing is not in the map is refused before anything is
    /// written. Zones with no page are anchored to the set's first sheet.
    ///
    /// One transaction for the whole set, and the Project Zones written once for the set, after
    /// every drawing's share (U-029). Each drawing used to commit on its own and write only the
    /// zones on its own pages. A markup on drawing 1 filed in a new zone on drawing 2 then named
    /// a `project_zone` row that did not exist when drawing 1 committed, so the deferred foreign
    /// key failed that save and every later one; and a child zone on drawing 1 under a parent on
    /// drawing 2 lost its parent on every save, because drawing 2's `DELETE FROM project_zone`
    /// fired `parent_zone_id … ON DELETE SET NULL` on drawing 1's row at once.
    public static func writeSet(
        _ unfolded: TakeoffSession.TakeoffState,
        into package: ProjectPackage,
        documentRows: [DocumentID: String]
    ) async throws {
        // Removed sheets go with their drawing, flagged (NL-DOCS-07).
        let state = unfolded.foldingArrangement()
        for page in state.pages where documentRows[page.documentID] == nil {
            throw ZPDFPersistenceError.packageMalformed(
                reason: "page \(page.id.rawValue) belongs to a drawing the project does not hold"
            )
        }
        var positions: [PageID: Int] = [:]
        for (offset, page) in state.pages.enumerated() { positions[page.id] = offset }
        var order: [DocumentID] = []
        for page in state.pages where !order.contains(page.documentID) { order.append(page.documentID) }
        // A drawing with no page left in the set still gets its (empty) takeoff written.
        for id in documentRows.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) where !order.contains(id) {
            order.append(id)
        }
        let setOrder = order
        var shares: [PreparedWrite] = []
        for (index, id) in order.enumerated() {
            guard let row = documentRows[id] else { continue }
            var share = state.filtered(toDrawing: id, includingUnpaged: index == 0)
            share.setPositions = positions.filter { page, _ in share.pages.contains { $0.id == page } }
            shares.append(try await prepareWrite(share, into: package, documentId: row))
        }
        // Every zone on a sheet of the set, and every zone with no sheet, anchored to the first.
        let setPageIDs = Set(state.pages.map(\.id))
        let setZones = state.projectZones.filter { zone in zone.pageID.map(setPageIDs.contains) ?? true }
        let zoneRows: (zones: [ProjectZoneRecord], extras: [ProjectZoneExtraRecord]) = state.pages.first.map {
            Self.zoneRows(of: setZones, anchorPageId: $0.id.rawValue.uuidString)
        } ?? ([], [])
        let setZoneIDs = Set(zoneRows.zones.map(\.id))
        let setDocumentRows = setOrder.compactMap { documentRows[$0] }
        let prepared = shares
        try await package.write { db in
            for (sortOrder, id) in setOrder.enumerated() {
                guard let row = documentRows[id] else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO document_set_entry (document_id, sort_order) VALUES (?, ?)
                        ON CONFLICT(document_id) DO UPDATE SET sort_order = excluded.sort_order
                        """,
                    arguments: [row, sortOrder]
                )
            }
            for share in prepared { try share.apply(db, setZoneIDs) }
            // The set's zones, all at once: every row goes and every row returns, so no
            // `ON DELETE SET NULL` can strip a parent that is coming straight back. Kept markups
            // name them under the same identities, checked at commit (`defer_foreign_keys`).
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            if !setDocumentRows.isEmpty {
                let placeholders = Array(repeating: "?", count: setDocumentRows.count).joined(separator: ", ")
                try db.execute(
                    sql: """
                        DELETE FROM project_zone WHERE page_id IN
                            (SELECT id FROM page WHERE document_id IN (\(placeholders)))
                        """,
                    arguments: StatementArguments(setDocumentRows)
                )
            }
            for row in zoneRows.zones { try row.insert(db) }
            for row in zoneRows.extras { try row.insert(db) }
        }
    }

    /// Reads every drawing's stored takeoff, in set order.
    public static func readSet(from package: ProjectPackage) async throws -> [(documentId: String, takeoff: StoredTakeoff?)] {
        var result: [(documentId: String, takeoff: StoredTakeoff?)] = []
        for row in try await documentRows(of: package) {
            result.append((row, try await read(from: package, documentId: row)))
        }
        return result
    }

    /// The drawings' stored takeoffs as one: every drawing's fresh pages adopt their stored
    /// identities, then the set is ordered by the stored set-wide positions. `drawings` pairs
    /// each document row with the fresh pages of its PDF.
    public static func adoptingStoredSet(
        _ drawings: [(documentId: String, pages: [ZPDFContracts.PageDescriptor])],
        stored: [(documentId: String, takeoff: StoredTakeoff?)]
    ) -> (pages: [ZPDFContracts.PageDescriptor], takeoff: StoredTakeoff?) {
        var pages: [ZPDFContracts.PageDescriptor] = []
        var merged: StoredTakeoff?
        for drawing in drawings {
            let takeoff = stored.first { $0.documentId == drawing.documentId }?.takeoff ?? nil
            guard let takeoff else {
                // A drawing with no saved takeoff still takes the stable ids of its document
                // row (K-03), never the random ones its fresh pages were minted with.
                var unsaved = StoredTakeoff(
                    pageIDsByIndex: [:], scales: [], pageScaleIDs: [:], markups: [], hasSavedTakeoff: false
                )
                unsaved.documentRowID = drawing.documentId
                pages.append(contentsOf: adoptingStoredPageIDs(drawing.pages, stored: unsaved))
                continue
            }
            // Positions are applied once, set-wide, below.
            var unordered = takeoff
            unordered.pagePositions = [:]
            unordered.documentRowID = drawing.documentId
            pages.append(contentsOf: adoptingStoredPageIDs(drawing.pages, stored: unordered))
            merged = merged.map { $0.merging(takeoff) } ?? takeoff
        }
        guard let merged, !merged.pagePositions.isEmpty else { return (pages, merged) }
        let ordered = pages.enumerated().sorted { lhs, rhs in
            let l = merged.pagePositions[lhs.element.id.rawValue] ?? Int.max
            let r = merged.pagePositions[rhs.element.id.rawValue] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
        return (ordered, merged)
    }
}

extension TakeoffArchive.StoredTakeoff {

    /// This takeoff and `other` as one, for a set of drawings: pages, markups, scales and the
    /// rest side by side. Page identities never collide (UUIDs), so nothing is overwritten.
    func merging(_ other: TakeoffArchive.StoredTakeoff) -> TakeoffArchive.StoredTakeoff {
        var result = TakeoffArchive.StoredTakeoff(
            pageIDsByIndex: pageIDsByIndex,   // per drawing; adoption already used each one
            scales: scales + other.scales,
            pageScaleIDs: pageScaleIDs.merging(other.pageScaleIDs) { first, _ in first },
            calibrationEvidence: calibrationEvidence.merging(other.calibrationEvidence) { first, _ in first },
            markups: markups + other.markups,
            hasSavedTakeoff: hasSavedTakeoff || other.hasSavedTakeoff,
            scaleRegions: scaleRegions + other.scaleRegions,
            projectZones: projectZones + other.projectZones.filter { zone in !projectZones.contains { $0.id == zone.id } }
        )
        result.customColumns = customColumns.isEmpty ? other.customColumns : customColumns
        result.unreadableMarkupIDs = unreadableMarkupIDs + other.unreadableMarkupIDs
        result.pagePositions = pagePositions.merging(other.pagePositions) { first, _ in first }
        result.sheetIdentities = sheetIdentities.merging(other.sheetIdentities) { first, _ in first }
        result.excludedPageIDs = excludedPageIDs.union(other.excludedPageIDs)
        result.pageViews = pageViews.merging(other.pageViews) { first, _ in first }
        // ADR-0032: project-level, read once per package; any drawing's copy is the same.
        result.markupLayers = markupLayers.isEmpty ? other.markupLayers : markupLayers
        result.activeMarkupLayerID = activeMarkupLayerID ?? other.activeMarkupLayerID
        result.displayUnits = displayUnits ?? other.displayUnits
        result.projectAssemblyRecipes = projectAssemblyRecipes   // NL-QTY-07-UI: project-level, one copy
        return result
    }
}

extension TakeoffSession.TakeoffState {

    /// The share of this state that belongs to one drawing of a set.
    func filtered(toDrawing drawing: DocumentID, includingUnpaged: Bool) -> Self {
        let pages = self.pages.filter { $0.documentID == drawing }
        let pageIDs = Set(pages.map(\.id))
        let scales = self.scales.filter { $0.pageID.map(pageIDs.contains) ?? false }
        let scaleIDs = Set(scales.map(\.id))
        var share = TakeoffSession.TakeoffState(
            pages: pages,
            markups: markups.filter { pageIDs.contains($0.pageID) },
            scales: scales,
            pageScaleIDs: pageScaleIDs.filter { pageIDs.contains($0.key) },
            calibrationEvidence: calibrationEvidence.filter { scaleIDs.contains($0.key) },
            scaleRegions: scaleRegions.filter { pageIDs.contains($0.pageID) },
            projectZones: projectZones.filter { zone in zone.pageID.map(pageIDs.contains) ?? includingUnpaged }
        )
        share.customColumns = customColumns
        // Every share carries every held markup: `unreadableMarkupRows` only ever keeps a held ID
        // among its own document's rows, so the other drawings' IDs are inert here. Giving them
        // to the first share only deleted the held markups of every later drawing (R-050).
        share.heldMarkupIDs = heldMarkupIDs
        share.sheetIdentities = sheetIdentities.filter { pageIDs.contains($0.key) }
        share.pageViews = pageViews.filter { pageIDs.contains($0.key) }
        share.excludedPageIDs = excludedPageIDs.filter { pageIDs.contains($0) }
        // ADR-0031: set-aside capture methods travel with their markups.
        let shareMarkupIDs = Set(share.markups.map(\.id))
        share.uncalibratedCaptures = uncalibratedCaptures.filter { shareMarkupIDs.contains($0.key) }
        // ADR-0032: the project-level settings travel with the first drawing's share only.
        if includingUnpaged {
            share.markupLayers = markupLayers
            share.activeMarkupLayerID = activeMarkupLayerID
            share.displayUnits = displayUnits
            share.projectAssemblyRecipes = projectAssemblyRecipes   // NL-QTY-07-UI
        }
        return share
    }
}
