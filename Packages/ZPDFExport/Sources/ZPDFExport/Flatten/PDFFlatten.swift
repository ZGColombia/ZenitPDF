import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFRenderer

/// The four shapes a drawing can leave Zenit PDF in, and the one machine that
/// produces three of them.
///
/// # Why one file holds all four
///
/// Printing, the flattened PDF, the clean PDF and the annotated PDF are the same question asked
/// four ways: *which markups belong on this page, and what does the page look like underneath
/// them?* Before this file the answer existed once, for the canvas, and printing answered it
/// again — by rasterising the page and drawing no markup at all, which is how an estimator came
/// to print a measured drawing and receive a blank one
/// (`ZenitPDFProjectDocument.printDocument(_:)`).
///
/// A second drawing implementation is how the canvas and the paper start disagreeing, so there
/// is not one: ``MarkupFlattener`` prepares a scene through `CoreGraphicsMarkupRenderer` — the
/// renderer's own reference backend, the oracle the golden suite compares Metal against — and
/// paints it into whatever `CGContext` it is handed. A print operation hands it the printer's
/// context; ``FlattenedPDFWriter`` hands it a `CGPDFContext`. The pixels cannot differ, because
/// there is only one set of instructions producing them.
public enum PDFExportShape: String, Sendable, Hashable, Codable, CaseIterable {

    /// Standard PDF annotations where the markup type maps onto one, Zenit's own dictionary
    /// where it does not. The markups stay selectable and editable in other readers.
    ///
    /// This shape is **not** produced here: annotations are objects in the file's page tree, not
    /// marks in a content stream, so they are written by `ZPDFPDFKitBridge`'s
    /// `writeAnnotations(_:of:to:)` against a pristine reopen of the original. What this package
    /// contributes is the half both shapes share — which markups are eligible, per
    /// ``PDFExportShape/includesMarkups`` and the `printable` rule below.
    case annotated

    /// The markups drawn into a copy of the page content. What print puts on paper, and what a
    /// recipient without Zenit PDF sees exactly as the estimator saw it.
    case flattened

    /// The drawing with no Zenit markup on it at all.
    case clean

    /// Whether this shape paints markups into the page content stream.
    ///
    /// `annotated` is `false` here and that is not an oversight: an annotated export that also
    /// burned the marks into the content would show every markup twice, once as ink and once as
    /// an annotation, and deleting the annotation in another reader would leave the ink behind.
    public var includesMarkups: Bool {
        switch self {
        case .flattened: true
        case .annotated, .clean: false
        }
    }
}

/// One page of a flatten job: the page's geometry and the markups that belong on it, already in
/// renderer terms.
///
/// The markups arrive as `RenderableMarkup` rather than as `MarkupRecord` on purpose. Turning a
/// record into drawable geometry is the canvas's job and it is done once, in the application's
/// scene builder; a second interpretation living here is the drift this whole file exists to
/// prevent. The `printable` rule is applied *before* this value is built, by whoever built it —
/// see ``PDFFlattenPolicy``.
public struct FlattenPage: Sendable {

    /// The page's geometry: boxes, `/Rotate`, `/UserUnit`.
    public var page: PageDescriptor
    /// Zero-based index of this page in the source document, for the content seam.
    public var sourcePageIndex: Int
    /// The markups to paint, in painter order. Empty is legal and is what ``PDFExportShape/clean``
    /// produces.
    public var markups: [RenderableMarkup]

    public init(page: PageDescriptor, sourcePageIndex: Int, markups: [RenderableMarkup]) {
        self.page = page
        self.sourcePageIndex = sourcePageIndex
        self.markups = markups
    }

    /// The sheet size in the page's own user-space units, `/Rotate` applied — the size the page
    /// appears to have on screen, and the size the page's coordinates (and every markup on it)
    /// are measured in. Equal to points when `/UserUnit` is 1.
    public var sheetSize: CGSize {
        let size = page.rotatedVisibleSize
        return CGSize(width: size.width, height: size.height)
    }

    /// The sheet size in **points** — 1/72 inch — on paper: ``sheetSize`` scaled by the page's
    /// `/UserUnit`.
    ///
    /// A Core Graphics PDF context cannot write `/UserUnit`, so a flattened copy of a
    /// `/UserUnit 2` drawing whose media box kept the unit count would print at half the
    /// physical size. The output sheet is therefore sized in points, and the content is scaled
    /// onto it, which keeps the physical scale the drawing's own unit promised.
    public var paperSize: CGSize {
        let unit = page.userUnit
        guard unit.isFinite, unit > 0 else { return sheetSize }
        let size = sheetSize
        return CGSize(width: size.width * unit, height: size.height * unit)
    }
}

/// The single rule that decides whether a markup is on the paper.
///
/// `MarkupRecord.printable` has existed since the contract was frozen — the catalogue's own
/// wording is *"excluded from print and flattened export when false"* — and until this type
/// nothing in the product read it. One function, used by every consumer, so the print sheet and
/// the flattened file cannot disagree about which marks a person asked to be left off.
public enum PDFFlattenPolicy {

    /// Whether a markup with these two flags belongs in a flattened or printed page.
    ///
    /// Hidden wins over printable: a markup nobody can see on screen is not put on paper by
    /// having been left `printable`.
    public static func isOnPaper(hidden: Bool, printable: Bool) -> Bool {
        !hidden && printable
    }
}

/// Draws the page underneath the markups.
///
/// ``CGPDFPageContentSource`` draws the original page's own content stream and therefore keeps
/// it vector; ``PreferredPageContentSource`` puts a complete appearance in front of it. The
/// raster fallback for a file Core Graphics will not open is the app's own
/// `DiskBackedRasterContentSource`, which holds one rendered sheet in memory at a time.
///
/// Not `Sendable`, and not asynchronous: a `CGContext` is neither. Everything here runs on the
/// thread that owns the context — the main actor under `NSPrintOperation`, the calling thread
/// under ``FlattenedPDFWriter``.
public protocol FlattenPageContentDrawing: AnyObject {

    /// Draws page `sourcePageIndex` into `context`, filling exactly `rect`.
    ///
    /// `rect` is in the context's current space, origin bottom-left, and is the page's
    /// `/Rotate`-applied crop box mapped to the sheet. An implementation must leave the graphics
    /// state as it found it.
    ///
    /// - Returns: `false` when this source has nothing for that page, which is a visible white
    ///   sheet with the markups on it rather than an error. A flatten that refused the whole job
    ///   because one page's underlay was unavailable would lose thirty-nine good sheets to one
    ///   bad one.
    func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect) -> Bool

    /// Draws page `sourcePageIndex` into `rect` **with the page descriptor's geometry** — its
    /// crop box and `/Rotate` — which is the geometry the markups on the same sheet are mapped
    /// with.
    ///
    /// The flatten and print paths call this one. An underlay fitted from the file's own boxes
    /// while the markups are mapped from the descriptor misregisters the two the moment they
    /// disagree (a revision with a different crop, a rotation held in the project before the
    /// file is rewritten), silently, on the artefact nobody re-opens to check. The default
    /// forwards to ``drawPageContent(sourcePageIndex:into:rect:)``, which is right for a source
    /// that has no geometry of its own, such as a supplied raster of the sheet.
    func drawPageContent(
        sourcePageIndex: Int,
        into context: CGContext,
        rect: CGRect,
        page: PageDescriptor
    ) -> Bool
}

public extension FlattenPageContentDrawing {
    func drawPageContent(
        sourcePageIndex: Int,
        into context: CGContext,
        rect: CGRect,
        page: PageDescriptor
    ) -> Bool {
        drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect)
    }
}

/// The affine that carries a page's default user space onto `rect`: the descriptor's crop box,
/// its `/Rotate` applied, stretched onto the rectangle with independent x and y scales — exactly
/// the mapping ``MarkupFlattener`` measures for the markups, so the drawing and the ink on it
/// cannot land in different places.
///
/// - Returns: `nil` for a degenerate box or rectangle.
func pageToSheetTransform(for page: PageDescriptor, rect: CGRect) -> CGAffineTransform? {
    // The inverse of `LayeredMarkupExporter.placement(for:)`, and the same mapping the burned-in
    // annotation appearances use: one implementation (R-112).
    let box = page.visibleBox
    return PageDisplayGeometry.pageToRect(
        box: CGRect(x: box.origin.x, y: box.origin.y, width: box.size.width, height: box.size.height),
        rotation: page.rotation.rawValue,
        rect: rect
    )
}

/// Everything the flatten path can refuse to do. Typed, exhaustive, never a trap.
///
/// A `LocalizedError` whose description is its own words: without it, `localizedDescription` —
/// what a report or an alert quotes — read "The operation couldn't be completed.
/// (ZPDFExport.PDFFlattenError error 1.)" (V-051).
public enum PDFFlattenError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// The job had no pages.
    case noPages
    /// A page's boxes or `/Rotate` do not describe a sheet that can be printed.
    case unusablePage(index: Int, reason: String)
    /// `CGContext(consumer:mediaBox:_:)` returned `nil`.
    case pdfContextUnavailable
    /// The bytes were produced but could not be written.
    case fileWriteFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .noPages:
            "there are no pages to flatten"
        case let .unusablePage(index, reason):
            "page \(index) cannot be laid out on paper: \(reason)"
        case .pdfContextUnavailable:
            "Core Graphics refused to open a PDF context"
        case let .fileWriteFailed(path, reason):
            "could not write \(path): \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
