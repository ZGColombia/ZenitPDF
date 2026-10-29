import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFImageIntake
@testable import ZenitPDFAppKit

/// NL-PLAT-04 in the app: a scan opens and drops as a drawing. Nothing is put on screen:
/// documents are opened with `display: false` and the drop opener is replaced.
@MainActor
@Suite("Image drawings in the app — NL-PLAT-04", .appTierSerialised)
struct ImageDrawingIntakeTests {

    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-image-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A multi-page 1-bit TIFF, G4-compressed, at `dpi`.
    private static func writeTIFF(to url: URL, pages: Int, width: Int = 2480, height: Int = 3508, dpi: Int?) throws {
        let bytesPerRow = (width + 7) / 8
        let bits = [UInt8](repeating: 0xFF, count: bytesPerRow * height)
        // Split in two (nl-collaboration): a `#require` nested inside another fails to compile
        // ("recursive expansion of macro") and blocked every app test build. Same checks.
        let provider = try #require(CGDataProvider(data: Data(bits) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, pages, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 4] as CFDictionary,
        ]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        for _ in 0..<pages { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("A scan becomes a PDF, a byte-for-byte copy of the original and a provenance note")
    func deriveKeepsTheOriginal() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tiff = root.appendingPathComponent("Plan room 7.tif")
        try Self.writeTIFF(to: tiff, pages: 3, dpi: 300)
        let derived = try ImageDrawingIntake.derive(from: tiff, into: root.appendingPathComponent("derived"))

        #expect(derived.pdf.lastPathComponent == "Plan room 7.pdf")
        #expect(try Data(contentsOf: derived.original) == Data(contentsOf: tiff))
        let note = try JSONDecoder().decode(ImageDrawingIntake.SourceNote.self, from: Data(contentsOf: derived.note))
        #expect(note.sourceFileName == "Plan room 7.tif")
        #expect(note.pages.count == 3)
        #expect(note.pages.allSatisfy { $0.resolutionTrusted && $0.dpiX == 300 })
        // 2480 px ÷ 300 dpi × 72 = 595.2 pt.
        #expect(note.pages.allSatisfy { abs($0.mediaBoxWidthPoints - 595.2) < 1e-9 })
        let pdf = try #require(CGPDFDocument(derived.pdf as CFURL))
        #expect(pdf.numberOfPages == 3)
    }

    @Test("The note says where the size came from, or that there is none")
    func notesTellTheTruth() throws {
        let trustedFrame = ImageFrameInfo(index: 0, pixelWidth: 2480, pixelHeight: 3508,
                                          resolution: .trusted(dpiX: 300, dpiY: 300), orientation: 1, bitsPerPixel: 1)
        let trusted = ImageIntakeResult(sourceFileName: "scan.tif", sourceTypeIdentifier: "public.tiff",
                                        pages: [ImageIntakePage(frame: trustedFrame, mediaBox: .zero)])
        let good = ImageDrawingIntake.openedNote(for: trusted)
        #expect(good.severity == .info)
        #expect(good.title == "Opened “scan.tif” as a drawing")
        #expect(good.message.hasPrefix("1 page at 300 dpi."))

        var untrustedFrame = trustedFrame
        untrustedFrame.resolution = .untrusted(.missing)
        let untrusted = ImageIntakeResult(sourceFileName: "photo.heic", sourceTypeIdentifier: "public.heic",
                                          pages: [ImageIntakePage(frame: untrustedFrame, mediaBox: .zero)])
        let bad = ImageDrawingIntake.openedNote(for: untrusted)
        #expect(bad.severity == .warning)
        #expect(bad.title == "“photo.heic” has no trusted resolution")
        #expect(bad.message.contains("Calibrate each page"))
    }

    @Test("Opening a TIFF through the document controller opens a 3-page drawing, with no window")
    func openRoutesThroughIntake() async throws {
        // Old code: typeForContents threw unsupportedFileType for anything but .pdf/.zpdfproj.
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tiff = root.appendingPathComponent("A-101 scan.tiff")
        try Self.writeTIFF(to: tiff, pages: 3, dpi: 300)
        #expect(ZenitDocumentController.isImageDrawing(tiff))
        #expect(ZenitDocumentController.openPanelContentTypes.contains(.tiff))

        let controller = ZenitDocumentController()
        ZenitDocumentController.derivedDrawingOpener = { url, _, completion in
            do { completion(try AppTestSupport.makeDocument(opening: url), false, nil) } catch { completion(nil, false, error) }
        }
        defer { ZenitDocumentController.derivedDrawingOpener = nil }
        var opened: NSDocument?
        var failure: (any Error)?
        var finished = false
        controller.openImageDrawing(tiff, release: nil, display: false, root: root.appendingPathComponent("derived")) { document, _, error in
            opened = document; failure = error; finished = true
        }
        #expect(await AppTestSupport.wait(upTo: 30) { finished })
        #expect(failure == nil, "\(String(describing: failure))")
        let document = try #require(opened as? ZenitPDFProjectDocument)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core?.snapshot.pages.count == 3 })
        #expect(await AppTestSupport.wait { document.core?.document.warnings.contains { $0.id == ImageDrawingIntake.openedNoteID } == true })
    }

    @Test("An image over the pixel budget is refused with the limit, and nothing opens")
    func oversizedRefusedOnOpen() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tiff = root.appendingPathComponent("huge.tif")
        try Self.writeTIFF(to: tiff, pages: 1, width: 3000, height: 3000, dpi: 300)
        let refusal = ImageDrawingIntake.openError(
            ImageIntakeError.frameTooLarge(fileName: "huge.tif", frame: 0, pixelWidth: 20_000, pixelHeight: 20_000, limit: 250_000_000),
            fileName: "huge.tif")
        #expect(refusal.localizedDescription == "Zenit PDF cannot open “huge.tif” as a drawing.")
        #expect(refusal.localizedRecoverySuggestion?.contains("20000 × 20000") == true)
        #expect(refusal.localizedRecoverySuggestion?.contains("250 million") == true)

        // End to end with a small budget, so the fixture stays small.
        #expect(throws: ImageIntakeError.self) {
            try ImageDrawingIntake.derive(from: tiff, into: root.appendingPathComponent("derived"),
                                          limits: ImageIntakeLimits(maximumPixelsPerFrame: 1_000_000))
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("derived").path)) ?? []
        #expect(leftovers.isEmpty, "a refused image leaves no folder behind")
    }
}
