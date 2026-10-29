import AppKit
import CryptoKit
import ZPDFAppCore
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// The office's shared Tool Library, subscribed from a folder (NL-PLAT-15).
///
/// The person points Settings ▸ Library at a folder — a file-server share, an iCloud Drive
/// folder, anything they already trust. Every `.zpdftools` in it is read through
/// ``ToolSetImportValidator`` (the posture of an imported file: untrusted, bounded, nothing
/// runs) at launch and whenever the application comes to the front, and listed in Imported
/// Libraries as "Office (read-only)". Duplicate is the only way to edit one, and it lands in
/// My Tools. When a file changes, its tools are replaced in place and a note says what changed.
///
/// Placed markups never change: placement freezes the preset's symbol and parameters into the
/// markup record, so a newer office set changes the next placement, not the last one.
///
/// Identity is stable across versions — a subscribed preset's id is derived from the file name
/// and the id the file gives it — so an updated set replaces its own tools rather than adding a
/// second copy, and a person's "Recent" still finds them.
@MainActor
final class SubscribedToolLibrary {

    static let shared = SubscribedToolLibrary()

    /// Where the folder bookmark and the last-seen digests are kept. The process store outside the
    /// assembled bundle; a test injects its own.
    var defaults: any ZPDFDefaultsStoring = ZenitProcessDefaults.layout

    static let folderKey = "Zenit.SubscribedToolLibrary.Folder"
    static let stateKey = "Zenit.SubscribedToolLibrary.State"
    static let noteID = UUID(uuidString: "5E2F7A1B-9C3D-4B6E-8F0A-1D2C3B4A5E6F")!
    /// The category suffix every subscribed tool carries, so the set reads "Office (read-only)".
    nonisolated static var readOnlySuffix: String { readOnlySuffixValue }

    private var observer: NSObjectProtocol?

    /// Starts watching for the application coming to the front. Idempotent.
    func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SubscribedToolLibrary.shared.refreshOpenDocuments() }
        }
    }

    // MARK: - The folder

    /// The subscribed folder, resolved from its security-scoped bookmark, or `nil`.
    var folder: URL? {
        guard let data = defaults.persistedData(forKey: Self.folderKey) else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        // A plain path, which is what a test (and a folder the sandbox already lets us read) stores.
        return String(data: data, encoding: .utf8).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Subscribes to `url`: stores a security-scoped bookmark (a plain path when a bookmark cannot
    /// be made, as in a test process) and forgets what was seen in the last folder.
    func subscribe(to url: URL) {
        let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? Data(url.path.utf8)
        defaults.setPersistedData(data, forKey: Self.folderKey)
        defaults.setPersistedData(nil, forKey: Self.stateKey)
        cachedRead = nil
    }

    /// Stops the subscription. The subscribed tools leave the library on the next refresh.
    func unsubscribe() {
        defaults.setPersistedData(nil, forKey: Self.folderKey)
        cachedRead = nil
    }

    // MARK: - Reading

    /// One subscribed file as read now.
    struct SubscribedSet: Equatable, Sendable {
        var fileName: String
        var setName: String
        var digest: String
        var presets: [ToolPresetSummary]
    }

    /// What the last refresh saw, per file: the digest and the tool names, for the change summary.
    struct SeenState: Codable, Equatable {
        var digests: [String: String] = [:]
        var toolNames: [String: [String]] = [:]
    }

    /// What one read of the folder found, and the listing it was read under.
    struct FolderRead: Sendable {
        var listing: [String]
        var sets: [SubscribedSet]
        var refused: [String]
    }

    /// The last read, reused while the folder's listing is unchanged (R-035).
    private var cachedRead: FolderRead?

    /// Full reads of the folder this instance has made. Test observability.
    private(set) var readCount = 0

    /// The folder's `.zpdftools` files by name, size and modification date: a cheap listing that
    /// changes whenever a file is added, removed or rewritten. Reading, validating and hashing
    /// every file is what a refresh is skipped for while it stays the same.
    nonisolated static func listing(folder: URL) -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == ToolSetDocument.fileExtension }
            .map { file in
                let values = try? file.resourceValues(forKeys: Set(keys))
                let stamp = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                return "\(file.lastPathComponent)|\(values?.fileSize ?? -1)|\(stamp)"
            }
            .sorted()
    }

    /// The folder, read — or `nil` when `cached` was read under the same listing.
    nonisolated static func readIfChanged(folder: URL, cached: [String]?) -> FolderRead? {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let listing = listing(folder: folder)
        guard listing != cached else { return nil }
        let (sets, refused) = read(folder: folder)
        return FolderRead(listing: listing, sets: sets, refused: refused)
    }

    /// Reads every `.zpdftools` in the folder through the validator. A file that fails is skipped
    /// and named; one bad file does not hide the others.
    nonisolated static func read(folder: URL) -> (sets: [SubscribedSet], refused: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var sets: [SubscribedSet] = []
        var refused: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == ToolSetDocument.fileExtension {
            guard let data = try? Data(contentsOf: file) else { refused.append(file.lastPathComponent); continue }
            switch ToolSetImportValidator(destinationPanel: .importedLibraries).review(data: data, fileName: file.lastPathComponent) {
            case let .success(review) where review.isSafeToImport:
                let setName = review.setName.isEmpty ? file.deletingPathExtension().lastPathComponent : review.setName
                let category = "\(setName) \(readOnlySuffix)"
                let presets: [ToolPresetSummary] = review.presets.enumerated().compactMap { index, preset in
                    guard var copy = preset.reidentified(stableID(fileName: file.lastPathComponent, presetID: preset.id)) else { return nil }
                    copy.panel = .importedLibraries
                    copy.category = category
                    copy.sortIndex = index
                    copy.provenance = ToolPresetProvenance(origin: .imported, sourceFileName: file.lastPathComponent, recordedAt: nil)
                    copy.isFavorite = false
                    copy.isReadOnly = true
                    copy.shortcutDisplayString = nil
                    return copy
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                sets.append(SubscribedSet(fileName: file.lastPathComponent, setName: setName, digest: digest, presets: presets))
            default:
                refused.append(file.lastPathComponent)
            }
        }
        return (sets, refused)
    }

    /// A subscribed preset's identity: the same file and the same preset id in the file always
    /// give the same id, so a newer version replaces its own tools.
    nonisolated static func stableID(fileName: String, presetID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("zenit.subscribed/\(fileName)/\(presetID.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 layout: name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Whether a preset came from a subscription: read-only, in Imported Libraries, and carrying
    /// the subscribed suffix on its set. The Tool Library's Remove asks the same rule (X-031).
    nonisolated static func isSubscribed(_ preset: ToolPresetSummary) -> Bool {
        SubscribedToolSet.owns(preset)
    }

    nonisolated static let readOnlySuffixValue = SubscribedToolSet.categorySuffix

    // MARK: - Applying

    /// What a refresh did, for the note and the tests.
    struct Outcome: Equatable {
        var presets: [ToolPresetSummary]
        var added: [String] = []
        var removed: [String] = []
        var updated: [String] = []
        var refused: [String] = []
        var changed: Bool { !added.isEmpty || !removed.isEmpty || !updated.isEmpty }
    }

    /// The library after a refresh: every earlier subscribed tool out, the folder's tools in,
    /// everything the person owns untouched. Pure over its inputs.
    nonisolated static func merge(library: [ToolPresetSummary], sets: [SubscribedSet], seen: SeenState) -> (Outcome, SeenState) {
        var outcome = Outcome(presets: library.filter { !isSubscribed($0) })
        outcome.presets.append(contentsOf: sets.flatMap(\.presets))
        var state = SeenState()
        for set in sets {
            state.digests[set.fileName] = set.digest
            state.toolNames[set.fileName] = set.presets.map(\.name)
            if let before = seen.digests[set.fileName] {
                if before != set.digest {
                    let old = Set(seen.toolNames[set.fileName] ?? [])
                    let new = Set(set.presets.map(\.name))
                    outcome.added += set.presets.map(\.name).filter { !old.contains($0) }
                    outcome.removed += (seen.toolNames[set.fileName] ?? []).filter { !new.contains($0) }
                    outcome.updated.append(set.setName)
                }
            } else {
                outcome.added += set.presets.map(\.name)
            }
        }
        for (file, names) in seen.toolNames where state.digests[file] == nil {
            outcome.removed += names
        }
        return (outcome, state)
    }

    /// The refresh a return to the front started, still reading.
    private var backgroundRefresh: Task<Void, Never>?

    /// Refreshes every open project from the folder. Called at launch and on each return to the
    /// front. Nothing happens without a subscription, except that tools of an ended one leave.
    ///
    /// The folder is read once for every open project, off the main thread, and not at all while
    /// its listing is unchanged. It used to be read, validated and hashed synchronously on the
    /// main thread once per open document on every activation — over a file share at that (R-035).
    func refreshOpenDocuments() {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? ZenitPDFProjectDocument }
        backgroundRefresh?.cancel()
        backgroundRefresh = Task { @MainActor in await self.refreshInBackground(documents) }
    }

    /// The body of ``refreshOpenDocuments()``, awaitable.
    func refreshInBackground(_ documents: [ZenitPDFProjectDocument]) async {
        guard let folder else {
            refresh(documents, read: nil)
            return
        }
        let cachedListing = cachedRead?.listing
        let fresh = await Task.detached(priority: .utility) {
            Self.readIfChanged(folder: folder, cached: cachedListing)
        }.value
        guard !Task.isCancelled else { return }
        if let fresh {
            readCount += 1
            cachedRead = fresh
        }
        // Unchanged since the last read: the cached read is applied, which costs a comparison
        // per document and no file access, and brings a project opened since up to date.
        refresh(documents, read: cachedRead)
    }

    /// Refreshes one document's library. Returns the outcome, or `nil` when there was nothing to do.
    @discardableResult
    func refresh(_ document: ZenitPDFProjectDocument) -> Outcome? {
        refresh([document]).first ?? nil
    }

    /// Refreshes several documents from one read of the folder — the cached one while the
    /// listing is unchanged. Synchronous: what a document's open calls.
    @discardableResult
    func refresh(_ documents: [ZenitPDFProjectDocument]) -> [Outcome?] {
        guard let folder else { return refresh(documents, read: nil) }
        if let fresh = Self.readIfChanged(folder: folder, cached: cachedRead?.listing) {
            readCount += 1
            cachedRead = fresh
        }
        return refresh(documents, read: cachedRead)
    }

    /// Applies one read to every document, against one seen state. The seen state used to be
    /// written by the first document's refresh, so with two projects open only the first was
    /// told the library had changed (R-035).
    @discardableResult
    private func refresh(_ documents: [ZenitPDFProjectDocument], read: FolderRead?) -> [Outcome?] {
        let seen = defaults.persistedData(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(SeenState.self, from: $0) } ?? SeenState()
        var newState: SeenState?
        let outcomes = documents.map { document -> Outcome? in
            guard let core = document.core else { return nil }
            let current = core.toolLibrary.presets
            if read == nil, !current.contains(where: Self.isSubscribed) { return nil }
            var (outcome, state) = Self.merge(library: current, sets: read?.sets ?? [], seen: seen)
            outcome.refused = read?.refused ?? []
            newState = state
            apply(outcome, to: document, core: core, current: current)
            return outcome
        }
        if let newState { defaults.setPersistedData(try? JSONEncoder().encode(newState), forKey: Self.stateKey) }
        return outcomes
    }

    /// Puts one outcome into one document's library and says what changed.
    private func apply(_ outcome: Outcome, to document: ZenitPDFProjectDocument, core: AppCoreEnvironment, current: [ToolPresetSummary]) {
        let refused = outcome.refused
        guard outcome.presets != current else { return }
        document.applyToolPresets(outcome.presets)
        if outcome.changed || !refused.isEmpty {
            var parts: [String] = []
            if !outcome.updated.isEmpty {
                parts.append(String(format: NSLocalizedString("Updated: %@.", comment: "Subscribed library note: updated sets"), outcome.updated.joined(separator: ", ")))
            }
            if !outcome.added.isEmpty {
                parts.append(String(format: NSLocalizedString("New tools: %@.", comment: "Subscribed library note: new tools"), outcome.added.joined(separator: ", ")))
            }
            if !outcome.removed.isEmpty {
                parts.append(String(format: NSLocalizedString("Removed: %@.", comment: "Subscribed library note: removed tools"), outcome.removed.joined(separator: ", ")))
            }
            if !refused.isEmpty {
                parts.append(String(format: NSLocalizedString("Not read (not a valid tool set): %@.", comment: "Subscribed library note: refused files"), refused.joined(separator: ", ")))
            }
            parts.append(NSLocalizedString("Markups already placed are unchanged.", comment: "Subscribed library note: placed markups unchanged"))
            core.document.post(AppWarning(
                id: Self.noteID, severity: refused.isEmpty ? .info : .warning,
                title: NSLocalizedString("The office tool library changed", comment: "Subscribed library note title"),
                message: parts.joined(separator: " "),
                source: NSLocalizedString("Office library", comment: "Subscribed library note source"),
                isDismissible: true, timestamp: Date()))
        }
    }
}

private extension ToolPresetSummary {
    /// The same preset under another identity, every other field kept — through its own coding,
    /// so a field added to the preset later travels too.
    func reidentified(_ id: UUID) -> ToolPresetSummary? {
        guard let data = try? JSONEncoder().encode(self),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["id"] = id.uuidString
        guard let changed = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ToolPresetSummary.self, from: changed)
    }
}
