import Foundation
import GRDB
import Observation
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// The app-tier feed behind the History tab (ADR-0007 §3).
///
/// One presenter, two responsibilities that must never drift apart:
///
/// 1. **Writing.** Every applied command and every undo is appended to the
///    `measurement_audit` table through ``ZPDFPersistence/MeasurementAuditStore`` — the
///    same append-only trail the inspector and the audit export read. Writes are
///    serialised behind one another, so the trail's order is the order the user acted in.
/// 2. **Reading.** After each write the trail is re-read through
///    ``ZPDFPersistence/MeasurementAuditStore/auditTrail(project:filter:in:)`` and published
///    as ``events``. The presenter is `@Observable`, which is the observation edge the
///    History pane re-renders on: a drawn measurement appears in the pane the moment its
///    entry commits, with no notification plumbing of its own.
///
/// In Project Mode the database is the package's own `project.sqlite`. In Quick PDF Mode
/// it is the takeoff's autosave database inside the app container (spec 6.2: quick
/// takeoff data lives in the container until the user chooses a home for it), and
/// ``migrate(to:projectID:)`` carries the trail into the package when the takeoff is
/// promoted — Create Project must never cost the user their history.
@MainActor
@Observable
public final class AppHistoryPresenter {

    /// The trail, oldest first, as the History pane consumes it.
    public private(set) var events: [LedgerAuditEvent] = [] {
        didSet { eventsGeneration &+= 1 }
    }
    /// Bumped whenever ``events`` is written, so a reader can keep an index of it (R-053).
    /// Observed (V-042): the History pane keys its memo on it and must re-read when it moves.
    public private(set) var eventsGeneration = 0

    /// The `undo_group` of the most recent batch this presenter recorded.
    ///
    /// Published so a scoped batch apply can put the group on its receipt without the
    /// caller having to go and find it: a batch is **one** audit group, and a receipt that
    /// names it is what makes "one group, expandable to the rows"
    /// checkable from outside the presenter.
    public private(set) var lastBatchAuditGroup: String?

    /// Whether a store is attached. Without one the presenter records nothing and the
    /// pane shows its honest "no changes recorded yet" state.
    public var isAttached: Bool { database != nil }

    /// Who entries are recorded as. Defaults to the local account's full name, matching
    /// the local-first identity rule (no server identity exists to use instead).
    public var actorName: String

    /// Resolves the author name at record time: the Settings
    /// author-name preference affects **new** entries only, so it is read per entry
    /// rather than captured once. `nil` keeps ``actorName``.
    public var actorNameProvider: (@MainActor () -> String)?

    /// The ledger's own formatter, so History rows render values through exactly the
    /// same layer as the ledger. The environment keeps it in
    /// step with the ledger projection's formatter.
    public var formatter: QuantityFormatter = QuantityFormatter()

    private var database: ProjectDatabaseActor?
    private var projectID: String = ""
    /// Subjects and page labels remembered at record time, so a deleted markup's rows
    /// still read as something a person recognises after the markup itself is gone.
    private var knownMarkups: [String: (subject: String, pageLabel: String)] = [:]
    /// What each markup is, as a History row names it — its tool or kind and its label
    /// ("Area R-1", "Text", "Image") — learned with the subjects (L-79).
    private var knownMarkupNames: [String: String] = [:]
    /// The rows last published, so a newly learned subject can be shown without a re-read.
    @ObservationIgnored
    private var lastPublishedRecords: [MeasurementAuditRecord] = []

    /// The project database the trail is attached to, for the takeoff snapshots that live in
    /// the same file (NL-QTY-16). `nil` before a document is attached.
    var attachedStore: (database: ProjectDatabaseActor, projectID: String)? {
        database.map { ($0, projectID) }
    }

    /// The audit trail as last read, oldest first — what the measurement trace folds to learn
    /// when each markup was measured and under which scale version (feature 16).
    public var auditRecords: [MeasurementAuditRecord] { lastPublishedRecords }
    /// The serialised write queue: every append chains behind the previous one.
    private var pendingWrites: Task<Void, Never>?
    /// Bumped per queued write, so ``settle()`` can tell "the task I awaited" from
    /// "another arrived while I waited" — `Task` is a value and has no identity.
    @ObservationIgnored
    private var writeGeneration: Int = 0

    /// Creates a detached presenter. Attach a store with ``attach(database:projectID:)``.
    public init(actorName: String = NSFullUserName()) {
        self.actorName = actorName.isEmpty ? NSUserName() : actorName
    }

    // MARK: - Store lifecycle

    /// Told when the feed attaches to a project database. The review threads (ADR-0021
    /// (collaboration)) live in the same database and follow the trail wherever it goes.
    @ObservationIgnored
    public var onAttach: (@MainActor (_ database: ProjectDatabaseActor, _ projectID: String) -> Void)?
    /// Told when the feed migrates into another database (Create Project), with where it came
    /// from, so the review threads are carried with the trail.
    @ObservationIgnored
    public var onMigrate: (@MainActor (
        _ from: ProjectDatabaseActor?, _ fromProject: String,
        _ to: ProjectDatabaseActor, _ toProject: String
    ) -> Void)?

    /// Points the feed at a project database and reloads the trail from it.
    public func attach(database: ProjectDatabaseActor, projectID: String) {
        self.database = database
        self.projectID = projectID
        onAttach?(database, projectID)
        enqueue { db, project in
            try Self.readTrail(db: db, project: project)
        }
    }

    /// Detaches the store. Recorded events stay on screen; nothing further is written.
    public func detach() {
        database = nil
        projectID = ""
    }

    /// Moves the trail into another database — the Create-Project promotion: every row of
    /// the quick takeoff's container trail is re-appended into the package's own
    /// `project.sqlite`, in order, and the feed reads from the package from then on.
    public func migrate(to newDatabase: ProjectDatabaseActor, projectID newProjectID: String) {
        let oldDatabase = database
        let oldProject = projectID
        database = newDatabase
        projectID = newProjectID
        onMigrate?(oldDatabase, oldProject, newDatabase, newProjectID)
        let previous = pendingWrites
        writeGeneration &+= 1
        pendingWrites = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                var carried: [MeasurementAuditRecord] = []
                if let oldDatabase {
                    carried = try await oldDatabase.read { db in
                        try MeasurementAuditStore.auditTrail(project: oldProject, in: db)
                    }
                }
                let rows = carried
                let records = try await newDatabase.write { db -> [MeasurementAuditRecord] in
                    try Self.carryOver(rows, into: newProjectID, in: db)
                    return try MeasurementAuditStore.auditTrail(project: newProjectID, in: db)
                }
                self.publish(records)
            } catch {
                // The takeoff itself is unharmed; the feed keeps showing what it has.
            }
        }
    }

    /// Re-appends carried rows into another project's trail **verbatim**.
    ///
    /// The row is copied as stored — its raw `action` string and its already-canonical value
    /// JSON included — rather than round-tripped through ``MeasurementAuditEntry``, whose
    /// `action` is this build's enum. The round trip rewrote every action a newer build wrote
    /// and this one does not know as `markup_modified`, silently altering an append-only trail
    /// during Create Project, against the record's own "stored as a raw string so older builds
    /// can still read it" rule (BH-445). Only the project and the project-wide sequence change,
    /// because those belong to the destination.
    nonisolated static func carryOver(
        _ rows: [MeasurementAuditRecord],
        into projectID: String,
        in db: Database
    ) throws {
        var sequence = (try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(sequence), 0) FROM measurement_audit WHERE project_id = ?",
            arguments: [projectID]
        ) ?? 0)
        for row in rows.sorted(by: { $0.sequence < $1.sequence }) {
            sequence += 1
            try MeasurementAuditRecord(
                id: row.id,
                projectId: projectID,
                markupId: row.markupId,
                sequence: sequence,
                occurredAt: row.occurredAt,
                action: row.action,
                actor: row.actor,
                beforeValuesJson: row.beforeValuesJson,
                afterValuesJson: row.afterValuesJson,
                scaleId: row.scaleId,
                scaleVersion: row.scaleVersion,
                formulaVersion: row.formulaVersion,
                commandName: row.commandName,
                undoGroup: row.undoGroup,
                note: row.note
            ).insert(db)
        }
    }

    /// Awaits every queued write and reload — how tests get a settled trail.
    public func settle() async {
        while let task = pendingWrites {
            let generation = writeGeneration
            await task.value
            guard writeGeneration == generation else { continue }
            pendingWrites = nil
        }
    }

    // MARK: - Recording (wired to DocumentCommandBus by AppCoreEnvironment)

    /// Records one applied command. Returns the audit entry id, which the command bus
    /// carries into the undo registration as the token a later ⌘Z compensates.
    public func recordApplied(_ outcome: DocumentCommandOutcome, snapshot: DocumentSnapshot) -> String? {
        guard database != nil else { return nil }
        let entryID = UUID().uuidString
        let occurredAt = PersistenceTimestamp.string(from: Date())
        let actor = resolvedActorName
        let action: MeasurementAuditAction
        let markupID: MarkupID
        var note: String?

        switch outcome.command {
        case .addMarkup(let record):
            action = .markupCreated
            markupID = record.id
            // The single click: a Place-mode stamp's trail records its
            // template and every value resolved into it, exactly as a batch-placed one does.
            if let stamp = record.stamp { note = StampBridge.auditNote(for: stamp) }
        case .addCutout(_, let cutout):
            action = .markupCreated
            markupID = cutout.id
        case .removeMarkup(let id):
            action = .markupDeleted
            markupID = id
        case .moveMarkup(let id, _, _):
            action = .markupModified
            markupID = id
        case .changeStyle(let id, _):
            action = .markupModified
            markupID = id
        case .editVertices(let id, _):
            action = .markupModified
            markupID = id
        case .editParameters(let id, _):
            action = .markupModified
            markupID = id
        case .editCustomValue(let id, _, _):
            action = .markupModified
            markupID = id
        case .editSubject(let id, _):
            action = .markupModified
            markupID = id
        case .editLabel(let id, _):
            action = .markupModified
            markupID = id
        case .editComment(let id, _), .editText(let id, _):
            action = .markupModified
            markupID = id
        case .rotateStamp(let id, _):
            action = .markupModified
            markupID = id
        case .setMarkupLink(let id, _):
            action = .markupModified
            markupID = id
        case .changeScale(let scale):
            // One `scale_changed` entry for the calibration itself, plus one `markup_modified`
            // entry per markup the new scale restamped, all under one `undo_group`. The trail
            // used to carry the single scale entry only, so a rescale that rewrote forty
            // numbers left forty rows whose history said nothing had happened to them, and
            // the trace resolver had no per-markup entry to learn the rescale from (CR-12).
            return recordScaleChange(scale, outcome: outcome, snapshot: snapshot)
        case .addCustomColumns, .setCustomColumns:
            // A column set changes no measurement; like a page reorder it fans out to nothing.
            return nil
        case .batchStatusChange, .recalculateMeasurements,
             .setScaleRegions, .setProjectZones, .setMarkupZone, .setMarkupScaleRegion,
             .setLocked, .setHidden, .arrangeMarkups, .setMarkupGroup,
             .setMarkupLayers, .setMarkupLayer, .deleteMarkupLayer:
            // Fan-out commands: one entry per affected markup, one shared `undo_group`,
            // the same shape a scale change already gets (ADR-0007 §2). Recording one
            // entry naming `changedMarkupIDs.first` — which is a `Set`, so not even a
            // stable choice — described a status change over twelve markups as a change
            // to one of them.
            //
            // The four project-structure commands join them for the same reason: assigning
            // a Scale Region restamps every markup inside it, and the trail has to name
            // each one. A structure edit that touched no markup — creating the first
            // region, renaming a zone — fans out to nothing, which is correct: the audit
            // trail is a record of what happened to *measurements*, and nothing did.
            return recordFanOut(
                markupIDs: outcome.changedMarkupIDs,
                inverse: outcome.inverse,
                forward: outcome.forward,
                commandName: outcome.command.undoActionName,
                snapshot: snapshot
            )
        case .reorderPage, .setSheetIdentities, .insertPages, .setPagesExcluded, .setPageViews:
            // A page reorder — or naming a sheet — touches no measurement, so by the rule above it fans out to
            // nothing. It used to be written as an anonymous `markup_modified` row with no
            // markup, which the History pane rendered as an "Edited" measurement event for a
            // change that edited none (BH-446).
            return nil
        }

        let names = NameContext(snapshot: snapshot)
        let entry = MeasurementAuditEntry(
            id: entryID,
            projectId: projectID,
            markupId: markupID.rawValue.uuidString,
            occurredAt: occurredAt,
            action: action,
            actor: actor,
            beforeValues: Self.values(of: outcome.inverse.markups[markupID] ?? nil, comparedWith: outcome.forward.markups[markupID] ?? nil),
            afterValues: Self.values(of: outcome.forward.markups[markupID] ?? nil, comparedWith: outcome.inverse.markups[markupID] ?? nil),
            commandName: outcome.command.undoActionName,
            undoGroup: entryID,
            note: note
        )
        var entries = [entry]
        rememberSubject(of: markupID, inverse: outcome.inverse, forward: outcome.forward, names: names)

        // The markups the command changed *besides* the one it names: a cutout's parent,
        // whose net area an added, moved, re-shaped or deleted cutout rewrites, and the
        // cutouts a deleted parent takes with it. Each gets its own row in the same undo
        // group, so the parent's 40 → 34 m² has a trail entry and ⌘Z compensates all of
        // them together. One row naming the cutout alone left the parent's number changed
        // with no history, and deleted cutouts left the document with none at all
        // (BH-010, BH-011).
        let companions = outcome.changedMarkupIDs
            .subtracting([markupID])
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        for companion in companions {
            let before = outcome.inverse.markups[companion] ?? nil
            let after = outcome.forward.markups[companion] ?? nil
            rememberSubject(of: companion, inverse: outcome.inverse, forward: outcome.forward, names: names)
            entries.append(
                MeasurementAuditEntry(
                    id: UUID().uuidString,
                    projectId: projectID,
                    markupId: companion.rawValue.uuidString,
                    occurredAt: occurredAt,
                    action: Self.auditAction(before: before, after: after),
                    actor: actor,
                    beforeValues: Self.values(of: before, comparedWith: after),
                    afterValues: Self.values(of: after, comparedWith: before),
                    commandName: outcome.command.undoActionName,
                    undoGroup: entryID
                )
            )
        }

        let written = entries
        enqueueAppend { db, _ in
            for entry in written {
                try MeasurementAuditStore.appendAudit(entry, in: db)
            }
        }
        return entryID
    }

    /// Records one applied *batch* — the ledger's bulk edit (ADR-0007 §2).
    ///
    /// One entry per affected markup, all sharing one `undo_group`, with that markup's own
    /// before and after values. The alternative the codebase had until now — a single
    /// entry naming `changedMarkupIDs.first` — is a trail that says a bulk edit touched
    /// one markup, and `Set.first` means it does not even say the same one twice. A
    /// dispute about markup seven is then unanswerable, which is the exact failure
    /// ADR-0007 exists to prevent.
    ///
    /// - Returns: the `undo_group`, which the bus carries into the undo registration. A
    ///   later Cmd-Z compensates the whole group, entry for entry.
    public func recordAppliedBatch(
        _ outcome: DocumentBatchOutcome,
        actionName: String,
        snapshot: DocumentSnapshot
    ) -> String? {
        // Cleared first, so a batch recorded with the feed detached does not put the group of
        // an earlier, unrelated batch on its receipt (BH-443).
        lastBatchAuditGroup = nil
        guard database != nil else { return nil }
        // Each markup's action is read off its own before and after (`auditAction`), so 312 new
        // stamps are 312 creations, a Delete or a Cut is a deletion, and a Split is one deletion
        // plus one creation per part. One action for the whole batch called every deletion,
        // split and merge "Edited", and Review Rounds counted nothing removed (X-019).
        // The trail records the stamp's template *and* its resolved values.
        // Derived from the records the batch actually wrote, so a template edited a minute
        // later cannot rewrite what the trail says was placed.
        var notes: [MarkupID: String] = [:]
        for command in outcome.commands {
            guard case .addMarkup(let record) = command, let stamp = record.stamp else { continue }
            notes[record.id] = StampBridge.auditNote(for: stamp)
        }
        let group = recordFanOut(
            markupIDs: outcome.changedMarkupIDs,
            inverse: outcome.inverse,
            forward: outcome.forward,
            commandName: actionName,
            notes: notes,
            snapshot: snapshot
        )
        lastBatchAuditGroup = group
        return group
    }

    /// The calibration entry and its per-markup fan-out, as one undo group (ADR-0007 §2).
    ///
    /// The scale entry names the scale and its version and no markup; each fan-out entry
    /// names its markup *and* the scale, so a row's own history says which calibration
    /// rewrote its number. Sorted like ``recordFanOut``, for a reproducible trail.
    private func recordScaleChange(
        _ scale: ScaleTransform,
        outcome: DocumentCommandOutcome,
        snapshot: DocumentSnapshot
    ) -> String? {
        guard database != nil else { return nil }
        let group = UUID().uuidString
        let occurredAt = PersistenceTimestamp.string(from: Date())
        let actor = resolvedActorName
        let scaleID = scale.id.rawValue.uuidString
        let commandName = outcome.command.undoActionName
        var entries: [MeasurementAuditEntry] = [
            MeasurementAuditEntry(
                id: group,
                projectId: projectID,
                markupId: nil,
                occurredAt: occurredAt,
                action: .scaleChanged,
                actor: actor,
                beforeValues: nil,
                afterValues: nil,
                scaleId: scaleID,
                scaleVersion: scale.version,
                commandName: commandName,
                undoGroup: group
            )
        ]
        let affected = outcome.changedMarkupIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let names = NameContext(snapshot: snapshot)
        for markupID in affected {
            rememberSubject(of: markupID, inverse: outcome.inverse, forward: outcome.forward, names: names)
            entries.append(
                MeasurementAuditEntry(
                    id: UUID().uuidString,
                    projectId: projectID,
                    markupId: markupID.rawValue.uuidString,
                    occurredAt: occurredAt,
                    action: .markupModified,
                    actor: actor,
                    beforeValues: Self.values(of: outcome.inverse.markups[markupID] ?? nil, comparedWith: outcome.forward.markups[markupID] ?? nil),
                    afterValues: Self.values(of: outcome.forward.markups[markupID] ?? nil, comparedWith: outcome.inverse.markups[markupID] ?? nil),
                    scaleId: scaleID,
                    scaleVersion: scale.version,
                    commandName: commandName,
                    undoGroup: group
                )
            )
        }
        let written = entries
        enqueueAppend { db, _ in
            for entry in written {
                try MeasurementAuditStore.appendAudit(entry, in: db)
            }
        }
        return group
    }

    /// One `scale_verified` entry (NL-MEASURE-04, ADR-0030): a scale was checked against a second
    /// dimension the drawing states. It names the scale and the version checked, and the note
    /// says both lengths and the deviation. Informational, so it names no markup and no undo
    /// compensates it: the check happened.
    @discardableResult
    public func recordScaleVerification(_ verification: ScaleVerification, scaleID: ScaleID, note: String) -> String? {
        guard database != nil else { return nil }
        let entryID = UUID().uuidString
        let entry = MeasurementAuditEntry(
            id: entryID,
            projectId: projectID,
            markupId: nil,
            occurredAt: PersistenceTimestamp.string(from: verification.verifiedAt),
            action: .scaleVerified,
            actor: resolvedActorName,
            beforeValues: nil,
            afterValues: nil,
            scaleId: scaleID.rawValue.uuidString,
            scaleVersion: verification.scaleVersion,
            commandName: NSLocalizedString("Verify Scale", comment: "History command name: a scale check"),
            undoGroup: entryID,
            note: note
        )
        enqueueAppend { db, _ in
            try MeasurementAuditStore.appendAudit(entry, in: db)
        }
        return entryID
    }

    /// What happened to one markup in one step, read off its own before and after: it did not
    /// exist and now does — created; it existed and now does not — deleted; anything else —
    /// modified.
    ///
    /// The one rule behind every row a step writes besides the single command's named markup:
    /// a single command's companions (a cutout's parent, a deleted parent's cutouts) and every
    /// row of a batch or fan-out. The batch path used to stamp one action on all of its rows, so
    /// a Delete, a Cut, a Split and a Merge — every one of them a batch — wrote "Edited" for the
    /// markups they removed and created (X-019).
    static func auditAction(
        before: ZPDFContracts.MarkupRecord?,
        after: ZPDFContracts.MarkupRecord?
    ) -> MeasurementAuditAction {
        switch (before, after) {
        case (nil, .some): return .markupCreated
        case (.some, nil): return .markupDeleted
        default: return .markupModified
        }
    }

    /// One entry per affected markup, all under one fresh `undo_group`, each with the action
    /// ``auditAction(before:after:)`` reads off that markup's own before and after.
    ///
    /// The single write path behind both the bulk edit and the fan-out commands, so the
    /// two cannot drift into recording the same kind of step two different ways.
    private func recordFanOut(
        markupIDs: Set<MarkupID>,
        inverse: DocumentCommandInverse,
        forward: DocumentCommandInverse,
        commandName: String,
        notes: [MarkupID: String] = [:],
        snapshot: DocumentSnapshot
    ) -> String? {
        guard database != nil else { return nil }
        // Sorted, so the trail's order inside one step is reproducible rather than
        // whatever order the `Set` happened to hash into.
        let affected = markupIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        guard !affected.isEmpty else { return nil }

        let group = UUID().uuidString
        let occurredAt = PersistenceTimestamp.string(from: Date())
        let actor = resolvedActorName
        var entries: [MeasurementAuditEntry] = []
        entries.reserveCapacity(affected.count)

        let names = NameContext(snapshot: snapshot)
        for markupID in affected {
            rememberSubject(of: markupID, inverse: inverse, forward: forward, names: names)
            let before = inverse.markups[markupID] ?? nil
            let after = forward.markups[markupID] ?? nil
            entries.append(
                MeasurementAuditEntry(
                    id: UUID().uuidString,
                    projectId: projectID,
                    markupId: markupID.rawValue.uuidString,
                    occurredAt: occurredAt,
                    action: Self.auditAction(before: before, after: after),
                    actor: actor,
                    beforeValues: Self.values(of: before, comparedWith: after),
                    afterValues: Self.values(of: after, comparedWith: before),
                    commandName: commandName,
                    undoGroup: group,
                    note: notes[markupID]
                )
            )
        }

        let written = entries
        enqueueAppend { db, _ in
            for entry in written {
                try MeasurementAuditStore.appendAudit(entry, in: db)
            }
        }
        return group
    }

    /// Records the compensating entry for an undo of the entry named by `token`
    /// (ADR-0007 §2: an undo adds history, it never subtracts any). Returns the
    /// compensation's own id, so a redo compensates the compensation in turn.
    public func recordCompensation(of token: String) -> String? {
        guard database != nil else { return nil }
        let compensationGroup = UUID().uuidString
        let occurredAt = PersistenceTimestamp.string(from: Date())
        let actor = resolvedActorName
        enqueueAppend { db, project in
            // The token is an `undo_group`, not a row id. A single command writes one
            // entry whose group is its own id, so this is the same lookup it always was;
            // a bulk edit writes eleven, and undoing it must compensate all eleven rather
            // than whichever one the id happened to name. The compensations form a group
            // of their own, so a redo compensates *them* in turn and the chain stays
            // append-only in both directions (ADR-0007 §2).
            let originals = try MeasurementAuditStore.auditTrail(
                project: project,
                filter: MeasurementAuditStore.AuditFilter(undoGroup: token),
                in: db
            )
            for original in originals {
                try MeasurementAuditStore.appendCompensatingEntry(
                    for: original,
                    id: UUID().uuidString,
                    occurredAt: occurredAt,
                    actor: actor,
                    undoGroup: compensationGroup,
                    in: db
                )
            }
        }
        return compensationGroup
    }

    // MARK: - Reading (LedgerAuditPresenting backing store)

    /// The trail, filtered, oldest first.
    public func auditEvents(matching filter: LedgerAuditFilter) -> [LedgerAuditEvent] {
        events.filter(filter.matches)
    }

    /// The page labels occurring in the trail, in first-appearance order.
    public var auditPageLabels: [String] {
        var seen: Set<String> = []
        return events.compactMap { event in
            guard let label = event.pageLabel, seen.insert(label).inserted else { return nil }
            return label
        }
    }

    /// The raw action values occurring in the trail, in first-appearance order.
    public var auditActions: [String] {
        var seen: Set<String> = []
        return events.compactMap { event in
            guard seen.insert(event.action).inserted else { return nil }
            return event.action
        }
    }

    /// One markup's own history, oldest first.
    public func derivation(for markupID: UUID) -> LedgerDerivationModel? {
        let history = events.filter { $0.markupID == markupID }
        guard !history.isEmpty else { return nil }
        return LedgerDerivationModel(
            markupID: markupID,
            hasProvenance: false,
            sections: [],
            history: history
        )
    }

    // MARK: - Internals

    /// Chains one write-and-reload behind whatever is already queued, and publishes the
    /// rows it returns.
    private func enqueue(
        _ work: @Sendable @escaping (Database, String) throws -> [MeasurementAuditRecord]
    ) {
        guard let database else { return }
        let project = projectID
        let previous = pendingWrites
        writeGeneration &+= 1
        pendingWrites = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let records = try await database.write { db in
                    try work(db, project)
                }
                self?.publish(records)
            } catch {
                // A refused append leaves the previous trail on screen. The mutation the
                // entry described has still happened; hiding rows would compound the loss.
            }
        }
    }

    /// Chains one append behind whatever is already queued, then publishes only the rows it
    /// added (R-052). Every append used to re-read the whole `measurement_audit` table and
    /// re-decode every row's JSON on the main actor, so each edit cost O(history).
    private func enqueueAppend(_ work: @Sendable @escaping (Database, String) throws -> Void) {
        guard let database else { return }
        let project = projectID
        let previous = pendingWrites
        writeGeneration &+= 1
        pendingWrites = Task { @MainActor [weak self] in
            await previous?.value
            // Read once the writes queued before this one have published, so the trail on
            // screen is complete up to its last sequence.
            let after = self?.lastPublishedRecords.last?.sequence ?? 0
            do {
                let rows = try await database.write { db in
                    try work(db, project)
                    return try Self.readTrail(db: db, project: project, after: after)
                }
                self?.publish(appending: rows)
            } catch {
                // A refused append leaves the previous trail on screen. The mutation the
                // entry described has still happened; hiding rows would compound the loss.
            }
        }
    }

    private nonisolated static func readTrail(db: Database, project: String) throws -> [MeasurementAuditRecord] {
        try MeasurementAuditStore.auditTrail(project: project, in: db)
    }

    /// The project's rows after `sequence`, oldest first.
    private nonisolated static func readTrail(db: Database, project: String, after sequence: Int) throws -> [MeasurementAuditRecord] {
        try MeasurementAuditRecord.fetchAll(
            db,
            sql: "SELECT * FROM measurement_audit WHERE project_id = ? AND sequence > ? ORDER BY sequence",
            arguments: [project, sequence]
        )
    }

    /// The units and locale the published rows were rendered in; a change re-renders them all.
    @ObservationIgnored
    private var renderedFormat: (units: DisplayUnitSelection, localeIdentifier: String)?
    /// How many rows have been rendered — decoded and formatted — since creation. Test seam.
    @ObservationIgnored
    private(set) var renderedRowCount = 0

    /// Appends newly read rows, rendering only them — unless the units changed since the rows
    /// on screen were rendered, when every row is rendered again in the new ones.
    private func publish(appending rows: [MeasurementAuditRecord]) {
        let last = lastPublishedRecords.last?.sequence ?? 0
        let fresh = rows.filter { $0.sequence > last }
        guard let format = renderedFormat, format.units == formatter.units,
              format.localeIdentifier == formatter.localeIdentifier else {
            publish(lastPublishedRecords + fresh)
            return
        }
        guard !fresh.isEmpty else { return }
        learnRecordedNames(from: fresh)
        lastPublishedRecords += fresh
        // The markups the new rows name may have been renamed by the step that wrote them:
        // their older rows take the name too, as a full re-render did.
        let named = Set(fresh.compactMap { $0.markupId.flatMap(UUID.init(uuidString:)) })
        var updated = patchingNames(of: named, in: events) ?? events
        updated += fresh.map(event(for:))
        events = updated
    }

    /// `events` with the rows of `ids` carrying each markup's known subject and page, or `nil`
    /// when none of them differs. Names only: the values are already rendered.
    private func patchingNames(of ids: Set<UUID>, in events: [LedgerAuditEvent]) -> [LedgerAuditEvent]? {
        guard !ids.isEmpty else { return nil }
        var patched = events
        var touched = false
        for index in patched.indices {
            let event = patched[index]
            guard let id = event.markupID, ids.contains(id), let known = knownMarkups[id.uuidString] else { continue }
            let name = knownMarkupNames[id.uuidString]
            guard known.subject != event.markupSubject || known.pageLabel != event.pageLabel
                    || name != event.markupName else { continue }
            patched[index] = LedgerAuditEvent(
                sequence: event.sequence, occurredAt: event.occurredAt, action: event.action, actor: event.actor,
                markupID: event.markupID, markupSubject: known.subject, pageLabel: known.pageLabel,
                commandName: event.commandName, undoGroup: event.undoGroup, note: event.note, changes: event.changes,
                markupName: name
            )
            touched = true
        }
        return touched ? patched : nil
    }

    private func publish(_ records: [MeasurementAuditRecord]) {
        learnRecordedNames(from: records)
        lastPublishedRecords = records
        renderedFormat = (formatter.units, formatter.localeIdentifier)
        events = records.map(event(for:))
    }

    /// One stored row as the History pane shows it.
    private func event(for record: MeasurementAuditRecord) -> LedgerAuditEvent {
        renderedRowCount += 1
        let markupID = record.markupId.flatMap(UUID.init(uuidString:))
        let known = record.markupId.flatMap { knownMarkups[$0] }
        let before = (try? MeasurementAuditStore.decodeValues(record.beforeValuesJson)) ?? nil
        let after = (try? MeasurementAuditStore.decodeValues(record.afterValuesJson)) ?? nil
        var fields = Set((before ?? [:]).keys)
        fields.formUnion((after ?? [:]).keys)
        fields.remove(Self.recordedNameField)
        let changes = fields.sorted().map { field in
            LedgerAuditValueChange(
                field: field,
                before: before?[field],
                after: after?[field],
                fieldDisplayName: Self.fieldDisplayName(field),
                beforeDisplay: displayText(field: field, canonical: before?[field]),
                afterDisplay: displayText(field: field, canonical: after?[field])
            )
        }
        return LedgerAuditEvent(
            sequence: record.sequence,
            occurredAt: PersistenceTimestamp.date(from: record.occurredAt) ?? .distantPast,
            action: Self.presentedAction(record.action, after: after),
            actor: record.actor,
            markupID: markupID,
            markupSubject: known?.subject,
            pageLabel: known?.pageLabel,
            commandName: record.commandName,
            undoGroup: record.undoGroup,
            note: record.note,
            changes: changes,
            markupName: record.markupId.flatMap { knownMarkupNames[$0] }
                ?? Self.recordedName(before: before, after: after)
        )
    }

    /// The action a row shows: a creation that recorded no quantity is "Added", not "Measured".
    ///
    /// L-99: a Note was logged as "Measured" — every `markup_created` row read that, whether or
    /// not anything was measured. Whether a quantity was recorded is read from the row itself (a
    /// created measurement stores its fields, a note stores only its text), so it holds for a
    /// markup deleted since and for a trail reopened from disk. The stored action is unchanged.
    static func presentedAction(_ action: String, after: [String: String]?) -> String {
        guard action == MeasurementAuditAction.markupCreated.rawValue else { return action }
        let measured = (after ?? [:]).keys.contains { ZPDFContracts.MeasurementField(rawValue: $0) != nil }
        return measured ? action : LedgerAuditEvent.markupAddedAction
    }

    /// The author name in force right now, for the entry being written.
    private var resolvedActorName: String {
        let provided = actorNameProvider?() ?? actorName
        return provided.isEmpty ? actorName : provided
    }

    /// A canonical decimal string rendered exactly as the ledger would render the same
    /// value — display unit, display precision, locale separators, unit symbol
    /// — so History rows read like sentences. `nil` for a field this build does not know,
    /// whose raw value then shows as itself rather than disappearing.
    private func displayText(field: String, canonical: String?) -> String? {
        if let review = ReviewAuditFields.displayValue(key: field, value: canonical) { return review }
        guard let canonical,
              let dimension = Self.fieldDimension(field),
              let value = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return formatter.textWithUnit(Shown.Quantity(value: value, dimension: dimension))
    }

    /// The display dimension of a stored field key.
    ///
    /// The presentation field enum is the first source, and the contract's own field enum the
    /// fallback: the engine emits four values — true perimeter, cutout area, plan wall area and
    /// net wall area — that the presentation enum has no case for, and those used to render as
    /// the raw canonical SI string with no unit beside neighbours formatted in the person's
    /// units, so an imperial user read `12.345` (m²) next to `Area 132.9 ft²` (BH-109).
    static func fieldDimension(_ field: String) -> Shown.Dimension? {
        if let shown = Shown.Field(rawValue: field) { return shown.dimension }
        guard let domain = Domain.Field(rawValue: field) else { return nil }
        return Shown.Dimension(domain: domain.dimension)
    }

    /// The column-style name of a stored field key, including the four contract fields the
    /// presentation enum lacks. `nil` only for a key this build does not know at all.
    static func fieldDisplayName(_ field: String) -> String? {
        if let review = ReviewAuditFields.displayName(of: field) { return review }
        if let shown = Shown.Field(rawValue: field) { return shown.displayName }
        switch Domain.Field(rawValue: field) {
        case .truePerimeter?:
            return NSLocalizedString("True Perimeter", comment: "Measurement field name")
        case .cutoutArea?:
            return NSLocalizedString("Cutout Area", comment: "Measurement field name")
        case .planWallArea?:
            return NSLocalizedString("Plan Wall Area", comment: "Measurement field name")
        case .netWallArea?:
            return NSLocalizedString("Net Wall Area", comment: "Measurement field name")
        default:
            return nil
        }
    }

    /// Page labels, and a lazily built index of the snapshot's markups, for one recording.
    ///
    /// Built once per recorded step. The lookup it replaces was a linear `first(where:)` over
    /// every markup in the document *per affected markup*, on the main actor inside the
    /// command bus — O(affected × markups), so a select-all status change on a 50 000-markup
    /// takeoff was billions of comparisons (BH-111).
    ///
    /// A class, so the lazily built index is built once and shared by every lookup of the
    /// recording rather than rebuilt inside each copy.
    final class NameContext {
        let pageLabels: [UUID: String]
        private let snapshot: DocumentSnapshot
        private var index: [UUID: Int]?

        init(snapshot: DocumentSnapshot) {
            self.snapshot = snapshot
            var labels: [UUID: String] = [:]
            for page in snapshot.pages where labels[page.id] == nil { labels[page.id] = page.label }
            self.pageLabels = labels
        }

        func summary(of id: UUID) -> ZPDFUIPresentation.MarkupSummary? {
            if index == nil {
                var built: [UUID: Int] = [:]
                built.reserveCapacity(snapshot.markups.count)
                for (offset, markup) in snapshot.markups.enumerated() where built[markup.id] == nil {
                    built[markup.id] = offset
                }
                index = built
            }
            return index?[id].map { snapshot.markups[$0] }
        }
    }

    /// A markup as a History row names it: its tool or kind ("Area", "Text", "Image") and, when
    /// it has one, its label — "Area R-1", or the label alone when it already says the kind
    /// ("Length A"). Every row used to read only its page, so a text box's "Edited" and an
    /// image's "Deleted" could not be told apart (L-79).
    nonisolated static func markupName(kind: Shown.Markup, tool: Shown.Kind?, label: String) -> String {
        let kindName = tool?.displayName ?? kind.displayName
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return kindName }
        if label.range(of: kindName, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return label }
        return String(
            format: NSLocalizedString(
                "history.markupName",
                value: "%1$@ %2$@",
                comment: "History row: a markup's tool or kind, then its label, e.g. Area R-1"
            ),
            kindName, label
        )
    }

    nonisolated static func markupName(of record: ZPDFContracts.MarkupRecord) -> String {
        markupName(kind: Shown.Markup(domain: record.kind), tool: record.tool.map { Shown.Kind(domain: $0) }, label: record.label)
    }

    nonisolated static func markupName(of summary: ZPDFUIPresentation.MarkupSummary) -> String {
        markupName(kind: summary.kind, tool: summary.measurementKind, label: summary.label)
    }

    /// Remembers the subject and page a row will be shown under.
    ///
    /// The command's own records win: the forward (after) state first, then the inverse
    /// (before) state for a deletion. The snapshot handed in is the document *before* the
    /// command — the bus records the audit entry before it publishes — so preferring it
    /// filed a subject rename under the old subject until some later command happened to
    /// touch the markup (BH-087, BH-110). The snapshot is the last resort only.
    private func rememberSubject(
        of markupID: MarkupID,
        inverse: DocumentCommandInverse,
        forward: DocumentCommandInverse,
        names: NameContext
    ) {
        let key = markupID.rawValue.uuidString
        if let record = (forward.markups[markupID] ?? nil) ?? (inverse.markups[markupID] ?? nil) {
            knownMarkups[key] = (record.subject, names.pageLabels[record.pageID.rawValue] ?? "")
            knownMarkupNames[key] = Self.markupName(of: record)
            return
        }
        if let summary = names.summary(of: markupID.rawValue) {
            knownMarkups[key] = (summary.subject, summary.pageLabel)
            knownMarkupNames[key] = Self.markupName(of: summary)
        }
    }

    /// Learns the subject and page of every markup in the document as it stands now.
    ///
    /// The subject cache used to be filled only at record time, so a reopened project's
    /// History read every row without a subject or a page, and the page filter had no options
    /// at all (BH-108). The environment calls this with each adopted snapshot; a markup
    /// deleted in an earlier session keeps whatever this session learned about it, and the
    /// trail is republished only when a name actually changed.
    public func noteMarkupNames(from snapshot: DocumentSnapshot) {
        var pageLabels: [UUID: String] = [:]
        for page in snapshot.pages where pageLabels[page.id] == nil { pageLabels[page.id] = page.label }
        var renamed: Set<UUID> = []
        for markup in snapshot.markups {
            let key = markup.id.uuidString
            let label = pageLabels[markup.pageID] ?? markup.pageLabel
            let name = Self.markupName(of: markup)
            if let known = knownMarkups[key], known.subject == markup.subject, known.pageLabel == label,
               knownMarkupNames[key] == name {
                continue
            }
            knownMarkups[key] = (markup.subject, label)
            knownMarkupNames[key] = name
            renamed.insert(markup.id)
        }
        guard !renamed.isEmpty, !events.isEmpty else { return }
        // Only the rows of the renamed markups, and only their names: the values are already
        // rendered. This republished the whole trail — every row decoded again — whenever any
        // name changed, and a newly added markup counts as one (R-052).
        if let patched = patchingNames(of: renamed, in: events) { events = patched }
    }

    /// `field -> canonical decimal string` for one record's measured values, in the same
    /// grammar the ledger stores (ADR-0007 §4), plus the review fields that differ from the
    /// other side of the change as `review.*` text (ADR-0021 (collaboration)).
    ///
    /// Review fields are written only where they changed — or, for a creation or deletion,
    /// where they hold something — so a move does not repeat the note on every row, while a
    /// status change says "Open → Accepted" and a note edit says what the note was and became.
    /// Before this, a status, notes, label, subject or lock change wrote no values at all, and
    /// on a markup with no measurement the row carried nothing (bug AppHistoryPresenter:768).
    static func values(
        of record: ZPDFContracts.MarkupRecord?,
        comparedWith other: ZPDFContracts.MarkupRecord?
    ) -> [String: String]? {
        guard let record else { return nil }
        var values: [String: String] = [:]
        if let measurement = record.measurement {
            for (field, quantity) in measurement.values {
                guard let canonical = DecimalString(quantity.value) else { continue }
                values[field.rawValue] = canonical.canonicalText
            }
        }
        let own = ReviewAuditFields.values(of: record)
        let theirs = other.map(ReviewAuditFields.values(of:))
        for (key, value) in own {
            if let theirs {
                guard theirs[key] != value else { continue }
            } else if ReviewAuditFields.isDefault(key: key, value: value) {
                continue
            }
            values[key] = value
        }
        // A field present on the other side and absent here (an emptied note) is written as
        // the empty string, so the change reads "Check the slab → (empty)".
        if let theirs {
            for key in theirs.keys where own[key] == nil { values[key] = "" }
        }
        // A creation and a deletion carry the markup's name, as its History rows name it, so a
        // reopened trail still names a markup deleted in an earlier session, which no snapshot
        // has any more (L-79). Never on an edit's two sides: it is not a value that changes.
        if other == nil {
            values[recordedNameField] = ReviewAuditFields.bounded(markupName(of: record))
        }
        return values.isEmpty ? nil : values
    }

    /// The values key a creation or a deletion stores the markup's name under (L-79). It rides
    /// the review prefix, the store's door for plain text, and is read back as the row's
    /// ``LedgerAuditEvent/markupName`` — never listed as a change.
    nonisolated static let recordedNameField = MeasurementAuditStore.reviewFieldPrefix + "markupName"

    /// The name a row recorded for its markup, if it recorded one.
    nonisolated static func recordedName(before: [String: String]?, after: [String: String]?) -> String? {
        let name = (after?[recordedNameField] ?? before?[recordedNameField])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// Learns the names rows recorded for markups this session knows nothing about — a markup
    /// deleted before the project was last closed — so every row about it is named, the ones
    /// written before the name was, too. A name learned from a record or a snapshot wins.
    private func learnRecordedNames(from records: [MeasurementAuditRecord]) {
        for record in records {
            guard let id = record.markupId, knownMarkupNames[id] == nil else { continue }
            // Only the rows that carry a name are decoded twice; most rows carry none.
            guard record.afterValuesJson?.contains(Self.recordedNameField) == true
                    || record.beforeValuesJson?.contains(Self.recordedNameField) == true else { continue }
            let before = (try? MeasurementAuditStore.decodeValues(record.beforeValuesJson)) ?? nil
            let after = (try? MeasurementAuditStore.decodeValues(record.afterValuesJson)) ?? nil
            if let name = Self.recordedName(before: before, after: after) { knownMarkupNames[id] = name }
        }
    }
}
