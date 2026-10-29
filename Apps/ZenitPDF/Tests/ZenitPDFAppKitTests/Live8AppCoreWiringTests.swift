import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// App-core regressions (l8-appcore), through the shipping window: L-70 (Split Area and
/// Merge Areas), L-102 (Radius on a sheet with separate X and Y scales) and L-99 (the Pen's
/// status hint). The window is never ordered on screen; pills are drawn with `cacheDisplay`.
@MainActor
@Suite(.appTierSerialised)
struct Live8AppCoreWiringTests {

    /// A tall, narrow area at (100, 100)–(160, 300): 60 × 200 pt, at 100 pt = 1 m 0,6 × 2 m.
    /// Split down the middle, each half is 30 pt wide — narrower than its pill at any zoom the
    /// harness opens at, so both pills step out on a leader below the area.
    private static func narrowArea(_ page: PageID) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 160, y: 100),
            PDFPoint(x: 160, y: 300), PDFPoint(x: 100, y: 300)
        ], isClosed: true))])
    }

    @Test("L-70: Split Area names itself, the halves' pills do not cover each other, Merge gives the label back")
    func splitAndMerge() async throws {
        let harness = try await Fix2Harness.make("L70Split.pdf")
        defer { harness.tearDown() }
        let area = try await harness.addMarkup(tool: .area, geometry: Self.narrowArea, subject: "Floor")
        _ = try await harness.core.commands.perform(.editLabel(id: area.id, label: "Kitchen floor"))
        await harness.settle()
        harness.core.canvas.select(markupIDs: [area.id.rawValue], additive: false)

        harness.controller.beginSplitArea(for: harness.document)
        // Old output: tool "Calibrate", note "Split Area: click the two ends of the dividing line."
        // — the status strip read "Tool Calibrate — Split Area: …".
        #expect(harness.core.status.snapshot.activeToolName == "Split Area")
        #expect(harness.core.status.snapshot.activeToolNote == "Click the two ends of the dividing line.")

        harness.controller.finishCalibration(
            points: [PDFPointValue(x: 130, y: 90), PDFPointValue(x: 130, y: 310)],
            for: harness.document
        )
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 2 })
        await harness.settle()
        let halves = await harness.records()
        #expect(halves.map(\.label) == ["Kitchen floor.1", "Kitchen floor.2"])

        // Both pills drawn, neither over the other. Old output: both hung under their own
        // bottom-left corner, 30 pt apart, so the second covered most of the first.
        let pageView = harness.canvas.pageViewForTesting
        pageView.backingScaleOverride = 1
        let rect = pageView.bounds.integral
        let picture = try #require(pageView.bitmapImageRepForCachingDisplay(in: rect))
        pageView.cacheDisplay(in: rect, to: picture)
        let first = try #require(pageView.captionFrames[halves[0].id.rawValue])
        let second = try #require(pageView.captionFrames[halves[1].id.rawValue])
        #expect(!first.intersects(second), "\(first) and \(second)")

        harness.core.canvas.select(markupIDs: Set(halves.map(\.id.rawValue)), additive: false)
        await AreaSplitFlow.merge(harness.document)
        let merged = await harness.records()
        #expect(merged.count == 1)
        // Old output: "Kitchen floor.1".
        #expect(merged.first?.label == "Kitchen floor")
    }

    @Test("L-102: Radius armed on a sheet with separate X and Y scales says why, and a click places nothing")
    func radiusOnASeparateAxesSheet() async throws {
        let harness = try await Fix2Harness.make("L102Radius.pdf", calibrate: false)
        defer { harness.tearDown() }
        let page = try #require(await harness.core.session.firstPageID)
        // X: 100 pt = 4,9 m; Y: 100 pt = 5,1 m — the reported 1:49 × 1:51.
        _ = try await harness.core.commands.calibrateXY(
            page: page,
            xFirst: PDFPoint(x: 0, y: 0), xSecond: PDFPoint(x: 100, y: 0), xKnownLength: Decimal(string: "4.9")!,
            yFirst: PDFPoint(x: 0, y: 0), ySecond: PDFPoint(x: 0, y: 100), yKnownLength: Decimal(string: "5.1")!,
            knownLengthUnit: .metre
        )
        await harness.settle()
        let reason = MeasurementWarningSummary.circleNeedsUniformScale.message

        // The toolbar path a person takes: the chip arms the tool, the shell names it.
        harness.shell.toolbar.activateMeasurement(.radius)
        // Old output: no note at all until the second click put raw engine text in the tray.
        #expect(harness.core.status.snapshot.activeToolName == MeasurementKind.radius.displayName)
        #expect(harness.core.status.snapshot.activeToolNote == reason)

        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 200), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.isEmpty)
        #expect(harness.core.status.snapshot.activeToolNote == reason)
        #expect(!harness.core.status.warnings.contains { $0.message.contains("scaleApplication") })
        #expect(await harness.records().isEmpty)
    }

    /// L-102 re-fix through the canvas: the first click is judged by the scale where it lands, so
    /// a uniform detail region on the X/Y sheet measures a radius and the bare sheet refuses it.
    @Test("L-102: on an X/Y sheet the canvas measures a radius inside a uniform Scale Region and refuses one outside")
    func radiusInsideAUniformRegion() async throws {
        let harness = try await Fix2Harness.make("L102Region.pdf", calibrate: false)
        defer { harness.tearDown() }
        let page = try #require(await harness.core.session.firstPageID)
        _ = try await harness.core.commands.calibrateXY(
            page: page,
            xFirst: PDFPoint(x: 0, y: 0), xSecond: PDFPoint(x: 100, y: 0), xKnownLength: Decimal(string: "4.9")!,
            yFirst: PDFPoint(x: 0, y: 0), ySecond: PDFPoint(x: 0, y: 100), yKnownLength: Decimal(string: "5.1")!,
            knownLengthUnit: .metre
        )
        let detail = try await harness.core.session.addRegionPresetScale(
            page: page, ratioDenominator: 20,
            boundary: [PDFPoint(x: 50, y: 50), PDFPoint(x: 250, y: 50), PDFPoint(x: 250, y: 250), PDFPoint(x: 50, y: 250)],
            name: "Detail 3"
        )
        var snap = await harness.core.session.currentSnapSettings
        snap.enabledKinds = []
        try await harness.core.session.setSnapSettings(snap)
        await harness.settle()

        harness.shell.toolbar.activateMeasurement(.radius)
        // Old output: "This sheet has separate X and Y scales, so a circle drawn on it has no single
        // radius. Calibrate one scale for both directions to measure circles." — and every click refused.
        #expect(harness.core.status.snapshot.activeToolNote
            == "Outside its Scale Regions this sheet has separate X and Y scales. Measure circles inside a Scale Region that has one scale for both directions.")

        // Outside the detail: refused, nothing placed, said in words.
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 400), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.isEmpty)
        #expect(harness.core.status.snapshot.activeToolNote == MeasurementWarningSummary.circleNeedsUniformScaleHere.message)

        // Inside it: centre and edge, and the radius lands at the detail's scale.
        harness.canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 1, "old output: 0 — the click was refused")
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 150), additive: false)
        #expect(await AppTestSupport.wait { harness.core.ledger.rowCount == 1 })
        let stored = try #require(await harness.records().first)
        #expect(stored.tool == .radius)
        #expect(stored.scaleRegionID == detail.regionID)
        // 50 pt at 1:20 = 50 × 20 × 0.0254 / 72 m.
        let radius = try #require(stored.measurement?.values[.radius]?.value)
        #expect(abs(NSDecimalNumber(decimal: radius).doubleValue - 50 * 20 * 0.0254 / 72) < 1e-9)
        #expect(!harness.core.status.warnings.contains { $0.message.contains("scaleApplication") })
    }

    @Test("L-99: the Pen's status hint is the drag that draws it, not the shape tools' finishes")
    func penHint() {
        let pen = ZenitToolMode.markup(.freehand)
        // Old output: "⇧ square · Return, double-click or secondary click to finish".
        #expect(PDFCanvasViewController.gestureHint(gesture: pen.gesture, placedCount: 0)
            == "Drag to draw · release to finish")
        // The box tools keep theirs.
        let rectangle = ZenitToolMode.markup(.rectangle)
        #expect(PDFCanvasViewController.gestureHint(gesture: rectangle.gesture, placedCount: 0)?
            .contains("⇧ straight") == true)
    }
}
