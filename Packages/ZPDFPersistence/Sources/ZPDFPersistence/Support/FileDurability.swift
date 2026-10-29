import CryptoKit
import Darwin
import Foundation
import os

/// The POSIX layer the save pipeline stands on.
///
/// Everything here exists because `FileManager` is not a durability API. `FileManager`
/// tells you a write returned; it does not tell you the bytes left the drive's cache,
/// and on macOS neither does `fsync(2)` — Darwin's `fsync` pushes to the device and
/// returns without waiting for the device to commit. `F_FULLFSYNC` is the call that
/// actually waits, and it is the difference between "we saved" and "we saved unless the
/// power goes out in the next few hundred milliseconds".
public enum FileDurability {

    /// Bytes moved per read/write in the copy loop, and per hash update.
    ///
    /// 1 MiB: large enough that a 2 GB drawing set is not four million syscalls, small
    /// enough that peak memory is flat no matter how big the file is.
    public static let chunkByteCount = 1 << 20

    // MARK: - Syncing

    /// `F_FULLFSYNC` on a file, falling back to `fsync` where the filesystem has no
    /// full-sync support (some network mounts).
    public static func syncFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ZPDFPersistenceError.posixFailure(operation: "open", path: url.path, errnoValue: errno)
        }
        defer { close(descriptor) }
        Statistics.noteFullSync()
        if fcntl(descriptor, F_FULLFSYNC) == -1 {
            let fullSyncErrno = errno
            guard fullSyncErrno == ENOTTY || fullSyncErrno == ENOTSUP || fullSyncErrno == EINVAL else {
                throw ZPDFPersistenceError.posixFailure(
                    operation: "fcntl(F_FULLFSYNC)", path: url.path, errnoValue: fullSyncErrno
                )
            }
            guard fsync(descriptor) == 0 else {
                throw ZPDFPersistenceError.posixFailure(operation: "fsync", path: url.path, errnoValue: errno)
            }
        }
    }

    /// `fsync` on a directory, which is what makes a `rename`, a `link` or a `creat`
    /// durable. Syncing the file is not enough: if the directory entry that names it is
    /// still only in the cache, the file survives with no name.
    public static func syncDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw ZPDFPersistenceError.posixFailure(operation: "open(dir)", path: url.path, errnoValue: errno)
        }
        defer { close(descriptor) }
        Statistics.noteFullSync()
        if fcntl(descriptor, F_FULLFSYNC) == -1 {
            let fullSyncErrno = errno
            guard fullSyncErrno == ENOTTY || fullSyncErrno == ENOTSUP || fullSyncErrno == EINVAL else {
                throw ZPDFPersistenceError.posixFailure(
                    operation: "fcntl(F_FULLFSYNC dir)", path: url.path, errnoValue: fullSyncErrno
                )
            }
            guard fsync(descriptor) == 0 else {
                throw ZPDFPersistenceError.posixFailure(operation: "fsync(dir)", path: url.path, errnoValue: errno)
            }
        }
    }

    /// Counters a test can read to see what the durability layer actually did.
    ///
    /// They exist because "the second save hashes one file" and "a tree sync flushes the
    /// device cache once" are claims about syscalls, and a claim about syscalls is only
    /// evidence when it is counted. Monotonic, process-wide, cheap.
    public enum Statistics {
        /// Calls to ``sha256(ofFileAt:)`` that opened and read a file.
        public static let fileHashCount = OSAllocatedUnfairLock(initialState: 0)
        /// `F_FULLFSYNC` calls issued (or their `fsync` fallback on a filesystem without it).
        public static let fullSyncCount = OSAllocatedUnfairLock(initialState: 0)

        /// What one scope of work did, counted for that scope alone.
        public struct Counts: Sendable, Hashable {
            public var fileHashCount = 0
            public var fullSyncCount = 0
        }

        /// A per-task recorder, so a test counting the syscalls of *its* save is not
        /// reading the saves the suites running beside it are making.
        public final class Recorder: Sendable {
            let counts = OSAllocatedUnfairLock(initialState: Counts())
            public init() {}
            public var current: Counts { counts.withLock { $0 } }
        }

        @TaskLocal static var recorder: Recorder?

        static func noteFileHash() {
            fileHashCount.withLock { $0 += 1 }
            recorder?.counts.withLock { $0.fileHashCount += 1 }
        }

        static func noteFullSync() {
            fullSyncCount.withLock { $0 += 1 }
            recorder?.counts.withLock { $0.fullSyncCount += 1 }
        }

        /// Runs `body` and returns what the durability layer did *inside it*. Work the
        /// body hands to an unstructured task it creates is counted too; work on a
        /// dispatch queue is not.
        public static func measure<T: Sendable>(
            _ body: () async throws -> T
        ) async rethrows -> (result: T, counts: Counts) {
            let recorder = Recorder()
            let result = try await $recorder.withValue(recorder) { try await body() }
            return (result, recorder.current)
        }
    }

    /// Syncs every regular file under `root`, then every directory, deepest first, then
    /// `root` itself. Symbolic links are not followed.
    ///
    /// ### One device flush per tree, not one per file (IM-075)
    ///
    /// Darwin's `fsync(2)` hands a file's dirty pages and metadata to the drive and
    /// returns; it is `F_FULLFSYNC` that waits for the drive to commit its cache to the
    /// platter, and on APFS that command flushes the *whole device's* cache, not one
    /// file's. So the durable sequence for a tree is: `fsync` every file and every
    /// directory, so the drive has been handed all of it, then one `F_FULLFSYNC` at the
    /// end, so all of it is committed. The previous shape issued a full flush per file,
    /// which on a package carrying two version slots and a few hundred site photos was
    /// several hundred device flushes per save for a result one delivers.
    ///
    /// The old-or-new guarantee is unchanged: nothing outside the staged package has been
    /// touched when this runs, and the atomic swap only follows once it has returned.
    public static func syncTree(at root: URL) throws {
        var directories: [URL] = [root]
        var files: [URL] = []
        var index = 0
        // Breadth-first with an explicit queue and a hard cap: a package with a
        // pathological number of entries must fail loudly, not spin.
        let entryLimit = 200_000
        while index < directories.count {
            let directory = directories[index]
            index += 1
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for entry in contents {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    directories.append(entry)
                } else {
                    files.append(entry)
                }
                guard directories.count + files.count <= entryLimit else {
                    throw ZPDFPersistenceError.inputTooLarge(
                        what: "package entries", byteCount: directories.count + files.count, limit: entryLimit
                    )
                }
            }
        }
        for file in files { try pushToDevice(at: file, flags: O_RDONLY) }
        for directory in directories.reversed() { try pushToDevice(at: directory, flags: O_RDONLY | O_DIRECTORY) }
        // The root last, with the full flush: by now every file and directory above has
        // been handed to the drive, and this is the call that makes the drive keep it.
        try syncDirectory(at: root)
    }

    /// Plain `fsync(2)`: the file or directory is handed to the drive, without waiting
    /// for the drive's own cache. Only meaningful when an `F_FULLFSYNC` follows.
    private static func pushToDevice(at url: URL, flags: Int32) throws {
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else {
            throw ZPDFPersistenceError.posixFailure(operation: "open(sync)", path: url.path, errnoValue: errno)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ZPDFPersistenceError.posixFailure(operation: "fsync", path: url.path, errnoValue: errno)
        }
    }

    // MARK: - Renaming

    /// `RENAME_SWAP`, from `<sys/stdio.h>`. Not re-exported to Swift, so it is spelled
    /// out here rather than guessed at a call site.
    private static let renameSwapFlag: UInt32 = 0x0002

    /// Atomically exchanges two existing paths.
    ///
    /// This is the heart of the save. `renamex_np(…, RENAME_SWAP)` on APFS swaps two
    /// directory entries in a single filesystem transaction: there is no instant at
    /// which the project's name points at a half-built package, and no instant at which
    /// it points at nothing. The alternative — delete the old, rename the new — has a
    /// window in which a crash loses the project outright, which is not an acceptable
    /// window for a document that took days to make.
    public static func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renamex_np(firstPath, secondPath, renameSwapFlag)
            }
        }
        guard result == 0 else {
            throw ZPDFPersistenceError.atomicReplaceFailed(
                reason: "renamex_np(RENAME_SWAP) \(first.lastPathComponent) <-> \(second.lastPathComponent)",
                errnoValue: errno
            )
        }
    }

    /// Atomically replaces `destination` with `temporary`.
    ///
    /// `renamex_np(RENAME_SWAP)` first — the two entries exchange places in one
    /// filesystem transaction and the superseded content survives at `temporary` for the
    /// caller to discard. Where the swap is refused — a filesystem without `RENAME_SWAP`,
    /// or a sandbox profile that permits writing the granted path but not renaming it
    /// outward — `FileManager.replaceItemAt(_:withItemAt:)` performs the same replacement
    /// through the API the powerbox is designed around; the superseded content is then
    /// disposed of by the system rather than left at `temporary`. Either way there is no
    /// instant at which `destination` names a half-built package or nothing at all.
    public static func atomicReplace(_ temporary: URL, into destination: URL) throws {
        do {
            try atomicSwap(temporary, destination)
        } catch {
            do {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } catch let replaceError {
                throw ZPDFPersistenceError.atomicReplaceFailed(
                    reason: "replaceItemAt \(destination.lastPathComponent) after failed swap "
                        + "(\(error)): \(replaceError.localizedDescription)",
                    errnoValue: 0
                )
            }
        }
    }

    /// `rename(2)`. Atomic within a filesystem; fails rather than crossing devices.
    public static func rename(_ from: URL, to destination: URL) throws {
        let result = from.path.withCString { fromPath in
            destination.path.withCString { toPath in
                Darwin.rename(fromPath, toPath)
            }
        }
        guard result == 0 else {
            throw ZPDFPersistenceError.posixFailure(operation: "rename", path: from.path, errnoValue: errno)
        }
    }

    // MARK: - Copying

    /// Streams `source` to `destination` in ``chunkByteCount`` chunks.
    ///
    /// - Parameter onProgress: called after each chunk with the fraction written, so
    ///   the durability tests can stop the process precisely half way through a copy.
    ///   It is `async` because the kill harness needs a suspension point there.
    public static func copyFile(
        from source: URL,
        to destination: URL,
        onProgress: (@Sendable (Double) async throws -> Void)? = nil
    ) async throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else {
            throw ZPDFPersistenceError.posixFailure(operation: "open(src)", path: source.path, errnoValue: errno)
        }
        defer { close(input) }

        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, 0o644)
        guard output >= 0 else {
            throw ZPDFPersistenceError.posixFailure(
                operation: "open(dst)", path: destination.path, errnoValue: errno
            )
        }
        defer { close(output) }

        let totalByteCount = max(1, byteCount(of: source))
        var written = 0
        var buffer = [UInt8](repeating: 0, count: chunkByteCount)

        while true {
            try Task.checkCancellation()
            let readCount: Int = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(input, base, chunkByteCount)
            }
            if readCount == 0 { break }
            guard readCount > 0 else {
                throw ZPDFPersistenceError.posixFailure(operation: "read", path: source.path, errnoValue: errno)
            }
            var offset = 0
            while offset < readCount {
                let writeCount: Int = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return write(output, base.advanced(by: offset), readCount - offset)
                }
                guard writeCount > 0 else {
                    throw ZPDFPersistenceError.posixFailure(
                        operation: "write", path: destination.path, errnoValue: errno
                    )
                }
                offset += writeCount
            }
            written += readCount
            if let onProgress {
                try await onProgress(min(1, Double(written) / Double(totalByteCount)))
            }
        }
    }

    /// Writes `data` to a brand-new file, failing if anything is already there.
    public static func writeNewFile(_ data: Data, to destination: URL) throws {
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw ZPDFPersistenceError.posixFailure(
                operation: "open(new)", path: destination.path, errnoValue: errno
            )
        }
        defer { close(descriptor) }
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let count = write(descriptor, base.advanced(by: offset), raw.count - offset)
                guard count > 0 else {
                    throw ZPDFPersistenceError.posixFailure(
                        operation: "write", path: destination.path, errnoValue: errno
                    )
                }
                offset += count
            }
        }
    }

    /// Writes `data` to `destination` through a temporary sibling and a rename, so a
    /// reader never sees a half-written file. Used for the journal and the manifest.
    public static func writeFileAtomically(_ data: Data, to destination: URL, token: String) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(token).tmp", isDirectory: false)
        try? FileManager.default.removeItem(at: temporary)
        do {
            try writeNewFile(data, to: temporary)
            try syncFile(at: temporary)
            try rename(temporary, to: destination)
        } catch {
            // The destination is untouched; do not strand the half-written sibling either.
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try syncDirectory(at: destination.deletingLastPathComponent())
    }

    // MARK: - Hashing

    /// Opens a path that must be a regular file: no symbolic link is followed, and a
    /// device, FIFO, socket or directory is refused before a single byte is read.
    ///
    /// Every member of a package this build wrote is a regular file, so a symbolic link
    /// in its place is not ours (BH-600). Following it used to mean that a
    /// `documents/working.pdf` pointing at `/dev/zero` hung the open forever, since the
    /// hash reads until an end of file that never comes; a FIFO would have blocked in
    /// `open` itself, which is what `O_NONBLOCK` is for — on a regular file it changes
    /// nothing.
    private static func openRegularFile(at url: URL, operation: String) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            let openErrno = errno
            // `O_NOFOLLOW` answers a symbolic link with ELOOP: the same refusal as any
            // other non-regular file, named as such rather than as an errno.
            guard openErrno != ELOOP else {
                throw ZPDFPersistenceError.packageMalformed(
                    reason: "\(url.lastPathComponent) is not a regular file"
                )
            }
            throw ZPDFPersistenceError.posixFailure(operation: operation, path: url.path, errnoValue: openErrno)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let statErrno = errno
            close(descriptor)
            throw ZPDFPersistenceError.posixFailure(operation: "fstat", path: url.path, errnoValue: statErrno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw ZPDFPersistenceError.packageMalformed(
                reason: "\(url.lastPathComponent) is not a regular file"
            )
        }
        return descriptor
    }

    /// Reads a small regular file whole, refusing anything over `limit` bytes *as
    /// measured on the open descriptor* — so a symbolic link cannot pass the cap with its
    /// own few bytes and then hand the reader something else (BH-598).
    public static func readRegularFile(at url: URL, limit: Int, what: String) throws -> Data {
        let descriptor = try openRegularFile(at: url, operation: "open(read)")
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw ZPDFPersistenceError.posixFailure(operation: "fstat", path: url.path, errnoValue: errno)
        }
        let size = Int(clamping: status.st_size)
        guard size <= limit else {
            throw ZPDFPersistenceError.inputTooLarge(what: what, byteCount: size, limit: limit)
        }
        var data = Data(count: size)
        var offset = 0
        while offset < size {
            let count = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(descriptor, base.advanced(by: offset), size - offset)
            }
            if count == 0 { break }
            guard count > 0 else {
                throw ZPDFPersistenceError.posixFailure(operation: "read", path: url.path, errnoValue: errno)
            }
            offset += count
        }
        if offset < size { data.removeSubrange(offset..<size) }
        return data
    }

    /// What identifies a file's *bytes* without reading them: the device and inode name
    /// the storage, the size and the nanosecond modification time change on any write.
    ///
    /// This is the key the save pipeline's digest cache uses (IM-006). Any external
    /// write to a member — a new file renamed into place, an in-place rewrite — changes
    /// at least one of the four, so a cached digest is only ever reused for bytes that
    /// are demonstrably the ones it was computed over.
    public struct FileIdentity: Sendable, Hashable {
        public let device: Int32
        public let inode: UInt64
        public let byteCount: Int64
        public let modifiedAtNanoseconds: Int64
    }

    /// The identity of a regular file, or `nil` if it cannot be stat'ed or is not one.
    public static func identity(of url: URL) -> FileIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            byteCount: status.st_size,
            modifiedAtNanoseconds: Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(status.st_mtimespec.tv_nsec)
        )
    }

    /// Streaming lowercase-hex SHA-256 of a regular file. Constant memory whatever the
    /// size. Refuses a symbolic link or a special file rather than following it.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let descriptor = try openRegularFile(at: url, operation: "open(hash)")
        defer { close(descriptor) }
        Statistics.noteFileHash()
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkByteCount)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(descriptor, base, chunkByteCount)
            }
            if count == 0 { break }
            guard count > 0 else {
                throw ZPDFPersistenceError.posixFailure(operation: "read(hash)", path: url.path, errnoValue: errno)
            }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<count]))
            }
        }
        return hexString(hasher.finalize())
    }

    /// Lowercase-hex SHA-256 of an in-memory buffer.
    public static func sha256(of data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    private static func hexString<Digest: Sequence>(_ digest: Digest) -> String
    where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Inspection

    public static func byteCount(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// The modification time of an item, or `nil` if it cannot be read.
    public static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        let present = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return present && directory.boolValue
    }

    public static func createDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ZPDFPersistenceError.temporaryPackageWriteFailed(
                reason: "mkdir \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }
}

public extension FileDurability {

    /// `clonefile(2)`: an independent copy that shares its blocks until one side is
    /// written to.
    ///
    /// On APFS this is O(1) whatever the size, which is what makes keeping a full
    /// previous version of a project with a 400 MB drawing set affordable. It works on
    /// whole directory trees as well as single files. On a filesystem without cloning
    /// it falls back to a real copy, and the caller cannot tell the difference apart
    /// from the time it takes.
    static func cloneItem(at source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0)
            }
        }
        if result == 0 { return }
        let cloneErrno = errno
        // ENOTSUP: not a cloning filesystem. EXDEV: different volume.
        guard cloneErrno == ENOTSUP || cloneErrno == EXDEV || cloneErrno == EINVAL else {
            throw ZPDFPersistenceError.posixFailure(
                operation: "clonefile", path: source.path, errnoValue: cloneErrno
            )
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ZPDFPersistenceError.temporaryPackageWriteFailed(
                reason: "copy \(source.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /// Removes an item if it is there. Never throws for absence.
    static func removeIfPresent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Marks a file read-only for its owner as well as everyone else.
    ///
    /// Applied to `documents/original.pdf` at create. It does not stop a determined
    /// process, but it does stop an accidental one, and it makes the intent legible in
    /// `ls -l`: the original is evidence, not a working file.
    static func makeReadOnly(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        } catch {
            throw ZPDFPersistenceError.temporaryPackageWriteFailed(
                reason: "chmod 444 \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /// Names of the immediate children of a directory. Empty when it is not readable.
    static func directoryEntryNames(at url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
    }
}
