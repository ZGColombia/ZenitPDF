import CoreGraphics
import Foundation

/// Which page-space convention the emitted coordinates are in.
///
/// `QUALITY_BAR` S10 requires the convention actually used to be recorded, so that a
/// test can assert the inverse. Both conventions are exact for the four legal `/Rotate`
/// values: every matrix entry is `0`, `±1` or a box coordinate, so `view → page → view`
/// round-trips bit for bit.
public enum VectorPageSpaceConvention: UInt8, Sendable, Hashable, Codable, CaseIterable {
    /// Unrotated PDF user space, measured from the **media box** origin. This is the
    /// canonical page space read literally — origin lower-left, rotation explicit — and
    /// it is the space `QUALITY_BAR` S10 asserts in.
    ///
    /// It is the default because it is the only space in which a coordinate can be
    /// compared with the numbers printed in the PDF itself.
    case pdfUserSpace = 0
    /// Crop-box-relative space with `/Rotate` applied: origin at the lower-left corner
    /// of the *displayed* page, axes as the reader shows them. This is the space a view
    /// layer wants. `pageTransform` maps user space into it and `inverseTransform`
    /// back out.
    case cropBoxRotated = 1
}

/// The single transform applied once, at the top of the composed CTM chain.
public struct VectorPageTransform: Sendable, Hashable, Codable {
    public let convention: VectorPageSpaceConvention
    public let mediaBox: VectorBounds
    public let cropBox: VectorBounds
    /// `/Rotate`, normalised to 0, 90, 180 or 270.
    public let rotation: Int
    /// Maps unrotated PDF user space to the convention's page space.
    public let matrix: CGAffineTransform
    /// The exact inverse of ``matrix``.
    public let inverseMatrix: CGAffineTransform
    /// The size of the page in the convention's space.
    public let canonicalWidth: Double
    public let canonicalHeight: Double

    public init(
        convention: VectorPageSpaceConvention,
        mediaBox: VectorBounds,
        cropBox: VectorBounds,
        rotation: Int
    ) {
        let normalisedRotation = VectorPageTransform.normalise(rotation)
        self.convention = convention
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        self.rotation = normalisedRotation

        switch convention {
        case .pdfUserSpace:
            self.matrix = .identity
            self.inverseMatrix = .identity
            self.canonicalWidth = mediaBox.width
            self.canonicalHeight = mediaBox.height
        case .cropBoxRotated:
            let w = cropBox.width
            let h = cropBox.height
            // Translate the crop box origin to (0, 0), then rotate the page clockwise by
            // `/Rotate` degrees, which is what a conforming reader displays.
            let translate = CGAffineTransform(translationX: -cropBox.minX, y: -cropBox.minY)
            let rotate: CGAffineTransform
            switch normalisedRotation {
            case 90:
                // (u, v) -> (v, w - u)
                rotate = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
            case 180:
                // (u, v) -> (w - u, h - v)
                rotate = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
            case 270:
                // (u, v) -> (h - v, u)
                rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
            default:
                rotate = .identity
            }
            let composed = translate.concatenating(rotate)
            self.matrix = composed
            self.inverseMatrix = composed.inverted()
            self.canonicalWidth = (normalisedRotation == 90 || normalisedRotation == 270) ? h : w
            self.canonicalHeight = (normalisedRotation == 90 || normalisedRotation == 270) ? w : h
        }
    }

    /// The crop box expressed in the convention's own space.
    public var canonicalCropBox: VectorBounds {
        cropBox.applying(matrix)
    }

    public func apply(to point: CGPoint) -> CGPoint { point.applying(matrix) }
    public func invert(_ point: CGPoint) -> CGPoint { point.applying(inverseMatrix) }

    static func normalise(_ degrees: Int) -> Int {
        var value = degrees % 360
        if value < 0 { value += 360 }
        // A /Rotate that is not a multiple of 90 is invalid; PDF 32000-1 says a reader
        // rounds it to the nearest multiple of 90. Round-half-up, then wrap.
        let snapped = ((value + 45) / 90 * 90) % 360
        return snapped
    }
}
