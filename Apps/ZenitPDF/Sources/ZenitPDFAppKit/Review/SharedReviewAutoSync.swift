import AppKit
import ZPDFAppCore
import ZPDFCollaboration

/// The Shared Review Folder, watched (NL-COLLAB-12, round 2): changes flow both ways on their own
/// once a project is connected, and the window says who else is looking and at which sheet.
///
/// Two signals start a sync, and nothing else does:
///
/// - **someone else wrote.** A file presenter on the folder's `participants/` directory hears the
///   write when the file system reports it; a poll every ``pollInterval`` seconds compares every
///   other participant's log by name, size and date, because sync clients do not always deliver
///   file events. Reading a byte is left to the sync itself, through the file coordinator.
/// - **this person changed something**: a markup, a reply, a page scale.
///
/// Presence is a heartbeat: the person's presence file is rewritten at most every
/// ``heartbeatInterval`` seconds, or when their sheet changes, so a synced folder is not asked to
/// upload a file every few seconds. Others are shown while their heartbeat is younger than
/// ``presenceFreshness``.
///
/// Every sync is the same one File ▸ Sync Shared Review runs, in quiet mode: a refusal is a
/// note, never a dialogue, and a sync that brought nothing posts nothing.
@MainActor
final class SharedReviewAutoSync: NSObject, NSFilePresenter {

    static var pollInterval: TimeInterval = 4
    static var heartbeatInterval: TimeInterval = 30
    static var presenceFreshness: TimeInterval = 120
    /// Whether connecting or opening a connected project starts watching. On in the assembled
    /// application; a test starts a watcher itself.
    static var automaticStart = ZenitProcessDefaults.isAssembledApplication

    private static var running: [ObjectIdentifier: SharedReviewAutoSync] = [:]

    weak var document: ZenitPDFProjectDocument?
    let folder: URL
    let participant: String
    nonisolated let presentedItemURL: URL?
    nonisolated let presentedItemOperationQueue: OperationQueue = .main

    private var timer: Timer?
    private var lastFingerprint: [String: String]?
    /// The document's ``ZenitPDFProjectDocument/localChangeRevision`` as the last sync left it.
    private var lastLocalRevision: Int?
    private var lastHeartbeat = Date.distantPast
    private var lastLookingAt: String?
    private var isSyncing = false
    private var wantsAnotherPass = false
    /// Syncs that failed in a row since the last one that ran, and the time before which the
    /// next retry waits (U-009): a paused sync is retried, a little less often each time.
    private(set) var consecutiveFailures = 0
    private(set) var retryNotBefore = Date.distantPast
    /// The longest wait between retries of a failed sync.
    static var maximumRetryInterval: TimeInterval = 60
    /// Everyone else whose heartbeat is fresh, newest first.
    private(set) var others: [SharedReviewFolder.Presence] = []
    /// Syncs this watcher has run. Test observability.
    private(set) var syncCount = 0

    /// The key this watcher is registered under: the document is weak, so once it is gone the
    /// watcher still has to find and remove its own entry (R-030).
    private let key: ObjectIdentifier

    private init(document: ZenitPDFProjectDocument, folder: URL, participant: String) {
        self.document = document
        self.key = ObjectIdentifier(document)
        self.folder = folder
        self.participant = participant
        self.presentedItemURL = folder.appendingPathComponent(SharedReviewFolder.participantsDirectory, isDirectory: true)
        super.init()
    }

    // MARK: - Lifecycle

    /// Starts watching `folder` for `document`, replacing any watcher it had.
    @discardableResult
    static func start(document: ZenitPDFProjectDocument, folder: URL, participant: String, registersPresenter: Bool = true) -> SharedReviewAutoSync {
        stop(document: document)
        let watcher = SharedReviewAutoSync(document: document, folder: folder, participant: participant)
        running[ObjectIdentifier(document)] = watcher
        if registersPresenter { NSFileCoordinator.addFilePresenter(watcher) }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak watcher] _ in
            Task { @MainActor in await watcher?.tick() }
        }
        timer.tolerance = pollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        watcher.timer = timer
        return watcher
    }

    static func stop(document: ZenitPDFProjectDocument) {
        // A watcher starting, the project closing or disconnecting ends any wait for its folder.
        pendingResumes.removeValue(forKey: ObjectIdentifier(document))?.invalidate()
        guard let watcher = running.removeValue(forKey: ObjectIdentifier(document)) else { return }
        watcher.invalidate()
    }

    /// Stops one watcher by itself, for when its document is already gone.
    private static func stop(watcher: SharedReviewAutoSync) {
        if running[watcher.key] === watcher { running.removeValue(forKey: watcher.key) }
        watcher.invalidate()
    }

    static func watcher(for document: ZenitPDFProjectDocument) -> SharedReviewAutoSync? {
        running[ObjectIdentifier(document)]
    }

    /// Resumes watching when a connected project opens.
    ///
    /// A connected project whose folder cannot be reached right now — a share not mounted, a
    /// drive not plugged in — used to open silently unsynced for the whole session (V-023). It
    /// says so, and waits for the folder: a volume mounting, or a look every
    /// ``resumeRetryInterval`` seconds, retries, and the first time the folder resolves the watch
    /// starts and syncs what changed meanwhile — so the note's "shared when its drive or share
    /// is available again" happens by itself (it5r V-023). File ▸ Sync Shared Review, run
    /// meanwhile, starts the watch too (`SharedReviewCommands.runSync`).
    static func resume(document: ZenitPDFProjectDocument) async {
        guard automaticStart, watcher(for: document) == nil, let package = document.projectPackage else { return }
        let projectID = await package.manifest.projectId
        guard let folder = SharedReviewCommands.folderURL(projectID) else {
            if SharedReviewCommands.isConnected(projectID) {
                document.core?.document.post(SharedReviewCommands.pausedNote(SharedReviewCommands.unreachableFolderReason))
                awaitFolder(document: document, projectID: projectID)
            }
            return
        }
        start(document: document, folder: folder, participant: SharedReviewCommands.participantID)
    }

    // MARK: - Waiting for an unreachable folder (it5r V-023)

    /// How often a project opened with its folder unreachable looks for it again, besides every
    /// volume mount. Resolving a bookmark without mounting is cheap; a share that comes back
    /// without a mount event (a sync client's folder reappearing) is found within this long.
    static var resumeRetryInterval: TimeInterval = 30

    /// One project waiting for its shared review folder.
    @MainActor
    final class PendingResume {
        weak var document: ZenitPDFProjectDocument?
        let projectID: String
        fileprivate var timer: Timer?
        fileprivate var mountObserver: (any NSObjectProtocol)?

        fileprivate init(document: ZenitPDFProjectDocument, projectID: String) {
            self.document = document
            self.projectID = projectID
        }

        fileprivate func invalidate() {
            timer?.invalidate()
            timer = nil
            if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
            mountObserver = nil
        }
    }

    private static var pendingResumes: [ObjectIdentifier: PendingResume] = [:]

    /// The wait for `document`'s folder, while there is one. Test observability.
    static func pendingResume(for document: ZenitPDFProjectDocument) -> PendingResume? {
        pendingResumes[ObjectIdentifier(document)]
    }

    /// Waits for `document`'s folder: a retry on every volume mount and every
    /// ``resumeRetryInterval`` seconds, until it resolves, a watcher starts some other way, or
    /// the project closes or disconnects (``stop(document:)``).
    static func awaitFolder(document: ZenitPDFProjectDocument, projectID: String) {
        let key = ObjectIdentifier(document)
        pendingResumes.removeValue(forKey: key)?.invalidate()
        let pending = PendingResume(document: document, projectID: projectID)
        pending.mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in retryPendingResume(key) }
        }
        let timer = Timer(timeInterval: resumeRetryInterval, repeats: true) { _ in
            Task { @MainActor in retryPendingResume(key) }
        }
        timer.tolerance = resumeRetryInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        pending.timer = timer
        pendingResumes[key] = pending
    }

    /// One retry of a waiting project: starts the watch once the folder resolves, and syncs at
    /// once. Returns whether the project is watched afterwards.
    @discardableResult
    static func retryPendingResume(_ key: ObjectIdentifier) -> Bool {
        guard let pending = pendingResumes[key] else { return false }
        guard let document = pending.document, !document.isClosed, document.projectPackage != nil,
              SharedReviewCommands.isConnected(pending.projectID) else {
            pendingResumes.removeValue(forKey: key)?.invalidate()
            return false
        }
        if watcher(for: document) != nil {
            pendingResumes.removeValue(forKey: key)?.invalidate()
            return true
        }
        // Never mounting a volume or asking for a server's password from a timer: the folder
        // counts as back when it resolves as things stand.
        guard let folder = SharedReviewCommands.folderURL(pending.projectID, mounting: false) else { return false }
        let watcher = start(document: document, folder: folder, participant: SharedReviewCommands.participantID)
        // Back: the paused note comes down, and the first sync publishes what changed meanwhile
        // (it posts the note again if it cannot run).
        document.core?.document.dismissWarning(id: SharedReviewCommands.noteID)
        Task { @MainActor in await watcher.tick() }
        return true
    }

    private func invalidate() {
        timer?.invalidate()
        timer = nil
        NSFileCoordinator.removeFilePresenter(self)
        let document = self.document
        others = []
        document?.windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
    }

    // MARK: - The watch

    nonisolated func presentedSubitemDidChange(at url: URL) {
        Task { @MainActor in await self.tick() }
    }

    nonisolated func presentedItemDidChange() {
        Task { @MainActor in await self.tick() }
    }

    /// One look at the folder and the document: syncs when someone else wrote or something
    /// changed here, refreshes presence, and says so in the window. Returns the sync it ran.
    @discardableResult
    func tick(now: Date = Date()) async -> SharedReviewSync.Report? {
        guard let document, !document.isClosed, let core = document.core, document.projectPackage != nil else {
            // A deallocated document used to leave its watcher, timer and file presenter
            // running, and its address blocked a new document's resume (R-030).
            Self.stop(watcher: self)
            return nil
        }
        if isSyncing {
            wantsAnotherPass = true
            return nil
        }
        let shared = SharedReviewFolder(url: folder)
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let fingerprint = shared.fingerprint(excluding: participant)
        let someoneWrote = lastFingerprint.map { $0 != fingerprint } ?? true
        // A counter the document bumps on every edit, undo and redo, not a hash of every markup
        // every four seconds: idle cost no longer grows with the takeoff (R-036).
        let changedHere = lastLocalRevision.map { $0 != document.localChangeRevision } ?? true
        var report: SharedReviewSync.Report?
        if someoneWrote || changedHere, now >= retryNotBefore {
            isSyncing = true
            let outcome = await SharedReviewCommands.runSync(document: document, quiet: true, participant: participant)
            isSyncing = false
            syncCount += 1
            report = outcome.report
            switch outcome {
            case .failed:
                // The sync failed ("Shared review paused"): nothing was published and nothing
                // merged, so nothing it saw is the new normal (U-009). Recording this revision
                // and fingerprint as synced left the edits made before the failure unpublished
                // until the person edited again. The next poll retries, backing off.
                lastFingerprint = nil
                lastLocalRevision = nil
                consecutiveFailures += 1
                retryNotBefore = now.addingTimeInterval(Self.retryDelay(afterFailures: consecutiveFailures))
            case .notConnected:
                // Nothing to sync with is not a failure: no retry and no backoff, so the next
                // tick is decided by what changes, as for a sync that ran (U-009, R-036).
                consecutiveFailures = 0
                retryNotBefore = .distantPast
                lastFingerprint = fingerprint
                lastLocalRevision = document.localChangeRevision
            case .synced(let report):
                // Resumed: the "paused" note comes down, unless this sync said something of its
                // own in its place (it posts under the same identity).
                if consecutiveFailures > 0, report.isQuiet, report.notApplied == 0 {
                    core.document.dismissWarning(id: SharedReviewCommands.noteID)
                }
                consecutiveFailures = 0
                retryNotBefore = .distantPast
                // What the sync itself wrote and applied is the new normal, not news. An edit
                // made here while it ran is news: the sync did not publish it, so the next tick
                // must run rather than take its revision bump for the sync's own (S-013).
                // The fingerprint the sync was decided on, not one taken after it (T-083): this
                // participant's own log is not in it, so whatever differs by the next tick is
                // somebody else's write — possibly one that landed after the sync read the
                // folder, which a fingerprint taken now would have absorbed without it ever
                // being merged.
                lastFingerprint = fingerprint
                lastLocalRevision = report.unpublishedLocalChanges > 0 ? nil : document.localChangeRevision
            }
            lastHeartbeat = now
        } else if lastFingerprint != nil || consecutiveFailures == 0 {
            lastFingerprint = fingerprint
        }

        // The heartbeat between syncs, when the sheet changed or it is due.
        let looking = SharedReviewCommands.looking(core)
        let lookingAt = "\(looking.pageLabel ?? "")|\(looking.selectedCount)"
        if report == nil, lookingAt != lastLookingAt || now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval {
            SharedReviewSync(folderURL: folder, participantID: participant, base: nil)
                .heartbeat(authorName: AuthorIdentity.current(), now: now, looking: looking)
            lastHeartbeat = now
        }
        lastLookingAt = lookingAt
        let fresh = SharedReviewSync(folderURL: folder, participantID: participant, base: nil)
            .others(now: now, freshness: Self.presenceFreshness)
        if fresh != others {
            others = fresh
            document.windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
        }
        if wantsAnotherPass {
            wantsAnotherPass = false
            return await tick(now: now) ?? report
        }
        return report
    }

    /// The wait before retrying after `failures` failed syncs in a row: the poll interval,
    /// doubled for each further failure, capped at ``maximumRetryInterval``.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 1 else { return pollInterval }
        let doubled = pollInterval * pow(2, Double(min(failures - 1, 16)))
        return min(maximumRetryInterval, max(pollInterval, doubled))
    }

    // MARK: - Presence in words

    /// "Ada on A-201 · Bo": the other people looking now, for the window's subtitle; `nil` when
    /// nobody else is.
    static func presenceText(for document: ZenitPDFProjectDocument) -> String? {
        guard let others = watcher(for: document)?.others, !others.isEmpty else { return nil }
        return others.prefix(3).map { presence in
            guard let label = presence.pageLabel, !label.isEmpty else { return presence.name }
            return String(format: NSLocalizedString("%1$@ on %2$@", comment: "Shared review presence: a person and the sheet they are looking at"),
                          presence.name, label)
        }.joined(separator: " · ") + (others.count > 3
            ? " " + String(format: NSLocalizedString("and %lld more", comment: "Shared review presence: further people"), others.count - 3)
            : "")
    }
}
