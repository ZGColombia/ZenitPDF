import Foundation
import UniformTypeIdentifiers
import ZPDFUIPresentation

/// What the person chose to import artwork from (ADR-0011 §4).
///
/// Two cases and no third, mirroring `ZPDFPDFKitBridge.ArtworkSource` across the UI seam so this
/// package keeps its two dependencies. Anything else — a font glyph, a clipboard flavour, a URL —
/// is a different feature with a different trust story, and adding one later must be a decision
/// rather than a default.
public enum ArtworkImportChoice: Hashable, Sendable {

    /// One page of a PDF file. Compiled to geometry, so it stays sharp at any magnification.
    case pdfPage(url: URL, pageIndex: Int)

    /// An image file. Accepted, marked as raster, and compiled to a bounded mosaic.
    case image(url: URL)

    /// **Ask what a PDF holds; import nothing.** Answers with ``ArtworkImportOutcome/inspected(_:)``.
    ///
    /// The third case, added because the second was quietly wrong for multi-page files: the
    /// chooser took page one and the button's help text admitted it, which is not the same as
    /// handling it. A title block, a seal and a signature block are routinely three pages of
    /// one PDF. This is the question the import sheet asks before it offers a page, and it is
    /// the same bounded, exception-guarded catalogue read the import itself runs first — so a
    /// file the import would refuse is refused here, before a page is chosen out of it.
    case inspectPDF(url: URL)

    /// The file the artwork is read from.
    public var url: URL {
        switch self {
        case let .pdfPage(url, _): return url
        case let .image(url): return url
        case let .inspectPDF(url): return url
        }
    }

    /// The content types the chooser offers for each case.
    public static let pdfContentTypes: [UTType] = [.pdf]
    /// Image types the importer can decode. `UTType.image` covers the concrete formats
    /// `CGImageSource` reads, and the importer refuses anything it cannot decode by name.
    public static let imageContentTypes: [UTType] = [.image]
}

/// What came back from an artwork import.
///
/// A refusal carries **the importer's own sentence**, with the number in it — "this artwork has
/// 41 208 contours; the limit is 20 000" — rather than a generic failure. `ArtworkImportRefusal`
/// went to the trouble of producing that sentence for eight distinct conditions; discarding it at
/// the UI seam and showing "Import failed" would waste the whole point of the refusal.
public enum ArtworkImportOutcome: Hashable, Sendable {

    /// The artwork is compiled and stored; here is what the preset should point at.
    case imported(StampArtworkDescriptor)

    /// It was refused, and this is why, in the importer's own words.
    case refused(String)

    /// The answer to ``ArtworkImportChoice/inspectPDF(url:)``: what the file holds. **Nothing
    /// was imported and nothing was stored.**
    case inspected(ArtworkSourceSummary)
}

/// What a chosen PDF holds, as the import sheet needs to state it.
///
/// The UI-seam mirror of `ZPDFPDFKitBridge.ArtworkSourceInspection`, for the reason every other
/// mirror in this package exists: `ZPDFUIWorkflows` has two dependencies and the bridge is not
/// one of them. Two fields, both of them things a person reads on the sheet.
public struct ArtworkSourceSummary: Hashable, Sendable {

    /// The file's own name.
    public var fileName: String

    /// How many pages it has, at least one.
    public var pageCount: Int

    public init(fileName: String, pageCount: Int) {
        self.fileName = fileName
        self.pageCount = max(1, pageCount)
    }

    /// Whether the person has a page to choose. One page is not a choice, and the sheet still
    /// appears for it — because the single-ink limit below has to be said either way.
    public var offersPageChoice: Bool { pageCount > 1 }
}

/// What imported vector artwork will actually look like, said before the person commits.
///
/// ADR-0011 §2.4, in the place the decision is made rather than only in the ADR. The extractor
/// records ink now (BH-167), and it was decided on 2026-09-23 that an imported stamp looks as
/// drawn by default: a stamp drawn in one colour starts in that colour and the person can
/// recolour it by choosing another; artwork in several colours keeps each filled area's colour,
/// while its lines — which carry no colour in the contract — still draw in the tool's colour. A
/// count symbol draws in the tool's colour, because that colour is the takeoff's colour code.
/// The sheet says so, with the image alternative named for artwork whose colours must survive
/// exactly.
public enum ArtworkVectorLimits {

    /// The sentence shown in the PDF import sheet, above the Import button.
    public static var singleInkNotice: String {
        NSLocalizedString(
            "PDF artwork is imported as line and area geometry and stays sharp at any zoom. A stamp drawn in one colour starts in that colour, and choosing another stamp colour recolours it; a count symbol draws in the tool's colour. Artwork in several colours keeps the colour of each filled area, but its lines draw in the tool's colour. To keep every colour exactly, import the artwork as an image instead — an image keeps its colours and resamples when magnified.",
            comment: "Notice shown in the artwork import sheet before a PDF page is imported, stating how vector artwork keeps or takes colour"
        )
    }
}

/// Runs one artwork import. Installed by the host, which owns the compiler and the project's
/// artwork store; `nil` in a preview, where the Artwork row is read-only.
public typealias ArtworkImportHandler = @MainActor (ArtworkImportChoice) async -> ArtworkImportOutcome
