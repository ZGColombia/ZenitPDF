import Foundation
import GRDB

// The v7 companion records (stamps). Same discipline as CoreRecords.swift and
// TakeoffHydrationRecords.swift: a faithful mirror of the row, no interpretation.

// MARK: - markup_stamp

/// One placed stamp: the template it came from, and what its dynamic fields said at the
/// instant it was placed.
///
/// The values are stored **as text**. The freezing rule — a stamp that says 2026-08-24
/// must still say that next year — is a storage decision before it is a
/// rendering one: a row that stored the field *kinds* and re-derived their text on read
/// would say the wrong date the first time the project was reopened, and would say a
/// different wrong date every day after that.
public struct MarkupStampRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "markup_stamp"

    public var markupId: String
    /// The tool preset the stamp was placed from.
    public var templateId: String
    /// The preset's name at placement time, kept verbatim: renaming a preset must not
    /// rewrite what a stamp placed last year records itself as.
    public var templateName: String
    /// The template's revision at placement time.
    public var templateRevision: Int
    /// SHA-256 of the artwork bytes in `stamp_artwork`, or NULL for a stamp with no artwork.
    public var artworkDigest: String?
    /// `vector`, `raster` or `none` — whether this stamp stays sharp when magnified.
    public var artworkKind: String
    public var widthPoints: Double
    public var heightPoints: Double
    public var rotationDegrees: Double
    /// `[{kind, slot, resolvedText}]` JSON, in template order.
    public var fieldsJson: String
    /// ``PersistenceTimestamp`` text: when the fields were resolved.
    public var resolvedAt: String

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case markupId = "markup_id"
        case templateId = "template_id"
        case templateName = "template_name"
        case templateRevision = "template_revision"
        case artworkDigest = "artwork_digest"
        case artworkKind = "artwork_kind"
        case widthPoints = "width_points"
        case heightPoints = "height_points"
        case rotationDegrees = "rotation_degrees"
        case fieldsJson = "fields_json"
        case resolvedAt = "resolved_at"
    }

    public init(
        markupId: String,
        templateId: String,
        templateName: String,
        templateRevision: Int = 1,
        artworkDigest: String? = nil,
        artworkKind: String,
        widthPoints: Double,
        heightPoints: Double,
        rotationDegrees: Double = 0,
        fieldsJson: String,
        resolvedAt: String
    ) {
        self.markupId = markupId
        self.templateId = templateId
        self.templateName = templateName
        self.templateRevision = templateRevision
        self.artworkDigest = artworkDigest
        self.artworkKind = artworkKind
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.rotationDegrees = rotationDegrees
        self.fieldsJson = fieldsJson
        self.resolvedAt = resolvedAt
    }
}

// MARK: - stamp_artwork

/// A stamp's artwork bytes, stored once per digest.
///
/// Content-addressed on purpose. A batch that stamps 312 sheets writes one of these and 312
/// ``MarkupStampRecord``s that name it; two presets that happened to import the same seal
/// share one row; and re-importing the same file twice cannot double the project's size.
public struct StampArtworkRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "stamp_artwork"

    /// SHA-256 of ``data``, lower-case hex. The primary key.
    public var digest: String
    /// `vector` for a PDF page, `raster` for an image.
    public var kind: String
    /// The bytes: a single-page PDF, or an image in its original encoding.
    public var data: Data
    /// `data.count`, stored so a size report never has to load the blob.
    public var byteCount: Int
    /// The file the artwork was imported from, for provenance.
    public var sourceName: String?
    /// The page of the source PDF, for vector artwork.
    public var sourcePageIndex: Int?
    /// Pixel width, for raster artwork. This is what makes "sharp to 312 %" a number and
    /// not an adjective.
    public var pixelWidth: Int?
    /// Pixel height, for raster artwork.
    public var pixelHeight: Int?
    /// The artwork **as compiled**: unit-space contours, as JSON.
    ///
    /// This is what is drawn. ``data`` is provenance and a re-compilation input, and nothing
    /// renders from it — re-scanning an untrusted PDF on every open would be a larger attack
    /// surface for no gain, and would make a stamp signed off last year a function of this
    /// year's compiler (ADR-0011 §2.2).
    public var geometryJson: String?
    /// The version of the compiler that produced ``geometryJson``, so a future build can tell
    /// which rows it made and which it inherited, per row rather than per file.
    public var compilerVersion: Int?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case digest
        case kind
        case data
        case byteCount = "byte_count"
        case sourceName = "source_name"
        case sourcePageIndex = "source_page_index"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case geometryJson = "geometry_json"
        case compilerVersion = "compiler_version"
    }

    public init(
        digest: String,
        kind: String,
        data: Data,
        byteCount: Int? = nil,
        sourceName: String? = nil,
        sourcePageIndex: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        geometryJson: String? = nil,
        compilerVersion: Int? = nil
    ) {
        self.digest = digest
        self.kind = kind
        self.data = data
        self.byteCount = byteCount ?? data.count
        self.sourceName = sourceName
        self.sourcePageIndex = sourcePageIndex
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.geometryJson = geometryJson
        self.compilerVersion = compilerVersion
    }

    /// Whether the compiled geometry is small enough for this schema to store.
    ///
    /// The storage layer's own bound, asked independently of the contract's semantic limits on
    /// contours and points, so that a defect in the compiler cannot write a project file no
    /// build can open. Two bounds, two places, on purpose.
    public var geometryFitsSchemaLimit: Bool {
        guard let geometryJson else { return true }
        return geometryJson.utf8.count <= ProjectSchema.maximumArtworkGeometryBytes
    }
}

// MARK: - markup_symbol

/// The symbol one markup draws itself as: a **reference** to artwork, or a built-in glyph.
///
/// The v8 companion for `MarkupRecord.symbol`, in the same shape and for the same reason as
/// ``MarkupStampRecord`` is the companion for its stamp — the authority is the field on the
/// record and this row is its projection, so the two cannot drift apart.
///
/// Storing the *digest* rather than the artwork is what makes a count mark survive its preset:
/// the bytes are in this project, addressed by content, and nothing consults the tool library
/// to draw a mark that has already been placed (ADR-0011 §2.1).
public struct MarkupSymbolRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "markup_symbol"

    public var markupId: String
    /// SHA-256 of the artwork in `stamp_artwork`, or NULL for a built-in glyph.
    public var artworkDigest: String?
    /// `vector`, `raster` or `none`.
    public var artworkKind: String
    /// The built-in glyph's name — `filledCircle`, `cross` and the rest — or NULL.
    ///
    /// A name and not a number: the renderer's raw glyph values are a wire format for a GPU
    /// instance buffer, and a persisted mark must not be pinned to a byte in a shader.
    public var builtInGlyph: String?
    /// Edge of the symbol's square box in PDF points.
    public var sizePoints: Double
    public var rotationDegrees: Double
    /// The file the artwork came from, kept verbatim for provenance.
    public var sourceName: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case markupId = "markup_id"
        case artworkDigest = "artwork_digest"
        case artworkKind = "artwork_kind"
        case builtInGlyph = "built_in_glyph"
        case sizePoints = "size_points"
        case rotationDegrees = "rotation_degrees"
        case sourceName = "source_name"
    }

    public init(
        markupId: String,
        artworkDigest: String? = nil,
        artworkKind: String,
        builtInGlyph: String? = nil,
        sizePoints: Double,
        rotationDegrees: Double = 0,
        sourceName: String? = nil
    ) {
        self.markupId = markupId
        self.artworkDigest = artworkDigest
        self.artworkKind = artworkKind
        self.builtInGlyph = builtInGlyph
        self.sizePoints = sizePoints
        self.rotationDegrees = rotationDegrees
        self.sourceName = sourceName
    }
}
