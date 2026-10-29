import Foundation

/// The person's job templates, in the application container.
///
/// Templates are cross-project by definition — a template exists to start the *next* project —
/// so they live beside the personal Tool Library rather than inside any `.zpdfproj`, under the
/// same support-directory idiom ``ToolPresetContainerStore`` established:
/// `Application Support/Zenit PDF/JobTemplates/job-templates.json`, a versioned JSON document
/// with sorted keys, written atomically, with the directory injectable so a test writes into a
/// temporary directory and can never touch a person's real templates.
///
/// The reader keeps the container store's posture toward its own file: check the format
/// identifier and the schema version before the body, refuse a version it does not know by
/// name, cap the size, and never silently read a broken library as an empty one.
public actor JobTemplateStore {

    /// What the file says it is. A different identifier is a different file that happens to
    /// share a name.
    public static let formatIdentifier = "zenit.jobTemplates.container"

    /// The schema this build writes and the only one it reads.
    public static let currentSchemaVersion = 1

    /// The largest template library this build will read. A template is a preset library plus
    /// a page of preferences; 64 MiB is a ceiling, not a budget.
    public static let maximumByteCount = 64 * 1024 * 1024

    /// Everything the store can refuse to do, each naming what was wrong.
    public enum StoreError: Error, Hashable, Sendable, CustomStringConvertible {
        case notAZenitTemplateLibrary(found: String?)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case tooLarge(bytes: Int, limit: Int)
        case unreadable(String)

        public var description: String {
            switch self {
            case .notAZenitTemplateLibrary(let found):
                return "the job template file declares format \(found.map { "\"\($0)\"" } ?? "nothing")"
            case .unsupportedSchemaVersion(let found, let supported):
                return "job template schema version \(found) is not readable by this build (supports \(supported))"
            case .tooLarge(let bytes, let limit):
                return "the job template file is \(bytes) bytes; this build reads at most \(limit)"
            case .unreadable(let reason):
                return "the job template file could not be read: \(reason)"
            }
        }
    }

    /// The on-disk shape: a header from the first byte, then the templates.
    private struct Envelope: Codable {
        var format: String
        var schemaVersion: Int
        var templates: [JobTemplate]
    }

    /// The directory the library file lives in.
    public let directory: URL

    /// The library file itself.
    public var fileURL: URL { directory.appendingPathComponent("job-templates.json") }

    /// Creates a store over an explicit directory. Tests pass a temporary one.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The shipping location: `Application Support/Zenit PDF/JobTemplates`.
    ///
    /// Resolved rather than hard-coded, so it lands inside the container under the sandbox and
    /// in the user's own Application Support without it — the same resolution, with the same
    /// temporary-directory fallback, as ``ToolPresetContainerStore/standard()``.
    public static func standard() -> JobTemplateStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return JobTemplateStore(
            directory: base
                .appendingPathComponent("Zenit PDF", isDirectory: true)
                .appendingPathComponent("JobTemplates", isDirectory: true)
        )
    }

    /// Reads the person's templates, or `nil` when none have been written yet.
    ///
    /// - Throws: ``StoreError`` when a file exists and is not one this build can read —
    ///   deliberately not swallowed, for the container store's reason: a library that silently
    ///   reads as empty is how a person loses their templates and finds out a project later.
    public func read() throws -> [JobTemplate]? {
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
            throw StoreError.notAZenitTemplateLibrary(found: header?["format"] as? String)
        }
        guard let version = header["schemaVersion"] as? Int else {
            throw StoreError.notAZenitTemplateLibrary(found: Self.formatIdentifier)
        }
        guard version == Self.currentSchemaVersion else {
            throw StoreError.unsupportedSchemaVersion(
                found: version, supported: Self.currentSchemaVersion
            )
        }
        do {
            return try Self.decoder().decode(Envelope.self, from: data).templates
        } catch {
            throw StoreError.unreadable(String(describing: error))
        }
    }

    /// Replaces the person's templates. Replacement rather than a diff: the caller's array
    /// *is* the library, exactly as the container store treats the preset library.
    public func write(_ templates: [JobTemplate]) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let data = try Self.encoder().encode(Envelope(
            format: Self.formatIdentifier,
            schemaVersion: Self.currentSchemaVersion,
            templates: templates
        ))
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Coders

    /// The one encoder configuration every template surface uses: sorted keys, so two saves of
    /// one library are byte-identical, and ISO 8601 dates, so a decoded template re-encodes to
    /// the bytes it was decoded from — which is what lets ``JobTemplateFile`` validate a digest
    /// over the canonical form.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The decoder matching ``encoder()``.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
