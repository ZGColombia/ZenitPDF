import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZPDFContracts
@testable import ZPDFPDFKitBridge

/// Regression tests for the artwork-import findings of bug hunt 2 (BH-025, BH-026, BH-166,
/// BH-168, BH-567, BH-568). Every fixture is written into the temporary directory by the test.
@Suite("Fix 2 — artwork import")
struct Fix2ArtworkTests {

    private let importer = StampArtworkImporter()

    // MARK: - BH-025

    @Test("BH-025: a /Rotate 90 page imports as the landscape picture the person saw")
    func rotatedPageImportsAsDisplayed() async throws {
        // A portrait media box with /Rotate 90 displays landscape. The stroked rectangle is
        // 40 wide and 180 tall in user space, so the displayed picture is 180 x 40.
        let url = try HandBuiltPDF.onePage(
            content: "0 0 0 RG 1 w 10 10 40 180 re S",
            mediaBox: "[0 0 100 200]",
            pageExtra: "/Rotate 90",
            label: "rotate-90-title-block"
        )
        let artwork = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        // Old code (unrotated user space): sourceAspectRatio == 40 / 180 ≈ 0.222 — sideways.
        #expect(abs(artwork.geometry.sourceAspectRatio - 4.5) < 0.01)
    }

    // MARK: - BH-026

    @Test("BH-026: geometry entirely outside the crop box does not join the artwork")
    func geometryOutsideCropBoxIsDropped() async throws {
        // The crop box keeps only the 80 x 80 seal; the 50 x 50 square at (400, 400) is off
        // the visible page, the way a sheet cropped down in a viewer leaves its content.
        let url = try HandBuiltPDF.onePage(
            content: "0 0 0 RG 1 w 10 10 80 80 re S 400 400 50 50 re S",
            mediaBox: "[0 0 600 600]",
            pageExtra: "/CropBox [0 0 100 100]",
            label: "cropped-seal"
        )
        let artwork = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        // Old code: 2 strokes, and the seal occupied the lower-left 18 % of the unit box.
        #expect(artwork.geometry.strokes.count == 1)
        #expect(abs(artwork.geometry.sourceAspectRatio - 1) < 1e-6)
        let xs = artwork.geometry.strokes.flatMap(\.points).map(\.x)
        #expect(abs((xs.max() ?? 0) - 1) < 1e-9)
    }

    @Test("BH-026: the seal's own page-sized outer box is still kept")
    func pageSizedBorderSurvives() async throws {
        // The page-sized background rules stay off for artwork: a filled box covering the
        // whole crop box is the seal's border, not a sheet background.
        let url = try HandBuiltPDF.onePage(
            content: "0 0 0 rg 0 0 100 100 re f 1 1 1 rg 20 20 60 60 re f",
            mediaBox: "[0 0 100 100]",
            label: "page-sized-seal"
        )
        let artwork = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        #expect(artwork.geometry.regions.count == 2)
    }

    // MARK: - BH-166

    @Test("BH-166: the sharp range is the 96-cell mosaic's, not the source file's")
    func sharpRangeUsesMosaicColumns() async throws {
        let url = try Self.image(width: 288, height: 96, type: .png, label: "wide-seal")
        let artwork = try await importer.importArtwork(from: .image(url: url))
        #expect(artwork.pixelWidth == 288)
        // Old code: 288 / 96 = 3.0 ("sharp to 300 %"). The mosaic holds 96 columns.
        let magnification = try #require(artwork.sharpUntilMagnification(inBoxWidthPoints: 96))
        #expect(abs(magnification - 1.0) < 1e-9)
        #expect(ImportedArtwork.mosaicColumns(pixelWidth: 288, pixelHeight: 96) == 96)
        #expect(ImportedArtwork.mosaicColumns(pixelWidth: 96, pixelHeight: 288) == 32)
        #expect(ImportedArtwork.mosaicColumns(pixelWidth: 32, pixelHeight: 32) == 32)
    }

    // MARK: - BH-168

    @Test("BH-168: EXIF orientation 6 reports the displayed, portrait size")
    func exifOrientationIsApplied() async throws {
        // Stored 64 x 32 (landscape); orientation 6 displays it 32 x 64 (portrait).
        let url = try Self.image(width: 64, height: 32, type: .tiff, orientation: 6, label: "phone-seal")
        let artwork = try await importer.importArtwork(from: .image(url: url))
        // Old code: sourceAspectRatio == 2.0, pixelWidth == 64, pixelHeight == 32.
        #expect(abs(artwork.geometry.sourceAspectRatio - 0.5) < 1e-9)
        #expect(artwork.pixelWidth == 32)
        #expect(artwork.pixelHeight == 64)
    }

    // MARK: - BH-567

    @Test("BH-567: the compiled geometry comes from the bytes that were hashed and stored")
    func geometryMatchesStoredBytes() async throws {
        let url = try HandBuiltPDF.onePage(
            content: "0 0 0 RG 1 w 10 10 80 80 re S",
            mediaBox: "[0 0 100 100]",
            label: "seal-revision-a"
        )
        let revisionA = try Data(contentsOf: url)
        // The file is rewritten in place after it was read — a re-export, a sync client.
        let revisionB = try Data(contentsOf: HandBuiltPDF.onePage(
            content: "0 0 0 RG 1 w 10 10 30 30 re S 60 60 30 30 re S 10 60 20 20 re S",
            mediaBox: "[0 0 100 100]",
            label: "seal-revision-b"
        ))
        try revisionB.write(to: url, options: .atomic)

        let artwork = try await importer.importPDFPage(sourceBytes: revisionA, sourceURL: url, pageIndex: 0)
        // Old code re-opened the URL: 3 strokes from revision B under revision A's digest.
        #expect(artwork.geometry.strokes.count == 1)
        #expect(artwork.sourceBytes == revisionA)
        #expect(artwork.digest == FileDigestReader.digest(of: revisionA, pageIndex: 0).sha256)
    }

    // MARK: - BH-568

    @Test("BH-568: an annotation-only stamp PDF is not called empty")
    func annotationOnlyPageSaysWhy() async throws {
        let appearance = HandBuiltPDF.stream(
            "0 0 0 RG 2 w 5 5 90 40 re S",
            extra: "/Type /XObject /Subtype /Form /BBox [0 0 100 50]"
        )
        let url = try HandBuiltPDF.onePage(
            content: "",
            mediaBox: "[0 0 200 200]",
            pageExtra: "/Annots [5 0 R]",
            additional: [
                "<< /Type /Annot /Subtype /Stamp /Rect [50 50 150 100] /F 4 /AP << /N 6 0 R >> >>",
                appearance
            ],
            label: "annotation-stamp"
        )
        do {
            _ = try await importer.importArtwork(from: .pdfPage(url: url, pageIndex: 0))
            Issue.record("an annotation-only page must be refused")
        } catch let refusal as ArtworkImportRefusal {
            // Old code: ArtworkImportRefusal.empty — "There is nothing to draw on that page."
            #expect(refusal != .empty)
            guard case let .incompleteArtwork(detail) = refusal else {
                Issue.record("expected incompleteArtwork, got \(refusal)")
                return
            }
            #expect(detail.contains("annotation"))
            #expect(detail.contains("flatten"))
        }
    }

    // MARK: - Fixtures

    /// Writes a `width x height` image, left half dark and right half light, with an optional
    /// EXIF/TIFF orientation tag.
    static func image(
        width: Int, height: Int, type: UTType, orientation: Int? = nil, label: String
    ) throws -> URL {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where x < width / 2 {
                let offset = (y * width + x) * 4
                bytes[offset] = 30; bytes[offset + 1] = 30; bytes[offset + 2] = 30
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { throw CocoaError(.fileWriteUnknown) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let ext = type.preferredFilenameExtension ?? "img"
        return try ArtworkFixtures.write(output as Data, name: "\(label).\(ext)")
    }
}
