import Foundation

/// A point in canonical PDF page space (spec 9.1).
///
/// Units are PDF points: 72 per inch, origin at the **lower left** of the page box, y increasing
/// upwards. This is not a view coordinate and never carries zoom or screen scale.
public struct PDFPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PDFPoint(x: 0, y: 0)

    public var isFinite: Bool { x.isFinite && y.isFinite }

    /// Euclidean distance in PDF points. Unscaled — this is page space, not real-world space.
    public func distance(to other: PDFPoint) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }

    public func translated(dx: Double, dy: Double) -> PDFPoint {
        PDFPoint(x: x + dx, y: y + dy)
    }
}

/// A size in PDF points.
public struct PDFSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = PDFSize(width: 0, height: 0)

    public var isFinite: Bool { width.isFinite && height.isFinite }
    /// True when both extents are strictly positive.
    public var isPositive: Bool { isFinite && width > 0 && height > 0 }
    /// Area in square PDF points.
    public var area: Double { width * height }
}

/// An axis-aligned rectangle in PDF page space, bottom-left origin.
///
/// A `PDFRect` may be stored with negative extents (PDF boxes are written as two corners in any
/// order); ``standardized`` is the canonical form with positive extents.
public struct PDFRect: Codable, Hashable, Sendable {
    public var origin: PDFPoint
    public var size: PDFSize

    public init(origin: PDFPoint, size: PDFSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: PDFPoint(x: x, y: y), size: PDFSize(width: width, height: height))
    }

    /// Builds the rectangle spanned by two opposite corners, in any order.
    public init(corner first: PDFPoint, opposite second: PDFPoint) {
        let minX = Swift.min(first.x, second.x)
        let minY = Swift.min(first.y, second.y)
        self.init(
            x: minX,
            y: minY,
            width: Swift.abs(second.x - first.x),
            height: Swift.abs(second.y - first.y)
        )
    }

    public static let zero = PDFRect(x: 0, y: 0, width: 0, height: 0)

    /// The rectangle with a non-negative width and height.
    public var standardized: PDFRect {
        PDFRect(
            x: size.width < 0 ? origin.x + size.width : origin.x,
            y: size.height < 0 ? origin.y + size.height : origin.y,
            width: Swift.abs(size.width),
            height: Swift.abs(size.height)
        )
    }

    public var minX: Double { standardized.origin.x }
    public var minY: Double { standardized.origin.y }
    public var maxX: Double { let r = standardized; return r.origin.x + r.size.width }
    public var maxY: Double { let r = standardized; return r.origin.y + r.size.height }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public var width: Double { standardized.size.width }
    public var height: Double { standardized.size.height }
    public var center: PDFPoint { PDFPoint(x: midX, y: midY) }
    public var isFinite: Bool { origin.isFinite && size.isFinite }
    /// Area in square PDF points.
    public var area: Double { width * height }

    public func contains(_ point: PDFPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func contains(_ other: PDFRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    public func intersects(_ other: PDFRect) -> Bool {
        !(other.minX > maxX || other.maxX < minX || other.minY > maxY || other.maxY < minY)
    }

    /// The smallest rectangle containing both. Used to build snap index bounds.
    public func union(_ other: PDFRect) -> PDFRect {
        PDFRect(
            corner: PDFPoint(x: Swift.min(minX, other.minX), y: Swift.min(minY, other.minY)),
            opposite: PDFPoint(x: Swift.max(maxX, other.maxX), y: Swift.max(maxY, other.maxY))
        )
    }

    /// The rectangle grown by `amount` on every side. Negative amounts shrink it.
    ///
    /// A shrink deeper than half an extent collapses that axis to zero at the midpoint rather
    /// than turning it inside out. Built from `minX`/`width` directly the arithmetic produces a
    /// negative extent, and because ``standardized`` takes the absolute value, a 10-wide box
    /// shrunk by 8 came back as a *valid* 6-wide box spanning 2...8 — reporting
    /// ``contains(_:)`` true for points that are nowhere near the real (empty) result.
    public func outsetBy(_ amount: Double) -> PDFRect {
        let newWidth = width + 2 * amount
        let newHeight = height + 2 * amount
        if newWidth >= 0 && newHeight >= 0 {
            return PDFRect(x: minX - amount, y: minY - amount, width: newWidth, height: newHeight)
        }
        return PDFRect(
            x: newWidth < 0 ? midX : minX - amount,
            y: newHeight < 0 ? midY : minY - amount,
            width: Swift.max(newWidth, 0),
            height: Swift.max(newHeight, 0)
        )
    }

    /// Deprecated spelling of ``outsetBy(_:)``: a positive amount **grows** the rectangle, the
    /// opposite of `CGRect.insetBy`. Behaviour is unchanged (code review CR-92); the name is
    /// the trap, so new code uses ``outsetBy(_:)`` and passes a negative amount to shrink.
    @available(*, deprecated, renamed: "outsetBy(_:)",
               message: "insetBy(_:) grows the rectangle for a positive amount; use outsetBy(_:)")
    public func insetBy(_ amount: Double) -> PDFRect {
        outsetBy(amount)
    }

    /// The bounding box of a point set, or `nil` for an empty set.
    public static func boundingBox(of points: [PDFPoint]) -> PDFRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = Swift.min(minX, point.x)
            maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y)
            maxY = Swift.max(maxY, point.y)
        }
        return PDFRect(corner: PDFPoint(x: minX, y: minY), opposite: PDFPoint(x: maxX, y: maxY))
    }
}

/// The `/Rotate` value of a PDF page. Only multiples of 90 exist in the format.
public enum PageRotation: Int, Codable, Hashable, Sendable, CaseIterable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    /// Builds a rotation from any integer degree value, normalising negatives and multiples of
    /// 360. Throws for values that are not multiples of 90.
    ///
    /// This is the one normalisation the contract permits (BH-481): a `/Rotate` of `-90` or
    /// `450` is a legal spelling of a quarter turn that real files contain, and every PDF
    /// reader folds it. A value that is not a multiple of 90 has no meaning and is refused.
    public static func normalizing(degrees: Int) throws -> PageRotation {
        guard degrees % 90 == 0 else { throw PageGeometryError.unsupportedRotation(degrees) }
        let wrapped = ((degrees % 360) + 360) % 360
        guard let rotation = PageRotation(rawValue: wrapped) else {
            throw PageGeometryError.unsupportedRotation(degrees)
        }
        return rotation
    }

    /// Number of clockwise quarter turns, 0...3.
    public var quarterTurns: Int { rawValue / 90 }

    /// True for 90 and 270, where the displayed width and height are the page box's height and
    /// width. Every layout calculation must consult this rather than assuming.
    public var swapsAxes: Bool { self == .degrees90 || self == .degrees270 }

    /// The rotation that undoes this one.
    public var inverse: PageRotation {
        switch self {
        case .degrees0: .degrees0
        case .degrees90: .degrees270
        case .degrees180: .degrees180
        case .degrees270: .degrees90
        }
    }
}

/// The two page boxes Zenit cares about (spec 9.1).
///
/// The crop box is the default drawing surface. `media` is kept because export and print need it,
/// and because a crop box outside the media box is a malformed file we must detect rather than
/// silently normalise.
public struct PageBoxes: Codable, Hashable, Sendable {
    /// `/MediaBox`, in PDF points, bottom-left origin.
    public var media: PDFRect
    /// `/CropBox`, in PDF points, bottom-left origin. Defaults to the media box in files that
    /// omit it — the importer is responsible for that substitution, not this type.
    public var crop: PDFRect

    public init(media: PDFRect, crop: PDFRect) {
        self.media = media
        self.crop = crop
    }

    /// Media box with the crop box defaulted to it.
    public init(media: PDFRect) {
        self.init(media: media, crop: media)
    }

    /// Validates the invariants the whole engine relies on.
    ///
    /// - Throws: ``PageGeometryError`` when a box is degenerate, non-finite, or when the crop box
    ///   escapes the media box.
    public func validate() throws {
        guard media.isFinite else { throw PageGeometryError.nonFiniteCoordinate(name: "media") }
        guard crop.isFinite else { throw PageGeometryError.nonFiniteCoordinate(name: "crop") }
        guard media.standardized.size.isPositive else {
            throw PageGeometryError.degenerateBox(name: "media")
        }
        guard crop.standardized.size.isPositive else {
            throw PageGeometryError.degenerateBox(name: "crop")
        }
        guard media.contains(crop) else { throw PageGeometryError.cropBoxOutsideMediaBox }
    }
}

/// Everything the engine needs to know about one page's geometry (spec 9.1, 9.3).
///
/// `PageDescriptor` is deliberately free of any PDFKit or PDFium type: it is the value that the
/// document layer hands to the measurement engine, the snap index and the renderer alike.
public struct PageDescriptor: Codable, Hashable, Sendable {
    /// Stable identifier, assigned once at import and persisted.
    public var id: PageID
    /// Owning document.
    public var documentID: DocumentID
    /// Zero-based index of the page in its own PDF (its `/Pages` order), fixed at import.
    ///
    /// Not the page's place in a set: reordering, and pages of several PDFs in one project,
    /// keep this unchanged, because the canvas rasterises it, text, OCR and vector extraction
    /// read it, and the archive re-binds stored page identity by it. The set order is the
    /// session's page order, persisted as `page_set_entry.position` (ADR-0022).
    public var index: Int
    /// The page label as the PDF declares it (`/PageLabels`), which is frequently *not*
    /// `String(index + 1)`. The ledger shows this, never the raw index, unless asked.
    public var label: String
    /// Media and crop boxes.
    public var boxes: PageBoxes
    /// The page's `/Rotate` entry.
    public var rotation: PageRotation
    /// The PDF `/UserUnit`, a multiplier on the 1/72 inch default. Almost always 1.0; large-format
    /// drawings occasionally carry more. Every point-to-real conversion must honour it.
    public var userUnit: Double

    public init(
        id: PageID,
        documentID: DocumentID,
        index: Int,
        label: String,
        boxes: PageBoxes,
        rotation: PageRotation = .degrees0,
        userUnit: Double = 1.0
    ) {
        self.id = id
        self.documentID = documentID
        self.index = index
        self.label = label
        self.boxes = boxes
        self.rotation = rotation
        self.userUnit = userUnit
    }

    /// The drawing surface: the crop box, standardized.
    public var visibleBox: PDFRect { boxes.crop.standardized }

    /// The visible size after `/Rotate` is applied.
    public var rotatedVisibleSize: PDFSize {
        let box = visibleBox
        return rotation.swapsAxes
            ? PDFSize(width: box.size.height, height: box.size.width)
            : box.size
    }

    public func validate() throws {
        try boxes.validate()
        guard userUnit.isFinite, userUnit > 0 else {
            throw PageGeometryError.invalidUserUnit(userUnit)
        }
    }
}
