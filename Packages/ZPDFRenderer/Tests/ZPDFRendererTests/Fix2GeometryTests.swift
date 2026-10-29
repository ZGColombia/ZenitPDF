import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// Bug hunt 2: the compiler, the preparer, the culler, dashes and symbol geometry.
@Suite("Fix2 geometry", .serialized)
struct Fix2GeometryTests {

    private static func id(_ n: UInt8) -> MarkupID {
        MarkupID(UUID(uuid: (0xF2, 0x6E, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)))
    }

    private static let page = SceneIdentity.page()

    private static func square(at x: Double, _ y: Double, side: Double) -> [PDFPoint] {
        [
            PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y),
            PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)
        ]
    }

    // MARK: BH-197

    @Test("BH-197: a hollow triangle drawn below 6 px has a finite, visible outline")
    func tinyHollowTriangleDraws() {
        for size in [3, 4, 5] {
            let bitmap = AlphaBitmap.rasterize(width: 8, height: 8) { context in
                context.setFillColor(gray: 1, alpha: 1)
                context.setStrokeColor(gray: 1, alpha: 1)
                SymbolAtlas.draw(.hollowTriangle, in: CGFloat(size), context: context)
            }
            let ink = bitmap?.coverage.reduce(0) { $0 + Int($1) } ?? 0
            // Old output: `insetBy` returned CGRect.null, the path had infinite coordinates and
            // nothing was painted (ink 0).
            #expect(ink > 0, "size \(size) painted nothing")
        }
    }

    // MARK: BH-198

    @Test("BH-198: a hole with an unusable vertex rejects the markup rather than filling the cutout")
    func corruptHoleRejects() throws {
        let area = RenderableMarkup(
            id: Self.id(1),
            shape: .filledPolygon(RenderPolygon(
                outer: Self.square(at: 100, 100, side: 200),
                holes: [[PDFPoint(x: 150, y: 150), PDFPoint(x: .nan, y: 150), PDFPoint(x: 250, y: 250)]]
            )),
            style: RenderStyle(stroke: nil, fill: .opaqueBlack)
        )
        let compiler = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1)
        // Old output: a compiled polygon whose fill covered the hole.
        #expect(compiler.compile(area) == nil)

        let preparer = ScenePreparer()
        let prepared = try preparer.prepare(
            page: Self.page, markups: [area], selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(Self.page, zoom: 1, backingScale: 1)
        )
        #expect(prepared.statistics.rejectedMarkupCount == 1)

        // A merely degenerate hole (two points) encloses nothing and is still skipped.
        var degenerate = area
        degenerate.shape = .filledPolygon(RenderPolygon(
            outer: Self.square(at: 100, 100, side: 200),
            holes: [[PDFPoint(x: 150, y: 150), PDFPoint(x: 250, y: 250)]]
        ))
        #expect(compiler.compile(degenerate) != nil)
    }

    // MARK: BH-625

    @Test("BH-625: a text label's bounds surround its text, so the selection ring is visible")
    func textLabelBoundsHaveExtent() throws {
        let label = RenderableMarkup(
            id: Self.id(2),
            shape: .textLabel(RenderTextLabel(anchorPoint: PDFPoint(x: 200, y: 500), text: "Room 101", fontSize: 12)),
            style: RenderStyle(stroke: .opaqueBlack)
        )
        let preparer = ScenePreparer()
        let prepared = try preparer.prepare(
            page: Self.page, markups: [label],
            selection: SelectionSnapshot(selectedIDs: [label.id], primaryID: label.id, hoveredID: nil),
            snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(Self.page, zoom: 1, backingScale: 1)
        )
        let box = try #require(prepared.bounds[label.id])
        // Old output: a zero-size box at the anchor (width 0, height 0).
        #expect(box.width > 30, "width \(box.width)")
        #expect(box.height > 8, "height \(box.height)")
        // Top-leading: the text starts at the anchor and hangs below it (page y is up).
        #expect(abs(box.minX - 200) < 2)
        #expect(abs(box.maxY - 500) < 2)
        let handles = OverlayBuilder.handleCenters(of: box)
        #expect(Set(handles.map { "\($0.x),\($0.y)" }).count == handles.count, "handles coincide")
    }

    // MARK: BH-626

    @Test("BH-626: the rejected count describes the scene on every frame, not just the recompiled ones")
    func rejectedCountIsSceneWide() throws {
        var markups: [RenderableMarkup] = (0..<10).map { n in
            RenderableMarkup(
                id: Self.id(UInt8(10 + n)),
                shape: .polyline(RenderPolyline(points: [PDFPoint(x: 10, y: Double(n) * 10), PDFPoint(x: 100, y: Double(n) * 10)]))
            )
        }
        for n in 0..<3 {
            markups[n].shape = .polyline(RenderPolyline(points: [PDFPoint(x: .infinity, y: 0), PDFPoint(x: 1, y: 1)]))
        }
        let preparer = ScenePreparer()
        let viewport = RenderViewport.fittingWholePage(Self.page, zoom: 1, backingScale: 1)
        let first = try preparer.prepare(page: Self.page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
        #expect(first.statistics.markupCount == 7)
        #expect(first.statistics.rejectedMarkupCount == 3)
        var panned = viewport
        panned.layout.anchor = CGPoint(x: -20, y: 5)
        let second = try preparer.prepare(page: Self.page, markups: markups, selection: .empty, snapFeedback: nil, viewport: panned)
        // Old output: 0 — the pan recompiled nothing, so nothing was counted.
        #expect(second.statistics.rejectedMarkupCount == 3)
        // Breaking one more through the incremental path raises the count by exactly one.
        markups[4].revision = 1
        markups[4].shape = .polyline(RenderPolyline(points: [PDFPoint(x: .nan, y: 0), PDFPoint(x: 1, y: 1)]))
        let third = try preparer.prepare(page: Self.page, markups: markups, selection: .empty, snapFeedback: nil, viewport: panned)
        #expect(third.statistics.rejectedMarkupCount == 4)
    }

    // MARK: BH-621

    @Test("BH-621: a short, thick stroke is measured by its ink for the sub-pixel cutoff")
    func thickShortStrokeIsNotSubPixel() throws {
        let dot = RenderableMarkup(
            id: Self.id(3),
            shape: .polyline(RenderPolyline(points: [PDFPoint(x: 300, y: 400), PDFPoint(x: 300.4, y: 400)])),
            style: RenderStyle(stroke: .opaqueBlack, lineWidth: 8, startCap: .round, endCap: .round)
        )
        let preparer = ScenePreparer()
        let prepared = try preparer.prepare(
            page: Self.page, markups: [dot], selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(Self.page, zoom: 1, backingScale: 1)
        )
        // Old output: subPixelMarkupCount 1 — the 0.4 pt centreline was measured, not the 8 pt ink.
        #expect(prepared.statistics.subPixelMarkupCount == 0)
        #expect(prepared.visibility.visibleIndices?.contains(0) ?? true)
    }

    // MARK: BH-623

    @Test("BH-623: a dash cut to four runs is flagged and counted, not changed silently")
    func truncatedDashIsCounted() throws {
        let odd = DashPattern(.pattern(runs: [6, 2, 1], phase: 0))
        #expect(odd.isTruncated)
        #expect(odd.runArray == [6, 2, 1, 6], "the kept runs are the real sequence's first four")
        #expect(!DashPattern(.pattern(runs: [6, 2, 1, 2], phase: 0)).isTruncated)
        #expect(!DashPattern(.pattern(runs: [3], phase: 0)).isTruncated)

        let line = RenderableMarkup(
            id: Self.id(4),
            shape: .polyline(RenderPolyline(points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 200, y: 10)])),
            style: RenderStyle(dash: .pattern(runs: [6, 2, 1], phase: 0))
        )
        let preparer = ScenePreparer()
        let prepared = try preparer.prepare(
            page: Self.page, markups: [line], selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(Self.page, zoom: 1, backingScale: 1)
        )
        // Old output: nothing anywhere said the pattern had been cut.
        #expect(prepared.markups.first?.dashTruncated == true)
        #expect(prepared.statistics.truncatedDashCount == 1)
    }

    // MARK: BH-624

    @Test("BH-624: the near-zero dot idiom keeps its spacing instead of exploding the dash scale")
    func dotRunsAreExemptFromTheFloor() {
        let dotted = DashPattern(.pattern(runs: [0.01, 2.2], phase: 0))
        // Old output: 150 at every zoom (1.5 / 0.01), a dot every 330 px.
        #expect(dotted.deviceScale(pixelsPerPagePoint: 2) == 2)
        #expect(abs(dotted.deviceScale(pixelsPerPagePoint: 0.1) - DashPattern.minimumRunPixels / 2.2) < 1e-12)
        // PDF's literal `[0 2] 0 d` stays a dotted line rather than becoming a 2/2 dash.
        let zero = DashPattern(.pattern(runs: [0, 2], phase: 0))
        #expect(zero.runArray == [0, 2])
        #expect(DashPattern(.pattern(runs: [0, 0], phase: 0)).isSolid)
        // An ordinary dotted pattern keeps the floor exactly as before.
        let ordinary = DashPattern(.pattern(runs: [1.2, 3.6], phase: 0))
        #expect(abs(ordinary.deviceScale(pixelsPerPagePoint: 0.05) - DashPattern.minimumRunPixels / 1.2) < 1e-12)
    }

    @Test("BH-624: a round-capped dotted line draws dots on both backends, and the backends agree")
    func dottedLineRendersOnBothBackends() throws {
        let line = RenderableMarkup(
            id: Self.id(5),
            shape: .polyline(RenderPolyline(points: [PDFPoint(x: 100, y: 400), PDFPoint(x: 160, y: 400)])),
            style: RenderStyle(stroke: .opaqueBlack, lineWidth: 3, dash: .pattern(runs: [0.01, 6], phase: 0), startCap: .round, endCap: .round)
        )
        guard let viewport = RenderViewport.window(Self.page, zoom: 2, backingScale: 1, pageRect: PDFRect(x: 95, y: 390, width: 70, height: 20))
        else { Issue.record("no viewport"); return }
        var images: [RasterImage] = []
        for renderer in [CoreGraphicsMarkupRenderer(), try MetalMarkupRenderer()] as [any OffscreenMarkupRendering] {
            defer { renderer.dispose() }
            renderer.update(page: Self.page, markups: [line], selection: .empty, snapFeedback: nil, viewport: viewport)
            let image = try renderer.renderOffscreen()
            images.append(image)
            // Count separate inked runs along the centre row: 60 pt / 6 pt ≈ 10 dots. Old
            // output: the scale was 150, the first gap 600 px — one dot in the window.
            let row = image.height / 2
            var runs = 0
            var inside = false
            for x in 0..<image.width {
                let inked = image.alpha(x: x, y: row) > 0.3
                if inked && !inside { runs += 1 }
                inside = inked
            }
            #expect(runs >= 9, "\(renderer.backend): \(runs) dots")
        }
        let comparison = ImageComparator.compare(images[0], images[1])
        #expect(comparison.matches, "\(comparison.failureReasons)")
    }
}
