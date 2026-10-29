import CoreGraphics
import CoreText
import Foundation

/// A synthetic *scanned* sheet: real words, rendered to a bitmap, embedded in a PDF that
/// has no text layer at all.
///
/// ### Why this is not in `ZPDFTestingSupport`
///
/// The corpus already has `content-scanned-look-page`, and this suite uses it — for the
/// half of the requirement that says a scanned page yields nothing before recognition.
/// But that fixture's raster is *statistically* like scanned text: dark runs on light
/// paper, placed by a fixed linear-congruential rule. It has the shape of text and
/// contains no words, which is exactly right for "vector snap must report unavailable" and
/// exactly useless for "and the expected words after OCR", because there are no expected
/// words in it.
///
/// So the OCR test needs a page with legible words and no text layer, and it must be
/// generated rather than checked in: a binary blob in the repository is a fixture nobody
/// can audit. It is built here, in the test target, from CoreText and CoreGraphics, and
/// the words it contains are declared as data next to it.
enum ScannedSheetFixture {

    /// The words drawn on the generated sheet, in reading order, one line each.
    ///
    /// Chosen to exercise what a Swedish or German drawing set actually contains: a plain
    /// English room name, a sheet number with a hyphen, and a word carrying diacritics.
    static let lines: [String] = [
        "ROOM 101",
        "CORRIDOR",
        "DRAWING A-102",
        "KÖK OCH FÖRRÅD"
    ]

    /// Points per rendered inch of the bitmap. High enough that 48-point type survives
    /// the round trip through JPEG-free flate compression and back out of the recogniser.
    static let bitmapScale: CGFloat = 2

    static let pageSize = CGSize(width: 612, height: 792)

    /// Writes the fixture and returns its URL. Regenerated only when absent.
    ///
    /// - Parameter pages: how many identical scanned pages the document has.
    static func write(into directory: URL, name: String = "scanned-words.pdf", pages: Int = 1) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let image = try renderWordsBitmap()
        try writePDF(embedding: image, to: url, pages: max(1, pages))
        return url
    }

    // MARK: - The bitmap

    /// Draws the words into an 8-bit grayscale bitmap with CoreText.
    ///
    /// Grayscale, because a scan is grayscale and because it makes the fixture a third the
    /// size of RGB for no loss of anything the recogniser uses.
    private static func renderWordsBitmap() throws -> CGImage {
        let width = Int(pageSize.width * bitmapScale)
        let height = Int(pageSize.height * bitmapScale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw FixtureFailure.noBitmapContext
        }

        // Paper.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 48 * bitmapScale, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]

        // Lines run down the page from the top, in the bitmap's bottom-left space.
        var baseline = CGFloat(height) - 120 * bitmapScale
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let typeset = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72 * bitmapScale, y: baseline)
            CTLineDraw(typeset, context)
            baseline -= 96 * bitmapScale
        }

        guard let image = context.makeImage() else { throw FixtureFailure.noImage }
        return image
    }

    // MARK: - The PDF

    /// Wraps the bitmap in a one-page PDF whose page dictionary has no `/Font` at all.
    ///
    /// `CGContext(consumer:mediaBox:auxiliaryInfo:)` writes an image XObject and nothing
    /// else, so PDFKit reports ``ZPDFPDFKitBridge/TextAvailability/noTextLayer`` for the
    /// page. That is the property the "nothing before OCR" half of the test rests on, and
    /// it is asserted directly rather than assumed.
    private static func writePDF(embedding image: CGImage, to url: URL, pages: Int) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw FixtureFailure.noPDFContext
        }
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.interpolationQuality = .high
            context.draw(image, in: mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
    }

    enum FixtureFailure: Error, CustomStringConvertible {
        case noBitmapContext
        case noImage
        case noPDFContext

        var description: String {
            switch self {
            case .noBitmapContext: return "CoreGraphics refused a grayscale bitmap context"
            case .noImage: return "the bitmap context produced no image"
            case .noPDFContext: return "CoreGraphics refused a PDF context"
            }
        }
    }
}
