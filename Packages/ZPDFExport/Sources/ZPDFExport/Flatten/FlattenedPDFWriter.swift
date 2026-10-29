import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFRenderer

/// Writes the flattened and clean output shapes: a new PDF whose pages carry the
/// original drawing's content, with Zenit's markups painted into it or deliberately left off.
///
/// # What it guarantees, and how each guarantee is kept
///
/// * **The original is never modified.** Nothing here opens the source for writing; the only
///   reader is ``CGPDFPageContentSource``, and ``write(_:pages:content:to:)`` refuses a
///   destination that resolves to a file the content source was opened from. The test hashes the
///   source before and after.
/// * **Page size and orientation are preserved.** Each page gets its own `/MediaBox`, set to that
///   page's `/Rotate`-applied crop box, because a construction set mixes ARCH-D details into an
///   ARCH-E set and scaling them to one paper size would print the wrong scale — which in this
///   application means printing a wrong dimension.
/// * **Scale is preserved.** One PDF point in equals one PDF point out; there is no fit step.
/// * **Markups stay vector.** They are painted by ``MarkupFlattener`` into a `CGPDFContext`, so
///   they leave as path operators, not as a sampled image.
/// * **`printable == false` is absent.** Not filtered here — filtered by whoever built the
///   ``FlattenPage`` values, through ``PDFFlattenPolicy``, so print and export cannot apply two
///   different rules.
public struct FlattenedPDFWriter: Sendable {

    /// Document-level metadata written into the output's `/Info`.
    public struct Metadata: Sendable, Hashable {
        public var title: String?
        public var creator: String?
        /// `/Subject`, used to record which of the four shapes this file is.
        public var subject: String?

        public init(title: String? = nil, creator: String? = nil, subject: String? = nil) {
            self.title = title
            self.creator = creator
            self.subject = subject
        }

        var auxiliaryInfo: CFDictionary? {
            var info: [CFString: Any] = [:]
            if let title { info[kCGPDFContextTitle] = title }
            if let creator { info[kCGPDFContextCreator] = creator }
            if let subject { info[kCGPDFContextSubject] = subject }
            return info.isEmpty ? nil : info as CFDictionary
        }
    }

    public init() {}

    /// Produces the bytes.
    ///
    /// - Parameters:
    ///   - shape: which of the two content-stream shapes this is.
    ///     ``PDFExportShape/clean`` paints no markup whatever the pages carry, so a caller
    ///     cannot produce a "clean" file with ink on it by passing the wrong page list.
    ///   - pages: the sheets, in output order.
    ///   - content: the underlay. `nil` writes the markups onto white, which is a legitimate
    ///     overlay-only artefact and is what the tests assert geometry against.
    public func data(
        shape: PDFExportShape,
        pages: [FlattenPage],
        content: (any FlattenPageContentDrawing)?,
        metadata: Metadata = Metadata()
    ) throws -> Data {
        guard !pages.isEmpty else { throw PDFFlattenError.noPages }

        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer as CFMutableData) else {
            throw PDFFlattenError.pdfContextUnavailable
        }
        // The context's own media box is a default only; every page overrides it below, which is
        // the whole reason a mixed-size set survives the round trip.
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultBox,
            metadata.auxiliaryInfo
        ) else {
            throw PDFFlattenError.pdfContextUnavailable
        }

        for page in pages {
            try draw(page: page, shape: shape, content: content, into: context)
        }
        context.closePDF()
        return buffer as Data
    }

    /// Produces the bytes and writes them.
    ///
    /// The write is atomic, so a full disk or a crash leaves the previous file rather than a
    /// truncated one that opens as a damaged drawing.
    public func write(
        shape: PDFExportShape,
        pages: [FlattenPage],
        content: (any FlattenPageContentDrawing)?,
        to url: URL,
        metadata: Metadata = Metadata(),
        protecting sources: [URL] = []
    ) throws {
        // The one same-file rule every drawing writer shares: by path and by file identifier, so a
        // case-variant name on a case-insensitive volume or a hard link is the drawing too (W-058).
        try StagedFileReplacement.refuseOverwriting(
            sources, with: url,
            refusal: PDFFlattenError.fileWriteFailed(path: url.path, reason: "the destination is the drawing being exported")
        )
        let bytes = try data(shape: shape, pages: pages, content: content, metadata: metadata)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw PDFFlattenError.fileWriteFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - One page

    /// Draws one sheet into an open PDF context.
    ///
    /// Exposed because `NSPrintOperation`'s view needs the identical sequence into a context it
    /// does not own, and a print path that repeated these four steps by hand would be the second
    /// implementation this file exists to avoid. The print view calls
    /// ``paintSheet(page:shape:content:into:rect:)``; this method is that call plus the page
    /// bracket.
    private func draw(
        page: FlattenPage,
        shape: PDFExportShape,
        content: (any FlattenPageContentDrawing)?,
        into context: CGContext
    ) throws {
        // Points on paper, not user-space units: a `/UserUnit 2` sheet is twice as large as its
        // unit count says, and this context cannot write `/UserUnit` to say so.
        let size = page.paperSize
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw PDFFlattenError.unusablePage(
                index: page.page.index,
                reason: "the crop box is empty or non-finite"
            )
        }
        var mediaBox = CGRect(origin: .zero, size: size)
        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: Data(
                bytes: &mediaBox,
                count: MemoryLayout<CGRect>.size
            ) as CFData
        ]
        context.beginPDFPage(pageInfo as CFDictionary)
        try Self.paintSheet(
            page: page,
            shape: shape,
            content: content,
            into: context,
            rect: mediaBox
        )
        context.endPDFPage()
    }

    /// Paints one sheet — underlay then markups — into `rect` of an already-open context.
    ///
    /// This is the shared body of every consumer that puts ink on a page:
    /// the flattened file above, and `DocumentPrintView` on paper. Both get the underlay drawn
    /// the same way, both get the markups through ``MarkupFlattener``, and neither can drift from
    /// the other because there is one copy of the sequence.
    @discardableResult
    public static func paintSheet(
        page: FlattenPage,
        shape: PDFExportShape,
        content: (any FlattenPageContentDrawing)?,
        into context: CGContext,
        rect: CGRect
    ) throws -> MarkupFlattener.Outcome {
        // White under everything. A page whose underlay is unavailable is then a blank sheet
        // with its markups on it rather than a transparent one that prints as whatever the
        // previous drawing left in the buffer.
        context.saveGState()
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.restoreGState()

        _ = content?.drawPageContent(
            sourcePageIndex: page.sourcePageIndex,
            into: context,
            rect: rect,
            page: page.page
        )

        guard shape.includesMarkups else { return .nothing }
        return try MarkupFlattener.paint(
            page: page.page,
            markups: page.markups,
            into: context,
            rect: rect
        )
    }
}
