import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFRenderer

/// One Zenit markup as **one standard PDF annotation** (NL-PDF-01).
///
/// # Why one value per markup, not one per drawn fragment
///
/// The renderer draws a markup as several fragments: an area is a filled polygon and a value
/// pill, a stamp is however many contours its artwork compiled to, a count group is forty
/// symbols. The first annotated export mapped those fragments one to one, so an area became two
/// annotations with nothing tying them together, a raster stamp became thousands of polygons,
/// and a count became a box. A reviewer's comment list in another reader showed N identical rows.
///
/// This value carries both halves of the markup instead:
///
/// - **what it is** — the standard subtype and its geometry keys (``Geometry``), identity
///   (`/NM`), author, subject, dates, review state and the style a reader regenerates from; and
/// - **what it looks like** — ``appearance``, the fragments the canvas draws, which the writer
///   paints once into the annotation's own `/AP /N` form with the same `MarkupFlattener` the
///   flatten and print paths use. Any reader that honours appearance streams shows exactly the
///   canvas; one that regenerates from the keys still has correct geometry, colour and opacity.
public struct StandardAnnotation: Sendable, Hashable {

    /// The standard subtype, with the geometry its keys need. Every coordinate is **page space**,
    /// the space `RenderableMarkup` is in and the space `/Rect`, `/Vertices` and `/L` are defined in.
    public enum Geometry: Sendable, Hashable {
        /// `/Polygon` with `/Vertices`. Areas, polygons and clouds.
        case polygon([PDFPoint])
        /// `/PolyLine` with `/Vertices`. Lengths and open multi-segment lines.
        case polyLine([PDFPoint])
        /// `/Line` with `/L`. Two-point lines and arrows.
        case line(start: PDFPoint, end: PDFPoint)
        /// `/Ink` with `/InkList`. Freehand strokes, and any shape no other subtype holds.
        case ink([[PDFPoint]])
        /// `/Square` — a rectangle.
        case square(PDFRect)
        /// `/Circle` — an ellipse inscribed in the rectangle.
        case circle(PDFRect)
        /// `/FreeText`. With a non-empty `callout`, a callout (`/IT /FreeTextCallout`, `/CL`).
        case freeText(PDFRect, callout: [PDFPoint])
        /// `/Text` — a note icon at a point.
        case note(PDFPoint)
        /// `/Stamp`. Stamps and count groups: the appearance is the whole of it.
        case stamp
        /// `/Link` with a URI action.
        case link(PDFRect, uri: String)
        /// `/Link` to a page of the same file (`/Dest [page /Fit]`), by its zero-based index in
        /// the file written — a sheet link of the project, re-pointed at the exported set.
        case pageLink(PDFRect, pageIndex: Int)
        /// `/Highlight`, `/Underline` or `/StrikeOut` over one or more rectangles (`/QuadPoints`).
        case textMarkup(TextMarkup, [PDFRect])

        /// The PDF `/Subtype` name.
        public var subtype: String {
            switch self {
            case .polygon: "Polygon"
            case .polyLine: "PolyLine"
            case .line: "Line"
            case .ink: "Ink"
            case .square: "Square"
            case .circle: "Circle"
            case .freeText: "FreeText"
            case .note: "Text"
            case .stamp: "Stamp"
            case .link, .pageLink: "Link"
            case let .textMarkup(kind, _): kind.rawValue
            }
        }
    }

    /// The three text-markup subtypes Zenit has tools for.
    public enum TextMarkup: String, Sendable, Hashable, CaseIterable {
        case highlight = "Highlight"
        case underline = "Underline"
        case strikeOut = "StrikeOut"
    }

    /// `/LE` line-ending names (ISO 32000-1 Table 176).
    public enum LineEnding: String, Sendable, Hashable, CaseIterable {
        case none = "None"
        case openArrow = "OpenArrow"
        case closedArrow = "ClosedArrow"
        case circle = "Circle"
        case square = "Square"
        case diamond = "Diamond"
        case slash = "Slash"
        case butt = "Butt"
    }

    /// The standard review state model's four terminal states (ISO 32000-1 §12.5.6.3).
    public enum ReviewState: String, Sendable, Hashable, CaseIterable {
        case accepted = "Accepted"
        case rejected = "Rejected"
        case cancelled = "Cancelled"
        case completed = "Completed"
    }

    /// `/IT` intents that say what a markup measures or how it is drawn.
    public enum Intent: String, Sendable, Hashable, CaseIterable {
        case polygonDimension = "PolygonDimension"
        case polyLineDimension = "PolyLineDimension"
        case lineDimension = "LineDimension"
        case lineArrow = "LineArrow"
        case polygonCloud = "PolygonCloud"
        case freeTextCallout = "FreeTextCallout"
    }

    /// The markup's identity. Written as `/NM`, so a second export supersedes the first and a
    /// round trip back into Zenit knows its own marks.
    public var id: UUID
    public var geometry: Geometry
    /// `/Contents`: label, formatted quantity and comment, one per line.
    public var contents: String?
    /// `/Subj`: the markup's subject, or its kind when it has none.
    public var subject: String?
    /// `/T`: the author recorded on the markup.
    public var author: String?
    public var creationDate: Date?
    public var modificationDate: Date?
    /// `/C`: the stroke colour. Alpha is carried by the appearance and by `/CA`.
    public var stroke: RGBAColor?
    /// `/IC`: the interior colour of closed shapes. Its alpha is written as the PDF 2.0 `/ca`
    /// (non-stroking opacity used when a reader regenerates the appearance) and kept in `/AP`.
    public var fill: RGBAColor?
    /// The markup's own opacity, 0...1. Written as `/CA`.
    public var opacity: Double
    /// `/BS /W`.
    public var lineWidth: Double
    /// `/BS /D`. Empty is a solid border.
    public var dash: [Double]
    public var startEnding: LineEnding
    public var endEnding: LineEnding
    /// `/BE << /S /C >>`: a cloudy border.
    public var cloudy: Bool
    public var intent: Intent?
    /// Written as a hidden `/Text` reply carrying `/StateModel (Review)` and `/State`.
    public var reviewState: ReviewState?
    /// `/F 4` when true.
    public var printable: Bool
    /// `/DA` font size for free text.
    public var fontSize: Double
    /// What the canvas draws for this markup, in painter order, page space. Painted once into
    /// `/AP /N`. Empty means no appearance stream is written.
    public var appearance: [RenderableMarkup]
    /// The markup's review thread (NL-COLLAB-07): each written as a hidden `/Text` reply with
    /// `/IRT` to this annotation and `/RT /R`, in the order given.
    public var replies: [Reply] = []
    /// The scale the markup was measured at, written as the annotation's `/Measure` so another
    /// reader's measuring tools read the same value (NL-PDF-02). `nil` for an unmeasured markup.
    public var measure: MeasureScale?

    /// One comment in a markup's review thread.
    public struct Reply: Sendable, Hashable {
        public var id: UUID
        public var author: String
        public var body: String
        public var createdAt: Date
        public var modifiedAt: Date?

        public init(id: UUID, author: String, body: String, createdAt: Date, modifiedAt: Date? = nil) {
            self.id = id
            self.author = author
            self.body = body
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
        }
    }

    public init(
        id: UUID,
        geometry: Geometry,
        contents: String? = nil,
        subject: String? = nil,
        author: String? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        stroke: RGBAColor? = nil,
        fill: RGBAColor? = nil,
        opacity: Double = 1,
        lineWidth: Double = 1,
        dash: [Double] = [],
        startEnding: LineEnding = .none,
        endEnding: LineEnding = .none,
        cloudy: Bool = false,
        intent: Intent? = nil,
        reviewState: ReviewState? = nil,
        printable: Bool = true,
        fontSize: Double = 12,
        appearance: [RenderableMarkup] = []
    ) {
        self.id = id
        self.geometry = geometry
        self.contents = contents
        self.subject = subject
        self.author = author
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.stroke = stroke
        self.fill = fill
        self.opacity = opacity
        self.lineWidth = lineWidth
        self.dash = dash
        self.startEnding = startEnding
        self.endEnding = endEnding
        self.cloudy = cloudy
        self.intent = intent
        self.reviewState = reviewState
        self.printable = printable
        self.fontSize = fontSize
        self.appearance = appearance
    }

    /// The `/NM` text: the markup's UUID, upper-case, exactly as `UUID.uuidString` spells it.
    public var name: String { id.uuidString }
}

/// One sheet's worth of annotations.
public struct StandardAnnotationPage: Sendable {
    /// The page's geometry, as measured — the writer refuses a file whose sheet differs.
    public var page: PageDescriptor
    /// Zero-based index of the page in the source document.
    public var sourcePageIndex: Int
    public var annotations: [StandardAnnotation]
    /// The page's `/VP` viewports (NL-PDF-02). Merged with the drawing's own: every entry of the
    /// page's existing `/VP` that Zenit did not write is kept, and Zenit's from an earlier export
    /// are replaced (V-052). Empty writes none of Zenit's.
    public var viewports: [MeasureViewport]
    /// The drawing's own annotations that became Zenit markups ("Make Drawing Annotations
    /// Editable", NL-UX-04). The markup is written as its own annotation, so the original is left
    /// out of the page's `/Annots` rather than appearing twice. Matched by `/NM`, or by subtype and
    /// rectangle when the original has no name.
    public var adoptedOriginals: [AdoptedOriginal] = []

    public init(
        page: PageDescriptor,
        sourcePageIndex: Int,
        annotations: [StandardAnnotation],
        viewports: [MeasureViewport] = []
    ) {
        self.page = page
        self.sourcePageIndex = sourcePageIndex
        self.annotations = annotations
        self.viewports = viewports
    }
}

/// A drawing scale as a PDF measurement dictionary (ISO 32000-1 §12.9): a ratio a person reads,
/// and the metres one page unit stands for.
public struct MeasureScale: Sendable, Hashable {
    /// `/R`, e.g. `1:100`.
    public var ratioLabel: String
    /// Metres per default user space unit. Uniform scales only; a separate X/Y calibration has
    /// no single ratio and is not written.
    public var metresPerPoint: Double
    /// Decimal places the number formats carry.
    public var decimalPlaces: Int

    public init(ratioLabel: String, metresPerPoint: Double, decimalPlaces: Int = 3) {
        self.ratioLabel = ratioLabel
        self.metresPerPoint = metresPerPoint
        self.decimalPlaces = decimalPlaces
    }
}

/// One `/VP` viewport of a page: the region a scale applies to (the whole sheet, or a Scale
/// Region), in page space.
public struct MeasureViewport: Sendable, Hashable {
    /// What a viewport covers, which decides its place among the drawing's own (V-052).
    public enum Coverage: Sendable, Hashable {
        /// The sheet's own scale over the whole sheet: written before the drawing's own
        /// viewports, so a detail viewport of the drawing still governs inside itself.
        case sheet
        /// A Scale Region over its boundary: written after them, so it governs inside itself.
        case region
    }

    public var bounds: PDFRect
    public var name: String
    public var measure: MeasureScale
    public var coverage: Coverage

    public init(bounds: PDFRect, name: String, measure: MeasureScale, coverage: Coverage = .region) {
        self.bounds = bounds
        self.name = name
        self.measure = measure
        self.coverage = coverage
    }
}

/// One of the drawing's own annotations that a Zenit markup replaced.
public struct AdoptedOriginal: Sendable, Hashable {
    public var name: String?
    public var subtype: String?
    public var rect: CGRect

    public init(name: String?, subtype: String?, rect: CGRect) {
        self.name = name
        self.subtype = subtype
        self.rect = rect
    }

    /// Whether an annotation dictionary on the page is this original.
    func matches(name other: String?, subtype otherSubtype: String?, rect otherRect: CGRect?) -> Bool {
        if let name, !name.isEmpty { return other == name }
        guard let otherRect, subtype == nil || subtype == otherSubtype else { return false }
        let a = rect.standardized, b = otherRect.standardized
        return abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.maxX - b.maxX) < 0.5 && abs(a.maxY - b.maxY) < 0.5
    }
}
