import Foundation
import GRDB
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIPresentation

/// The project's content-addressed artwork store: the one door between an import and
/// `stamp_artwork` (ADR-0011 §2.2).
///
/// # Why this file exists
///
/// `StampArtworkImporter` could compile a PDF page or an image into geometry, refuse eight
/// kinds of hostile input, and address the result by SHA-256 — and nothing in the application
/// could call it, because nothing could *store* what it produced. The table, the digest column
/// and the compiled-geometry column all existed with no writer. This is the writer, and the
/// reader beside it.
///
/// # Content addressing is the whole design
///
/// The key is the SHA-256 of the source bytes, so importing the same seal twice writes one row,
/// two presets that chose the same file share it, and a batch that stamps 312 sheets stores one
/// picture. The row carries three things and the ADR is explicit about why each is there: the
/// **bytes** (provenance, and the input a future compiler would re-read), the **compiled
/// geometry** (what is actually drawn — nothing renders from the bytes, so opening a project
/// never re-scans an untrusted PDF), and the **compiler version** that produced it.
public enum ProjectArtworkStore {

    /// The version stamped on rows this build compiles.
    ///
    /// Per row rather than per file, so a project that accumulated artwork across builds can
    /// say which compiler made which picture.
    public static let compilerVersion = 1

    /// Stores imported artwork, or does nothing when the project already holds it.
    ///
    /// Idempotent by construction: the digest is the primary key and the row is inserted with
    /// `INSERT OR IGNORE` semantics, so re-importing a file the project already has is a
    /// no-op rather than a duplicate or an error.
    ///
    /// - Returns: the descriptor a preset stores — a reference and never bytes.
    @discardableResult
    public static func store(
        _ artwork: ImportedArtwork,
        in package: ProjectPackage
    ) async throws -> StampArtworkDescriptor {
        let geometryJSON = try encodedGeometry(of: artwork.geometry)
        let row = StampArtworkRecord(
            digest: artwork.digest,
            kind: artwork.geometry.kind.rawValue,
            data: artwork.sourceBytes,
            byteCount: artwork.sourceBytes.count,
            sourceName: artwork.sourceName,
            sourcePageIndex: artwork.sourcePageIndex,
            pixelWidth: artwork.pixelWidth,
            pixelHeight: artwork.pixelHeight,
            geometryJson: geometryJSON,
            compilerVersion: compilerVersion
        )
        // The storage layer's own bound, asked separately from the contract's semantic limits
        // on contours and points. Two bounds in two places on purpose: a defect in the compiler
        // must not be able to write a project file no build can open.
        guard row.geometryFitsSchemaLimit else {
            throw ArtworkImportRefusal.tooManyPoints(
                found: artwork.geometry.pointCount,
                limit: ArtworkLimits.maximumTotalPoints
            )
        }
        try await package.write { db in
            try row.insert(db, onConflict: .ignore)
        }
        return descriptor(of: artwork)
    }

    /// Why stored artwork geometry could not be handed out.
    public enum ReadFailure: Error, Hashable, Sendable, CustomStringConvertible {
        /// The row exists and its `geometry_json` does not decode — damaged, or written by a
        /// newer compiler with a primitive this build does not know.
        case undecodable(digest: String, detail: String)
        /// The row decodes to more than the contract's artwork limits allow.
        case exceedsLimits(digest: String, refusal: ArtworkImportRefusal)

        public var description: String {
            switch self {
            case .undecodable(let digest, let detail):
                return "stored artwork \(digest) could not be read: \(detail)"
            case .exceedsLimits(let digest, let refusal):
                return "stored artwork \(digest) exceeds the artwork limits: \(refusal)"
            }
        }
    }

    /// The compiled geometry the project holds for a digest, or `nil` when no row holds it.
    ///
    /// Read from `geometry_json` and never re-derived from the bytes: a stamp signed off last
    /// year must draw the same this year, and re-compiling on open would make the picture a
    /// function of the build (ADR-0011 §2.2).
    ///
    /// - Throws: ``ReadFailure``. A row that does not decode used to read as `nil` — the same
    ///   answer as "no such row" — so a symbol the project demonstrably held drew as the plain
    ///   dot with no word about why (BH-426). And a decoded row is bounded by
    ///   `ArtworkGeometry.limitViolation()`, which documents itself as the one bound the
    ///   compiler, the decoder *and this read path* share; the read path never called it, so an
    ///   edited row with five million points reached every placement unchecked (BH-095).
    public static func geometry(
        forDigest digest: String,
        in package: ProjectPackage
    ) async throws -> ArtworkGeometry? {
        let json = try await package.read { db in
            try StampArtworkRecord.fetchOne(db, key: digest)?.geometryJson
        }
        guard let json else { return nil }
        return try decodeStoredGeometry(json, digest: digest)
    }

    /// The stored source bytes of **raster** artwork — the image file as it was imported — or
    /// `nil` when no row holds the digest or the row is a PDF page.
    ///
    /// ADR-0043: an image placed with Edit ▸ Insert Image is drawn on the canvas from its own
    /// pixels, not from the 96-cell mosaic the compiled geometry holds, which is what made a
    /// 2 400 × 1 700 px photo soft and blocky at any zoom (L-81). A PDF page's bytes are never
    /// handed out here: vector artwork is drawn from its compiled contours, as §2.2 of ADR-0011
    /// requires.
    public static func rasterSourceBytes(
        forDigest digest: String,
        in package: ProjectPackage
    ) async throws -> Data? {
        try await package.read { db in
            guard let row = try StampArtworkRecord.fetchOne(db, key: digest),
                  row.kind == ZPDFContracts.StampArtworkKind.raster.rawValue
            else { return nil }
            return row.data
        }
    }

    /// Decodes and bounds one stored `geometry_json`. Separate so the rule is testable without
    /// a package.
    static func decodeStoredGeometry(_ json: String, digest: String) throws -> ArtworkGeometry {
        let geometry: ArtworkGeometry
        do {
            geometry = try JSONDecoder().decode(ArtworkGeometry.self, from: Data(json.utf8))
        } catch {
            throw ReadFailure.undecodable(digest: digest, detail: String(describing: error))
        }
        if let refusal = geometry.limitViolation() {
            throw ReadFailure.exceedsLimits(digest: digest, refusal: refusal)
        }
        return geometry
    }

    /// The presentation-tier descriptor for imported artwork.
    ///
    /// The value a preset carries: what it is, how big the source was, where it came from and
    /// the digest that addresses it. Never the picture.
    public static func descriptor(of artwork: ImportedArtwork) -> StampArtworkDescriptor {
        StampArtworkDescriptor(
            kind: StampBridge.artworkKind(artwork.geometry.kind),
            digest: artwork.digest,
            byteCount: artwork.sourceBytes.count,
            sourceName: artwork.sourceName,
            sourcePageIndex: artwork.sourcePageIndex,
            pixelWidth: artwork.pixelWidth,
            pixelHeight: artwork.pixelHeight,
            // The seal's one ink, so a stamp preset adopting it starts in the colour it was
            // drawn in (ADR-0011 §2.4).
            sourceInk: artwork.sourceInk.map {
                ColorRGBA(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
            }
        )
    }

    /// Canonical JSON for compiled geometry: sorted keys, so the same artwork produces the same
    /// bytes on two machines and a project diff is about the artwork rather than about the
    /// encoder's mood.
    static func encodedGeometry(of geometry: ArtworkGeometry) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(geometry), as: UTF8.self)
    }
}
