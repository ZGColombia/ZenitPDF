import CoreGraphics
import Foundation
import ImageIO
import ZPDFContracts

/// The one rule for turning an inserted picture's stored bytes into the pixels it is drawn from
/// (ADR-0043, L-81) — on the canvas, on paper and in every file export.
///
/// The importer compiles a raster into a mosaic of at most
/// ``ZPDFContracts/ArtworkLimits/maximumRasterSampleEdge`` (96) cells on its long edge: the bounded
/// geometry ADR-0011 §2.4 chose for raster *stamps*. An inserted photo or sketch is a picture
/// someone zooms into and prints; drawn as its mosaic, a 2 400 × 1 700 px JPEG became 96 × 68
/// blocks (live test 8). It is drawn from the bytes the project stores beside the mosaic instead,
/// decoded here, within the import's own bounds.
public enum RenderImagePixels {

    /// The longest edge a picture is decoded to, in pixels. A 4 096-px edge is sharp at well past
    /// 400 % on any sheet a placed picture covers and prints at 300 dpi across 34 cm; it bounds the
    /// decoded bitmap at 64 MB.
    public static let maximumDecodedEdge = 4_096

    /// The picture `data` holds, decoded to at most ``maximumDecodedEdge`` on its long edge with
    /// its orientation applied, or `nil` for bytes that are not a readable image or that declare
    /// more than ``ZPDFContracts/ArtworkLimits/maximumRasterPixels`` — the import's own bound,
    /// checked from the header before a single pixel is decoded.
    public static func decode(_ data: Data) -> CGImage? {
        guard let size = declaredPixelSize(data) else { return nil }
        let pixels = size.width.multipliedReportingOverflow(by: size.height)
        guard !pixels.overflow, pixels.partialValue <= ArtworkLimits.maximumRasterPixels,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximumDecodedEdge, max(size.width, size.height)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The pixel size the first image in `data` declares in its header, or `nil` when the bytes
    /// are not an image ImageIO can read. Nothing is decoded.
    public static func declaredPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }
}
