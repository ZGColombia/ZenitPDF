import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// L-108 (live 2026-10-05): a click on an Inspector tab, a Navigator tab or a toolbar chip within
/// half a second of a canvas click was ignored. The system counted the second press 2, and AppKit
/// sends a press counted 2 or more to the view that took the previous press without hit-testing,
/// so it went to the canvas. ``ZPDFProjectWindow`` now counts presses by place before AppKit
/// dispatches them (``ZPDFClickCounter``). The routing itself is replayed on the real controls in
/// `zpdf-hit-probe` [L-108], because a window that is never ordered in dispatches no mouse event.
@MainActor
@Suite("L-108: a double-click is two presses at one place", .shellTierSerialised)
struct L108ClickCountTests {

    // MARK: - The rule

    @Test("A press far from the last one starts a new count; one at the same place continues it")
    func countRule() {
        var counter = ZPDFClickCounter()
        // The canvas click.
        #expect(counter.countForPress(systemCount: 1, timestamp: 10, location: CGPoint(x: 600, y: 400), interval: 0.5) == 1)
        #expect(counter.countForRelease(systemCount: 1) == 1)
        // The Inspector tab 0.25 s later, 800 pt away, counted 2 by the system: a first click.
        // Old: dispatched counted 2, which AppKit sent to the canvas.
        #expect(counter.countForPress(systemCount: 2, timestamp: 10.25, location: CGPoint(x: 1_400, y: 740), interval: 0.5) == 1)
        #expect(counter.pendingReleaseCount == 1)
        #expect(counter.countForRelease(systemCount: 2) == 1, "the release carries its press's count")
        // The same tab again, 2 pt off, counted 3 by the system: the second click of a double-click.
        #expect(counter.countForPress(systemCount: 3, timestamp: 10.45, location: CGPoint(x: 1_402, y: 739), interval: 0.5) == 2)
        #expect(counter.countForRelease(systemCount: 3) == 2)
        // And a third there: a triple-click.
        #expect(counter.countForPress(systemCount: 4, timestamp: 10.6, location: CGPoint(x: 1_401, y: 740), interval: 0.5) == 3)
        #expect(counter.countForRelease(systemCount: 4) == 3)
    }

    @Test("A real double-click keeps the system's count, and its release is left alone")
    func realDoubleClickUntouched() {
        var counter = ZPDFClickCounter()
        #expect(counter.countForPress(systemCount: 1, timestamp: 3, location: CGPoint(x: 100, y: 100), interval: 0.5) == 1)
        #expect(counter.countForRelease(systemCount: 1) == 1)
        // 4 pt apart, inside the 5 pt slop.
        #expect(counter.countForPress(systemCount: 2, timestamp: 3.2, location: CGPoint(x: 104, y: 100), interval: 0.5) == 2)
        #expect(counter.pendingReleaseCount == nil)
        #expect(counter.countForRelease(systemCount: 2) == 2)
    }

    @Test("Outside the slop, outside the interval, or with no press before it, a press is a first click")
    func firstClickCases() {
        // Just outside the slop.
        var counter = ZPDFClickCounter()
        _ = counter.countForPress(systemCount: 1, timestamp: 1, location: CGPoint(x: 0, y: 0), interval: 0.5)
        #expect(counter.countForPress(systemCount: 2, timestamp: 1.1, location: CGPoint(x: ZPDFClickCounter.slop + 0.5, y: 0), interval: 0.5) == 1)
        // On the slop: still a double-click.
        counter = ZPDFClickCounter()
        _ = counter.countForPress(systemCount: 1, timestamp: 1, location: CGPoint(x: 0, y: 0), interval: 0.5)
        #expect(counter.countForPress(systemCount: 2, timestamp: 1.1, location: CGPoint(x: 3, y: 4), interval: 0.5) == 2)
        // The window's last press is older than the interval: the system's pair began elsewhere
        // (another window).
        counter = ZPDFClickCounter()
        _ = counter.countForPress(systemCount: 1, timestamp: 1, location: CGPoint(x: 0, y: 0), interval: 0.5)
        #expect(counter.countForPress(systemCount: 2, timestamp: 1.8, location: CGPoint(x: 0, y: 0), interval: 0.5) == 1)
        // The window has seen no press at all.
        counter = ZPDFClickCounter()
        #expect(counter.countForPress(systemCount: 2, timestamp: 1, location: CGPoint(x: 0, y: 0), interval: 0.5) == 1)
        // A press counted 1 by the system is never changed, and its release neither.
        counter = ZPDFClickCounter()
        #expect(counter.countForPress(systemCount: 1, timestamp: 1, location: CGPoint(x: 0, y: 0), interval: 0.5) == 1)
        #expect(counter.countForRelease(systemCount: 1) == 1)
        // A release whose press never came through (an AppKit tracking loop took it) keeps its count.
        #expect(counter.countForRelease(systemCount: 2) == 2)
    }

    @Test("The canvas's double-click distance is the window's")
    func oneSlop() {
        #expect(ZPDFClickCounter.slop == 5)
    }

    // MARK: - The window

    private static func makeWindow() -> (ProjectWindowLayoutController, ZPDFProjectWindow) {
        let layout = ProjectWindowLayoutController(
            environment: .mock(),
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "l108.window")
        )
        layout.presentDetachedLedgerWindow = { _ in }
        layout.detachedLedgerAutosaveName = ""
        layout.runCustomizationPalette = { _ in }
        let window = ZPDFProjectWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = layout
        layout.configure(window: window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1_440, height: 900), display: false)
        window.layoutIfNeeded()
        layout.view.layoutSubtreeIfNeeded()
        return (layout, window)
    }

    private static func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, count: Int, time: TimeInterval,
        in window: NSWindow, flags: NSEvent.ModifierFlags = [], eventNumber: Int = 7
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
            clickCount: count, pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    @Test("The window re-counts a far press to 1 and keeps everything else about it")
    func windowRewritesTheFarPress() throws {
        let (_, window) = Self.makeWindow()
        defer { window.close() }
        let start = ProcessInfo.processInfo.systemUptime
        let canvasDown = try Self.mouse(.leftMouseDown, at: NSPoint(x: 600, y: 400), count: 1, time: start, in: window)
        #expect(window.clickCountedEvent(canvasDown) === canvasDown, "a first press passes untouched")
        let canvasUp = try Self.mouse(.leftMouseUp, at: NSPoint(x: 600, y: 400), count: 1, time: start + 0.05, in: window)
        #expect(window.clickCountedEvent(canvasUp) === canvasUp)

        let tabDown = try Self.mouse(.leftMouseDown, at: NSPoint(x: 1_300, y: 760), count: 2, time: start + 0.25, in: window, flags: [.shift], eventNumber: 9)
        let counted = window.clickCountedEvent(tabDown)
        #expect(counted.clickCount == 1, "old: 2, which AppKit sends to the canvas")
        #expect(counted.type == .leftMouseDown)
        #expect(counted.locationInWindow == tabDown.locationInWindow)
        #expect(counted.timestamp == tabDown.timestamp)
        #expect(counted.windowNumber == window.windowNumber)
        #expect(counted.eventNumber == 9)
        #expect(counted.modifierFlags.contains(.shift))
        #expect(counted.pressure == tabDown.pressure)
        let tabUp = try Self.mouse(.leftMouseUp, at: NSPoint(x: 1_300, y: 760), count: 2, time: start + 0.3, in: window, eventNumber: 9)
        #expect(window.clickCountedEvent(tabUp).clickCount == 1, "the release follows its press")

        // Other events pass untouched.
        let right = try Self.mouse(.rightMouseDown, at: NSPoint(x: 1_300, y: 760), count: 2, time: start + 0.32, in: window)
        #expect(window.clickCountedEvent(right) === right)
        let moved = try Self.mouse(.mouseMoved, at: NSPoint(x: 1_200, y: 700), count: 0, time: start + 0.33, in: window)
        #expect(window.clickCountedEvent(moved) === moved)
    }

    @Test("A double-click at one place passes through the window as the system counted it")
    func windowKeepsARealDoubleClick() throws {
        let (_, window) = Self.makeWindow()
        defer { window.close() }
        let start = ProcessInfo.processInfo.systemUptime
        let point = NSPoint(x: 600, y: 400)
        _ = window.clickCountedEvent(try Self.mouse(.leftMouseDown, at: point, count: 1, time: start, in: window))
        _ = window.clickCountedEvent(try Self.mouse(.leftMouseUp, at: point, count: 1, time: start + 0.05, in: window))
        let second = try Self.mouse(.leftMouseDown, at: NSPoint(x: 602, y: 399), count: 2, time: start + 0.2, in: window)
        #expect(window.clickCountedEvent(second) === second)
        let secondUp = try Self.mouse(.leftMouseUp, at: NSPoint(x: 602, y: 399), count: 2, time: start + 0.25, in: window)
        #expect(window.clickCountedEvent(secondUp) === secondUp)
    }

    @Test("sendEvent runs the count before AppKit sees the event")
    func sendEventCounts() throws {
        let (_, window) = Self.makeWindow()
        defer { window.close() }
        let start = ProcessInfo.processInfo.systemUptime
        // A window that is never ordered in dispatches nothing, but the override runs first.
        window.sendEvent(try Self.mouse(.leftMouseDown, at: NSPoint(x: 600, y: 400), count: 1, time: start, in: window))
        window.sendEvent(try Self.mouse(.leftMouseUp, at: NSPoint(x: 600, y: 400), count: 1, time: start + 0.05, in: window))
        window.sendEvent(try Self.mouse(.leftMouseDown, at: NSPoint(x: 1_300, y: 760), count: 2, time: start + 0.25, in: window))
        let last = try #require(window.clickCounter.lastPress)
        #expect(last.count == 1 && last.location == NSPoint(x: 1_300, y: 760), "counted \(last)")
        #expect(window.clickCounter.pendingReleaseCount == 1)
    }

    @Test("The top band's titlebar double-click still zooms; a press there right after a canvas click does not")
    func bandDoubleClickSurvives() throws {
        let (layout, window) = Self.makeWindow()
        defer { window.close() }
        let band = try #require(layout.topBand)
        var actions: [ProjectTopBandView.DoubleClickAction] = []
        band.readGlobalDefault = { $0 == "AppleActionOnDoubleClick" ? "Maximize" : nil }
        band.performWindowAction = { action, target in
            actions.append(action)
            #expect(target === window)
        }
        let frame = band.convert(band.bounds, to: nil)
        let empty = NSPoint(x: frame.midX, y: frame.minY + 8)
        let start = ProcessInfo.processInfo.systemUptime
        // The double-click: the first press is counted (its delivery starts a window drag, which
        // a test window must not do), the second is counted and delivered to the band, as AppKit
        // sends a press counted 2 to the view that took the first.
        _ = window.clickCountedEvent(try Self.mouse(.leftMouseDown, at: empty, count: 1, time: start, in: window))
        _ = window.clickCountedEvent(try Self.mouse(.leftMouseUp, at: empty, count: 1, time: start + 0.05, in: window))
        let second = window.clickCountedEvent(try Self.mouse(.leftMouseDown, at: NSPoint(x: empty.x + 1, y: empty.y), count: 2, time: start + 0.2, in: window))
        #expect(second.clickCount == 2)
        band.mouseDown(with: second)
        #expect(actions == [.zoom])

        // A canvas click, then the band 0.25 s later: a first press, a drag rather than a zoom.
        // Old: counted 2 — AppKit gave it to the canvas.
        let canvas = try #require(layout.canvasPane?.canvasController.view)
        let canvasFrame = canvas.convert(canvas.bounds, to: nil)
        let canvasPoint = NSPoint(x: canvasFrame.midX, y: canvasFrame.midY)
        _ = window.clickCountedEvent(try Self.mouse(.leftMouseDown, at: canvasPoint, count: 1, time: start + 5, in: window))
        _ = window.clickCountedEvent(try Self.mouse(.leftMouseUp, at: canvasPoint, count: 1, time: start + 5.05, in: window))
        let afterCanvas = window.clickCountedEvent(try Self.mouse(.leftMouseDown, at: empty, count: 2, time: start + 5.25, in: window))
        #expect(afterCanvas.clickCount == 1)
    }
}
