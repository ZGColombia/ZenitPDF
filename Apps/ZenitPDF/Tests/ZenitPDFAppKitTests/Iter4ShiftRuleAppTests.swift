import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIMeasurement
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Quality-loop iteration 4, area "ui-presentation-measure", U-073 re-fix, in the assembled app:
/// the shipping canvas's rubber band and Shift angle read the package's one Shift rule, so they
/// hold to the ray — or, on a rectangle's depth step, the perpendicular — the click holds to.
/// The harness calibrates 100 pt = 1 m with snapping off; the snap glyph's half of the rule is
/// tested in the package (`Iter4UIPresentationMeasureTests.depthStepGlyphIsTheClick`). No window
/// is ordered front.
@MainActor
@Suite("Iteration 4 ui-presentation-measure: one Shift rule (app)", .appTierSerialised)
struct Iter4ShiftRuleAppTests {

    private static func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    private static func polar(_ origin: PDFPointValue, _ length: Double, _ degrees: Double) -> PDFPointValue {
        let radians = degrees * .pi / 180
        return p(origin.x + length * cos(radians), origin.y + length * sin(radians))
    }

    private static func near(_ a: PDFPointValue?, _ b: PDFPointValue, _ tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return Swift.abs(a.x - b.x) <= tolerance && Swift.abs(a.y - b.y) <= tolerance
    }

    /// First corner (100, 300); Shift; pointer (190, 400), 48.0° from it, so the 45° ray.
    /// By hand: |(90, 100)| = √18100 = 134.536…, and 134.536… · cos 45° = 95.131…, so the held
    /// point is (195.131…, 395.131…).
    ///
    /// Old output: `liveCursorPoint` (190.0, 400.0) — the canvas's own copy left the Rectangle
    /// Area's first edge free — while the pill read "45.0°" and the click landed on the ray.
    @Test("U-073: the Rectangle Area's first-edge rubber band holds to the ray the click holds to")
    func rectangleFirstEdgeBandIsTheClick() async throws {
        let harness = try await Fix2Harness.make("Iter4 Shift Rectangle.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas

        core.measurement.activate(kind: .rectangleArea)
        canvas.handleClick(at: Self.p(100, 300), additive: false)
        await core.measurement.settlePlacements()
        // The session hands the point back through the page transform: (100.00000000000009,
        // 299.99999999999994), so the comparisons below allow 1e-6 pt.
        #expect(core.measurement.placedPoints.count == 1)
        #expect(Self.near(core.measurement.placedPoints.first, Self.p(100, 300), 1e-6))

        canvas.handleModifiers(shiftHeld: true)
        canvas.handlePointerMove(Self.p(190, 400))
        let held = Self.p(195.13148795220224, 395.13148795220224)
        #expect(Self.near(core.measurement.liveCursorPoint, held, 1e-6),
                "old output: (190.0, 400.0); got \(String(describing: core.measurement.liveCursorPoint))")
        let caption = canvas.liveStateForTesting().drawing.caption ?? ""
        #expect(caption.contains("45.0°"), "\(caption)")

        canvas.handleClick(at: Self.p(190, 400), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 2)
        #expect(Self.near(core.measurement.placedPoints.last, held, 1e-6), "the click lands where the band ended")

        canvas.handleModifiers(shiftHeld: false)
        _ = canvas.handle(key: .escape)
    }

    /// Area, edge (100, 300) → 100 pt at 30°, then `⌥` and Shift held: the next click is the
    /// three-point rectangle's depth. Pointer 60 pt up the perpendicular (120°) and 15 pt along the
    /// edge — 106° from the edge end, nearest rose ray 90°. By hand the depth point is 60 pt up the
    /// perpendicular from the edge end: (156.60…, 401.96…).
    ///
    /// Old output: the band and the preview quadrilateral's depth sat on the 90° ray at
    /// (186.60…, 411.85…) and the pill read "90.0°", while the `⌥`-click placed the depth on the
    /// perpendicular — the preview was a parallelogram, the commit a rectangle.
    @Test("U-073: Area's ⌥ rectangle under Shift previews the depth the ⌥-click places")
    func optionRectanglePreviewIsTheClick() async throws {
        let harness = try await Fix2Harness.make("Iter4 Shift Option Rectangle.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas

        let start = Self.p(100, 300)
        let end = Self.polar(start, 100, 30)
        core.measurement.activate(kind: .area)
        canvas.handleClick(at: start, additive: false)
        canvas.handleClick(at: end, additive: false)
        await core.measurement.settlePlacements()
        let placed = core.measurement.placedPoints
        try #require(placed.count == 2)
        #expect(Self.near(placed[0], start) && Self.near(placed[1], end), "\(placed)")

        canvas.handleModifiers(shiftHeld: true, optionHeld: true)
        let raw = Self.polar(Self.polar(end, 60, 120), 15, 30)
        canvas.handlePointerMove(raw)
        let depth = Self.polar(end, 60, 120)
        #expect(Self.near(core.measurement.liveCursorPoint, depth, 1e-6),
                "old output: (186.60, 411.85) on the 90° ray; got \(String(describing: core.measurement.liveCursorPoint))")
        let live = canvas.liveStateForTesting()
        #expect(!(live.drawing.caption ?? "").contains("°"), "old output: 90.0°; got \(live.drawing.caption ?? "nil")")
        let quad = try #require(live.drawing.inferredQuad)
        #expect(Self.near(quad[2], depth, 1e-6), "\(quad)")

        canvas.handleClick(at: raw, additive: false, optionHeld: true)
        let clicked = canvas.measurementInputForTesting.lastEffects.compactMap { effect -> PDFPointValue? in
            if case let .placePoint(point) = effect { return point }
            return nil
        }
        try #require(clicked.count == 2, "\(canvas.measurementInputForTesting.lastEffects)")
        #expect(Self.near(clicked[0], quad[2]), "the ⌥-click's depth is the previewed depth")
        #expect(Self.near(clicked[1], quad[3]), "and its derived corner the previewed corner")
        #expect(await AppTestSupport.wait { core.ledger.rowCount == 1 }, "the ⌥-click commits the rectangle")

        canvas.handleModifiers(shiftHeld: false, optionHeld: false)
    }
}
