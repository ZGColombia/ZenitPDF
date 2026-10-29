import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ZenitQuickLookCore

/// NL-PLAT-21: what Finder shows for a project. Sizes are hand-derived from the fixtures.
@Suite("Project thumbnails for Finder")
struct PackageThumbnailTests {

    static func package() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-ql-\(UUID().uuidString)/Plan.zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)
        return url
    }

    /// A one-page A4 landscape PDF (842 × 595 pt) with a black 400 × 200 rectangle at its centre.
    static func writeDrawing(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 842, height: 595)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 221, y: 197.5, width: 400, height: 200))
        context.endPDFPage()
        context.closePDF()
    }

    static func writePNG(width: Int, height: Int, gray: CGFloat, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The sRGB gray of the pixel at (x, y) from the top-left, 0–255.
    static func gray(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Int(data[(y * image.width + x) * 4])
    }

    @Test("With no saved picture the first sheet is drawn: 842 × 595 fits 256 as 256 × 180, the rectangle black at the centre, paper white at the edge")
    func drawsTheFirstSheet() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try Self.writeDrawing(to: package.appendingPathComponent("documents/working.pdf"))
        #expect(PackageThumbnail.source(in: package) == .drawing(package.appendingPathComponent("documents/working.pdf")))
        let image = try #require(PackageThumbnail.render(package: package, maximum: CGSize(width: 256, height: 256)))
        // 256 / 842 = 0.30404; 595 × 0.30404 = 180.9, rounded down to 180.
        #expect(image.width == 256 && image.height == 180)
        #expect(try Self.gray(image, x: 128, y: 90) < 20, "the drawing's rectangle")
        #expect(try Self.gray(image, x: 4, y: 4) > 235, "white paper")
    }

    @Test("A saved picture wins over the drawing, and is never scaled up")
    func storedPictureWins() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try Self.writeDrawing(to: package.appendingPathComponent("documents/working.pdf"))
        try Self.writePNG(width: 120, height: 80, gray: 0.5, to: package.appendingPathComponent("thumbnails/package.png"))
        #expect(PackageThumbnail.source(in: package) == .storedImage(package.appendingPathComponent("thumbnails/package.png")))
        let image = try #require(PackageThumbnail.render(package: package, maximum: CGSize(width: 512, height: 512)))
        #expect(image.width == 120 && image.height == 80)
    }

    @Test("The original drawing stands in when there is no working copy")
    func fallsBackToTheOriginal() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try Self.writeDrawing(to: package.appendingPathComponent("documents/original.pdf"))
        #expect(PackageThumbnail.source(in: package) == .drawing(package.appendingPathComponent("documents/original.pdf")))
    }

    @Test("A link, an empty file or a damaged PDF is no thumbnail: Finder shows the document icon")
    func untrustedMembersRefused() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let outside = package.deletingLastPathComponent().appendingPathComponent("elsewhere.pdf")
        try Self.writeDrawing(to: outside)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("documents/working.pdf"), withDestinationURL: outside)
        #expect(PackageThumbnail.source(in: package) == nil, "a link out of the package is not followed")
        try FileManager.default.removeItem(at: package.appendingPathComponent("documents/working.pdf"))
        try Data().write(to: package.appendingPathComponent("documents/working.pdf"))
        #expect(PackageThumbnail.source(in: package) == nil)
        try Data("%PDF-1.7\nthis is not a drawing".utf8).write(to: package.appendingPathComponent("documents/working.pdf"))
        #expect(PackageThumbnail.render(package: package, maximum: CGSize(width: 256, height: 256)) == nil)
    }

    @Test("Fitting keeps proportions and never enlarges")
    func fitting() {
        #expect(PackageThumbnail.fitted(CGSize(width: 842, height: 595), into: CGSize(width: 128, height: 128)) == CGSize(width: 128, height: 90))
        #expect(PackageThumbnail.fitted(CGSize(width: 100, height: 50), into: CGSize(width: 1024, height: 1024)) == CGSize(width: 100, height: 50))
        #expect(PackageThumbnail.fitted(CGSize(width: 0, height: 50), into: CGSize(width: 64, height: 64)) == .zero)
    }
}

/// R-210: a thumbnail opens its source once.
@Suite("Project thumbnails — one open per thumbnail (R-210)")
struct Iter1ThumbnailOpenTests {

    private func opens(_ body: () throws -> Void) rethrows -> Int {
        let counter = PackageThumbnail.OpenCounter()
        try PackageThumbnail.$openCounter.withValue(counter) { try body() }
        return counter.count
    }

    @Test("Sizing and drawing come from one open: one decode of the picture, one open of the drawing")
    func oneOpenPerThumbnail() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try PackageThumbnailTests.writeDrawing(to: package.appendingPathComponent("documents/working.pdf"))

        var drawn: CGImage?
        // Old output: 2 — `naturalSize(of:)` opened the PDF, then `draw` opened it again.
        #expect(opens { drawn = PackageThumbnail.render(package: package, maximum: CGSize(width: 256, height: 256)) } == 1)
        #expect(drawn?.width == 256 && drawn?.height == 180)

        try PackageThumbnailTests.writePNG(width: 120, height: 80, gray: 0.5,
                                           to: package.appendingPathComponent("thumbnails/package.png"))
        var pictured: CGImage?
        #expect(opens { pictured = PackageThumbnail.render(package: package, maximum: CGSize(width: 512, height: 512)) } == 1)
        #expect(pictured?.width == 120 && pictured?.height == 80)

        // The extension's own path: resolve once, then size and draw from the resolved source.
        let resolved = try #require(PackageThumbnail.source(in: package).flatMap(PackageThumbnail.resolve))
        let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let later = opens {
            #expect(resolved.naturalSize == CGSize(width: 120, height: 80))
            resolved.draw(in: context, size: CGSize(width: 120, height: 80))
        }
        #expect(later == 0, "sizing and drawing a resolved source open nothing")
    }
}
