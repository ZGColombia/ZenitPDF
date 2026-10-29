import Foundation
import GRDB

// MARK: - measurement_audit (ADR-0007)

/// What an audit entry records happened. Stored as the raw string, so a build that gains a new
/// action can still read a trail written by one that had not.
public enum MeasurementAuditAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// A markup was created and measured.
    case markupCreated = "markup_created"
    /// A markup's geometry, parameters or metadata changed and its values were recomputed.
    case markupModified = "markup_modified"
    /// A markup was deleted. The trail keeps its final values; the markup row is gone.
    case markupDeleted = "markup_deleted"
    /// A scale definition changed — the entry that silently moves every number on a page.
    case scaleChanged = "scale_changed"
    /// A markup's values were recomputed under a changed scale (the fan-out of `scaleChanged`).
    case markupRescaled = "markup_rescaled"
    /// A compensating entry: the mutation a previous entry recorded was undone. The original
    /// entry is never edited or deleted (ADR-0007 §2).
    case compensated = "compensated"
    /// A compensating entry whose target was itself a compensation — a redo. Same append-only
    /// mechanics as ``compensated``; a distinct action only so the History pane can say
    /// "Redone" instead of mislabeling a ⇧⌘Z as "Undone" (History rows read like sentences;
    /// found 2026-08-24).
    case recompensated = "recompensated"
    /// A scale was checked against a second dimension the drawing states (NL-MEASURE-04,
    /// ADR-0030). Informational: nothing about the scale or any value changed. The note carries
    /// the deviation.
    case scaleVerified = "scale_verified"
}

/// One row of the append-only `measurement_audit` table (ADR-0007 §2).
///
/// Written **inside the same transaction as the mutation it records**, so a change and its
/// record cannot diverge: either both commit or both roll back. The table carries no foreign
/// keys on purpose — the trail must survive the deletion of everything it describes.
public struct MeasurementAuditRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "measurement_audit"

    public var id: String
    public var projectId: String
    /// The markup the entry is about, or `nil` for a project-level entry such as the scale
    /// half of a scale change.
    public var markupId: String?
    /// Project-wide monotonic position, allocated by ``MeasurementAuditStore/appendAudit(_:in:)``
    /// inside the writing transaction. Orders one markup's history and the whole project's.
    public var sequence: Int
    /// ``PersistenceTimestamp`` text, sortable as a plain string.
    public var occurredAt: String
    /// ``MeasurementAuditAction`` raw value.
    public var action: String
    /// Who made the change, for example the markup author or the machine user name.
    public var actor: String
    /// `{field: decimal string}` JSON, canonical decimal strings, keys sorted. `nil` when the
    /// entry created something from nothing.
    public var beforeValuesJson: String?
    /// Same shape as `beforeValuesJson`. `nil` when the entry deleted something.
    public var afterValuesJson: String?
    public var scaleId: String?
    public var scaleVersion: Int?
    public var formulaVersion: Int?
    /// The undoable command that made the mutation, for example "Move vertex".
    public var commandName: String?
    /// Groups the entries of one user-visible undo step, so a single Cmd-Z that touches
    /// twelve markups reads as one step in the history.
    public var undoGroup: String?
    public var note: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case projectId = "project_id"
        case markupId = "markup_id"
        case sequence
        case occurredAt = "occurred_at"
        case action
        case actor
        case beforeValuesJson = "before_values_json"
        case afterValuesJson = "after_values_json"
        case scaleId = "scale_id"
        case scaleVersion = "scale_version"
        case formulaVersion = "formula_version"
        case commandName = "command_name"
        case undoGroup = "undo_group"
        case note
    }

    public init(
        id: String,
        projectId: String,
        markupId: String? = nil,
        sequence: Int,
        occurredAt: String,
        action: String,
        actor: String,
        beforeValuesJson: String? = nil,
        afterValuesJson: String? = nil,
        scaleId: String? = nil,
        scaleVersion: Int? = nil,
        formulaVersion: Int? = nil,
        commandName: String? = nil,
        undoGroup: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.markupId = markupId
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.action = action
        self.actor = actor
        self.beforeValuesJson = beforeValuesJson
        self.afterValuesJson = afterValuesJson
        self.scaleId = scaleId
        self.scaleVersion = scaleVersion
        self.formulaVersion = formulaVersion
        self.commandName = commandName
        self.undoGroup = undoGroup
        self.note = note
    }

    /// The action as the typed enum, or `nil` for a value written by a newer build.
    public var auditAction: MeasurementAuditAction? {
        MeasurementAuditAction(rawValue: action)
    }
}

/// An audit entry as a caller states it — everything except the `sequence`, which only the
/// writing transaction can allocate correctly.
public struct MeasurementAuditEntry: Sendable, Hashable {
    public var id: String
    public var projectId: String
    public var markupId: String?
    public var occurredAt: String
    public var action: MeasurementAuditAction
    public var actor: String
    /// `field -> canonical decimal string`, the same strings the ledger stores.
    public var beforeValues: [String: String]?
    /// Same shape as `beforeValues`.
    public var afterValues: [String: String]?
    public var scaleId: String?
    public var scaleVersion: Int?
    public var formulaVersion: Int?
    public var commandName: String?
    public var undoGroup: String?
    public var note: String?

    public init(
        id: String,
        projectId: String,
        markupId: String? = nil,
        occurredAt: String,
        action: MeasurementAuditAction,
        actor: String,
        beforeValues: [String: String]? = nil,
        afterValues: [String: String]? = nil,
        scaleId: String? = nil,
        scaleVersion: Int? = nil,
        formulaVersion: Int? = nil,
        commandName: String? = nil,
        undoGroup: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.markupId = markupId
        self.occurredAt = occurredAt
        self.action = action
        self.actor = actor
        self.beforeValues = beforeValues
        self.afterValues = afterValues
        self.scaleId = scaleId
        self.scaleVersion = scaleVersion
        self.formulaVersion = formulaVersion
        self.commandName = commandName
        self.undoGroup = undoGroup
        self.note = note
    }
}
