import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFRenderer

/// Supplies the drawing underneath the markups: a rasterised page region.
///
/// One conformance matters in the app — its `CanvasSnippetPageSource`, which forwards to the
/// app's `PageRasterSource`, the one object that holds the open drawing — and the tests supply a
/// deterministic fake, which is the point of the seam: the compositor's behaviour is testable
/// without a PDF on disk.
public protocol SnippetPageRasterizing: Sendable {
    /// Rasterises `region` (page space, bottom-left origin) of page `pageIndex` at
    /// `pixelsPerPoint` output pixels per page point, opaque, sRGB-compatible.
    func rasterizePageRegion(
        pageIndex: Int,
        region: PDFRect,
        pixelsPerPoint: Double
    ) async throws -> CGImage
}

/// A finished snippet: the composited picture plus the caption it carries.
public struct SnippetImage: Sendable {
    /// Premultiplied RGBA8, sRGB. Content on top, caption band (if any) at the bottom.
    public let image: RasterImage
    /// The page-space rectangle the picture shows.
    public let region: PDFRect
    /// Height in pixels of the drawing part, above the caption band.
    public let contentPixelHeight: Int
    public let caption: SnippetCaption
    public let scaleFactor: Double
    /// A true sentence about the source, used as the plain-text pasteboard fallback when the
    /// caption is `.none`.
    public let sourceDescription: String

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }

    /// PNG, sRGB, at the spec's scale factor (ADR-0006 §3).
    public func pngData() throws(SnippetExportError) -> Data {
        guard let data = image.pngData() else { throw SnippetExportError.pngEncodingFailed }
        return data
    }

    /// The pasteboard payload of ADR-0006 §3: the PNG **and** a plain-text fallback, so
    /// pasting into a plain-text field still says something true. The app layer writes both
    /// representations to the platform pasteboard; this package stays UI-free.
    public func pasteboardPayload() throws(SnippetExportError) -> SnippetPasteboardPayload {
        SnippetPasteboardPayload(
            png: try pngData(),
            plainText: caption.isEmpty ? sourceDescription : caption.text
        )
    }
}

/// What a copy puts on the pasteboard: two representations of one snippet.
public struct SnippetPasteboardPayload: Sendable, Hashable {
    public let png: Data
    public let plainText: String

    public init(png: Data, plainText: String) {
        self.png = png
        self.plainText = plainText
    }
}

/// The pixel dimensions a spec would produce, worked out **before** any allocation
/// (ADR-0006 §3). Internal: the renderer checks it itself; nothing outside needs it (W-057).
struct SnippetPixelEstimate: Sendable, Hashable {
    public let contentWidth: Int
    public let contentHeight: Int
    public let captionHeight: Int
    public var totalWidth: Int { contentWidth }
    public var totalHeight: Int { contentHeight + captionHeight }
    /// The per-edge budget the estimate was checked against.
    public let maximumEdge: Int
    /// The total-pixel budget the estimate was checked against — the page raster's own.
    public let maximumPixels: Int
    public var exceedsBudget: Bool {
        totalWidth > maximumEdge || totalHeight > maximumEdge
            || totalWidth.multipliedReportingOverflow(by: totalHeight).overflow
            || totalWidth * totalHeight > maximumPixels
    }
}

/// ADR-0006's compositor: PDFKit-bridge page raster + the renderer's offscreen markups + a
/// caption band from the `LedgerReport` projection.
///
/// # Why the Core Graphics backend, deliberately
///
/// The markups are rendered through `CoreGraphicsMarkupRenderer` — the renderer package's
/// reference implementation — not the Metal one. An export must be deterministic across
/// machines and cannot require a GPU; the golden suite proves the two backends paint the same
/// picture, so nothing visual is given up by choosing the one whose output is reproducible
/// byte for byte.
///
/// # Zoom invariance, by construction
///
/// No method here takes a viewport, a zoom or a scroll position. The region is page-space
/// geometry, the output scale is the spec's, and the offscreen viewport is derived from those
/// two numbers alone — so the same spec produces the same bytes whatever the app's canvas was
/// doing, which the zoom-invariance test asserts literally.
public struct SnippetExporter: Sendable {

    public init() {}

    /// The total-pixel ceiling a snippet is checked against before anything is allocated: the
    /// PDFKit bridge's page-raster budget, so a request the raster would refuse is refused here,
    /// by name, instead (ADR-0006 §3). The same ceiling bounds the composition buffer when the
    /// drawing is left out.
    public static let maximumPixels = DocumentLimits().maximumRenderPixels

    // MARK: - Pixel budget

    /// The output dimensions of `spec` over `region`, checked against the budget before
    /// ``render(spec:page:markups:zones:projection:captionOptions:pageSource:)`` or
    /// ``renderPDF(spec:page:markups:zones:projection:captionOptions:pageSource:vectorPage:)``
    /// allocates anything.
    private func estimate(
        spec: SnippetSpec,
        page: PageDescriptor,
        region: PDFRect,
        caption: SnippetCaption
    ) throws(SnippetExportError) -> SnippetPixelEstimate {
        // The budget is checked on the *requested* dimensions, computed by arithmetic before
        // any viewport exists — `RenderViewport.pixelSize` clamps to the same limit, which
        // would silently shrink an oversized request instead of refusing it (ADR-0006 §3).
        let swaps = page.rotation.swapsAxes
        let displayWidth = swaps ? region.height : region.width
        let displayHeight = swaps ? region.width : region.height
        let scaledWidth = displayWidth * spec.scaleFactor
        let scaledHeight = displayHeight * spec.scaleFactor
        let maximumEdge = RenderLimits.maximumTargetPixels
        // A region too large for `Int` is over every budget; it must be refused, not trapped on.
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth <= Double(maximumEdge), scaledHeight <= Double(maximumEdge)
        else {
            throw SnippetExportError.pixelBudgetExceeded(
                width: scaledWidth.isFinite ? Int(Swift.min(scaledWidth.rounded(.up), 1e9)) : Int.max,
                height: scaledHeight.isFinite ? Int(Swift.min(scaledHeight.rounded(.up), 1e9)) : Int.max,
                maximumEdge: maximumEdge
            )
        }
        let requestedWidth = Int(scaledWidth.rounded(.up))
        // The caption is wrapped to the picture's width, so its height depends on it.
        let requestedMetrics = CaptionMetrics(
            caption: caption,
            scaleFactor: spec.scaleFactor,
            contentWidth: requestedWidth
        )
        let requestedHeight = Int(scaledHeight.rounded(.up)) + requestedMetrics.bandHeightPixels
        guard requestedWidth <= maximumEdge, requestedHeight <= maximumEdge else {
            throw SnippetExportError.pixelBudgetExceeded(
                width: requestedWidth,
                height: requestedHeight,
                maximumEdge: maximumEdge
            )
        }
        // The page raster refuses on the product, not per edge; so does this, before either the
        // raster or the composition buffer is allocated.
        guard requestedWidth * requestedHeight <= Self.maximumPixels else {
            throw SnippetExportError.pixelAreaExceeded(
                width: requestedWidth,
                height: requestedHeight,
                maximumPixels: Self.maximumPixels
            )
        }

        guard let viewport = RenderViewport.window(
            page, zoom: spec.scaleFactor, backingScale: 1, pageRect: region
        ) else { throw SnippetExportError.renderFailed("unusable page or region") }
        let content = viewport.pixelSize
        let metrics = CaptionMetrics(
            caption: caption,
            scaleFactor: spec.scaleFactor,
            contentWidth: content.width
        )
        let estimate = SnippetPixelEstimate(
            contentWidth: content.width,
            contentHeight: content.height,
            captionHeight: metrics.bandHeightPixels,
            maximumEdge: maximumEdge,
            maximumPixels: Self.maximumPixels
        )
        guard !estimate.exceedsBudget else {
            throw SnippetExportError.pixelAreaExceeded(
                width: estimate.totalWidth,
                height: estimate.totalHeight,
                maximumPixels: Self.maximumPixels
            )
        }
        return estimate
    }

    // MARK: - PNG path

    /// Renders the spec to a composited raster snippet.
    ///
    /// - Parameters:
    ///   - projection: the ledger projection the caption quotes. Required unless
    ///     `spec.caption == .none`; the caption cannot come from anywhere else, which is what
    ///     keeps a snippet incapable of disagreeing with the CSV or the XLSX.
    ///   - pageSource: the page raster seam. Required when `spec.content.includeDrawing`.
    public func render(
        spec: SnippetSpec,
        page: PageDescriptor,
        markups: [RenderableMarkup],
        zones: [ZoneID: PDFRect] = [:],
        projection: ExportProjection? = nil,
        captionOptions: SnippetCaptionOptions = SnippetCaptionOptions(),
        pageSource: (any SnippetPageRasterizing)? = nil
    ) async throws -> SnippetImage {
        try spec.validate()
        let region = try SnippetRegionResolver.resolve(
            spec.region, page: page, markups: markups, zones: zones,
            scaleFactor: spec.scaleFactor
        )
        let caption = try makeCaption(
            spec: spec, projection: projection, options: captionOptions
        )
        let estimate = try estimate(spec: spec, page: page, region: region, caption: caption)

        let pageImage = try await pageRaster(
            spec: spec, region: region, pageSource: pageSource
        )
        let markupImage = try renderMarkups(
            spec: spec, page: page, markups: markups, region: region
        )

        let composed = try compose(
            spec: spec,
            estimate: estimate,
            pageImage: pageImage,
            markupImage: markupImage,
            caption: caption
        )
        return SnippetImage(
            image: composed,
            region: region,
            contentPixelHeight: estimate.contentHeight,
            caption: caption,
            scaleFactor: spec.scaleFactor,
            sourceDescription: Self.sourceDescription(spec.source)
        )
    }

    // MARK: - PDF path

    /// The vector variant of the same pipeline (ADR-0006 §3): identical region, identical
    /// caption text, markups and caption drawn as vectors into a single-page PDF. The page
    /// layer underneath is the bridge's raster at the same scale factor — the bridge's seam
    /// hands back pixels, not a draw closure — which prints correctly and keeps the one code
    /// path; a fully vector page layer would need a bridge API that does not exist yet.
    ///
    /// - Parameter vectorPage: the drawing's own page content (NL-PDF-21). When given, and the
    ///   page is not rotated, the page layer is the drawing's vector content clipped to the
    ///   region — no image at all for a vector sheet — and `pageSource` is not asked for pixels.
    public func renderPDF(
        spec: SnippetSpec,
        page: PageDescriptor,
        markups: [RenderableMarkup],
        zones: [ZoneID: PDFRect] = [:],
        projection: ExportProjection? = nil,
        captionOptions: SnippetCaptionOptions = SnippetCaptionOptions(),
        pageSource: (any SnippetPageRasterizing)? = nil,
        vectorPage: (any FlattenPageContentDrawing)? = nil
    ) async throws -> Data {
        try spec.validate()
        let region = try SnippetRegionResolver.resolve(
            spec.region, page: page, markups: markups, zones: zones,
            scaleFactor: spec.scaleFactor
        )
        let caption = try makeCaption(
            spec: spec, projection: projection, options: captionOptions
        )
        let estimate = try estimate(spec: spec, page: page, region: region, caption: caption)
        let drawsVector = spec.content.includeDrawing && vectorPage != nil && page.rotation == .degrees0
        let pageImage = drawsVector ? nil : try await pageRaster(
            spec: spec, region: region, pageSource: pageSource
        )

        // The markup renderer is prepared exactly as in the raster path; only the surface it
        // paints differs.
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        // …and, because that surface is vector, so are the glyphs and the count symbols. The
        // page layer underneath is still the bridge's raster — see the note above — but a
        // dimension value in a snippet has no reason to be a bitmap when the snippet is a PDF.
        renderer.atlasImaging = .outlines
        var hasMarkups = false
        if spec.content.includeMarkups {
            let visible = filteredMarkups(spec: spec, markups: markups)
            if !visible.isEmpty, let viewport = RenderViewport.window(
                page, zoom: spec.scaleFactor, backingScale: 1, pageRect: region
            ) {
                renderer.update(
                    page: page,
                    markups: visible,
                    selection: .empty,
                    snapFeedback: nil,
                    viewport: viewport
                )
                hasMarkups = renderer.statistics.markupCount > 0
            }
        }

        let scale = spec.scaleFactor
        let widthPoints = Double(estimate.contentWidth) / scale
        let contentHeightPoints = Double(estimate.contentHeight) / scale
        let bandPoints = Double(estimate.captionHeight) / scale
        var mediaBox = CGRect(
            x: 0, y: 0,
            width: widthPoints,
            height: contentHeightPoints + bandPoints
        )
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw SnippetExportError.pdfContextUnavailable }

        context.beginPDFPage(nil)
        let theme = spec.appearance.theme
        context.setFillColor(Self.cgColor(theme.background))
        context.fill(mediaBox)

        let contentRect = CGRect(
            x: 0, y: bandPoints, width: widthPoints, height: contentHeightPoints
        )
        if drawsVector, let vectorPage {
            // The whole sheet at one point per point, placed so the region lands on the content
            // rectangle, and clipped to it: the drawing's own paths, at any zoom a reader likes.
            let box = page.visibleBox
            let sheet = CGRect(
                x: -(region.minX - box.minX) * contentRect.width / region.width,
                y: contentRect.minY - (region.minY - box.minY) * contentRect.height / region.height,
                width: box.width * contentRect.width / region.width,
                height: box.height * contentRect.height / region.height
            )
            context.saveGState()
            context.clip(to: contentRect)
            _ = vectorPage.drawPageContent(sourcePageIndex: spec.source.pageIndex, into: context, rect: sheet, page: page)
            context.restoreGState()
        } else if let pageImage {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(pageImage, in: contentRect)
            context.restoreGState()
        }
        if hasMarkups {
            context.saveGState()
            context.clip(to: contentRect)
            context.translateBy(x: 0, y: CGFloat(bandPoints))
            context.scaleBy(x: CGFloat(1 / scale), y: CGFloat(1 / scale))
            renderer.drawCurrentScene(into: context, pixelHeight: estimate.contentHeight)
            context.restoreGState()
        }
        if !caption.isEmpty {
            // Wrapped at the raster scale — the same line breaks the PNG gets, and the line
            // count the band height above was computed from — then drawn at one point per point.
            let wrapped = CaptionMetrics(
                caption: caption,
                scaleFactor: spec.scaleFactor,
                contentWidth: estimate.contentWidth
            )
            let metrics = CaptionMetrics(lines: wrapped.lines, scaleFactor: 1)
            drawCaption(
                metrics: metrics,
                theme: theme,
                into: context,
                bandRect: CGRect(x: 0, y: 0, width: widthPoints, height: bandPoints)
            )
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: - Stages

    private func makeCaption(
        spec: SnippetSpec,
        projection: ExportProjection?,
        options: SnippetCaptionOptions
    ) throws(SnippetExportError) -> SnippetCaption {
        guard spec.caption != .none else { return .empty }
        guard let projection else { throw SnippetExportError.captionRequiresProjection }
        let ids: [MarkupID]
        if case let .markups(named, _) = spec.region {
            ids = named
        } else {
            ids = []
        }
        return SnippetCaptionBuilder.build(
            detail: spec.caption,
            markupIDs: ids,
            projection: projection,
            source: spec.source,
            options: options
        )
    }

    private func pageRaster(
        spec: SnippetSpec,
        region: PDFRect,
        pageSource: (any SnippetPageRasterizing)?
    ) async throws -> CGImage? {
        guard spec.content.includeDrawing else { return nil }
        guard let pageSource else {
            throw SnippetExportError.pageRasterFailed(
                "includeDrawing is set but no page source was supplied"
            )
        }
        do {
            return try await pageSource.rasterizePageRegion(
                pageIndex: spec.source.pageIndex,
                region: region,
                pixelsPerPoint: spec.scaleFactor
            )
        } catch is CancellationError {
            throw SnippetExportError.cancelled
        } catch PDFBridgeError.cancelled {
            throw SnippetExportError.cancelled
        } catch {
            // A source that reports cancellation in its own words is still a cancellation when
            // the task asking for the snippet has been cancelled.
            if Task.isCancelled { throw SnippetExportError.cancelled }
            throw SnippetExportError.pageRasterFailed(String(describing: error))
        }
    }

    private func filteredMarkups(
        spec: SnippetSpec,
        markups: [RenderableMarkup]
    ) -> [RenderableMarkup] {
        guard spec.content.includeMarkups else { return [] }
        if !spec.content.includeOtherMarkups, case let .markups(ids, _) = spec.region {
            // By **shape family**, not by exact identity: a count group is one mark per
            // renderable and a stamp is one contour per renderable, so filtering on the id
            // the region names would leave the snippet showing a fragment of the very
            // markup it was asked for. See ``SnippetRegionResolver/familyKey(of:)``.
            return SnippetRegionResolver.shapes(of: ids, in: markups)
        }
        return markups
    }

    private func renderMarkups(
        spec: SnippetSpec,
        page: PageDescriptor,
        markups: [RenderableMarkup],
        region: PDFRect
    ) throws(SnippetExportError) -> CGImage? {
        let visible = filteredMarkups(spec: spec, markups: markups)
        guard !visible.isEmpty else { return nil }
        guard let viewport = RenderViewport.window(
            page, zoom: spec.scaleFactor, backingScale: 1, pageRect: region
        ) else { throw SnippetExportError.renderFailed("unusable page or region") }
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page,
            markups: visible,
            selection: .empty,   // interface state never reaches an export
            snapFeedback: nil,   // includeSnapGuides is structurally false here (ADR-0006)
            viewport: viewport
        )
        do {
            let raster = try renderer.renderOffscreen()
            guard let image = raster.makeCGImage() else {
                throw SnippetExportError.bitmapContextUnavailable
            }
            return image
        } catch let error as SnippetExportError {
            throw error
        } catch {
            throw SnippetExportError.renderFailed(String(describing: error))
        }
    }

    private func compose(
        spec: SnippetSpec,
        estimate: SnippetPixelEstimate,
        pageImage: CGImage?,
        markupImage: CGImage?,
        caption: SnippetCaption
    ) throws(SnippetExportError) -> RasterImage {
        let width = estimate.totalWidth
        let height = estimate.totalHeight
        guard width > 0, height > 0 else { throw SnippetExportError.emptyRegion }
        let theme = spec.appearance.theme
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        var succeeded = false
        storage.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  )
            else { return }
            succeeded = true
            context.setFillColor(Self.cgColor(theme.background))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let bandHeight = estimate.captionHeight
            let contentRect = CGRect(
                x: 0,
                y: CGFloat(bandHeight),
                width: CGFloat(width),
                height: CGFloat(estimate.contentHeight)
            )
            context.interpolationQuality = .high
            if let pageImage {
                context.draw(pageImage, in: contentRect)
            }
            if let markupImage {
                context.draw(markupImage, in: contentRect)
            }
            if !caption.isEmpty, bandHeight > 0 {
                let metrics = CaptionMetrics(
                    caption: caption,
                    scaleFactor: spec.scaleFactor,
                    contentWidth: width
                )
                drawCaption(
                    metrics: metrics,
                    theme: theme,
                    into: context,
                    bandRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(bandHeight))
                )
            }
        }
        guard succeeded else { throw SnippetExportError.bitmapContextUnavailable }
        guard let image = RasterImage(width: width, height: height, pixels: storage) else {
            throw SnippetExportError.bitmapContextUnavailable
        }
        return image
    }

    // MARK: - Caption band drawing

    /// The caption band's type metrics, and the caption's lines **wrapped to the band**.
    ///
    /// The band is exactly as wide as the picture, and a snippet of one count mark is 168 px
    /// wide at 3x while "Doors · Count: 12 pcs" in the 33 px caption face is twice that. Drawn
    /// unwrapped, the line ran off the bitmap and took the quantity with it — the one thing the
    /// caption exists to carry (ADR-0006 §2). Each line is broken at word boundaries (at a
    /// character cluster only when a single word is wider than the band), and the band grows by
    /// a line per break, so every character of the caption is in the picture.
    struct CaptionMetrics {
        let fontSize: CGFloat
        let lineHeight: CGFloat
        let padding: CGFloat
        /// The lines as drawn, after wrapping.
        let lines: [String]

        var lineCount: Int { lines.count }

        /// - Parameter contentWidth: the band's width in the same units as `scaleFactor`
        ///   produces (pixels for the PNG); `nil` leaves the lines unwrapped.
        init(caption: SnippetCaption, scaleFactor: Double, contentWidth: Int?) {
            fontSize = CGFloat(11 * scaleFactor)
            lineHeight = CGFloat((11 * 1.45) * scaleFactor)
            padding = CGFloat(8 * scaleFactor)
            if let contentWidth {
                let available = CGFloat(contentWidth) - 2 * padding
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                lines = caption.lines.flatMap {
                    Self.wrap($0, font: font, width: available)
                }
            } else {
                lines = caption.lines
            }
        }

        /// Metrics for lines already wrapped at another scale.
        init(lines: [String], scaleFactor: Double) {
            fontSize = CGFloat(11 * scaleFactor)
            lineHeight = CGFloat((11 * 1.45) * scaleFactor)
            padding = CGFloat(8 * scaleFactor)
            self.lines = lines
        }

        var bandHeightPixels: Int {
            guard lineCount > 0 else { return 0 }
            return Int((CGFloat(lineCount) * lineHeight + 2 * padding).rounded(.up))
        }

        /// `line` broken into pieces no wider than `width` when set in `font`.
        static func wrap(_ line: String, font: CTFont, width: CGFloat) -> [String] {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            let length = attributed.length
            guard length > 0, width.isFinite else { return [line] }
            // A band narrower than one glyph still gets one cluster per line rather than none.
            let budget = Double(Swift.max(width, 1))
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let text = attributed.string as NSString
            var pieces: [String] = []
            var start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, budget)
                if count <= 0 { count = CTTypesetterSuggestClusterBreak(typesetter, start, budget) }
                if count <= 0 {
                    count = text.rangeOfComposedCharacterSequence(at: start).length
                }
                count = Swift.min(Swift.max(count, 1), length - start)
                let piece = text.substring(with: NSRange(location: start, length: count))
                    .trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { pieces.append(piece) }
                start += count
            }
            return pieces.isEmpty ? [line] : pieces
        }
    }

    private func drawCaption(
        metrics: CaptionMetrics,
        theme: SnippetTheme,
        into context: CGContext,
        bandRect: CGRect
    ) {
        context.saveGState()
        context.setFillColor(Self.cgColor(theme.captionBackground))
        context.fill(bandRect)
        // A hairline separator between picture and caption.
        let separatorHeight = Swift.max(bandRect.height * 0.006, 0.5)
        context.setFillColor(Self.cgColor(theme.captionSeparator))
        context.fill(CGRect(
            x: bandRect.minX,
            y: bandRect.maxY - separatorHeight,
            width: bandRect.width,
            height: separatorHeight
        ))

        let font = CTFontCreateWithName("Helvetica" as CFString, metrics.fontSize, nil)
        let color = Self.cgColor(theme.captionText)
        context.textMatrix = .identity
        for (index, line) in metrics.lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let baseline = bandRect.maxY - metrics.padding
                - CGFloat(index) * metrics.lineHeight - metrics.fontSize
            context.textPosition = CGPoint(x: bandRect.minX + metrics.padding, y: baseline)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    // MARK: - Small helpers

    private static func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }

    private static func sourceDescription(_ source: SnippetSource) -> String {
        var parts = ["Snippet of \(source.documentName)"]
        if let label = source.pageLabel, !label.isEmpty {
            parts.append("page \(label)")
        } else {
            parts.append("page \(source.pageIndex + 1)")
        }
        if let revision = source.revision, !revision.isEmpty {
            parts.append("rev \(revision)")
        }
        return parts.joined(separator: ", ")
    }
}
