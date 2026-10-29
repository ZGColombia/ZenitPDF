import CoreGraphics
import Foundation
import ZPDFContracts

/// The drawing under the markups, drawn from the **original file's own content stream**.
///
/// # Why Core Graphics and not the PDFKit bridge
///
/// `ZPDFPDFKitBridge`'s seam hands back pixels — `SnippetPageRasterizing` returns a `CGImage` —
/// which is right for a snippet destined for a mail thread and wrong for a sheet destined for a
/// plotter. A flattened A1 at 600 dpi is 34 000 x 24 000 pixels and 3.3 GB; the same sheet drawn
/// through `CGContextDrawPDFPage` is the original's own operators, resolution-free, at whatever
/// the output device can actually resolve. `CGPDFDocument` is the only API in the platform that
/// will replay a page's content into a context the caller owns, so this is it.
///
/// # The original is opened read-only and is never written
///
/// `CGPDFDocument(url:)` maps the file for reading; there is no mutating call on the type and
/// none is made. `FlattenedPDFWriter` refuses a destination that resolves to the source, so the
/// output cannot land on the input either. `FlattenedPDFWriterTests` hashes the source before and
/// after a flatten and asserts the two digests are equal, because "we only read it" is the sort
/// of claim that should be a measurement.
///
/// # Encryption and refusal
///
/// A password-protected file returns a document that is not unlocked, and every page fetch
/// returns `nil`. That is reported as `false` from ``drawPageContent(sourcePageIndex:into:rect:)``
/// and the caller gets a white sheet carrying the markups — a visibly incomplete export, never a
/// silently blank one and never a crash.
public final class CGPDFPageContentSource: FlattenPageContentDrawing {

    private let document: CGPDFDocument?
    /// The box the source page is fitted from. Crop, to match what the estimator measured
    /// against and what `PageDescriptor.visibleBox` reports.
    private let box: CGPDFBox = .cropBox

    /// Opens `url` for reading.
    ///
    /// - Returns: `nil` when Core Graphics will not open the file at all. A caller that gets
    ///   `nil` should fall back to a raster underlay — the app's `DiskBackedRasterContentSource`
    ///   — rather than abandoning the export.
    public init?(url: URL) {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            return nil
        }
        // An encrypted document that is not unlocked yields no pages. Refusing here rather than
        // per page means the caller learns before it has written half a file.
        guard !document.isEncrypted || document.isUnlocked else { return nil }
        self.document = document
    }

    public func drawPageContent(
        sourcePageIndex: Int,
        into context: CGContext,
        rect: CGRect
    ) -> Bool {
        guard let document else { return false }
        // `CGPDFDocument` numbers pages from 1; every index in this product is zero-based.
        let number = sourcePageIndex + 1
        guard number >= 1, number <= document.numberOfPages,
              let page = document.page(at: number)
        else { return false }

        context.saveGState()
        // `getDrawingTransform` folds in the page's `/Rotate` and the offset of the chosen box,
        // and fits the result inside `rect` without stretching. Doing the quarter turn by hand
        // here is how a rotated sheet prints upside down on one page in forty.
        let transform = page.getDrawingTransform(
            box,
            rect: rect,
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        // Clip to the box itself, so content the crop box excludes stays excluded. A flattened
        // page that suddenly shows the printer's marks outside the crop is a different drawing.
        if let boxRect = pageBox(page) {
            context.clip(to: boxRect)
        }
        context.drawPDFPage(page)
        context.restoreGState()
        return true
    }

    /// Draws the page with the descriptor's crop box and `/Rotate`, mapped onto `rect` the way
    /// the markups are — see ``FlattenPageContentDrawing/drawPageContent(sourcePageIndex:into:rect:page:)``.
    /// When the descriptor and the file agree (every page today: the descriptor is read from the
    /// file on load) the result is the fitted drawing above, pixel for pixel; when they do not,
    /// the linework follows the same geometry as the markups instead of letterboxing away from
    /// them.
    public func drawPageContent(
        sourcePageIndex: Int,
        into context: CGContext,
        rect: CGRect,
        page descriptor: PageDescriptor
    ) -> Bool {
        guard let transform = pageToSheetTransform(for: descriptor, rect: rect) else {
            return drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect)
        }
        guard let document else { return false }
        let number = sourcePageIndex + 1
        guard number >= 1, number <= document.numberOfPages,
              let page = document.page(at: number)
        else { return false }

        let box = descriptor.visibleBox
        context.saveGState()
        context.clip(to: rect)
        context.concatenate(transform)
        // Clip to the descriptor's crop box in page space, so content outside the sheet the
        // estimator measured stays outside it.
        context.clip(to: CGRect(
            x: box.origin.x,
            y: box.origin.y,
            width: box.size.width,
            height: box.size.height
        ))
        context.drawPDFPage(page)
        context.restoreGState()
        return true
    }

    private func pageBox(_ page: CGPDFPage) -> CGRect? {
        let rect = page.getBoxRect(box)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
}
