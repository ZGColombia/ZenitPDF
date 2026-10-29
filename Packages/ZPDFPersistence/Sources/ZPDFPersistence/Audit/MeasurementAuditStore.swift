import Foundation
import GRDB

/// The one write path and the query surface of the measurement audit trail (ADR-0007).
///
/// Every function takes a `Database`, which is the design decision that makes the atomicity
/// guarantee real: an audit entry is appended **inside the transaction that performs the
/// mutation it records** — the same `write { db in ... }` closure — so a crash, a kill or a
/// thrown error between "mutate" and "record" is impossible by construction. There is no
/// separate audit connection, no queue, no deferred write to lose.
public enum MeasurementAuditStore {

    // MARK: - Append

    /// Appends one entry, allocating the next project-wide sequence number inside the caller's
    /// transaction. Returns the row as written.
    ///
    /// The values dictionaries must hold canonical decimal strings — the same grammar the
    /// ledger's columns use — so a history row and a ledger row compare directly (ADR-0007 §4).
    ///
    /// - Throws: ``ZPDFPersistenceError/malformedDecimalString(_:)`` when a value is not a
    ///   canonical decimal string.
    @discardableResult
    public static func appendAudit(
        _ entry: MeasurementAuditEntry,
        in db: Database
    ) throws -> MeasurementAuditRecord {
        let record = MeasurementAuditRecord(
            id: entry.id,
            projectId: entry.projectId,
            markupId: entry.markupId,
            sequence: try nextSequence(project: entry.projectId, in: db),
            occurredAt: entry.occurredAt,
            action: entry.action.rawValue,
            actor: entry.actor,
            beforeValuesJson: try encodeValues(entry.beforeValues),
            afterValuesJson: try encodeValues(entry.afterValues),
            scaleId: entry.scaleId,
            scaleVersion: entry.scaleVersion,
            formulaVersion: entry.formulaVersion,
            commandName: entry.commandName,
            undoGroup: entry.undoGroup,
            note: entry.note
        )
        try record.insert(db)
        return record
    }

    /// Appends the compensating entry for an undo (ADR-0007 §2): before and after swap places,
    /// the action becomes ``MeasurementAuditAction/compensated``, and the original row is left
    /// exactly as it was — an undo adds history, it never subtracts any.
    ///
    /// Compensating a row that is itself a compensation is a **redo**, and is recorded as
    /// ``MeasurementAuditAction/recompensated`` so the trail reads "Measured → Undone →
    /// Redone" rather than logging a ⇧⌘Z as a second "Undone" with the values reversed.
    @discardableResult
    public static func appendCompensatingEntry(
        for original: MeasurementAuditRecord,
        id: String,
        occurredAt: String,
        actor: String,
        undoGroup: String? = nil,
        in db: Database
    ) throws -> MeasurementAuditRecord {
        let action: MeasurementAuditAction =
            original.action == MeasurementAuditAction.compensated.rawValue
                ? .recompensated
                : .compensated
        let record = MeasurementAuditRecord(
            id: id,
            projectId: original.projectId,
            markupId: original.markupId,
            sequence: try nextSequence(project: original.projectId, in: db),
            occurredAt: occurredAt,
            action: action.rawValue,
            actor: actor,
            beforeValuesJson: original.afterValuesJson,
            afterValuesJson: original.beforeValuesJson,
            scaleId: original.scaleId,
            scaleVersion: original.scaleVersion,
            formulaVersion: original.formulaVersion,
            commandName: original.commandName,
            // The caller's group, or none (BH-590). Falling back to the original's group
            // put the compensation into the very group a later undo re-queries, so that
            // undo compensated the original a second time and re-compensated its own
            // compensation in one step.
            undoGroup: undoGroup,
            note: "compensates \(original.id)"
        )
        try record.insert(db)
        return record
    }

    // MARK: - Scale-change fan-out

    /// One markup's values before and after a scale change.
    public struct MarkupValueChange: Sendable, Hashable {
        public let markupId: String
        /// `field -> canonical decimal string` under the old scale version.
        public let beforeValues: [String: String]
        /// `field -> canonical decimal string` under the new scale version.
        public let afterValues: [String: String]

        public init(markupId: String, beforeValues: [String: String], afterValues: [String: String]) {
            self.markupId = markupId
            self.beforeValues = beforeValues
            self.afterValues = afterValues
        }
    }

    /// Records a scale change as ADR-0007 §2 requires: **one** ``MeasurementAuditAction/scaleChanged``
    /// entry for the scale itself, plus **one** ``MeasurementAuditAction/markupRescaled`` entry
    /// per affected markup with its before and after values — all inside the caller's
    /// transaction, all sharing one `undoGroup`, so "did the numbers change after the revision
    /// came in" is a query, not a memory.
    ///
    /// - Parameters:
    ///   - identifiers: mints one id per entry; injected so the fan-out is deterministic.
    /// - Returns: the entries as written, scale entry first.
    @discardableResult
    public static func recordScaleChange(
        projectId: String,
        scaleId: String,
        oldVersion: Int,
        newVersion: Int,
        affected: [MarkupValueChange],
        occurredAt: String,
        actor: String,
        formulaVersion: Int? = nil,
        commandName: String? = nil,
        undoGroup: String,
        note: String? = nil,
        identifiers: any IdentifierGenerator,
        in db: Database
    ) throws -> [MeasurementAuditRecord] {
        var written: [MeasurementAuditRecord] = []
        written.reserveCapacity(affected.count + 1)

        written.append(try appendAudit(
            MeasurementAuditEntry(
                id: identifiers.nextIdentifier(),
                projectId: projectId,
                markupId: nil,
                occurredAt: occurredAt,
                action: .scaleChanged,
                actor: actor,
                scaleId: scaleId,
                scaleVersion: newVersion,
                formulaVersion: formulaVersion,
                commandName: commandName,
                undoGroup: undoGroup,
                note: note ?? "scale \(scaleId) version \(oldVersion) -> \(newVersion), \(affected.count) markup(s) affected"
            ),
            in: db
        ))

        for change in affected {
            written.append(try appendAudit(
                MeasurementAuditEntry(
                    id: identifiers.nextIdentifier(),
                    projectId: projectId,
                    markupId: change.markupId,
                    occurredAt: occurredAt,
                    action: .markupRescaled,
                    actor: actor,
                    beforeValues: change.beforeValues,
                    afterValues: change.afterValues,
                    scaleId: scaleId,
                    scaleVersion: newVersion,
                    formulaVersion: formulaVersion,
                    commandName: commandName,
                    undoGroup: undoGroup
                ),
                in: db
            ))
        }
        return written
    }

    // MARK: - Queries

    /// A History-pane filter (ADR-0007 §3): every field is optional, absent means "all".
    public struct AuditFilter: Sendable, Hashable {
        /// Only entries about this markup.
        public var markupId: String?
        /// Only these actions.
        public var actions: Set<MeasurementAuditAction>?
        /// Only entries at or after this ``PersistenceTimestamp`` text.
        public var occurredAtOrAfter: String?
        /// Only entries strictly before this ``PersistenceTimestamp`` text.
        public var occurredBefore: String?
        /// Only entries of this undo group.
        public var undoGroup: String?
        /// Cap on the number of rows returned, newest first when set.
        public var limit: Int?

        public init(
            markupId: String? = nil,
            actions: Set<MeasurementAuditAction>? = nil,
            occurredAtOrAfter: String? = nil,
            occurredBefore: String? = nil,
            undoGroup: String? = nil,
            limit: Int? = nil
        ) {
            self.markupId = markupId
            self.actions = actions
            self.occurredAtOrAfter = occurredAtOrAfter
            self.occurredBefore = occurredBefore
            self.undoGroup = undoGroup
            self.limit = limit
        }
    }

    /// One markup's own change list, oldest first — the inspector's per-markup history.
    public static func auditTrail(
        markup markupId: String,
        in db: Database
    ) throws -> [MeasurementAuditRecord] {
        try MeasurementAuditRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM measurement_audit
                WHERE markup_id = ? ORDER BY sequence
                """,
            arguments: [markupId]
        )
    }

    /// The project's trail, filtered (ADR-0007 §3). Oldest first, unless a `limit` asks for
    /// the newest slice, which comes back newest first.
    public static func auditTrail(
        project projectId: String,
        filter: AuditFilter = AuditFilter(),
        in db: Database
    ) throws -> [MeasurementAuditRecord] {
        var conditions = ["project_id = ?"]
        var arguments: [any DatabaseValueConvertible] = [projectId]

        if let markupId = filter.markupId {
            conditions.append("markup_id = ?")
            arguments.append(markupId)
        }
        if let actions = filter.actions {
            // "Only these actions": an empty set selects nothing, not everything (BH-591).
            guard !actions.isEmpty else { return [] }
            let sorted = actions.map(\.rawValue).sorted()
            conditions.append("action IN (\(sorted.map { _ in "?" }.joined(separator: ",")))")
            arguments.append(contentsOf: sorted)
        }
        if let from = filter.occurredAtOrAfter {
            conditions.append("occurred_at >= ?")
            arguments.append(from)
        }
        if let before = filter.occurredBefore {
            conditions.append("occurred_at < ?")
            arguments.append(before)
        }
        if let undoGroup = filter.undoGroup {
            conditions.append("undo_group = ?")
            arguments.append(undoGroup)
        }

        var sql = "SELECT * FROM measurement_audit WHERE \(conditions.joined(separator: " AND "))"
        if let limit = filter.limit {
            sql += " ORDER BY sequence DESC LIMIT \(max(0, limit))"
        } else {
            sql += " ORDER BY sequence"
        }
        return try MeasurementAuditRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    /// The reserved key prefix for review-field values (ADR-0021 (collaboration)).
    public static let reviewFieldPrefix = "review."

    /// The longest review value a row may carry. A note is prose, not a document; this bounds
    /// what one audit row can cost without truncating any note a person would type.
    public static let maximumReviewValueBytes = 32 * 1024

    /// Whether a values key is a review field (plain text) rather than a measured value.
    public static func isReviewField(_ key: String) -> Bool {
        key.hasPrefix(reviewFieldPrefix)
    }

    /// Only the measured-value keys of a decoded values object — what a consumer that folds
    /// quantities must look at, so a status or note edit is never mistaken for a re-measure.
    public static func measuredValues(_ values: [String: String]?) -> [String: String]? {
        guard let values else { return nil }
        let measured = values.filter { !isReviewField($0.key) }
        return measured.isEmpty ? nil : measured
    }

    /// Decodes a `before_values_json` / `after_values_json` column back into `field -> decimal
    /// string`, strictly.
    public static func decodeValues(_ json: String?) throws -> [String: String]? {
        guard let json else { return nil }
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        } catch {
            throw ZPDFPersistenceError.packageMalformed(
                reason: "measurement_audit values column is not a {field: string} object: \(error)"
            )
        }
    }

    // MARK: - Internals

    /// The next project-wide sequence number. Runs on the caller's write connection inside the
    /// caller's transaction, so two appends cannot race: SQLite has one writer.
    static func nextSequence(project projectId: String, in db: Database) throws -> Int {
        let current = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(sequence), 0) FROM measurement_audit WHERE project_id = ?",
            arguments: [projectId]
        ) ?? 0
        return current + 1
    }

    /// Encodes `field -> decimal string` as deterministic JSON (sorted keys), refusing any
    /// value that is not a canonical decimal string.
    static func encodeValues(_ values: [String: String]?) throws -> String? {
        guard let values else { return nil }
        for (field, text) in values {
            // ADR-0021 (collaboration): review fields — status, notes, label, subject, lock,
            // visibility — are recorded as plain text under the reserved `review.` prefix, so
            // the trail can say "status went Open → Accepted". Every other key is a measured
            // value and stays a canonical decimal string (ADR-0007 §4), which is what lets a
            // history row and a ledger row compare directly.
            if isReviewField(field) {
                guard text.utf8.count <= maximumReviewValueBytes else {
                    throw ZPDFPersistenceError.malformedDecimalString("\(field): review value over \(maximumReviewValueBytes) bytes")
                }
                continue
            }
            if DecimalString(text: text) == nil {
                throw ZPDFPersistenceError.malformedDecimalString("\(field): \(text)")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(values)
        return String(decoding: data, as: UTF8.self)
    }
}
