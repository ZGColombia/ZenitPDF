import Foundation
import GRDB

/// The read and write API for a project's custom ledger columns with their complete
/// definition (schema v11, BH-075).
///
/// The definition is whatever `Codable` value the application uses for a column — the
/// persistence layer does not know its shape and does not need to. It is stored as sorted-key
/// JSON in `custom_column.definition_json`, beside the spec 8.2 columns that still carry the
/// name, type, order and visibility, so a reader that predates v11 still sees the column.
///
/// Writes are upserts keyed by `custom_column.id`: an existing column keeps its row, and so
/// keeps every `custom_value` that references it (a delete-and-reinsert would cascade them
/// away). Removing a column is a separate, explicit call.
public enum CustomColumnStore {

    /// The largest definition this store writes or accepts back: a column definition is a few
    /// hundred bytes, and anything past this is not one.
    public static let maximumDefinitionByteCount = 64 * 1024

    /// One column: the spec 8.2 fields plus the application's definition.
    public struct Column<Definition: Codable & Sendable>: Sendable {
        public var id: String
        public var name: String
        public var type: String
        public var sortOrder: Int
        public var visible: Bool
        /// `nil` for a column written before v11, or without a definition.
        public var definition: Definition?

        public init(
            id: String, name: String, type: String, sortOrder: Int,
            visible: Bool = true, definition: Definition?
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.sortOrder = sortOrder
            self.visible = visible
            self.definition = definition
        }
    }

    /// Inserts or updates the given columns of `project`, in one statement per column,
    /// inside the caller's transaction. Columns not named are left alone.
    public static func upsert<Definition: Codable & Sendable>(
        _ columns: [Column<Definition>],
        project projectId: String,
        in db: Database
    ) throws {
        for column in columns {
            let json = try column.definition.map(encode)
            if var existing = try CustomColumnRecord.fetchOne(db, key: column.id) {
                guard existing.projectId == projectId else {
                    throw ZPDFPersistenceError.packageMalformed(
                        reason: "custom column \(column.id) belongs to another project"
                    )
                }
                existing.name = column.name
                existing.type = column.type
                existing.sortOrder = column.sortOrder
                existing.visible = column.visible
                existing.definitionJson = json
                try existing.update(db)
            } else {
                try CustomColumnRecord(
                    id: column.id, projectId: projectId, name: column.name, type: column.type,
                    sortOrder: column.sortOrder, visible: column.visible, definitionJson: json
                ).insert(db)
            }
        }
    }

    /// Every custom column of `project`, in `sort_order`, with its definition decoded.
    ///
    /// A definition that does not decode as `Definition` — written by a newer build, or
    /// damaged — reads as `nil` rather than failing the whole read: the column still exists
    /// by name and type, and the caller decides what a column without a definition means.
    public static func columns<Definition: Codable & Sendable>(
        project projectId: String,
        as definition: Definition.Type,
        in db: Database
    ) throws -> [Column<Definition>] {
        let rows = try CustomColumnRecord
            .filter(CustomColumnRecord.CodingKeys.projectId == projectId)
            .order(CustomColumnRecord.CodingKeys.sortOrder, CustomColumnRecord.CodingKeys.id)
            .fetchAll(db)
        return rows.map { row in
            Column(
                id: row.id, name: row.name, type: row.type, sortOrder: row.sortOrder,
                visible: row.visible, definition: row.definitionJson.flatMap { decode($0, as: definition) }
            )
        }
    }

    /// Removes the named columns of `project`. Their `custom_value` rows go with them
    /// (`ON DELETE CASCADE`), which is what removing a column means.
    @discardableResult
    public static func remove(ids: [String], project projectId: String, in db: Database) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try CustomColumnRecord
            .filter(CustomColumnRecord.CodingKeys.projectId == projectId)
            .filter(ids.contains(CustomColumnRecord.CodingKeys.id))
            .deleteAll(db)
    }

    static func encode<Definition: Encodable>(_ definition: Definition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(definition)
        guard data.count <= maximumDefinitionByteCount else {
            throw ZPDFPersistenceError.inputTooLarge(
                what: "custom column definition", byteCount: data.count, limit: maximumDefinitionByteCount
            )
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<Definition: Decodable>(_ json: String, as type: Definition.Type) -> Definition? {
        let data = Data(json.utf8)
        guard data.count <= maximumDefinitionByteCount else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
