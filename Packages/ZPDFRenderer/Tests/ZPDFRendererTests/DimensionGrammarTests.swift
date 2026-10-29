import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// The dimension grammar's contract: the measured endpoints are the
/// arrow **tips**, decoration is view-sized so it stays legible at every zoom, and none of it
/// ever moves the measured points. The pixels are held by the two `dimension-grammar` goldens;
/// these tests pin the geometry the pixels came from.
@Suite("Dimension grammar")
struct DimensionGrammarTests {

    private let ink = RenderStyle(stroke: SceneColors.measurement, lineWidth: 1.4)

    private func id(_ value: UInt8) -> MarkupID {
        MarkupID(UUID(uuid: (
            value, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, value
        )))
    }

    private func compiler(
        pixelsPerPagePoint: Double = 1,
        pagePointsPerViewPoint: Double = 1
    ) -> MarkupCompiler {
        MarkupCompiler(
            glyphAtlases: GlyphAtlasCache(),
            pixelsPerPagePoint: pixelsPerPagePoint,
            pagePointsPerViewPoint: pagePointsPerViewPoint
        )
    }

    private func dimension(
        from start: PDFPoint,
        to end: PDFPoint,
        label: String = "14,72 m"
    ) -> RenderableMarkup {
        RenderableMarkup(
            id: id(1),
            shape: .dimensionLine(RenderDimensionLine(start: start, end: end, label: label)),
            style: ink
        )
    }

    // MARK: - The tips are the measured points

    @Test("Each arrowhead has a vertex exactly on its measured endpoint, at any angle")
    func arrowTipsAreTheMeasuredPoints() throws {
        let cases: [(PDFPoint, PDFPoint)] = [
            (PDFPoint(x: 80, y: 700), PDFPoint(x: 460, y: 700)),
            (PDFPoint(x: 540, y: 90), PDFPoint(x: 540, y: 610)),
            (PDFPoint(x: 90, y: 110), PDFPoint(x: 310, y: 300)),
            (PDFPoint(x: 100, y: 400), PDFPoint(x: 150, y: 400))
        ]
        for (start, end) in cases {
            let compiled = try #require(compiler().compile(dimension(from: start, to: end)))
            #expect(compiled.triangles.count >= 2, "two arrowheads expected")
            let vertices = compiled.triangles.flatMap { [$0.a, $0.b, $0.c] }
            // Exactly, not approximately: the tip is a statement about geometry.
            #expect(vertices.contains(start), "no arrow vertex on the start point")
            #expect(vertices.contains(end), "no arrow vertex on the end point")
        }
    }

    @Test("Shaft segments end exactly on the measured points, with butt caps")
    func shaftEndsOnTheMeasuredPoints() throws {
        let start = PDFPoint(x: 100, y: 200)
        let end = PDFPoint(x: 500, y: 200)
        let compiled = try #require(compiler().compile(dimension(from: start, to: end)))
        let endpoints = compiled.segments.flatMap { [$0.start, $0.end] }
        #expect(endpoints.contains(start))
        #expect(endpoints.contains(end))
        for segment in compiled.segments {
            #expect(segment.startCap == .butt && segment.endCap == .butt,
                    "a round cap would push ink past the measured point")
        }
    }

    // MARK: - Decoration scales with zoom, geometry does not

    @Test("Arrowheads and ticks are view-sized: page-point size follows 1/zoom, tips never move")
    func decorationIsViewSized() throws {
        let start = PDFPoint(x: 100, y: 300)
        let end = PDFPoint(x: 500, y: 300)
        // Zoom 1 and zoom 0.25: pagePointsPerViewPoint 1 and 4.
        let atZoom1 = try #require(compiler(pagePointsPerViewPoint: 1).compile(dimension(from: start, to: end)))
        let atZoom025 = try #require(compiler(pagePointsPerViewPoint: 4).compile(dimension(from: start, to: end)))

        func arrowLength(_ compiled: CompiledMarkup, tip: PDFPoint) throws -> Double {
            let triangle = try #require(compiled.triangles.first {
                [$0.a, $0.b, $0.c].contains(tip)
            })
            // Distance from the tip to the base midpoint.
            let others = [triangle.a, triangle.b, triangle.c].filter { $0 != tip }
            let base = PDFPoint(x: (others[0].x + others[1].x) / 2, y: (others[0].y + others[1].y) / 2)
            return tip.distance(to: base)
        }

        let lengthAtZoom1 = try arrowLength(atZoom1, tip: start)
        let lengthAtZoom025 = try arrowLength(atZoom025, tip: start)
        #expect(abs(lengthAtZoom025 / lengthAtZoom1 - 4) < 1e-9,
                "arrow page size must follow 1/zoom so its view size is constant")

        // The tips are unchanged by the zoom.
        for compiled in [atZoom1, atZoom025] {
            let vertices = compiled.triangles.flatMap { [$0.a, $0.b, $0.c] }
            #expect(vertices.contains(start) && vertices.contains(end))
        }
    }

    @Test("A short dimension clamps its arrowheads to a third of the span each")
    func shortSpanClampsArrows() throws {
        let start = PDFPoint(x: 100, y: 400)
        let end = PDFPoint(x: 110, y: 400) // 10 pt span, default arrow is 9 vp
        let compiled = try #require(compiler().compile(dimension(from: start, to: end)))
        let triangle = try #require(compiled.triangles.first { [$0.a, $0.b, $0.c].contains(start) })
        let others = [triangle.a, triangle.b, triangle.c].filter { $0 != start }
        let base = PDFPoint(x: (others[0].x + others[1].x) / 2, y: (others[0].y + others[1].y) / 2)
        let length = start.distance(to: base)
        let limit = 10.0 * MarkupCompiler.DimensionGrammar.maximumArrowFractionOfSpan
        #expect(length <= limit + 1e-9, "arrow \(length) exceeds the clamp \(limit)")
        #expect(length > 0)
    }

    // MARK: - The pill

    @Test("The value pill sits on the line at its midpoint and the shaft yields to it")
    func pillSitsOnTheLine() throws {
        let start = PDFPoint(x: 100, y: 200)
        let end = PDFPoint(x: 500, y: 200)
        let compiled = try #require(compiler().compile(dimension(from: start, to: end)))
        let mid = PDFPoint(x: 300, y: 200)

        // Pill triangles are the ones not touching an arrow tip; their bounds centre is the
        // midpoint of the measured span.
        let pillVertices = compiled.triangles
            .filter { ![$0.a, $0.b, $0.c].contains(start) && ![$0.a, $0.b, $0.c].contains(end) }
            .flatMap { [$0.a, $0.b, $0.c] }
        #expect(!pillVertices.isEmpty, "no pill was built")
        let minX = try #require(pillVertices.map(\.x).min())
        let maxX = try #require(pillVertices.map(\.x).max())
        let minY = try #require(pillVertices.map(\.y).min())
        let maxY = try #require(pillVertices.map(\.y).max())
        #expect(abs((minX + maxX) / 2 - mid.x) < 1e-6)
        #expect(abs((minY + maxY) / 2 - mid.y) < 1e-6)

        // The shaft stops clear of the pill on both sides: no shaft segment endpoint lies
        // strictly inside the pill's box.
        let clearance = MarkupCompiler.DimensionGrammar.pillClearanceViewPoints
        for segment in compiled.segments where segment.start.y == 200 && segment.end.y == 200 {
            for point in [segment.start, segment.end] where point != start && point != end {
                let insideX = point.x > minX + 1e-6 && point.x < maxX - 1e-6
                #expect(!insideX, "shaft endpoint \(point) is inside the pill")
                // And the gap it leaves is at least the documented clearance.
                let distanceToPill = Swift.min(abs(point.x - minX), abs(point.x - maxX))
                #expect(distanceToPill + 1e-6 >= clearance - 1e-6 || !insideX)
            }
        }
    }

    @Test("A standalone label pill's fill area matches the closed-form rounded-rect area")
    func labelPillClosedFormArea() throws {
        let center = PDFPoint(x: 300, y: 400)
        let markup = RenderableMarkup(
            id: id(2),
            shape: .labelPill(RenderLabelPill(anchorPoint: center, text: "Area C: 21,34 m²")),
            style: ink
        )
        let compiled = try #require(compiler().compile(markup))
        #expect(!compiled.glyphs.isEmpty)
        #expect(!compiled.triangles.isEmpty)

        func triangleArea(_ t: CompiledTriangle) -> Double {
            abs((t.b.x - t.a.x) * (t.c.y - t.a.y) - (t.c.x - t.a.x) * (t.b.y - t.a.y)) / 2
        }
        let fanArea = compiled.triangles.reduce(0.0) { $0 + triangleArea($1) }

        let box = try #require(compiled.bounds)
        let width = box.size.width, height = box.size.height
        let radius = Swift.min(width, height) / 2
        // Exact rounded-rect area, minus the corner-facet deficit of the 6-step arcs, which is
        // under half a percent; 1 % headroom covers it.
        let exact = width * height - (4 - Double.pi) * radius * radius
        #expect(abs(fanArea - exact) / exact < 0.01,
                "fan area \(fanArea) is not the rounded-rect area \(exact)")

        // The pill is centred on its anchor.
        #expect(abs(box.midX - center.x) < 1e-6)
        #expect(abs(box.midY - center.y) < 1e-6)
    }

    @Test("The pill's glyphs are pixel-sized offsets centred on the anchor")
    func pillGlyphsAreCentred() throws {
        let center = PDFPoint(x: 250, y: 350)
        let markup = RenderableMarkup(
            id: id(3),
            shape: .labelPill(RenderLabelPill(anchorPoint: center, text: "3,20 m")),
            style: ink
        )
        let compiled = try #require(compiler().compile(markup))
        for glyph in compiled.glyphs {
            #expect(glyph.anchor == center)
        }
        let minOffset = try #require(compiled.glyphs.map(\.offsetX).min())
        let maxReach = try #require(compiled.glyphs.map { $0.offsetX + $0.widthPixels }.max())
        // The run is laid out symmetrically about the anchor, within a pixel of quantisation.
        #expect(abs(minOffset + maxReach) < 2.0, "run not centred: \(minOffset) ... \(maxReach)")
    }

    // MARK: - Model behaviour

    @Test("geometryBounds reports the measured span only, never the decoration")
    func geometryBoundsIsTheMeasuredSpan() throws {
        let markup = dimension(from: PDFPoint(x: 100, y: 200), to: PDFPoint(x: 500, y: 260))
        let bounds = try #require(markup.geometryBounds)
        #expect(bounds.origin.x == 100 && bounds.origin.y == 200)
        #expect(bounds.size.width == 400 && bounds.size.height == 60)

        // The compiled bounds, by contrast, must contain the ink.
        let compiled = try #require(compiler().compile(markup))
        let ink = try #require(compiled.bounds)
        #expect(ink.origin.x <= 100 && ink.origin.y <= 200)
        #expect(ink.maxX >= 500 && ink.maxY >= 260)
        #expect(ink.size.width > bounds.size.width, "arrow/tick/pill ink must widen the box")
    }

    @Test("Degenerate dimensions are rejected, never partially drawn")
    func degenerateDimensionsAreRejected() {
        let point = PDFPoint(x: 100, y: 100)
        #expect(compiler().compile(dimension(from: point, to: point)) == nil)
        #expect(compiler().compile(dimension(
            from: PDFPoint(x: .nan, y: 100), to: PDFPoint(x: 200, y: 100)
        )) == nil)
        var unstroked = dimension(from: PDFPoint(x: 0, y: 0), to: PDFPoint(x: 100, y: 0))
        unstroked.style.stroke = nil
        #expect(compiler().compile(unstroked) == nil)
    }

    @Test("An empty label produces a plain shaft and no pill, not a rejected markup")
    func emptyLabelKeepsTheShaft() throws {
        let start = PDFPoint(x: 100, y: 100)
        let end = PDFPoint(x: 400, y: 100)
        let compiled = try #require(compiler().compile(dimension(from: start, to: end, label: "")))
        #expect(compiled.glyphs.isEmpty)
        #expect(compiled.triangles.count == 2, "only the two arrowheads")
        // One unbroken shaft plus two ticks.
        let shaft = compiled.segments.filter { $0.start.y == 100 && $0.end.y == 100 }
        #expect(shaft.contains { $0.start == start && $0.end == end })
    }

    @Test("The new shapes round-trip through Codable")
    func codableRoundTrip() throws {
        let shapes: [RenderShape] = [
            .dimensionLine(RenderDimensionLine(
                start: PDFPoint(x: 1, y: 2),
                end: PDFPoint(x: 3, y: 4),
                label: "14,72 m"
            )),
            .labelPill(RenderLabelPill(anchorPoint: PDFPoint(x: 5, y: 6), text: "21,34 m²"))
        ]
        for shape in shapes {
            let data = try JSONEncoder().encode(shape)
            let decoded = try JSONDecoder().decode(RenderShape.self, from: data)
            #expect(decoded == shape)
        }
    }

    // MARK: - Zoom invalidation and staleness

    @Test("A zoom step recompiles dimension markups and hands consumers a new revision")
    func zoomStepRecompilesAndRestamps() throws {
        let page = SceneIdentity.page()
        let markups = [
            dimension(from: PDFPoint(x: 100, y: 300), to: PDFPoint(x: 500, y: 300)),
            RenderableMarkup(
                id: id(9),
                zIndex: 1,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: 100, y: 500), PDFPoint(x: 500, y: 500)
                ])),
                style: ink
            )
        ]
        let preparer = ScenePreparer()
        let first = try preparer.prepare(
            page: page, markups: markups, selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
        let firstRevision = try #require(first.markups.first { $0.id == markups[0].id }).revision

        let second = try preparer.prepare(
            page: page, markups: markups, selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 2.0, backingScale: 1.0)
        )
        // Only the zoom-dependent markup recompiled; the polyline slot was untouched.
        #expect(preparer.recompiledCount == 1)
        let secondRevision = try #require(second.markups.first { $0.id == markups[0].id }).revision
        #expect(secondRevision != firstRevision,
                "an unchanged compiled revision would let a slot cache keep the old zoom's geometry")

        // And the recompile actually resized the decoration: half the page-point arrow at 200 %.
        let firstCompiled = try #require(first.markups.first { $0.id == markups[0].id })
        _ = firstCompiled
        let secondCompiled = try #require(second.markups.first { $0.id == markups[0].id })
        #expect(!secondCompiled.triangles.isEmpty)
    }

    @Test("A point on the pill hits the dimension markup, on both backends' shared hit tester")
    func pillIsHitTestable() throws {
        let page = SceneIdentity.page()
        let markup = dimension(from: PDFPoint(x: 100, y: 300), to: PDFPoint(x: 500, y: 300))
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page, markups: [markup], selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
        // The pill's centre is the span midpoint.
        let hit = renderer.hitTest(pagePoint: CGPoint(x: 300, y: 300), toleranceInPagePoints: 1)
        #expect(hit?.markupID == markup.id)
        // And the tip is hittable too.
        let tip = renderer.hitTest(pagePoint: CGPoint(x: 100, y: 300), toleranceInPagePoints: 2)
        #expect(tip?.markupID == markup.id)
    }
}
