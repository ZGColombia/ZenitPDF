import Foundation
import GRDB

extension ProjectSchema {

    /// v17 (NL-AUTO-16): the Takeoff Assistant's inbox. Each row is one proposal a
    /// detector made for one page — a sheet name, a scale, a room, a symbol hit — waiting for a
    /// person. Nothing in this table is a quantity or a markup: accepting a proposal goes through
    /// the ordinary command bus, and the row only records that it was decided. The payload is the
    /// application's own JSON; persistence stores it and does not interpret it.
    public static let automationProposalTableStatement = """
        CREATE TABLE automation_proposal (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            page_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at TEXT NOT NULL,
            decided_at TEXT
        )
        """

    public static let automationProposalIndexDefinitions: [IndexDefinition] = [
        .init(
            name: "idx_automation_proposal_page_state",
            sql: "CREATE INDEX idx_automation_proposal_page_state ON automation_proposal(project_id, page_id, state)",
            rationale: "The Navigator badge counts a page's open proposals; the inbox lists them per page."
        )
    ]

    static func createAutomationProposalTable(_ db: Database) throws {
        try db.execute(sql: automationProposalTableStatement)
        for definition in automationProposalIndexDefinitions { try db.execute(sql: definition.sql) }
    }
}

/// One proposal in the Takeoff Assistant's inbox (schema v17).
public struct AutomationProposalRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "automation_proposal"

    /// Where a proposal stands. Stored as text so a newer state survives an older reader.
    public enum State: String, Codable, Sendable, CaseIterable {
        case open
        case accepted
        case rejected
    }

    public var id: String
    public var projectId: String
    public var pageId: String
    public var kind: String
    public var payloadJson: String
    public var state: String
    public var createdAt: String
    public var decidedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case projectId = "project_id"
        case pageId = "page_id"
        case kind
        case payloadJson = "payload_json"
        case state
        case createdAt = "created_at"
        case decidedAt = "decided_at"
    }

    public init(id: String, projectId: String, pageId: String, kind: String, payloadJson: String,
                state: String = State.open.rawValue, createdAt: String, decidedAt: String? = nil) {
        self.id = id
        self.projectId = projectId
        self.pageId = pageId
        self.kind = kind
        self.payloadJson = payloadJson
        self.state = state
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}

/// Read and write API for the Takeoff Assistant's inbox (schema v17).
public enum AutomationProposalStore {

    /// The largest payload kept. A proposal is a name, a ratio, a ring of points or a list of hits.
    public static let maximumPayloadByteCount = 4 * 1024 * 1024

    public static func insert(_ records: [AutomationProposalRecord], in db: Database) throws {
        for record in records {
            guard record.payloadJson.utf8.count <= maximumPayloadByteCount else {
                throw ZPDFPersistenceError.packageMalformed(reason: "automation proposal payload is larger than \(maximumPayloadByteCount) bytes")
            }
            try record.upsert(db)
        }
    }

    /// Every proposal of a project, page by page, oldest first.
    public static func proposals(project projectId: String, in db: Database) throws -> [AutomationProposalRecord] {
        try AutomationProposalRecord
            .filter(AutomationProposalRecord.CodingKeys.projectId == projectId)
            .order(AutomationProposalRecord.CodingKeys.pageId, AutomationProposalRecord.CodingKeys.createdAt, AutomationProposalRecord.CodingKeys.id)
            .fetchAll(db)
    }

    /// Records a decision.
    public static func setState(id: String, state: AutomationProposalRecord.State, decidedAt: String?, in db: Database) throws {
        try db.execute(sql: "UPDATE automation_proposal SET state = ?, decided_at = ? WHERE id = ?",
                       arguments: [state.rawValue, decidedAt, id])
    }

    /// Removes a page's open proposals — before a fresh run of the assistant replaces them.
    /// Decided rows stay, so a rerun does not offer again what a person already rejected.
    public static func removeOpen(project projectId: String, page pageId: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM automation_proposal WHERE project_id = ? AND page_id = ? AND state = 'open'",
                       arguments: [projectId, pageId])
    }
}
