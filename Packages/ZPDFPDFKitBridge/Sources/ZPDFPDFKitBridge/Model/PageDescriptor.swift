import CoreGraphics
import Foundation

/// The five page boundary boxes of the PDF specification.
///
/// Zenit PDF measures in the coordinate system of the *crop* box, because that is what
/// the estimator sees on screen, but the media box is what a page operation preserves.
public enum PDFPageBox: String, Sendable, Hashable, Codable, CaseIterable {
    case media
    case crop
    case bleed
    case trim
    case art
}

/// Every box of one page, in PDF points, bottom-left origin.
public struct PageBoxes: Sendable, Hashable, Codable {
    public let media: CGRect
    public let crop: CGRect
    public let bleed: CGRect
    public let trim: CGRect
    public let art: CGRect

    public init(media: CGRect, crop: CGRect, bleed: CGRect, trim: CGRect, art: CGRect) {
        self.media = media
        self.crop = crop
        self.bleed = bleed
        self.trim = trim
        self.art = art
    }

    public subscript(box: PDFPageBox) -> CGRect {
        switch box {
        case .media: return media
        case .crop: return crop
        case .bleed: return bleed
        case .trim: return trim
        case .art: return art
        }
    }
}

/// One page, described without loading its content.
///
/// `index` is the zero-based position in the page tree. `label` is the string the
/// document says the page is called — `A-102`, `iv`, `C.3` — and the two are different
/// things. A construction set numbered `A-101 … A-140` has index 0 for label `A-101`,
/// and every user-facing surface in Zenit PDF shows the label. Nothing in this package
/// ever formats an index as if it were a label.
public struct PDFPageDescriptor: Sendable, Hashable, Codable {
    public let index: Int
    public let label: String
    /// `true` when `label` came from a `/PageLabels` tree rather than from the fallback
    /// "index + 1" rule.
    public let labelIsExplicit: Bool
    public let boxes: PageBoxes
    /// `/Rotate`, normalised into `{0, 90, 180, 270}`.
    public let rotation: Int

    public init(
        index: Int,
        label: String,
        labelIsExplicit: Bool,
        boxes: PageBoxes,
        rotation: Int
    ) {
        self.index = index
        self.label = label
        self.labelIsExplicit = labelIsExplicit
        self.boxes = boxes
        self.rotation = rotation
    }

    /// The crop-box size after `/Rotate` is applied, which is the size the page appears
    /// to have on screen.
    public var displaySize: CGSize {
        let size = boxes.crop.size
        return (rotation == 90 || rotation == 270)
            ? CGSize(width: size.height, height: size.width)
            : size
    }
}
