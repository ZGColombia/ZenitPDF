import CoreGraphics
import Foundation

/// A point in canonical PDF page space.
///
/// Page space is 72 points per inch with the origin at the lower-left corner of the
/// page, exactly as PDFKit reports it. Presentation code never stores screen pixels or
/// a zoom factor in a geometry value — conversion happens in the canvas layer.
public struct PDFPointValue: Codable, Hashable, Sendable {

    /// Horizontal position in PDF points, increasing to the right.
    public var x: Double
    /// Vertical position in PDF points, increasing upwards.
    public var y: Double

    /// Creates a page-space point.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The origin of page space, `(0, 0)`.
    public static let zero = PDFPointValue(x: 0, y: 0)

    /// A `CGPoint` with the same components, for handing straight to drawing code.
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    /// Creates a page-space point from a `CGPoint` that is already in page space.
    public init(_ cgPoint: CGPoint) {
        self.init(x: Double(cgPoint.x), y: Double(cgPoint.y))
    }

    /// Straight-line distance to another page-space point, in PDF points.
    public func distance(to other: PDFPointValue) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// A size in canonical PDF page space, in PDF points.
public struct PDFSizeValue: Codable, Hashable, Sendable {

    /// Width in PDF points.
    public var width: Double
    /// Height in PDF points.
    public var height: Double

    /// Creates a page-space size.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// A zero size.
    public static let zero = PDFSizeValue(width: 0, height: 0)
}

/// An axis-aligned rectangle in canonical PDF page space.
///
/// The origin is the lower-left corner. Negative origins are legal in PDF and are
/// preserved verbatim rather than normalised, because crop boxes rely on them.
public struct PDFRectValue: Codable, Hashable, Sendable {

    /// Lower-left corner of the rectangle.
    public var origin: PDFPointValue
    /// Extent of the rectangle.
    public var size: PDFSizeValue

    /// Creates a page-space rectangle from an origin and a size.
    public init(origin: PDFPointValue, size: PDFSizeValue) {
        self.origin = origin
        self.size = size
    }

    /// Creates a page-space rectangle from scalar components.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: PDFPointValue(x: x, y: y), size: PDFSizeValue(width: width, height: height))
    }

    /// An empty rectangle at the page-space origin.
    public static let zero = PDFRectValue(x: 0, y: 0, width: 0, height: 0)

    /// Smallest x value.
    public var minX: Double { origin.x }
    /// Smallest y value.
    public var minY: Double { origin.y }
    /// Largest x value.
    public var maxX: Double { origin.x + size.width }
    /// Largest y value.
    public var maxY: Double { origin.y + size.height }
    /// Geometric centre.
    public var center: PDFPointValue {
        PDFPointValue(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }
    /// Area in square PDF points, before any scale transform is applied.
    public var areaInSquarePoints: Double { size.width * size.height }

    /// A `CGRect` with the same components.
    public var cgRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    /// Whether the rectangle contains a page-space point, edges inclusive.
    public func contains(_ point: PDFPointValue) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

/// The explicit page rotation recorded in the PDF, in degrees clockwise.
///
/// Rotation is always explicit in Zenit; no code path may infer it from the aspect ratio.
public enum PageRotation: Int, Codable, Hashable, Sendable, CaseIterable {

    /// No rotation.
    case degrees0 = 0
    /// Rotated 90° clockwise.
    case degrees90 = 90
    /// Rotated 180°.
    case degrees180 = 180
    /// Rotated 270° clockwise.
    case degrees270 = 270

    /// Whether the rotation swaps the visual width and height of the page.
    public var swapsAxes: Bool { self == .degrees90 || self == .degrees270 }

    /// A localized label such as `"90°"`, for the status bar and the page inspector.
    public var displayName: String {
        switch self {
        case .degrees0: return NSLocalizedString("0°", comment: "Page rotation of zero degrees")
        case .degrees90: return NSLocalizedString("90°", comment: "Page rotation of ninety degrees")
        case .degrees180: return NSLocalizedString("180°", comment: "Page rotation of one hundred eighty degrees")
        case .degrees270: return NSLocalizedString("270°", comment: "Page rotation of two hundred seventy degrees")
        }
    }
}
