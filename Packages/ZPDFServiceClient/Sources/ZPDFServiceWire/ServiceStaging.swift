import Foundation

/// How both service cores copy an inherited document into their own container, and how a
/// service sweeps what an earlier run of it left behind (S-117, S-127).
///
/// Written once for both. The geometry core had a stage that removed its partial copy on a read
/// or write error, ran off its actor (R-211) and a startup sweep; the repair core had its own
/// stage without any of the three, so every repair ended by the wedge watchdog — which with
/// qpdf, synchronous C that never sees a cancel, is nearly every cancelled repair — left a
/// drawing-sized copy in the service container for good, since `_exit` runs no `defer`.
public enum ServiceStaging {

    /// Copies the file behind `fileDescriptor` into `directory` as `<prefix><UUID>.pdf`.
    ///
    /// The name is the service's own and never carries the request's file name, which the wire
    /// documents as "for error messages only" (BH-650, BH-651: a long name overflowed NAME_MAX).
    /// A copy that fails part-way is removed before the error is thrown. A regular file is
    /// copied from its start; a descriptor that cannot seek (a pipe) from where it stands —
    /// seeking it failed the copy with ESPIPE before a byte was read.
    public static func stage(
        fileDescriptor: Int32,
        prefix: String,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        var info = stat()
        if fstat(fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
            try handle.seek(toOffset: 0)
        }
        let url = directory.appendingPathComponent("\(prefix)\(UUID().uuidString).pdf")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            let out = try FileHandle(forWritingTo: url)
            defer { try? out.close() }
            while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// ``stage(fileDescriptor:prefix:in:)`` run off the calling actor, so a large copy does not
    /// hold the core while cancels and other requests wait (R-211, S-127).
    public static func stageDetached(
        fileDescriptor: Int32,
        prefix: String,
        in directory: URL = FileManager.default.temporaryDirectory
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try stage(fileDescriptor: fileDescriptor, prefix: prefix, in: directory)
        }.value
    }

    /// Deletes the files and folders in `directory` whose names start with one of `prefixes`
    /// and that were not modified for `age` seconds; returns how many it removed.
    ///
    /// For a service's listener at start, where the temporary directory is the service
    /// container's own. Never for a core inside the application or a test worker, whose
    /// temporary directory other processes share. The age keeps the working files of another
    /// live instance (a second copy of the app shares the service container) out of reach: no
    /// request lives that long under its deadline, and a copy the geometry core reuses across
    /// requests is touched at every lease and release (T-085).
    @discardableResult
    public static func sweepStale(
        prefixes: [String],
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 600,
        now: Date = Date()
    ) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) >= age
            else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
