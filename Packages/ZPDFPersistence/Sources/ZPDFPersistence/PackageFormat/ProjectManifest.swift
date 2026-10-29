import Foundation

/// `manifest.json`, spec 6.3, field for field.
///
/// The JSON keys are the spec's keys exactly. This file is the compatibility contract:
/// a future Zenit PDF reads `schemaVersion` first and decides whether it is allowed to
/// touch anything else, so the key names may not drift and the encoding must stay
/// stable enough to hash.
public struct ProjectManifest: Sendable, Hashable, Codable {

    /// The `.zpdfproj` package format version. Bumped when the *layout* changes.
    public var schemaVersion: Int
    public var projectId: String
    public var displayName: String
    public var createdAt: String
    public var modifiedAt: String
    public var appVersion: String
    /// The database migration count. Bumped when the *schema* changes.
    public var databaseSchema: Int
    public var originalPdfSha256: String
    public var workingPdfSha256: String
    /// Always `PDF_POINTS_BOTTOM_LEFT` in version 1. Present so a future coordinate
    /// convention is a data change rather than a silent reinterpretation of old files.
    public var coordinateSystem: String
    /// The oldest build that may open this file. Advisory; `schemaVersion` is the gate.
    public var minimumReaderVersion: String

    /// The package format this build writes and is willing to open.
    public static let currentSchemaVersion = 1
    public static let pdfPointsBottomLeft = "PDF_POINTS_BOTTOM_LEFT"

    public init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        projectId: String,
        displayName: String,
        createdAt: String,
        modifiedAt: String,
        appVersion: String,
        databaseSchema: Int,
        originalPdfSha256: String,
        workingPdfSha256: String,
        coordinateSystem: String = ProjectManifest.pdfPointsBottomLeft,
        minimumReaderVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.projectId = projectId
        self.displayName = displayName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.appVersion = appVersion
        self.databaseSchema = databaseSchema
        self.originalPdfSha256 = originalPdfSha256
        self.workingPdfSha256 = workingPdfSha256
        self.coordinateSystem = coordinateSystem
        self.minimumReaderVersion = minimumReaderVersion
    }

    // MARK: Coding

    /// Sorted keys and no escaped slashes, so the same manifest always produces the
    /// same bytes and therefore the same SHA-256.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return encoder
    }

    public func encoded() throws -> Data {
        do {
            return try Self.encoder().encode(self)
        } catch {
            throw ZPDFPersistenceError.manifestUnreadable(reason: "encode: \(error.localizedDescription)")
        }
    }

    /// Reads a manifest, refusing anything implausibly large before parsing it.
    ///
    /// A manifest is a few hundred bytes. A multi-megabyte `manifest.json` is not a
    /// manifest, and handing it to `JSONDecoder` is how a hostile file turns into an
    /// allocation the user cannot cancel.
    public static let maximumByteCount = 1 << 20

    public static func read(from url: URL) throws -> ProjectManifest {
        guard FileDurability.exists(url) else {
            throw ZPDFPersistenceError.packageMemberMissing(relativePath: ProjectPackageLayout.manifest)
        }
        // The cap is measured on the descriptor the bytes are read from, never on the
        // path (BH-598): a `manifest.json` that is a symbolic link used to pass the cap
        // with the link's own few bytes and then hand the decoder whatever it pointed at.
        let data: Data
        do {
            data = try FileDurability.readRegularFile(
                at: url, limit: maximumByteCount, what: "manifest.json"
            )
        } catch let error as ZPDFPersistenceError {
            throw error
        } catch {
            throw ZPDFPersistenceError.manifestUnreadable(reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(ProjectManifest.self, from: data)
        } catch {
            throw ZPDFPersistenceError.manifestUnreadable(reason: "decode: \(error.localizedDescription)")
        }
    }

    /// The refusal that protects a user who opens tomorrow's project with today's app.
    public func assertReadable() throws {
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw ZPDFPersistenceError.packageSchemaTooNew(
                found: schemaVersion, supported: Self.currentSchemaVersion
            )
        }
        guard databaseSchema <= ProjectSchema.currentVersion else {
            throw ZPDFPersistenceError.databaseSchemaTooNew(
                found: "manifest databaseSchema \(databaseSchema)",
                supported: ProjectSchema.currentVersion
            )
        }
        // S17-08. `coordinateSystem` documents itself as existing "so a future
        // coordinate convention is a data change rather than a silent reinterpretation
        // of old files" — and until now nothing compared it, so a package could name any
        // convention it liked and have every coordinate in it read as bottom-left points
        // anyway. An unknown value means this build cannot interpret the geometry, and
        // the honest response to "I cannot interpret this" is to stop, not to guess:
        // a takeoff read in the wrong coordinate space is a wrong quantity on an invoice
        // that looks exactly like a right one.
        guard coordinateSystem == Self.pdfPointsBottomLeft else {
            throw ZPDFPersistenceError.unsupportedCoordinateSystem(
                found: coordinateSystem, supported: Self.pdfPointsBottomLeft
            )
        }
    }
}

/// The hashes spec 6.4 requires the save pipeline to take, written beside the manifest.
///
/// Separate from the manifest for one structural reason: the pipeline hashes the
/// manifest, and a document cannot contain its own digest. Keeping the record separate
/// also means verifying a package is a read of two small files rather than a re-encode.
public struct IntegrityRecord: Sendable, Hashable, Codable {
    /// SHA-256 of `manifest.json` as written.
    public var manifestSha256: String
    /// SHA-256 of `project.sqlite` as written, after the WAL was truncated into it.
    public var databaseSha256: String
    public var originalPdfSha256: String
    public var workingPdfSha256: String
    /// Identifier of the save that produced this package. Matches the journal.
    public var saveToken: String
    public var savedAt: String
    /// Serial number of the save, incremented once per successful save.
    public var generation: Int

    public init(
        manifestSha256: String, databaseSha256: String,
        originalPdfSha256: String, workingPdfSha256: String,
        saveToken: String, savedAt: String, generation: Int
    ) {
        self.manifestSha256 = manifestSha256
        self.databaseSha256 = databaseSha256
        self.originalPdfSha256 = originalPdfSha256
        self.workingPdfSha256 = workingPdfSha256
        self.saveToken = saveToken
        self.savedAt = savedAt
        self.generation = generation
    }

    public static let maximumByteCount = 1 << 20

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        do {
            return try encoder.encode(self)
        } catch {
            throw ZPDFPersistenceError.packageMalformed(reason: "integrity encode: \(error.localizedDescription)")
        }
    }

    public static func read(from url: URL) throws -> IntegrityRecord {
        guard FileDurability.exists(url) else {
            throw ZPDFPersistenceError.packageMemberMissing(relativePath: ProjectPackageLayout.integrity)
        }
        do {
            // Same rule as the manifest (BH-598): the cap is checked on the open file.
            let data = try FileDurability.readRegularFile(
                at: url, limit: maximumByteCount, what: "integrity.json"
            )
            return try JSONDecoder().decode(IntegrityRecord.self, from: data)
        } catch let error as ZPDFPersistenceError {
            throw error
        } catch {
            throw ZPDFPersistenceError.packageMalformed(reason: "integrity decode: \(error.localizedDescription)")
        }
    }
}
