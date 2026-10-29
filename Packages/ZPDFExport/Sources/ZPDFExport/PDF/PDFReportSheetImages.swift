import CoreGraphics
import ImageIO
import Foundation

/// The report's page-image appendix (NL-QTY-11): each sheet with its markups, painted through the
/// **one** flatten sequence (``FlattenedPDFWriter/paintSheet(page:shape:content:into:rect:)``) —
/// the same underlay-then-markups call the flattened export and print use, so the picture in the
/// report cannot drift from the sheet those produce.
public enum PDFReportSheetImages {

    /// The longest side of a rendered sheet, in pixels. An A1 sheet at this size is legible on an
    /// A4 appendix page and costs a few megabytes, not the hundreds a print-resolution raster would.
    public static let defaultLongestSide = 2_000

    /// The pixel size a sheet of `paper` points is rendered at: aspect kept, longest side
    /// `longestSide`, never larger than two pixels per point.
    public static func pixelSize(paper: CGSize, longestSide: Int = defaultLongestSide) -> (width: Int, height: Int)? {
        guard paper.width.isFinite, paper.height.isFinite, paper.width > 0, paper.height > 0, longestSide > 0 else {
            return nil
        }
        let scale = min(Double(longestSide) / Double(max(paper.width, paper.height)), 2)
        return (max(1, Int((Double(paper.width) * scale).rounded())), max(1, Int((Double(paper.height) * scale).rounded())))
    }

    /// One appendix page per sheet, titled with the sheet's label. A sheet that cannot be painted
    /// is skipped, and its label is returned in `skipped` so the caller can say so.
    public static func render(
        pages: [FlattenPage],
        content: (any FlattenPageContentDrawing)?,
        longestSide: Int = defaultLongestSide
    ) -> (pages: [PDFReportAppendixPage], skipped: [String]) {
        var output: [PDFReportAppendixPage] = []
        var skipped: [String] = []
        for page in pages {
            let label = page.page.label.isEmpty ? "Sheet \(page.page.index + 1)" : page.page.label
            guard let size = pixelSize(paper: page.paperSize, longestSide: longestSide),
                  let context = CGContext(
                      data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { skipped.append(label); continue }
            let scale = Double(size.width) / Double(page.paperSize.width)
            context.scaleBy(x: scale, y: scale)
            let rect = CGRect(origin: .zero, size: page.paperSize)
            guard (try? FlattenedPDFWriter.paintSheet(
                page: page, shape: .flattened, content: content, into: context, rect: rect
            )) != nil, let image = context.makeImage()
            else { skipped.append(label); continue }
            let count = page.markups.count
            output.append(PDFReportAppendixPage(
                title: label,
                caption: count == 1 ? "1 markup" : "\(count) markups",
                image: image
            ))
        }
        return (output, skipped)
    }
}

/// An appendix page as bytes (NL-QTY-11): `Sendable`, so the page images rendered on the main
/// actor can travel to the background task that writes the report. `CGImage` cannot.
public struct PDFReportAppendixImage: Hashable, Sendable {
    public var title: String
    public var caption: String?
    /// PNG bytes.
    public var imageData: Data

    public init(title: String, caption: String?, imageData: Data) {
        self.title = title
        self.caption = caption
        self.imageData = imageData
    }
}

extension PDFReportSheetImages {

    /// The pages as PNG bytes. A page that cannot be encoded is dropped and named in `failed`.
    public static func encode(_ pages: [PDFReportAppendixPage]) -> (images: [PDFReportAppendixImage], failed: [String]) {
        var images: [PDFReportAppendixImage] = []
        var failed: [String] = []
        for page in pages {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                failed.append(page.title); continue
            }
            CGImageDestinationAddImage(destination, page.image, nil)
            guard CGImageDestinationFinalize(destination) else { failed.append(page.title); continue }
            images.append(PDFReportAppendixImage(title: page.title, caption: page.caption, imageData: data as Data))
        }
        return (images, failed)
    }

    /// The pages back as images, for ``PDFReportRenderer/render(_:to:options:appendix:auditAppendix:)``.
    public static func decode(_ images: [PDFReportAppendixImage]) -> [PDFReportAppendixPage] {
        images.compactMap { image in
            Painter.decodeImage(image.imageData).map {
                PDFReportAppendixPage(title: image.title, caption: image.caption, image: $0)
            }
        }
    }
}
