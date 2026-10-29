import Foundation
import ZPDFContracts

/// A snippet is a **specification, not a screen grab** (ADR-0006 §1).
///
/// Everything here is page-space or document data: nothing refers to a window, a scroll
/// position or a zoom. The same spec rendered after any sequence of viewport changes produces
/// the identical bytes — a property the zoom-invariance test in `SnippetExportTests` asserts
/// literally, byte for byte.
public struct SnippetSpec: Sendable, Hashable {
    public var source: SnippetSource
    public var region: SnippetRegion
    public var content: SnippetContent
    public var caption: SnippetCaptionDetail
    /// Output pixels per page point: `1...8`, default 3. Validated by ``validate()`` before
    /// anything is allocated.
    public var scaleFactor: Double
    public var appearance: SnippetAppearance

    public init(
        source: SnippetSource,
        region: SnippetRegion,
        content: SnippetContent = SnippetContent(),
        caption: SnippetCaptionDetail = .compact,
        scaleFactor: Double = 3,
        appearance: SnippetAppearance = .light
    ) {
        self.source = source
        self.region = region
        self.content = content
        self.caption = caption
        self.scaleFactor = scaleFactor
        self.appearance = appearance
    }

    /// The bounds every renderer of this spec relies on.
    public func validate() throws(SnippetExportError) {
        guard scaleFactor.isFinite, (1.0...8.0).contains(scaleFactor) else {
            throw SnippetExportError.scaleFactorOutOfRange(scaleFactor)
        }
        if case let .markups(ids, padding) = region {
            guard !ids.isEmpty else { throw SnippetExportError.emptyRegion }
            guard padding.isFinite, padding >= 0 else {
                throw SnippetExportError.invalidPadding(padding)
            }
        }
    }
}

/// What the snippet is *of*: document, page, revision (ADR-0006 §1).
public struct SnippetSource: Sendable, Hashable {
    public var documentName: String
    /// Zero-based page index in the document.
    public var pageIndex: Int
    /// The page label as the PDF declares it — what the `.full` caption prints, never the raw
    /// index (the ledger makes the same distinction).
    public var pageLabel: String?
    public var revision: String?

    public init(
        documentName: String,
        pageIndex: Int,
        pageLabel: String? = nil,
        revision: String? = nil
    ) {
        self.documentName = documentName
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.revision = revision
    }
}

/// Where the snippet's picture comes from — always **page-space geometry, never the view**
/// (ADR-0006 §1). `SnippetRegionResolver` turns each case into a page-space rectangle.
public enum SnippetRegion: Sendable, Hashable {
    /// The union of the markups' page-space bounds, grown by `padding` page points on every
    /// side. Bounds are computed from geometry, not from what happened to be on screen.
    case markups([MarkupID], padding: Double)
    /// A drawn region, already in page space.
    case rect(PDFRect)
    /// A project zone; its page-space bounds come from the zone catalogue the caller supplies.
    case zone(ZoneID)
}

/// Which layers the picture contains.
///
/// `includeSnapGuides` defaults to `false` and the export pipeline could not honour `true` if
/// it wanted to: snap feedback is interface state that never reaches the exporter, which is
/// the ADR's point — a snippet shows drawing content, not the pointer's snap glyph.
public struct SnippetContent: Sendable, Hashable {
    /// The PDF page under the markups. Off produces markups on a plain ground.
    public var includeDrawing: Bool
    /// The markups the region names.
    public var includeMarkups: Bool
    /// Markups other than the region's own — context around the measurement being asked about.
    public var includeOtherMarkups: Bool
    /// Always effectively `false`; see the type's discussion.
    public var includeSnapGuides: Bool

    public init(
        includeDrawing: Bool = true,
        includeMarkups: Bool = true,
        includeOtherMarkups: Bool = true,
        includeSnapGuides: Bool = false
    ) {
        self.includeDrawing = includeDrawing
        self.includeMarkups = includeMarkups
        self.includeOtherMarkups = includeOtherMarkups
        self.includeSnapGuides = includeSnapGuides
    }
}

/// How much the caption band says.
///
/// `.none` exists for clean artwork and **is not the default** (ADR-0006 §2): the failure mode
/// this feature guards against is a quantity travelling without its context.
public enum SnippetCaptionDetail: Sendable, Hashable {
    case none
    /// Measured value with unit, markup label and subject.
    case compact
    /// `.compact` plus page label, drawing name, revision, scale, calibration source, project
    /// name and the export timestamp.
    case full
}

/// The snippet's colour treatment. `.light` is the default: white ground, dark caption text,
/// legible in a mail thread. `.matchApp` takes the caller's theme colours.
public enum SnippetAppearance: Sendable, Hashable {
    case light
    case matchApp(SnippetTheme)

    var theme: SnippetTheme {
        switch self {
        case .light: .light
        case let .matchApp(theme): theme
        }
    }
}

/// The colours a snippet is composed with.
public struct SnippetTheme: Sendable, Hashable {
    /// Ground behind the page raster (and the whole picture when the drawing is excluded).
    public var background: RGBAColor
    public var captionBackground: RGBAColor
    public var captionText: RGBAColor
    public var captionSeparator: RGBAColor

    public init(
        background: RGBAColor,
        captionBackground: RGBAColor,
        captionText: RGBAColor,
        captionSeparator: RGBAColor
    ) {
        self.background = background
        self.captionBackground = captionBackground
        self.captionText = captionText
        self.captionSeparator = captionSeparator
    }

    public static let light = SnippetTheme(
        background: RGBAColor(red: 1, green: 1, blue: 1),
        captionBackground: RGBAColor(red: 0.96, green: 0.96, blue: 0.97),
        captionText: RGBAColor(red: 0.10, green: 0.11, blue: 0.13),
        captionSeparator: RGBAColor(red: 0.80, green: 0.81, blue: 0.83)
    )
}

/// Everything the snippet exporter can refuse to do. Typed, exhaustive, never a trap.
public enum SnippetExportError: Error, Sendable, Hashable, CustomStringConvertible {
    /// `scaleFactor` outside `1...8` (ADR-0006 §3).
    case scaleFactorOutOfRange(Double)
    case invalidPadding(Double)
    /// The region resolves to nothing drawable on the page.
    case emptyRegion
    /// `.markups` named ids the caller's geometry does not contain.
    case markupsNotFound([MarkupID])
    /// `.zone` named a zone the caller's catalogue does not contain.
    case zoneNotFound(ZoneID)
    /// The pixel budget refusal of ADR-0006 §3: dimensions are reported **before** export, so
    /// a 12x request on an A1 sheet is refused with a clear reason rather than allocating
    /// gigabytes. The budget is the renderer's own (`RenderLimits.maximumTargetPixels` per
    /// edge).
    case pixelBudgetExceeded(width: Int, height: Int, maximumEdge: Int)
    /// The same refusal against the **total** pixel count: the page raster behind a snippet
    /// refuses more than `maximumPixels` (the PDFKit bridge's `maximumRenderPixels`), and an A1
    /// sheet at 6x is well inside the per-edge budget and far outside that one. Checked before
    /// anything is allocated, so the refusal is this sentence rather than a failed raster.
    case pixelAreaExceeded(width: Int, height: Int, maximumPixels: Int)
    /// The export was cancelled while the page was being rasterised. Not a failure: callers
    /// that treat cancellation as silence can tell the two apart.
    case cancelled
    /// The caption was asked for but no ledger projection was supplied. A snippet must not
    /// invent numbers, so this is a refusal, not a silent blank band (ADR-0006 §2).
    case captionRequiresProjection
    /// The page or the composed geometry failed validation inside the renderer.
    case renderFailed(String)
    /// The page raster source failed.
    case pageRasterFailed(String)
    case bitmapContextUnavailable
    case pngEncodingFailed
    case pdfContextUnavailable

    public var description: String {
        switch self {
        case let .scaleFactorOutOfRange(value):
            "scale factor \(value) is outside the 1x...8x range"
        case let .invalidPadding(value):
            "region padding \(value) is not a non-negative finite number"
        case .emptyRegion:
            "the region resolves to nothing drawable on the page"
        case let .markupsNotFound(ids):
            "the region names \(ids.count) markup(s) with no known geometry"
        case let .zoneNotFound(id):
            "no zone with id \(id) was supplied"
        case let .pixelBudgetExceeded(width, height, maximumEdge):
            "\(width)x\(height) pixels exceeds the \(maximumEdge)-pixel edge budget; lower the scale factor or shrink the region"
        case let .pixelAreaExceeded(width, height, maximumPixels):
            "\(width)x\(height) pixels exceeds the \(maximumPixels)-pixel budget; lower the scale factor or shrink the region"
        case .cancelled:
            "the snippet export was cancelled"
        case .captionRequiresProjection:
            "a captioned snippet needs the ledger report projection its values come from"
        case let .renderFailed(reason):
            "the snippet could not be rendered: \(reason)"
        case let .pageRasterFailed(reason):
            "the page raster failed: \(reason)"
        case .bitmapContextUnavailable:
            "Core Graphics refused to create the composition context"
        case .pngEncodingFailed:
            "PNG encoding failed"
        case .pdfContextUnavailable:
            "Core Graphics refused to create the PDF context"
        }
    }
}
