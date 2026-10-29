import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFUIShell
@testable import ZenitPDFAppKit

/// L-108: the project window counts left presses by place before AppKit dispatches them, so a
/// press within the double-click interval of a click somewhere else is a first click. These tests
/// drive the shipping window and canvas with presses counted by that window — the window is never
/// ordered on screen, so each counted press is delivered to the view AppKit would give it — and
/// prove the canvas's own double-click and single click still do what they did. The routing that
/// lost the click (a press counted 2 goes to the previous press's view) is replayed on the real
/// controls in `zpdf-hit-probe` [L-108].
@MainActor
@Suite("L-108: presses counted by the project window", .appTierSerialised, .serialized)
struct L108WindowClickTests {

    /// A press or release at a page point, at an explicit time, counted by the system as given.
    private static func event(
        _ type: NSEvent.EventType, at point: PDFPointValue, systemCount: Int, time: TimeInterval,
        harness: Fix2Harness
    ) throws -> NSEvent {
        let page = harness.canvas.pageViewForTesting
        let transform = try #require(page.transform)
        let windowPoint = page.convert(transform.viewPoint(from: point), to: nil)
        return try #require(NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: [], timestamp: time,
            windowNumber: page.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: systemCount, pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    /// One click on the canvas: counted by the project window, then delivered to the page view.
    /// Returns the count the press was dispatched with.
    @discardableResult
    private static func click(
        _ point: PDFPointValue, systemCount: Int = 1, at time: TimeInterval,
        window: ZPDFProjectWindow, harness: Fix2Harness
    ) throws -> Int {
        let page = harness.canvas.pageViewForTesting
        let down = window.clickCountedEvent(try event(.leftMouseDown, at: point, systemCount: systemCount, time: time, harness: harness))
        let up = window.clickCountedEvent(try event(.leftMouseUp, at: point, systemCount: systemCount, time: time + 0.05, harness: harness))
        page.mouseDown(with: down)
        page.mouseUp(with: up)
        return down.clickCount
    }

    @Test("A double-click that finishes an area still reaches the canvas as a double-click")
    func canvasDoubleClickFinishesTheArea() async throws {
        let harness = try await Fix2Harness.make("L108 Area.pdf")
        defer { harness.tearDown() }
        let window = try #require(harness.controller.window as? ZPDFProjectWindow)
        let page = harness.canvas.pageViewForTesting
        var doubleClicks = 0
        let finish = page.onDoubleClick
        page.onDoubleClick = { point in
            doubleClicks += 1
            finish?(point)
        }
        harness.shell.toolbar.activateMeasurement(.area)
        harness.canvas.refresh()
        let start = ProcessInfo.processInfo.systemUptime
        for (index, corner) in [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 400, y: 100), PDFPointValue(x: 400, y: 400)].enumerated() {
            #expect(try Self.click(corner, at: start + Double(index), window: window, harness: harness) == 1)
            await harness.core.measurement.settlePlacements()
        }
        // The fourth corner, double-clicked. (A hand's drift inside the slop is the shell suite's
        // and the probe's; here the page's zoom would scale it.)
        let last = PDFPointValue(x: 100, y: 400)
        #expect(try Self.click(last, at: start + 5, window: window, harness: harness) == 1)
        await harness.core.measurement.settlePlacements()
        let second = try Self.click(last, systemCount: 2, at: start + 5.2, window: window, harness: harness)
        await harness.core.measurement.settlePlacements()
        #expect(second == 2, "the window kept the double-click")
        #expect(doubleClicks == 1, "the canvas heard one double-click")
        #expect(await Self.eventually { await harness.records().contains { $0.tool == .area } }, "the area was committed")
        #expect(harness.core.measurement.placedPoints.isEmpty, "nothing is left in progress: \(harness.core.measurement.placedPoints)")
    }

    @Test("A canvas click right after the Length chip is a first click, and places Length's first point")
    func canvasClickAfterTheChip() async throws {
        let harness = try await Fix2Harness.make("L108 Chip.pdf")
        defer { harness.tearDown() }
        let window = try #require(harness.controller.window as? ZPDFProjectWindow)
        let band = try #require(Self.firstBand(in: window.contentView))
        let chip = try #require(band.centreEntries.first { $0.identifier == .zenitLength }?.view)
        let chipFrame = chip.convert(chip.bounds, to: nil)
        let start = ProcessInfo.processInfo.systemUptime
        // The press on the chip, counted by the window; arming is the chip's action.
        _ = window.clickCountedEvent(try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: chipFrame.midX, y: chipFrame.midY), modifierFlags: [],
            timestamp: start, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )))
        harness.shell.toolbar.activateMeasurement(.length)
        // The canvas 0.25 s later, counted 2 by the system. Old: dispatched counted 2, which AppKit
        // sends to the chip, not to the canvas.
        let count = try Self.click(PDFPointValue(x: 120, y: 300), systemCount: 2, at: start + 0.25, window: window, harness: harness)
        await harness.core.measurement.settlePlacements()
        #expect(count == 1)
        #expect(harness.core.measurement.placedPoints.count == 1)
    }

    private static func eventually(upTo seconds: Double = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private static func firstBand(in view: NSView?) -> ProjectTopBandView? {
        guard let view else { return nil }
        if let band = view as? ProjectTopBandView { return band }
        for subview in view.subviews {
            if let band = firstBand(in: subview) { return band }
        }
        return nil
    }
}
