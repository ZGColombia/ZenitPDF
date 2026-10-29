import AppKit
import ZPDFAppCore
import ZPDFPersistence
import ZPDFUIPresentation

/// File ▸ Shared Review (NL-COLLAB-12, ADR-0026): review one project with other people through a
/// folder they all reach — a synced drive or a file share — with no server and no account.
///
/// The project itself never goes into the folder. Each person keeps their own project; the folder
/// holds one append-only log per person, and Sync Now publishes what changed here and applies what
/// everybody else did, as one undoable step.
///
/// The folder is remembered per project as a security-scoped bookmark and this machine's base
/// (what it last agreed with the folder) sits in Application Support. Every dialogue goes through
/// ``ZenitModalPresenter``.
@MainActor
enum SharedReviewCommands {

    static let panelIdentifier = "sharedReview.connect.panel"
    static let refusalIdentifier = "sharedReview.refused"
    static let noteID = UUID(uuidString: "3F1A6C92-7B40-4E0D-8D2B-9C6E51A07D44")!

    /// Where bases live when not Application Support: `nil` in the assembled app, the temporary
    /// directory in any other process, so a test never writes the user's Application Support.
    static let defaultBaseDirectoryOverride: URL? = Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier
        ? nil
        : FileManager.default.temporaryDirectory.appendingPathComponent("zenit-shared-review-bases", isDirectory: true)
    /// A test decides where bases live; `nil` is Application Support.
    static var baseDirectoryOverride: URL? = defaultBaseDirectoryOverride
    /// The defaults the bookmark and participant id live in: the person's own in the assembled
    /// app, a process-local scratch suite anywhere else unless a test injects one — a test must
    /// never write the user's defaults.
    static var defaults: ReviewPreferences = .store

    // MARK: - Identity

    /// This installation's participant id: made once, kept, used as the log's file name.
    static var participantID: String {
        let key = "zenit.sharedReview.participantID"
        if let stored = defaults.string(forKey: key), !stored.isEmpty { return stored }
        let made = UUID().uuidString.lowercased()
        defaults.set(made, forKey: key)
        return made
    }

    // MARK: - Commands

    static func connect(document: ZenitPDFProjectDocument, window: NSWindow?) {
        guard document.projectPackage != nil else {
            refuse(NSLocalizedString(
                "Shared review needs a project. Save this drawing as a project first.",
                comment: "Shared review refusal: a Quick PDF has no project to share"
            ))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Use Folder", comment: "Shared review folder panel: confirm button")
        panel.message = NSLocalizedString(
            "Choose a folder everyone reviewing this project can reach, such as a synced drive or a file share. The project stays here; the folder holds each person's changes.",
            comment: "Shared review folder panel message"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: panelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in _ = await connect(document: document, folder: url) }
        }
    }

    /// Connects the project to a folder and runs a first sync.
    @discardableResult
    static func connect(document: ZenitPDFProjectDocument, folder: URL) async -> SharedReviewSync.Report? {
        guard let package = document.projectPackage else { return nil }
        let manifest = await package.manifest
        let projectID = manifest.projectId
        let name = document.displayName ?? manifest.displayName
        let sync = SharedReviewSync(folderURL: folder, participantID: participantID, base: nil)
        do {
            try withAccess(to: folder) { try sync.prepare(projectID: projectID, projectName: name) }
        } catch {
            refuse(message(for: error))
            return nil
        }
        if let bookmark = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: bookmarkKey(projectID))
        } else {
            defaults.set(folder.path, forKey: pathKey(projectID))
        }
        removeBase(projectID)
        let report = await syncNow(document: document)
        // Round 2: from now on the folder is watched and changes flow both ways on their own.
        if report != nil, SharedReviewAutoSync.automaticStart {
            SharedReviewAutoSync.start(document: document, folder: folder, participant: participantID)
        }
        return report
    }

    /// What one sync came to (U-009).
    ///
    /// `nil` from ``syncNow(document:quiet:participant:)`` used to mean both "there is nothing to
    /// sync with" and "the sync failed", and the automatic sync could not tell them apart: it
    /// either left a failed edit unpublished or backed off from a project that was never
    /// connected. It backs off and retries after ``failed`` only.
    enum SyncOutcome {
        /// The sync ran.
        case synced(SharedReviewSync.Report)
        /// There is nothing to sync with: a Quick PDF, or a project with no folder connected.
        case notConnected
        /// A sync was due and did not run: the connected folder could not be reached, or the
        /// sync threw. Said as "Shared review paused" in quiet mode, as a refusal otherwise.
        case failed

        var report: SharedReviewSync.Report? {
            if case .synced(let report) = self { return report }
            return nil
        }
    }

    /// Publishes what changed here and applies everybody else's changes.
    ///
    /// `quiet` is the automatic sync's: a refusal becomes a note rather than a dialogue, and a
    /// sync that brought nothing from anyone posts nothing. `participant` names the log to write
    /// (a test's second "machine"); `nil` is this installation's.
    @discardableResult
    static func syncNow(document: ZenitPDFProjectDocument, quiet: Bool = false, participant: String? = nil) async -> SharedReviewSync.Report? {
        await runSync(document: document, quiet: quiet, participant: participant).report
    }

    /// ``syncNow(document:quiet:participant:)``, saying why no report came back.
    static func runSync(document: ZenitPDFProjectDocument, quiet: Bool = false, participant: String? = nil) async -> SyncOutcome {
        guard let package = document.projectPackage, let core = document.core else {
            // Said, not swallowed: the row used to be enabled on a Quick PDF and do nothing (R-029).
            if !quiet { refuse(needsProjectMessage) }
            return .notConnected
        }
        let projectID = await package.manifest.projectId
        guard let folder = folderURL(projectID) else {
            if isConnected(projectID) {
                // A folder is remembered and its bookmark no longer resolves — a share that is
                // not mounted, a drive that is not plugged in. That is a failure to retry, not
                // a project with nothing to share.
                if quiet { core.document.post(pausedNote(unreachableFolderReason)) } else { refuse(unreachableFolderReason) }
                return .failed
            }
            if !quiet {
                refuse(String(
                    format: NSLocalizedString(
                        "This project is not connected to a shared review folder. Choose %@ first.",
                        comment: "Shared review refusal: no folder connected; the Connect menu command's path in the menu bar"
                    ),
                    ZenitAppCommandTable.menuPath(for: .connectSharedReview)
                ))
            }
            return .notConnected
        }
        let sync = SharedReviewSync(folderURL: folder, participantID: participant ?? participantID, base: loadBase(projectID, participant: participant))
        sync.readFile = coordinatedRead
        do {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let report = try await sync.sync(core: core, authorName: AuthorIdentity.current(), looking: looking(core))
            saveBase(sync.base, projectID, participant: participant)
            if !quiet || !report.isQuiet || report.notApplied > 0 {
                core.document.post(note(for: report, folder: folder))
            }
            // The folder is reachable and nothing is watching it (the project was opened while
            // its drive or share was offline, so the watch never started): a sync that ran starts
            // it, File ▸ Sync Shared Review included (V-023). Only for this installation's own
            // log, never a test's second participant.
            if participant == nil, SharedReviewAutoSync.automaticStart, SharedReviewAutoSync.watcher(for: document) == nil {
                SharedReviewAutoSync.start(document: document, folder: folder, participant: participantID)
            }
            return .synced(report)
        } catch {
            if quiet {
                core.document.post(pausedNote(message(for: error)))
            } else {
                refuse(message(for: error))
            }
            return .failed
        }
    }

    /// Why a remembered folder was not synced with: its bookmark no longer resolves.
    static var unreachableFolderReason: String {
        NSLocalizedString(
            "The shared review folder cannot be reached. Changes made here are shared when its drive or share is available again.",
            comment: "Shared review: the connected folder's bookmark does not resolve"
        )
    }

    /// The automatic sync's failure note, under the one shared-review identity.
    static func pausedNote(_ message: String) -> AppWarning {
        AppWarning(
            id: noteID, severity: .warning,
            title: NSLocalizedString("Shared review paused", comment: "Shared review automatic sync failure note title"),
            message: message, source: NSLocalizedString("Shared Review", comment: "Status note source for shared review"),
            isDismissible: true, timestamp: Date())
    }

    /// Where this person is looking, for their presence file: the sheet's label and how many
    /// markups they have selected.
    static func looking(_ core: AppCoreEnvironment) -> (pageLabel: String?, selectedCount: Int) {
        let label = core.document.pages.first { $0.id == core.document.currentPageID }?.label
        return (label, core.canvas.selectedMarkups.count)
    }

    static func disconnect(document: ZenitPDFProjectDocument) async {
        guard let package = document.projectPackage else {
            refuse(needsProjectMessage)
            return
        }
        SharedReviewAutoSync.stop(document: document)
        let projectID = await package.manifest.projectId
        let wasConnected = folderURL(projectID)
        defaults.removeObject(forKey: bookmarkKey(projectID))
        defaults.removeObject(forKey: pathKey(projectID))
        removeBase(projectID)
        // Disconnecting used to post nothing, so the person could not tell it had happened (R-029).
        document.core?.document.post(AppWarning(
            id: noteID,
            severity: .info,
            title: wasConnected.map {
                String(
                    format: NSLocalizedString("Disconnected from “%@”", comment: "Shared review disconnect note title; the folder name"),
                    $0.lastPathComponent
                )
            } ?? NSLocalizedString("Not connected to a shared review folder", comment: "Shared review disconnect note title when nothing was connected"),
            message: NSLocalizedString(
                "Changes made here are no longer shared, and nobody else's are applied. The folder and what it holds are left as they are.",
                comment: "Shared review disconnect note detail"
            ),
            source: NSLocalizedString("Shared Review", comment: "Status note source for shared review"),
            isDismissible: true,
            timestamp: Date()
        ))
    }

    /// The refusal a Quick PDF gets from every shared review command.
    static var needsProjectMessage: String {
        String(
            format: NSLocalizedString(
                "Shared review needs a project. Choose File ▸ %@ first.",
                comment: "Shared review refusal: a Quick PDF has no project; the Create Project menu command's title"
            ),
            ZenitAppCommandTable.spec(for: .createProject).title
        )
    }

    // MARK: - Words

    static func note(for report: SharedReviewSync.Report, folder: URL) -> AppWarning {
        var parts: [String] = []
        if report.isQuiet {
            parts.append(NSLocalizedString("Nothing new from anyone else.", comment: "Shared review sync note: no incoming changes"))
        } else {
            parts.append(String(
                format: NSLocalizedString(
                    "%1$lld added, %2$lld changed, %3$lld removed.",
                    comment: "Shared review sync note: incoming markup changes; added, changed, removed"
                ),
                report.added, report.changed, report.removed
            ))
            if report.scales == 1 {
                parts.append(NSLocalizedString("1 sheet's scale changed; its measurements were recomputed here.", comment: "Shared review sync note: one incoming scale change"))
            } else if report.scales > 1 {
                parts.append(String(
                    format: NSLocalizedString("%lld sheets' scales changed; their measurements were recomputed here.", comment: "Shared review sync note: incoming scale changes"),
                    report.scales
                ))
            }
            if report.replies == 1 {
                parts.append(NSLocalizedString("1 new reply.", comment: "Shared review sync note: one incoming reply"))
            } else if report.replies > 1 {
                parts.append(String(
                    format: NSLocalizedString("%lld new replies.", comment: "Shared review sync note: incoming replies"),
                    report.replies
                ))
            }
        }
        if report.published > 0 {
            parts.append(String(
                format: NSLocalizedString("%lld of your changes shared.", comment: "Shared review sync note: changes published"),
                report.published
            ))
        }
        if !report.others.isEmpty {
            parts.append(String(
                format: NSLocalizedString("Reviewing with %@.", comment: "Shared review sync note: the other participants"),
                report.others.joined(separator: ", ")
            ))
        }
        let unsupported = report.notApplied - report.heldForRemovedSheets - report.missingZonesOrRegions
        if unsupported > 0 {
            parts.append(String(
                format: NSLocalizedString(
                    "%lld changes could not be applied by this version and were left as they are.",
                    comment: "Shared review sync note: changes not applied"
                ),
                unsupported
            ))
        }
        if report.heldForRemovedSheets > 0 {
            parts.append(String(
                format: NSLocalizedString(
                    "%lld changes are to markups on sheets removed from the set here; they wait until the sheet is restored.",
                    comment: "Shared review sync note: changes held for sheets removed from this copy's set"
                ),
                report.heldForRemovedSheets
            ))
        }
        if report.missingZonesOrRegions > 0 {
            parts.append(String(
                format: NSLocalizedString(
                    "%lld markups name a Project Zone or Scale Region this copy does not have; they were filed without it or measured by this copy's Scale Regions, and any that lie across two were left out.",
                    comment: "Shared review sync note: markups naming a zone or Scale Region this copy lacks"
                ),
                report.missingZonesOrRegions
            ))
        }
        if report.skippedLines > 0 {
            parts.append(NSLocalizedString(
                "Some lines are still arriving from the sync service and will be read next time.",
                comment: "Shared review sync note: unreadable lines skipped"
            ))
        }
        return AppWarning(
            id: noteID,
            severity: report.notApplied > 0 ? .warning : .info,
            title: String(
                format: NSLocalizedString("Synced with “%@”", comment: "Shared review sync note title; the folder name"),
                folder.lastPathComponent
            ),
            message: parts.joined(separator: " "),
            source: NSLocalizedString("Shared Review", comment: "Status note source for shared review"),
            isDismissible: true,
            timestamp: Date()
        )
    }

    static func message(for error: any Error) -> String {
        switch error as? SharedReviewSync.SyncError {
        case .otherProject(let name)?:
            return String(
                format: NSLocalizedString(
                    "That folder holds the review of “%@”, another project. Choose an empty folder or this project's own.",
                    comment: "Shared review refusal: the folder reviews another project"
                ),
                name
            )
        case .newerFormat?:
            return NSLocalizedString(
                "A newer version of Zenit PDF wrote this folder. Update to review in it.",
                comment: "Shared review refusal: newer folder format"
            )
        case .unwritable?:
            return NSLocalizedString(
                "The folder could not be written to. Check that it is still connected and that you may write to it.",
                comment: "Shared review refusal: folder not writable"
            )
        case .refused(let detail)?:
            return String(
                format: NSLocalizedString(
                    "The changes could not be applied: %@. Nothing in the project was changed.",
                    comment: "Shared review refusal: the document refused the merged changes"
                ),
                detail
            )
        case nil:
            return error.localizedDescription
        }
    }

    private static func refuse(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Shared review", comment: "Shared review refusal title")
        alert.informativeText = reason
        ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, answerWithoutAUser: .button(0))
    }

    // MARK: - Storage

    static func bookmarkKey(_ projectID: String) -> String { "zenit.sharedReview.bookmark.\(projectID)" }
    static func pathKey(_ projectID: String) -> String { "zenit.sharedReview.path.\(projectID)" }

    /// Whether a folder is remembered for this project, resolvable or not.
    static func isConnected(_ projectID: String) -> Bool {
        defaults.data(forKey: bookmarkKey(projectID)) != nil || defaults.string(forKey: pathKey(projectID)) != nil
    }

    /// The connected folder, or `nil` when none is remembered or its bookmark does not resolve.
    /// `mounting: false` resolves without mounting a volume or showing any interface — what a
    /// background retry uses (it5r V-023).
    static func folderURL(_ projectID: String, mounting: Bool = true) -> URL? {
        if let data = defaults.data(forKey: bookmarkKey(projectID)) {
            var stale = false
            let options: URL.BookmarkResolutionOptions = mounting ? [.withSecurityScope] : [.withSecurityScope, .withoutMounting, .withoutUI]
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return defaults.string(forKey: pathKey(projectID)).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func baseURL(_ projectID: String, participant: String? = nil) -> URL? {
        let root = baseDirectoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Zenit PDF/SharedReview", isDirectory: true)
        guard let root else { return nil }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safe = projectID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let suffix = participant.map { "-" + $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } } ?? ""
        return root.appendingPathComponent("\(safe)\(suffix).json")
    }

    static func loadBase(_ projectID: String, participant: String? = nil) -> SharedReviewBaseValue? {
        baseURL(projectID, participant: participant).flatMap { try? Data(contentsOf: $0) }.flatMap(SharedReviewBaseValue.decoded)
    }

    private static func saveBase(_ base: SharedReviewBaseValue, _ projectID: String, participant: String? = nil) {
        guard let url = baseURL(projectID, participant: participant), let data = try? base.encoded() else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func removeBase(_ projectID: String) {
        if let url = baseURL(projectID) { try? FileManager.default.removeItem(at: url) }
    }

    private static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// Reads through a file coordinator, which also asks a sync service to download a file it
    /// has evicted to the cloud before handing back its bytes.
    nonisolated static let coordinatedRead: @Sendable (URL) -> Data? = { url in
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            // Bounded, no link followed, no FIFO blocked on (T-081); the engine has already
            // refused anything but a regular file before this coordinator is involved.
            data = SharedReviewSync.readLog(readURL)
        }
        return data
    }
}

/// Where the review features keep per-person, per-project preferences: the person's defaults in
/// the assembled application, and an in-memory store in any other process (a test, a tool), so no
/// test ever writes the user's defaults or leaves a preferences file behind.
@MainActor
final class ReviewPreferences {
    static let store = ReviewPreferences(
        defaults: Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier ? .standard : nil
    )

    private let defaults: UserDefaults?
    private var memory: [String: Any] = [:]

    /// `nil` keeps everything in memory.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func object(forKey key: String) -> Any? { defaults?.object(forKey: key) ?? memory[key] }
    func set(_ value: Any?, forKey key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }
    func removeObject(forKey key: String) {
        if let defaults { defaults.removeObject(forKey: key) } else { memory[key] = nil }
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func integer(forKey key: String) -> Int { (object(forKey: key) as? Int) ?? 0 }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
}
