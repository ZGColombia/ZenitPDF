import Foundation

// MARK: - Derivation

/// Where an expected value in a manifest came from.
///
/// QUALITY_BAR section 2.6: an expected value may never be produced by the code under
/// test, and `code_under_test` is not a member of this enumeration by construction.
public enum FixtureDerivationMethod: String, Sendable, Codable, Hashable, CaseIterable {
    case closedForm = "closed_form"
    case handComputation = "hand_computation"
    case externalTool = "external_tool"
    case exactExpansionOracle = "exact_expansion_oracle"
    case physicalReference = "physical_reference"
}

/// The provenance block required by QUALITY_BAR section 2.6.
public struct FixtureDerivation: Sendable, Codable, Hashable {
    public var method: FixtureDerivationMethod
    /// The formula written out with its substituted inputs, the worked steps, or the
    /// tool name plus version plus raw output.
    public var detail: String
    public var derivedBy: String
    /// ISO-8601 calendar date. A constant string, never `Date()`.
    public var derivedOn: String
    public var reviewedBy: String?
    /// κ for area records, so that the M-A3 bound can be evaluated.
    public var conditionNumber: Double?
    /// The floor used by `rel(a, b) = |a − b| / max(|b|, floor)`.
    public var magnitudeFloor: Double

    public init(
        method: FixtureDerivationMethod,
        detail: String,
        derivedBy: String = "ZPDFTestingSupport",
        derivedOn: String = "2026-08-23",
        reviewedBy: String? = nil,
        conditionNumber: Double? = nil,
        magnitudeFloor: Double = 1.0
    ) {
        self.method = method
        self.detail = detail
        self.derivedBy = derivedBy
        self.derivedOn = derivedOn
        self.reviewedBy = reviewedBy
        self.conditionNumber = conditionNumber
        self.magnitudeFloor = magnitudeFloor
    }
}

// MARK: - Path record

/// What kind of geometry a `FixturePath` describes.
public enum FixturePathKind: String, Sendable, Codable, Hashable {
    /// An open polyline. `area` is `0` and carries no meaning.
    case openPolyline
    /// A closed simple polygon, given counter-clockwise.
    case closedPolygon
    /// A closed polygon with one or more holes, outer ring counter-clockwise and
    /// every hole clockwise.
    case polygonWithHoles
    /// A closed loop built from cubic Bézier segments. `points` holds the on-curve
    /// endpoints only; `cubics` holds the exact control points.
    case cubicBezierLoop
}

/// One drawn path, described in exact numbers.
///
/// `points` are already in **page space** — every form XObject `/Matrix` and every
/// `cm` in force has been composed into them — so a consumer never has to reproduce
/// the transform stack to know where the geometry landed. `sourcePoints` and
/// `transform` record the untransformed form-space geometry when the path was drawn
/// inside a form XObject, so that an extractor's transform handling can be checked
/// independently.
public struct FixturePath: Sendable, Codable, Hashable {
    public var id: String
    public var pageIndex: Int
    public var kind: FixturePathKind
    /// Page-space vertices of the outer ring, in drawing order. For a closed ring the
    /// first vertex is **not** repeated at the end.
    public var points: [FixturePoint]
    /// Page-space vertices of each hole, clockwise.
    public var holes: [[FixturePoint]]
    /// Exact cubic control points in page space, for `.cubicBezierLoop`.
    public var cubics: [FixtureCubic]
    /// Total length: polyline length for an open path, perimeter (outer ring plus
    /// every hole) for a closed one.
    public var length: Double
    /// Enclosed area, net of holes. `0` for an open path.
    public var area: Double
    /// Untransformed geometry, when the path lives inside a form XObject.
    public var sourcePoints: [FixturePoint]?
    /// The composed matrix mapping `sourcePoints` to `points`.
    public var transform: FixtureMatrix?
    /// `true` when the path is decoration that snap and measurement must ignore —
    /// the full-page background rectangle, for instance.
    public var isBackground: Bool
    /// The portion of `length` that survives the page's clipping path, when the
    /// fixture has one.
    public var clippedVisibleLength: Double?
    /// The portion of `area` that survives the page's clipping path.
    public var clippedVisibleArea: Double?
    /// How `length` and `area` were derived.
    public var derivation: FixtureDerivation
    /// Free-form notes: the approximation error of a Bézier circle, for instance.
    public var notes: [String]

    public init(
        id: String,
        pageIndex: Int,
        kind: FixturePathKind,
        points: [FixturePoint],
        holes: [[FixturePoint]] = [],
        cubics: [FixtureCubic] = [],
        length: Double,
        area: Double,
        sourcePoints: [FixturePoint]? = nil,
        transform: FixtureMatrix? = nil,
        isBackground: Bool = false,
        clippedVisibleLength: Double? = nil,
        clippedVisibleArea: Double? = nil,
        derivation: FixtureDerivation,
        notes: [String] = []
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.kind = kind
        self.points = points
        self.holes = holes
        self.cubics = cubics
        self.length = length
        self.area = area
        self.sourcePoints = sourcePoints
        self.transform = transform
        self.isBackground = isBackground
        self.clippedVisibleLength = clippedVisibleLength
        self.clippedVisibleArea = clippedVisibleArea
        self.derivation = derivation
        self.notes = notes
    }
}

// MARK: - Text record

/// A searchable string placed at a known baseline origin.
public struct FixtureText: Sendable, Codable, Hashable {
    public var id: String
    public var pageIndex: Int
    /// The exact string written into the content stream, in WinAnsi.
    public var string: String
    /// Baseline origin in page space.
    public var origin: FixturePoint
    public var fontSize: Double
    /// The base-14 font name, e.g. `Helvetica`.
    public var fontName: String
    /// `true` when the string is part of the title block rather than drawing content.
    public var isTitleBlock: Bool

    public init(
        id: String,
        pageIndex: Int,
        string: String,
        origin: FixturePoint,
        fontSize: Double,
        fontName: String,
        isTitleBlock: Bool = false
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.string = string
        self.origin = origin
        self.fontSize = fontSize
        self.fontName = fontName
        self.isTitleBlock = isTitleBlock
    }
}

// MARK: - Raster record

/// A rasterised image placed on a page — used by the "scanned drawing" fixtures that
/// drive the OCR and "Vector Snap unavailable" paths.
public struct FixtureRaster: Sendable, Codable, Hashable {
    public var id: String
    public var pageIndex: Int
    /// Where the image is placed in page space.
    public var placement: FixtureRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var bitsPerComponent: Int
    /// `DeviceGray` or `DeviceRGB`.
    public var colorSpace: String

    public init(
        id: String,
        pageIndex: Int,
        placement: FixtureRect,
        pixelWidth: Int,
        pixelHeight: Int,
        bitsPerComponent: Int,
        colorSpace: String
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.placement = placement
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bitsPerComponent = bitsPerComponent
        self.colorSpace = colorSpace
    }
}

// MARK: - Page record

/// Everything a consumer needs to know about one page's geometry.
public struct FixturePage: Sendable, Codable, Hashable {
    public var index: Int
    public var mediaBox: FixtureRect
    /// The declared crop box. When the page declares none, this equals `mediaBox`,
    /// which is what a conforming reader must default to.
    public var cropBox: FixtureRect
    /// `true` when the page dictionary actually carries a `/CropBox` entry.
    public var declaresCropBox: Bool
    /// `/Rotate`, normalised to one of 0, 90, 180, 270.
    public var rotation: Int
    /// The page's clipping path in page space, when it has one.
    public var clipPath: FixtureRect?
    /// `true` when the page carries extractable text.
    public var hasTextLayer: Bool
    /// `true` when the page carries a rasterised image.
    public var hasRasterContent: Bool

    public init(
        index: Int,
        mediaBox: FixtureRect,
        cropBox: FixtureRect? = nil,
        rotation: Int = 0,
        clipPath: FixtureRect? = nil,
        hasTextLayer: Bool = false,
        hasRasterContent: Bool = false
    ) {
        self.index = index
        self.mediaBox = mediaBox
        self.cropBox = cropBox ?? mediaBox
        self.declaresCropBox = cropBox != nil
        self.rotation = rotation
        self.clipPath = clipPath
        self.hasTextLayer = hasTextLayer
        self.hasRasterContent = hasRasterContent
    }
}

// MARK: - Hostile traits

/// How a hostile fixture is malformed or dangerous. A reader is expected to fail
/// safely — a typed error, never a hang, an unbounded allocation or a crash.
public enum FixtureHostileTrait: String, Sendable, Codable, Hashable, CaseIterable {
    case truncated
    case brokenCrossReferenceTable
    case cyclicPageTree
    case missingObject
    case deeplyNestedForms
    case decompressionBomb
    case encrypted
    case embeddedFile
    case launchAction
    case javaScript
    case malformedOperatorStream
    case brokenLayerReference
}

// MARK: - Manifest

/// The closed-form truth for one fixture.
///
/// Every number in here was derived from a formula, a hand computation or an external
/// tool, and never by running the code the fixture exists to test. A test asserts
/// against these numbers; it does not recompute them from the PDF.
public struct FixtureManifest: Sendable, Codable, Hashable {
    public var kind: FixtureKind
    /// Human-readable name, used in FIXTURES.md and in failure messages.
    public var title: String
    /// What the fixture is for.
    public var purpose: String
    /// The file name `ZPDFFixtures.make(_:in:)` writes.
    public var fileName: String
    public var pageCount: Int
    /// One record per page. For the 300- and 1 000-page fixtures this holds one
    /// record per page as well; the pages are uniform and the array stays small
    /// enough to keep in memory.
    public var pages: [FixturePage]
    public var paths: [FixturePath]
    public var texts: [FixtureText]
    public var rasters: [FixtureRaster]
    /// Form XObject nesting depth exercised by the fixture, when it has forms.
    public var formNestingDepth: Int?
    public var hostileTraits: [FixtureHostileTrait]
    /// For `.decompressionBomb`: how many bytes the content stream inflates to.
    public var declaredInflatedByteCount: Int?
    /// The user password for `.encryptedUserPassword`.
    public var userPassword: String?
    /// `true` when the file is deliberately not a conforming PDF, so a test must not
    /// require it to open.
    public var isStructurallyValid: Bool
    public var notes: [String]
    /// Sheet-set structure (labels, bookmarks, links, title-block regions), for the fixtures
    /// that model a drawing set; `nil` for every other fixture.
    public var sheetSet: FixtureSheetSet?
    /// For the synthetic drawing sheets: how many primitives a vector extractor that emits one
    /// primitive per subpath segment, plus one per closed subpath, reports for page 0 with
    /// hidden optional content included. Counted by hand from the drawing's construction, never
    /// by running an extractor; `nil` for every other fixture.
    public var vectorPrimitiveCount: Int?

    public init(
        kind: FixtureKind,
        title: String,
        purpose: String,
        fileName: String,
        pageCount: Int,
        pages: [FixturePage],
        paths: [FixturePath] = [],
        texts: [FixtureText] = [],
        rasters: [FixtureRaster] = [],
        formNestingDepth: Int? = nil,
        hostileTraits: [FixtureHostileTrait] = [],
        declaredInflatedByteCount: Int? = nil,
        userPassword: String? = nil,
        isStructurallyValid: Bool = true,
        notes: [String] = [],
        sheetSet: FixtureSheetSet? = nil,
        vectorPrimitiveCount: Int? = nil
    ) {
        self.kind = kind
        self.title = title
        self.purpose = purpose
        self.fileName = fileName
        self.pageCount = pageCount
        self.pages = pages
        self.paths = paths
        self.texts = texts
        self.rasters = rasters
        self.formNestingDepth = formNestingDepth
        self.hostileTraits = hostileTraits
        self.declaredInflatedByteCount = declaredInflatedByteCount
        self.userPassword = userPassword
        self.isStructurallyValid = isStructurallyValid
        self.notes = notes
        self.sheetSet = sheetSet
        self.vectorPrimitiveCount = vectorPrimitiveCount
    }

    /// The paths on `pageIndex`, in drawing order.
    public func paths(onPage pageIndex: Int) -> [FixturePath] {
        paths.filter { $0.pageIndex == pageIndex }
    }

    /// The single path with `id`, or `nil`.
    public func path(id: String) -> FixturePath? {
        paths.first { $0.id == id }
    }
}
