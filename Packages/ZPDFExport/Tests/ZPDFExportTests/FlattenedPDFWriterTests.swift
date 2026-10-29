import CoreGraphics
import CryptoKit
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// The flatten path, verified by **reading the produced PDF back**.
///
/// Every assertion below opens the bytes that were written, decodes the page content stream and
/// looks for the markup's own page-space geometry in it. Nothing here trusts a return value: the
/// defect this whole path exists to close — printing that dropped every markup — was a code path
/// that returned success on every call it made.
@Suite(.sharedHeap)
struct FlattenedPDFWriterTests {

    // MARK: - Fixtures

    /// A 400 x 300 page whose crop box is offset from the media box, so a writer that confused
    /// the two would be caught rather than accidentally right.
    static func page(
        index: Int = 0,
        width: Double = 400,
        height: Double = 300,
        rotation: PageRotation = .degrees0,
        cropOrigin: PDFPoint = PDFPoint(x: 10, y: 20)
    ) -> PageDescriptor {
        PageDescriptor(
            id: PageID(UUID()),
            documentID: DocumentID(UUID()),
            index: index,
            label: "\(index + 1)",
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: width + cropOrigin.x * 2, height: height + cropOrigin.y * 2),
                crop: PDFRect(x: cropOrigin.x, y: cropOrigin.y, width: width, height: height)
            ),
            rotation: rotation
        )
    }

    /// A diagonal open polyline. Pure strokes, so it can carry the "still vector" assertion.
    static func polyline(
        id: UUID = UUID(),
        from start: PDFPoint,
        to end: PDFPoint
    ) -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(id),
            zIndex: 0,
            shape: .polyline(RenderPolyline(points: [start, end], isClosed: false)),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0.6, blue: 0.9, alpha: 1), lineWidth: 2)
        )
    }

    static func filledTriangle(id: UUID = UUID(), at origin: PDFPoint, size: Double) -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(id),
            zIndex: 1,
            shape: .filledPolygon(RenderPolygon(outer: [
                origin,
                PDFPoint(x: origin.x + size, y: origin.y),
                PDFPoint(x: origin.x + size / 2, y: origin.y + size)
            ])),
            style: RenderStyle(
                stroke: RGBAColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1),
                fill: RGBAColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.4),
                lineWidth: 1.5
            )
        )
    }

    static func dimension(from start: PDFPoint, to end: PDFPoint, label: String) -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(UUID()),
            zIndex: 2,
            shape: .dimensionLine(RenderDimensionLine(start: start, end: end, label: label)),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), lineWidth: 1)
        )
    }

    static func countSymbol(at centre: PDFPoint) -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(UUID()),
            zIndex: 3,
            shape: .countSymbol(RenderCountSymbol(center: centre, symbol: .filledSquare, size: 12)),
            style: RenderStyle(
                stroke: RGBAColor(red: 0.1, green: 0.5, blue: 0.1, alpha: 1),
                fill: RGBAColor(red: 0.1, green: 0.5, blue: 0.1, alpha: 1),
                lineWidth: 1
            )
        )
    }

    /// Page space to sheet space: the crop box's lower-left corner is the sheet's origin.
    static func onSheet(_ point: PDFPoint, page: PageDescriptor) -> CGPoint {
        let box = page.visibleBox
        return CGPoint(x: point.x - box.minX, y: point.y - box.minY)
    }

    // MARK: - The markup reaches the paper

    @Test("A flattened page carries its markups' geometry in the output's content stream")
    func markupGeometryIsInTheOutput() throws {
        let page = Self.page()
        let start = PDFPoint(x: 60, y: 80)
        let end = PDFPoint(x: 300, y: 250)
        let job = FlattenPage(
            page: page,
            sourcePageIndex: 0,
            markups: [Self.polyline(from: start, to: end)]
        )
        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [job],
            content: nil
        )
        let inspector = try #require(PDFContentStreamInspector(data: data))
        #expect(inspector.pages.count == 1)
        let output = inspector.pages[0]

        // The two measured endpoints, in the sheet's own coordinates.
        #expect(PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(start, page: page)
        ))
        #expect(PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(end, page: page)
        ))
    }

    @Test("A dimension line prints its arrowheads, its extension ticks and its pill")
    func dimensionGrammarSurvivesFlattening() throws {
        let page = Self.page()
        let start = PDFPoint(x: 50, y: 100)
        let end = PDFPoint(x: 350, y: 100)
        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(
                page: page,
                sourcePageIndex: 0,
                markups: [Self.dimension(from: start, to: end, label: "14,72 m")]
            )],
            content: nil
        )
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]

        // Arrow tips are the measured points, exactly — the grammar's own contract.
        #expect(PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(start, page: page)
        ))
        #expect(PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(end, page: page)
        ))
        // The extension tick through the first measured point: perpendicular, 9 view points
        // long, so its ends are 4.5 above and below at zoom 1.
        let tickTop = Self.onSheet(PDFPoint(x: start.x, y: start.y + 4.5), page: page)
        let tickBottom = Self.onSheet(PDFPoint(x: start.x, y: start.y - 4.5), page: page)
        #expect(PDFContentStreamInspector.contains(output.pathPoints, tickTop))
        #expect(PDFContentStreamInspector.contains(output.pathPoints, tickBottom))
        // The pill is filled geometry around the midpoint, and its glyphs are atlas tiles, so
        // the sheet has both fills and images on it.
        #expect(output.paintOperators.contains("f"))
    }

    @Test("A count symbol reaches the paper")
    func countSymbolsReachThePaper() throws {
        let page = Self.page()
        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(
                page: page,
                sourcePageIndex: 0,
                markups: [Self.countSymbol(at: PDFPoint(x: 200, y: 150))]
            )],
            content: nil
        )
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        // A symbol is an atlas tile clipped and filled: the proof it is on the sheet is that
        // the page's content stream now paints something other than the white ground.
        #expect(output.paintOperators.count > 1 || output.xObjectInvocations > 0
            || output.inlineImages > 0)
        #expect(output.stream.count > 64)
    }

    // MARK: - printable == false

    @Test("A markup left out of the page is absent from the output, and the rest are not")
    func nonPrintableMarkupsAreAbsent() throws {
        let page = Self.page()
        let printedStart = PDFPoint(x: 40, y: 40)
        let printedEnd = PDFPoint(x: 120, y: 90)
        let suppressedStart = PDFPoint(x: 260, y: 210)
        let suppressedEnd = PDFPoint(x: 330, y: 260)

        // The rule itself. One function decides it for print and for every export shape.
        #expect(PDFFlattenPolicy.isOnPaper(hidden: false, printable: true))
        #expect(!PDFFlattenPolicy.isOnPaper(hidden: false, printable: false))
        #expect(!PDFFlattenPolicy.isOnPaper(hidden: true, printable: true))
        #expect(!PDFFlattenPolicy.isOnPaper(hidden: true, printable: false))

        let all = [
            (Self.polyline(from: printedStart, to: printedEnd), true),
            (Self.polyline(from: suppressedStart, to: suppressedEnd), false)
        ]
        let kept = all
            .filter { PDFFlattenPolicy.isOnPaper(hidden: false, printable: $0.1) }
            .map(\.0)
        #expect(kept.count == 1)

        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: kept)],
            content: nil
        )
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        #expect(PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(printedStart, page: page)
        ))
        #expect(PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(printedEnd, page: page)
        ))
        #expect(!PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(suppressedStart, page: page)
        ))
        #expect(!PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(suppressedEnd, page: page)
        ))
    }

    @Test("The clean shape paints no markup even when the page carries them")
    func cleanShapePaintsNothing() throws {
        let page = Self.page()
        let start = PDFPoint(x: 60, y: 80)
        let end = PDFPoint(x: 300, y: 250)
        let job = FlattenPage(
            page: page,
            sourcePageIndex: 0,
            markups: [Self.polyline(from: start, to: end), Self.countSymbol(at: PDFPoint(x: 200, y: 150))]
        )
        let data = try FlattenedPDFWriter().data(shape: .clean, pages: [job], content: nil)
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        #expect(!PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(start, page: page)
        ))
        #expect(!PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(end, page: page)
        ))
        #expect(output.inlineImages == 0)
        #expect(!PDFExportShape.clean.includesMarkups)
        #expect(!PDFExportShape.annotated.includesMarkups)
        #expect(PDFExportShape.flattened.includesMarkups)
    }

    // MARK: - Vector

    @Test("A stroked markup leaves as path operators, not as a sampled image")
    func markupsStayVector() throws {
        let page = Self.page()
        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(
                page: page,
                sourcePageIndex: 0,
                markups: [
                    Self.polyline(from: PDFPoint(x: 40, y: 40), to: PDFPoint(x: 340, y: 240)),
                    Self.filledTriangle(at: PDFPoint(x: 120, y: 60), size: 80)
                ]
            )],
            content: nil
        )
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        #expect(output.paintOperators.contains("S"))
        #expect(output.paintOperators.contains("f"))
        // No image was needed for geometry made only of strokes and fills.
        #expect(output.inlineImages == 0)
        #expect(output.xObjectInvocations == 0)
    }

    // MARK: - Page size, orientation, scale

    @Test("Each page keeps its own size, and a rotated page keeps its orientation")
    func pageSizeAndOrientationArePreserved() throws {
        let portrait = Self.page(index: 0, width: 400, height: 300)
        let landscape = Self.page(index: 1, width: 400, height: 300, rotation: .degrees90)
        let wide = Self.page(index: 2, width: 842, height: 595)

        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [portrait, landscape, wide].enumerated().map { index, page in
                FlattenPage(
                    page: page,
                    sourcePageIndex: index,
                    markups: [Self.polyline(
                        from: PDFPoint(x: page.visibleBox.minX + 20, y: page.visibleBox.minY + 20),
                        to: PDFPoint(x: page.visibleBox.minX + 60, y: page.visibleBox.minY + 60)
                    )]
                )
            },
            content: nil
        )
        let inspector = try #require(PDFContentStreamInspector(data: data))
        #expect(inspector.pages.count == 3)
        #expect(inspector.pages[0].mediaBox.size == CGSize(width: 400, height: 300))
        // `/Rotate 90` swaps the sheet: the flattened copy is drawn the way it is read.
        #expect(inspector.pages[1].mediaBox.size == CGSize(width: 300, height: 400))
        #expect(inspector.pages[2].mediaBox.size == CGSize(width: 842, height: 595))
    }

    @Test("One PDF point in is one PDF point out: a known span keeps its length")
    func scaleIsPreserved() throws {
        let page = Self.page(width: 500, height: 400)
        let start = PDFPoint(x: 100, y: 200)
        let end = PDFPoint(x: 400, y: 200)
        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: [
                Self.polyline(from: start, to: end)
            ])],
            content: nil
        )
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        let a = Self.onSheet(start, page: page)
        let b = Self.onSheet(end, page: page)
        #expect(PDFContentStreamInspector.contains(output.pathPoints, a))
        #expect(PDFContentStreamInspector.contains(output.pathPoints, b))
        // 300 page points measured on the sheet, not 300 x anything.
        #expect(abs(Double(b.x - a.x) - 300) < 0.01)
    }

    @Test("A rotated page puts its markup where the reader sees it")
    func rotatedPagePlacesMarkupsCorrectly() throws {
        // On a `/Rotate 90` page the sheet is the crop box turned a quarter turn, so a point
        // near the crop box's lower-left corner appears near the sheet's *upper* left.
        let page = Self.page(width: 400, height: 300, rotation: .degrees90)
        let corner = PDFPoint(x: page.visibleBox.minX + 30, y: page.visibleBox.minY + 40)
        let other = PDFPoint(x: page.visibleBox.minX + 30, y: page.visibleBox.minY + 140)
        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: [
                Self.polyline(from: corner, to: other)
            ])],
            content: nil
        )
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        #expect(output.mediaBox.size == CGSize(width: 300, height: 400))
        // The white ground is a rectangle over the whole sheet; its four corners are the only
        // other path points on the page, so removing them leaves the markup and nothing else.
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0),
            CGPoint(x: 300, y: 400), CGPoint(x: 0, y: 400)
        ]
        let ink = output.pathPoints.filter { point in
            !corners.contains { abs(Double($0.x - point.x)) < 0.5 && abs(Double($0.y - point.y)) < 0.5 }
        }
        #expect(ink.count == 2)
        // Both endpoints land on the sheet — a quarter turn applied in the wrong sense puts
        // them off it — and the 100-point span survives the turn.
        for point in ink {
            #expect(point.x >= 0 && point.x <= 300)
            #expect(point.y >= 0 && point.y <= 400)
        }
        if ink.count == 2 {
            let span = Double(hypot(ink[1].x - ink[0].x, ink[1].y - ink[0].y))
            #expect(abs(span - 100) < 0.5)
        }
    }

    // MARK: - The original is never touched

    @Test("Flattening does not modify the drawing it was made from")
    func theOriginalIsNeverModified() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-flatten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A real one-page PDF to flatten over, written with Core Graphics so the test needs no
        // fixture on disk.
        let sourceURL = directory.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let sourceContext = try #require(CGContext(sourceURL as CFURL, mediaBox: &box, nil))
        sourceContext.beginPDFPage(nil)
        sourceContext.setFillColor(gray: 0.85, alpha: 1)
        sourceContext.fill(CGRect(x: 50, y: 50, width: 120, height: 90))
        sourceContext.endPDFPage()
        sourceContext.closePDF()

        let before = try Self.digest(of: sourceURL)
        let source = try #require(CGPDFPageContentSource(url: sourceURL))

        let page = Self.page(width: 400, height: 300, cropOrigin: PDFPoint(x: 0, y: 0))
        let destination = directory.appendingPathComponent("flattened.pdf")
        try FlattenedPDFWriter().write(
            shape: .flattened,
            pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: [
                Self.polyline(from: PDFPoint(x: 20, y: 20), to: PDFPoint(x: 380, y: 280))
            ])],
            content: source,
            to: destination,
            protecting: [sourceURL]
        )

        let after = try Self.digest(of: sourceURL)
        #expect(before == after)

        // And the output carries both layers: the source's grey rectangle, and the markup.
        let output = try #require(
            PDFContentStreamInspector(data: try Data(contentsOf: destination))
        ).pages[0]
        #expect(output.mediaBox.size == CGSize(width: 400, height: 300))
        #expect(PDFContentStreamInspector.contains(
            output.pathPoints, CGPoint(x: 20, y: 20)
        ))
        // The underlay is the original's own operators, replayed as a form — not a raster.
        #expect(output.inlineImages == 0)
    }

    @Test("Writing onto the drawing being exported is refused")
    func writingOntoTheSourceIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-flatten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try Data("not a pdf".utf8).write(to: sourceURL)

        let page = Self.page()
        #expect(throws: PDFFlattenError.self) {
            try FlattenedPDFWriter().write(
                shape: .flattened,
                pages: [FlattenPage(page: page, sourcePageIndex: 0, markups: [])],
                content: nil,
                to: sourceURL,
                protecting: [sourceURL]
            )
        }
        #expect(try Data(contentsOf: sourceURL) == Data("not a pdf".utf8))
    }

    // MARK: - Refusals

    @Test("An empty job is refused rather than producing a zero-page PDF")
    func emptyJobIsRefused() {
        #expect(throws: PDFFlattenError.noPages) {
            _ = try FlattenedPDFWriter().data(shape: .flattened, pages: [], content: nil)
        }
    }

    @Test("An unopenable file yields no content source rather than a half-drawn export")
    func unopenableSourceYieldsNil() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-flatten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.pdf")
        try Data(repeating: 0x41, count: 512).write(to: url)
        #expect(CGPDFPageContentSource(url: url) == nil)
    }

    @Test("A page whose underlay is missing still prints its markups")
    func missingUnderlayStillPrintsMarkups() throws {
        let page = Self.page()
        let start = PDFPoint(x: 70, y: 70)
        let data = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(page: page, sourcePageIndex: 7, markups: [
                Self.polyline(from: start, to: PDFPoint(x: 200, y: 200))
            ])],
            // A source that has nothing for page 7.
            content: NoUnderlay()
        )
        let output = try #require(PDFContentStreamInspector(data: data)).pages[0]
        #expect(PDFContentStreamInspector.contains(
            output.pathPoints, Self.onSheet(start, page: page)
        ))
    }

    // MARK: - Support

    /// An underlay source with nothing for any page: the white sheet a missing raster gives.
    final class NoUnderlay: FlattenPageContentDrawing {
        func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect) -> Bool { false }
    }

    static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
