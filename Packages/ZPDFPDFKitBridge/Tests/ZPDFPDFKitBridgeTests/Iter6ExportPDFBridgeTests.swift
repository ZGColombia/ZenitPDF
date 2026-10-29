import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// Iteration 6, Clean Up Scanned Sheets: W-053 (Trim Border crops the band the
/// border detection found, not its mirror image) and W-054 (a trimmed or rectified sheet keeps one
/// scale on both axes). No `@testable`: ``ScanCleanup/topLeftPixelRect(_:imageHeight:)`` and
/// ``ScanCleanup/cleanedPaper(_:rendered:cleaned:quarterTurns:dpi:)`` are `package`.
@Suite("Iteration 6 — scan clean-up trim and page size (W-053, W-054)", .serialized)
struct Iter6ExportPDFBridgeTests {

    /// A 1000 × 700 px "scan" of a sheet sitting off-centre on the glass: dark scanner border of
    /// 20 px at the top, 80 px at the bottom and 60 px left and right, so the paper is 880 × 600 px
    /// at x 60…939 and, counted from the top, rows 20…619. A red mark sits on the paper's top
    /// strip (rows 25…44 from the top) and a blue one on its bottom strip (rows 595…614).
    static func offCentreScan() -> CGImage {
        let width = 1000, height = 700
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Core Graphics coordinates: y up, so the top 20 rows are y 680…699 and the bottom 80
        // rows are y 0…79.
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 60, y: 80, width: 880, height: 600))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 400, y: 700 - 45, width: 40, height: 20))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 400, y: 700 - 615, width: 40, height: 20))
        return context.makeImage()!
    }

    /// RGBA bytes of `image`, row 0 the top.
    static func pixels(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The rows of `image` whose mean grey is under 100: scanner border, not paper.
    static func darkRows(of image: CGImage) -> [Int] {
        let bytes = pixels(of: image)
        return (0..<image.height).filter { row in
            var sum = 0
            for column in 0..<image.width {
                let index = (row * image.width + column) * 4
                sum += (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
            }
            return sum / image.width < 100
        }
    }

    /// Whether `image` holds a pixel that is clearly red (or blue).
    static func holds(_ image: CGImage, red: Bool) -> Bool {
        let bytes = pixels(of: image)
        return stride(from: 0, to: bytes.count, by: 4).contains { index in
            red ? bytes[index] > 180 && bytes[index + 2] < 80 : bytes[index + 2] > 180 && bytes[index] < 80
        }
    }

    // MARK: - W-053

    @Test("W-053: the bottom-left content rectangle becomes the top-left crop rectangle, hand-derived")
    func contentRectangleIsFlippedForCropping() throws {
        let scan = Self.offCentreScan()
        // contentBounds is origin bottom-left: 80 rows of border below the paper, so y = 80.
        let bounds = try #require(ScanCleanup.contentBounds(of: scan))
        #expect(bounds == CGRect(x: 60, y: 80, width: 880, height: 600), "\(bounds)")
        // cropping(to:) counts from the top: y = 700 − (80 + 600) = 20, the top border's height.
        #expect(ScanCleanup.topLeftPixelRect(bounds, imageHeight: 700) == CGRect(x: 60, y: 20, width: 880, height: 600))
    }

    @Test("W-053: Trim Border on an off-centre sheet keeps all of the paper and none of the border")
    func trimKeepsThePaper() throws {
        let cleaned = ScanCleanup.clean(
            Self.offCentreScan(), pageIndex: 0, options: .init(straightens: false, trimsBorder: true, enhancement: .none)
        )
        #expect(cleaned.report.trimmed)
        #expect(cleaned.image.width == 880 && cleaned.image.height == 600)
        // Old: the bottom-left rectangle (y 80) was cropped as if top-left, rows 80…679 from the
        // top: 60 rows of the bottom border kept, and paper rows 20…79 — with the red mark — lost.
        #expect(Self.darkRows(of: cleaned.image).isEmpty, "border rows kept: \(Self.darkRows(of: cleaned.image).count)")
        #expect(Self.holds(cleaned.image, red: true), "the paper's top strip was cut off")
        #expect(Self.holds(cleaned.image, red: false), "the paper's bottom strip was cut off")
    }

    // MARK: - W-054

    @Test("W-054: a sheet is rendered for cleaning at the dpi asked, filling the raster")
    func renderFillsTheRaster() throws {
        // A 100 × 100 pt page painted black all over, rendered at 216 dpi: 300 × 300 px, every
        // pixel black. Old: getDrawingTransform never scales up, so the page stayed 100 × 100 px
        // (72 dpi) in the middle of white — 10 000 dark pixels of 90 000.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.setFillColor(CGColor(gray: 0, alpha: 1))
        pdf.fill(box)
        pdf.endPDFPage()
        pdf.closePDF()
        let provider = try #require(CGDataProvider(data: data))
        let page = try #require(CGPDFDocument(provider)?.page(at: 1))
        let raster = try #require(ScanCleanup.render(page, paper: CGSize(width: 100, height: 100), dpi: 216))
        #expect(raster.width == 300 && raster.height == 300)
        let bytes = Self.pixels(of: raster)
        let dark = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 128 }.count
        #expect(dark == 90_000, "\(dark) dark pixels of 90 000")
    }

    @Test("W-054: the page keeps the source size when the picture kept its shape, and is the picture's own size when it did not")
    func cleanedPaperIsHandDerived() throws {
        func image(_ width: Int, _ height: Int) -> CGImage {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        // 400 × 300 pt at 200 dpi renders 1111 × 833 px (400 × 200 / 72 = 1111.1, 300 × 200 / 72
        // = 833.3, rounded).
        let paper = CGSize(width: 400, height: 300)
        let rendered = image(1111, 833)
        #expect(ScanCleanup.cleanedPaper(paper, rendered: rendered, cleaned: image(1111, 833), quarterTurns: 0, dpi: 200) == paper)
        // A quarter turn swaps the picture and the page with it.
        #expect(ScanCleanup.cleanedPaper(paper, rendered: rendered, cleaned: image(833, 1111), quarterTurns: 1, dpi: 200)
            == CGSize(width: 300, height: 400))
        #expect(ScanCleanup.cleanedPaper(paper, rendered: rendered, cleaned: image(833, 1111), quarterTurns: -1, dpi: 200)
            == CGSize(width: 300, height: 400))
        // A trim to 1000 × 700 px: 1000 × 72 / 200 = 360 pt by 700 × 72 / 200 = 252 pt.
        // Old: 400 × 300 whatever the picture — 1000 px over 400 pt across, 700 px over 300 pt down.
        #expect(ScanCleanup.cleanedPaper(paper, rendered: rendered, cleaned: image(1000, 700), quarterTurns: 0, dpi: 200)
            == CGSize(width: 360, height: 252))
    }

    @Test("W-054: a trimmed sheet is written at its own size, so X and Y keep one scale")
    func trimmedSheetKeepsOneScale() throws {
        let directory = try Corpus.scratchDirectory("iter6-scan-trim")
        let input = directory.appendingPathComponent("scan.pdf"), output = directory.appendingPathComponent("clean.pdf")
        // A 720 × 504 pt page (10 × 7 in) holding the 1000 × 700 px scan: at 100 dpi it renders
        // back at 1000 × 700 px, 1 px per source pixel.
        var box = CGRect(x: 0, y: 0, width: 720, height: 504)
        let context = try #require(CGContext(input as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(Self.offCentreScan(), in: box)
        context.endPDFPage()
        context.closePDF()

        let reports = try ScanCleanup.cleanDocument(
            at: input, to: output, options: .init(straightens: false, trimsBorder: true, enhancement: .none, dpi: 100)
        )
        #expect(reports.first?.trimmed == true)
        let page = try #require(CGPDFDocument(output as CFURL)?.page(at: 1))
        let size = page.getBoxRect(.mediaBox).size
        // The 880 × 600 px paper at 100 dpi: 880 × 72 / 100 = 633.6 pt by 600 × 72 / 100 = 432 pt,
        // within two pixels (1.44 pt) for the edge the render softens. Old: 720 × 504 pt, the
        // 880 × 600 px picture stretched onto it — 880 / 720 = 1.2222 px/pt across against
        // 600 / 504 = 1.1905 px/pt down, 2.7 % apart.
        #expect(abs(size.width - 633.6) <= 1.44 && abs(size.height - 432) <= 1.44, "\(size)")
        let pixelsAcross = size.width * 100 / 72, pixelsDown = size.height * 100 / 72
        #expect(abs(pixelsAcross - pixelsAcross.rounded()) < 1e-6 && abs(pixelsDown - pixelsDown.rounded()) < 1e-6,
                "the page is a whole number of cleaned pixels at the cleaning dpi: \(pixelsAcross) × \(pixelsDown)")
    }

    @Test("W-054: a rectified phone photo is written at the sheet's own proportions, not the photo's")
    func rectifiedPhotoKeepsItsProportions() throws {
        let width = 1600, height = 1200
        let photoContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        photoContext.setFillColor(CGColor(red: 0.25, green: 0.22, blue: 0.2, alpha: 1))
        photoContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let corners = [CGPoint(x: 220, y: 150), CGPoint(x: 1420, y: 130), CGPoint(x: 1260, y: 1050), CGPoint(x: 360, y: 1070)]
        photoContext.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
        photoContext.addLines(between: corners); photoContext.closePath(); photoContext.fillPath()
        photoContext.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)); photoContext.setLineWidth(3)
        photoContext.move(to: CGPoint(x: 420, y: 600)); photoContext.addLine(to: CGPoint(x: 1200, y: 600)); photoContext.strokePath()
        let photo = try #require(photoContext.makeImage())

        let directory = try Corpus.scratchDirectory("iter6-scan-rectify")
        let input = directory.appendingPathComponent("photo.pdf"), output = directory.appendingPathComponent("clean.pdf")
        // 576 × 432 pt (8 × 6 in) at 200 dpi renders back at 1600 × 1200 px.
        var box = CGRect(x: 0, y: 0, width: 576, height: 432)
        let context = try #require(CGContext(input as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(photo, in: box)
        context.endPDFPage()
        context.closePDF()

        let reports = try ScanCleanup.cleanDocument(
            at: input, to: output,
            options: .init(straightens: false, correctsPerspective: true, enhancement: .none, dpi: 200)
        )
        #expect(reports.first?.perspectiveCorrected == true, "the sheet was not found")
        let size = try #require(CGPDFDocument(output as CFURL)?.page(at: 1)).getBoxRect(.mediaBox).size
        // The sheet's opposite edges average 1055 px across and 930 px down (NLPDFScanCleanupTests
        // .rectifiesAPhoto): aspect 1.134 within 5 %. Old: the photo's own 576 × 432 page, aspect
        // 1.333 — the rectified sheet stretched about 17.5 % across against down.
        let aspect = Double(size.width / size.height)
        #expect(abs(aspect - 1055.0 / 930.0) / (1055.0 / 930.0) < 0.05, "aspect \(aspect), page \(size)")
        #expect(size != CGSize(width: 576, height: 432))
    }
}
