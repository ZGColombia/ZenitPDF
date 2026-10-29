import CoreGraphics
import Foundation
import ZPDFRenderer

/// The pixels an image placed with Edit ▸ Insert Image is drawn from on the canvas (ADR-0043,
/// L-81).
///
/// The importer compiles a raster into a mosaic of at most
/// ``ZPDFContracts/ArtworkLimits/maximumRasterSampleEdge`` (96) cells on its long edge — the
/// bounded geometry ADR-0011 §2.4 chose for raster *stamps*, which are a few centimetres wide.
/// An inserted photo or sketch is a picture someone will zoom into: a 2 400 × 1 700 px JPEG drawn
/// as 96 × 68 cells read soft and blocky at 413 %. The canvas draws such an image
/// from the bytes the project already stores beside its geometry, decoded once per digest, by the
/// renderer's one decode rule — the rule print and every export decode the same bytes by.
enum InsertedImagePixels {

    /// The longest edge an image is decoded to, in pixels (``RenderImagePixels/maximumDecodedEdge``).
    static let maximumDecodedEdge = RenderImagePixels.maximumDecodedEdge

    /// The image `data` holds, decoded to at most ``maximumDecodedEdge`` on its long edge with its
    /// orientation applied, or `nil` for bytes that are not a single readable image or that
    /// declare more than ``ZPDFContracts/ArtworkLimits/maximumRasterPixels`` — the import's own
    /// bound, checked before anything is decoded.
    static func decode(_ data: Data) -> CGImage? {
        RenderImagePixels.decode(data)
    }
}
