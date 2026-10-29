import AppKit
import CryptoKit
import Foundation
import ZPDFImageIntake
import ZPDFUIPresentation

/// Opening a scan or a photo of a sheet as a drawing (NL-PLAT-04).
///
/// The image becomes a PDF (``ZPDFImageIntake/ImageIntake``) at its recorded resolution, written
/// into the app's own container with a byte-for-byte copy of the original and a provenance note
/// beside it. The PDF then opens through the normal document path, so everything that works on a
/// PDF drawing works on it. A scan dropped on a project opens as a drawing of its own; it does
/// not join the project's set (X-015 retired the unreachable "add to project" path).
enum ImageDrawingIntake {

    /// A converted image: the PDF to open, the kept original, the note and what the intake found.
    struct Derived: Sendable {
        var pdf: URL
        var original: URL
        var note: URL
        var result: ImageIntakeResult
        var noteData: Data
    }

    /// Where derived drawings live: `Application Support/Zenit PDF/Drawings from Images/`, inside
    /// the sandbox container. One folder per conversion, so two scans with one name never meet.
    static var derivedRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Zenit PDF/Drawings from Images", isDirectory: true)
    }

    /// The provenance note written beside the original, and into the project package.
    struct SourceNote: Codable, Equatable {
        struct Page: Codable, Equatable {
            var index: Int
            var pixelWidth: Int
            var pixelHeight: Int
            var dpiX: Double?
            var dpiY: Double?
            var resolutionTrusted: Bool
            var orientation: Int
            var mediaBoxWidthPoints: Double
            var mediaBoxHeightPoints: Double
        }
        var formatVersion = 1
        var sourceFileName: String
        var sourceType: String
        var sourceSHA256: String
        var pages: [Page]
    }

    /// Converts `image` into a new folder under `root`. Runs off the main actor: decoding a large
    /// scan takes real time. Throws ``ImageIntakeError`` for a refused image, before anything is
    /// written that would stay.
    static func derive(from image: URL, into root: URL, limits: ImageIntakeLimits = .standard) throws -> Derived {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let baseName = image.deletingPathExtension().lastPathComponent
            let pdf = folder.appendingPathComponent("\(baseName).pdf")
            let result = try ImageIntake.makePDF(from: image, to: pdf, limits: limits)
            let original = folder.appendingPathComponent(image.lastPathComponent)
            try FileManager.default.copyItem(at: image, to: original)
            let digest = SHA256.hash(data: try Data(contentsOf: original, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            let note = SourceNote(
                sourceFileName: image.lastPathComponent,
                sourceType: result.sourceTypeIdentifier,
                sourceSHA256: digest,
                pages: result.pages.map { page in
                    var dpiX: Double?, dpiY: Double?
                    switch page.frame.resolution {
                    case let .trusted(x, y): dpiX = x; dpiY = y
                    case .untrusted(.implausible(let x, let y)): dpiX = x; dpiY = y
                    case .untrusted(.missing): break
                    }
                    return SourceNote.Page(
                        index: page.frame.index,
                        pixelWidth: page.frame.pixelWidth,
                        pixelHeight: page.frame.pixelHeight,
                        dpiX: dpiX,
                        dpiY: dpiY,
                        resolutionTrusted: page.frame.resolution.isTrusted,
                        orientation: page.frame.orientation,
                        mediaBoxWidthPoints: page.mediaBox.width,
                        mediaBoxHeightPoints: page.mediaBox.height
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let noteData = try encoder.encode(note)
            let noteURL = folder.appendingPathComponent("source.json")
            try noteData.write(to: noteURL, options: .atomic)
            return Derived(pdf: pdf, original: original, note: noteURL, result: result, noteData: noteData)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    // MARK: - What the person is told

    static let openedNoteID = UUID(uuidString: "3F0A7C1E-8B2D-4E6F-9A1B-5C4D3E2F1A01")!

    /// The status note after a derived drawing opens. It says where the size came from, or that
    /// there is none, in which case the page must be calibrated before anything is measured.
    @MainActor
    static func openedNote(for result: ImageIntakeResult, now: Date = Date()) -> AppWarning {
        let name = result.sourceFileName
        let pageCount = result.pages.count
        if result.allPagesHaveTrustedResolution {
            let resolutions = Set(result.pages.compactMap { page -> Int? in
                if case let .trusted(x, _) = page.frame.resolution { return Int(x.rounded()) }
                return nil
            })
            let dpiText = resolutions.count == 1
                ? String(format: NSLocalizedString("%lld dpi", comment: "A scan resolution, e.g. 300 dpi"), Int64(resolutions.first ?? 0))
                : NSLocalizedString("the resolution each page records", comment: "Scan resolution when pages differ")
            return AppWarning(
                id: openedNoteID,
                severity: .info,
                title: String(
                    format: NSLocalizedString("Opened “%@” as a drawing", comment: "Status note after an image opens as a drawing; the file name"),
                    name
                ),
                message: String(
                    format: NSLocalizedString(
                        "%1$@ at %2$@. The sheet size comes from the scan. Calibrate as usual; Vector Snap has no linework to use on a scan.",
                        comment: "Status note detail after an image opens as a drawing; page count phrase, resolution"
                    ),
                    LocalizedPlural.string(
                        "%lld pages", count: pageCount,
                        one: NSLocalizedString("%lld page", comment: "Page count, singular"),
                        other: NSLocalizedString("%lld pages", comment: "Page count, plural")
                    ),
                    dpiText
                ),
                source: NSLocalizedString("Image", comment: "Status note source for drawings made from images"),
                isDismissible: true,
                timestamp: now
            )
        }
        return AppWarning(
            id: openedNoteID,
            severity: .warning,
            title: String(
                format: NSLocalizedString("“%@” has no trusted resolution", comment: "Status note when an image opened as a drawing has no usable resolution; the file name"),
                name
            ),
            message: NSLocalizedString(
                "The sheet’s real size is not known, so nothing on it is to scale yet. Calibrate each page against a known length before measuring.",
                comment: "Status note detail when an image opened as a drawing has no usable resolution"
            ),
            source: NSLocalizedString("Image", comment: "Status note source for drawings made from images"),
            isDismissible: true,
            timestamp: now
        )
    }

    /// The error an open reports when the intake refuses an image: one sentence naming the file and
    /// the limit, localized.
    static func openError(_ error: Error, fileName: String) -> NSError {
        let reason: String
        switch error as? ImageIntakeError {
        case let .frameTooLarge(_, frame, width, height, limit)?:
            reason = String(
                format: NSLocalizedString(
                    "Page %1$lld is %2$lld × %3$lld pixels. Zenit PDF opens images of up to %4$lld million pixels per page; scan at a lower resolution or split the sheet.",
                    comment: "Refusal of an oversized image; page number, width, height, limit in millions of pixels"
                ),
                Int64(frame + 1), Int64(width), Int64(height), Int64(limit / 1_000_000)
            )
        case let .tooManyFrames(_, count, limit)?:
            reason = String(
                format: NSLocalizedString(
                    "It has %1$lld pages; Zenit PDF opens up to %2$lld pages from one image file.",
                    comment: "Refusal of a multi-page image with too many pages; count, limit"
                ),
                Int64(count), Int64(limit)
            )
        case .fileTooLarge?:
            reason = NSLocalizedString("The file is larger than Zenit PDF opens as a drawing.", comment: "Refusal of an image file over the size limit")
        default:
            reason = NSLocalizedString(
                "It is not a TIFF, JPEG, PNG or HEIC image that can be read.",
                comment: "Refusal of an unreadable image"
            )
        }
        return NSError(domain: "com.zenitgroup.zenitpdf.image-intake", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(
                format: NSLocalizedString("Zenit PDF cannot open “%@” as a drawing.", comment: "Image intake refusal headline; the file name"),
                fileName
            ),
            NSLocalizedRecoverySuggestionErrorKey: reason,
        ])
    }

    /// Posts `note` once the document's presenters exist (a document opens asynchronously).
    @MainActor
    static func post(_ note: AppWarning, to document: ZenitPDFProjectDocument, waitingUpTo seconds: Double = 30) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(seconds)
            while document.core == nil, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            document.core?.document.post(note)
        }
    }
}
