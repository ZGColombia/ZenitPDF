import Foundation
import ZPDFContracts

/// The in-memory shape of a `.zpdfoverlay` file — the measurements, and nothing else (feature 6).
///
/// # What it is for
///
/// One estimator measures a drawing and sends a small file. Another estimator, holding *their own
/// copy of the same drawing*, drops it on and sees exactly what was measured. So the file carries
/// measurements and the identity of the drawing they were measured against, and it carries no
/// totals, no grouping, no filter, no cover page — a `.zpdfjson` already does all of that.
///
/// # The identity is the whole safety property
///
/// ``Source`` names the drawing three ways: the file name it had, its page count, and the SHA-256
/// of its bytes. The importer trusts the digest and only the digest. A renamed file has the same
/// bytes and is accepted; a different drawing has different bytes and is refused with both names
/// and the difference stated. Silently importing a set of page-space coordinates onto a different
/// building is the failure this type exists to make impossible.
///
/// # One record codec
///
/// Each measurement's ledger fields are a ``ZenitInterchangeDocument/Row`` — the same rows,
/// written and read by the same code as `.zpdfjson`. There is no second encoding of a cell in
/// this package.
public struct ZenitOverlayDocument: Hashable, Sendable {

    public static let formatIdentifier = "zenit.measurement.overlay"
    public static let currentSchemaVersion = 1
    public static let fileExtension = "zpdfoverlay"

    /// The largest overlay this build will parse. Checked before the bytes are handed to a
    /// parser, for the same reason ``ZenitInterchangeImport`` checks its own.
    public static let maximumByteCount = 64 * 1024 * 1024

    /// The drawing the overlay was measured against.
    public struct Source: Hashable, Sendable {
        /// The file name at export time, for the human half of a mismatch message.
        public let fileName: String
        public let pageCount: Int
        /// Lowercase hexadecimal SHA-256 of the drawing's bytes — `FileDigest.sha256`.
        public let digestSHA256: String
        /// `FileDigest.byteCount`. Cheap corroboration; the digest is what decides.
        public let digestByteCount: Int

        public init(fileName: String, pageCount: Int, digestSHA256: String, digestByteCount: Int) {
            self.fileName = fileName
            self.pageCount = pageCount
            self.digestSHA256 = digestSHA256
            self.digestByteCount = digestByteCount
        }

        /// The digest, shortened the way a person can compare two of them at a glance.
        public var shortDigest: String { String(digestSHA256.prefix(12)) }
    }

    /// One measurement: its ledger row, and the page-space geometry that drew it.
    public struct Measurement: Hashable, Sendable {
        /// Subject, label, value and every other visible cell, in the `.zpdfjson` row encoding.
        public let row: ZenitInterchangeDocument.Row
        /// The geometry, in canonical PDF page space. `nil` for a row whose geometry the caller
        /// did not supply — the row still travels, it just cannot be redrawn.
        public let geometry: MeasurementGeometry?
        /// Where and how to redraw it on the matching drawing (optional, additive in schema 1).
        /// Page IDs are minted per session, so the geometry's own `pageID` cannot find the page on
        /// another copy; the page *index* can. Absent in files written before 2026-09-23.
        public let placement: Placement?

        public init(row: ZenitInterchangeDocument.Row, geometry: MeasurementGeometry?, placement: Placement? = nil) {
            self.row = row
            self.geometry = geometry
            self.placement = placement
        }
    }

    /// What redrawing a measurement needs beyond its geometry.
    public struct Placement: Hashable, Sendable {
        /// Zero-based index of the page in the drawing the digest names.
        public let pageIndex: Int
        /// The measurement tool's raw value (`MeasurementTool.rawValue`), when the markup had one.
        public let tool: String?
        /// The measurement parameters (depth, height, slope, cutout policy…), as the JSON text the
        /// project database stores them in. Parsed by the app tier with the contract's decoder.
        public let parametersJSON: String?
        /// The markup's style — stroke colour, fill, opacity, line width and pattern — as the JSON
        /// of the contract's `MarkupStyle` (L-47, optional and additive in schema 1). An area
        /// drawn in blue arrived grey and unoutlined on the other copy, because only its geometry
        /// travelled. Absent in files written before 2026-10-04; parsed by the app tier with the
        /// contract's decoder, never trusted beyond it.
        public let styleJSON: String?

        public init(pageIndex: Int, tool: String?, parametersJSON: String?, styleJSON: String? = nil) {
            self.pageIndex = pageIndex
            self.tool = tool
            self.parametersJSON = parametersJSON
            self.styleJSON = styleJSON
        }
    }

    public let schemaVersion: Int
    public let generatedAt: String
    public let producer: ZenitInterchangeDocument.Producer
    public let source: Source
    /// The column definitions the cells are positional against — the same `Column` as `.zpdfjson`.
    public let columns: [ZenitInterchangeDocument.Column]
    public let numberLocale: ZenitInterchangeDocument.NumberLocaleInfo
    public let measurements: [Measurement]

    public init(
        schemaVersion: Int,
        generatedAt: String,
        producer: ZenitInterchangeDocument.Producer,
        source: Source,
        columns: [ZenitInterchangeDocument.Column],
        numberLocale: ZenitInterchangeDocument.NumberLocaleInfo,
        measurements: [Measurement]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.producer = producer
        self.source = source
        self.columns = columns
        self.numberLocale = numberLocale
        self.measurements = measurements
    }
}

/// How an overlay's ``ZenitOverlayDocument/Source`` compares with the drawing it is being dropped
/// onto.
public enum OverlaySourceMatch: Hashable, Sendable {
    /// Same bytes, same name. The ordinary case.
    case identical
    /// Same bytes, different name. Allowed, and reported: renaming a drawing does not change what
    /// it is, and refusing here would make the feature useless the first time somebody tidied
    /// their folder.
    case renamed(from: String, to: String)
}

/// A successful import: the overlay, and how its drawing compared.
public struct OverlayImport: Hashable, Sendable {
    public let document: ZenitOverlayDocument
    public let match: OverlaySourceMatch

    public init(document: ZenitOverlayDocument, match: OverlaySourceMatch) {
        self.document = document
        self.match = match
    }
}
