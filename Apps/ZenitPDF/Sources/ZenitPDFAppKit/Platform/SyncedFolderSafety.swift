import AppKit
import Foundation
import ZPDFPersistence

/// A project saved in a synced folder, handled safely (NL-PLAT-16). This is not sync: iCloud
/// containers and CloudKit need a paid Apple developer membership. It is the three things a
/// project in iCloud Drive, a company share or any sync client's folder needs so that it never
/// opens half-downloaded and never loses someone's copy:
///
/// 1. **Evicted members are downloaded first.** A sync service may have left only a placeholder
///    of `documents/working.pdf` or the database on this Mac. Every member is read through a file
///    coordinator before the package is opened — the coordinator downloads what the file provider
///    evicted — so the drawing never reaches PDFKit or the extractor as an empty file and fails
///    as a "damaged PDF".
/// 2. **Conflict versions are offered, never merged.** When the sync service kept two versions,
///    the person can open the other one as a separate copy to compare, or keep the one they
///    opened. Nothing is deleted, and the other version stays available in the version browser.
/// 3. **Open elsewhere** is NL-COLLAB-13's (the session marker and the read-only default).
@MainActor
enum SyncedFolderSafety {

    // MARK: - Evicted members

    /// Whether a file is a placeholder a sync service left: an iCloud item not downloaded, or a
    /// file-provider file with no data on this Mac (`SF_DATALESS`).
    nonisolated static func isEvicted(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current {
            return true
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// The package's files whose bytes are not on this Mac.
    nonisolated static func evictedMembers(of package: URL, isEvicted: (URL) -> Bool = SyncedFolderSafety.isEvicted) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var evicted: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            // `recovery/` and `versions/` are this Mac's session and history; they download too,
            // but nothing in the open reads them before the drawing and the database.
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, isEvicted(item) else { continue }
            evicted.append(item)
        }
        return evicted.sorted { $0.path < $1.path }
    }

    /// How a member is brought down: ask the provider to download it, then read it through a file
    /// coordinator, which returns once the bytes are here. Injectable; a test counts the calls.
    static var download: @Sendable (URL) async -> Bool = { url in
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var coordinationError: NSError?
            var ok = false
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
                ok = FileManager.default.isReadableFile(atPath: readable.path)
            }
            return ok && coordinationError == nil
        }.value
    }

    /// Downloads every evicted member of `package` that `including` accepts, reporting progress
    /// as (done, total). Returns the members that could not be brought down.
    @discardableResult
    static func materialize(_ package: URL, isEvicted: @escaping (URL) -> Bool = SyncedFolderSafety.isEvicted,
                            progress: @MainActor (Int, Int) -> Void = { _, _ in },
                            including: (URL) -> Bool = { _ in true }) async -> [URL] {
        let members = evictedMembers(of: package, isEvicted: isEvicted).filter(including)
        guard !members.isEmpty else { return [] }
        var failed: [URL] = []
        progress(0, members.count)
        for (index, member) in members.enumerated() {
            if await !download(member) { failed.append(member) }
            progress(index + 1, members.count)
        }
        return failed
    }

    /// Members an open never reads — the Finder and Quick Look pictures and the version history
    /// — so one that could not be downloaded does not stop the open.
    nonisolated static let membersTheOpenSkips = [
        ProjectPackageLayout.thumbnails, ProjectPackageLayout.finderQuickLook, ProjectPackageLayout.versions
    ]

    /// Some of a project's files are still only in the sync service (T-017): an open refused in
    /// words, rather than a package opened with placeholders that then fails as "damaged".
    struct MembersNotDownloaded: LocalizedError, CustomStringConvertible, Equatable {
        let projectName: String
        let memberCount: Int

        var errorDescription: String? {
            memberCount == 1
                ? String(format: NSLocalizedString("1 file of “%@” is not downloaded yet.", comment: "Open refusal: one member of a synced project could not be downloaded; the project name"), projectName)
                : String(format: NSLocalizedString("%1$lld files of “%2$@” are not downloaded yet.", comment: "Open refusal: members of a synced project could not be downloaded; count, the project name"), Int64(memberCount), projectName)
        }

        var recoverySuggestion: String? {
            NSLocalizedString(
                "The project is in a synced folder and this Mac could not fetch all of it. Connect to the network, or let the sync service finish downloading it, then open it again. Nothing was changed.",
                comment: "Open refusal: what to do about a partly downloaded synced project"
            )
        }

        var description: String { [errorDescription, recoverySuggestion].compactMap { $0 }.joined(separator: " ") }
    }

    /// Whether `member` of `package` is one the open never reads (``membersTheOpenSkips``).
    nonisolated static func isSkippedByTheOpen(_ member: URL, in package: URL) -> Bool {
        let root = package.standardizedFileURL.resolvingSymlinksInPath().path
        let path = member.standardizedFileURL.resolvingSymlinksInPath().path
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : member.lastPathComponent
        return membersTheOpenSkips.contains { relative == $0 || relative.hasPrefix($0 + "/") }
    }

    /// Downloads the evicted members the open reads, before it runs, and refuses the open when
    /// one could not be brought down (T-017). The failures ``materialize`` returned used to be
    /// dropped, and the package opened with placeholders in it.
    ///
    /// Only what the open reads (U-016): the version history — two clones of a completed save,
    /// whose sharing a sync service does not keep — and the Finder pictures used to be fetched
    /// first too, so the drawing and database crossed the network about three times before the
    /// window opened. The history is fetched when a recovery needs it, or in the background
    /// after the open (``prefetchMembersTheOpenSkips(_:isEvicted:)``).
    static func materializeForOpen(_ package: URL, isEvicted: @escaping (URL) -> Bool = SyncedFolderSafety.isEvicted) async throws {
        let failed = await materialize(package, isEvicted: isEvicted, including: { !isSkippedByTheOpen($0, in: package) })
        guard failed.isEmpty else {
            throw MembersNotDownloaded(projectName: package.deletingPathExtension().lastPathComponent, memberCount: failed.count)
        }
    }

    /// Downloads the members the open skipped — the version history and the Finder pictures —
    /// for a recovery that restores from the history, or after the open so the next save does
    /// not stall rotating placeholders. One that cannot be fetched is left to the reader that
    /// needs it, which says so. Returns the members that could not be brought down.
    @discardableResult
    static func prefetchMembersTheOpenSkips(_ package: URL, isEvicted: @escaping (URL) -> Bool = SyncedFolderSafety.isEvicted) async -> [URL] {
        // Only those folders are walked: the whole package was walked once before the open.
        var failed: [URL] = []
        for folder in membersTheOpenSkips {
            failed += await materialize(package.appendingPathComponent(folder, isDirectory: true), isEvicted: isEvicted)
        }
        return failed
    }

    // MARK: - Conflict versions

    enum ConflictChoice: Equatable {
        case openOtherCopy
        case keepThisOne
        case later
    }

    /// The conflict notice itself, now with its two ways forward: one identifier, one alert.
    static let conflictChoiceIdentifier = SharedStoragePrompt.conflictModalIdentifier

    /// Where copies of the other version are opened from: a folder of this session's own.
    static var otherCopiesFolder: () -> URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent("Zenit PDF other versions", isDirectory: true)
    }

    /// The other version's bytes, copied beside nothing the person owns, named so it cannot be
    /// mistaken for the project: "Plan (other version).zpdfproj". `nil` when there is none.
    static func copyOfOtherVersion(of package: URL, siblingNames: [String]) -> URL? {
        let source: URL?
        if let version = NSFileVersion.unresolvedConflictVersionsOfItem(at: package)?.first {
            source = version.url
        } else if let sibling = siblingNames.first {
            source = package.deletingLastPathComponent().appendingPathComponent(sibling)
        } else {
            source = nil
        }
        guard let source else { return nil }
        let folder = otherCopiesFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = package.deletingPathExtension().lastPathComponent
        let target = folder.appendingPathComponent("\(name) (other version).\(package.pathExtension)")
        try? FileManager.default.removeItem(at: target)
        do {
            // X-049: a sibling copy is outside the grant the open holds for the package; it is
            // read inside the scope of the folder's grant when one is kept.
            try ConflictFolderAccess.withFolderAccess(package.deletingLastPathComponent()) {
                try FileManager.default.copyItem(at: source, to: target)
            }
        } catch { return nil }
        return target
    }

    /// Marks the sync service's conflict versions resolved in favour of the one opened. They stay
    /// in the version store; sibling conflict copies are left where they are.
    static func keepThisOne(_ package: URL) {
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: package) ?? [] {
            version.isResolved = true
        }
    }

    /// How the other copy is opened. The shipping value opens it through the document controller.
    static var opener: @MainActor (URL) -> Void = { url in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { ZenitErrorPresenter.present(error) }
        }
    }
}
