import CryptoKit
import Foundation

/// A generated fixture on disk.
public struct FixtureHandle: Sendable, Hashable {
    /// Where the file is.
    public let url: URL
    /// The closed-form truth about what is in it.
    public let manifest: FixtureManifest
    /// Size of the file in bytes.
    public let byteCount: Int
    /// `false` when the file was already present from an earlier call in this test run
    /// and was reused rather than regenerated.
    public let wasGenerated: Bool

    public var kind: FixtureKind { manifest.kind }

    public init(url: URL, manifest: FixtureManifest, byteCount: Int, wasGenerated: Bool) {
        self.url = url
        self.manifest = manifest
        self.byteCount = byteCount
        self.wasGenerated = wasGenerated
    }
}

/// A fixture held in memory.
public struct FixtureData: Sendable, Hashable {
    public let data: Data
    public let manifest: FixtureManifest

    public var kind: FixtureKind { manifest.kind }

    public init(data: Data, manifest: FixtureManifest) {
        self.data = data
        self.manifest = manifest
    }
}

/// The synthetic PDF corpus.
///
/// ```swift
/// let handle = try ZPDFFixtures.make(.rectangle, in: temporaryDirectory)
/// let expected = handle.manifest.path(id: "rect")?.area   // 51840, exactly
/// ```
///
/// **Caching.** Generated files are cached in the destination directory itself rather
/// than in a process-wide table: alongside `rectangle.pdf` the generator writes
/// `rectangle.pdf.stamp` recording the generator version, the byte count, a SHA-256 of
/// the kind's manifest and a SHA-256 of the file, and a later `make` for the same kind
/// in the same directory reuses the file only when all four still hold. Callers may
/// point several runs at one persistent directory, so the stamp does not rely on the
/// directory being fresh: a generator edit that changes the manifest (any coordinate,
/// length, area, name or note) invalidates the cache by itself, and a file changed on
/// disk — even to the same length — is regenerated. An edit that changes only bytes and
/// no manifest value still needs `generatorVersion` bumped. There is no shared mutable
/// state and no locking — which matters, because the house rules forbid
/// `@unchecked Sendable` and this API is synchronous by design.
///
/// **Determinism.** Every fixture except `.encryptedUserPassword` is byte-identical on
/// every run and every machine: no `Date()`, no `UUID()`, no platform RNG, and no
/// CoreGraphics re-encoding of coordinates. The encrypted fixture is produced by
/// CoreGraphics, whose encryption dictionary embeds fresh random material by design.
public enum ZPDFFixtures {

    /// The user password of `.encryptedUserPassword`.
    public static var encryptedUserPassword: String { HostileFixtures.userPassword }
    /// The owner password of `.encryptedUserPassword`.
    public static var encryptedOwnerPassword: String { HostileFixtures.ownerPassword }
    /// Bumped whenever a fixture's bytes change; recorded in the on-disk cache stamp.
    public static var generatorVersion: Int { FixtureRegistry.generatorVersion }

    // MARK: - Manifests

    /// The closed-form truth for `kind`, without touching the filesystem.
    ///
    /// Manifests are pure functions of the kind, so two calls return equal values.
    public static func manifest(for kind: FixtureKind) throws -> FixtureManifest {
        try FixtureRegistry.build(kind).manifest
    }

    // MARK: - In-memory

    /// Generates `kind` in memory.
    ///
    /// Nothing is cached here: generation is deterministic and, for every fixture but
    /// `.decompressionBomb`, cheap. Use `make(_:in:)` when the cost matters.
    public static func data(_ kind: FixtureKind) throws -> FixtureData {
        let build = try FixtureRegistry.build(kind)
        return FixtureData(data: try build.makeData(), manifest: build.manifest)
    }

    // MARK: - On disk

    /// Writes `kind` into `directory`, creating the directory if necessary, and returns
    /// a handle to the file and its manifest.
    ///
    /// A file already present from an earlier call in the same directory is reused when
    /// its stamp matches the current generator version, the current manifest, and the
    /// file's actual size and content digest.
    @discardableResult
    public static func make(_ kind: FixtureKind, in directory: URL) throws -> FixtureHandle {
        let build = try FixtureRegistry.build(kind)
        let fileURL = directory.appendingPathComponent(kind.fileName, isDirectory: false)
        let stampURL = directory.appendingPathComponent(kind.fileName + ".stamp", isDirectory: false)

        try ensureDirectory(directory)

        let manifestDigest = try digest(of: build.manifest)

        if let cached = cachedByteCount(fileURL: fileURL, stampURL: stampURL, manifestDigest: manifestDigest) {
            return FixtureHandle(
                url: fileURL,
                manifest: build.manifest,
                byteCount: cached,
                wasGenerated: false
            )
        }

        let written = try write(build: build, to: fileURL)
        try writeStamp(
            CacheStamp(
                version: FixtureRegistry.generatorVersion,
                byteCount: written.byteCount,
                manifestDigest: manifestDigest,
                contentDigest: written.contentDigest
            ),
            to: stampURL
        )
        let byteCount = written.byteCount

        return FixtureHandle(
            url: fileURL,
            manifest: build.manifest,
            byteCount: byteCount,
            wasGenerated: true
        )
    }

    /// Writes `kind` into one cache directory under the temporary directory that every test
    /// process shares, and returns its handle.
    ///
    /// For the large drawing sheets that many suites open read-only (``SyntheticRoofPlan``). The
    /// stamp beside each file makes reuse safe across processes and generator versions, and the
    /// atomic write makes concurrent first generations safe. A caller that hands the file to code
    /// which may delete or modify it copies it first.
    @discardableResult
    public static func shared(_ kind: FixtureKind) throws -> FixtureHandle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-fixture-cache-v\(FixtureRegistry.generatorVersion)", isDirectory: true)
        return try make(kind, in: directory)
    }

    /// Writes every fixture into `directory`.
    @discardableResult
    public static func makeAll(in directory: URL) throws -> [FixtureHandle] {
        try FixtureKind.allCases.map { try make($0, in: directory) }
    }

    /// Writes the fixtures of one group into `directory`.
    @discardableResult
    public static func make(_ kinds: [FixtureKind], in directory: URL) throws -> [FixtureHandle] {
        try kinds.map { try make($0, in: directory) }
    }

    // MARK: - Filesystem plumbing

    private static func ensureDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw FixtureError.directoryUnavailable(
                    path: directory.path,
                    reason: "path exists and is not a directory"
                )
            }
            return
        }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw FixtureError.directoryUnavailable(path: directory.path, reason: "\(error)")
        }
    }

    /// What the `.stamp` beside a cached fixture records.
    struct CacheStamp: Equatable {
        var version: Int
        var byteCount: Int
        var manifestDigest: String
        var contentDigest: String

        static let header = "zpdf-fixture-stamp 2"

        var text: String {
            [Self.header, "\(version)", "\(byteCount)", manifestDigest, contentDigest]
                .joined(separator: "\n") + "\n"
        }

        /// Parses a stamp; an older two-field stamp or anything malformed is `nil`.
        init?(text: String) {
            let fields = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 5, fields[0] == Self.header,
                  let version = Int(fields[1]), let byteCount = Int(fields[2])
            else { return nil }
            self.init(version: version, byteCount: byteCount, manifestDigest: fields[3], contentDigest: fields[4])
        }

        init(version: Int, byteCount: Int, manifestDigest: String, contentDigest: String) {
            self.version = version
            self.byteCount = byteCount
            self.manifestDigest = manifestDigest
            self.contentDigest = contentDigest
        }
    }

    /// SHA-256 of the manifest's canonical JSON (sorted keys), lowercase hex.
    static func digest(of manifest: FixtureManifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return hex(SHA256.hash(data: try encoder.encode(manifest)))
        } catch {
            throw FixtureError.generationFailed(kind: manifest.kind, reason: "manifest not encodable: \(error)")
        }
    }

    /// Streamed SHA-256 of a file, lowercase hex; `nil` when it cannot be read.
    static func contentDigest(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the cached file's byte count when the stamp is current, `nil` otherwise.
    private static func cachedByteCount(fileURL: URL, stampURL: URL, manifestDigest: String) -> Int? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path),
              let stampData = manager.contents(atPath: stampURL.path),
              let text = String(data: stampData, encoding: .utf8),
              let stamp = CacheStamp(text: text),
              stamp.version == FixtureRegistry.generatorVersion,
              stamp.manifestDigest == manifestDigest
        else { return nil }

        guard let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue == stamp.byteCount,
              contentDigest(ofFileAt: fileURL) == stamp.contentDigest
        else { return nil }

        return stamp.byteCount
    }

    private static func writeStamp(_ stamp: CacheStamp, to stampURL: URL) throws {
        guard let data = stamp.text.data(using: .utf8) else {
            throw FixtureError.writeFailed(path: stampURL.path, reason: "stamp is not UTF-8")
        }
        do {
            try data.write(to: stampURL, options: .atomic)
        } catch {
            throw FixtureError.writeFailed(path: stampURL.path, reason: "\(error)")
        }
    }

    /// Renames `temporaryURL` over `fileURL` with `rename(2)`, which replaces an
    /// existing file atomically. A branch on `fileExists` followed by `moveItem` is a
    /// race: two concurrent generations can both see "absent", and the second
    /// `moveItem` then throws although an identical fixture is already in place.
    static func moveIntoPlace(_ temporaryURL: URL, over fileURL: URL) throws {
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporaryURL)
            throw FixtureError.writeFailed(path: fileURL.path, reason: String(cString: strerror(code)))
        }
    }

    /// Writes the fixture and returns its size and content digest, streaming when the
    /// fixture supports it.
    private static func write(build: FixtureBuild, to fileURL: URL) throws -> (byteCount: Int, contentDigest: String) {
        let manager = FileManager.default

        guard let streamTo = build.streamTo else {
            let data = try build.makeData()
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                throw FixtureError.writeFailed(path: fileURL.path, reason: "\(error)")
            }
            return (data.count, hex(SHA256.hash(data: data)))
        }

        // Streaming path: write to a sibling temporary file, then move it into place, so
        // a partially written fixture is never observable at the final URL.
        // The temporary name is unique per call, so two concurrent generations of the
        // same fixture cannot clobber each other's partial file.
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(unique).partial", isDirectory: false)
        guard manager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw FixtureError.writeFailed(path: temporaryURL.path, reason: "cannot create file")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            throw FixtureError.writeFailed(path: temporaryURL.path, reason: "\(error)")
        }

        var writeError: Error?
        do {
            try streamTo(handle, temporaryURL.path)
        } catch {
            writeError = error
        }
        try? handle.close()

        if let writeError {
            try? manager.removeItem(at: temporaryURL)
            throw writeError
        }

        // Digest the partial file before it is published: once renamed, a concurrent
        // generation may already have replaced it.
        guard let attributes = try? manager.attributesOfItem(atPath: temporaryURL.path),
              let size = attributes[.size] as? NSNumber,
              let digest = contentDigest(ofFileAt: temporaryURL)
        else {
            try? manager.removeItem(at: temporaryURL)
            throw FixtureError.writeFailed(path: temporaryURL.path, reason: "cannot stat written file")
        }

        // `rename(2)` is atomic, so a concurrent reader sees either the old file or the
        // new one and never a half-written page tree.
        try moveIntoPlace(temporaryURL, over: fileURL)
        return (size.intValue, digest)
    }
}
