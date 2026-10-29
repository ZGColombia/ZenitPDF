import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Source bytes → the stored form: bounded, downscaled, re-encoded, metadata dropped.
///
/// CoreGraphics and ImageIO only — no new dependency, and the same hostile-input
/// discipline `StampArtworkImporter` keeps for artwork:
///
/// - the declared pixel count is read from the image source's *metadata* and refused
///   before a decode is attempted, so a decode bomb never allocates;
/// - the downscale happens **during** decode (`kCGImageSourceThumbnailMaxPixelSize`), so
///   the full-resolution bitmap is never materialised even for a legal 100-megapixel scan;
/// - EXIF orientation is baked into the pixels (`kCGImageSourceCreateThumbnailWithTransform`),
///   so the stored photograph is upright without carrying the flag that made it so;
/// - the re-encode writes **no source metadata**. A site photograph routinely carries a
///   GPS fix, and a `.zpdfproj` is mailed to people who need the picture, not the
///   photographer's position. The capture time is read out first and kept in the
///   manifest, where it is visible instead of buried.
enum PhotoImagePipeline {

    /// What processing produced: the exact bytes the store will keep, and what they show.
    struct ProcessedPhoto: Sendable {
        /// The stored form. Digesting these bytes names the blob.
        let jpegData: Data
        /// Pixel width of ``jpegData``.
        let pixelWidth: Int
        /// Pixel height of ``jpegData``.
        let pixelHeight: Int
        /// EXIF `DateTimeOriginal` of the source, read as UTC, when it carries one.
        let capturedAt: Date?
    }

    /// Normalises source bytes into the stored form, refusing hostile or over-budget input.
    ///
    /// Deterministic by construction: fixed decode path, fixed edge, fixed quality, no
    /// clock, no randomness — the same source bytes produce the same stored bytes, which
    /// is what lets the digest deduplicate a photograph attached twice.
    ///
    /// - Throws: ``PhotoImportRefusal`` and nothing else.
    static func process(_ sourceData: Data, budget: PhotoBudget) throws -> ProcessedPhoto {
        guard !sourceData.isEmpty else { throw PhotoImportRefusal.unreadableImage }
        guard sourceData.count <= budget.sourceBytes else {
            throw PhotoImportRefusal.sourceTooLarge(bytes: sourceData.count, limit: budget.sourceBytes)
        }

        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw PhotoImportRefusal.unreadableImage }

        // Declared size from metadata, bounded before any decode.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let declaredWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let declaredHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              declaredWidth > 0, declaredHeight > 0
        else { throw PhotoImportRefusal.unreadableImage }
        let declaredPixels = declaredWidth.multipliedReportingOverflow(by: declaredHeight)
        guard !declaredPixels.overflow, declaredPixels.partialValue <= budget.sourcePixels else {
            throw PhotoImportRefusal.sourcePixelsTooLarge(
                pixels: declaredPixels.overflow ? Int.max : declaredPixels.partialValue,
                limit: budget.sourcePixels
            )
        }

        // A format ImageIO decodes in full is bounded tighter: the subsampled decode that
        // keeps a huge JPEG safe does not exist for it (BH-438).
        let type = CGImageSourceGetType(source) as String?
        if !subsamplingTypes.contains(type ?? ""),
           declaredPixels.partialValue > budget.fullDecodeSourcePixels {
            throw PhotoImportRefusal.sourcePixelsTooLarge(
                pixels: declaredPixels.partialValue,
                limit: budget.fullDecodeSourcePixels
            )
        }

        let capturedAt = captureDate(from: properties)

        // Decode straight to the stored resolution. ImageIO downsamples during decode and
        // never upscales: a photograph already inside the limit keeps its own size.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: budget.longestEdgePixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { throw PhotoImportRefusal.unreadableImage }

        // Re-encode as JPEG at the stated quality, carrying no properties: the source's
        // EXIF (GPS included) stops here.
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw PhotoImportRefusal.encodingFailed }
        let encodeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: budget.compressionQuality
        ]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length > 0 else {
            throw PhotoImportRefusal.encodingFailed
        }

        return ProcessedPhoto(
            jpegData: encoded as Data,
            pixelWidth: image.width,
            pixelHeight: image.height,
            capturedAt: capturedAt
        )
    }

    /// The formats ImageIO downsamples during decode.
    static let subsamplingTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier
    ]

    // MARK: - EXIF capture time

    /// EXIF timestamps are `yyyy:MM:dd HH:mm:ss`, naive local time with no zone recorded.
    /// Parsed as UTC — an arbitrary but deterministic reading, stated on
    /// ``PhotoAttachment/capturedAt``.
    private static func captureDate(from properties: [CFString: Any]) -> Date? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return parseEXIFDate(text)
    }

    /// Parses one EXIF timestamp by hand: six integer fields in fixed positions. A
    /// `DateFormatter` would do the same job with a locale and a mood; this cannot vary.
    static func parseEXIFDate(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = parts[3]
        components.minute = parts[4]
        components.second = parts[5]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }
}
