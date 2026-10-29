import Foundation
import os

/// The layout of a Shared Review Folder, and the only reads and writes this package makes in it
/// (NL-COLLAB-12).
///
/// ```
/// <folder>/
///   review.json                      format version and the project this folder reviews
///   participants/<id>.zlog           one append-only operation log per participant
///   participants/<id>.presence       who, and when they last synced
/// ```
///
/// **One writer per file.** A participant writes its own log and presence file and nothing else;
/// every other file is only read. Two machines therefore never write the same file, which is the
/// failure that corrupts databases and whole-package saves on synced storage. The project database
/// itself never goes into the folder.
public struct SharedReviewFolder: Sendable {

    public static let formatVersion = 1
    public static let manifestName = "review.json"
    public static let participantsDirectory = "participants"
    public static let logExtension = "zlog"
    public static let presenceExtension = "presence"
    /// A participant id is used as a file name, so it is held to a safe alphabet.
    public static func isValidParticipantID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public struct Manifest: Codable, Hashable, Sendable {
        public var formatVersion: Int
        public var projectID: String
        public var projectName: String
        public var createdAt: Date
    }

    /// A heartbeat: who, when they last synced or looked in, and where they are looking.
    public struct Presence: Codable, Hashable, Sendable {
        public var participantID: String
        public var name: String
        public var lastSync: Date
        /// The sheet in front of them, by its label ("A-201"); absent before round 2.
        public var pageLabel: String?
        /// How many markups they have selected; absent before round 2.
        public var selectedCount: Int?

        public init(participantID: String, name: String, lastSync: Date, pageLabel: String? = nil, selectedCount: Int? = nil) {
            self.participantID = participantID
            self.name = name
            self.lastSync = lastSync
            self.pageLabel = pageLabel
            self.selectedCount = selectedCount
        }
    }

    public enum FolderError: Error, Equatable, Sendable {
        /// The folder reviews another project.
        case otherProject(name: String)
        /// A newer build wrote the folder.
        case newerFormat(Int)
        case invalidParticipant
        case unwritable(String)
        /// A file the folder holds could not be read, so nothing was written over it (T-078): the
        /// manifest, or this participant's own log. Folder-relative file names.
        case unreadable(files: [String])
        /// This participant's log would pass ``OperationLogCodec/maximumLogBytes`` even compacted,
        /// and a reader refuses a log that size (T-079). Nothing was written.
        case logFull
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    var manifestURL: URL { url.appendingPathComponent(Self.manifestName) }
    var participantsURL: URL { url.appendingPathComponent(Self.participantsDirectory, isDirectory: true) }

    func logURL(_ participant: String) -> URL {
        participantsURL.appendingPathComponent("\(participant).\(Self.logExtension)")
    }

    func presenceURL(_ participant: String) -> URL {
        participantsURL.appendingPathComponent("\(participant).\(Self.presenceExtension)")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The largest manifest read. A real one is a few hundred bytes.
    public static let maximumManifestBytes = 64 * 1024

    /// Makes the folder ready for this project, or confirms it already is. A folder that reviews
    /// another project is refused rather than mixed.
    ///
    /// A new manifest is written only where there is none (T-078). A manifest that is there and
    /// cannot be read — evicted by a sync service while offline, a read error on a share, damage —
    /// used to be taken for a missing one and written over, which could claim another project's
    /// folder for this one. It is refused instead.
    @discardableResult
    public func prepare(projectID: String, projectName: String, now: Date = Date()) throws -> Manifest {
        let manager = FileManager.default
        switch Self.readRegularFile(manifestURL, limit: Self.maximumManifestBytes) {
        case .data(let data):
            // A newer build's manifest is refused as that, even where this build cannot read the rest.
            if let probe = try? Self.decoder.decode(FormatProbe.self, from: data), probe.formatVersion > Self.formatVersion {
                throw FolderError.newerFormat(probe.formatVersion)
            }
            guard let manifest = try? Self.decoder.decode(Manifest.self, from: data) else {
                throw FolderError.unreadable(files: [Self.manifestName])
            }
            guard manifest.projectID == projectID else { throw FolderError.otherProject(name: manifest.projectName) }
            try? manager.createDirectory(at: participantsURL, withIntermediateDirectories: true)
            return manifest
        case .unreadable:
            throw FolderError.unreadable(files: [Self.manifestName])
        case .missing:
            break
        }
        let manifest = Manifest(formatVersion: Self.formatVersion, projectID: projectID, projectName: projectName, createdAt: now)
        do {
            try manager.createDirectory(at: participantsURL, withIntermediateDirectories: true)
            try Self.encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            throw FolderError.unwritable(error.localizedDescription)
        }
        return manifest
    }

    private struct FormatProbe: Decodable {
        var formatVersion: Int
    }

    /// Appends to this participant's own log: only the new lines are written, at the end of the
    /// file, and nothing the log already holds is read back or rewritten (T-078).
    ///
    /// The log used to be read whole, extended and written back through a rename, and every read
    /// error was taken for an empty log — an evicted file read offline, an I/O error on a share —
    /// so the rewrite left only this sync's changes, and every markup this person had ever
    /// published was then removed on every machine. Now the one byte read is the log's last, to
    /// know whether a newline is owed; a log whose end cannot be read, or that is not a regular
    /// file, is refused with ``FolderError/unreadable(files:)`` and left as it was. A write that
    /// fails part-way is cut back to the old length. A reader that meets the lines half-written
    /// skips the unterminated last one until it is whole (``OperationLogCodec``).
    ///
    /// A log that the new lines would take past `limit` is compacted first
    /// (``ReviewLogCompaction``) and replaced whole through a rename; one that is still too large
    /// compacted is refused with ``FolderError/logFull`` (T-079).
    public func append(_ operations: [ReviewOperation], participant: String, now: Date = Date(),
                       limit: Int = OperationLogCodec.maximumLogBytes) throws {
        guard Self.isValidParticipantID(participant) else { throw FolderError.invalidParticipant }
        guard !operations.isEmpty else { return }
        let lines: Data
        do {
            lines = try OperationLogCodec.encode(operations)
            try FileManager.default.createDirectory(at: participantsURL, withIntermediateDirectories: true)
        } catch {
            throw FolderError.unwritable(error.localizedDescription)
        }
        let url = logURL(participant)
        let name = url.lastPathComponent
        var info = stat()
        // Whether this append creates the log (V-090): a new name is durable only once the
        // directory that records it is flushed too.
        var creates = false
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw FolderError.unreadable(files: [name]) }
        } else if errno == ENOENT {
            creates = true
        } else {
            throw FolderError.unreadable(files: [name])
        }
        // O_NONBLOCK: a FIFO swapped in after the check fails the open instead of blocking it.
        let flags = O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var descriptor = open(url.path, flags | (creates ? O_EXCL : 0), 0o644)
        if descriptor < 0, creates, errno == EEXIST {
            // The owner's other window created it since the check: an append to its log.
            creates = false
            descriptor = open(url.path, flags, 0o644)
        }
        guard descriptor >= 0 else { throw FolderError.unwritable(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw FolderError.unreadable(files: [name])
        }
        let size = Int(info.st_size)
        var bytes = Data()
        if size > 0 {
            var last: UInt8 = 0
            guard pread(descriptor, &last, 1, off_t(size - 1)) == 1 else { throw FolderError.unreadable(files: [name]) }
            if last != 0x0A { bytes.append(0x0A) }
        }
        bytes.append(lines)
        if size + bytes.count > limit {
            do {
                try replaceCompacted(descriptor: descriptor, adding: operations,
                                     participant: participant, at: url, now: now, limit: limit)
            } catch {
                // Refused, so nothing was published: a log this append created goes again.
                if creates { _ = unlink(url.path) }
                throw error
            }
            return
        }
        do {
            try Self.writeAll(bytes, to: descriptor)
            // On the platter before this returns (U-102): the caller records these lines as
            // published in its base, and a line it believes published but a power loss took back
            // reads as a markup deleted — on every machine that knew it.
            try Self.fullSync(descriptor, path: url.path)
            // V-090. The first append creates the log, and flushing the file does not flush its
            // name: after a power loss the lines could be on the platter under no name at all,
            // with the base recording them as published — the same deleted markups by another
            // road. Flushed as ``replaceCompacted(descriptor:adding:participant:at:now:limit:)``
            // flushes the directory after its rename.
            if creates { try Self.fullSyncDirectory(participantsURL) }
        } catch {
            // A log this append created goes again, name and all; an existing one is cut back.
            if creates { _ = unlink(url.path) } else { _ = ftruncate(descriptor, off_t(size)) }
            throw FolderError.unwritable(error.localizedDescription)
        }
    }

    /// Compacts this participant's own log when it is already over `limit`, and returns whether
    /// it did (T-079, iteration 3 re-fix).
    ///
    /// A log over the cap is refused by every reader, so a sync — its owner's too — refuses at
    /// its first read of the folder, before ``append(_:participant:now:limit:)`` (which keeps a log
    /// under the cap) is ever reached. A log grown past the cap by a build from before that cap,
    /// or by two of its owner's appends racing, was therefore stuck for good: refused on every
    /// machine, and only deletable, which would remove every markup it holds everywhere. Its
    /// owner is its only writer, so its owner may rewrite it: a sync calls this before it reads
    /// the folder. The log is read as a stream, never whole, and replaced through a rename.
    ///
    /// Another participant's log is never touched here; over the cap, it stays refused until its
    /// owner's next sync compacts it. A log that is not a regular file is left for
    /// ``readAll(now:limit:cache:read:)`` to name. Throws ``FolderError/logFull`` when even the
    /// compacted log is over `limit`, ``FolderError/unreadable(files:)`` when it cannot be read,
    /// and ``FolderError/unwritable(_:)`` when it changed while it was compacted — never having
    /// written anything.
    @discardableResult
    public func compactOwnLogIfOverLimit(participant: String, now: Date = Date(),
                                         limit: Int = OperationLogCodec.maximumLogBytes) throws -> Bool {
        guard Self.isValidParticipantID(participant) else { throw FolderError.invalidParticipant }
        let url = logURL(participant)
        let name = url.lastPathComponent
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw FolderError.unreadable(files: [name])
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > off_t(limit) else { return false }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw FolderError.unreadable(files: [name]) }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw FolderError.unreadable(files: [name])
        }
        try replaceCompacted(descriptor: descriptor, adding: [], participant: participant, at: url, now: now, limit: limit)
        return true
    }

    /// Replaces the log with its compaction plus `operations`, through a rename, so a reader on
    /// another machine sees the old log or the new one.
    ///
    /// The log is streamed (``OwnLogCompactor``): memory holds one chunk, one line being read and
    /// the compaction so far, never the file — a log already over the cap can be any size. Before
    /// the rename the log must still be the file that was read, at the length that was read; a
    /// write that landed meanwhile (the owner's other window) refuses the replacement instead of
    /// being lost, and the next sync compacts again.
    private func replaceCompacted(descriptor: Int32, adding operations: [ReviewOperation],
                                  participant: String, at url: URL, now: Date, limit: Int) throws {
        let name = url.lastPathComponent
        var compactor = OwnLogCompactor(participant: participant, now: now)
        guard compactor.read(descriptor) else { throw FolderError.unreadable(files: [name]) }
        let compacted: Data
        do {
            compacted = try OperationLogCodec.encode(compactor.finish(adding: operations))
        } catch {
            throw FolderError.unwritable(error.localizedDescription)
        }
        guard compacted.count <= limit else { throw FolderError.logFull }
        let temporary = participantsURL.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        do {
            // Written and flushed through its own descriptor before the rename (U-102). A rename
            // can reach the disk before the data it names: after a power loss the log would be
            // empty or zero-filled, read as a log with no operations, and every machine that knew
            // this participant's markups would delete them on its next sync.
            try Self.writeNewFileDurably(compacted, at: temporary)
            var opened = stat()
            var current = stat()
            guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
                  opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
                  Int(opened.st_size) == compactor.bytesRead else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "the log changed while it was being compacted"])
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw FolderError.unwritable(error.localizedDescription)
        }
        // The rename itself is durable only once the directory that records it is flushed.
        do {
            try Self.fullSyncDirectory(participantsURL)
        } catch {
            throw FolderError.unwritable(error.localizedDescription)
        }
    }

    /// A participant's own log, read as a stream and compacted as it is read (T-079).
    ///
    /// Lines are cut at their newline with `memchr`, one chunk at a time. The owner's operations
    /// gather in a batch that is folded into the compaction so far every `batchBytes` bytes of
    /// lines: `compact(compact(A) + B)` keeps exactly what `compact(A + B)` keeps, because the
    /// winner of every slot over `A + B` is the winner over `A` or an operation of `B`, and
    /// `compact(A)` keeps every winner over `A`. A line over ``OperationLogCodec/maximumLineBytes``
    /// is skipped to its newline without being held, and an unterminated last line — a write still
    /// arriving, or the zeros a file extended past its data reads as — is dropped, as a reader
    /// drops it. Lines speaking for somebody else are never merged from this log and are dropped.
    struct OwnLogCompactor {
        static let chunkBytes = 1 << 20

        let participant: String
        let now: Date
        /// Bytes of own lines gathered before they are folded into the compaction. Tests fold
        /// after every line.
        let batchBytes: Int
        private var kept: [ReviewOperation] = []
        private var batch: [ReviewOperation] = []
        private var batched = 0
        private var line = Data()
        private var skippingOverlongLine = false
        /// Bytes read from the start of the file.
        private(set) var bytesRead = 0
        /// Times the batch was folded into the compaction.
        private(set) var folds = 0

        init(participant: String, now: Date, batchBytes: Int = 8 << 20) {
            self.participant = participant
            self.now = now
            self.batchBytes = batchBytes
        }

        /// Reads `descriptor` from where the last read stopped to its end; `false` on a read error.
        mutating func read(_ descriptor: Int32) -> Bool {
            var chunk = [UInt8](repeating: 0, count: Self.chunkBytes)
            while true {
                let count = chunk.withUnsafeMutableBytes { raw in
                    pread(descriptor, raw.baseAddress, raw.count, off_t(bytesRead))
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { return false }
                if count == 0 { return true }
                chunk.withUnsafeBytes { raw in feed(UnsafeRawBufferPointer(rebasing: raw[0..<count])) }
                bytesRead += count
            }
        }

        mutating func feed(_ bytes: UnsafeRawBufferPointer) {
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                let remaining = bytes.count - start
                guard let hit = memchr(base + start, 0x0A, remaining) else {
                    take(base + start, count: remaining)
                    return
                }
                let end = base.distance(to: UnsafeRawPointer(hit))
                take(base + start, count: end - start)
                if !skippingOverlongLine, !line.isEmpty { decode(line) }
                line.removeAll(keepingCapacity: true)
                skippingOverlongLine = false
                start = end + 1
            }
        }

        private mutating func take(_ bytes: UnsafeRawPointer, count: Int) {
            guard !skippingOverlongLine, count > 0 else { return }
            guard line.count + count <= OperationLogCodec.maximumLineBytes else {
                line.removeAll()
                skippingOverlongLine = true
                return
            }
            line.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        }

        private mutating func decode(_ line: Data) {
            guard let operation = try? OperationLogCodec.decoder.decode(ReviewOperation.self, from: line),
                  operation.participantID == participant else { return }
            batch.append(operation)
            batched += line.count
            if batched >= batchBytes { fold() }
        }

        private mutating func fold() {
            guard !batch.isEmpty else { return }
            kept = ReviewLogCompaction.compact(kept + batch, now: now)
            batch.removeAll(keepingCapacity: true)
            batched = 0
            folds += 1
        }

        /// The compaction of every complete own line read, plus `operations`.
        mutating func finish(adding operations: [ReviewOperation]) -> [ReviewOperation] {
            batch.append(contentsOf: operations)
            fold()
            return kept
        }
    }

    /// The paths flushed by ``fullSync(_:path:)``, in order, while a test has switched recording
    /// on by setting it to `[]`; `nil` — the default, and always in the application — records
    /// nothing, so nothing grows.
    static let flushRecord = OSAllocatedUnfairLock<[String]?>(initialState: nil)

    /// `F_FULLFSYNC` — the flush that waits for the device, not only for the drive's cache —
    /// falling back to `fsync` where a filesystem has no full sync (some network shares).
    static func fullSync(_ descriptor: Int32, path: String) throws {
        if fcntl(descriptor, F_FULLFSYNC) == -1 {
            let fullSyncErrno = errno
            guard fullSyncErrno == ENOTTY || fullSyncErrno == ENOTSUP || fullSyncErrno == EINVAL else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(fullSyncErrno))])
            }
            guard fsync(descriptor) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        }
        flushRecord.withLock { record in record?.append(path) }
    }

    /// Flushes a directory, which is what makes a rename inside it durable.
    static func fullSyncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        defer { close(descriptor) }
        try fullSync(descriptor, path: url.path)
    }

    /// Creates `url`, which must not exist, writes `bytes` to it and flushes it.
    private static func writeNewFileDurably(_ bytes: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        defer { close(descriptor) }
        try writeAll(bytes, to: descriptor)
        try fullSync(descriptor, path: url.path)
    }

    private static func writeAll(_ bytes: Data, to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
                }
                offset += count
            }
        }
    }

    /// Writes this participant's presence file.
    public func writePresence(_ presence: Presence) throws {
        guard Self.isValidParticipantID(presence.participantID) else { throw FolderError.invalidParticipant }
        do {
            try Self.encoder.encode(presence).write(to: presenceURL(presence.participantID), options: .atomic)
        } catch {
            throw FolderError.unwritable(error.localizedDescription)
        }
    }

    /// What the logs in the folder hold, and which could not be read.
    public struct Contents: Sendable {
        public var operations: [ReviewOperation] = []
        /// Lines that could not be read (a sync still arriving, or damage), that speak for
        /// somebody other than the log's owner, or whose clock is not plausible.
        public var skippedLines = 0
        /// The participants whose logs were read, in name order.
        public var logs: [String] = []
        /// The participants whose log is in the folder but could not be read in full: not a
        /// regular file, over ``OperationLogCodec/maximumLogBytes``, or refused by the reader
        /// (an evicted file read offline, an I/O error on a share). T-079.
        public var unreadableLogs: [String] = []
        /// The participants directory itself could not be listed: the folder is offline, gone
        /// or not readable, so nobody's log was read.
        public var isFolderUnreadable = false

        /// Whether every log in the folder was read. A merge of anything less takes the missing
        /// logs' markups for removed, so a sync must refuse it rather than apply it.
        public var isComplete: Bool { !isFolderUnreadable && unreadableLogs.isEmpty }

        public init() {}
    }

    /// Decoded logs kept between reads (T-083), keyed by file name. Every log is still read at
    /// every sync — the reader is the app's file coordinator, which fetches a file a sync service
    /// has evicted, and a read is what a caller times a sync by — but a log that is the same file
    /// as last time (device and inode) with its old end where it was decodes only the lines past
    /// that end: none when it is unchanged, the new ones when it grew. Anything else — a log
    /// replaced through a rename, rewritten, cut short — is decoded afresh, so a write by anybody
    /// is never missed.
    public struct LogCache: Sendable {
        struct Entry: Sendable {
            var device: Int64
            var inode: UInt64
            /// Bytes of complete lines decoded, from the start of the file.
            var consumed: Int
            /// The bytes just before `consumed`, checked before only the tail is decoded.
            var sentinel: Data
            /// The owner's operations, before any clock is judged.
            var own: [ReviewOperation]
            /// Lines speaking for somebody else, and complete lines that did not parse.
            var foreign: Int
            var malformed: Int
            var unterminatedTail: Bool

            func canResume(_ info: stat, with data: Data) -> Bool {
                device == Int64(info.st_dev) && inode == UInt64(info.st_ino) && data.count >= consumed
                    && data[data.startIndex + consumed - sentinel.count ..< data.startIndex + consumed] == sentinel
            }

            mutating func stamp(_ info: stat) {
                device = Int64(info.st_dev)
                inode = UInt64(info.st_ino)
            }

            /// Decodes `data` from `consumed` on and adds what it holds; returns the lines examined.
            mutating func decode(_ data: Data, participant: String) -> Int {
                let lines = OperationLogCodec.decodeLines(data, from: consumed)
                for operation in lines.operations {
                    if operation.participantID == participant { own.append(operation) } else { foreign += 1 }
                }
                malformed += lines.malformed
                unterminatedTail = lines.unterminatedTail
                consumed = lines.consumed
                // A copy: a slice would keep the whole file alive in the cache.
                sentinel = data.subdata(in: data.startIndex + max(0, consumed - 64) ..< data.startIndex + consumed)
                return lines.examined
            }

            static let empty = Entry(device: 0, inode: 0, consumed: 0, sentinel: Data(), own: [], foreign: 0,
                                     malformed: 0, unterminatedTail: false)
        }

        var entries: [String: Entry] = [:]
        /// Log lines decoded through this cache since it was made — the work a read cost.
        public internal(set) var decodedLineCount = 0

        public init() {}
    }

    /// What every log in the folder holds, read with a fresh cache.
    public func readAll(
        now: Date = Date(),
        limit: Int = OperationLogCodec.maximumLogBytes,
        read: (URL) -> Data? = SharedReviewFolder.readLog
    ) -> Contents {
        var cache = LogCache()
        return readAll(now: now, limit: limit, cache: &cache, read: read)
    }

    /// What every log in the folder holds. A reader, `read`, can be injected so the app reads
    /// through its file coordinator (which also downloads a cloud-evicted file first).
    ///
    /// `now` bounds how far in the future an operation's clock may be (R-202).
    ///
    /// Every entry is checked with `lstat` before the reader sees it (T-081): only a regular file
    /// of at most `limit` bytes is handed over. A FIFO named like a log used to reach the app's
    /// coordinated reader, where the file coordinator blocked the main thread for good. A log that
    /// fails the check, or that the reader cannot read, is named in
    /// ``Contents/unreadableLogs`` instead of being left out without a word (T-079): left out, its
    /// markups merged as removed.
    public func readAll(
        now: Date = Date(),
        limit: Int = OperationLogCodec.maximumLogBytes,
        cache: inout LogCache,
        read: (URL) -> Data? = SharedReviewFolder.readLog
    ) -> Contents {
        var contents = Contents()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: participantsURL.path) else {
            contents.isFolderUnreadable = true
            return contents
        }
        var kept: [String: LogCache.Entry] = [:]
        for name in names.sorted() where name.hasSuffix(".\(Self.logExtension)") {
            let participant = String(name.dropLast(Self.logExtension.count + 1))
            guard Self.isValidParticipantID(participant) else { continue }
            let url = participantsURL.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno != ENOENT { contents.unreadableLogs.append(participant) }   // ENOENT: gone since the listing
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= off_t(limit) else {
                contents.unreadableLogs.append(participant)
                continue
            }
            guard let data = read(url), data.count <= limit else {
                contents.unreadableLogs.append(participant)
                continue
            }
            var entry = cache.entries[name].flatMap { $0.canResume(info, with: data) ? $0 : nil } ?? .empty
            cache.decodedLineCount += entry.decode(data, participant: participant)
            entry.stamp(info)
            kept[name] = entry
            // A line is only trusted from the log it claims: a log cannot speak for another
            // participant. Clocks are judged at every read, never cached: one too far ahead now
            // may be plausible later.
            let plausible = entry.own.filter { HybridLogicalClock.isPlausible($0.clock, now: now) }
            contents.skippedLines += entry.malformed + (entry.unterminatedTail ? 1 : 0) + entry.foreign
                + (entry.own.count - plausible.count)
            contents.operations.append(contentsOf: plausible)
            contents.logs.append(participant)
        }
        cache.entries = kept
        return contents
    }

    /// The default log reader: the bytes of a regular file of at most
    /// ``OperationLogCodec/maximumLogBytes``, opened without following a link and without
    /// blocking on a FIFO, re-checked on what was opened, and read with a bound (T-081).
    public static func readLog(_ url: URL) -> Data? {
        guard case .data(let data) = readRegularFile(url, limit: OperationLogCodec.maximumLogBytes) else { return nil }
        return data
    }

    /// The largest presence file read. A real one is a few hundred bytes.
    public static let maximumPresenceBytes = 64 * 1024

    /// Everybody's presence files.
    ///
    /// Only regular files of at most ``maximumPresenceBytes`` are read, and the size is checked
    /// before a byte is read (S-126): the folder is writable by anybody who can reach it, this
    /// runs on every presence refresh, and the old read-then-check let one planted multi-gigabyte
    /// file make every participant allocate that much each time — or a FIFO block the reader.
    public func presences() -> [Presence] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: participantsURL.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".\(Self.presenceExtension)"),
                  let data = Self.readSmallRegularFile(participantsURL.appendingPathComponent(name), limit: Self.maximumPresenceBytes),
                  let presence = try? Self.decoder.decode(Presence.self, from: data),
                  // A presence file speaks only for the participant it is named after.
                  name == "\(presence.participantID).\(Self.presenceExtension)"
            else { return nil }
            return presence
        }
    }

    /// What reading a file the folder may hold found.
    enum FileRead: Sendable {
        /// There is no file by that name.
        case missing
        case data(Data)
        /// Something is there and it could not be read in full: not a regular file, over the
        /// limit, or a read error.
        case unreadable
    }

    /// The bytes of `url` when it is a regular file — not a link, a FIFO or a device — of at most
    /// `limit` bytes. Checked with `lstat` before opening and with `fstat` on what was opened (the
    /// entry may be swapped in between), and read with a bound either way. Only a name that is
    /// not there reads as ``FileRead/missing``; every other failure is ``FileRead/unreadable``
    /// (T-078: the difference between "no log yet" and "a log this machine cannot see").
    static func readRegularFile(_ url: URL, limit: Int) -> FileRead {
        func isSmallRegular(_ info: stat) -> Bool {
            (info.st_mode & S_IFMT) == S_IFREG && info.st_size >= 0 && info.st_size <= off_t(limit)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        guard isSmallRegular(info) else { return .unreadable }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fstat(descriptor, &info) == 0, isSmallRegular(info) else { return .unreadable }
        guard let read = try? handle.read(upToCount: limit + 1) else {
            return info.st_size == 0 ? .data(Data()) : .unreadable
        }
        return read.count <= limit ? .data(read) : .unreadable
    }

    /// The bytes of a small regular file, or `nil` for anything else (S-126).
    static func readSmallRegularFile(_ url: URL, limit: Int) -> Data? {
        guard case .data(let data) = readRegularFile(url, limit: limit) else { return nil }
        return data
    }

    /// What every other participant's log looks like on disk — name, size and modification time —
    /// so a watcher can tell "someone wrote" without reading a byte. This participant's own log is
    /// left out: writing it is not news.
    public func fingerprint(excluding participant: String) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: participantsURL.path)) ?? []
        var result: [String: String] = [:]
        for name in names where name.hasSuffix(".\(Self.logExtension)") && name != "\(participant).\(Self.logExtension)" {
            let values = try? participantsURL.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            result[name] = "\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        }
        return result
    }
}
