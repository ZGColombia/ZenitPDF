import CoreGraphics
import Foundation

/// An image drawn on the page.
///
/// Raster content is **not** geometry and never becomes a snap primitive: a scanned
/// page reports Vector Snap as unavailable rather than inventing lines. The region is still recorded, because a mixed page needs to know
/// where the scanned block is so the UI can explain why snap goes quiet there.
public struct VectorRasterRegion: Sendable, Hashable, Codable, Identifiable {
    public let id: UInt64
    /// The image's unit square mapped through the CTM: an image under a rotating CTM is
    /// a parallelogram, not a rectangle.
    public let placement: VectorQuad
    public let bounds: VectorBounds
    public let nestingDepth: Int
    public let sourceObjectID: UInt64
    /// `true` for `BI … ID … EI`, `false` for an image XObject drawn with `Do`.
    public let isInline: Bool
    /// The resource name of the XObject, when it had one.
    public let resourceName: String?

    public init(
        id: UInt64,
        placement: VectorQuad,
        bounds: VectorBounds,
        nestingDepth: Int,
        sourceObjectID: UInt64,
        isInline: Bool,
        resourceName: String?
    ) {
        self.id = id
        self.placement = placement
        self.bounds = bounds
        self.nestingDepth = nestingDepth
        self.sourceObjectID = sourceObjectID
        self.isInline = isInline
        self.resourceName = resourceName
    }
}
