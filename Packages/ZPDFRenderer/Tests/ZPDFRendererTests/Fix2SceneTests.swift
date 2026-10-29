import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// Bug hunt 2: imported artwork and stamp scenes.
@Suite("Fix2 artwork scenes", .serialized)
struct Fix2SceneTests {

    private static let baseID = MarkupID(
        UUID(uuidString: "F2F2A000-0000-4000-8000-000000000001") ?? UUID()
    )
    private static let ink = RGBAColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)

    private static func square(_ inset: Double = 0) -> [PDFPoint] {
        [
            PDFPoint(x: inset, y: inset), PDFPoint(x: 1 - inset, y: inset),
            PDFPoint(x: 1 - inset, y: 1 - inset), PDFPoint(x: inset, y: 1 - inset)
        ]
    }

    private static func extent(_ points: [PDFPoint]) -> (width: Double, height: Double) {
        let xs = points.map(\.x), ys = points.map(\.y)
        return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    @Test("BH-032: a colourless region with a stroke-only style is filled with the ink, not outlined")
    func colourlessRegionIsFilled() {
        let seal = ArtworkGeometry(kind: .vector, regions: [ArtworkRegion(outer: Self.square(0.1))])
        let drawn = StampArtworkScene.markups(
            artwork: seal,
            center: PDFPoint(x: 100, y: 100),
            size: PDFSize(width: 50, height: 50),
            style: RenderStyle(stroke: Self.ink, fill: nil, lineWidth: 1.5),
            baseID: Self.baseID
        )
        #expect(drawn.count == 1)
        // Old output: fill nil, stroke ink — the solid area exported as a hollow 1.5 pt outline.
        #expect(drawn[0].style.fill == Self.ink)
        #expect(drawn[0].style.stroke == nil)
        let compiled = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1)
            .compile(drawn[0])
        #expect((compiled?.triangles.count ?? 0) > 0)
        #expect(compiled?.segments.isEmpty == true)
    }

    @Test("BH-203: stamp artwork is letterboxed by its aspect ratio; labels keep the whole box")
    func stampArtworkIsLetterboxed() {
        let oval = ArtworkGeometry(
            kind: .vector,
            regions: [ArtworkRegion(outer: Self.square())],
            sourceAspectRatio: 1.6
        )
        let label = StampSceneLabel(
            text: "APPROVED",
            normalizedFrame: PDFRect(x: 0, y: 0, width: 1, height: 1),
            anchor: .center
        )
        let drawn = StampArtworkScene.markups(
            artwork: oval,
            labels: [label],
            center: PDFPoint(x: 300, y: 300),
            size: PDFSize(width: 160, height: 160),
            baseID: Self.baseID
        )
        guard case let .filledPolygon(region) = drawn[0].shape else {
            Issue.record("expected the region first")
            return
        }
        let size = Self.extent(region.outer)
        // Old output: 160 × 160 — the oval seal stretched into a circle.
        #expect(abs(size.width - 160) < 1e-9)
        #expect(abs(size.height - 100) < 1e-9)
        guard case let .textLabel(text) = drawn[1].shape else {
            Issue.record("expected the label second")
            return
        }
        #expect(text.anchorPoint == PDFPoint(x: 300, y: 300))
        #expect(abs(text.fontSize - 0.2 * 160) < 1e-9, "the label's font follows the whole box")
    }

    @Test("BH-632: an undeclared contour width is 2 % of the box, as on the canvas")
    func undeclaredContourWidthScales() {
        let artwork = ArtworkGeometry(
            kind: .vector,
            strokes: [ArtworkContour(points: Self.square(), isClosed: true, widthFraction: 0)]
        )
        let drawn = StampArtworkScene.markups(
            artwork: artwork,
            center: PDFPoint(x: 0, y: 0),
            size: PDFSize(width: 400, height: 400),
            style: RenderStyle(lineWidth: 1.5),
            baseID: Self.baseID
        )
        // Old output: 1.5 — the style's fixed width, not scaled with the 400 pt box.
        #expect(abs(drawn[0].style.lineWidth - 8) < 1e-9)
        let tiny = StampArtworkScene.markups(
            artwork: artwork,
            center: PDFPoint(x: 0, y: 0),
            size: PDFSize(width: 10, height: 10),
            baseID: Self.baseID
        )
        #expect(abs(tiny[0].style.lineWidth - 0.5) < 1e-9, "the floor is half a point")
    }

    @Test("BH-633: a count mark with a non-finite rotation still draws, upright")
    func infiniteRotationStillDraws() {
        var symbol = MarkupSymbol(
            artworkDigest: String(repeating: "a", count: 64), kind: .vector, sizePoints: 20
        )
        symbol.rotationDegrees = .infinity
        let artwork = ArtworkGeometry(kind: .vector, regions: [ArtworkRegion(outer: Self.square(0.2))])
        let drawn = StampArtworkScene.markups(
            symbol: symbol, artwork: artwork, center: PDFPoint(x: 50, y: 50), baseID: Self.baseID
        )
        let compiler = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1)
        // Old output: every placed point NaN, every shape rejected by the compiler.
        #expect(!drawn.isEmpty)
        #expect(drawn.allSatisfy { compiler.compile($0) != nil })
        guard case let .filledPolygon(region) = drawn[0].shape else { return }
        let size = Self.extent(region.outer)
        #expect(abs(size.width - 12) < 1e-9, "the mark keeps its size (20 × 0.6 = 12)")
    }

    @Test("BH-634: the built-in fallback glyph keeps the mark's rotation")
    func fallbackGlyphKeepsRotation() {
        var symbol = MarkupSymbol.builtIn("filledTriangle", sizePoints: 14)
        symbol.rotationDegrees = 90
        let drawn = StampArtworkScene.markups(
            symbol: symbol, artwork: nil, center: PDFPoint(x: 0, y: 0), baseID: Self.baseID
        )
        guard case let .countSymbol(mark) = drawn.first?.shape else {
            Issue.record("expected a glyph")
            return
        }
        // Old output: RenderCountSymbol had no angle, so the glyph exported upright.
        #expect(mark.rotationDegrees == 90)
        let compiled = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1)
            .compile(drawn[0])
        #expect(compiled?.symbols.first?.rotationDegrees == 90)
    }

    /// Ink-weighted centroid of the non-transparent pixels, in pixel coordinates.
    private static func centroid(_ image: RasterImage) -> (x: Double, y: Double, ink: Double) {
        var sx = 0.0, sy = 0.0, total = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let a = image.alpha(x: x, y: y)
                sx += a * Double(x); sy += a * Double(y); total += a
            }
        }
        return total > 0 ? (sx / total, sy / total, total) : (0, 0, 0)
    }

    @Test("BH-634: a turned triangle turns counter-clockwise on the page, identically on both backends")
    func turnedTriangleRendersOnBothBackends() throws {
        let page = SceneIdentity.page()
        let window = PDFRect(x: 280, y: 380, width: 40, height: 40)
        guard let viewport = RenderViewport.window(page, zoom: 4, backingScale: 1, pageRect: window)
        else { Issue.record("no viewport"); return }
        func markup(_ degrees: Double) -> RenderableMarkup {
            RenderableMarkup(
                id: Self.baseID,
                shape: .countSymbol(RenderCountSymbol(
                    center: PDFPoint(x: 300, y: 400), symbol: .filledTriangle, size: 30, rotationDegrees: degrees
                )),
                style: RenderStyle(stroke: .opaqueBlack)
            )
        }
        let cg = CoreGraphicsMarkupRenderer()
        let metal = try MetalMarkupRenderer()
        defer { cg.dispose(); metal.dispose() }
        var images: [RasterImage] = []
        for renderer in [cg, metal] as [any OffscreenMarkupRendering] {
            renderer.update(page: page, markups: [markup(90)], selection: .empty, snapFeedback: nil, viewport: viewport)
            let turned = try renderer.renderOffscreen()
            images.append(turned)
            let c = Self.centroid(turned)
            let middle = Double(turned.width) / 2
            // An upright triangle's ink sits below its centre (the base is heavier); turned a
            // quarter counter-clockwise the apex points left and the base's weight is on the
            // right. Old output: the angle was ignored, centroid x ≈ middle.
            #expect(c.x > middle + 5, "\(renderer.backend): centroid x \(c.x), middle \(middle)")
            #expect(abs(c.y - Double(turned.height) / 2) < 2, "\(renderer.backend): centroid y \(c.y)")
        }
        let comparison = ImageComparator.compare(images[0], images[1])
        #expect(comparison.matches, "\(comparison.failureReasons)")
    }

    @Test("BH-635: a top-anchored field hangs from the top of its frame, a bottom one sits on its foot")
    func labelAnchorsFollowTheVerticalAnchor() {
        func anchorY(_ anchor: TextAnchor) -> Double? {
            let label = StampSceneLabel(
                text: "X",
                normalizedFrame: PDFRect(x: 0, y: 0.5, width: 1, height: 0.5),
                anchor: anchor
            )
            let drawn = StampArtworkScene.markups(
                artwork: StampArtworkGeometry(),
                labels: [label],
                center: PDFPoint(x: 0, y: 0),
                size: PDFSize(width: 100, height: 100),
                baseID: Self.baseID
            )
            guard case let .textLabel(text) = drawn.first?.shape else { return nil }
            return text.anchorPoint.y
        }
        // The frame spans y 0 … 50 in page space around the centre. Old output: 25 for every
        // anchor, so top-anchored text hung into the lower half of its slot.
        #expect(anchorY(.topLeading) == 50)
        #expect(anchorY(.centerLeading) == 25)
        #expect(anchorY(.bottomTrailing) == 0)
    }
}
