import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Limits

/// What an image may cost before it is decoded. Every check runs on the file's header
/// properties, so an oversized or hostile image is refused without allocating its pixels.
public struct ImageIntakeLimits: Sendable, Equatable {
    /// Pixels in one frame. The default, 250 million, admits an A0 sheet scanned at 600 dpi
    /// (about 19 900 × 28 100 = 559 million) only in 1-bit, so it is deliberately a little below
    /// that: 250 M is an A0 at 400 dpi, well above what a plan room delivers.
    public var maximumPixelsPerFrame: Int
    /// Frames (pages) in one file.
    public var maximumFrameCount: Int
    /// Bytes on disk.
    public var maximumFileBytes: Int64

    public init(maximumPixelsPerFrame: Int = 250_000_000, maximumFrameCount: Int = 500, maximumFileBytes: Int64 = 2_000_000_000) {
        self.maximumPixelsPerFrame = maximumPixelsPerFrame
        self.maximumFrameCount = maximumFrameCount
        self.maximumFileBytes = maximumFileBytes
    }

    public static let standard = ImageIntakeLimits()
}

// MARK: - Errors

/// Why an image did not become a sheet. Every case names the file or the frame and a limit, so the
/// sentence the person reads can say what to do.
public enum ImageIntakeError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(fileName: String)
    case notAnImage(fileName: String)
    case noFrames(fileName: String)
    case fileTooLarge(fileName: String, bytes: Int64, limit: Int64)
    case tooManyFrames(fileName: String, count: Int, limit: Int)
    case frameTooLarge(fileName: String, frame: Int, pixelWidth: Int, pixelHeight: Int, limit: Int)
    case decodeFailed(fileName: String, frame: Int)
    case writeFailed(fileName: String)

    public var description: String {
        switch self {
        case let .unreadable(name): return "\(name) could not be read."
        case let .notAnImage(name): return "\(name) is not an image Zenit PDF can open as a drawing."
        case let .noFrames(name): return "\(name) holds no image."
        case let .fileTooLarge(name, bytes, limit): return "\(name) is \(bytes) bytes; the limit is \(limit)."
        case let .tooManyFrames(name, count, limit): return "\(name) has \(count) pages; the limit is \(limit)."
        case let .frameTooLarge(name, frame, w, h, limit):
            return "Page \(frame + 1) of \(name) is \(w) × \(h) pixels; the limit is \(limit) pixels per page."
        case let .decodeFailed(name, frame): return "Page \(frame + 1) of \(name) could not be decoded."
        case let .writeFailed(name): return "The sheet made from \(name) could not be written."
        }
    }
}

// MARK: - Resolution

/// Whether a frame's stated resolution can be trusted as a physical size.
public enum ImageResolution: Sendable, Equatable {
    /// Pixels per inch, horizontally and vertically, as the file states them.
    case trusted(dpiX: Double, dpiY: Double)
    /// The file states no resolution, or one that cannot be a real scan of a real sheet.
    case untrusted(ImageResolutionProblem)

    public var isTrusted: Bool {
        if case .trusted = self { return true }
        return false
    }
}

public enum ImageResolutionProblem: Sendable, Equatable {
    /// No resolution in the file at all (common in phone photos and screenshots).
    case missing
    /// A screen default (72 or 96) on an image far larger than any sheet at that resolution, or a
    /// value outside any scanner's range. The stated value is kept for the note.
    case implausible(dpiX: Double, dpiY: Double)
}

/// One frame of an image file, read from its header only.
public struct ImageFrameInfo: Sendable, Equatable {
    public var index: Int
    /// Stored pixel size, before orientation.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var resolution: ImageResolution
    /// EXIF/TIFF orientation 1…8 (1 = as stored).
    public var orientation: Int
    /// Bits per pixel, when the header says (1 for a CCITT scan).
    public var bitsPerPixel: Int?

    public init(index: Int, pixelWidth: Int, pixelHeight: Int, resolution: ImageResolution, orientation: Int, bitsPerPixel: Int?) {
        self.index = index
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.resolution = resolution
        self.orientation = orientation
        self.bitsPerPixel = bitsPerPixel
    }

    /// Width and height as the sheet is seen, after orientation (5…8 swap the axes).
    public var orientedPixelSize: (width: Int, height: Int) {
        (5...8).contains(orientation) ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight)
    }
}

/// One page of the PDF made from an image.
public struct ImageIntakePage: Sendable, Equatable {
    public var frame: ImageFrameInfo
    /// The page's media box in points. With a trusted resolution this is exactly
    /// `pixels ÷ dpi × 72` on each axis, so a length measured on it is a real length on paper.
    public var mediaBox: CGRect

    public init(frame: ImageFrameInfo, mediaBox: CGRect) {
        self.frame = frame
        self.mediaBox = mediaBox
    }
}

/// The PDF made from an image file, and what it was made from.
public struct ImageIntakeResult: Sendable, Equatable {
    public var sourceFileName: String
    public var sourceTypeIdentifier: String
    public var pages: [ImageIntakePage]

    public init(sourceFileName: String, sourceTypeIdentifier: String, pages: [ImageIntakePage]) {
        self.sourceFileName = sourceFileName
        self.sourceTypeIdentifier = sourceTypeIdentifier
        self.pages = pages
    }

    /// `true` when every page carries a trusted physical size.
    public var allPagesHaveTrustedResolution: Bool { pages.allSatisfy { $0.frame.resolution.isTrusted } }
}

// MARK: - Intake

public enum ImageIntake {

    /// The drawing-image types Zenit opens: TIFF (single and multi-page, CCITT G4 included),
    /// JPEG, PNG and HEIC/HEIF.
    public static let supportedTypes: [UTType] = [.tiff, .jpeg, .png, .heic, .heif]

    /// File extensions of ``supportedTypes`` (lowercase), for drop targets and routing.
    public static let supportedExtensions: Set<String> = ["tif", "tiff", "jpg", "jpeg", "png", "heic", "heif"]

    /// Whether `url` names an image this intake opens, by its extension.
    public static func canOpen(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Screen defaults that software writes when it does not know the real resolution.
    static let screenDefaultDPI: Set<Double> = [72, 96]
    /// The long edge of an A0 sheet in inches (1189 mm), with a margin for oversize plots.
    static let largestPlausibleScreenDefaultSheetInches = 1189.0 / 25.4 * 1.05
    /// PDF's practical page limit is 200 inches (14 400 pt); no trusted page may exceed it.
    static let largestPageInches = 200.0
    static let scannerDPIRange: ClosedRange<Double> = 50...4800

    /// Decides whether a stated resolution is a physical size.
    public static func resolution(dpiX: Double?, dpiY: Double?, pixelWidth: Int, pixelHeight: Int) -> ImageResolution {
        guard let x = dpiX, let y = dpiY, x > 0, y > 0 else { return .untrusted(.missing) }
        guard scannerDPIRange.contains(x), scannerDPIRange.contains(y) else {
            return .untrusted(.implausible(dpiX: x, dpiY: y))
        }
        let longInches = max(Double(pixelWidth) / x, Double(pixelHeight) / y)
        if screenDefaultDPI.contains(x.rounded()), screenDefaultDPI.contains(y.rounded()),
           longInches > largestPlausibleScreenDefaultSheetInches {
            return .untrusted(.implausible(dpiX: x, dpiY: y))
        }
        if longInches > largestPageInches { return .untrusted(.implausible(dpiX: x, dpiY: y)) }
        return .trusted(dpiX: x, dpiY: y)
    }

    /// The media box for a frame. Trusted: `oriented pixels ÷ dpi × 72`. Untrusted: one point per
    /// pixel (72 dpi, the PDF default), shrunk only if that would exceed 200 inches, and never
    /// presented as a physical size.
    public static func mediaBox(for frame: ImageFrameInfo) -> CGRect {
        let (w, h) = frame.orientedPixelSize
        switch frame.resolution {
        case let .trusted(dpiX, dpiY):
            // Orientation 5…8 swaps the axes, so the stated resolutions swap with them.
            let (horizontal, vertical) = (5...8).contains(frame.orientation) ? (dpiY, dpiX) : (dpiX, dpiY)
            return CGRect(x: 0, y: 0, width: Double(w) / horizontal * 72, height: Double(h) / vertical * 72)
        case .untrusted:
            let longest = Double(max(w, h))
            let scale = min(1, largestPageInches * 72 / longest)
            return CGRect(x: 0, y: 0, width: Double(w) * scale, height: Double(h) * scale)
        }
    }

    /// Reads every frame's header. Refuses, before any pixel is decoded, a file over the size
    /// limit, a file with too many frames and a frame over the pixel budget.
    public static func inspect(_ url: URL, limits: ImageIntakeLimits = .standard) throws -> [ImageFrameInfo] {
        let name = url.lastPathComponent
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
        guard let bytes else { throw ImageIntakeError.unreadable(fileName: name) }
        guard bytes <= limits.maximumFileBytes else {
            throw ImageIntakeError.fileTooLarge(fileName: name, bytes: bytes, limit: limits.maximumFileBytes)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageIntakeError.unreadable(fileName: name)
        }
        return try inspect(source, fileName: name, limits: limits)
    }

    static func inspect(_ source: CGImageSource, fileName name: String, limits: ImageIntakeLimits) throws -> [ImageFrameInfo] {
        guard let type = CGImageSourceGetType(source) as String?,
              let utType = UTType(type), supportedTypes.contains(where: { utType.conforms(to: $0) }) else {
            throw ImageIntakeError.notAnImage(fileName: name)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ImageIntakeError.noFrames(fileName: name) }
        guard count <= limits.maximumFrameCount else {
            throw ImageIntakeError.tooManyFrames(fileName: name, count: count, limit: limits.maximumFrameCount)
        }
        var frames: [ImageFrameInfo] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else {
                throw ImageIntakeError.decodeFailed(fileName: name, frame: index)
            }
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, pixels <= limits.maximumPixelsPerFrame else {
                throw ImageIntakeError.frameTooLarge(
                    fileName: name, frame: index, pixelWidth: width, pixelHeight: height, limit: limits.maximumPixelsPerFrame)
            }
            let dpiX = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
            let dpiY = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue
            frames.append(ImageFrameInfo(
                index: index,
                pixelWidth: width,
                pixelHeight: height,
                resolution: resolution(dpiX: dpiX, dpiY: dpiY, pixelWidth: width, pixelHeight: height),
                orientation: (1...8).contains(orientation) ? orientation : 1,
                bitsPerPixel: depth
            ))
        }
        return frames
    }

    /// Writes a PDF with one page per frame of the image at `source` to `destination`.
    ///
    /// Each frame is placed unscaled on a page whose media box is ``mediaBox(for:)``: the PDF
    /// carries the frame's own pixels (a 1-bit scan stays 1-bit), and a trusted resolution makes
    /// the page exactly the paper size the scanner recorded. Frames are decoded one at a time with
    /// caching off, after ``inspect(_:limits:)`` has accepted every header.
    @discardableResult
    public static func makePDF(from source: URL, to destination: URL, limits: ImageIntakeLimits = .standard) throws -> ImageIntakeResult {
        let name = source.lastPathComponent
        let frames = try inspect(source, limits: limits)
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(imageSource) as String? else {
            throw ImageIntakeError.unreadable(fileName: name)
        }
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, [
                  kCGPDFContextCreator: "Zenit PDF image intake",
                  kCGPDFContextTitle: name,
              ] as CFDictionary) else {
            throw ImageIntakeError.writeFailed(fileName: name)
        }
        var pages: [ImageIntakePage] = []
        var failure: ImageIntakeError?
        for frame in frames {
            guard let image = CGImageSourceCreateImageAtIndex(
                imageSource, frame.index, [kCGImageSourceShouldCache: false] as CFDictionary
            ) else {
                failure = .decodeFailed(fileName: name, frame: frame.index)
                break
            }
            var box = mediaBox(for: frame)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.saveGState()
            context.concatenate(orientationTransform(frame.orientation, box: box))
            let drawSize = (5...8).contains(frame.orientation)
                ? CGSize(width: box.height, height: box.width) : box.size
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(origin: .zero, size: drawSize))
            context.restoreGState()
            context.endPDFPage()
            pages.append(ImageIntakePage(frame: frame, mediaBox: box))
        }
        context.closePDF()
        if let failure {
            try? FileManager.default.removeItem(at: destination)
            throw failure
        }
        return ImageIntakeResult(sourceFileName: name, sourceTypeIdentifier: type, pages: pages)
    }

    /// The transform that shows a stored image upright in `box`, for EXIF/TIFF orientations 1…8
    /// (PDF space: origin bottom-left, y up). The image is drawn into (0,0,w,h) where w,h are the
    /// *stored* dimensions scaled to the box.
    static func orientationTransform(_ orientation: Int, box: CGRect) -> CGAffineTransform {
        let w = box.width, h = box.height
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)            // mirrored
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)           // 180°
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)            // mirrored 180°
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h)           // mirrored 90° CW
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)            // 90° CW
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)             // mirrored 90° CCW
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)            // 90° CCW
        default: return .identity
        }
    }
}
