import Foundation
import ZPDFUIPresentation

/// The person's Tool Library, in the application container.
///
/// The other half of ``ToolPresetArchive``, which stores a project's set inside its `.zpdfproj`.
/// This one stores the sets that belong to the estimator rather than to the job — `My Tools`,
/// `Recent`, `Favorites`, `Sequences`, `Count Symbols` and any imported library — so a discipline
/// standard survives closing a project and follows the person to the next one. See
/// ``ToolPresetScopeRule`` for which panel goes where and why.
///
/// # Where it writes
///
/// `Application Support/Zenit PDF/ToolLibrary/tool-presets.json`. Inside the sandbox that is the
/// application container and nothing else can see it. The directory is a parameter rather than a
/// constant so a test writes into a temporary directory: a unit test that touches the real
/// container would carry state between runs, and could delete a person's tools.
///
/// # What it writes
///
/// A versioned JSON document with sorted keys, written atomically. Sorted keys because two saves
/// of one library must produce identical bytes — a file that changes when nothing changed makes
/// every backup and every sync look busy. Atomically because a kill mid-write must leave the old
/// library or the new one, never half of either; the same rule ``ToolPresetArchive`` keeps with
/// its single transaction.
///
/// # What it refuses to read
///
/// Its own file is not automatically trustworthy — it is a plain file in a directory a person
/// can edit, and on an unsandboxed build anything can write it. So the reader checks the format
/// identifier and the schema version, refuses a version it does not know by name rather than
/// guessing, and caps the size. A preset is data and never executable, here as in a `.zpdftools`
/// import.
public actor ToolPresetContainerStore {

    /// What the file says it is. A different identifier is a different file that happens to
    /// share a name.
    public static let formatIdentifier = "zenit.toolLibrary.container"

    /// The schema this build writes and the only one it reads.
    public static let currentSchemaVersion = 1

    /// The largest container library this build will read. A preset is a few hundred bytes; a
    /// library of ten thousand is 4 MB. 64 MiB is a ceiling, not a budget.
    public static let maximumByteCount = 64 * 1024 * 1024

    /// Everything the store can refuse to do, each naming what was wrong.
    public enum StoreError: Error, Hashable, Sendable, CustomStringConvertible {
        case notAZenitToolLibrary(found: String?)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case tooLarge(bytes: Int, limit: Int)
        case unreadable(String)
        /// A write was refused because the file already on disk is one this build cannot read.
        case refusingToOverwriteUnreadableLibrary(String)

        public var description: String {
            switch self {
            case .notAZenitToolLibrary(let found):
                return "the tool library file declares format \(found.map { "\"\($0)\"" } ?? "nothing")"
            case .unsupportedSchemaVersion(let found, let supported):
                return "tool library schema version \(found) is not readable by this build (supports \(supported))"
            case .tooLarge(let bytes, let limit):
                return "the tool library file is \(bytes) bytes; this build reads at most \(limit)"
            case .unreadable(let reason):
                return "the tool library file could not be read: \(reason)"
            case .refusingToOverwriteUnreadableLibrary(let reason):
                return "the saved tool library was left untouched because this build cannot read it (\(reason)); nothing was written over it"
            }
        }
    }

    /// The on-disk shape. Written by hand rather than as a bare `[ToolPresetSummary]` so the file
    /// carries a version from its first byte: a preset array with no header is a file that can
    /// only ever be migrated by guessing.
    private struct Envelope: Codable {
        var format: String
        var schemaVersion: Int
        var presets: [ToolPresetSummary]
    }

    /// The directory the library file lives in.
    public let directory: URL

    /// The library file itself.
    public var fileURL: URL { directory.appendingPathComponent("tool-presets.json") }

    /// Creates a store over an explicit directory. Tests pass a temporary one.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The shipping location: `Application Support/Zenit PDF/ToolLibrary`.
    ///
    /// Resolved rather than hard-coded, so it lands inside the container under the sandbox and
    /// in the user's own Application Support without it. If Foundation cannot give a URL at all,
    /// the store falls back to a temporary directory: a Tool Library that does not persist is a
    /// disappointment, and a crash at document open is a broken product.
    public static func standard() -> ToolPresetContainerStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return ToolPresetContainerStore(
            directory: base
                .appendingPathComponent("Zenit PDF", isDirectory: true)
                .appendingPathComponent("ToolLibrary", isDirectory: true)
        )
    }

    /// Whether a library has ever been written here.
    ///
    /// The legacy migration in ``ToolPresetLibraryStore`` turns on this and only this: a package
    /// written before the container store existed is adopted *once*, on a machine that has never
    /// had a personal library, and never afterwards. Opening a project somebody e-mailed you
    /// must not quietly merge their tools into yours.
    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Reads the person's library, or `nil` when none has been written yet.
    ///
    /// - Throws: ``StoreError`` when a file exists and is not one this build can read. Deliberately
    ///   *not* swallowed: a personal library that silently reads as empty is how a person loses
    ///   forty tools and finds out a week later.
    public func read() throws -> [ToolPresetSummary]? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
        guard data.count <= Self.maximumByteCount else {
            throw StoreError.tooLarge(bytes: data.count, limit: Self.maximumByteCount)
        }
        // The header is read before the body, so a file from a future build is refused by
        // version rather than by a decode failure three fields deep.
        let header: [String: Any]?
        do {
            header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
        guard let header, header["format"] as? String == Self.formatIdentifier else {
            throw StoreError.notAZenitToolLibrary(found: header?["format"] as? String)
        }
        guard let version = header["schemaVersion"] as? Int else {
            throw StoreError.notAZenitToolLibrary(found: Self.formatIdentifier)
        }
        guard version == Self.currentSchemaVersion else {
            throw StoreError.unsupportedSchemaVersion(
                found: version, supported: Self.currentSchemaVersion
            )
        }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).presets
        } catch {
            throw StoreError.unreadable(String(describing: error))
        }
    }

    /// Replaces the person's library. Replacement rather than a diff, for the reason
    /// ``ToolPresetArchive/write(_:into:)`` gives: the presenter's array *is* the library.
    ///
    /// Container-scope presets only. Passing a project preset here is a programming error the
    /// filter silences rather than persists — a `Project Tools` row written into the container
    /// would appear in every other project, which is precisely the confusion the two scopes
    /// exist to prevent.
    ///
    /// - Throws: ``StoreError/refusingToOverwriteUnreadableLibrary(_:)`` when a library file
    ///   exists that this build cannot read — a newer build's schema, a transient I/O error.
    ///   `load` degrades such a file to zero presets and a warning that says the saved library
    ///   was left untouched; the document then seeded the six built-ins and saved them straight
    ///   over the person's forty tools (BH-007). A library this build cannot read is a library
    ///   this build must not replace.
    public func write(_ presets: [ToolPresetSummary]) throws {
        if exists() {
            do {
                _ = try read()
            } catch {
                throw StoreError.refusingToOverwriteUnreadableLibrary(String(describing: error))
            }
        }
        let owned = ToolPresetScopeRule.presets(presets, in: .container)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(
            format: Self.formatIdentifier,
            schemaVersion: Self.currentSchemaVersion,
            presets: owned
        ))
        try data.write(to: fileURL, options: .atomic)
    }
}
