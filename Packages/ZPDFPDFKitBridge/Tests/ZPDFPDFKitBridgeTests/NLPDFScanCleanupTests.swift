import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// NL-PDF-12: scan clean-up measured on synthetic scans whose skew, sheet corners and border are
/// known by construction.
@Suite("Scan clean-up (NL-PDF-12)", .serialized)
struct NLPDFScanCleanupTests {

    /// A 1700 × 1200 "scan": thirty ruled lines and text-like dashes, turned `degrees`
    /// counter-clockwise, on white.
    static func skewedScan(degrees: Double, width: Int = 1700, height: Int = 1200) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(degrees * .pi / 180))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        for row in 0..<30 {
            let y = CGFloat(row * 32 - 480)
            context.fill(CGRect(x: -700, y: y, width: 1400, height: 3))
            var x: CGFloat = -690
            var seed = row * 7919
            while x < 680 {
                seed = (seed * 1103515245 + 12345) & 0x7fffffff
                let w = CGFloat(8 + seed % 30)
                context.fill(CGRect(x: x, y: y + 8, width: w, height: 12))
                x += w + 10
            }
        }
        return context.makeImage()!
    }

    static func pdf(with image: CGImage, pageSize: CGSize, at url: URL) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    @Test("A sheet scanned 2.3° off comes out straight: measured within 0.1°, output within 0.1° of level, same physical size")
    func straightens() throws {
        let scan = Self.skewedScan(degrees: 2.3)
        let measured = try #require(ScanCleanup.skewAngle(of: scan))
        #expect(abs(measured - 2.3) <= 0.1, "measured \(measured)°")
        let negative = try #require(ScanCleanup.skewAngle(of: Self.skewedScan(degrees: -1.2)))
        #expect(abs(negative + 1.2) <= 0.1, "measured \(negative)°")

        let directory = try Corpus.scratchDirectory("scan-cleanup")
        let input = directory.appendingPathComponent("skewed.pdf"), output = directory.appendingPathComponent("clean.pdf")
        // A 612 × 432 pt page (8.5 × 6 in) holding the scan.
        try Self.pdf(with: scan, pageSize: CGSize(width: 612, height: 432), at: input)
        // Old behaviour: no clean-up existed; a skewed scan stayed skewed.
        let reports = try ScanCleanup.cleanDocument(at: input, to: output, options: .init(straightens: true, enhancement: .none, dpi: 200))
        let report = try #require(reports.first)
        #expect(abs((report.measuredSkew ?? 0) - 2.3) <= 0.1)
        let cleaned = try #require(CGPDFDocument(output as CFURL)?.page(at: 1))
        #expect(cleaned.getBoxRect(.mediaBox).size == CGSize(width: 612, height: 432), "physical size kept")
        // Render the cleaned page and measure it again.
        let render = CGContext(data: nil, width: 1700, height: 1200, bitsPerComponent: 8, bytesPerRow: 6800,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        render.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        render.fill(CGRect(x: 0, y: 0, width: 1700, height: 1200))
        render.scaleBy(x: 1700 / 612, y: 1200 / 432)
        render.drawPDFPage(cleaned)
        let rendered = try #require(render.makeImage())
        let after = try #require(ScanCleanup.skewAngle(of: rendered))
        #expect(abs(after) <= 0.1, "residual skew \(after)°")
    }

    @Test("A phone photo of a sheet: the sheet's corners are found and the page rectified to its rectangle")
    func rectifiesAPhoto() throws {
        let width = 1600, height = 1200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.25, green: 0.22, blue: 0.2, alpha: 1)) // a desk
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The sheet, seen at an angle: a trapezoid, wider at the bottom.
        let corners = [CGPoint(x: 220, y: 150), CGPoint(x: 1420, y: 130), CGPoint(x: 1260, y: 1050), CGPoint(x: 360, y: 1070)]
        context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
        context.addLines(between: corners); context.closePath(); context.fillPath()
        context.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)); context.setLineWidth(3)
        context.move(to: CGPoint(x: 420, y: 600)); context.addLine(to: CGPoint(x: 1200, y: 600)); context.strokePath()
        let photo = try #require(context.makeImage())

        let quad = try #require(ScanCleanup.sheetQuadrilateral(in: photo), "the sheet was not found")
        func near(_ normalised: CGPoint, _ pixel: CGPoint) -> Bool {
            abs(normalised.x * CGFloat(width) - pixel.x) < 30 && abs(normalised.y * CGFloat(height) - pixel.y) < 30
        }
        #expect(near(quad.bottomLeft, corners[0]) && near(quad.bottomRight, corners[1]))
        #expect(near(quad.topRight, corners[2]) && near(quad.topLeft, corners[3]))
        let rectified = try #require(ScanCleanup.perspectiveCorrected(photo))
        // The sheet's edges average 1055 wide by 930 tall; the rectified picture has that shape
        // within 5 %, and none of the desk.
        let aspect = Double(rectified.width) / Double(rectified.height)
        #expect(abs(aspect - 1055.0 / 930.0) / (1055.0 / 930.0) < 0.05, "aspect \(aspect)")
    }

    @Test("The scanner's dark border is trimmed; quarter turns swap the sheet's sides; black and white is one-bit")
    func trimTurnEnhance() throws {
        let width = 1000, height = 700
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 60, y: 40, width: 880, height: 620))
        let scan = try #require(context.makeImage())
        let bounds = try #require(ScanCleanup.contentBounds(of: scan))
        #expect(abs(bounds.minX - 60) <= 1 && abs(bounds.minY - 40) <= 1 && abs(bounds.width - 880) <= 2 && abs(bounds.height - 620) <= 2, "\(bounds)")

        let turned = try #require(ScanCleanup.turned(scan, quarterTurns: 1))
        #expect(turned.width == height && turned.height == width)
        let bw = try #require(ScanCleanup.enhanced(Self.skewedScan(degrees: 0, width: 400, height: 300), .blackAndWhite))
        let gray = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 400,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.draw(bw, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let pixels = gray.data!.assumingMemoryBound(to: UInt8.self)
        let midtones = (0..<(400 * 300)).filter { pixels[$0] > 40 && pixels[$0] < 215 }.count
        #expect(Double(midtones) / 120_000 < 0.02, "one-bit: ink black, paper white (\(midtones) grey pixels)")
    }
}
