import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-05 on the canvas (ADR-0030 §5.6): A while drawing makes the next segment a
/// three-point arc; outside a shape A is still the Area tool, and mid-shape it never switches tools.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureArcDrawingAppTests {

    /// 100 pt = 1 m. A polylength (100,100) → (1100,100) is 10 m; A, a click at (1350,350) — the
    /// through point, not a vertex — and a click at (1100,600) make the second edge the semicircle
    /// of radius 250 pt = 2.5 m, bulge 1: 10 + 2.5π m. The pill says the arc's 2.5π m while it
    /// follows the pointer; Delete takes the arc's end and its arc back; A outside a shape arms Area.
    @Test("A mid-polylength draws a three-point arc: 10 + 2.5π m; Delete removes the arc; A outside arms Area")
    func arcWhileDrawing() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Drawing.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        harness.shell.toolbar.activateMeasurement(.polylength)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })

        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 100))
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 1100, y: 100))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })

        // Mid-shape A: the next segment is an arc, and the tool is still Polylength.
        #expect(canvas.handle(key: .area))
        #expect(core.measurement.activeKind == .polylength)
        #expect(core.measurement.isArcNextSegment)

        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 1350, y: 350))
        #expect(await AppTestSupport.wait { core.measurement.arcThroughPoint == PDFPointValue(x: 1350, y: 350) })
        #expect(core.measurement.placedPoints.count == 2, "the through point is not a vertex")

        // The live pill: the running 10 + 2.5π m and the arc's own 2.5π m ≈ 7.85 m.
        core.measurement.updateLiveCursor(PDFPointValue(x: 1100, y: 600))
        #expect(await AppTestSupport.wait { core.measurement.liveArcSegmentField != nil })
        let arcLength = NSDecimalNumber(decimal: core.measurement.liveArcSegmentField?.quantity.value ?? 0).doubleValue
        #expect(Swift.abs(arcLength - 2.5 * .pi) <= 2.5 * .pi * 1e-12)
        canvas.refresh()
        let live = canvas.liveStateForTesting().drawing
        // In the session's locale (L-104): "Arc 7,85 m" on a Swedish Mac, "Arc 7.85 m" in English.
        #expect(live.caption?.contains("Arc 7\(Locale.current.decimalSeparator ?? ".")85") == true, "\(String(describing: live.caption))")
        #expect((live.rubberBand?.count ?? 0) > 10, "the rubber band is drawn as the arc")

        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 1100, y: 600))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 3 })
        #expect(Swift.abs((core.measurement.placedArcBulges[1] ?? 0) - 1) <= 1e-12)
        #expect(!core.measurement.isArcNextSegment)

        // Delete takes the arc's end back, and its arc with it.
        #expect(canvas.handle(key: .removeLastVertex))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        #expect(core.measurement.placedArcBulges.isEmpty)

        // Draw it again and finish: 10 + 2.5π m in the ledger.
        #expect(canvas.handle(key: .area))
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 1350, y: 350))
        #expect(await AppTestSupport.wait { core.measurement.arcThroughPoint != nil })
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 1100, y: 600))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 3 })
        #expect(canvas.handle(key: .finish))
        var length = 0.0
        for _ in 0..<250 {
            let record = await core.session.orderedMarkups.first { $0.tool == .polylength }
            length = NSDecimalNumber(decimal: record?.measurement?[.planLength]?.value ?? 0).doubleValue
            if length > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let expected = 10 + 2.5 * Double.pi
        #expect(Swift.abs(length - expected) <= expected * 1e-12, "\(length) vs \(expected)")

        // Outside a shape, A is the Area tool.
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.isEmpty })
        #expect(canvas.handle(key: .area))
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .area })
    }

    /// A tool whose segments cannot be arcs keeps its shape: A mid-count neither arms Area nor
    /// throws the marks away.
    @Test("A mid-count does not switch tools")
    func noToolSwitchMidShape() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Count.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        harness.shell.toolbar.activateMeasurement(.count)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .count })
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 200, y: 200))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        #expect(canvas.handle(key: .area))
        #expect(core.measurement.activeKind == .count)
        #expect(core.measurement.placedPoints.count == 1)
    }
}
