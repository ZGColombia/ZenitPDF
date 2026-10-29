import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer

/// The structural half of "vector stays vector", and the count-symbol pipeline.
///
/// `ImportedArtworkZoomTests` measures pictures. This measures the geometry that produced them,
/// which is where the claim actually lives: if enlarging a stamp multiplies coordinates and
/// emits the same primitives, then there is nothing in the pipeline that *could* resample, and
/// no rendering setting can make it blur.
@Suite("Imported artwork scenes")
struct ImportedArtworkSceneTests {

    private static let baseID = MarkupID(
        UUID(uuidString: "B27C0000-0000-4000-8000-000000000001") ?? UUID()
    )

    private static func artwork() -> ArtworkGeometry {
        ArtworkGeometry(
            kind: .vector,
            strokes: [
                ArtworkContour(
                    points: [
                        PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0),
                        PDFPoint(x: 1, y: 1), PDFPoint(x: 0, y: 1)
                    ],
                    isClosed: true,
                    widthFraction: 0.01
                ),
                ArtworkContour(
                    points: [PDFPoint(x: 0.25, y: 0.25), PDFPoint(x: 0.75, y: 0.75)],
                    isClosed: false
                )
            ],
            regions: [ArtworkRegion(outer: [
                PDFPoint(x: 0.3, y: 0.3), PDFPoint(x: 0.7, y: 0.3), PDFPoint(x: 0.7, y: 0.7)
            ])],
            sourceAspectRatio: 1
        )
    }

    @Test("Enlarging the box ten times multiplies coordinates and emits the same primitives")
    func vectorArtworkStaysVector() throws {
        let center = PDFPoint(x: 300, y: 400)
        let small = StampArtworkScene.markups(
            artwork: Self.artwork(),
            center: center,
            size: PDFSize(width: 40, height: 40),
            baseID: Self.baseID
        )
        let large = StampArtworkScene.markups(
            artwork: Self.artwork(),
            center: center,
            size: PDFSize(width: 400, height: 400),
            baseID: Self.baseID
        )
        #expect(small.count == large.count)
        #expect(small.count == 3)

        for (near, far) in zip(small, large) {
            switch (near.shape, far.shape) {
            case let (.polyline(a), .polyline(b)):
                #expect(a.points.count == b.points.count)
                for (p, q) in zip(a.points, b.points) {
                    // Every vertex is exactly ten times as far from the anchor. Not
                    // approximately: an affine map has no rounding in it.
                    #expect(abs((q.x - center.x) - 10 * (p.x - center.x)) < 1e-9)
                    #expect(abs((q.y - center.y) - 10 * (p.y - center.y)) < 1e-9)
                }
            case let (.filledPolygon(a), .filledPolygon(b)):
                #expect(a.outer.count == b.outer.count)
                for (p, q) in zip(a.outer, b.outer) {
                    #expect(abs((q.x - center.x) - 10 * (p.x - center.x)) < 1e-9)
                    #expect(abs((q.y - center.y) - 10 * (p.y - center.y)) < 1e-9)
                }
            default:
                Issue.record("shape kinds diverged between the two sizes")
            }
        }
    }

    @Test("A contour's width fraction becomes a width in points, scaled with the box")
    func strokeWidthsFollowTheBox() {
        let small = StampArtworkScene.markups(
            artwork: Self.artwork(),
            center: PDFPoint(x: 0, y: 0),
            size: PDFSize(width: 100, height: 100),
            style: RenderStyle(lineWidth: 3),
            baseID: Self.baseID
        )
        let widths = small.compactMap { markup -> Double? in
            guard case .polyline = markup.shape else { return nil }
            return markup.style.lineWidth
        }
        // The closed outline declared 0.01 of the box, so 1 point; the diagonal declared
        // nothing, which the contract calls "the renderer's default" — 2 % of the box, as on the
        // canvas — so 2 points, not the style's fixed 3 (BH-632).
        #expect(widths.contains { abs($0 - 1.0) < 1e-9 })
        #expect(widths.contains { abs($0 - 2.0) < 1e-9 })
        #expect(!widths.contains { abs($0 - 3.0) < 1e-9 })
    }

    @Test("A mosaic cell paints itself; a compiled PDF page takes the markup's colour")
    func regionColoursAreHonoured() {
        let cell = RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let raster = ArtworkGeometry(
            kind: .raster,
            regions: [
                ArtworkRegion(outer: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1)
                ], color: cell)
            ]
        )
        let drawn = StampArtworkScene.markups(
            artwork: raster,
            center: PDFPoint(x: 0, y: 0),
            size: PDFSize(width: 10, height: 10),
            style: RenderStyle(stroke: .opaqueBlack, fill: nil),
            baseID: Self.baseID
        )
        #expect(drawn.count == 1)
        #expect(drawn[0].style.fill == cell)
        // A one-pixel outline on every cell would double the ink and turn a picture into a grid.
        #expect(drawn[0].style.stroke == nil)

        let vector = StampArtworkScene.markups(
            artwork: Self.artwork(),
            center: PDFPoint(x: 0, y: 0),
            size: PDFSize(width: 10, height: 10),
            style: RenderStyle(stroke: .opaqueBlack, fill: SceneFill.value),
            baseID: Self.baseID
        )
        let fills = vector.compactMap { markup -> RGBAColor? in
            guard case .filledPolygon = markup.shape else { return nil }
            return markup.style.fill
        }
        #expect(fills == [SceneFill.value])
    }

    private enum SceneFill {
        static let value = RGBAColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1)
    }

    // MARK: - Count symbols ride the same pipeline

    @Test("A count mark with imported artwork is drawn as that artwork, aspect preserved")
    func countSymbolUsesImportedArtwork() {
        var wide = Self.artwork()
        wide.sourceAspectRatio = 2
        let drawn = StampArtworkScene.markups(
            symbol: MarkupSymbol(
                artworkDigest: String(repeating: "d", count: 64), kind: .vector, sizePoints: 40
            ),
            artwork: wide,
            center: PDFPoint(x: 100, y: 100),
            baseID: Self.baseID
        )
        #expect(drawn.count == 3)
        #expect(drawn.allSatisfy { if case .countSymbol = $0.shape { false } else { true } })

        // Aspect 2 in a 40-point square is 40 wide and 20 tall, not 40 by 40. An oval company
        // mark placed a thousand times is a thousand wrong marks.
        let size = StampArtworkScene.fittedSize(aspectRatio: 2, inSquareOf: 40)
        #expect(size.width == 40)
        #expect(size.height == 20)
        #expect(StampArtworkScene.fittedSize(aspectRatio: 0.5, inSquareOf: 40).width == 20)
        #expect(StampArtworkScene.fittedSize(aspectRatio: .nan, inSquareOf: 40).width == 40)
    }

    @Test("A count mark whose artwork is missing still draws, at its own size and place")
    func countSymbolFallsBackVisibly() {
        let drawn = StampArtworkScene.markups(
            symbol: MarkupSymbol(
                artworkDigest: String(repeating: "e", count: 64), kind: .vector, sizePoints: 18
            ),
            artwork: nil,
            center: PDFPoint(x: 50, y: 60),
            baseID: Self.baseID
        )
        #expect(drawn.count == 1)
        guard case let .countSymbol(mark) = drawn[0].shape else {
            Issue.record("expected a fallback glyph")
            return
        }
        #expect(mark.symbol == .filledCircle)
        #expect(mark.size == 18)
        #expect(mark.center == PDFPoint(x: 50, y: 60))
    }

    @Test("A built-in glyph is named, not numbered, and an unknown name is not a crash")
    func builtInGlyphsRoundTripByName() {
        for glyph in CountSymbol.allCases {
            #expect(CountSymbol(name: glyph.name) == glyph)
            let drawn = StampArtworkScene.markups(
                symbol: MarkupSymbol.builtIn(glyph.name, sizePoints: 14),
                artwork: nil,
                center: PDFPoint(x: 0, y: 0),
                baseID: Self.baseID
            )
            guard case let .countSymbol(mark) = drawn[0].shape else {
                Issue.record("\(glyph.name) did not draw as a glyph")
                continue
            }
            #expect(mark.symbol == glyph)
        }
        #expect(CountSymbol(name: "notAGlyphThisBuildKnows") == nil)
        let unknown = StampArtworkScene.markups(
            symbol: MarkupSymbol.builtIn("notAGlyphThisBuildKnows"),
            artwork: nil,
            center: PDFPoint(x: 0, y: 0),
            baseID: Self.baseID
        )
        guard case let .countSymbol(mark) = unknown[0].shape else {
            Issue.record("an unknown glyph name produced no mark at all")
            return
        }
        #expect(mark.symbol == .filledCircle)
    }

    @Test("A symbol with an unusable size is drawn at a legible default, never at zero")
    func unusableSizesFallBack() {
        for bad in [0.0, Double.nan, Double.infinity, -5, 1_000_000] {
            let drawn = StampArtworkScene.markups(
                symbol: MarkupSymbol.builtIn("plus", sizePoints: bad),
                artwork: nil,
                center: PDFPoint(x: 0, y: 0),
                baseID: Self.baseID
            )
            guard case let .countSymbol(mark) = drawn[0].shape else {
                Issue.record("no mark for size \(bad)")
                continue
            }
            #expect(mark.size == 12)
        }
    }
}
