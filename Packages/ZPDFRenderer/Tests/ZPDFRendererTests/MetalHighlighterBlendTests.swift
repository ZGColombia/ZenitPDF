import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// K-07: the Metal renderer paints a highlighter (`RenderStyle.blendMode = .multiply`)
/// multiplied, exactly as the Core Graphics backend — and so the canvas and every export —
/// already did.
///
/// Old output: `MetalMarkupRenderer` ignored `CompiledMarkup.multiplies` and drew every markup
/// source-over, so opaque yellow highlighter ink over a black fill came out yellow
/// (255, 255, 0) on the GPU while the Core Graphics oracle drew it black (0, 0, 0).
@Suite("Metal highlighter blend (K-07)", .serialized)
struct MetalHighlighterBlendTests {

    private static let page = SceneIdentity.page()

    private static func id(_ n: UInt8) -> MarkupID {
        MarkupID(UUID(uuid: (0xB1, 0xE7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)))
    }

    private static func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RenderPolygon {
        RenderPolygon(outer: [
            PDFPoint(x: x, y: y), PDFPoint(x: x + width, y: y),
            PDFPoint(x: x + width, y: y + height), PDFPoint(x: x, y: y + height)
        ])
    }

    private static let yellow = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)

    /// A 100 × 100 px window onto the top-left corner of the page (page y 692…792), so pixel
    /// `(x, y)` is page `(x, 792 − y)`.
    ///
    /// - z 0: a black fill over pixels x 0…50 (all rows).
    /// - z 1: a yellow **multiply** fill over pixels x 25…75, y 25…75.
    /// - z 2: a blue normal fill over pixels x 60…90, y 40…50, painted after the highlighter.
    /// - z 3: a yellow **multiply** stroke along pixel row 90, x 5…95, 6 pt wide.
    private static func markups(highlight: Bool) -> [RenderableMarkup] {
        func fill(_ color: RGBAColor, multiply: Bool = false) -> RenderStyle {
            var style = RenderStyle(stroke: nil, fill: color)
            if multiply && highlight { style.blendMode = .multiply }
            return style
        }
        var strokeStyle = RenderStyle(stroke: yellow, fill: nil, lineWidth: 6)
        if highlight { strokeStyle.blendMode = .multiply }
        // A style change is a new revision, or the renderer keeps the compiled slot.
        let revision: UInt64 = highlight ? 2 : 1
        return [
            RenderableMarkup(id: id(1), revision: revision, zIndex: 0, shape: .filledPolygon(rectangle(0, 692, 50, 100)),
                             style: fill(RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))),
            RenderableMarkup(id: id(2), revision: revision, zIndex: 1, shape: .filledPolygon(rectangle(25, 717, 50, 50)),
                             style: fill(yellow, multiply: true)),
            RenderableMarkup(id: id(3), revision: revision, zIndex: 2, shape: .filledPolygon(rectangle(60, 742, 30, 10)),
                             style: fill(RGBAColor(red: 0, green: 0, blue: 1, alpha: 1))),
            RenderableMarkup(id: id(4), revision: revision, zIndex: 3, shape: .polyline(RenderPolyline(points: [
                PDFPoint(x: 5, y: 702), PDFPoint(x: 95, y: 702)
            ])), style: strokeStyle)
        ]
    }

    private static func render(
        _ renderer: any OffscreenMarkupRendering,
        highlight: Bool
    ) throws -> RasterImage {
        let viewport = try #require(RenderViewport.window(
            page, zoom: 1, backingScale: 1, pageRect: PDFRect(x: 0, y: 692, width: 100, height: 100)
        ))
        renderer.update(page: page, markups: markups(highlight: highlight), selection: .empty,
                        snapFeedback: nil, viewport: viewport)
        return try renderer.renderOffscreen()
    }

    private static func expectPixel(
        _ image: RasterImage, _ x: Int, _ y: Int, _ expected: (Int, Int, Int, Int), _ label: String
    ) {
        let pixel = image.pixel(x: x, y: y)
        let actual = (Int(pixel.0), Int(pixel.1), Int(pixel.2), Int(pixel.3))
        let close = abs(actual.0 - expected.0) <= 3 && abs(actual.1 - expected.1) <= 3
            && abs(actual.2 - expected.2) <= 3 && abs(actual.3 - expected.3) <= 3
        #expect(close, "\(label) at (\(x), \(y)): \(actual), expected \(expected)")
    }

    @Test("Metal multiplies a highlighter like Core Graphics: black stays black, bare paper takes the ink")
    func metalMultipliesLikeCoreGraphics() throws {
        let metal = try MetalMarkupRenderer()
        defer { metal.dispose() }
        let reference = CoreGraphicsMarkupRenderer()
        defer { reference.dispose() }
        let gpu = try Self.render(metal, highlight: true)
        let oracle = try Self.render(reference, highlight: true)

        for (name, image) in [("metal", gpu), ("core graphics", oracle)] {
            // By hand, premultiplied multiply = Cs·(1 − αd) + Cd·(1 − αs) + Cs·Cd.
            // Yellow (1, 1, 0, 1) over opaque black (0, 0, 0, 1): 0 + 0 + 0 = black. Old Metal
            // output: (255, 255, 0, 255), the highlighter covering the fill.
            Self.expectPixel(image, 40, 50, (0, 0, 0, 255), "\(name): highlighter fill over black")
            // Over a transparent target the first term is the ink itself: yellow.
            Self.expectPixel(image, 70, 30, (255, 255, 0, 255), "\(name): highlighter fill over nothing")
            // Painter's order survives the switch of pipelines: the blue fill drawn after the
            // highlighter covers it (a multiply over blue would read (0, 0, 0)).
            Self.expectPixel(image, 65, 45, (0, 0, 255, 255), "\(name): normal fill after the highlighter")
            // The stroke pipeline multiplies too.
            Self.expectPixel(image, 20, 90, (0, 0, 0, 255), "\(name): highlighter stroke over black")
            Self.expectPixel(image, 80, 90, (255, 255, 0, 255), "\(name): highlighter stroke over nothing")
        }
        let comparison = ImageComparator.compare(gpu, oracle)
        #expect(comparison.matches, "\(comparison.failureReasons)")
    }

    @Test("A scene without a highlighter keeps one draw per category; a highlighter adds only its own runs")
    func drawCountsOnlyGrowForHighlighters() throws {
        let metal = try MetalMarkupRenderer()
        defer { metal.dispose() }
        _ = try Self.render(metal, highlight: false)
        // Fills in one draw, strokes in one draw.
        #expect(metal.statistics.drawCallCount == 2)
        _ = try Self.render(metal, highlight: true)
        // Fills: normal (black), multiply (yellow), normal (blue) = three runs. Strokes: the one
        // multiply run.
        #expect(metal.statistics.drawCallCount == 4)
        _ = try Self.render(metal, highlight: false)
        #expect(metal.statistics.drawCallCount == 2)
    }
}
