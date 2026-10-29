import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// The assertion: **a flattened sheet contains no image XObject.**
///
/// # Why this file exists
///
/// The work that proved printing puts markups on paper proved it the only way that counts — it
/// drove a real print operation and decompressed the content stream of the file that came out.
/// Reading it turned up something no passing test could see. The strokes and fills were vector,
/// as `MarkupFlattener` documents; **every glyph and every count symbol was a small 8-bit image
/// behind an ExtGState soft mask** — 46 of them on one sheet, 4 × 5 to 19 × 21 pixels. The flatten
/// path compiles the scene at `zoom: 1, backingScale: 1`, so one atlas pixel becomes one PDF
/// point, and a plotted A1 came out with crisp linework and blocky dimension values.
///
/// Neither the app-tier suite nor the rest of `ZPDFExportTests` could see it: they assert that the
/// markups are *present* and correctly *placed*, which they were. Nothing asserted what the ink
/// was made of. This file does, and it does it with a negative control — the same scene imaged the
/// old way, in the same test, asserted to *contain* images — because an assertion that would pass
/// on an empty document is the failure mode this repository has already met once.
///
/// # The allow-list, and its one entry
///
/// The rule allows a raster to stay a raster when a markup genuinely is one, provided the
/// allow-list names it and says why: ``imageAllowance(_:)``, exhaustive over `RenderShape` so a
/// new case cannot reach paper without a decision. **One entry**: the picture placed with
/// Edit ▸ Insert Image (`RenderShape.image`, ADR-0043, L-81) — a photo or a sketch is a raster
/// by nature, and drawing it as its 96-cell mosaic was the defect. It lands as exactly one image
/// XObject at its decoded size (`L8InsertedImageExportTests`). Every other case flattens to paths,
/// and ``everyShapeFlattensWithoutAnImage`` is the enumeration that proves it. Imported stamp
/// artwork is not an exception — `StampArtworkScene` compiles a PDF page's artwork into
/// `StampArtworkGeometry` contours before the renderer ever sees it, and expands into polylines,
/// polygons and text labels, all of which this test covers.
///
/// The one image a flattened *file* may legitimately contain is the **underlay**: the source
/// drawing's own content, which is copied rather than painted through `MarkupFlattener`. So the
/// assertions here are made on markups-only sheets, and ``underlayImagesAreNotOurs`` states the
/// general rule for a sheet that has an underlay — flattening adds no image the clean control
/// does not already have.
@Suite(.sharedHeap)
struct FlattenedVectorTextTests {

    // MARK: - Fixtures

    private typealias Base = FlattenedPDFWriterTests

    private static func textLabel(at point: PDFPoint, _ text: String) -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(UUID()),
            zIndex: 4,
            shape: .textLabel(RenderTextLabel(
                anchorPoint: point, text: text, fontName: "Helvetica", fontSize: 12
            )),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), lineWidth: 1)
        )
    }

    private static func labelPill(at point: PDFPoint, _ text: String) -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(UUID()),
            zIndex: 5,
            shape: .labelPill(RenderLabelPill(anchorPoint: point, text: text)),
            style: RenderStyle(
                stroke: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
                fill: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
                lineWidth: 1
            )
        )
    }

    /// One markup of every text-bearing kind, plus one of every count symbol, on one sheet.
    /// This is the scene 30.3 read 46 images out of.
    private static func textHeavySheet(page: PageDescriptor) -> [RenderableMarkup] {
        var markups: [RenderableMarkup] = [
            Base.polyline(from: PDFPoint(x: 30, y: 30), to: PDFPoint(x: 370, y: 40)),
            Base.dimension(
                from: PDFPoint(x: 40, y: 120), to: PDFPoint(x: 340, y: 120), label: "14,72 m"
            ),
            textLabel(at: PDFPoint(x: 40, y: 200), "Sektion B — brandcell"),
            labelPill(at: PDFPoint(x: 220, y: 240), "Area C: 21,34 m²")
        ]
        for (index, symbol) in CountSymbol.allCases.enumerated() {
            markups.append(RenderableMarkup(
                id: MarkupID(UUID()),
                zIndex: 6 + index,
                shape: .countSymbol(RenderCountSymbol(
                    center: PDFPoint(x: 40 + Double(index) * 30, y: 270),
                    symbol: symbol,
                    size: 14
                )),
                style: RenderStyle(
                    stroke: RGBAColor(red: 0.1, green: 0.5, blue: 0.1, alpha: 1),
                    fill: RGBAColor(red: 0.1, green: 0.5, blue: 0.1, alpha: 1),
                    lineWidth: 1
                )
            ))
        }
        return markups
    }

    // MARK: - Reading the file for images

    /// How many image XObjects a produced PDF declares.
    ///
    /// Counted from the raw bytes rather than from the content stream, because that is where a
    /// soft-masked glyph tile actually lives: the stream says `/Gs24 gs … re f`, and the picture
    /// is off in an `/SMask` object the stream never names. `CGPDFContext` compresses stream
    /// *contents* but writes object dictionaries in the clear, so `/Subtype /Image` is readable
    /// exactly where it is written.
    private static func imageObjectCount(in data: Data) -> Int {
        let text = String(decoding: data, as: UTF8.self)
        var count = 0
        for spelling in ["/Subtype /Image", "/Subtype/Image"] {
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: spelling, range: search) {
                count += 1
                search = found.upperBound..<text.endIndex
            }
        }
        return count
    }

    /// Paints the same scene the flatten path would, but through the **old** imaging — the atlas
    /// mask blit — into a PDF context. The negative control: if this does not produce images, the
    /// positive assertion is measuring nothing.
    private static func atlasImagedSheet(
        page: PageDescriptor,
        markups: [RenderableMarkup]
    ) throws -> Data {
        let viewport = RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        let pixelSize = viewport.pixelSize
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.atlasImaging = .atlas
        renderer.update(
            page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport
        )
        var box = CGRect(x: 0, y: 0, width: Double(pixelSize.width), height: Double(pixelSize.height))
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        renderer.drawCurrentScene(into: context, pixelHeight: pixelSize.height)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    // MARK: - The assertion 30.3 owed

    @Test("A flattened sheet whose markups are all vector contains no image XObject")
    func flattenedSheetContainsNoImageXObject() throws {
        let page = Base.page()
        let markups = Self.textHeavySheet(page: page)

        // The control first, so a green run cannot be a vacuous one. Imaged through the atlas,
        // this exact scene is a pile of soft-masked bitmaps — one per glyph, one per symbol. It
        // measured **78** image XObjects when this test was written; the floor is set well under
        // that so a font metric or a label edit cannot make the control brittle.
        let control = try Self.atlasImagedSheet(page: page, markups: markups)
        let controlImages = Self.imageObjectCount(in: control)
        #expect(controlImages > 20, "the control must actually contain the defect: \(controlImages)")

        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: markups)],
            content: nil
        )
        #expect(Self.imageObjectCount(in: data) == 0)

        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        #expect(output.inlineImages == 0)
        // No underlay was given, so nothing legitimate can be invoked either.
        #expect(output.xObjectInvocations == 0)

        // And the text is still on the sheet: glyph outlines are curves, and nothing else in
        // this scene draws one — the pill is a fanned polygon, the arrowheads are triangles.
        #expect(output.stream.contains(" c\n") || output.stream.contains(" c "))
        #expect(output.paintOperators.contains("f"))
    }

    /// The allow-list: why a shape's ink may reach a flattened sheet as an image, or `nil` when it
    /// must not. Exhaustive on purpose — no `default`.
    static func imageAllowance(_ shape: RenderShape) -> String? {
        switch shape {
        case .polyline, .filledPolygon, .countSymbol, .textLabel, .dimensionLine, .labelPill:
            return nil
        case .image:
            return "an inserted picture is a raster by nature, painted once at its own pixels (ADR-0043, L-81)"
        }
    }

    @Test("Every RenderShape but the inserted picture flattens to paths — the allow-list names that one")
    func everyShapeFlattensWithoutAnImage() throws {
        let page = Base.page()
        let cases: [(String, RenderShape)] = [
            ("polyline", .polyline(RenderPolyline(
                points: [PDFPoint(x: 40, y: 40), PDFPoint(x: 300, y: 200)], isClosed: false
            ))),
            ("filledPolygon", .filledPolygon(RenderPolygon(outer: [
                PDFPoint(x: 60, y: 60), PDFPoint(x: 200, y: 60), PDFPoint(x: 130, y: 180)
            ]))),
            ("countSymbol", .countSymbol(RenderCountSymbol(
                center: PDFPoint(x: 150, y: 150), symbol: .star, size: 20
            ))),
            ("textLabel", .textLabel(RenderTextLabel(
                anchorPoint: PDFPoint(x: 60, y: 220), text: "Våning 3 · 8 st"
            ))),
            ("dimensionLine", .dimensionLine(RenderDimensionLine(
                start: PDFPoint(x: 50, y: 90), end: PDFPoint(x: 330, y: 90), label: "9,05 m"
            ))),
            ("labelPill", .labelPill(RenderLabelPill(
                anchorPoint: PDFPoint(x: 200, y: 250), text: "12,5 m²"
            )))
        ]
        for (name, shape) in cases {
            #expect(Self.imageAllowance(shape) == nil, "\(name) is on the allow-list")
            let markup = RenderableMarkup(
                id: MarkupID(UUID()),
                zIndex: 0,
                shape: shape,
                style: RenderStyle(
                    stroke: RGBAColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1),
                    fill: RGBAColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 0.5),
                    lineWidth: 2
                )
            )
            let data = try FlattenedPDFWriter().data(
                shape: .flattened,
                pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: [markup])],
                content: nil
            )
            #expect(Self.imageObjectCount(in: data) == 0, "\(name) put an image on the sheet")
            let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
            #expect(output.inlineImages == 0, "\(name) put an inline image on the sheet")
            #expect(output.xObjectInvocations == 0, "\(name) invoked an XObject")
            #expect(!output.pathPoints.isEmpty, "\(name) drew nothing at all")
        }
    }

    @Test("With an underlay, flattening adds no image the clean control does not have")
    func underlayImagesAreNotOurs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-vector-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A source page that deliberately carries a raster of its own, so the assertion is
        // "flattening added none" rather than "the file has none".
        let sourceURL = directory.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let sourceContext = try #require(CGContext(sourceURL as CFURL, mediaBox: &box, nil))
        sourceContext.beginPDFPage(nil)
        var pixels: [UInt8] = [200, 40, 40, 255, 40, 200, 40, 255, 40, 40, 200, 255, 220, 220, 40, 255]
        let provider = try #require(pixels.withUnsafeMutableBytes { raw in
            CGDataProvider(data: Data(raw) as CFData)
        })
        let raster = try #require(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        sourceContext.draw(raster, in: CGRect(x: 40, y: 40, width: 120, height: 90))
        sourceContext.endPDFPage()
        sourceContext.closePDF()

        let page = Base.page(width: 400, height: 300, cropOrigin: PDFPoint(x: 0, y: 0))
        let markups = Self.textHeavySheet(page: page)

        let clean = try FlattenedPDFWriter().data(
            shape: .clean,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: markups)],
            content: try #require(CGPDFPageContentSource(url: sourceURL))
        )
        let flattened = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: markups)],
            content: try #require(CGPDFPageContentSource(url: sourceURL))
        )

        let cleanImages = Self.imageObjectCount(in: clean)
        let flattenedImages = Self.imageObjectCount(in: flattened)
        // The source's own raster is present in both — otherwise this test proves nothing.
        #expect(cleanImages >= 1, "the underlay's own image should survive: \(cleanImages)")
        #expect(flattenedImages == cleanImages, "flattening added \(flattenedImages - cleanImages)")
    }
}
