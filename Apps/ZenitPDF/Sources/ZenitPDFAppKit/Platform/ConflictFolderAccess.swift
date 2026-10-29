import AppKit
import Foundation
import ZPDFAppCore
import ZPDFPersistence
import ZPDFUIPresentation

/// Read access to the folder a project sits in, so the sync-conflict check can look beside it
/// in the sandboxed application (X-049).
///
/// Opening a `.zpdfproj` grants that package and nothing beside it. Sync clients make their
/// conflict copies as siblings ("Plan (Mac-B's conflicted copy).zpdfproj",
/// "Plan.sync-conflict-…zpdfproj"), so the shipped application could never list them: the
/// refused listing read as an empty folder and the open said nothing, while a colleague's work
/// sat in the other copy. Now:
///
/// 1. The folder is listed directly when the process may (an unsandboxed build, or a folder the
///    sandbox already lets it read), else inside the scope of a folder grant kept from before.
/// 2. With neither, a project in a synced location asks **once per folder**: an open panel aimed
///    at the project's folder, through ``ZenitModalPresenter`` so no test can show it. The grant
///    is kept as an app-scoped bookmark, and every later open of a project in that folder is
///    checked without asking.
/// 3. While no grant covers the folder, the open says the folder was not checked — whether or
///    not there is anything else to report (X-049 re-fix). The conflict notice carries the
///    sentence when it appears; otherwise, and beside it, the window's warning tray holds a
///    non-modal note with **Allow Access…**, which asks for the folder and looks again. So a
///    declined panel, or a project outside the locations that are asked about, is never
///    passed off as "no copies there", and no modal appears on every open.
///
/// The other copy is copied out inside the same grant's scope
/// (`SyncedFolderSafety.copyOfOtherVersion`).
@MainActor
enum ConflictFolderAccess {

    /// How the folder is being listed, so a test can refuse the direct listing as the sandbox
    /// does and allow the one inside a grant's scope.
    enum ListingRoute: Equatable {
        case direct
        case throughGrant
    }

    /// What the look beside a package found.
    enum Outcome: Equatable {
        /// The folder was read; these are its conflict copies, possibly none.
        case copies([String])
        /// No access to the folder: nobody knows whether copies are there.
        case folderNotChecked

        var copyNames: [String] {
            if case .copies(let names) = self { return names }
            return []
        }

        var folderChecked: Bool { self != .folderNotChecked }
    }

    /// The stable name of the open panel, for `ZenitModalPresenter` assertions.
    static let openPanelIdentifier = "sharedStorage.conflictFolderAccess"
    /// Folder grants: folder path → security-scoped bookmark.
    static let grantsKey = "Zenit.ConflictFolderAccess.Grants"
    /// Folders already asked about, granted or not.
    static let askedKey = "Zenit.ConflictFolderAccess.Asked"

    /// Where grants and the asked folders are kept: the process store outside the assembled
    /// bundle, like every other bookmark; a test injects its own.
    static var defaultsOverride: (any ZPDFDefaultsStoring)?
    static var defaults: any ZPDFDefaultsStoring { defaultsOverride ?? ZenitProcessDefaults.bookmarks }

    /// How a folder is listed. Injectable: a test refuses the direct route.
    static var listing: (URL, ListingRoute) throws -> [String] = { folder, _ in
        try SyncConflictScanner.listFolder(folder)
    }

    /// Whether a project is in a folder a sync service keeps: an iCloud Drive or file-provider
    /// item, or a path under iCloud Drive or the file providers' cloud storage. Injectable.
    static var isInSyncedLocation: (URL) -> Bool = { url in
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true { return true }
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
    }

    /// Entering and leaving a grant's scope. Injectable, so a test can see the scope is held.
    static var startAccessing: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    static var stopAccessing: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }

    /// Making a grant's security-scoped bookmark, and resolving one with whether the system
    /// calls it stale. Injectable, so a test can hand back a stale bookmark.
    static var makeBookmark: (URL) -> Data? = { url in
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static var resolveBookmark: (Data) -> (url: URL, isStale: Bool)? = { data in
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    // MARK: - The look

    /// The conflict copies beside `package`: directly, else through a grant covering its folder.
    static func scan(besides package: URL) -> Outcome {
        if case .copies(let names) = SyncConflictScanner.conflictCopies(besides: package, listing: { try listing($0, .direct) }) {
            return .copies(names)
        }
        let viaGrant = withGrant(covering: package.deletingLastPathComponent()) {
            SyncConflictScanner.conflictCopies(besides: package, listing: { try listing($0, .throughGrant) })
        }
        if case .copies(let names)? = viaGrant { return .copies(names) }
        return .folderNotChecked
    }

    /// The look the open runs: ``scan(besides:)``, and when the folder could not be read, the
    /// one question per folder (``requestAccess(besides:)``) followed by a second look.
    static func scanAskingOnce(besides package: URL) async -> Outcome {
        let first = scan(besides: package)
        guard first == .folderNotChecked, shouldAsk(besides: package), await requestAccess(besides: package) else {
            return first
        }
        return scan(besides: package)
    }

    /// Runs `body` with the folder readable: inside the scope of a grant covering it when one is
    /// kept, else as the process is. For reads of a sibling — the other copy — that a grant on
    /// the package does not cover.
    static func withFolderAccess<T>(_ folder: URL, _ body: () throws -> T) rethrows -> T {
        if let value = try withGrant(covering: folder, body) { return value }
        return try body()
    }

    /// `body` inside the scope of a kept grant covering `folder`; `nil` when no grant covers it.
    static func withGrant<T>(covering folder: URL, _ body: () throws -> T) rethrows -> T? {
        guard let granted = grantedFolder(covering: folder) else { return nil }
        let scoped = startAccessing(granted)
        defer { if scoped { stopAccessing(granted) } }
        return try body()
    }

    /// Reports what a look found, as the open does: the conflict notice when there are copies
    /// beside the package or versions the sync service kept, saying whether the folder was
    /// looked in; nothing otherwise. The one rule for the open and the tray's Allow Access….
    static func report(_ outcome: Outcome, besides package: URL,
                       through report: @MainActor (_ copyNames: [String], _ unresolvedVersions: Int, _ packageName: String) -> Void) {
        let copies = outcome.copyNames
        let versions = SyncConflictScanner.unresolvedVersionCount(at: package)
        guard !copies.isEmpty || versions > 0 else { return }
        // NL-PLAT-16: the report can act on this package — open the other copy, or keep this.
        SharedStoragePrompt.conflictPackageURL = package
        SharedStoragePrompt.conflictFolderChecked = outcome.folderChecked
        report(copies, versions, package.lastPathComponent)
        SharedStoragePrompt.conflictPackageURL = nil
        SharedStoragePrompt.conflictFolderChecked = true
    }

    // MARK: - The question

    /// Whether the open should ask: no grant covers the folder, the project is in a synced
    /// location, and this folder has never been asked about.
    static func shouldAsk(besides package: URL) -> Bool {
        let folder = package.deletingLastPathComponent()
        return grantedFolder(covering: folder) == nil && isInSyncedLocation(package) && !askedFolders.contains(key(folder))
    }

    /// Asks for the project's folder once: an open panel aimed at it. A folder that is the
    /// project's or holds it is kept as a grant. Answers whether a grant now covers the folder.
    static func requestAccess(besides package: URL) async -> Bool {
        let folder = package.deletingLastPathComponent()
        var asked = askedFolders
        asked.insert(key(folder))
        defaults.encode(asked.sorted(), forKey: askedKey)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.message = String(
            format: NSLocalizedString(
                "Zenit PDF can read “%1$@” but not the folder it is in, so it cannot see copies a sync service may have made beside it. Choose “%2$@” to check it now and whenever a project in it opens.",
                comment: "Sync conflict folder access panel: the project's name, then its folder's name"
            ),
            package.lastPathComponent, folder.lastPathComponent
        )
        panel.prompt = NSLocalizedString("Allow Access", comment: "Sync conflict folder access panel: the button that grants the folder")
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<ZenitModalAnswer, Never>) in
            ZenitModalPresenter.runOpenPanel(panel, identifier: openPanelIdentifier, sheetedOn: nil) { continuation.resume(returning: $0) }
        }
        guard let chosen = answer.firstURL, covers(chosen, folder) else { return false }
        var grants = storedGrants
        grants[key(chosen)] = makeBookmark(chosen) ?? Data(chosen.standardizedFileURL.path.utf8)
        defaults.encode(grants, forKey: grantsKey)
        return grantedFolder(covering: folder) != nil
    }

    // MARK: - The tray note (X-049 re-fix)

    /// A "not checked" note in a window's tray: the document whose tray holds it and the
    /// package it is about. Held by the note's identity until its action runs.
    struct PendingNote {
        weak var document: ZenitPDFProjectDocument?
        let package: URL
    }

    static var pendingNotes: [UUID: PendingNote] = [:]

    /// Says in `document`'s tray that the folder beside `package` was not checked, with the way
    /// to let it be. Non-modal: it appears on every open that could not look, which a modal
    /// would make unbearable, and it costs nothing to dismiss. Answers the note's identity.
    @discardableResult
    static func postFolderNotChecked(besides package: URL, document: ZenitPDFProjectDocument,
                                     core: AppCoreEnvironment) -> UUID {
        let id = UUID()
        pendingNotes = pendingNotes.filter { $0.value.document != nil }
        pendingNotes[id] = PendingNote(document: document, package: package)
        core.document.post(folderNotCheckedNote(id: id, package: package))
        return id
    }

    static func folderNotCheckedNote(id: UUID, package: URL) -> AppWarning {
        AppWarning(
            id: id,
            severity: .info,
            title: NSLocalizedString(
                "The project’s folder was not checked for sync conflict copies.",
                comment: "Tray note: the folder beside an opened project could not be listed"
            ),
            message: String(
                format: NSLocalizedString(
                    "Zenit PDF can read “%1$@” but not the folder it is in, so it cannot see copies a sync service may have made beside it. Allow Access lets it check “%2$@” now and whenever a project in it opens.",
                    comment: "Tray note detail: the project's name, then its folder's name"
                ),
                package.lastPathComponent, package.deletingLastPathComponent().lastPathComponent
            ),
            source: NSLocalizedString("Sync conflicts", comment: "Warning source for the sync-conflict check at open"),
            actionTitle: NSLocalizedString("Allow Access…", comment: "Tray note action: grant the folder beside the project"),
            isDismissible: true,
            timestamp: Date()
        )
    }

    /// The note's Allow Access…. Returns whether the warning was one of these notes.
    static func handleNoteAction(_ warningID: UUID, document: ZenitPDFProjectDocument) -> Bool {
        guard let note = pendingNotes[warningID], note.document === document else { return false }
        Task { @MainActor in await allowAccess(note: warningID, besides: note.package, document: document) }
        return true
    }

    /// Asks for the folder, whatever the location and however often it was asked before: the
    /// person asked for it. Granted, the note goes and the look the open could not make is made
    /// and reported as the open reports it. Declined, the note stays — it is still true.
    static func allowAccess(note warningID: UUID, besides package: URL, document: ZenitPDFProjectDocument) async {
        guard await requestAccess(besides: package) else { return }
        pendingNotes.removeValue(forKey: warningID)
        document.core?.document.dismissWarning(id: warningID)
        report(scan(besides: package), besides: package) { copies, versions, name in
            SharedStoragePrompt.reportConflicts(copyNames: copies, unresolvedVersions: versions, packageName: name)
        }
    }

    // MARK: - Grants

    static var storedGrants: [String: Data] { defaults.decode([String: Data].self, forKey: grantsKey) ?? [:] }
    static var askedFolders: Set<String> { Set(defaults.decode([String].self, forKey: askedKey) ?? []) }

    /// The kept grant whose folder is `folder` or holds it, resolved; the nearest one first.
    ///
    /// A bookmark the system calls stale still resolves, but stops resolving some time later
    /// (the folder was moved or its volume changed), so it is replaced at once by a fresh one
    /// made inside its own scope. One that now resolves to a folder that does not hold
    /// `folder` covers it no longer.
    static func grantedFolder(covering folder: URL) -> URL? {
        let target = key(folder)
        for (path, data) in storedGrants.sorted(by: { $0.key.count > $1.key.count })
        where target == path || target.hasPrefix(path.hasSuffix("/") ? path : path + "/") {
            if let resolved = resolveBookmark(data) {
                if resolved.isStale { refreshGrant(storedAt: path, resolved.url) }
                if covers(resolved.url, folder) { return resolved.url }
                continue
            }
            // A plain path, which is what a process that cannot make a bookmark stores.
            if let plain = String(data: data, encoding: .utf8), plain.hasPrefix("/") {
                return URL(fileURLWithPath: plain, isDirectory: true)
            }
        }
        return nil
    }

    /// Replaces the stale bookmark kept at `path` with one made for `url` inside the scope of
    /// the stale one, as a security-scoped bookmark of a folder must be. Kept under `url`'s
    /// own path; one that cannot be made leaves the old bookmark as it was.
    static func refreshGrant(storedAt path: String, _ url: URL) {
        let scoped = startAccessing(url)
        defer { if scoped { stopAccessing(url) } }
        guard let fresh = makeBookmark(url) else { return }
        var grants = storedGrants
        grants.removeValue(forKey: path)
        grants[key(url)] = fresh
        defaults.encode(grants, forKey: grantsKey)
    }

    /// Whether `chosen` is `folder` or a folder that holds it.
    static func covers(_ chosen: URL, _ folder: URL) -> Bool {
        let parent = key(chosen), target = key(folder)
        return target == parent || target.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    static func key(_ folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
