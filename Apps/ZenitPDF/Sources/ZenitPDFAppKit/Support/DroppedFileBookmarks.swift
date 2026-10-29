import Foundation
import ZPDFUIPresentation

/// Security-scoped bookmarks for files that arrived by drag and drop.
///
/// Under the App Sandbox a dropped file arrives with implicit access, but that access does not
/// survive a relaunch. The classic bug is taking no bookmark at drop
/// time and silently failing to reopen the file from Open Recent next session. So: the bookmark
/// is taken **at drop time**, while the implicit access is still alive, and resolved before any
/// later open of the same path.
///
/// Storage is a defaults store, keyed by the file's path. There is no default argument: the
/// product passes ``ZenitProcessDefaults/bookmarks`` (the real domain only inside the assembled
/// bundle), so no test can reach the user's preferences through a forgotten parameter. A bookmark is small (a few hundred
/// bytes) and the store is capped, oldest first, so a career of drops cannot grow it without
/// bound.
public enum DroppedFileBookmarks {

    static let defaultsKey = "zenit.droppedFileBookmarks"
    static let capacity = 200

    /// Takes and stores a security-scoped bookmark for a just-dropped file.
    ///
    /// A failure is not reported to the user: at drop time the file opens regardless, and the
    /// bookmark only matters for the *next* session. The failure is left in the log.
    public static func remember(_ url: URL, defaults: any ZPDFDefaultsStoring) {
        guard url.isFileURL else { return }
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var store = load(defaults: defaults)
        store.removeAll { $0.path == url.path }
        store.append(Entry(path: url.path, bookmark: data, storedAt: Date()))
        if store.count > capacity {
            store.removeFirst(store.count - capacity)
        }
        save(store, defaults: defaults)
    }

    /// Takes bookmarks for the files among `urls` that have none yet, reading and writing the
    /// store once. What the window session records on every change: the drawings it names are
    /// usually bookmarked already, and taking a fresh bookmark and rewriting the store for each
    /// of them on every edit was the cost R-021 measured. A stale bookmark is refreshed where
    /// it is resolved, in ``beginAccess(forPath:defaults:)``.
    public static func rememberMissing(_ urls: [URL], defaults: any ZPDFDefaultsStoring) {
        var store = load(defaults: defaults)
        var known = Set(store.map(\.path))
        var changed = false
        for url in urls where url.isFileURL && !known.contains(url.path) {
            guard let data = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { continue }
            store.append(Entry(path: url.path, bookmark: data, storedAt: Date()))
            known.insert(url.path)
            changed = true
        }
        guard changed else { return }
        if store.count > capacity {
            store.removeFirst(store.count - capacity)
        }
        save(store, defaults: defaults)
    }

    /// Resolves a stored bookmark for a path and starts security-scoped access on it.
    ///
    /// Returns the resolved URL — which must be the one actually opened, because a stale
    /// bookmark can point at a moved file — or `nil` when no bookmark is stored. The caller
    /// owns the matching `stopAccessingSecurityScopedResource`; in practice access is held
    /// for the lifetime of the open document, which is the sandbox's own model.
    public static func beginAccess(forPath path: String, defaults: any ZPDFDefaultsStoring) -> URL? {
        var store = load(defaults: defaults)
        guard let index = store.firstIndex(where: { $0.path == path }) else { return nil }
        var isStale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: store[index].bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // Only a bookmark that can never resolve is dropped. An unmounted drive or a
            // share that is offline fails the same call, and deleting then left nothing to
            // reopen the file with once the drive came back (BH-897).
            if Self.isPermanentResolveFailure(error) {
                store.remove(at: index)
                save(store, defaults: defaults)
            }
            return nil
        }
        if isStale, let fresh = try? resolved.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            store[index] = Entry(path: resolved.path, bookmark: fresh, storedAt: Date())
            save(store, defaults: defaults)
        }
        guard resolved.startAccessingSecurityScopedResource() else { return nil }
        return resolved
    }

    /// Whether a bookmark is stored for a path. For tests.
    public static func hasBookmark(forPath path: String, defaults: any ZPDFDefaultsStoring) -> Bool {
        load(defaults: defaults).contains { $0.path == path }
    }

    /// Removes everything. For tests.
    public static func removeAll(defaults: any ZPDFDefaultsStoring) {
        defaults.setPersistedData(nil, forKey: defaultsKey)
    }

    // MARK: - Storage

    struct Entry: Codable {
        var path: String
        var bookmark: Data
        var storedAt: Date
    }

    /// Where a store this build cannot decode is set aside, so the first new drop does not
    /// write over every bookmark an earlier (or later) build took (BH-898).
    static let undecodableBackupKey = "zenit.droppedFileBookmarks.undecodable"

    /// Whether a resolve error means the bookmark itself is unusable — its data is corrupt —
    /// rather than that its file is out of reach right now.
    static func isPermanentResolveFailure(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.fileReadCorruptFile.rawValue
    }

    private static func load(defaults: any ZPDFDefaultsStoring) -> [Entry] {
        guard let data = defaults.persistedData(forKey: defaultsKey) else { return [] }
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) { return entries }
        // Treated as empty, but never lost: the first blob that failed to decode is kept.
        if defaults.persistedData(forKey: undecodableBackupKey) == nil {
            defaults.setPersistedData(data, forKey: undecodableBackupKey)
        }
        return []
    }

    private static func save(_ entries: [Entry], defaults: any ZPDFDefaultsStoring) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.setPersistedData(data, forKey: defaultsKey)
    }
}
