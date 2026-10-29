import AppKit
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 2, render-extract-search: an area with a cutout on paper. Snippet, flattened
/// and standard-annotation exports all compose through `SnippetSceneBuilder`, so the builder and
/// the renderer it feeds are where the courtyard is proved clear (S-097) and where the value
/// pill is proved to follow the canvas's placement rule (S-101).
@MainActor
@Suite("Cutouts on paper (iter2 S-097 / S-101)", .appTierSerialised)
struct Iter2SnippetCutoutTests {

    private static func ring(_ x: Double, _ y: Double, _ side: Double) -> [PDFPointValue] {
        [PDFPointValue(x: x, y: y), PDFPointValue(x: x + side, y: y),
         PDFPointValue(x: x + side, y: y + side), PDFPointValue(x: x, y: y + side)]
    }

    /// A 300 pt square area with a 100 pt courtyard in its middle, as `CanvasSceneBuilder` emits
    /// a parent area after `addCutout`: one filled outer ring, then the hole as an unfilled ring.
    private static func courtyard(caption: String? = nil, opacity: Double = 1) -> CanvasMarkupShape {
        CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1),
            strokes: [
                CanvasStroke(points: ring(0, 0, 300), closed: true, filled: true),
                CanvasStroke(points: ring(100, 100, 100), closed: true, filled: false)
            ],
            fill: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1), counts: [], symbol: nil, artwork: nil, stamp: nil,
            bounds: PDFRectValue(x: 0, y: 0, width: 300, height: 300), hidden: false, printable: true,
            caption: caption, kind: .measurement, text: nil, textBox: nil, leaderTarget: nil,
            lineWidth: 1, opacity: opacity, fontSize: 12, lineStyle: .solid, vertices: []
        )
    }

    private static func render(_ markups: [RenderableMarkup]) throws -> RasterImage {
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 300, height: 300),
                             crop: PDFRect(x: 0, y: 0, width: 300, height: 300))
        )
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page, markups: markups, selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        )
        return try renderer.renderOffscreen()
    }

    // MARK: S-097

    @Test("S-097: the courtyard of an area with a cutout stays paper-coloured in an export")
    func courtyardIsNotFilled() throws {
        let markups = SnippetSceneBuilder.renderables(from: [Self.courtyard()], for: .paper)
        let polygons = markups.compactMap { markup -> RenderPolygon? in
            if case let .filledPolygon(polygon) = markup.shape { return polygon }
            return nil
        }
        let area = try #require(polygons.first)
        // Old output: RenderPolygon(outer: 4 points, holes: []) — the courtyard was filled.
        #expect(area.holes.count == 1)
        #expect(area.holes.first == Self.ring(100, 100, 100).map(SnippetSceneBuilder.point(_:)))
        // The filled polygon strokes the hole's outline with its own; no second copy of it.
        let holeLines = markups.filter { markup in
            if case let .polyline(line) = markup.shape { return line.points.count == 4 && line.isClosed }
            return false
        }
        #expect(holeLines.isEmpty, "the hole outline was drawn twice")

        let image = try Self.render(markups)
        // The page and the geometry are symmetric about y = 150, so page (x, 150) is pixel
        // (x, 150) whichever way the raster's rows run.
        // Old output: alpha 255 at the courtyard's centre, the same blue as the measured band.
        #expect(image.pixel(x: 150, y: 150).3 == 0, "courtyard filled: \(image.pixel(x: 150, y: 150))")
        #expect(image.pixel(x: 50, y: 150).3 > 200, "the measured band lost its fill")
        // The hole's outline is still drawn: its left edge at x = 100.
        #expect(image.pixel(x: 100, y: 150).3 > 0, "the cutout's outline vanished")
    }

    @Test("S-097: an area without a cutout is unchanged, and arc contours list every ring")
    func plainAreaAndCurves() throws {
        var plain = Self.courtyard()
        plain.strokes.removeLast()
        let markups = SnippetSceneBuilder.renderables(from: [plain], for: .paper)
        guard case let .filledPolygon(polygon)? = markups.first?.shape else {
            Issue.record("no filled polygon"); return
        }
        #expect(polygon.holes.isEmpty && polygon.curves == nil)

        // One curved hole: the compiler ignores a curve list that misses a contour, so both
        // rings must be listed — the straight outer as lines, the hole from its arc outline.
        var outer = CanvasStroke(points: Self.ring(0, 0, 300), closed: true, filled: true)
        outer.arcOutline = nil
        var hole = CanvasStroke(points: Self.ring(100, 100, 100), closed: true, filled: false)
        hole.arcOutline = PolygonRing(points: Self.ring(100, 100, 100).map(SnippetSceneBuilder.point(_:)),
                                      bulges: [0.4, 0, 0, 0])
        let curves = try #require(SnippetSceneBuilder.contourCurves(outer: outer, holes: [hole]))
        #expect(curves.count == 2)
        #expect(curves[0].start == PDFPoint(x: 0, y: 0))
        #expect(curves[0].elements.count == 3 && curves[0].isClosed)
        #expect(curves[1].elements.contains { if case .cubic = $0 { return true } else { return false } })
    }

    // MARK: S-101

    @Test("S-101: a courtyard's pill leaves the cutout on the canvas's leader, as the canvas draws it")
    func pillAvoidsTheCutoutOnPaper() throws {
        let caption = "Area A: 8.00 m²"
        let markups = SnippetSceneBuilder.renderables(from: [Self.courtyard(caption: caption)], for: .paper)
        let pill = try #require(markups.compactMap { markup -> RenderLabelPill? in
            if case let .labelPill(pill) = markup.shape, pill.text == caption { return pill }
            return nil
        }.first)
        // Hand-derived: the centroid (150, 150) is in the courtyard, so the pill falls back to the
        // bottom vertex (0, 0) (minimum y, ties on the smaller x), an 18 pt leader down to
        // (0, −18), then 2 pt clearance and half the pill's 15 pt height: centre (0, −27.5).
        // Old output: the pill centred at (150, 150), inside the cutout, and no leader.
        #expect(pill.anchorPoint == PDFPoint(x: 0, y: -27.5))
        let leader = markups.contains { markup in
            if case let .polyline(line) = markup.shape {
                return line.points == [PDFPoint(x: 0, y: 0), PDFPoint(x: 0, y: -18)]
            }
            return false
        }
        #expect(leader, "the fallback pill hung below the polygon with no leader")
    }

    /// The page-space rule (renderer) and the view-space rule (canvas) are two copies kept equal
    /// by this test, the discipline the R-157 dimension-grammar test set: mirror every polygon
    /// through y → −y and the two must agree on interior-or-leader, centre and leader.
    @Test("S-101: AreaPillPlacement and the canvas's AreaPillLayout agree, holes included")
    func pagePlacementEqualsCanvasLayout() throws {
        func square(_ x: Double, _ y: Double, _ side: Double) -> [PDFPoint] {
            [PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y),
             PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)]
        }
        let concaveC = [
            PDFPoint(x: 200, y: 192), PDFPoint(x: 440, y: 192), PDFPoint(x: 440, y: 252),
            PDFPoint(x: 260, y: 252), PDFPoint(x: 260, y: 472), PDFPoint(x: 440, y: 472),
            PDFPoint(x: 440, y: 532), PDFPoint(x: 200, y: 532)
        ]
        let cases: [(name: String, outer: [PDFPoint], holes: [[PDFPoint]], interior: Bool)] = [
            ("convex", square(0, 0, 300), [], true),
            ("courtyard", square(0, 0, 300), [square(100, 100, 100)], false),
            ("small hole under the pill", square(0, 0, 300), [square(148, 148, 4)], false),
            ("hole away from the pill", square(0, 0, 300), [square(10, 10, 20)], true),
            ("concave C", concaveC, [], false),
            ("too small", [PDFPoint(x: 100, y: 100), PDFPoint(x: 140, y: 100), PDFPoint(x: 120, y: 130)], [], false),
            // T-067: a slot and a thin shaft crossing the pill box between its corners, with no
            // vertex inside it. Old output of both rules: interior.
            ("slot between the corners", [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0), PDFPoint(x: 200, y: 100), PDFPoint(x: 115, y: 100),
                PDFPoint(x: 115, y: 30), PDFPoint(x: 110, y: 30), PDFPoint(x: 110, y: 100), PDFPoint(x: 0, y: 100)
            ], [], false),
            ("thin shaft through the pill", square(0, 0, 300), [[
                PDFPoint(x: 40, y: 153), PDFPoint(x: 260, y: 153), PDFPoint(x: 260, y: 154), PDFPoint(x: 40, y: 154)
            ]], false)
        ]
        let flip = { (point: PDFPoint) in CGPoint(x: point.x, y: -point.y) }
        for item in cases {
            let page = try #require(AreaPillPlacement.placement(
                polygon: item.outer, holes: item.holes, pillHalfWidth: 40, pillHalfHeight: 7.5
            ))
            let view = try #require(AreaPillLayout.placement(
                polygon: item.outer.map(flip), holes: item.holes.map { $0.map(flip) },
                pillHalfWidth: 40, pillHalfHeight: 7.5
            ))
            #expect(page.isInterior == item.interior, "\(item.name): interior")
            #expect(page.isInterior == view.isInterior, "\(item.name): the two rules disagree")
            #expect(flip(page.center) == view.center, "\(item.name): centre")
            #expect(page.leaderStart.map(flip) == view.leaderStart, "\(item.name): leader start")
            #expect(page.leaderEnd.map(flip) == view.leaderEnd, "\(item.name): leader end")
        }
    }
}
