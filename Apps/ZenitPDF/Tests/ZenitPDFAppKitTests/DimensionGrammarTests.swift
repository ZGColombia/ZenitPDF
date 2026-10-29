import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFRenderer
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The committed-length dimension grammar: arrowheads whose tips are
/// the measured points, an extension tick through every point, decoration sized in view points so
/// it reads at every zoom. The maths is pure and the pixels are asserted where they are produced,
/// exactly like `CanvasDrawingTests`.
@MainActor
@Suite(.appTierSerialised)
struct DimensionGrammarTests {

    // MARK: - Pure geometry

    @Test("Arrowhead tips are exactly the measured endpoints, bases point inward")
    func arrowheadTipsAreTheMeasuredPoints() {
        let points = [CGPoint(x: 40, y: 60), CGPoint(x: 240, y: 60)]
        let decoration = DimensionGrammar.decoration(forViewPoints: points)

        #expect(decoration.arrowheads.count == 2)
        #expect(decoration.arrowheads[0][0] == points[0], "the first tip must be the first measured point, exactly")
        #expect(decoration.arrowheads[1][0] == points[1], "the last tip must be the last measured point, exactly")

        // The first arrowhead's base sits 9 view points inward, along +x.
        let base = decoration.arrowheads[0]
        #expect(abs(base[1].x - 49) < 1e-9 && abs(base[2].x - 49) < 1e-9)
        #expect(abs(base[1].y - base[2].y - 7) < 1e-9, "base is two half-widths of 3.5 apart")

        // One tick through every measured point, perpendicular, 9 view points long.
        #expect(decoration.ticks.count == 2)
        let tick = decoration.ticks[0]
        #expect(abs(tick[0].x - 40) < 1e-9 && abs(tick[1].x - 40) < 1e-9, "the tick is perpendicular to the shaft")
        #expect(abs(abs(tick[1].y - tick[0].y) - DimensionGrammar.tickLength) < 1e-9)
    }

    @Test("Decoration size is independent of the measured span — the every-zoom guarantee")
    func decorationSizeIsZoomIndependent() {
        // 27 view points is the shortest span whose arrowheads are not clamped to a third of it
        // (R-157); below that the heads shrink so they never cross, as the renderer's do.
        let long = DimensionGrammar.decoration(forViewPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 800, y: 0)])
        let short = DimensionGrammar.decoration(forViewPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 27, y: 0)])
        func arrowSpan(_ d: DimensionGrammar.Decoration) -> CGFloat {
            abs(d.arrowheads[0][1].x - d.arrowheads[0][0].x)
        }
        #expect(arrowSpan(long) == arrowSpan(short), "arrowheads must not scale with the span")
        func tickSpan(_ d: DimensionGrammar.Decoration) -> CGFloat {
            abs(d.ticks[1][1].y - d.ticks[1][0].y)
        }
        #expect(tickSpan(long) == tickSpan(short))
    }

    /// R-157: the canvas-core copy of the grammar and the renderer's must not drift. The
    /// portable package cannot link the renderer, so this target — which links both — holds
    /// them equal.
    @Test("R-157: the canvas grammar's sizes and clamp equal the renderer's")
    func grammarMatchesTheRenderer() {
        let line = RenderDimensionLine(start: PDFPoint(x: 0, y: 0), end: PDFPoint(x: 1, y: 0), label: "")
        #expect(Double(DimensionGrammar.arrowLength) == line.arrowLengthViewPoints)
        #expect(Double(DimensionGrammar.arrowHalfWidth) == line.arrowHalfWidthViewPoints)
        #expect(Double(DimensionGrammar.tickLength) == line.tickLengthViewPoints)
        #expect(Double(DimensionGrammar.maximumArrowFractionOfSpan) == MarkupCompiler.DimensionGrammar.maximumArrowFractionOfSpan)
    }

    @Test("Interior vertices of a polyline get a tick but no arrowhead")
    func interiorVerticesTickOnly() {
        let decoration = DimensionGrammar.decoration(forViewPoints: [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 80),
        ])
        #expect(decoration.ticks.count == 3)
        #expect(decoration.arrowheads.count == 2, "arrowheads only at the two path ends")
    }

    @Test("Coincident points produce no decoration rather than NaN")
    func degeneratePathIsSafe() {
        let decoration = DimensionGrammar.decoration(forViewPoints: [
            CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5),
        ])
        #expect(decoration.arrowheads.isEmpty && decoration.ticks.isEmpty)
    }

    // MARK: - Scene

    @Test("A committed length is dimensioned in the scene; a committed area is not")
    func sceneMarksLengthsDimensioned() throws {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let ink = AppMeasurementToolPresenter.measurementInk
        func record(tool: MeasurementTool, geometry: MeasurementGeometry) -> MarkupRecord {
            MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: pageID,
                kind: .measurement,
                tool: tool,
                subject: "x",
                author: "test",
                style: MarkupStyle(color: ink),
                geometry: geometry,
                createdAt: stamp,
                modifiedAt: stamp
            )
        }
        let length = record(tool: .polylength, geometry: MeasurementGeometry(
            pageID: pageID,
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)]
        ))
        let area = record(tool: .area, geometry: MeasurementGeometry(
            pageID: pageID,
            polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 80),
            ], isClosed: true))]
        ))
        let shapes = CanvasSceneBuilder.build(records: [length, area], summaries: [], pageID: pageID.rawValue)
        #expect(shapes.count == 2)
        let lengthShape = try #require(shapes.first { !$0.strokes.contains(where: \.closed) })
        let areaShape = try #require(shapes.first { $0.strokes.contains(where: \.closed) })
        #expect(lengthShape.strokes.allSatisfy { $0.dimensioned }, "a committed length carries the dimension grammar")
        #expect(areaShape.strokes.allSatisfy { !$0.dimensioned }, "a polygon outline is not a dimension line")
    }

    // MARK: - Pixels

    /// The committed line's extension tick is drawn in the markup's ink at both a small and a
    /// large zoom, at constant view size — sampled perpendicular to the shaft at the endpoint,
    /// where only the tick can paint.
    @Test("Committed lengths draw ticks and endpoint dots at both zoom extremes", arguments: [0.25, 4.0])
    func committedLengthIsDimensionedOnScreen(zoom: Double) {
        let pageBox = PDFRectValue(x: 0, y: 0, width: 200, height: 100)
        let view = CanvasPageView()
        view.transform = PageDisplayTransform(
            pageBox: pageBox,
            rotation: 0,
            zoom: zoom,
            origin: CGPoint(x: 20, y: 10)
        )
        // A pure-red horizontal committed length across the middle of the page, page y = 50.
        view.shapes = [
            CanvasMarkupShape(
                id: UUID(),
                pageID: UUID(),
                color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
                strokes: [
                    CanvasStroke(
                        points: [PDFPointValue(x: 40, y: 50), PDFPointValue(x: 160, y: 50)],
                        closed: false,
                        filled: false,
                        dimensioned: true
                    )
                ],
                counts: [],
                bounds: PDFRectValue(x: 40, y: 50, width: 120, height: 0),
                hidden: false,
                caption: nil
            )
        ]
        let size = CGSize(width: 900, height: 500)
        view.frame = CGRect(origin: .zero, size: size)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        func color(atViewX x: CGFloat, y: CGFloat) -> NSColor {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear
        }

        // The left endpoint in view space: x = 20 + 40*zoom, y = 10 + (100-50)*zoom.
        let endX = 20 + 40 * zoom
        let endY = 10 + 50 * zoom
        // 3 view points above the endpoint: on the tick, off the shaft — at every zoom.
        let onTick = color(atViewX: endX, y: endY - 3)
        #expect(onTick.redComponent > 0.6 && onTick.greenComponent < 0.4,
                "the extension tick must paint here at zoom \(zoom), got \(onTick)")
        // Design round d7 (2026-09-23 design): the shaft ends in a round dot centred on the
        // measured endpoint instead of an arrowhead. 2.5 view points *outward* of the endpoint,
        // on the shaft's axis, only the dot can paint — the shaft stops at the endpoint and the
        // tick is a hairline through it — at every zoom.
        let onDot = color(atViewX: endX - 2.5, y: endY)
        #expect(onDot.redComponent > 0.6 && onDot.greenComponent < 0.4,
                "the endpoint dot must paint here at zoom \(zoom), got \(onDot)")
    }
}
