import Foundation
import GRDB

// MARK: - layer_override (schema v3)

/// One per-project override of a PDF layer's visibility or lock state.
///
/// A row exists only where the project departs from the document default; the
/// effective state is always `override ?? documentDefault`, and that resolution lives
/// in the PDFKit bridge's `PDFLayerTree`, next to the code that read the defaults.
/// `layerId` is the bridge's stable positional identifier (`"ocg:<index>"` into
/// `/OCProperties /OCGs`), never a display name — names are legally duplicable.
public struct LayerOverrideRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "layer_override"

    public var projectId: String
    public var documentId: String
    public var layerId: String
    /// `nil` leaves visibility at the document default.
    public var visible: Bool?
    /// `nil` leaves the lock state at the document default.
    public var locked: Bool?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case projectId = "project_id"
        case documentId = "document_id"
        case layerId = "layer_id"
        case visible
        case locked
    }

    public init(
        projectId: String,
        documentId: String,
        layerId: String,
        visible: Bool?,
        locked: Bool?
    ) {
        self.projectId = projectId
        self.documentId = documentId
        self.layerId = layerId
        self.visible = visible
        self.locked = locked
    }
}

// MARK: - Store

/// Reads and writes `layer_override` rows. Pure database functions, run inside the
/// caller's `ProjectDatabaseActor.read`/`write` block like every other store here.
public enum LayerOverrideStore {

    /// Inserts or replaces the override for one layer.
    ///
    /// An override that sets **neither** field is not stored: it is indistinguishable
    /// from its own absence, so it is written as a removal instead. That keeps the
    /// table's CHECK constraint an invariant rather than a trap.
    public static func upsert(_ db: Database, _ record: LayerOverrideRecord) throws {
        if record.visible == nil && record.locked == nil {
            try remove(
                db,
                projectId: record.projectId,
                documentId: record.documentId,
                layerId: record.layerId
            )
            return
        }
        try record.upsert(db)
    }

    /// Removes one layer's override, returning it to the document default.
    public static func remove(
        _ db: Database,
        projectId: String,
        documentId: String,
        layerId: String
    ) throws {
        try db.execute(
            sql: """
                DELETE FROM layer_override
                WHERE project_id = ? AND document_id = ? AND layer_id = ?
                """,
            arguments: [projectId, documentId, layerId]
        )
    }

    /// Every override for one document in one project, ordered by `layer_id` so the
    /// result is deterministic.
    public static func overrides(
        _ db: Database,
        projectId: String,
        documentId: String
    ) throws -> [LayerOverrideRecord] {
        try LayerOverrideRecord
            .filter(LayerOverrideRecord.CodingKeys.projectId == projectId)
            .filter(LayerOverrideRecord.CodingKeys.documentId == documentId)
            .order(LayerOverrideRecord.CodingKeys.layerId)
            .fetchAll(db)
    }

    /// The visibility overrides of one document as the `[layerId: visible]` dictionary
    /// the bridge's `PDFLayerTree.effectiveVisibility(overrides:)` consumes. Rows that
    /// only override `locked` do not appear.
    public static func visibilityOverrides(
        _ db: Database,
        projectId: String,
        documentId: String
    ) throws -> [String: Bool] {
        var out: [String: Bool] = [:]
        for record in try overrides(db, projectId: projectId, documentId: documentId) {
            if let visible = record.visible { out[record.layerId] = visible }
        }
        return out
    }
}
