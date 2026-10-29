import Foundation
import ZPDFPDFKitBridge

/// One job template as a file: a single JSON document with the extension `.zpdftemplate`.
///
/// # The file is data, and it proves what it carries
///
/// The envelope names its format and version from the first byte and carries the SHA-256 of
/// the template's canonical form, computed with the one encoder configuration every template
/// surface uses (``JobTemplateStore/encoder()``). Import decodes the template, re-encodes it
/// canonically, and refuses the file when the digest disagrees — a truncated download, a
/// hand-edited preset, a byte flipped in transit all fail by name rather than arriving as a
/// template that is almost the one that was sent. This mirrors the posture
/// `ToolSetImportValidator` takes for `.zpdftools`: bounded before parsing, header before
/// body, nothing in the file executed, followed or resolved.
///
/// The digest is integrity, not authenticity: it says the template is intact, not who wrote
/// it. Nothing in a template is executable either way — it is presets, subjects, column
/// preferences and units, and the decoder has no key for anything else. In particular it has
/// no key for a scale, so a hostile file cannot smuggle one in through this door;
/// `JobTemplateTests` proves the smuggling attempt decodes to nothing.
public enum JobTemplateFile {

    /// The file extension a template travels under.
    public static let fileExtension = "zpdftemplate"

    /// What the file says it is.
    public static let formatIdentifier = "zenit.jobTemplate.file"

    /// The file format this build writes and the only one it reads.
    public static let currentFormatVersion = 1

    /// Largest file the importer will parse at all — the same bound `.zpdftools` import uses,
    /// for the same reason: a template is configuration, not content.
    public static let maximumByteCount = 8 * 1024 * 1024

    /// Everything the importer can refuse, each naming what was wrong.
    public enum FileError: Error, Hashable, Sendable, CustomStringConvertible {
        case tooLarge(bytes: Int, limit: Int)
        case notAJobTemplate(found: String?)
        case unsupportedFormatVersion(found: Int, supported: Int)
        case digestMismatch(declared: String, computed: String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .tooLarge(let bytes, let limit):
                return "the template file is \(bytes) bytes; this build reads at most \(limit)"
            case .notAJobTemplate(let found):
                return "the file declares format \(found.map { "\"\($0)\"" } ?? "nothing"), not a Zenit job template"
            case .unsupportedFormatVersion(let found, let supported):
                return "template file format \(found) is not readable by this build (supports \(supported))"
            case .digestMismatch(let declared, let computed):
                return "the template does not match its own digest (file says \(declared.prefix(12))…, content is \(computed.prefix(12))…), so it was altered or damaged and Zenit will not add it"
            case .unreadable(let reason):
                return "the template file could not be read: \(reason)"
            }
        }
    }

    /// The on-disk shape.
    private struct Envelope: Codable {
        var format: String
        var formatVersion: Int
        var payloadSHA256: String
        var template: JobTemplate
    }

    // MARK: - Export

    /// The template as the bytes of a `.zpdftemplate` file.
    public static func export(_ template: JobTemplate) throws -> Data {
        let digest = FileDigestReader.digest(of: try canonicalPayload(of: template)).sha256
        return try JobTemplateStore.encoder().encode(Envelope(
            format: formatIdentifier,
            formatVersion: currentFormatVersion,
            payloadSHA256: digest,
            template: template
        ))
    }

    // MARK: - Import

    /// Reads a `.zpdftemplate` file, validating format, version and digest before believing it.
    ///
    /// - Throws: ``FileError`` and nothing else.
    public static func read(_ data: Data) throws -> JobTemplate {
        guard data.count <= maximumByteCount else {
            throw FileError.tooLarge(bytes: data.count, limit: maximumByteCount)
        }
        // Header before body, exactly as the stores read their own files: a future format is
        // refused by version, a foreign file by name, before any field of the template decodes.
        let header: [String: Any]?
        do {
            header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            throw FileError.unreadable(error.localizedDescription)
        }
        guard let header, header["format"] as? String == formatIdentifier else {
            throw FileError.notAJobTemplate(found: header?["format"] as? String)
        }
        guard let version = header["formatVersion"] as? Int else {
            throw FileError.notAJobTemplate(found: formatIdentifier)
        }
        guard version == currentFormatVersion else {
            throw FileError.unsupportedFormatVersion(
                found: version, supported: currentFormatVersion
            )
        }
        let envelope: Envelope
        do {
            envelope = try JobTemplateStore.decoder().decode(Envelope.self, from: data)
        } catch {
            throw FileError.unreadable(String(describing: error))
        }
        let computed: String
        let legacy: String
        do {
            computed = FileDigestReader.digest(of: try canonicalPayload(of: envelope.template)).sha256
            legacy = FileDigestReader.digest(of: try legacyPrettyPayload(of: envelope.template)).sha256
        } catch {
            throw FileError.unreadable(String(describing: error))
        }
        // Files exported before the compact canonical form carry the pretty-printed digest and
        // stay readable.
        guard computed == envelope.payloadSHA256 || legacy == envelope.payloadSHA256 else {
            throw FileError.digestMismatch(declared: envelope.payloadSHA256, computed: computed)
        }
        return envelope.template
    }

    // MARK: - Canonical form

    /// The template's canonical bytes: the one sorted-keys, ISO-8601 encoding, so exporter and
    /// importer hash the same thing whichever machine they run on.
    ///
    /// Compact — sorted keys, no whitespace. The digest used to be taken over the store's
    /// pretty-printed output, which ties integrity to Foundation's indentation and separator
    /// spacing: a formatting change between macOS releases would have reported every exported
    /// template as "altered or damaged" with its bytes intact (BH-466).
    static func canonicalPayload(of template: JobTemplate) throws -> Data {
        let encoder = JobTemplateStore.encoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(template)
    }

    /// The pretty-printed form the digest was taken over before BH-466, for reading old files.
    static func legacyPrettyPayload(of template: JobTemplate) throws -> Data {
        try JobTemplateStore.encoder().encode(template)
    }
}
