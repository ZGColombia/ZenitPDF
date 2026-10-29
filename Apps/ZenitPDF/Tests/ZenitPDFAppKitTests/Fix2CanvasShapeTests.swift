import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Bug hunt 2, how committed ink draws and what a click on it picks: cutout holes, count
/// captions and symbols, the tape, and hit radii.
@MainActor
@Suite(.appTierSerialised)
struct Fix2CanvasShapeTests {

    private static func ring(_ x: Double, _ y: Double, _ side: Double) -> [PDFPointValue] {
        [PDFPointValue(x: x, y: y), PDFPointValue(x: x + side, y: y),
         PDFPointValue(x: x + side, y: y + side), PDFPointValue(x: x, y: y + side)]
    }

    private static func shape(
        strokes: [CanvasStroke] = [],
        counts: [PDFPointValue] = [],
        caption: String? = nil,
        lineWidth: Double = 1,
        temporary: Bool = false
    ) -> CanvasMarkupShape {
        var shape = CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1),
            strokes: strokes, fill: nil, counts: counts, symbol: nil, artwork: nil, stamp: nil,
            bounds: PDFRectValue(x: 0, y: 0, width: 400, height: 400), hidden: false, printable: true,
            caption: caption, kind: .measurement, text: nil, textBox: nil, leaderTarget: nil,
            lineWidth: lineWidth, opacity: 1, fontSize: 12, lineStyle: .solid, vertices: []
        )
        shape.isTemporary = temporary
        return shape
    }

    @Test("BH-339 / BH-344: a Temporary Measure is never hit and never caught by a marquee")
    func tapeIsNotSelectable() {
        let tape = Self.shape(strokes: [CanvasStroke(points: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0)],
                                                   closed: false, filled: false)], temporary: true)
        // Old: selected — a phantom id the session does not hold, then a refused move.
        #expect(!CanvasHitTesting.shape(tape, contains: PDFPointValue(x: 50, y: 0), tolerance: 3))
        #expect(!CanvasHitTesting.shape(tape, intersects: PDFRectValue(x: -10, y: -10, width: 200, height: 20)))
    }

    @Test("BH-340: a cutout is a hole — its interior is neither filled nor clickable as the area")
    func cutoutHoleIsNotTheArea() {
        let area = Self.shape(strokes: [
            CanvasStroke(points: Self.ring(0, 0, 300), closed: true, filled: true),
            CanvasStroke(points: Self.ring(100, 100, 100), closed: true, filled: false)
        ])
        #expect(CanvasHitTesting.holes(of: area).count == 1)
        // Old: the outer fill covered the courtyard, so a click there picked the area.
        #expect(!CanvasHitTesting.shape(area, contains: PDFPointValue(x: 150, y: 150), tolerance: 1))
        #expect(CanvasHitTesting.shape(area, contains: PDFPointValue(x: 50, y: 50), tolerance: 1))
        // The cutout child record draws as an outline: the parent already leaves the hole clear.
        let page = PageID(UUID())
        let child = MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page,
            kind: .measurement, tool: .polygonCutout, subject: "",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)
            ]))]),
            parentMarkupID: MarkupID(UUID()),
            createdAt: Date(), modifiedAt: Date()
        )
        let childShape = CanvasSceneBuilder.build(records: [child], summaries: [], pageID: page.rawValue).first
        #expect(childShape?.strokes.allSatisfy { !$0.filled } == true, "the cutout tinted the hole a second time")
    }

    @Test("BH-880: an area pill never sits in a cutout")
    func areaPillAvoidsTheHole() throws {
        let outer = [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 300), CGPoint(x: 0, y: 300)]
        let hole = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 200), CGPoint(x: 100, y: 200)]
        let without = try #require(AreaPillLayout.placement(polygon: outer, pillHalfWidth: 20, pillHalfHeight: 8))
        #expect(without.isInterior)
        let with = try #require(AreaPillLayout.placement(polygon: outer, holes: [hole], pillHalfWidth: 20, pillHalfHeight: 8))
        // Old: centred on (150, 150) — in the courtyard the number does not cover.
        #expect(!with.isInterior)
    }

    @Test("BH-341: a committed count draws its caption, anchored on its marks")
    func countCaptionHasAnAnchor() {
        let marks = [PDFPointValue(x: 10, y: 50), PDFPointValue(x: 40, y: 90), PDFPointValue(x: 5, y: 90)]
        // Old: no strokes → no anchor → the caption was dropped.
        #expect(CanvasPageView.countCaptionAnchor(marks) == PDFPointValue(x: 5, y: 90))
        #expect(CanvasPageView.countCaptionAnchor([]) == nil)
    }

    @Test("BH-338: a symbol's stored counter-clockwise rotation is negated for the flipped view")
    func symbolRotationIsCounterClockwise() {
        let symbol = MarkupSymbol(builtInGlyph: "triangle", sizePoints: 12, rotationDegrees: 30)
        // Old: +30 in a y-down view — clockwise on screen, counter-clockwise everywhere else.
        #expect(CanvasCountSymbolPainter.viewRotationDegrees(for: symbol) == -30)
        #expect(CanvasCountSymbolPainter.viewRotationDegrees(for: nil) == 0)
    }

    @Test("BH-878 / IM-161: the drawn symbol and the drawn stroke width are the hit targets")
    func hitTargetsAreWhatIsDrawn() {
        let count = Self.shape(counts: [PDFPointValue(x: 100, y: 100)])
        // An unsymbolled mark is 8 pt; at 400 % a 6-px slop is 0.75 pt, the drawn radius 1 pt.
        #expect(CanvasHitTesting.shape(count, contains: PDFPointValue(x: 100.9, y: 100), tolerance: 0.75, zoom: 4))
        // Old: missed — the tolerance ignored the symbol's size.
        let fat = Self.shape(strokes: [CanvasStroke(points: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0)],
                                                  closed: false, filled: false)], lineWidth: 9)
        #expect(CanvasHitTesting.shape(fat, contains: PDFPointValue(x: 50, y: 6), tolerance: 3))
        #expect(!CanvasHitTesting.shape(fat, contains: PDFPointValue(x: 50, y: 9), tolerance: 3))
    }

    @Test("BH-885: hit radii are view points, the same on a 1x and a 2x display")
    func tolerancesAreViewPoints() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ZenitPDFAppKit/Canvas/PDFCanvasViewController.swift"),
            encoding: .utf8
        )
        // Old: every canvas radius went through pageTolerance(forScreenPixels:), which also
        // divides by the backing scale — half the grab radius on a Retina display.
        #expect(!source.contains("pageTolerance(forScreenPixels"))
        let viewport = ViewportSnapshot(pageID: UUID(), pageIndex: 0, zoom: 2, visiblePageRect: .zero, backingScaleFactor: 2)
        #expect(viewport.pageDistance(forViewPoints: 7) == 3.5)
    }

    @Test("BH-343: Calibrate Scale collects its clicks even with an Apply preset armed")
    func calibrationOutranksAnArmedPreset() async throws {
        let harness = try await Fix2Harness.make("BH343.pdf")
        defer { harness.tearDown() }
        let preset = ToolPresetSummary(
            id: UUID(), name: "Slab", category: "Concrete", panel: .myTools,
            markupKind: .measurement, measurementKind: .area,
            colorRGBA: ColorRGBA(red: 0.9, green: 0.7, blue: 0.2, alpha: 1), defaultSubject: "Slab"
        )
        harness.core.toolLibrary.setPresets([preset])
        harness.core.toolLibrary.setMode(.apply, for: preset.panel)
        defer { harness.core.toolLibrary.setMode(.draw, for: preset.panel) }
        harness.core.toolLibrary.activatePreset(id: preset.id)
        harness.canvas.beginCalibration()
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        // Old: the click went to the preset's Apply branch; calibration never saw it.
        #expect(await AppTestSupport.wait { harness.canvas.calibrationPointsForTesting.count == 1 })
    }
}
