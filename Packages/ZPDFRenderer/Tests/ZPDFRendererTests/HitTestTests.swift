import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// Hit testing, and the requirement that both backends answer identically.
@Suite("Hit testing")
struct HitTestTests {

    private func makeRenderers() throws -> [any OffscreenMarkupRendering] {
        let metal = try MetalMarkupRenderer()
        return [CoreGraphicsMarkupRenderer(), metal]
    }

    private let lineID = MarkupID(UUID(uuidString: "E1E1E1E1-0000-0000-0000-000000000001") ?? UUID())
    private let fillID = MarkupID(UUID(uuidString: "E1E1E1E1-0000-0000-0000-000000000002") ?? UUID())

    private func scene(zoom: Double, backingScale: Double = 1.0) -> RenderScene {
        let page = SceneIdentity.page()
        let markups = [
            RenderableMarkup(
                id: fillID,
                zIndex: 0,
                shape: .filledPolygon(RenderPolygon(
                    outer: [
                        PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100),
                        PDFPoint(x: 300, y: 300), PDFPoint(x: 100, y: 300)
                    ],
                    holes: [[
                        PDFPoint(x: 150, y: 150), PDFPoint(x: 250, y: 150),
                        PDFPoint(x: 250, y: 250), PDFPoint(x: 150, y: 250)
                    ]]
                )),
                style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.concrete, lineWidth: 1)
            ),
            RenderableMarkup(
                id: lineID,
                zIndex: 5,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: 400, y: 400), PDFPoint(x: 500, y: 400)
                ])),
                style: RenderStyle(stroke: SceneColors.ink, lineWidth: 0.25, startCap: .butt, endCap: .butt)
            )
        ]
        return RenderScene(
            name: "hit",
            purpose: "",
            page: page,
            markups: markups,
            selection: SelectionSnapshot(selectedIDs: [fillID], primaryID: fillID),
            viewport: RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: backingScale)
        )
    }

    private func push(_ scene: RenderScene, into renderer: any MarkupPageRendering) {
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: scene.selection,
            snapFeedback: scene.snapFeedback,
            viewport: scene.viewport
        )
    }

    @Test("Both backends return identical results over a grid of query points and zooms")
    func backendsAgree() throws {
        let renderers = try makeRenderers()
        defer { renderers.forEach { $0.dispose() } }
        for zoom in [0.05, 0.25, 1.0, 8.0, 64.0] {
            let scene = scene(zoom: zoom)
            for renderer in renderers { push(scene, into: renderer) }
            for gridY in stride(from: 60.0, through: 560.0, by: 17.0) {
                for gridX in stride(from: 60.0, through: 560.0, by: 17.0) {
                    let point = CGPoint(x: gridX, y: gridY)
                    let results = renderers.map { $0.hitTest(pagePoint: point, toleranceInPagePoints: 2) }
                    let first = results[0]
                    for other in results.dropFirst() {
                        #expect(first == other, "zoom \(zoom) at \(point)")
                    }
                }
            }
        }
    }

    @Test("A hairline is hittable across the band it was actually painted at")
    func hairlineHitAtDrawnWidth() throws {
        let renderers = try makeRenderers()
        defer { renderers.forEach { $0.dispose() } }
        // At 5 % zoom a 0.25 pt stroke is painted one device pixel wide, which is 20 page points
        // across; its drawn half width is 10 page points.
        let zoomedOut = scene(zoom: 0.05)
        for renderer in renderers {
            push(zoomedOut, into: renderer)
            let near = renderer.hitTest(pagePoint: CGPoint(x: 450, y: 408), toleranceInPagePoints: 0)
            #expect(near?.markupID == lineID)
            let far = renderer.hitTest(pagePoint: CGPoint(x: 450, y: 425), toleranceInPagePoints: 0)
            #expect(far?.markupID != lineID)
        }
        // At 800 % on a non-Retina backing store the same stroke is 2 device pixels, so its
        // drawn half width is 0.125 page points and the band has shrunk by eighty times.
        let zoomedIn = scene(zoom: 8.0)
        for renderer in renderers {
            push(zoomedIn, into: renderer)
            #expect(
                renderer.hitTest(pagePoint: CGPoint(x: 450, y: 400.1), toleranceInPagePoints: 0)?
                    .markupID == lineID
            )
            #expect(
                renderer.hitTest(pagePoint: CGPoint(x: 450, y: 400.5), toleranceInPagePoints: 0)?
                    .markupID != lineID
            )
        }
    }

    @Test("A hole is not part of the fill")
    func holesAreNotHit() throws {
        let renderers = try makeRenderers()
        defer { renderers.forEach { $0.dispose() } }
        let scene = scene(zoom: 1.0)
        for renderer in renderers {
            push(scene, into: renderer)
            let inFill = renderer.hitTest(pagePoint: CGPoint(x: 120, y: 200), toleranceInPagePoints: 0)
            #expect(inFill?.markupID == fillID)
            #expect(inFill?.kind == .fill)
            let inHole = renderer.hitTest(pagePoint: CGPoint(x: 200, y: 200), toleranceInPagePoints: 0)
            #expect(inHole == nil)
        }
    }

    @Test("A handle wins over the shape it sits on, and stays one physical size at every zoom")
    func handlesWin() throws {
        let renderers = try makeRenderers()
        defer { renderers.forEach { $0.dispose() } }
        for zoom in [0.25, 1.0, 8.0] {
            let scene = scene(zoom: zoom)
            for renderer in renderers {
                push(scene, into: renderer)
                // The primary selection's bounding box corner is at (100, 100).
                let hit = renderer.hitTest(pagePoint: CGPoint(x: 100, y: 100), toleranceInPagePoints: 0)
                #expect(hit?.kind == .handle, "zoom \(zoom)")
                #expect(hit?.markupID == fillID)
                // Seven view points at this zoom, half of it, is where the handle stops.
                let halfPagePoints = 3.5 / zoom
                let outside = renderer.hitTest(
                    pagePoint: CGPoint(x: 100 + halfPagePoints * 3, y: 100 + halfPagePoints * 3),
                    toleranceInPagePoints: 0
                )
                #expect(outside?.kind != .handle, "zoom \(zoom)")
            }
        }
    }

    @Test("A vertex beats the stroke that runs through it")
    func vertexBeatsStroke() throws {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        let scene = scene(zoom: 1.0)
        push(scene, into: renderer)
        let atVertex = renderer.hitTest(pagePoint: CGPoint(x: 400, y: 400), toleranceInPagePoints: 1)
        #expect(atVertex?.kind == .vertex)
        #expect(atVertex?.elementIndex == 0)
        let midSpan = renderer.hitTest(pagePoint: CGPoint(x: 450, y: 400), toleranceInPagePoints: 1)
        #expect(midSpan?.kind == .stroke)
    }

    @Test("Painter's order decides which of two overlapping markups is hit")
    func topmostWins() throws {
        let page = SceneIdentity.page()
        let low = MarkupID(UUID(uuidString: "E2E2E2E2-0000-0000-0000-000000000001") ?? UUID())
        let high = MarkupID(UUID(uuidString: "E2E2E2E2-0000-0000-0000-000000000002") ?? UUID())
        func square(_ id: MarkupID, _ z: Int) -> RenderableMarkup {
            RenderableMarkup(
                id: id,
                zIndex: z,
                shape: .filledPolygon(RenderPolygon(outer: [
                    PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100),
                    PDFPoint(x: 300, y: 300), PDFPoint(x: 100, y: 300)
                ])),
                style: RenderStyle(stroke: nil, fill: SceneColors.concrete)
            )
        }
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page,
            markups: [square(low, 1), square(high, 9)],
            selection: .empty,
            snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
        #expect(
            renderer.hitTest(pagePoint: CGPoint(x: 200, y: 200), toleranceInPagePoints: 0)?
                .markupID == high
        )
    }

    @Test("A dash gap is not a hole in the object")
    func dashGapsAreStillHittable() throws {
        let page = SceneIdentity.page()
        let id = MarkupID(UUID(uuidString: "E3E3E3E3-0000-0000-0000-000000000001") ?? UUID())
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page,
            markups: [RenderableMarkup(
                id: id,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: 100, y: 400), PDFPoint(x: 500, y: 400)
                ])),
                style: RenderStyle(stroke: SceneColors.ink, lineWidth: 2, dash: .pattern(runs: [4, 40], phase: 0))
            )],
            selection: .empty,
            snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
        // Deep inside a 40 pt gap.
        #expect(
            renderer.hitTest(pagePoint: CGPoint(x: 120, y: 400), toleranceInPagePoints: 0)?
                .markupID == id
        )
    }

    @Test("Hit testing a disposed or empty renderer returns nil rather than crashing")
    func emptyAndDisposed() throws {
        let renderer = CoreGraphicsMarkupRenderer()
        #expect(renderer.hitTest(pagePoint: .zero, toleranceInPagePoints: 4) == nil)
        push(scene(zoom: 1.0), into: renderer)
        renderer.dispose()
        #expect(renderer.hitTest(pagePoint: CGPoint(x: 200, y: 200), toleranceInPagePoints: 4) == nil)
        #expect(renderer.hitTest(pagePoint: CGPoint(x: CGFloat.nan, y: 2), toleranceInPagePoints: CGFloat.nan) == nil)
    }
}
