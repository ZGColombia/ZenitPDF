import AppKit
import Foundation
import Observation
import os
import ZPDFUIPresentation
import Testing
import ZPDFAppCore
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// CR-148 (observation chains accumulate per tab return) and CR-149 (a stale Scale Region
/// calibration target redirects the next page calibration).
@MainActor
@Suite(.appTierSerialised)
struct CanvasObservationAndCalibrationTargetTests {

    private func makeHarness(
        _ name: String
    ) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, AppCoreEnvironment, PDFCanvasViewController) {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)
        let canvas = try #require(controller.canvasController(for: document))
        return (document, controller, core, canvas)
    }

    @Test("Canvas layout observes zoom geometry but never the per-move cursor")
    func layoutDoesNotObserveCursor() async throws {
        let harness = try await Fix2Harness.make("LoupeLayoutObservation.pdf")
        defer { harness.tearDown() }
        await harness.settle()
        harness.canvas.viewDidLayout()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            harness.canvas.viewDidLayout()
        } onChange: {
            changed.withLock { $0 = true }
        }
        harness.core.canvas.updateCursor(pagePoint: PDFPointValue(x: 123, y: 234))
        #expect(!changed.withLock { $0 }, "a cursor update must not schedule AppKit layout")
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 1.1)
        #expect(changed.withLock { $0 }, "a real geometry change must still invalidate layout")
    }

    @Test("Returning to a tab three times leaves ONE observation chain, not four")
    func observationChainsDoNotAccumulate() async throws {
        let (document, _, core, canvas) = try await makeHarness("ObserveOnce.pdf")
        defer { document.close() }
        // Three tab returns. Before CR-148 each `viewDidAppear` armed one more permanent,
        // self-re-arming chain: one selection change below then ran `refresh()` three
        // times (measured 3 with this test on the old code), and N+1 after N returns.
        canvas.viewDidAppear()
        canvas.viewDidAppear()
        canvas.viewDidAppear()
        try await Task.sleep(for: .milliseconds(200))
        canvas.refreshCountForTesting = 0

        core.canvas.select(markupIDs: [UUID()], additive: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(canvas.refreshCountForTesting == 1,
                "CR-148: one observed change must refresh once — got \(canvas.refreshCountForTesting)")

        // The surviving chain still re-arms: a second change refreshes again, once.
        canvas.refreshCountForTesting = 0
        core.canvas.clearSelection()
        try await Task.sleep(for: .milliseconds(250))
        #expect(canvas.refreshCountForTesting == 1,
                "the retained chain re-arms after firing — got \(canvas.refreshCountForTesting)")
    }

    // "Unticking a markup layer in the Navigator reaches the canvas's draw list" (CR-112) went
    // with the path it pinned: that hook could not fire once a window installs the project's
    // markup layers, and was deleted as dead code (X-009, Iter7AppCanvasTests).

    @Test("Measure ▸ Calibrate Scale… calibrates the page even after a region calibration was abandoned")
    func menuCalibrationClearsAStaleRegionTarget() async throws {
        let (document, controller, _, canvas) = try await makeHarness("StaleTarget.pdf")
        defer { document.close() }
        // The live shape: the Scale Regions panel set its destination, the person pressed
        // Escape, and the destination stayed. Before CR-149 the next Calibrate Scale…
        // created a second scale and assigned it to the old region — page still "No scale".
        document.pendingScaleCalibration = .region(UUID())

        let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZenitAppCommand.calibrateScale.rawValue
        controller.performZenitCommand(item)
        // NL-MEASURE-01: the menu command opens the calibration sheet for the page.
        #expect(ScaleSheetCoordinator.active(for: document) != nil, "the menu command opens the scale sheet")
        #expect(document.pendingScaleCalibration == nil,
                "CR-149: the page command must not inherit a region's destination")
        ScaleSheetCoordinator.active(for: document)?.cancel()
        _ = canvas
    }

    @Test("Escape drops the region destination; collecting both points keeps it for the finish")
    func cancelDropsTheTargetAndFinishKeepsIt() async throws {
        let (document, _, _, canvas) = try await makeHarness("TargetLifetime.pdf")
        defer { document.close() }

        // The panel's own path sets its destination and starts the same two-click flow.
        document.pendingScaleCalibration = .draft
        document.onBeginCalibration?()
        #expect(canvas.isCalibrating)
        #expect(document.pendingScaleCalibration == .draft, "the panel's destination is kept while calibrating")
        canvas.endCalibration()  // Escape
        #expect(document.pendingScaleCalibration == nil,
                "CR-149: an abandoned calibration must not leave its destination behind")

        document.pendingScaleCalibration = .draft
        document.onBeginCalibration?()
        canvas.endCalibration(collected: true)  // the second point landed
        #expect(document.pendingScaleCalibration == .draft,
                "a completed calibration keeps its destination for finishCalibration to consume")
        document.pendingScaleCalibration = nil
    }
}
