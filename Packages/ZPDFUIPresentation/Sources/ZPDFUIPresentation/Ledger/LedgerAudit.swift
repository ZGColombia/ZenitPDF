import Foundation

// ADR-0007 §3: the two trust surfaces — a per-markup derivation ("How this number was
// calculated") and the project audit trail — as the UI tier consumes them. These are
// presentation values: the app tier maps a measurement's provenance (`DerivationBridge`) and the
// persistence audit rows into this shape, and this package stays dependency-free.

/// One line of the derivation disclosure. `key` is the engine's stable machine identifier
/// (`scale.version`, `value.netArea.si`); the UI maps it to localized wording and shows
/// `value` verbatim — it is already deterministic text.
public struct LedgerDerivationFact: Codable, Hashable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A titled group of derivation facts: geometry, scale, slope, parameters, values, engine.
public struct LedgerDerivationSection: Codable, Hashable, Sendable, Identifiable {
    /// Stable machine identifier of the section.
    public let key: String
    public let facts: [LedgerDerivationFact]

    public var id: String { key }

    public init(key: String, facts: [LedgerDerivationFact]) {
        self.key = key
        self.facts = facts
    }
}

/// One field's movement inside an audited change: `netArea` went from `"21.34"` to `"25.5"`.
/// Values are the ledger's canonical decimal strings; `nil` before means the value came into
/// existence, `nil` after means it was removed.
///
/// The `…Display` trio is for reading: the presenter fills them through the same
/// formatting layer as the ledger ("Plan Length", "5,04 m") so a History row reads like a
/// sentence, while `field`/`before`/`after` keep the raw machine values for the derivation
/// disclosure and the audit export, where full precision belongs.
public struct LedgerAuditValueChange: Codable, Hashable, Sendable {
    public let field: String
    public let before: String?
    public let after: String?
    /// The localized, human field name — "Plan Length", never `planLength`.
    public let fieldDisplayName: String?
    /// `before` at display precision with its unit — "5,04 m", never 14 decimals.
    public let beforeDisplay: String?
    /// `after` at display precision with its unit.
    public let afterDisplay: String?

    public init(
        field: String,
        before: String?,
        after: String?,
        fieldDisplayName: String? = nil,
        beforeDisplay: String? = nil,
        afterDisplay: String? = nil
    ) {
        self.field = field
        self.before = before
        self.after = after
        self.fieldDisplayName = fieldDisplayName
        self.beforeDisplay = beforeDisplay
        self.afterDisplay = afterDisplay
    }

    /// Whether a person reading the row sees the value move: the stored values differ, and so do
    /// the texts the row shows for them.
    ///
    /// An edit records every measured value on both sides — the trail keeps the markup's whole
    /// state — so a Group, an Align, a Send to Back or a move of an area wrote "Plan Area 30,79 m²"
    /// before and after. Listed as the row's detail, those unchanged values hid which command ran
    /// (L-79). A value that differs below display precision reads the same on both sides, so it is
    /// not a change a person can see either.
    public var isVisibleChange: Bool {
        guard before != after else { return false }
        if let beforeDisplay, let afterDisplay, beforeDisplay == afterDisplay { return false }
        return true
    }

    /// The change as one line: "Plan Length 5,04 m → 6,12 m" for an edit, "Plan Length 5,04 m" for
    /// a value that came into existence, "Plan Length 5,04 m → —" for one that went — through the
    /// presenter's display strings when it filled them, else the raw canonical values.
    public var summaryLine: String {
        let name = fieldDisplayName ?? field
        let shownBefore = beforeDisplay ?? before
        let shownAfter = afterDisplay ?? after
        switch (shownBefore, shownAfter) {
        case (nil, let after?):
            return "\(name) \(after)"
        case (let before?, nil):
            return "\(name) \(before) → —"
        case (let before?, let after?):
            return before == after ? "\(name) \(after)" : "\(name) \(before) → \(after)"
        case (nil, nil):
            return name
        }
    }
}

/// One entry of the project's append-only audit trail, as the History pane, the inspector's
/// change list and the audit export consume it.
public struct LedgerAuditEvent: Codable, Hashable, Sendable, Identifiable {
    /// Position in the project's append-only trail; gapless per project, so it doubles as
    /// a stable identity.
    public let sequence: Int
    public let occurredAt: Date
    /// The audit action's raw value (`markup_created`, `scale_changed`, ...). Kept raw so
    /// an entry written by a newer build still renders; ``actionDisplayName`` localizes the
    /// ones this build knows.
    public let action: String
    public let actor: String
    /// The markup the entry is about, or `nil` for a project-level entry such as the scale
    /// half of a scale change.
    public let markupID: UUID?
    /// The markup's subject at the time of display, for a row a user can recognise.
    public let markupSubject: String?
    /// The page the markup lives on, for the History pane's page filter.
    public let pageLabel: String?
    public let commandName: String?
    public let undoGroup: String?
    public let note: String?
    public let changes: [LedgerAuditValueChange]
    /// What the markup is, as a person names it: its tool or kind ("Area", "Text", "Image"),
    /// with its label when it has one ("Area R-1"). A subject is often empty — a text box, a
    /// note, an image has none — and a row that named nothing but its page could not be told
    /// from the next (L-79). `nil` for a project-level entry or a markup never seen.
    public let markupName: String?

    public var id: Int { sequence }

    public init(
        sequence: Int,
        occurredAt: Date,
        action: String,
        actor: String,
        markupID: UUID? = nil,
        markupSubject: String? = nil,
        pageLabel: String? = nil,
        commandName: String? = nil,
        undoGroup: String? = nil,
        note: String? = nil,
        changes: [LedgerAuditValueChange] = [],
        markupName: String? = nil
    ) {
        self.markupName = markupName
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.action = action
        self.actor = actor
        self.markupID = markupID
        self.markupSubject = markupSubject
        self.pageLabel = pageLabel
        self.commandName = commandName
        self.undoGroup = undoGroup
        self.note = note
        self.changes = changes
    }

    /// The action a History row shows for a created markup that has no quantity — a Note, a Text
    /// box, a shape (L-99). The stored trail keeps `markup_created` for every creation; the app
    /// tier presents the ones that measured nothing under this value, so the row reads "Added"
    /// rather than "Measured" and the action filter offers the two apart.
    public static let markupAddedAction = "markup_added"

    /// Localized wording for the known actions; the raw value for anything newer than this
    /// build, which is honest rather than blank.
    public var actionDisplayName: String {
        switch action {
        case "markup_created":
            return NSLocalizedString("Measured", comment: "Audit action: a markup was created and measured")
        case Self.markupAddedAction:
            return NSLocalizedString("Added", comment: "Audit action: a markup without a quantity (a note, a text, a shape) was added")
        case "markup_modified":
            return NSLocalizedString("Edited", comment: "Audit action: a markup's geometry or data changed")
        case "markup_deleted":
            return NSLocalizedString("Deleted", comment: "Audit action: a markup was deleted")
        case "scale_changed":
            return NSLocalizedString("Scale changed", comment: "Audit action: a scale definition changed")
        case "markup_rescaled":
            return NSLocalizedString("Rescaled", comment: "Audit action: values recomputed under a changed scale")
        case "compensated":
            return NSLocalizedString("Undone", comment: "Audit action: a previous change was undone by a compensating entry")
        case "recompensated":
            return NSLocalizedString("Redone", comment: "Audit action: an undone change was re-applied by a redo")
        case "scale_verified":
            return NSLocalizedString("Scale verified", comment: "Audit action: a scale was checked against a second stated dimension")
        default:
            return action
        }
    }

    /// Whether the entry is an undo or a redo of an earlier one. Its note is bookkeeping — the id
    /// of the entry it compensates — not words for a person.
    public var isCompensation: Bool { action == "compensated" || action == "recompensated" }

    /// The values a History row lists: the ones that visibly moved (``LedgerAuditValueChange/isVisibleChange``).
    /// A creation or a deletion lists every value it recorded, since each one came or went.
    public var visibleChanges: [LedgerAuditValueChange] { changes.filter(\.isVisibleChange) }

    /// What a History row says under its markup: the values that moved, one per line; for a step
    /// that moved none, its note (a stamp's template and values, a scale check's deviation); and
    /// otherwise the command that ran — "Group", "Send to Back", "Align Left", "Move Markup".
    ///
    /// L-79: a step that changed no value on an area, a length or a count listed every unchanged
    /// value under "Edited", and the command's name never showed. An undo of such a step reads its
    /// command too, never the compensation's bookkeeping note.
    public var historyDetail: String? {
        let moved = visibleChanges
        if !moved.isEmpty { return moved.map(\.summaryLine).joined(separator: "\n") }
        if !isCompensation, let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        guard let command = commandName?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return nil
        }
        return command
    }
}

/// The full derivation of one markup's values: the disclosure sections plus the markup's own
/// change list, oldest first (ADR-0007 §1, §3).
public struct LedgerDerivationModel: Codable, Hashable, Sendable {
    public let markupID: UUID
    /// `false` for a value measured before provenance capture existed: the panel says so
    /// instead of guessing.
    public let hasProvenance: Bool
    public let sections: [LedgerDerivationSection]
    /// This markup's audit events, oldest first.
    public let history: [LedgerAuditEvent]

    public init(
        markupID: UUID,
        hasProvenance: Bool,
        sections: [LedgerDerivationSection],
        history: [LedgerAuditEvent]
    ) {
        self.markupID = markupID
        self.hasProvenance = hasProvenance
        self.sections = sections
        self.history = history
    }
}

/// A History-pane filter (ADR-0007 §3). Every field optional; absent means "all".
public struct LedgerAuditFilter: Codable, Hashable, Sendable {
    /// Only entries about markups on this page.
    public var pageLabel: String?
    /// Only entries about this markup.
    public var markupID: UUID?
    /// Only entries with this raw action value.
    public var action: String?

    public init(pageLabel: String? = nil, markupID: UUID? = nil, action: String? = nil) {
        self.pageLabel = pageLabel
        self.markupID = markupID
        self.action = action
    }

    public var isEmpty: Bool { pageLabel == nil && markupID == nil && action == nil }

    /// Whether one event passes this filter.
    public func matches(_ event: LedgerAuditEvent) -> Bool {
        if let pageLabel, event.pageLabel != pageLabel { return false }
        if let markupID, event.markupID != markupID { return false }
        if let action, event.action != action { return false }
        return true
    }
}

/// Presents the measurement provenance surfaces of ADR-0007: the derivation of one markup's
/// values and the project's audit trail.
///
/// Adopted *alongside* ``LedgerPresenting`` by presenters that have a project database to
/// read the trail from; the shell reaches it with a conditional cast, so a presenter without
/// history (a bare mock, an interim app tier) degrades to an explicit empty state rather
/// than a compile error.
@MainActor
public protocol LedgerAuditPresenting: AnyObject {

    /// The derivation of one markup's values, or `nil` when the markup is unknown.
    func derivation(for markupID: UUID) -> LedgerDerivationModel?

    /// The project's audit trail, filtered, oldest first.
    func auditEvents(matching filter: LedgerAuditFilter) -> [LedgerAuditEvent]

    /// The page labels that occur in the trail, in display order, for the filter menu.
    var auditPageLabels: [String] { get }

    /// The raw action values that occur in the trail, in a stable order, for the filter menu.
    var auditActions: [String] { get }

    /// Moves whenever the trail changes, observably, so a reader can memoise a query of it.
    ///
    /// The trail publishes on its own schedule, not with the ledger's `contentRevision`: a
    /// Verify Scale entry, or an append that lands after the ledger adopted, changes the trail
    /// and not the ledger. The History pane keyed its memo on the ledger alone and kept the old
    /// list (V-042).
    var auditRevision: Int { get }
}
