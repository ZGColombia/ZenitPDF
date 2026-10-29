import Foundation
import ZPDFPersistence

extension DocumentLoadPipeline {

    /// A project package the open made, and whether its folder could be looked in for
    /// sync-conflict copies (X-049).
    struct OpenedProjectPackage {
        let package: ProjectPackage
        /// `false`: nobody knows whether copies are beside it. The window's tray says so once
        /// the document has adopted the load, even when there was nothing else to report.
        let conflictFolderChecked: Bool
    }

    /// Opens a project package, answering crash evidence with the recovery prompt and a live
    /// session elsewhere with the shared-storage prompt — never the other way round
    /// (NL-COLLAB-13).
    ///
    /// Once open read-write, the session's heartbeat starts, so a second Mac looking at the
    /// same package through a shared folder sees a live session. Sync-conflict copies beside
    /// the package are reported, never touched.
    func openProjectPackage(at url: URL) async throws -> OpenedProjectPackage {
        let name = url.lastPathComponent
        // NL-PLAT-16 (r2-platform): a sync service's placeholders are downloaded, through a file
        // coordinator, before anything reads the package — never a "damaged PDF" for a file that
        // is simply not here yet. One that cannot be fetched refuses the open in those words
        // (T-017).
        try await SyncedFolderSafety.materializeForOpen(url)
        let package: ProjectPackage
        switch try await ProjectPackage.open(at: url) {
        case .opened(let opened):
            package = opened
        case .recoveryRequired(let assessment):
            // A recovery may restore from the version history, which the open itself does not
            // read and so did not fetch (U-016).
            await SyncedFolderSafety.prefetchMembersTheOpenSkips(url)
            let decision = await askRecovery(assessment, name)
            package = try await ProjectPackage.open(at: url, resolving: decision)
        case .openElsewhere(let session, _):
            let decision = askForeignSession(session, name)
            do {
                package = try await ProjectPackage.open(at: url, foreignSession: decision)
            } catch ZPDFPersistenceError.recoveryDecisionRequired(let assessment) {
                // The other session's heartbeat went stale while the question was up: from
                // here on it is crash evidence, and it gets the crash question.
                await SyncedFolderSafety.prefetchMembersTheOpenSkips(url)
                let recovery = await askRecovery(assessment, name)
                package = try await ProjectPackage.open(at: url, resolving: recovery)
            }
        }
        // The rest of a synced project — its version history — comes down behind the open,
        // before a save rotates the history's slots (U-016). A local project has nothing evicted.
        Task { @MainActor in await SyncedFolderSafety.prefetchMembersTheOpenSkips(url) }
        if package.accessMode == .readWrite {
            ProjectSessionHeartbeat.start(for: package)
        }
        // X-049: the folder is listed directly, through a kept grant, or — asked once per folder
        // — through one granted now. A look that could not happen is not "no copies there".
        let scan = await ConflictFolderAccess.scanAskingOnce(besides: url)
        ConflictFolderAccess.report(scan, besides: url, through: reportSyncConflicts)
        return OpenedProjectPackage(package: package, conflictFolderChecked: scan.folderChecked)
    }
}
