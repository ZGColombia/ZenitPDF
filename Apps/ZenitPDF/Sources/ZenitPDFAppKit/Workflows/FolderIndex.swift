import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFSearch
import ZPDFUIPresentation

/// The folder index of closed drawings (NL-DOCS-15): the text of every PDF in a folder the person
/// chose, searchable without opening any of them.
///
/// - **One folder, granted.** The folder is chosen through the one modal door and remembered as a
///   security-scoped bookmark in the layout store; its scope is held while it is granted, so a
///   result can be opened, and ended by Forget.
/// - **One index per drawing, keyed by SHA-256.** Each drawing's text layer is read into a
///   ``ZPDFAppCore/DocumentSearchIndex`` of its own — the same index an open drawing uses — named
///   after its bytes, so two copies of one file share an index and a renamed file keeps its own.
///   A catalogue beside the indexes maps each file, by path relative to the folder, to its hash,
///   size and date: an unchanged file is not read again, and an index no file names any more is
///   deleted.
/// - **Local, and read only.** Nothing is written into the folder. The indexes live in the
///   application's own search directory.
@MainActor
final class FolderIndex {

    static let shared = FolderIndex()

    /// Where the folder bookmark lives: the process store outside the assembled bundle; a test
    /// injects its own.
    var defaults: any ZPDFDefaultsStoring = ZenitProcessDefaults.layout

    /// Where the per-drawing indexes and the catalogue live.
    var root: URL = ZenitPDFProjectDocument.searchIndexRoot.appendingPathComponent("Folder Index", isDirectory: true)

    static let folderKey = "Zenit.FolderIndex.Folder"
    static let catalogueName = "catalogue.json"
    /// The most drawings one folder index reads: a folder larger than this is indexed up to it
    /// and the rest are named in the report.
    nonisolated static let maximumDrawings = 2_000

    /// The folder whose security scope this index holds, while it is granted.
    private var accessedFolder: URL?

    // MARK: - The folder

    /// The granted folder, resolved from its bookmark (a plain path where no bookmark could be
    /// made, as in a test process), or `nil`.
    var folder: URL? {
        guard let data = defaults.persistedData(forKey: Self.folderKey) else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return String(data: data, encoding: .utf8).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Grants `url`: remembers it and starts its security scope. A different folder than before
    /// starts a fresh catalogue; the old indexes go at the next rebuild.
    ///
    /// A rebuild still running is for the folder this grant replaces, and starting the new scope
    /// stops the one it reads through (T-012): it is stopped like Forget stops it, at its next
    /// drawing, and keeps nothing, rather than saving a catalogue of files it could no longer
    /// read and deleting their indexes. The command refuses the grant first; this is the floor.
    func grant(_ url: URL) {
        if isIndexing { grantGeneration &+= 1 }
        let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? Data(url.path.utf8)
        defaults.setPersistedData(data, forKey: Self.folderKey)
        startAccess()
    }

    /// Starts the granted folder's security scope, once.
    @discardableResult
    func startAccess() -> URL? {
        guard let folder else { return nil }
        if let accessedFolder, accessedFolder.standardizedFileURL == folder.standardizedFileURL { return folder }
        stopAccess()
        if folder.startAccessingSecurityScopedResource() { accessedFolder = folder }
        return folder
    }

    private func stopAccess() {
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
    }

    /// Forgets the folder: its bookmark, its scope, the catalogue and every index. A rebuild that
    /// is running stops at its next drawing and deletes what it wrote since (S-015).
    func revoke() {
        grantGeneration &+= 1
        defaults.setPersistedData(nil, forKey: Self.folderKey)
        stopAccess()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The catalogue

    struct CatalogueEntry: Codable, Equatable, Sendable {
        /// The file's path inside the folder.
        var relativePath: String
        var sha256: String
        var byteCount: Int
        /// The file's modification date, as seconds since the reference date.
        var modified: Double
        var pageCount: Int
    }

    struct Catalogue: Codable, Equatable, Sendable {
        var folderPath: String
        var entries: [CatalogueEntry]
    }

    func loadCatalogue() -> Catalogue? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(Self.catalogueName)) else { return nil }
        return try? JSONDecoder().decode(Catalogue.self, from: data)
    }

    private func saveCatalogue(_ catalogue: Catalogue) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(catalogue) else { return }
        try? data.write(to: root.appendingPathComponent(Self.catalogueName), options: .atomic)
    }

    /// The index file of one drawing, by its bytes.
    nonisolated static func indexURL(sha256: String, root: URL) -> URL {
        root.appendingPathComponent(sha256).appendingPathExtension("sqlite")
    }

    // MARK: - Finding the drawings

    /// Every PDF under `folder`, by path, hidden files and packages (a project's own drawings)
    /// left out; at most `limit`, and whether there were more.
    nonisolated static func drawings(in folder: URL, limit: Int = maximumDrawings) -> (files: [URL], truncated: Bool) {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], false) }
        var files: [URL] = []
        for case let url as URL in enumerator {
            // A project package is skipped by name as well: outside the assembled application
            // the system may not know `.zpdfproj` is a package.
            if url.pathExtension.lowercased() == ProjectPackageLayout.fileExtension {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "pdf",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(url)
        }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        files.sort { relativePath(of: $0, base: base).localizedStandardCompare(relativePath(of: $1, base: base)) == .orderedAscending }
        return (Array(files.prefix(limit)), files.count > limit)
    }

    /// `url`'s path below `base`.
    nonisolated static func relativePath(of url: URL, base: String) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    // MARK: - Indexing

    struct Report: Equatable, Sendable {
        var indexed = 0
        var unchanged = 0
        /// Files that could not be indexed, each with the reason.
        var skipped: [Skip] = []
        /// More PDFs than ``FolderIndex/maximumDrawings`` were found.
        var truncated = false

        struct Skip: Equatable, Sendable {
            var relativePath: String
            var reason: String
        }
    }

    /// Whether a rebuild is running.
    private(set) var isIndexing = false

    /// Bumped by every Forget. A rebuild remembers the value it started under, and one that sees
    /// it change stops and deletes what it wrote: Forget used to delete the index while a running
    /// rebuild went on writing indexes and, at its end, the catalogue, so the text of the drawings
    /// read so far was back on disk after the note said it was deleted (S-015). Bumped too by a
    /// grant of another folder while a rebuild runs (T-012).
    private var grantGeneration = 0

    /// Whether the catalogue on disk belongs to the granted folder. A catalogue of another folder
    /// is left from before a new grant, until the new folder's first rebuild finishes (S-014).
    var isCatalogueCurrent: Bool {
        guard let folder, let catalogue = loadCatalogue() else { return false }
        return catalogue.folderPath == folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Reads every drawing in the granted folder into its index. An unchanged file (same size
    /// and date) is kept as it is; a new or changed one is hashed and read; an index no file names
    /// any more is deleted. Returns `nil` when there is no folder or a rebuild is running.
    @discardableResult
    func rebuild(progress: (@MainActor (Int, Int) -> Void)? = nil) async -> Report? {
        guard !isIndexing, let folder = startAccess() else { return nil }
        isIndexing = true
        defer { isIndexing = false }
        let generation = grantGeneration
        let root = self.root
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let previous = loadCatalogue().flatMap { $0.folderPath == base ? $0 : nil }
        let known = Dictionary((previous?.entries ?? []).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let (files, truncated) = await Task.detached(priority: .utility) { Self.drawings(in: folder) }.value
        var report = Report(truncated: truncated)
        var entries: [CatalogueEntry] = []
        for (position, file) in files.enumerated() {
            if Task.isCancelled || grantGeneration != generation { break }
            let relative = Self.relativePath(of: file, base: base)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? -1
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            if let entry = known[relative], entry.byteCount == size, entry.modified == modified,
               FileManager.default.fileExists(atPath: Self.indexURL(sha256: entry.sha256, root: root).path) {
                entries.append(entry)
                report.unchanged += 1
            } else {
                do {
                    let entry = try await Self.index(file: file, relativePath: relative, byteCount: size, modified: modified, root: root)
                    entries.append(entry)
                    report.indexed += 1
                } catch {
                    report.skipped.append(Report.Skip(relativePath: relative, reason: Self.reason(for: error)))
                }
            }
            progress?(position + 1, files.count)
        }
        // Forgotten while it ran: whatever it wrote goes, and nothing is recorded.
        guard grantGeneration == generation else {
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        saveCatalogue(Catalogue(folderPath: base, entries: entries))
        // An index no file names any more — the file was deleted, changed or moved out.
        let used = Set(entries.map(\.sha256))
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "sqlite" && !used.contains(url.deletingPathExtension().lastPathComponent) {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        return report
    }

    /// Reads one drawing's text layer into its own index.
    nonisolated static func index(file: URL, relativePath: String, byteCount: Int, modified: Double, root: URL) async throws -> CatalogueEntry {
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(.url(file), password: nil)
        // A locked drawing opens but yields no text: said, not indexed as empty.
        guard !opened.descriptor.encryption.isLocked else {
            await provider.closeAll()
            throw PDFBridgeError.passwordRequired
        }
        let descriptors: [PDFPageDescriptor]
        do {
            descriptors = try await provider.pageDescriptors(of: opened.handle, range: nil)
        } catch {
            await provider.closeAll()
            throw error
        }
        await provider.closeAll()
        let digest = opened.descriptor.digest
        let documentID = DocumentID(UUID())
        let pages = try descriptors.map { try DocumentSessionLoader.contractPage(from: $0, documentID: documentID) }
        let index = try await DocumentSearchIndex.open(
            databaseAt: indexURL(sha256: digest.sha256, root: root),
            drawingAt: file,
            displayName: file.deletingPathExtension().lastPathComponent,
            pages: pages,
            knownDigest: digest
        )
        do {
            _ = try await index.indexDrawingText()
        } catch {
            await index.shutDown()
            throw error
        }
        await index.shutDown()
        return CatalogueEntry(relativePath: relativePath, sha256: digest.sha256, byteCount: byteCount, modified: modified, pageCount: pages.count)
    }

    nonisolated static func reason(for error: any Error) -> String {
        switch error as? PDFBridgeError {
        case .passwordRequired?, .incorrectPassword?, .documentLocked?:
            return NSLocalizedString("locked with a password", comment: "Folder index skip reason")
        default:
            break
        }
        return NSLocalizedString("could not be read as a PDF", comment: "Folder index skip reason")
    }

    // MARK: - Searching

    struct Hit: Equatable, Sendable, Identifiable {
        var id: String { "\(relativePath)#\(pageIndex)#\(snippet)" }
        var fileURL: URL
        var relativePath: String
        var pageIndex: Int
        var pageLabel: String
        var snippet: String
    }

    /// The hits of one file, in page order.
    struct FileHits: Equatable, Sendable, Identifiable {
        var id: String { relativePath }
        var fileURL: URL
        var relativePath: String
        var hits: [Hit]
    }

    /// Searches every indexed drawing for `text`: the files with hits, in folder order, each with
    /// its hits in page order. Nothing is opened but the indexes.
    func search(_ text: String, limit: Int = 200) async -> [FileHits] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let folder, let catalogue = loadCatalogue() else { return [] }
        // Only the granted folder's catalogue (S-014): after a new grant, the old folder's entries
        // joined onto the new folder's path listed hits that opened nothing, or another file.
        guard catalogue.folderPath == folder.standardizedFileURL.resolvingSymlinksInPath().path else { return [] }
        let root = self.root
        let bySHA = Dictionary(grouping: catalogue.entries, by: \.sha256)
        var hitsBySHA: [String: [ZPDFSearch.SearchHit]] = [:]
        for sha in bySHA.keys {
            if Task.isCancelled { return [] }
            hitsBySHA[sha] = await Self.searchIndex(sha256: sha, text: trimmed, limit: limit, root: root)
        }
        return catalogue.entries.compactMap { entry -> FileHits? in
            guard let hits = hitsBySHA[entry.sha256], !hits.isEmpty else { return nil }
            let fileURL = folder.appendingPathComponent(entry.relativePath)
            let rows = hits
                .compactMap { hit -> Hit? in
                    guard let page = hit.pageIndex else { return nil }
                    return Hit(
                        fileURL: fileURL, relativePath: entry.relativePath, pageIndex: page,
                        pageLabel: hit.pageLabel ?? String(page + 1), snippet: hit.snippet
                    )
                }
                .sorted { $0.pageIndex < $1.pageIndex }
            return rows.isEmpty ? nil : FileHits(fileURL: fileURL, relativePath: entry.relativePath, hits: rows)
        }
    }

    /// One index's hits for `text`, read without the drawing.
    nonisolated static func searchIndex(sha256: String, text: String, limit: Int, root: URL) async -> [ZPDFSearch.SearchHit] {
        guard let database = try? await ProjectDatabaseActor.open(
            at: indexURL(sha256: sha256, root: root), readOnly: true, migrate: false
        ) else { return [] }
        let service = SearchService(database: database)
        let results = try? await service.search(SearchRequest(
            text: text,
            scope: .project(projectId: "zenit.search." + sha256),
            maximumHits: limit,
            resolvesBounds: false
        ))
        try? await database.close()
        return results?.hits ?? []
    }
}
