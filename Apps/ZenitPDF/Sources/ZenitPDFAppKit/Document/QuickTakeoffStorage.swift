import Foundation
import ZPDFPersistence

/// Quick PDF Mode's container-side takeoff storage, as one
/// serialized type (IM-181).
///
/// An unsaved quick takeoff lives in the app container until the person chooses a real home for
/// it: an autosave package and the audit-trail database, both under ``directory``. This state
/// used to be six loose fields on the document — the package, the history database, the
/// debounce task, the in-flight autosave, the restored directory and the "established" flag —
/// and it caused the documented create-if-absent race: two autosaves interleaving at the await
/// inside `ProjectPackage.create`, the second deleting the directory the first had an open
/// SQLite file in (`SQLite error 10: disk I/O error`).
///
/// ### One queue
///
/// Every operation that touches the container — ``flush()``, ``openHistoryDatabase()`` and
/// ``retire()`` — runs through one internal FIFO queue, so no two of them ever interleave at
/// an await. ``shutDown()`` is queued too, but waits only for the autosaves queued before it —
/// quit waits on it — and a history open it overtakes closes its own database. A future caller (a new promotion path, say) cannot bypass it:
/// the handles are `private(set)` and the only write that skips the queue is ``write()``, which
/// exists for the document's test seam and is documented as such.
///
/// The document keeps one instance and delegates to it; nothing here knows about `NSDocument`,
/// so the storage is testable without a document or a window.
@MainActor
final class QuickTakeoffStorage {

    /// What a new container package is created from.
    struct Origin: Sendable {
        let originalPDF: URL
        let pageCount: Int
        let displayName: String
    }

    /// The container package's name inside ``directory``.
    nonisolated static let packageName = "Autosave.\(ProjectPackageLayout.fileExtension)"

    /// Where the container package lives inside an autosave directory.
    nonisolated static func packageURL(in directory: URL) -> URL {
        directory.appendingPathComponent(packageName, isDirectory: true)
    }

    // MARK: - Configuration

    /// This takeoff's own directory when it did not restore an earlier one. Evaluated on every
    /// read, so an override of the autosave root set after construction still applies.
    private let defaultDirectory: @MainActor () -> URL

    /// What to create a container package from. Throws when the owning document cannot autosave right
    /// now — not in Quick PDF Mode, or no drawing yet — and the throw is the write's answer.
    var origin: @MainActor () throws -> Origin

    /// Writes the in-session takeoff into the container package (the document's archive writer).
    var writeArchive: @MainActor (ProjectPackage) async throws -> Void

    /// Told after each successful write: `true` for the one full package save a container gets
    /// when it is created, `false` for every light write after it (IM-048).
    var didWrite: @MainActor (_ fullSave: Bool) -> Void = { _ in }

    init(
        defaultDirectory: @escaping @MainActor () -> URL,
        origin: @escaping @MainActor () throws -> Origin,
        writeArchive: @escaping @MainActor (ProjectPackage) async throws -> Void
    ) {
        self.defaultDirectory = defaultDirectory
        self.origin = origin
        self.writeArchive = writeArchive
    }

    // MARK: - State

    /// The container autosave package, once created or restored.
    private(set) var package: ProjectPackage?

    /// The container's audit-trail database, once the History feed has attached it.
    private(set) var historyDatabase: ProjectDatabaseActor?

    /// Whether the container package has had its one full save (IM-048).
    private(set) var isEstablished = false

    /// The autosave directory of an earlier session this takeoff restored and continues in,
    /// instead of starting a fresh one (CR-153).
    private var directoryOverride: URL?

    /// The debounced autosave, if one is scheduled.
    private var debounce: Task<Void, Never>?

    /// The last operation in the queue. Each new operation waits for it before it starts.
    private var tail: Task<Void, Never>?

    /// The queue position just after the latest autosave, so a shutdown can wait for every
    /// write queued before it without waiting for anything else.
    private var lastWrite: Task<Void, Never>?

    /// Bumped by every ``shutDown()``. A history open that finishes after a shutdown it was
    /// queued before closes what it opened instead of keeping it.
    private var shutdownEpoch = 0

    /// Operations queued or running. Test seam: zero means the queue is idle.
    private(set) var pendingOperations = 0

    /// This takeoff's autosave directory inside the container.
    var directory: URL { directoryOverride ?? defaultDirectory() }

    /// Whether any container handle is still open — what quit must wait to close.
    var holdsStorage: Bool { package != nil || historyDatabase != nil }

    // MARK: - Operations

    /// Debounced autosave: edits coalesce for a moment, then land as one queued ``flush()``.
    func schedule(after delay: Duration = .seconds(1)) {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            _ = try? await self?.flush()
        }
    }

    /// Cancels a scheduled autosave that has not fired yet. Synchronous, so a closing document
    /// stops the debounce before it awaits anything.
    func cancelScheduled() {
        debounce?.cancel()
    }

    /// Writes the quick takeoff into its container package and returns where, queued behind
    /// every earlier operation. Each caller still gets a real save of the state at its turn.
    @discardableResult
    func flush() async throws -> URL {
        try await serialized(isWrite: true) { try await self.write() }
    }

    /// The write itself, **outside the queue**. Only ``flush()`` and the document's test seam
    /// (`performQuickPDFAutosave`) call it; everything in the product goes through ``flush()``.
    func write() async throws -> URL {
        let origin = try origin()
        let directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packageURL = Self.packageURL(in: directory)
        if package == nil {
            if FileManager.default.fileExists(atPath: packageURL.path) {
                try FileManager.default.removeItem(at: packageURL)
            }
            package = try await ProjectPackage.create(
                at: packageURL,
                displayName: origin.displayName,
                originalPDF: origin.originalPDF,
                pageCount: origin.pageCount
            )
        }
        if let package {
            // The container package is edited in place and its database is durable on every
            // commit; the restore opens it with `.recover` and reads the live database. So an
            // edit needs the archive written and nothing else — the full package save (PDF
            // re-hash, manifest, integrity, version rotation) ran one second after every edit
            // and bought nothing (IM-048). It runs once, when the container is created.
            try await writeArchive(package)
            if !isEstablished {
                _ = try await package.save()
                isEstablished = true
                didWrite(true)
            } else {
                didWrite(false)
            }
        }
        return packageURL
    }

    /// Continues in an earlier session's container, which the person chose to restore
    /// (CR-153). The package was opened with `.recover` and already holds a full save.
    func adoptRestored(package: ProjectPackage, directory: URL) {
        directoryOverride = directory
        self.package = package
        isEstablished = true
    }

    /// Opens the container's audit-trail database for the History feed,
    /// queued so it can never land in a directory a retire is removing.
    func openHistoryDatabase() async throws -> ProjectDatabaseActor {
        let epoch = shutdownEpoch
        return try await serialized {
            let directory = self.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database: ProjectDatabaseActor
            do {
                database = try await ProjectDatabaseActor.open(
                    at: directory.appendingPathComponent("history.sqlite")
                )
            } catch {
                self.removeDirectoryIfDiscarded(since: epoch, directory)
                throw error
            }
            // The document shut down while this was queued or opening: close it, never leak it.
            guard epoch == self.shutdownEpoch else {
                try? await database.close()
                // A discarding shutdown ran while this open was creating the file it removes.
                self.removeDirectoryIfDiscarded(since: epoch, directory)
                throw CancellationError()
            }
            self.historyDatabase = database
            return database
        }
    }

    /// Removes the container autosave — Don't Save, Discard All, or a completed promotion.
    /// Waits for an autosave already writing, so it never closes a package under a write.
    func retire() async {
        debounce?.cancel()
        debounce = nil
        _ = try? await serialized {
            await self.closeHandles()
            try? FileManager.default.removeItem(at: self.directory)
        }
    }

    /// Closes the container handles. By default it keeps the directory: an edited takeoff's
    /// autosave is its crash-survival copy. Idempotent; a second call finds nothing open.
    ///
    /// `discardingDirectory` is for a takeoff with nothing to survive — saved, discarded or never
    /// edited: the directory goes too, with the `history.sqlite` the History feed opened in it at
    /// load. Quit used to shut such a takeoff down keeping it, and every clean quick PDF open at
    /// quit left an `Autosave/<UUID>/history.sqlite` behind (L-31).
    ///
    /// Waits for every autosave queued before it — never closes a package under a write — but
    /// not for a history open: quit waits on this, and a history database that finishes
    /// opening afterwards closes itself (``openHistoryDatabase()``), removing the directory it
    /// created when this shutdown discards it.
    func shutDown(discardingDirectory: Bool = false) async {
        debounce?.cancel()
        shutdownEpoch += 1
        if discardingDirectory { discardedEpoch = shutdownEpoch }
        _ = try? await serialized(waitingOnlyFor: lastWrite) {
            await self.closeHandles()
            if discardingDirectory { try? FileManager.default.removeItem(at: self.directory) }
        }
    }

    /// The epoch of the latest shutdown that discarded the directory; 0 when none has.
    private var discardedEpoch = 0

    /// Removes `directory` when a discarding shutdown came after the operation that started in
    /// `epoch` — the operation's own files would otherwise outlive the discard.
    private func removeDirectoryIfDiscarded(since epoch: Int, _ directory: URL) {
        guard discardedEpoch > epoch else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func closeHandles() async {
        let autosave = package
        let history = historyDatabase
        package = nil
        isEstablished = false
        historyDatabase = nil
        try? await autosave?.close()
        try? await history?.close()
    }

    /// Runs `body` after every operation queued before it, and before every one queued after.
    ///
    /// `waitingOnlyFor` lets an operation start after an earlier point in the queue than its
    /// end (``shutDown()`` after the last write). Operations queued after it still wait for
    /// everything before them, so the queue stays FIFO for them.
    private func serialized<T: Sendable>(
        isWrite: Bool = false,
        waitingOnlyFor predecessor: Task<Void, Never>?? = .none,
        _ body: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tail
        let waitFor = predecessor ?? previous
        pendingOperations += 1
        let operation = Task { @MainActor in
            await waitFor?.value
            return try await body()
        }
        tail = Task { @MainActor [weak self] in
            _ = try? await operation.value
            await previous?.value
            self?.pendingOperations -= 1
        }
        if isWrite { lastWrite = tail }
        return try await operation.value
    }

    // MARK: - The container root (CR-153)

    /// One container autosave that could be restored for a drawing.
    struct Restorable: Sendable {
        let directory: URL
        let packageURL: URL
        let autosavedAt: Date?
    }

    /// The most recent container autosave under `root` written for a drawing with this digest,
    /// skipping the directories in `live` (autosaves of documents open in this process).
    ///
    /// Matched through each package's own `manifest.json` rather than by opening it: an
    /// open assesses recovery and touches the database, and there may be several candidates.
    nonisolated static func restorable(
        matchingDigest digest: String,
        in root: URL,
        sparing live: Set<String>
    ) -> Restorable? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return nil }
        var best: Restorable?
        for directory in entries where !live.contains(directory.resolvingSymlinksInPath().path) {
            let packageURL = packageURL(in: directory)
            let manifestURL = packageURL.appendingPathComponent(ProjectPackageLayout.manifest)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ProjectManifest.self, from: data),
                  manifest.originalPdfSha256 == digest
            else { continue }
            let stamp = lastWritten(packageURL: packageURL)
            if let current = best, let a = current.autosavedAt, let b = stamp, a >= b { continue }
            best = Restorable(directory: directory, packageURL: packageURL, autosavedAt: stamp)
        }
        return best
    }

    /// Removes container autosaves under `root` nobody has come back for, sparing `live`.
    /// - Returns: the directories removed.
    nonisolated static func removeStale(
        in root: URL,
        sparing live: Set<String>,
        olderThan age: TimeInterval,
        now: Date
    ) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        var removed: [URL] = []
        for directory in entries where !live.contains(directory.resolvingSymlinksInPath().path) {
            // The same stamp ``restorable(matchingDigest:in:sparing:)`` offers a restore by.
            // Judged by the manifest alone, a restored container — established, so only ever
            // light-autosaved into its database — kept its creation date and was swept at
            // launch although it had been written the day before (R-020).
            let written = lastWritten(packageURL: packageURL(in: directory))
                ?? (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified = written, now.timeIntervalSince(modified) > age else { continue }
            if (try? manager.removeItem(at: directory)) != nil { removed.append(directory) }
        }
        return removed
    }

    /// When a container package was last written: the newest of its manifest, its database
    /// and the database's WAL, because the container is autosaved into its database without
    /// rewriting the manifest (IM-048). `nil` when none of the three exists.
    nonisolated static func lastWritten(packageURL: URL) -> Date? {
        [
            packageURL.appendingPathComponent(ProjectPackageLayout.manifest),
            packageURL.appendingPathComponent(ProjectPackageLayout.database),
            packageURL.appendingPathComponent(ProjectPackageLayout.database + "-wal")
        ]
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
