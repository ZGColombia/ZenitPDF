import Foundation
import ZPDFContracts

/// Where imported artwork came from.
///
/// Two cases and no third. A stamp's picture is a page of a PDF or an image file; anything
/// else — a font glyph, a clipboard flavour, a URL — is a different feature with a different
/// trust story, and adding it here later must be a decision rather than a default.
public enum ArtworkSource: Sendable, Hashable {

    /// One page of a PDF file. Compiled to geometry, so it stays sharp at any magnification.
    case pdfPage(url: URL, pageIndex: Int)

    /// An image file. Accepted, marked as raster, and compiled to a bounded mosaic.
    case image(url: URL)

    /// The file this artwork is being read from.
    public var url: URL {
        switch self {
        case let .pdfPage(url, _): return url
        case let .image(url): return url
        }
    }

    /// The page index, for a PDF source.
    public var pageIndex: Int? {
        switch self {
        case let .pdfPage(_, index): return index
        case .image: return nil
        }
    }
}

/// The result of a successful import: compiled geometry, the bytes it came from, and enough
/// provenance for the editor to say what it is and where it came from.
///
/// The bytes travel with the geometry because the project stores both (ADR-0011 §2.2): the
/// geometry is what is drawn, and the bytes are what a future compiler would re-read. Nothing
/// draws from the bytes.
public struct ImportedArtwork: Sendable, Hashable {

    /// The compiled artwork, in unit space.
    public let geometry: ArtworkGeometry
    /// SHA-256 of ``sourceBytes``, lower-case hex. The address the artwork is stored under.
    public let digest: String
    /// The source file's bytes, verbatim.
    public let sourceBytes: Data
    /// The source file's name, for provenance.
    public let sourceName: String
    /// The page the artwork came from, for a PDF source.
    public let sourcePageIndex: Int?
    /// Pixel width of the source, for a raster source.
    public let pixelWidth: Int?
    /// Pixel height of the source, for a raster source.
    public let pixelHeight: Int?
    /// The one ink a PDF page is drawn in, or `nil` when it has several, none, or one the
    /// extractor cannot state (a pattern, a separation). Always `nil` for a raster source,
    /// whose cells carry their own colours.
    ///
    /// Decided 2026-09-23 (ADR-0011 §2.4): an imported stamp looks as drawn by default,
    /// so a red one-colour seal imports red. The seal's geometry stays colourless — strokes
    /// carry no colour in the contract, and fills and strokes must not part company — and this
    /// is the colour the stamp's own colour starts at. Choosing another stamp colour later
    /// recolours every ink region and stroke; white knockouts keep their own white.
    public let sourceInk: RGBAColor?

    public init(
        geometry: ArtworkGeometry,
        digest: String,
        sourceBytes: Data,
        sourceName: String,
        sourcePageIndex: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        sourceInk: RGBAColor? = nil
    ) {
        self.geometry = geometry
        self.digest = digest
        self.sourceBytes = sourceBytes
        self.sourceName = sourceName
        self.sourcePageIndex = sourcePageIndex
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceInk = sourceInk
    }

    /// Whether magnifying the canvas keeps this artwork's edges crisp.
    public var staysSharpWhenMagnified: Bool { geometry.kind.staysSharpWhenMagnified }

    /// The magnification at which a raster source stops adding detail in a box of the given
    /// width, or `nil` for vector artwork.
    ///
    /// The number the preset editor's warning shows. A 300-pixel seal in a 96-point box is
    /// indistinguishable from vector below 312 % and resolution-limited above it, and
    /// "resolution-limited above 312 %" is a fact an estimator can act on in a way that
    /// "this may look worse" is not.
    ///
    /// The detail is the **mosaic's**, not the source file's: import compiles an image to at
    /// most ``ArtworkLimits/maximumRasterSampleEdge`` cells on its longer edge, so a 300-pixel
    /// seal carries 96 columns of detail, and in a 96-point box it stops being sharp at 100 %,
    /// not at the 312 % the raw pixel count suggests (BH-166).
    public func sharpUntilMagnification(inBoxWidthPoints widthPoints: Double) -> Double? {
        guard geometry.kind == .raster, let pixelWidth, pixelWidth > 0, widthPoints > 0,
              widthPoints.isFinite
        else { return nil }
        let columns = Self.mosaicColumns(pixelWidth: pixelWidth, pixelHeight: pixelHeight ?? pixelWidth)
        return Double(columns) / widthPoints
    }

    /// The number of mosaic columns an image of this displayed size compiles to.
    ///
    /// ImageIO downsamples so the longer edge is at most
    /// ``ArtworkLimits/maximumRasterSampleEdge`` and never upsamples, preserving the aspect
    /// ratio; the importer then takes that image's width as its column count.
    public static func mosaicColumns(pixelWidth: Int, pixelHeight: Int) -> Int {
        let edge = ArtworkLimits.maximumRasterSampleEdge
        guard pixelWidth > 0 else { return 0 }
        let longer = Swift.max(pixelWidth, Swift.max(0, pixelHeight))
        guard longer > edge else { return pixelWidth }
        let scaled = (Double(pixelWidth) * Double(edge) / Double(longer)).rounded()
        return Swift.max(1, Swift.min(edge, Int(scaled)))
    }
}

/// What a chosen PDF holds, answered before anything is imported from it.
///
/// Produced by ``StampArtworkImporter/inspectPDF(at:)``. It exists so a chooser can offer the
/// page a person actually wants instead of taking page one and mentioning it in help text: a
/// title block, a seal and a signature block are routinely three pages of one file, and "the
/// import silently takes page 1" is a defect however honestly it is documented.
public struct ArtworkSourceInspection: Sendable, Hashable {

    /// The file's own name, for the sentence the chooser shows.
    public var fileName: String

    /// How many pages the file has. Always at least one — a document with none is refused
    /// as unreadable rather than described.
    public var pageCount: Int

    public init(fileName: String, pageCount: Int) {
        self.fileName = fileName
        self.pageCount = pageCount
    }

    /// Whether the person has a choice to make. One page is not a choice.
    public var offersPageChoice: Bool { pageCount > 1 }
}
