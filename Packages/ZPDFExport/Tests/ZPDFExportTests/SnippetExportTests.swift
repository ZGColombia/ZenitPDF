import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFRenderer
@testable import ZPDFExport

/// ADR-0006 snippet export: the spec model, the region-from-geometry rule, the pixel budget
/// refusal, the caption's ledger lineage, zoom invariance, the PDF variant and the pasteboard
/// payload.
@Suite("Snippet export (ADR-0006)", .sharedHeap)
struct SnippetExportTests {

    // MARK: - Fixture

    /// A deterministic page source: a two-tone pattern whose phase depends on the region, so a
    /// snippet that rasterised the wrong region produces visibly and byte-wise different
    /// output.
    struct PatternPageSource: SnippetPageRasterizing {
        func rasterizePageRegion(
            pageIndex: Int,
            region: PDFRect,
            pixelsPerPoint: Double
        ) async throws -> CGImage {
            let width = Swift.max(1, Int((region.width * pixelsPerPoint).rounded(.up)))
            let height = Swift.max(1, Int((region.height * pixelsPerPoint).rounded(.up)))
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let phase = Int(region.minX + region.minY) + pageIndex
            for y in 0..<height {
                for x in 0..<width where (x + y + phase) % 16 < 8 {
                    let offset = (y * width + x) * 4
                    pixels[offset] = 220
                    pixels[offset + 1] = 228
                    pixels[offset + 2] = 236
                }
            }
            guard let image = RasterImage(width: width, height: height, pixels: pixels)?
                .makeCGImage()
            else { throw SnippetExportError.bitmapContextUnavailable }
            return image
        }
    }

    /// A page source that must never be called.
    struct ForbiddenPageSource: SnippetPageRasterizing {
        func rasterizePageRegion(
            pageIndex: Int, region: PDFRect, pixelsPerPoint: Double
        ) async throws -> CGImage {
            Issue.record("the page source was called before the pixel budget was checked")
            throw SnippetExportError.bitmapContextUnavailable
        }
    }

    static func page() -> PageDescriptor {
        let box = PDFRect(x: 0, y: 0, width: 612, height: 792)
        return PageDescriptor(
            id: PageID(ExportFixture.uuid(-2)),
            documentID: DocumentID(ExportFixture.uuid(-1)),
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: box, crop: box)
        )
    }

    /// Renderable geometry whose ids line up with the golden ledger fixture's rows, so a
    /// caption can quote real projected values for the markups in the picture.
    static func markups() -> [RenderableMarkup] {
        var markups: [RenderableMarkup] = []
        for index in 0..<ExportFixture.goldenValues.count {
            let x = 100.0 + Double(index) * 60
            let y = 300.0 + Double(index % 2) * 80
            markups.append(RenderableMarkup(
                id: MarkupID(ExportFixture.uuid(index)),
                zIndex: index,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: x, y: y),
                    PDFPoint(x: x + 40, y: y + 25),
                    PDFPoint(x: x + 40, y: y - 25)
                ])),
                style: RenderStyle(
                    stroke: RGBAColor(red: 0.75, green: 0.15, blue: 0.30),
                    lineWidth: 1.5
                )
            ))
        }
        return markups
    }

    static func projection() throws -> ExportProjection {
        try ExportProjector().project(
            ExportFixture.goldenReport(),
            options: ExportProjectionOptions(document: ExportDocumentContext(
                projectName: "Harbour House",
                documentName: "A-101 Ground Floor",
                revision: "C",
                scaleDescription: "1:100"
            ))
        )
    }

    static func spec(
        region: SnippetRegion,
        caption: SnippetCaptionDetail = .compact,
        scaleFactor: Double = 3,
        content: SnippetContent = SnippetContent()
    ) -> SnippetSpec {
        SnippetSpec(
            source: SnippetSource(
                documentName: "A-101 Ground Floor",
                pageIndex: 0,
                pageLabel: "A-101",
                revision: "C"
            ),
            region: region,
            content: content,
            caption: caption,
            scaleFactor: scaleFactor
        )
    }

    // MARK: - Region from geometry

    @Test("The markups region is the union of page-space geometry bounds plus padding")
    func markupRegionComesFromGeometry() throws {
        let markups = Self.markups()
        let ids = [markups[0].id, markups[1].id]
        let region = try SnippetRegionResolver.resolve(
            .markups(ids, padding: 12),
            page: Self.page(),
            markups: markups,
            zones: [:]
        )
        // Markup 0 spans x 100...140, y 275...325; markup 1 spans x 160...200, y 355...405.
        #expect(region.minX == 88)
        #expect(region.maxX == 212)
        #expect(region.minY == 263)
        #expect(region.maxY == 417)
    }

    @Test("Unknown markup ids are a typed refusal, not a guessed crop")
    func unknownMarkupsRefuse() {
        let stranger = MarkupID(ExportFixture.uuid(999))
        #expect(throws: SnippetExportError.markupsNotFound([stranger])) {
            _ = try SnippetRegionResolver.resolve(
                .markups([stranger], padding: 0),
                page: Self.page(),
                markups: Self.markups(),
                zones: [:]
            )
        }
    }

    @Test("A zone region resolves through the supplied catalogue and refuses when absent")
    func zoneRegion() throws {
        let zone = ZoneID(ExportFixture.uuid(77))
        let bounds = PDFRect(x: 50, y: 60, width: 200, height: 100)
        let resolved = try SnippetRegionResolver.resolve(
            .zone(zone), page: Self.page(), markups: [], zones: [zone: bounds]
        )
        #expect(resolved == bounds)
        #expect(throws: SnippetExportError.zoneNotFound(zone)) {
            _ = try SnippetRegionResolver.resolve(
                .zone(zone), page: Self.page(), markups: [], zones: [:]
            )
        }
    }

    // MARK: - Refusals

    @Test("A scale factor outside 1x...8x is refused before anything is allocated")
    func scaleFactorRefusal() async {
        let spec = Self.spec(region: .rect(PDFRect(x: 0, y: 0, width: 100, height: 100)),
                             caption: .none,
                             scaleFactor: 12)
        await #expect(throws: SnippetExportError.scaleFactorOutOfRange(12)) {
            _ = try await SnippetExporter().render(
                spec: spec,
                page: Self.page(),
                markups: Self.markups(),
                pageSource: ForbiddenPageSource()
            )
        }
    }

    @Test("The pixel budget refusal reports the dimensions and fires before rasterising")
    func pixelBudgetRefusal() async throws {
        // An 8x request on a full A1 sheet: 2384 x 1684 points -> 19 072 x 13 472 pixels,
        // over the 16 384-pixel edge budget shared with the renderer.
        let a1 = PDFRect(x: 0, y: 0, width: 2384, height: 1684)
        let page = PageDescriptor(
            id: PageID(ExportFixture.uuid(-3)),
            documentID: DocumentID(ExportFixture.uuid(-1)),
            index: 0,
            label: "A1",
            boxes: PageBoxes(media: a1, crop: a1)
        )
        let spec = Self.spec(region: .rect(a1), caption: .none, scaleFactor: 8)
        do {
            _ = try await SnippetExporter().render(
                spec: spec, page: page, markups: [], pageSource: ForbiddenPageSource()
            )
            Issue.record("an 8x A1 snippet was not refused")
        } catch let error as SnippetExportError {
            guard case let .pixelBudgetExceeded(width, height, maximumEdge) = error else {
                Issue.record("wrong refusal: \(error)")
                return
            }
            #expect(width == 19_072)
            #expect(height == 13_472)
            #expect(maximumEdge == RenderLimits.maximumTargetPixels)
        }
    }

    @Test("A captioned snippet without a projection is refused, never silently uncaptioned")
    func captionRequiresProjection() async {
        let spec = Self.spec(region: .rect(PDFRect(x: 0, y: 0, width: 100, height: 100)))
        await #expect(throws: SnippetExportError.captionRequiresProjection) {
            _ = try await SnippetExporter().render(
                spec: spec,
                page: Self.page(),
                markups: Self.markups(),
                pageSource: PatternPageSource()
            )
        }
    }

    // MARK: - Zoom invariance

    @Test("The same spec renders byte-identical PNGs whatever any viewport did in between")
    func zoomInvariance() async throws {
        let markups = Self.markups()
        let ids = [markups[0].id, markups[2].id]
        let spec = Self.spec(region: .markups(ids, padding: 20))
        let projection = try Self.projection()
        let exporter = SnippetExporter()
        let page = Self.page()

        let first = try await exporter.render(
            spec: spec,
            page: page,
            markups: markups,
            projection: projection,
            pageSource: PatternPageSource()
        )

        // Simulate the app doing viewport work between the two exports: pan, deep zoom,
        // fit-to-page, on a live renderer holding the same scene.
        let canvas = CoreGraphicsMarkupRenderer()
        defer { canvas.dispose() }
        for zoom in [0.37, 5.0, 1.0, 0.05] {
            let viewport = RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: 2)
            canvas.update(
                page: page, markups: markups, selection: .empty,
                snapFeedback: nil, viewport: viewport
            )
            _ = try canvas.renderOffscreen()
        }

        // And hand the exporter the same markups in a different array order.
        let second = try await exporter.render(
            spec: spec,
            page: page,
            markups: markups.reversed(),
            projection: projection,
            pageSource: PatternPageSource()
        )

        #expect(first.pixelWidth == second.pixelWidth)
        #expect(first.pixelHeight == second.pixelHeight)
        #expect(first.image.pixels == second.image.pixels, "composited pixels differ")
        #expect(try first.pngData() == second.pngData(), "PNG bytes differ")
        #expect(first.caption.text == second.caption.text)
    }

    // MARK: - Caption lineage

    @Test("The caption quotes the ledger projection digit for digit, against the CSV")
    func captionMatchesLedger() throws {
        let projection = try Self.projection()
        let markups = Self.markups()
        let ids = [markups[0].id, markups[1].id]
        let caption = SnippetCaptionBuilder.build(
            detail: .compact,
            markupIDs: ids,
            projection: projection,
            source: Self.spec(region: .markups(ids, padding: 0)).source
        )
        #expect(caption.lines.count == 2)

        // Expected values straight from the projection: the first numeric cell of each row.
        let table = projection.table
        let planAreaIndex = try #require(table.columns.firstIndex { $0.key == "planArea" })
        for (line, id) in zip(caption.lines, ids) {
            let row = try #require(table.allRows().first {
                $0.markupID == id.rawValue.uuidString
            })
            let number = try #require(row.cells[planAreaIndex].number)
            #expect(line.hasSuffix(": \(number.text) \(number.unitSymbol)"),
                    "caption line \(line) does not end with \(number.text) \(number.unitSymbol)")
        }

        // And against the CSV file itself: same projection, same digits, same column.
        let csv = try CSVExporter().export(projection)
        let records = CSVReader.records(
            String(decoding: csv, as: UTF8.self), delimiter: ","
        )
        let header = try #require(records.first)
        let planAreaColumn = try #require(header.firstIndex(of: "Plan Area"))
        let labelColumn = try #require(header.firstIndex(of: "label"))
        for (line, id) in zip(caption.lines, ids) {
            let row = try #require(table.allRows().first {
                $0.markupID == id.rawValue.uuidString
            })
            let labelIndex = try #require(table.columns.firstIndex { $0.key == "label" })
            let label = row.cells[labelIndex].text
            let record = try #require(records.dropFirst().first { $0[labelColumn] == label })
            let csvValue = record[planAreaColumn]
            #expect(
                line.contains(": \(csvValue) "),
                "caption \(line) disagrees with CSV value \(csvValue)"
            )
        }
    }

    @Test("The full caption adds provenance: page, drawing, revision, scale, timestamp")
    func fullCaptionProvenance() throws {
        let projection = try Self.projection()
        let markups = Self.markups()
        let caption = SnippetCaptionBuilder.build(
            detail: .full,
            markupIDs: [markups[0].id],
            projection: projection,
            source: Self.spec(region: .markups([markups[0].id], padding: 0)).source,
            options: SnippetCaptionOptions(calibrationDescription: "calibrated from title block")
        )
        let text = caption.text
        #expect(text.contains("Harbour House"))
        #expect(text.contains("A-101 Ground Floor"))
        #expect(text.contains("page A-101"))
        #expect(text.contains("rev C"))
        #expect(text.contains("scale 1:100"))
        #expect(text.contains("calibrated from title block"))
        #expect(text.contains(projection.table.metadata.generatedAt.iso8601))
    }

    // MARK: - Composited output

    @Test("A rendered snippet has the estimated size, a caption band, and page ink under markups")
    func renderedSnippetShape() async throws {
        let markups = Self.markups()
        let ids = [markups[0].id]
        let spec = Self.spec(region: .markups(ids, padding: 15))
        let projection = try Self.projection()
        let exporter = SnippetExporter()

        let snippet = try await exporter.render(
            spec: spec,
            page: Self.page(),
            markups: markups,
            projection: projection,
            pageSource: PatternPageSource()
        )
        #expect(snippet.pixelHeight > snippet.contentPixelHeight, "no caption band")
        #expect(!snippet.caption.isEmpty)
        // Fully opaque everywhere: the page ground is under everything.
        var opaque = true
        for y in 0..<snippet.pixelHeight where opaque {
            for x in 0..<snippet.pixelWidth where snippet.image.alpha(x: x, y: y) < 1 {
                opaque = false
                break
            }
        }
        #expect(opaque, "an export must not have transparent holes")
    }

    @Test("The pasteboard payload carries the PNG and the caption as plain text")
    func pasteboardPayload() async throws {
        let markups = Self.markups()
        let spec = Self.spec(region: .markups([markups[0].id], padding: 10))
        let snippet = try await SnippetExporter().render(
            spec: spec,
            page: Self.page(),
            markups: markups,
            projection: try Self.projection(),
            pageSource: PatternPageSource()
        )
        let payload = try snippet.pasteboardPayload()
        #expect(payload.png == (try snippet.pngData()))
        #expect(payload.plainText == snippet.caption.text)
        #expect(!payload.plainText.isEmpty)

        // `.none` still pastes something true.
        let bare = try await SnippetExporter().render(
            spec: Self.spec(region: .markups([markups[0].id], padding: 10), caption: .none),
            page: Self.page(),
            markups: markups,
            pageSource: PatternPageSource()
        )
        let barePayload = try bare.pasteboardPayload()
        #expect(barePayload.plainText == "Snippet of A-101 Ground Floor, page A-101, rev C")
    }

    // MARK: - PDF variant

    @Test("The PDF variant is a parseable one-page PDF of the same region and caption")
    func pdfVariant() async throws {
        let markups = Self.markups()
        let ids = [markups[0].id, markups[1].id]
        let spec = Self.spec(region: .markups(ids, padding: 20))
        let data = try await SnippetExporter().renderPDF(
            spec: spec,
            page: Self.page(),
            markups: markups,
            projection: try Self.projection(),
            pageSource: PatternPageSource()
        )
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == 1)
        let pdfPage = try #require(document.page(at: 1))
        let box = pdfPage.getBoxRect(.mediaBox)
        // The two markups' union is 100 x 130 page points; padding 20 makes the region
        // 140 x 170. The media box must be the region plus the caption band below it.
        #expect(abs(box.width - 140) < 2, "media box width \(box.width)")
        #expect(box.height > 170, "media box height \(box.height) lacks the caption band")
    }

    @Test("Snippets without the drawing layer refuse a missing page source only when needed")
    func drawingLayerToggle() async throws {
        let markups = Self.markups()
        let spec = Self.spec(
            region: .markups([markups[0].id], padding: 10),
            caption: .none,
            content: SnippetContent(includeDrawing: false)
        )
        // No page source needed when the drawing is excluded.
        let snippet = try await SnippetExporter().render(
            spec: spec, page: Self.page(), markups: markups
        )
        #expect(snippet.pixelWidth > 0)

        // But including the drawing with no source is a typed refusal.
        let withDrawing = Self.spec(
            region: .markups([markups[0].id], padding: 10),
            caption: .none
        )
        do {
            _ = try await SnippetExporter().render(
                spec: withDrawing, page: Self.page(), markups: markups
            )
            Issue.record("a drawing-included snippet rendered without a page source")
        } catch let error as SnippetExportError {
            guard case .pageRasterFailed = error else {
                Issue.record("wrong refusal: \(error)")
                return
            }
        }
    }
}
