import Foundation
import GRDB
import Observation
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// Review threads: replies on a markup, each with its own author and time, and the thread the
/// Comments tab shows (NL-COLLAB-01/02, ADR-0021 (collaboration)).
///
/// ### What a thread is made of
///
/// - **The note** — the markup's `comment`, the Inspector's Notes. Its author and time come
///   from the History row that last wrote it (the `review.comment` value, ADR-0021), not from
///   the markup's author and last-modified time: those named A for a note B wrote on A's markup,
///   and moved the date whenever the markup was dragged (bug InspectorCommentsTab:31).
/// - **Replies** — `review_entry` rows, written through this presenter.
/// - **Status changes** — the History rows whose `review.status` changed, so a status change is
///   recorded once, in the append-only trail, and the thread and the History can never disagree.
///
/// ### Persistence and undo
///
/// A reply is written straight into the project database, the way the History trail is — the
/// database is edited in place and a save snapshots it — and it is one step on the document's
/// undo stack: ⌘Z removes the last reply only, ⇧⌘Z puts back the same row. Withdrawing a reply is
/// a tombstone, also undoable. Nothing here touches `MarkupRecord` or the takeoff session, so no
/// frozen contract and no `DocumentCommandInverse` field changed; ADR-0021 records why.
@MainActor
@Observable
public final class AppReviewPresenter: ReviewThreadPresenting {

    /// Bumped on every change a thread could show.
    public private(set) var threadRevision = 0

    /// Every reply in the project, oldest first.
    public private(set) var entries: [ReviewEntryRecord] = []

    /// Who replies are signed as, read per reply so a Settings change signs the next one only.
    @ObservationIgnored
    public var actorNameProvider: (@MainActor () -> String)?

    /// The clock replies are stamped with. Injected by tests.
    @ObservationIgnored
    public var now: @MainActor () -> Date = { Date() }

    /// The History, for the note's attribution and the status changes.
    @ObservationIgnored
    public weak var history: AppHistoryPresenter?

    /// Every markup of the document, read from the environment's snapshot (observable there).
    @ObservationIgnored
    public var markupsProvider: (@MainActor () -> [MarkupSummary])?

    public var reviewMarkups: [MarkupSummary] { markupsProvider?() ?? [] }

    /// The ledger's per-subject totals as they stand now (W-027): what a review round stores
    /// when it closes and what its comparison is taken against. Installed by the document's own
    /// environment; `nil` leaves a round comparing by the History alone.
    @ObservationIgnored
    var ledgerTotalsProvider: (@MainActor () -> ReviewRoundTotals?)?

    /// Whether a project database is attached. Without one, no reply can be kept, so none is
    /// accepted.
    public var isAttached: Bool { database != nil }

    // MARK: - Author directory (NL-COLLAB-05, schema v16)

    /// This installation's person, as the app knows it: a stable id, an optional company and an
    /// optional avatar colour. `nil` until the app installs it; the directory then stays empty.
    public struct LocalAuthor: Sendable, Equatable {
        public var id: String
        public var company: String?
        public var colorRGBA: String?
        public init(id: String, company: String? = nil, colorRGBA: String? = nil) {
            self.id = id
            self.company = company
            self.colorRGBA = colorRGBA
        }
    }

    @ObservationIgnored
    public var localAuthorProvider: (@MainActor () -> LocalAuthor)?

    /// Everyone who has signed something in this project, by name.
    public private(set) var authors: [AuthorRecord] = []

    /// The company a signed name belongs to, from the directory (the newest entry for that name).
    public func company(of name: String) -> String? {
        authors.filter { $0.displayName == name }.max { $0.lastSeen < $1.lastSeen }?.company.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "A. Berg, North Build" — a name with its company when the directory knows one.
    public func signature(of name: String) -> String {
        guard let company = company(of: name) else { return name }
        return String(format: NSLocalizedString("%1$@, %2$@", comment: "An author's name followed by their company"), name, company)
    }

    /// Records this person in the directory — on attach and whenever they sign a reply — so a
    /// colleague opening the project sees their company.
    public func recordLocalAuthor() {
        guard let database, let local = localAuthorProvider?() else { return }
        let name = currentAuthor
        let stamp = PersistenceTimestamp.string(from: now())
        let initials = Self.initials(of: name)
        let record = AuthorRecord(id: local.id, projectId: projectID, displayName: name, initials: initials,
                                  colorRGBA: local.colorRGBA, company: local.company, firstSeen: stamp, lastSeen: stamp)
        let project = projectID
        let previous = pendingWrites
        writeGeneration &+= 1
        pendingWrites = Task { @MainActor [weak self] in
            await previous?.value
            let loaded = try? await database.write { db -> [AuthorRecord] in
                try AuthorDirectoryStore.upsert(record, in: db)
                return try AuthorDirectoryStore.authors(project: project, in: db)
            }
            if let loaded { self?.authors = loaded; self?.bump() }
        }
    }

    /// Up to two initials, the one rule the top bar and the Inspector draw (S-053).
    nonisolated static func initials(of name: String) -> String {
        AuthorInitials.initials(for: name)
    }

    @ObservationIgnored private let undoManager: UndoManager
    @ObservationIgnored private var database: ProjectDatabaseActor?
    @ObservationIgnored private var projectID = ""
    @ObservationIgnored private var pendingWrites: Task<Void, Never>?
    @ObservationIgnored private var writeGeneration = 0

    public init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    // MARK: - Store lifecycle

    /// Points the threads at a project database and reloads them.
    public func attach(database: ProjectDatabaseActor, projectID: String) {
        self.database = database
        self.projectID = projectID
        let pending = pendingRecords.map { record -> ReviewEntryRecord in
            var filed = record
            filed.projectId = projectID
            return filed
        }
        pendingRecords = []
        enqueue { db, project in
            for record in pending { try ReviewEntryStore.upsert(record, in: db) }
            return try ReviewEntryStore.entries(project: project, in: db)
        }
        recordLocalAuthor()
    }

    /// Carries every reply into another database — Create Project — and reads from it after.
    public func migrate(
        from oldDatabase: ProjectDatabaseActor?,
        oldProjectID: String,
        to newDatabase: ProjectDatabaseActor,
        newProjectID: String
    ) {
        database = newDatabase
        projectID = newProjectID
        let previous = pendingWrites
        let revision = localWriteRevision
        writeGeneration &+= 1
        pendingWrites = Task { @MainActor [weak self] in
            await previous?.value
            do {
                var carried: [ReviewEntryRecord] = []
                if let oldDatabase {
                    carried = try await oldDatabase.read { db in
                        try ReviewEntryStore.entries(project: oldProjectID, in: db)
                    }
                }
                let rows = carried
                let loaded = try await newDatabase.write { db -> [ReviewEntryRecord] in
                    try ReviewEntryStore.carryOver(rows, into: newProjectID, in: db)
                    return try ReviewEntryStore.entries(project: newProjectID, in: db)
                }
                self?.publishUnlessOvertaken(loaded, readAt: revision)
            } catch {
                // The in-memory threads stay on screen.
            }
        }
    }

    /// Awaits every queued write — how tests get a settled store.
    public func settle() async {
        while let task = pendingWrites {
            let generation = writeGeneration
            await task.value
            guard writeGeneration == generation else { continue }
            pendingWrites = nil
        }
    }

    // MARK: - Writing

    @discardableResult
    public func addReply(_ body: String, to markupID: UUID) -> UUID? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard database != nil, !text.isEmpty, text.utf8.count <= ReviewEntryStore.maximumBodyBytes else {
            return nil
        }
        let id = UUID()
        let provided = actorNameProvider?() ?? NSFullUserName()
        let record = ReviewEntryRecord(
            id: id.uuidString,
            projectId: projectID,
            markupId: markupID.uuidString,
            authorName: provided.isEmpty ? NSUserName() : provided,
            body: text,
            createdAt: PersistenceTimestamp.string(from: now())
        )
        insert(record, actionName: Self.addReplyActionName)
        return id
    }

    /// The same reply on several markups, as one undoable step — a status note over a selection.
    @discardableResult
    public func addReplies(_ body: String, to markupIDs: Set<UUID>) -> Int {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard database != nil, !text.isEmpty, !markupIDs.isEmpty,
              text.utf8.count <= ReviewEntryStore.maximumBodyBytes else { return 0 }
        let stamp = PersistenceTimestamp.string(from: now())
        let author = currentAuthor
        let records = markupIDs.sorted { $0.uuidString < $1.uuidString }.map { id in
            ReviewEntryRecord(id: UUID().uuidString, projectId: projectID, markupId: id.uuidString,
                              authorName: author, body: text, createdAt: stamp)
        }
        insertBatch(records, actionName: Self.addReplyActionName)
        return records.count
    }

    public func retractReply(_ replyID: UUID) {
        guard database != nil,
              let current = entries.first(where: { $0.id == replyID.uuidString }),
              !current.retracted
        else { return }
        setRetracted(current.id, to: true, actionName: Self.retractActionName)
    }

    // MARK: - Activity (NL-COLLAB-15)

    /// The feed, newest first.
    public internal(set) var activityItems: [ReviewActivityItem] = []
    public var activity: [ReviewActivityItem] { activityItems }

    /// Told about new activity items — the app posts a local notification when the person
    /// has asked for them. Never called for this person's own operations.
    @ObservationIgnored
    public var onActivity: (@MainActor ([ReviewActivityItem]) -> Void)?

    public func markActivityRead() {
        for index in activityItems.indices { activityItems[index].isRead = true }
        bump()
    }

    func bumpActivity() { bump() }

    // MARK: - Since you last looked (NL-COLLAB-14)

    /// The newest History sequence when this person last opened the project; set by the app from
    /// its own per-project preference. `nil` means "never looked", which marks nothing new.
    public var lastSeenSequence: Int? {
        didSet { bump() }
    }

    /// Markups a shared-review sync or an import changed, not yet looked at.
    public private(set) var changedElsewhere: Set<UUID> = []

    /// Told whenever ``changedElsewhere`` changes, so the app can keep it across launches.
    @ObservationIgnored
    public var onChangedElsewhere: (@MainActor (Set<UUID>) -> Void)?

    public func markChangedElsewhere(_ ids: some Sequence<UUID>) {
        let before = changedElsewhere
        changedElsewhere.formUnion(ids)
        guard changedElsewhere != before else { return }
        bump()
        onChangedElsewhere?(changedElsewhere)
    }

    /// Restores the set the app kept, without telling it back.
    public func restoreChangedElsewhere(_ ids: Set<UUID>) {
        changedElsewhere = ids
        bump()
    }

    public var changedSinceLastLook: Set<UUID> {
        _ = threadRevision
        var result = changedElsewhere
        if let lastSeenSequence, let history {
            let me = myNames
            for record in history.auditRecords where record.sequence > lastSeenSequence && !me.contains(record.actor) {
                if let id = record.markupId.flatMap(UUID.init(uuidString:)) { result.insert(id) }
            }
        }
        return result
    }

    public func markAllSeen() {
        lastSeenSequence = history?.auditRecords.map(\.sequence).max() ?? lastSeenSequence
        changedElsewhere = []
        bump()
        onChangedElsewhere?([])
    }

    // MARK: - Assignments (NL-COLLAB-17)

    /// What an assignment entry's body holds.
    struct AssignmentBody: Codable, Hashable {
        var assignee: String
        var due: String?
    }

    /// Every name this person has signed with; `AuthorIdentity.names()` by default.
    @ObservationIgnored
    public var myNamesProvider: (@MainActor () -> [String])? = { AuthorIdentity.names() }

    public var myNames: Set<String> { Set((myNamesProvider?() ?? []) + [currentAuthor]) }

    public var currentAuthor: String {
        let provided = actorNameProvider?() ?? NSFullUserName()
        return provided.isEmpty ? NSUserName() : provided
    }

    public func assign(_ markupIDs: Set<UUID>, to assignee: String, due: Date?) {
        guard database != nil, !markupIDs.isEmpty else { return }
        let name = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = AssignmentBody(assignee: name, due: due.map(Self.dayString))
        guard let json = try? JSONEncoder().encode(body), let text = String(data: json, encoding: .utf8) else { return }
        let stamp = PersistenceTimestamp.string(from: now())
        let author = currentAuthor
        let records = markupIDs.sorted { $0.uuidString < $1.uuidString }.map { id in
            ReviewEntryRecord(
                id: UUID().uuidString, projectId: projectID, markupId: id.uuidString,
                kind: ReviewEntryRecord.Kind.assignment.rawValue, authorName: author, body: text, createdAt: stamp
            )
        }
        insertBatch(records, actionName: name.isEmpty
            ? NSLocalizedString("Clear Assignment", comment: "Undo action name for clearing who a markup is assigned to")
            : NSLocalizedString("Assign", comment: "Undo action name for assigning markups to a person"))
    }

    public func assignment(for markupID: UUID) -> ReviewAssignment? {
        assignmentIndex()[markupID.uuidString]
    }

    /// Every markup's latest live assignment, decoded once per change of the entries (T-059).
    ///
    /// `assignment(for:)` used to scan every entry, decode the JSON body and build a
    /// `DateFormatter` on each call, and the Review List asks once per row on every render — each
    /// keystroke in its search field cost O(markups × entries) plus the decoding.
    private struct AssignmentIndex {
        let revision: Int
        let byMarkup: [String: ReviewAssignment]
    }

    @ObservationIgnored
    private var cachedAssignmentIndex: AssignmentIndex?

    /// How many times the assignment index was rebuilt. Test evidence for T-059.
    @ObservationIgnored
    private(set) var assignmentIndexBuildCount = 0

    private func assignmentIndex() -> [String: ReviewAssignment] {
        // Read even when the cache answers, so a view that asked is told when an entry changes:
        // every change to `entries` bumps the revision.
        let revision = threadRevision
        if let cached = cachedAssignmentIndex, cached.revision == revision { return cached.byMarkup }
        let kind = ReviewEntryRecord.Kind.assignment.rawValue
        var latest: [String: ReviewEntryRecord] = [:]
        // Entries are oldest first, so the last live assignment of a markup wins — exactly the
        // `entries.last(where:)` this replaces, including a cleared (empty) one hiding an older.
        for entry in entries where entry.kind == kind && !entry.retracted {
            latest[entry.markupId] = entry
        }
        var byMarkup: [String: ReviewAssignment] = [:]
        for (key, entry) in latest {
            guard let body = Self.assignmentBody(entry), !body.assignee.isEmpty else { continue }
            byMarkup[key] = ReviewAssignment(
                assignee: body.assignee,
                due: body.due.flatMap(Self.day(from:)),
                assignedBy: entry.authorName,
                assignedAt: PersistenceTimestamp.date(from: entry.createdAt) ?? Date(timeIntervalSince1970: 0)
            )
        }
        assignmentIndexBuildCount += 1
        cachedAssignmentIndex = AssignmentIndex(revision: revision, byMarkup: byMarkup)
        return byMarkup
    }

    static func assignmentBody(_ entry: ReviewEntryRecord) -> AssignmentBody? {
        try? JSONDecoder().decode(AssignmentBody.self, from: Data(entry.body.utf8))
    }

    /// A due date is a calendar day, stored as `yyyy-MM-dd` so it means the same day everywhere.
    static func dayString(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }

    static func day(from text: String) -> Date? {
        dayFormatter().date(from: text)
    }

    /// The one `yyyy-MM-dd` formatter. A new one was built for every call — per row, per render
    /// of the Review List (T-059).
    private static let sharedDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The shared formatter in the current time zone: a due date is a day where the person is,
    /// so a time-zone change is followed as the per-call formatter followed it.
    private static func dayFormatter() -> DateFormatter {
        let zone = TimeZone.current
        if sharedDayFormatter.timeZone != zone { sharedDayFormatter.timeZone = zone }
        return sharedDayFormatter
    }

    func insertBatch(_ records: [ReviewEntryRecord], actionName: String) {
        if records.contains(where: { $0.authorName == currentAuthor }) { recordLocalAuthor() }
        entries.append(contentsOf: records)
        entries.sort(by: Self.chronological)
        bump()
        enqueueWrite { db in for record in records { try ReviewEntryStore.upsert(record, in: db) } }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.removeBatch(records, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func removeBatch(_ records: [ReviewEntryRecord], actionName: String) {
        let ids = Set(records.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        bump()
        enqueueWrite { db in for id in ids { try ReviewEntryStore.remove(id: id, in: db) } }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.insertBatch(records, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    static var addReplyActionName: String {
        NSLocalizedString("Add Reply", comment: "Undo action name for replying on a markup")
    }

    static var retractActionName: String {
        NSLocalizedString("Withdraw Reply", comment: "Undo action name for withdrawing a reply on a markup")
    }

    private func insert(_ record: ReviewEntryRecord, actionName: String) {
        if record.authorName == currentAuthor { recordLocalAuthor() }
        entries.append(record)
        entries.sort(by: Self.chronological)
        bump()
        enqueueWrite { db in try ReviewEntryStore.upsert(record, in: db) }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.remove(record, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func remove(_ record: ReviewEntryRecord, actionName: String) {
        entries.removeAll { $0.id == record.id }
        bump()
        let id = record.id
        enqueueWrite { db in try ReviewEntryStore.remove(id: id, in: db) }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.insert(record, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func setRetracted(_ id: String, to retracted: Bool, actionName: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let stamp = PersistenceTimestamp.string(from: now())
        entries[index].retracted = retracted
        entries[index].editedAt = stamp
        bump()
        enqueueWrite { db in
            try ReviewEntryStore.setRetracted(id: id, retracted: retracted, editedAt: stamp, in: db)
        }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setRetracted(id, to: !retracted, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    /// The project the threads are filed under.
    var currentProjectID: String { projectID }

    /// Records that arrived before a database was attached: kept on screen, written on attach.
    @ObservationIgnored private var pendingRecords: [ReviewEntryRecord] = []

    /// Adds records that are not the local person's own action — an import — with no undo step.
    /// Before a database is attached (a document still opening) they are kept and written as soon
    /// as it is, never dropped.
    func recordWithoutUndo(_ records: [ReviewEntryRecord]) {
        guard !records.isEmpty else { return }
        guard database != nil else {
            pendingRecords.append(contentsOf: records)
            entries.append(contentsOf: records)
            entries.sort(by: Self.chronological)
            bump()
            return
        }
        entries.append(contentsOf: records)
        entries.sort(by: Self.chronological)
        bump()
        enqueueWrite { db in
            for record in records { try ReviewEntryStore.upsert(record, in: db) }
        }
    }

    /// Sets a reply's tombstone without an undo step (another participant's withdrawal).
    func applyRetraction(_ id: String, _ retracted: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].retracted != retracted else { return }
        let stamp = PersistenceTimestamp.string(from: now())
        entries[index].retracted = retracted
        entries[index].editedAt = stamp
        bump()
        enqueueWrite { db in
            try ReviewEntryStore.setRetracted(id: id, retracted: retracted, editedAt: stamp, in: db)
        }
    }

    // MARK: - Reading

    /// Every markup's audit events and replies, indexed once per change (R-053). `thread(for:)`
    /// used to filter the whole trail and every reply for each markup, so the Review List and
    /// the review report cost O(markups × (events + replies)) on the main actor.
    private struct ThreadIndex {
        let revision: Int
        let historyOwner: ObjectIdentifier?
        let historyGeneration: Int
        let events: [UUID: [LedgerAuditEvent]]
        let entries: [String: [ReviewEntryRecord]]
    }

    @ObservationIgnored
    private var cachedThreadIndex: ThreadIndex?

    private func threadIndex() -> ThreadIndex {
        // Read even when the cache answers, so a view that asked is told when the trail changes.
        let events = history?.events ?? []
        let owner = history.map(ObjectIdentifier.init)
        let generation = history?.eventsGeneration ?? 0
        if let cached = cachedThreadIndex, cached.revision == threadRevision,
           cached.historyOwner == owner, cached.historyGeneration == generation {
            return cached
        }
        var byMarkup: [UUID: [LedgerAuditEvent]] = [:]
        for event in events {
            if let id = event.markupID { byMarkup[id, default: []].append(event) }
        }
        var repliesByMarkup: [String: [ReviewEntryRecord]] = [:]
        for entry in entries { repliesByMarkup[entry.markupId, default: []].append(entry) }
        let index = ThreadIndex(
            revision: threadRevision, historyOwner: owner, historyGeneration: generation,
            events: byMarkup, entries: repliesByMarkup
        )
        cachedThreadIndex = index
        return index
    }

    public func thread(for markup: MarkupSummary) -> ReviewThread {
        _ = threadRevision
        let index = threadIndex()
        let history = index.events[markup.id] ?? []
        var items: [(order: Int, item: ReviewThreadItem)] = []

        let note = markup.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            let attribution = Self.noteAttribution(comment: markup.comment, history: history)
            items.append((0, ReviewThreadItem(
                id: "note-\(markup.id.uuidString)",
                kind: .note,
                author: attribution?.author ?? "",
                date: attribution?.date,
                text: note
            )))
        }

        for event in history {
            guard let change = event.changes.first(where: { $0.field == ReviewAuditFields.status }) else { continue }
            let reverted = event.action == MeasurementAuditAction.compensated.rawValue
                || event.action == MeasurementAuditAction.recompensated.rawValue
            items.append((1, ReviewThreadItem(
                id: "status-\(event.sequence)",
                kind: .statusChange(
                    from: Self.shownStatus(change.before),
                    to: Self.shownStatus(change.after),
                    reverted: reverted
                ),
                author: event.actor,
                date: event.occurredAt,
                text: event.note ?? ""
            )))
        }

        let key = markup.id.uuidString
        for entry in index.entries[key] ?? [] {
            if entry.kind == ReviewEntryRecord.Kind.assignment.rawValue {
                guard let body = Self.assignmentBody(entry) else { continue }
                items.append((2, ReviewThreadItem(
                    id: "assign-\(entry.id)",
                    kind: .assignment(assignee: body.assignee, due: body.due.flatMap(Self.day(from:))),
                    author: entry.authorName,
                    date: PersistenceTimestamp.date(from: entry.createdAt),
                    text: ""
                )))
                continue
            }
            items.append((2, ReviewThreadItem(
                id: "reply-\(entry.id)",
                kind: .reply,
                author: entry.authorName,
                date: PersistenceTimestamp.date(from: entry.createdAt),
                text: entry.body,
                isRetracted: entry.retracted,
                replyID: UUID(uuidString: entry.id)
            )))
        }

        let ordered = items.enumerated().sorted { lhs, rhs in
            let left = lhs.element.item.date ?? .distantPast
            let right = rhs.element.item.date ?? .distantPast
            if left != right { return left < right }
            if lhs.element.order != rhs.element.order { return lhs.element.order < rhs.element.order }
            return lhs.offset < rhs.offset
        }.map(\.element.item)
        return ReviewThread(markupID: markup.id, items: ordered, history: history)
    }

    /// Who wrote the note as it stands, and when: the newest History row — not an undo or a
    /// redo — whose `review.comment` became exactly this text. An undo puts back an earlier
    /// text, and the row that first wrote that text is the one that names its author.
    static func noteAttribution(
        comment: String,
        history: [LedgerAuditEvent]
    ) -> (author: String, date: Date)? {
        for event in history.reversed() {
            if event.action == MeasurementAuditAction.compensated.rawValue
                || event.action == MeasurementAuditAction.recompensated.rawValue { continue }
            guard let change = event.changes.first(where: { $0.field == ReviewAuditFields.comment }),
                  change.after == comment
            else { continue }
            return (event.actor, event.occurredAt)
        }
        return nil
    }

    static func shownStatus(_ raw: String?) -> ZPDFUIPresentation.MarkupStatus? {
        guard let raw, let domain = ZPDFContracts.MarkupStatus(rawValue: raw) else { return nil }
        return ZPDFUIPresentation.MarkupStatus(domain: domain)
    }

    // MARK: - Internals

    private static func chronological(_ lhs: ReviewEntryRecord, _ rhs: ReviewEntryRecord) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id < rhs.id
    }

    private func bump() { threadRevision &+= 1 }

    private func publish(_ loaded: [ReviewEntryRecord]) {
        entries = loaded.sorted(by: Self.chronological)
        bump()
    }

    /// A write that does not reload: the in-memory list is already what the row says.
    private func enqueueWrite(_ work: @Sendable @escaping (Database) throws -> Void) {
        guard let database else { return }
        localWriteRevision &+= 1
        let previous = pendingWrites
        writeGeneration &+= 1
        pendingWrites = Task { @MainActor in
            await previous?.value
            do {
                try await database.write { db in try work(db) }
            } catch {
                // The reply stays on screen; the next attach re-reads what the file holds.
            }
        }
    }

    /// Counts local writes. A reload that was queued before one and read before it landed would
    /// publish a list without it — a reply typed while the project was still opening vanished from
    /// the thread (and from the annotated export) until the next open. Such a reload reads again.
    @ObservationIgnored private var localWriteRevision = 0

    private func publishUnlessOvertaken(_ loaded: [ReviewEntryRecord], readAt revision: Int) {
        guard localWriteRevision == revision else {
            enqueue { db, project in try ReviewEntryStore.entries(project: project, in: db) }
            return
        }
        publish(loaded)
    }

    private func enqueue(_ work: @Sendable @escaping (Database, String) throws -> [ReviewEntryRecord]) {
        guard let database else { return }
        let project = projectID
        let previous = pendingWrites
        let revision = localWriteRevision
        writeGeneration &+= 1
        pendingWrites = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let loaded = try await database.write { db in try work(db, project) }
                self?.publishUnlessOvertaken(loaded, readAt: revision)
            } catch {
                // Nothing to show beyond what is already on screen.
            }
        }
    }
}
