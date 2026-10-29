import CoreGraphics
import Foundation
import Testing
@testable import ZenitQuickLookCore

/// S-125: a stored `thumbnails/package.png` that does not decode used to cost the whole Finder
/// thumbnail and the Space-bar preview's sheet, although the drawing was readable.
@Suite("Project thumbnails — a stored picture that does not open falls back to the drawing (S-125)")
struct Iter2ThumbnailFallbackTests {

    /// Old output: `nil` — the source was chosen as `.storedImage` on file type and size alone,
    /// and the decode failure ended there (Finder: fileReadCorruptFile, the document icon).
    @Test("A package.png that is not an image: the first sheet is drawn, 256 × 180 as by hand")
    func undecodablePictureFallsBack() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try PackageThumbnailTests.writeDrawing(to: package.appendingPathComponent("documents/working.pdf"))
        try Data("not a PNG, whatever the name says".utf8).write(to: package.appendingPathComponent(PackageThumbnail.storedImageMember))
        #expect(PackageThumbnail.source(in: package) == .storedImage(package.appendingPathComponent(PackageThumbnail.storedImageMember)),
                "the picture is still preferred when it is there")
        let image = try #require(PackageThumbnail.render(package: package, maximum: CGSize(width: 256, height: 256)))
        // 842 × 595 fitted into 256: 256 × 180 (hand-derived in PackageThumbnailTests).
        #expect(image.width == 256 && image.height == 180)
        #expect(try PackageThumbnailTests.gray(image, x: 128, y: 90) < 20, "the drawing's rectangle")
        // The extension's path: one resolution, from the package.
        #expect(PackageThumbnail.resolve(package: package)?.naturalSize == CGSize(width: 842, height: 595))
    }

    /// Old output: `nil` — a picture over 8 192 px is refused by the decoder's cap.
    @Test("A picture over the 8 192 px cap falls back to the drawing too")
    func oversizedPictureFallsBack() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try PackageThumbnailTests.writeDrawing(to: package.appendingPathComponent("documents/working.pdf"))
        try PackageThumbnailTests.writePNG(width: 8_193, height: 2, gray: 0.5,
                                           to: package.appendingPathComponent(PackageThumbnail.storedImageMember))
        let image = try #require(PackageThumbnail.render(package: package, maximum: CGSize(width: 256, height: 256)))
        #expect(image.width == 256 && image.height == 180)
    }

    /// Old output: `nil` — the preview's last fallback went through the same failing source.
    @Test("The Space-bar preview's sheet image falls back to the drawing when both stored pictures fail")
    func previewImageFallsBack() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try PackageThumbnailTests.writeDrawing(to: package.appendingPathComponent("documents/working.pdf"))
        try Data("damaged".utf8).write(to: package.appendingPathComponent(PackageThumbnail.storedImageMember))
        try Data("damaged".utf8).write(to: package.appendingPathComponent(PackagePreview.imageMember))
        #expect(PackagePreview.imageData(in: package) != nil)
    }

    @Test("A drawing member that does not open falls through to the next one")
    func brokenWorkingFallsBackToOriginal() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try Data("%PDF-1.7 truncated".utf8).write(to: package.appendingPathComponent("documents/working.pdf"))
        try PackageThumbnailTests.writeDrawing(to: package.appendingPathComponent("documents/original.pdf"))
        #expect(PackageThumbnail.resolve(package: package)?.naturalSize == CGSize(width: 842, height: 595))
    }
}
