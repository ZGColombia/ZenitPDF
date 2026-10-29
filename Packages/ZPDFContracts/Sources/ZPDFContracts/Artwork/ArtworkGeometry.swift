import Foundation

/// The bounds imported artwork is allowed to produce, and the single place they are written.
///
/// Imported artwork is **data from outside the product** — a PDF page or an image the person
/// chose, possibly written by something hostile, more often written by something merely
/// careless. ADR-0011 §2.5: every one of these numbers exists so that a refusal is a sentence
/// with a limit in it rather than a spinner that never stops, and so that the cost of a stamp
/// is known before it is placed 312 times.
public enum ArtworkLimits: Sendable {

    /// Largest source file accepted, in bytes. A stamp is a seal, not a drawing set.
    public static let maximumSourceBytes = 16 * 1024 * 1024

    /// Largest number of contours one artwork may compile to.
    ///
    /// A contour bomb is the cheapest denial of service a PDF content stream can express:
    /// a few kilobytes of `re f` produce as many rectangles as the reader is willing to keep.
    public static let maximumContours = 20_000

    /// Largest number of points in any single contour.
    public static let maximumPointsPerContour = 8_000

    /// Largest number of points across the whole artwork.
    ///
    /// The two limits above are individually satisfiable and jointly ruinous — 19 999 contours
    /// of 7 999 points each satisfies both — so the product is bounded as well as the factors.
    public static let maximumTotalPoints = 200_000

    /// Largest raster the importer will decode, in pixels. Refused **before** decoding, from
    /// the image source's declared size, so a decode bomb is never allocated.
    public static let maximumRasterPixels = 40_000_000

    /// Longest edge, in cells, of the mosaic a raster source is compiled to.
    ///
    /// The mosaic's cost is a property of this number and not of the imported file, which is
    /// what makes a raster stamp's primitive count predictable no matter what was imported.
    public static let maximumRasterSampleEdge = 96

    /// Deepest form-XObject nesting followed. A form that refers to itself terminates here.
    public static let maximumNestingDepth = 12

    /// How far each mosaic cell overlaps its neighbours, as a fraction of a cell.
    ///
    /// Two abutting fills each cover about half of the pixel on the edge they share, and a
    /// renderer composites that half its own way — which shows up as a hairline seam through
    /// every cell boundary of the mosaic, and made this product's two backends disagree on a
    /// third of the pixels at 25 % zoom. An overlap costs a fraction of a cell of positional
    /// fidelity and removes the seam on both. It is a property of the compiled artwork rather
    /// than of a renderer, so it is fixed here, once, and every producer of a mosaic uses it.
    public static let rasterCellBleed = 0.35

    /// Smallest stamp box accepted, in PDF points, so a divide-by-box cannot happen.
    public static let minimumBoxPoints = 1.0

    /// Largest stamp box accepted, in PDF points. Wider than any ISO sheet, on purpose.
    public static let maximumBoxPoints = 20_000.0

    /// Largest stroke width a contour may carry, as a fraction of the artwork box's smaller
    /// edge (BH-127). A width of `1` already covers the whole box; the compiler clamps to half
    /// of that, and a stored value above this is corrupt data, not a wide pen.
    public static let maximumStrokeWidthFraction = 1.0
}

/// Why an artwork import was refused, with the limit it hit.
///
/// A refusal is a product surface, not a log line. "This page has 41 208 contours; the limit
/// is 20 000" is something an estimator can act on — simplify the artwork, export it flattened,
/// pick a different page. "Import failed" is not.
public enum ArtworkImportRefusal: Error, Codable, Hashable, Sendable {

    /// The source file is larger than ``ArtworkLimits/maximumSourceBytes``.
    case sourceTooLarge(bytes: Int, limit: Int)
    /// The file could not be read as a PDF or as an image at all.
    case unreadableSource
    /// The PDF is encrypted. Zenit does not carry a password into an artwork import.
    case encryptedSource
    /// The requested page does not exist in the source document.
    case pageOutOfRange(requested: Int, pageCount: Int)
    /// The page or image contains nothing that can be drawn.
    case empty
    /// More contours than ``ArtworkLimits/maximumContours``.
    case tooManyContours(found: Int, limit: Int)
    /// A single contour longer than ``ArtworkLimits/maximumPointsPerContour``.
    case contourTooLong(found: Int, limit: Int)
    /// More points in total than ``ArtworkLimits/maximumTotalPoints``.
    case tooManyPoints(found: Int, limit: Int)
    /// A raster larger than ``ArtworkLimits/maximumRasterPixels``, refused before decoding.
    case rasterTooLarge(pixels: Int, limit: Int)
    /// Form-XObject nesting deeper than ``ArtworkLimits/maximumNestingDepth``.
    case nestingTooDeep(depth: Int, limit: Int)
    /// The geometry contains a coordinate that is not finite, so no bounding box exists.
    case nonFiniteGeometry
    /// A finite coordinate lies outside the artwork's own unit box (BH-479). Compiled artwork
    /// is stored in `0...1` space; a stored value outside it was edited or corrupted, and is
    /// named as such rather than as a number that is not finite.
    case coordinateOutsideUnitBox
    /// The page's own bounding box has no area, so unit space cannot be defined.
    case degenerateBounds
    /// A contour's stroke width is not a finite fraction of the box in
    /// `0...ArtworkLimits.maximumStrokeWidthFraction` (BH-127). The painters multiply this
    /// number straight into a line width, so an unbounded one paints a blob over the sheet.
    case invalidStrokeWidth(found: Double, limit: Double)
    /// The page was read, but not all of it: a budget fired, a form referred to itself, or
    /// the content stream was malformed part-way through.
    ///
    /// Snap degrades to *fewer* candidates and says so; artwork cannot. Half a seal is not a
    /// smaller seal, it is the wrong picture, and a stamp placed on 312 sheets is the worst
    /// possible place to discover that. So partial extraction is a refusal here even though
    /// the same condition is a warning in Vector Snap.
    case incompleteArtwork(detail: String)

    /// A sentence for the person, with the number in it.
    public var reason: String {
        switch self {
        case let .sourceTooLarge(bytes, limit):
            return "The file is \(bytes) bytes; the limit for imported artwork is \(limit)."
        case .unreadableSource:
            return "The file could not be read as a PDF page or as an image."
        case .encryptedSource:
            return "The PDF is encrypted. Artwork cannot be imported from an encrypted file."
        case let .pageOutOfRange(requested, pageCount):
            return "Page \(requested + 1) was requested; the file has \(pageCount)."
        case .empty:
            return "There is nothing to draw on that page."
        case let .tooManyContours(found, limit):
            return "This artwork has \(found) contours; the limit is \(limit)."
        case let .contourTooLong(found, limit):
            return "One contour has \(found) points; the limit is \(limit)."
        case let .tooManyPoints(found, limit):
            return "This artwork has \(found) points; the limit is \(limit)."
        case let .rasterTooLarge(pixels, limit):
            return "The image is \(pixels) pixels; the limit is \(limit)."
        case let .nestingTooDeep(depth, limit):
            return "The page nests drawing forms \(depth) deep; the limit is \(limit)."
        case .nonFiniteGeometry:
            return "The artwork contains a coordinate that is not a finite number."
        case .coordinateOutsideUnitBox:
            return "The artwork contains a coordinate outside its own bounding box."
        case .degenerateBounds:
            return "The artwork has no width or no height."
        case let .invalidStrokeWidth(found, limit):
            return "A stroke width of \(found) times the artwork box was found; the limit is \(limit)."
        case let .incompleteArtwork(detail):
            return "Only part of that page could be read (\(detail)), so the artwork would be incomplete."
        }
    }
}

/// One open or closed contour of compiled artwork, in **unit space**.
///
/// Unit space is the `0...1` box of the artwork's own bounding box, origin lower-left. A
/// template is resizable and 312 placements share one compilation, so the compiled form must
/// not know how big any of them are.
public struct ArtworkContour: Codable, Hashable, Sendable {
    /// Vertices in unit space. Curves are already flattened by the compiler.
    public var points: [PDFPoint]
    /// When true the last point joins back to the first.
    public var isClosed: Bool
    /// Stroke width as a fraction of the artwork box's smaller edge, so a stamp scaled from
    /// 96 points to 400 keeps its line weights in proportion. `0` means the renderer's default.
    public var widthFraction: Double

    public init(points: [PDFPoint], isClosed: Bool = false, widthFraction: Double = 0) {
        self.points = points
        self.isClosed = isClosed
        self.widthFraction = widthFraction
    }
}

/// One filled region of compiled artwork, in unit space, with an optional own colour.
///
/// The colour is present for raster mosaics, where a cell without its own colour is not a
/// picture, and absent for compiled PDF pages, where `CGPDFScanner` extraction records paint
/// role and stroke width but not ink (ADR-0011 §2.4). An absent colour means "the stamp's own
/// style colour", which is what a single-ink seal wants.
public struct ArtworkRegion: Codable, Hashable, Sendable {
    /// Outer contour in unit space.
    public var outer: [PDFPoint]
    /// Hole contours in unit space. The fill rule is even-odd, as everywhere else in Zenit.
    public var holes: [[PDFPoint]]
    /// The region's own colour, or `nil` to take the markup's style colour.
    public var color: RGBAColor?

    public init(outer: [PDFPoint], holes: [[PDFPoint]] = [], color: RGBAColor? = nil) {
        self.outer = outer
        self.holes = holes
        self.color = color
    }
}

/// Imported artwork, compiled once, in unit space.
///
/// This is the durable form: it is what `stamp_artwork.geometry_json` stores and what the
/// renderer draws. The source bytes are kept beside it for provenance and for re-compilation
/// under a future compiler, and are never consulted to draw a frame — ADR-0011 §2.2.
public struct ArtworkGeometry: Codable, Hashable, Sendable {

    /// The compiler that produced this. Bumped when the compiled shape of the same input
    /// would change, so a stored artwork can say which grammar it came from.
    public static let compilerVersion = 1

    /// Whether this compiled from a PDF page or from an image, and therefore whether
    /// magnifying it keeps its edges crisp.
    public var kind: StampArtworkKind
    /// Contours to stroke.
    public var strokes: [ArtworkContour]
    /// Regions to fill.
    public var regions: [ArtworkRegion]
    /// The version of the compiler that produced ``strokes`` and ``regions``.
    public var compilerVersion: Int
    /// The aspect ratio of the source, width divided by height, so a stamp box can be
    /// proposed that does not distort the artwork.
    public var sourceAspectRatio: Double

    public init(
        kind: StampArtworkKind,
        strokes: [ArtworkContour] = [],
        regions: [ArtworkRegion] = [],
        compilerVersion: Int = ArtworkGeometry.compilerVersion,
        sourceAspectRatio: Double = 1
    ) {
        self.kind = kind
        self.strokes = strokes
        self.regions = regions
        self.compilerVersion = compilerVersion
        self.sourceAspectRatio = sourceAspectRatio
    }

    /// Artwork with nothing in it.
    public static let empty = ArtworkGeometry(kind: .none)

    /// Whether there is anything to draw.
    public var isEmpty: Bool { strokes.isEmpty && regions.isEmpty }

    /// Primitives per placement. A 40 000-primitive logo on 312 sheets is 12.5 million
    /// primitives, and a batch sheet that can say so is better than a frame rate that
    /// explains it later.
    public var primitiveCount: Int { strokes.count + regions.count }

    /// Total vertices, which is what the import limits are actually written against.
    public var pointCount: Int {
        strokes.reduce(0) { $0 + $1.points.count }
            + regions.reduce(0) { $0 + $1.outer.count + $1.holes.reduce(0) { $0 + $1.count } }
    }

    /// Whether every coordinate is finite and inside the unit box, the aspect ratio is a
    /// positive finite number and every stroke width is a bounded fraction.
    ///
    /// Checked on the way in *and* available on the way out, because compiled artwork is
    /// stored and a stored value that is read back is input again. ``wellFormednessViolation``
    /// says *which* of those failed; this is its yes/no form.
    public var isWellFormed: Bool { wellFormednessViolation == nil }

    /// The first thing wrong with the geometry itself, named precisely (BH-479, BH-127), or
    /// `nil` when it is well formed.
    ///
    /// - ``ArtworkImportRefusal/nonFiniteGeometry`` for a NaN or infinite coordinate;
    /// - ``ArtworkImportRefusal/coordinateOutsideUnitBox`` for a finite one outside `0...1`
    ///   (with the compiler's rounding slack);
    /// - ``ArtworkImportRefusal/degenerateBounds`` for an aspect ratio that is not a positive
    ///   finite number — the source box had no width or no height;
    /// - ``ArtworkImportRefusal/invalidStrokeWidth(found:limit:)`` for a stroke width that is
    ///   not finite, negative, or above ``ArtworkLimits/maximumStrokeWidthFraction``.
    public var wellFormednessViolation: ArtworkImportRefusal? {
        func violation(in points: [PDFPoint]) -> ArtworkImportRefusal? {
            for point in points {
                guard point.x.isFinite, point.y.isFinite else { return .nonFiniteGeometry }
                guard point.x >= -0.0001, point.x <= 1.0001,
                      point.y >= -0.0001, point.y <= 1.0001 else {
                    return .coordinateOutsideUnitBox
                }
            }
            return nil
        }
        guard sourceAspectRatio.isFinite, sourceAspectRatio > 0 else { return .degenerateBounds }
        for stroke in strokes {
            if let found = violation(in: stroke.points) { return found }
            let width = stroke.widthFraction
            guard width.isFinite, width >= 0, width <= ArtworkLimits.maximumStrokeWidthFraction else {
                return .invalidStrokeWidth(found: width, limit: ArtworkLimits.maximumStrokeWidthFraction)
            }
        }
        for region in regions {
            if let found = violation(in: region.outer) { return found }
            for hole in region.holes {
                if let found = violation(in: hole) { return found }
            }
        }
        return nil
    }

    /// The refusal this artwork would earn if it were offered for import, or `nil`.
    ///
    /// One function, so the compiler, the decoder and the persistence read path all bound the
    /// same thing the same way. A limit enforced in one of three places is a limit with two
    /// holes in it.
    public func limitViolation() -> ArtworkImportRefusal? {
        let contours = strokes.count + regions.count
        if contours > ArtworkLimits.maximumContours {
            return .tooManyContours(found: contours, limit: ArtworkLimits.maximumContours)
        }
        for stroke in strokes where stroke.points.count > ArtworkLimits.maximumPointsPerContour {
            return .contourTooLong(
                found: stroke.points.count, limit: ArtworkLimits.maximumPointsPerContour
            )
        }
        for region in regions {
            if region.outer.count > ArtworkLimits.maximumPointsPerContour {
                return .contourTooLong(
                    found: region.outer.count, limit: ArtworkLimits.maximumPointsPerContour
                )
            }
            for hole in region.holes where hole.count > ArtworkLimits.maximumPointsPerContour {
                return .contourTooLong(
                    found: hole.count, limit: ArtworkLimits.maximumPointsPerContour
                )
            }
        }
        let points = pointCount
        if points > ArtworkLimits.maximumTotalPoints {
            return .tooManyPoints(found: points, limit: ArtworkLimits.maximumTotalPoints)
        }
        return wellFormednessViolation
    }
}

/// The symbol a markup draws itself as: a **reference** to artwork, never the artwork.
///
/// ADR-0011 §2.1. Two properties decided the shape of this type and nothing else did:
///
/// - **A markup must render correctly after its preset is deleted or edited.** Nothing here
///   is resolved through the tool library at draw time. ``artworkDigest`` addresses bytes that
///   live in the project, so deleting the preset, renaming it or replacing its artwork cannot
///   reach a mark that was already placed.
/// - **A project must stay self-contained when it travels.** The bytes are in the `.zpdfproj`,
///   keyed by this digest, so a colleague who opens the file sees the same picture without ever
///   having had the preset.
///
/// It is on the record rather than in a side table for ADR-0010's reason, unchanged: undo, redo,
/// save, export and the clipboard all move whole ``MarkupRecord`` values, and a symbol that
/// lived only beside the record is a symbol one of those five paths eventually drops.
public struct MarkupSymbol: Codable, Hashable, Sendable {

    /// SHA-256 of the artwork bytes in the project's artwork store, lower-case hex.
    /// `nil` when the symbol is a built-in glyph rather than imported artwork.
    public var artworkDigest: String?

    /// Whether the artwork stays sharp when magnified. `.none` for a built-in glyph, which is
    /// drawn from geometry and is therefore sharp by construction.
    public var kind: StampArtworkKind

    /// The built-in glyph's name — `"filledCircle"`, `"cross"`, and the rest of the renderer's
    /// count-symbol set — when there is no imported artwork.
    ///
    /// A named glyph rather than an absent value, for the reason ``MarkupStatus/none`` exists:
    /// "a plain filled circle" is a decision, and a decision spelled as `nil` is one every
    /// consumer has to re-interpret.
    public var builtInGlyph: String?

    /// Edge of the symbol's square box in PDF points. A count mark's size is a property of the
    /// mark, so two marks made with one tool may legitimately differ.
    public var sizePoints: Double

    /// Rotation about the mark's own point, in degrees counter-clockwise.
    public var rotationDegrees: Double

    /// The file the artwork was imported from, kept verbatim for provenance. Empty for a
    /// built-in glyph.
    public var sourceName: String

    /// Creates a symbol reference.
    public init(
        artworkDigest: String? = nil,
        kind: StampArtworkKind = .none,
        builtInGlyph: String? = nil,
        sizePoints: Double = 12,
        rotationDegrees: Double = 0,
        sourceName: String = ""
    ) {
        self.artworkDigest = artworkDigest
        self.kind = kind
        self.builtInGlyph = builtInGlyph
        self.sizePoints = sizePoints
        self.rotationDegrees = rotationDegrees
        self.sourceName = sourceName
    }

    /// A built-in glyph by name.
    public static func builtIn(_ name: String, sizePoints: Double = 12) -> MarkupSymbol {
        MarkupSymbol(kind: .none, builtInGlyph: name, sizePoints: sizePoints)
    }

    /// Whether this symbol draws imported artwork rather than a built-in glyph.
    public var usesImportedArtwork: Bool { artworkDigest != nil }

    /// Whether magnifying the canvas keeps this symbol's edges crisp.
    ///
    /// A built-in glyph is vector and always crisp. Imported artwork answers from its
    /// ``kind`` — except when the kind is ``StampArtworkKind/none`` while a digest is present
    /// (BH-480): both production constructors fall back to `.none` for an `artwork_kind` this
    /// build cannot read, so that combination means "unknown", and an unknown picture is not
    /// promised to stay sharp. The two predicates were keyed on different fields before, and a
    /// raster mosaic with an unreadable kind was reported crisp.
    public var staysSharpWhenMagnified: Bool {
        guard usesImportedArtwork else { return true }
        return kind != .none && kind.staysSharpWhenMagnified
    }

    /// Whether the size is one the renderer can actually place.
    public var hasUsableSize: Bool {
        sizePoints.isFinite
            && sizePoints >= ArtworkLimits.minimumBoxPoints
            && sizePoints <= ArtworkLimits.maximumBoxPoints
            && rotationDegrees.isFinite
    }
}
