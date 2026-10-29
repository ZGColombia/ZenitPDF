import CoreGraphics
import CoreText
import Foundation
import Testing
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFRenderer
@testable import ZPDFExport

/// Bug hunt 2: the snippet compositor's pixel budget, caption band, text-markup
/// crop and cancellation. No test here puts a window on screen or touches a pasteboard; the
/// page raster is a fake.
@Suite(.sharedHeap)
struct Fix2E2SnippetTests {

    static func page(width: Double, height: Double, rotation: PageRotation = .degrees0) -> PageDescriptor {
        let box = PDFRect(x: 0, y: 0, width: width, height: height)
        return PageDescriptor(
            id: PageID(ExportFixture.uuid(-2)),
            documentID: DocumentID(ExportFixture.uuid(-1)),
            index: 0,
            label: "S-1",
            boxes: PageBoxes(media: box, crop: box),
            rotation: rotation
        )
    }

    struct FailingPageSource: SnippetPageRasterizing {
        let error: any Error & Sendable
        func rasterizePageRegion(
            pageIndex: Int, region: PDFRect, pixelsPerPoint: Double
        ) async throws -> CGImage {
            throw error
        }
    }

    // MARK: - BH-144 / BH-534: the total-pixel budget

    @Test("BH-144: an A1 sheet at 6x is refused before allocation against the 64 MP raster budget")
    func a1AtSixTimesIsRefusedUpFront() async throws {
        // 2384 x 1684 pt at 6x is 14304 x 10104 = 144.5 MP: under 16384 per edge, over the page
        // raster's 64 MP. Old: the up-front estimate said exceedsBudget == false, and render
        // failed later as pageRasterFailed("pixelBudgetExceeded(...)") — or, with the drawing
        // off, allocated two 578 MB buffers.
        let a1 = Self.page(width: 2384, height: 1684)
        let spec = SnippetExportTests.spec(
            region: .rect(PDFRect(x: 0, y: 0, width: 2384, height: 1684)),
            caption: .none,
            scaleFactor: 6
        )
        // The budget is the page raster's own.
        #expect(SnippetExporter.maximumPixels == DocumentLimits().maximumRenderPixels)

        // Refused by name before the page source is asked, with the drawing on or off.
        for includeDrawing in [true, false] {
            var drawingSpec = spec
            drawingSpec.content.includeDrawing = includeDrawing
            await #expect(throws: SnippetExportError.pixelAreaExceeded(
                width: 14_304, height: 10_104, maximumPixels: SnippetExporter.maximumPixels
            )) {
                _ = try await SnippetExporter().render(
                    spec: drawingSpec, page: a1, markups: [],
                    pageSource: SnippetExportTests.ForbiddenPageSource()
                )
            }
        }
    }

    @Test("BH-534: an A0 region at the default 3x (72.3 MP) is refused by name, not as a raster failure")
    func a0AtThreeTimesIsRefusedUpFront() async throws {
        let a0 = Self.page(width: 3370, height: 2384)
        let spec = SnippetExportTests.spec(
            region: .rect(PDFRect(x: 0, y: 0, width: 3370, height: 2384)),
            caption: .none
        )
        await #expect(throws: SnippetExportError.pixelAreaExceeded(
            width: 10_110, height: 7_152, maximumPixels: SnippetExporter.maximumPixels
        )) {
            _ = try await SnippetExporter().render(
                spec: spec, page: a0, markups: [],
                pageSource: SnippetExportTests.ForbiddenPageSource()
            )
        }
        // A region under the budget on the same sheet renders: 500 x 400 pt at 3x is
        // 1500 x 1200 px, 1.8 MP of the 64 MP budget.
        #expect(SnippetExporter.maximumPixels == 64_000_000)
        let small = SnippetExportTests.spec(
            region: .rect(PDFRect(x: 0, y: 0, width: 500, height: 400)),
            caption: .none
        )
        let rendered = try await SnippetExporter().render(
            spec: small, page: a0, markups: [], pageSource: SnippetExportTests.PatternPageSource()
        )
        #expect(rendered.image.width == 1_500 && rendered.image.height == 1_200)
        #expect(rendered.contentPixelHeight == 1_200)
    }

    // MARK: - BH-145 / BH-146: the caption fits the band

    @Test("BH-145: caption lines are wrapped to the band, word by word, with every word kept")
    func captionLinesWrapToTheBand() {
        let caption = SnippetCaption(lines: ["Doors · Count: 12 pcs", "A-101 · rev C"])
        // One 8 pt count symbol plus 24 pt padding a side is 56 pt, 168 px at 3x.
        let metrics = SnippetExporter.CaptionMetrics(caption: caption, scaleFactor: 3, contentWidth: 168)
        let font = CTFontCreateWithName("Helvetica" as CFString, metrics.fontSize, nil)
        let available = 168 - 2 * metrics.padding
        #expect(metrics.lines.count > caption.lines.count)
        for line in metrics.lines {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
            #expect(CGFloat(width) <= available + 0.5, "\"\(line)\" is \(width) wide in a \(available) band")
        }
        let words = { (lines: [String]) in lines.joined(separator: " ").split(separator: " ").map(String.init) }
        #expect(words(metrics.lines) == words(caption.lines))
        #expect(metrics.lines.contains { $0.contains("12") }, "the quantity is not in any wrapped line")

        // A wide band leaves the caption alone.
        let wide = SnippetExporter.CaptionMetrics(caption: caption, scaleFactor: 3, contentWidth: 2_000)
        #expect(wide.lines == caption.lines)
    }

    @Test("BH-146: a narrow snippet's caption band grows instead of running ink off the right edge")
    func narrowSnippetCaptionStaysInsideTheBitmap() async throws {
        // Old: the band was one line per caption line and CTLineDraw ran past the bitmap, so the
        // rightmost columns of the band carried caption ink and the value was cut off.
        let markups = SnippetExportTests.markups()
        let spec = SnippetExportTests.spec(region: .markups([markups[0].id], padding: 2))
        let projection = try SnippetExportTests.projection()
        let image = try await SnippetExporter().render(
            spec: spec,
            page: SnippetExportTests.page(),
            markups: markups,
            projection: projection,
            pageSource: SnippetExportTests.PatternPageSource()
        )
        let unwrapped = SnippetExporter.CaptionMetrics(caption: image.caption, scaleFactor: 3, contentWidth: nil)
        let wrapped = SnippetExporter.CaptionMetrics(
            caption: image.caption, scaleFactor: 3, contentWidth: image.pixelWidth
        )
        #expect(image.pixelWidth < 200)
        #expect(wrapped.lines.count > unwrapped.lines.count, "the fixture caption fits without wrapping")
        let band = image.pixelHeight - image.contentPixelHeight
        #expect(band == wrapped.bandHeightPixels)

        // No caption ink in the band's last eight columns: every line ends inside the padding.
        let background = spec.appearance.theme.captionBackground
        let expected = [background.red, background.green, background.blue].map { UInt8(($0 * 255).rounded()) }
        var inked = 0
        let separator = Int((Double(band) * 0.006).rounded(.up)) + 2
        for y in (image.contentPixelHeight + separator)..<image.pixelHeight {
            for x in (image.pixelWidth - 8)..<image.pixelWidth {
                let offset = (y * image.pixelWidth + x) * 4
                for channel in 0..<3 where abs(Int(image.image.pixels[offset + channel]) - Int(expected[channel])) > 24 {
                    inked += 1
                    break
                }
            }
        }
        #expect(inked == 0, "\(inked) caption pixels touch the right edge of the snippet")
    }

    // MARK: - BH-147 / BH-148: text markups crop to the text

    @Test("BH-147: a text note crops to its text, not to a 48 pt square at its corner")
    func textNotesCropToTheirText() throws {
        // Old: geometryBounds of a .textLabel is a zero-size rect at the anchor, so padding 0
        // threw emptyRegion and padding 24 gave a 48 x 48 pt crop of the note's corner.
        let id = MarkupID(ExportFixture.uuid(700))
        let note = RenderableMarkup(
            id: id,
            shape: .textLabel(RenderTextLabel(
                anchorPoint: PDFPoint(x: 100, y: 400),
                text: "Verify opening on site",
                fontSize: 11,
                anchor: .topLeading
            )),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0))
        )
        let size = try #require(SnippetRegionResolver.textSize("Verify opening on site", fontName: "Helvetica", fontSize: 11))
        #expect(size.width > 100)
        let region = try SnippetRegionResolver.resolve(
            .markups([id], padding: 0),
            page: SnippetExportTests.page(),
            markups: [note],
            zones: [:]
        )
        #expect(abs(region.minX - 100) < 1e-9)
        #expect(abs(region.maxY - 400) < 1e-9)
        #expect(abs(region.width - size.width) < 1e-6)
        #expect(abs(region.height - size.height) < 1e-6)

        let padded = try SnippetRegionResolver.resolve(
            .markups([id], padding: 24),
            page: SnippetExportTests.page(),
            markups: [note],
            zones: [:]
        )
        #expect(padded.width > 48 + 100)
    }

    @Test("BH-147: on a /Rotate 90 page the upright text extends along page +y and +x")
    func rotatedTextNotesCropToTheirText() throws {
        let id = MarkupID(ExportFixture.uuid(701))
        let note = RenderableMarkup(
            id: id,
            shape: .textLabel(RenderTextLabel(anchorPoint: PDFPoint(x: 100, y: 400), text: "Verify opening on site")),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0))
        )
        let size = try #require(SnippetRegionResolver.textSize("Verify opening on site", fontName: "Helvetica", fontSize: 11))
        let region = try SnippetRegionResolver.resolve(
            .markups([id], padding: 0),
            page: Self.page(width: 612, height: 792, rotation: .degrees90),
            markups: [note],
            zones: [:]
        )
        // Screen right is page +y, screen down is page +x on a quarter-turned sheet.
        #expect(abs(region.minX - 100) < 1e-9 && abs(region.minY - 400) < 1e-9)
        #expect(abs(region.width - size.height) < 1e-6)
        #expect(abs(region.height - size.width) < 1e-6)
    }

    @Test("BH-148: a label pill contributes its pill, sized at the snippet's scale")
    func labelPillsCropToThePill() throws {
        // Old: a point at the pill's centre.
        let id = MarkupID(ExportFixture.uuid(702))
        let pill = RenderableMarkup(
            id: id,
            shape: .labelPill(RenderLabelPill(anchorPoint: PDFPoint(x: 300, y: 300), text: "Area C: 21,34 m²")),
            style: RenderStyle(stroke: RGBAColor(red: 1, green: 1, blue: 1))
        )
        let text = try #require(SnippetRegionResolver.textSize("Area C: 21,34 m²", fontName: "Helvetica", fontSize: 10))
        let region = try SnippetRegionResolver.resolve(
            .markups([id], padding: 0),
            page: SnippetExportTests.page(),
            markups: [pill],
            zones: [:],
            scaleFactor: 2
        )
        let expectedWidth = (text.width + 2 * MarkupCompiler.DimensionGrammar.pillPaddingXViewPoints) / 2
        #expect(abs(region.width - expectedWidth) < 1e-6)
        #expect(abs(region.midX - 300) < 1e-9 && abs(region.midY - 300) < 1e-9)
    }

    // MARK: - BH-535: cancellation is not a raster failure

    @Test("BH-535: a cancelled page raster surfaces as .cancelled, not pageRasterFailed")
    func cancellationIsReportedAsCancellation() async throws {
        // Old: pageRasterFailed("cancelled") / pageRasterFailed("CancellationError()").
        let spec = SnippetExportTests.spec(
            region: .rect(PDFRect(x: 10, y: 10, width: 100, height: 100)),
            caption: .none
        )
        for error in [PDFBridgeError.cancelled, CancellationError()] as [any Error & Sendable] {
            await #expect(throws: SnippetExportError.cancelled) {
                _ = try await SnippetExporter().render(
                    spec: spec, page: SnippetExportTests.page(), markups: [],
                    pageSource: FailingPageSource(error: error)
                )
            }
        }
        // A real failure is still a raster failure.
        await #expect(throws: SnippetExportError.pageRasterFailed(String(describing: SnippetExportError.pngEncodingFailed))) {
            _ = try await SnippetExporter().render(
                spec: spec, page: SnippetExportTests.page(), markups: [],
                pageSource: FailingPageSource(error: SnippetExportError.pngEncodingFailed)
            )
        }
    }
}
