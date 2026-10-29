import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-11 through the canvas: a fence line closes an opening too wide to propose, and
/// Perimeter and Wall Area trace a room as Area does.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureFenceTraceTests {

    /// Room 0..600 × 0..300 pt with a 350 pt opening in the bottom wall (x 100..450). At 100 pt/m
    /// the room is 6 m × 3 m = 18 m², perimeter 18 m; the 3.5 m opening is over the 2.5 m cap,
    /// so without a fence the trace refuses.
    static let room = "1 w 0 0 0 RG 0 0 m 100 0 l S 450 0 m 600 0 l S 600 0 m 600 300 l S 600 300 m 0 300 l S 0 300 m 0 0 l S"
        + " 600 0 m 900 0 l S 900 0 m 900 300 l S 900 300 m 600 300 l S"

    @Test("A fence closes a wide opening; Area, Perimeter and Wall Area trace the room")
    func fenceAndTraceableTools() async throws {
        let harness = try await NLMeasureR2Harness.make("Fence.pdf", content: Self.room)
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        await core.refresh()

        // Without a fence: refused, nothing committed.
        harness.shell.toolbar.activateMeasurement(.area)
        canvas.handleClick(at: PDFPointValue(x: 300, y: 150), additive: false, optionHeld: true)
        await canvas.settleAutoTrace()
        #expect(await core.session.orderedMarkups.isEmpty)

        // Draw Fence Line across the opening (the two clicks arrive as a calibration pick does).
        harness.controller.beginFenceLine(for: harness.document)
        #expect(FencePick.isArmed(harness.document))
        // The canvas ends its two-click pick before it hands the points over, as here.
        canvas.endCalibration(collected: true)
        harness.controller.finishCalibration(points: [PDFPointValue(x: 100, y: 0), PDFPointValue(x: 450, y: 0)], for: harness.document)
        #expect(canvas.traceFences[harness.page.rawValue]?.count == 1)
        canvas.refresh()
        #expect(canvas.pageViewForTesting.traceFenceLines.count == 1, "the fence is drawn")

        harness.shell.toolbar.activateMeasurement(.area)
        canvas.handleClick(at: PDFPointValue(x: 300, y: 150), additive: false, optionHeld: true)
        await canvas.settleAutoTrace()
        let area = try #require(await Self.markup(core, count: 1).last)
        #expect(Swift.abs(NSDecimalNumber(decimal: try #require(area.measurement?[.netArea]?.value)).doubleValue - 18) < 1e-9)
        #expect((core.status.snapshot.activeToolNote ?? "").contains("fence"), "the note names the fence")

        // ⇧⌥-click the next room (600..900 × 0..300, 3 × 3 m) with the first selected: one area,
        // 18 + 9 = 27 m², the shared wall gone.
        core.canvas.select(markupIDs: [area.id.rawValue], additive: false)
        canvas.isShiftHeld = true
        // The click's own ⇧ (`additive`), as the page view reports a ⇧⌥-click: the union is
        // decided from the click, not from the stored key state when the trace lands (V-009).
        canvas.handleClick(at: PDFPointValue(x: 750, y: 150), additive: true, optionHeld: true)
        await canvas.settleAutoTrace()
        var grown = 0.0
        for _ in 0..<150 {
            grown = NSDecimalNumber(decimal: await core.session.markup(area.id)?.measurement?[.netArea]?.value ?? 0).doubleValue
            if grown > 19 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        canvas.isShiftHeld = false
        core.canvas.select(markupIDs: [], additive: false)
        #expect(Swift.abs(grown - 27) < 1e-9)
        #expect(await core.session.orderedMarkups.count == 1)

        // Perimeter: 2 × (6 + 3) = 18 m.
        harness.shell.toolbar.activateMeasurement(.perimeter)
        canvas.handleClick(at: PDFPointValue(x: 300, y: 150), additive: false, optionHeld: true)
        await canvas.settleAutoTrace()
        let perimeter = try #require(await Self.markup(core, count: 2).last)
        #expect(perimeter.tool == .perimeter)
        #expect(Swift.abs(NSDecimalNumber(decimal: try #require(perimeter.measurement?[.perimeter]?.value)).doubleValue - 18) < 1e-9)

        // Wall Area at 2.5 m: 18 × 2.5 = 45 m².
        harness.shell.toolbar.activateMeasurement(.wallArea)
        core.measurement.setParameterText("2.5")
        canvas.handleClick(at: PDFPointValue(x: 300, y: 150), additive: false, optionHeld: true)
        await canvas.settleAutoTrace()
        let wall = try #require(await Self.markup(core, count: 3).last)
        #expect(wall.tool == .wallArea)
        #expect(Swift.abs(NSDecimalNumber(decimal: try #require(wall.measurement?[.wallArea]?.value)).doubleValue - 45) < 1e-9)

        harness.controller.clearFenceLines(for: harness.document)
        #expect(canvas.traceFences[harness.page.rawValue] == nil)
    }

    static func markup(_ core: AppCoreEnvironment, count: Int) async -> [MarkupRecord] {
        var records = await core.session.orderedMarkups
        for _ in 0..<150 where records.count < count {
            try? await Task.sleep(for: .milliseconds(20))
            records = await core.session.orderedMarkups
        }
        return records
    }
}
