import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell

// L-108 (live 2026-10-05): a click on another control within about 0.4 s of a click on the
// canvas was ignored — Inspector Comments stayed on Properties, Navigator Layers stayed on Pages,
// the Length chip did not arm — while the same click 0.6 s later, or a second Inspector tab
// clicked 0.3 s after the first, worked.
//
// The cause is AppKit's routing, not the controls. The system counts every press inside the
// double-click interval, wherever it lands, so the second press arrives with `clickCount == 2`;
// and `-[NSWindow _handleMouseDownEvent:isDelayedEvent:]` (read from AppKit's code, macOS 26)
// sends a left press counted 2 or more to `_lastLeftHit` — the view that took the window's
// previous left press — without hit-testing. The press on the tab went to the canvas, outside its
// page, and was dropped there. Two tabs in one strip worked because both live in one hosting view.
//
// A window that is never ordered in does not dispatch a mouse event at all (AppKit returns before
// hit-testing unless the window is visible), so the probe cannot run AppKit's dispatcher. It runs
// the rule instead — ``AppKitPressRoute`` below, one line of it — on the real project window, with
// its real controls, and every event goes through `ZPDFProjectWindow.clickCountedEvent(_:)`, the
// function the window's `sendEvent(_:)` runs before AppKit sees the event.

#if DEBUG || ZPDF_MOCKS

/// AppKit's choice of the view a left press goes to, as `_handleMouseDownEvent:isDelayedEvent:`
/// makes it: a press counted 2 or more goes to the view that took the previous left press, any
/// other press to the view hit-testing finds. A release goes to its press's view.
@MainActor
final class AppKitPressRoute {
    private(set) var lastLeftHit: NSView?

    func target(for event: NSEvent, in window: NSWindow) -> NSView? {
        guard event.type == .leftMouseDown else { return lastLeftHit }
        if event.clickCount >= 2, let lastLeftHit { return lastLeftHit }
        lastLeftHit = window.contentView?.superview?.hitTest(event.locationInWindow)
        return lastLeftHit
    }
}

/// How a press reaches AppKit's routing in ``l108Scenario()``.
enum L108Path: String, CaseIterable {
    /// With the count the system gave it — the window before the fix.
    case systemCount = "system count"
    /// Through `ZPDFProjectWindow.clickCountedEvent(_:)`, as the window's `sendEvent(_:)` hands it on.
    case projectWindow = "project window"
}

/// What one routed click did.
struct L108Delivery {
    var target: NSView?
    var count: Int
}

/// One click, press and release, `seconds` after `start`, counted `systemCount` by the system,
/// routed by AppKit's rule and delivered like ``click(_:in:)``. `deliver: false` counts and
/// routes the press without delivering it — for the top band, whose single press starts a window
/// drag.
@MainActor
@discardableResult
func l108Click(
    _ point: NSPoint, systemCount: Int, at seconds: TimeInterval, from start: TimeInterval,
    in window: ZPDFProjectWindow, route: AppKitPressRoute, path: L108Path, deliver: Bool = true
) -> L108Delivery {
    let time = start + seconds
    guard
        var down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: systemCount, pressure: 1
        ),
        var up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: systemCount, pressure: 0
        )
    else { return L108Delivery(target: nil, count: -1) }
    if path == .projectWindow {
        down = window.clickCountedEvent(down)
        up = window.clickCountedEvent(up)
    }
    let target = route.target(for: down, in: window)
    guard deliver, let target else { return L108Delivery(target: target, count: down.clickCount) }
    NSApp.postEvent(up, atStart: false)
    target.mouseDown(with: down)
    if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
        target.mouseUp(with: pending)
    }
    spin(0.15)
    return L108Delivery(target: target, count: down.clickCount)
}

@MainActor
func centre(_ view: NSView) -> NSPoint {
    let frame = view.convert(view.bounds, to: nil)
    return NSPoint(x: frame.midX, y: frame.midY)
}

@MainActor
func describe(_ view: NSView?) -> String {
    guard let view else { return "nothing" }
    let name = String(describing: type(of: view))
    if name.contains("Canvas") { return "the canvas" }
    if name.contains("InspectorPanel") { return "the Inspector" }
    if name.contains("Navigator") { return "the Navigator" }
    if name.contains("ZenitToolChip") { return "a toolbar chip" }
    if view is ProjectTopBandView { return "the top band" }
    return name
}

/// A control live test L-108 clicked 0.25 s after a canvas click — a press the system counted 2.
struct L108Control {
    let name: String
    /// The control's landmark, when it has one.
    var marker: String?
    /// The control's centre, in the window, when it has no landmark.
    var point: (ProjectWindowLayoutController) -> NSPoint? = { _ in nil }
    /// Whether the click took effect.
    let tookEffect: (ProjectWindowLayoutController, ProjectShellEnvironment) -> Bool
    /// What the control shows.
    let state: (ProjectWindowLayoutController, ProjectShellEnvironment) -> String
}

@MainActor
func l108Controls() -> [L108Control] {
    [
        L108Control(
            name: "Inspector Comments tab",
            marker: InspectorTab.comments.markerIdentifier,
            tookEffect: { layout, _ in layout.panelState.inspectorTab == .comments },
            state: { layout, _ in "Inspector on \(layout.panelState.inspectorTab.title)" }
        ),
        L108Control(
            name: "Navigator Layers tab",
            marker: NavigatorSection.layers.markerIdentifier,
            tookEffect: { layout, _ in layout.panelState.navigatorSection == .layers },
            state: { layout, _ in "Navigator on \(layout.panelState.navigatorSection.rawValue)" }
        ),
        L108Control(
            name: "toolbar Length chip",
            point: { layout in
                layout.topBand?.centreEntries.first(where: { $0.identifier == .zenitLength }).map { centre($0.view) }
            },
            tookEffect: { _, env in env.toolbar.activeTool == .length },
            state: { _, env in "tool \(env.toolbar.activeTool)" }
        )
    ]
}

@MainActor
func l108Point(of control: L108Control, layout: ProjectWindowLayoutController, window: NSWindow) -> NSPoint? {
    if let marker = control.marker {
        return Host.frame(ofMarker: marker, in: window).map { NSPoint(x: $0.midX, y: $0.midY) }
    }
    return control.point(layout)
}

/// L-108: a click on a control right after a click on the canvas reaches the control; a real
/// double-click still arrives as one, at the view that took its first press.
@MainActor
func l108Scenario() {
    print("\n[L-108] a click on a control within the double-click interval of a canvas click (L-108)")

    // The suspect first: does a SwiftUI control drop a press counted 2? Delivered to the tab's own
    // view, with nothing before it, it does not — the count is not what loses the click.
    do {
        let env = ProjectShellEnvironment.mock()
        let (layout, window) = makeBandHost(env)
        defer { window.close() }
        if let comments = Host.frame(ofMarker: InspectorTab.comments.markerIdentifier, in: window) {
            let point = NSPoint(x: comments.midX, y: comments.midY)
            let route = AppKitPressRoute()
            // A fresh route has no previous press, so even a press counted 2 is hit-tested.
            let delivery = l108Click(point, systemCount: 2, at: 0, from: ProcessInfo.processInfo.systemUptime, in: window, route: route, path: .systemCount)
            check(
                layout.panelState.inspectorTab == .comments,
                "[L-108] a press counted 2, delivered to the Comments tab's own view (\(describe(delivery.target))), opens Comments: the count alone loses nothing (open: \(layout.panelState.inspectorTab.title))"
            )
        } else {
            check(false, "[L-108] the Comments tab can be found in the project window")
        }
    }

    for control in l108Controls() {
        for path in L108Path.allCases {
            let env = ProjectShellEnvironment.mock()
            let (layout, window) = makeBandHost(env)
            defer { window.close() }
            guard let canvas = layout.canvasPane?.canvasController.view,
                  let point = l108Point(of: control, layout: layout, window: window)
            else {
                check(false, "[L-108, \(path.rawValue)] the canvas and the \(control.name) can be found")
                continue
            }
            let route = AppKitPressRoute()
            let start = ProcessInfo.processInfo.systemUptime
            let canvasPoint = centre(canvas)
            let first = l108Click(canvasPoint, systemCount: 1, at: 0, from: start, in: window, route: route, path: path)
            let before = control.tookEffect(layout, env)
            let second = l108Click(point, systemCount: 2, at: 0.25, from: start, in: window, route: route, path: path)
            let took = control.tookEffect(layout, env)
            let line = "canvas click to \(describe(first.target)), then the \(control.name) 0.25 s later went to \(describe(second.target)) counted \(second.count): \(control.state(layout, env))"
            switch path {
            case .systemCount:
                // The rule reproduces the live finding, or the project-window check proves nothing.
                check(
                    !before && !took && describe(second.target) == "the canvas",
                    "[L-108, as before the fix] \(line) — the live finding reproduced"
                )
            case .projectWindow:
                check(!before && took && second.count == 1, "[L-108] \(line)")
            }
        }
    }

    // The other way round: a chip, then the canvas 0.25 s later (L-36b's live sequence).
    for path in L108Path.allCases {
        let env = ProjectShellEnvironment.mock()
        let (layout, window) = makeBandHost(env)
        defer { window.close() }
        guard let canvas = layout.canvasPane?.canvasController.view,
              let chip = layout.topBand?.centreEntries.first(where: { $0.identifier == .zenitLength })?.view
        else {
            check(false, "[L-108, \(path.rawValue)] the Length chip and the canvas can be found")
            continue
        }
        let route = AppKitPressRoute()
        let start = ProcessInfo.processInfo.systemUptime
        l108Click(centre(chip), systemCount: 1, at: 0, from: start, in: window, route: route, path: path)
        let armed = env.toolbar.activeTool == .length
        let second = l108Click(centre(canvas), systemCount: 2, at: 0.25, from: start, in: window, route: route, path: path)
        let line = "the Length chip (armed: \(armed)), then the canvas 0.25 s later: the press went to \(describe(second.target)) counted \(second.count)"
        switch path {
        case .systemCount:
            check(armed && describe(second.target) == "a toolbar chip", "[L-108, as before the fix] \(line) — the canvas never heard of it")
        case .projectWindow:
            check(armed && describe(second.target) == "the canvas" && second.count == 1, "[L-108] \(line)")
        }
    }

    // A real double-click is two presses at one place: it keeps its count and its first view.
    do {
        let env = ProjectShellEnvironment.mock()
        let (layout, window) = makeBandHost(env)
        defer { window.close() }
        guard let canvas = layout.canvasPane?.canvasController.view,
              let band = layout.topBand,
              let comments = Host.frame(ofMarker: InspectorTab.comments.markerIdentifier, in: window)
        else {
            check(false, "[L-108 double-clicks] the canvas, the band and the Comments tab can be found")
            return
        }
        let route = AppKitPressRoute()
        var start = ProcessInfo.processInfo.systemUptime

        // The canvas: finishing a shape. The second press 2 pt from the first, as a hand lands it.
        let point = centre(canvas)
        l108Click(point, systemCount: 1, at: 0, from: start, in: window, route: route, path: .projectWindow)
        let canvasSecond = l108Click(NSPoint(x: point.x + 2, y: point.y - 1), systemCount: 2, at: 0.2, from: start, in: window, route: route, path: .projectWindow)
        check(
            canvasSecond.count == 2 && describe(canvasSecond.target) == "the canvas",
            "[L-108 double-clicks] a double-click on the canvas arrives at the canvas counted 2 (\(describe(canvasSecond.target)), \(canvasSecond.count))"
        )
        // A third press there is a triple-click, whatever ran before it in the window.
        let canvasThird = l108Click(point, systemCount: 3, at: 0.4, from: start, in: window, route: route, path: .projectWindow)
        check(canvasThird.count == 3, "[L-108 double-clicks] a third press at the same place counts 3 (\(canvasThird.count))")

        // An Inspector tab: a double-click on Comments right after a canvas click keeps the tab
        // open and counts from the tab's own first press.
        start += 5
        let tab = NSPoint(x: comments.midX, y: comments.midY)
        l108Click(point, systemCount: 1, at: 0, from: start, in: window, route: route, path: .projectWindow)
        let tabFirst = l108Click(tab, systemCount: 2, at: 0.25, from: start, in: window, route: route, path: .projectWindow)
        let tabSecond = l108Click(tab, systemCount: 3, at: 0.45, from: start, in: window, route: route, path: .projectWindow)
        check(
            tabFirst.count == 1 && tabSecond.count == 2 && describe(tabSecond.target) == "the Inspector"
                && layout.panelState.inspectorTab == .comments,
            "[L-108 double-clicks] canvas, then a double-click on Comments: counted \(tabFirst.count) then \(tabSecond.count), at \(describe(tabSecond.target)), Comments open: \(layout.panelState.inspectorTab == .comments)"
        )

        // The top band's empty area: the titlebar double-click. Counted and routed, never
        // delivered: the band's single press starts a window drag and its double-click zooms the
        // window, neither of which a window that is never ordered in should do. That the band
        // zooms on a press counted 2 is the package suite's to show.
        start += 5
        let bandFrame = band.convert(band.bounds, to: nil)
        let empty = (0..<200).lazy
            .map { NSPoint(x: bandFrame.minX + 300 + CGFloat($0) * 4, y: bandFrame.minY + 8) }
            .first { window.contentView?.superview?.hitTest($0) === band }
        guard let empty else {
            check(false, "[L-108 double-clicks] the band has an empty area to double-click")
            return
        }
        let bandFirst = l108Click(empty, systemCount: 1, at: 0, from: start, in: window, route: route, path: .projectWindow, deliver: false)
        let bandSecond = l108Click(empty, systemCount: 2, at: 0.2, from: start, in: window, route: route, path: .projectWindow, deliver: false)
        check(
            bandFirst.target === band && bandSecond.target === band && bandSecond.count == 2,
            "[L-108 double-clicks] a double-click on the band's empty area reaches the band counted 2, its titlebar double-click (\(describe(bandSecond.target)), \(bandSecond.count))"
        )
        // A canvas click, then a press on the band 0.25 s later: a first press (a drag), not a zoom.
        start += 5
        l108Click(point, systemCount: 1, at: 0, from: start, in: window, route: route, path: .projectWindow)
        let bandAfterCanvas = l108Click(empty, systemCount: 2, at: 0.25, from: start, in: window, route: route, path: .projectWindow, deliver: false)
        check(
            bandAfterCanvas.target === band && bandAfterCanvas.count == 1,
            "[L-108 double-clicks] a press on the band right after a canvas click reaches the band counted 1, a drag rather than a titlebar double-click (\(describe(bandAfterCanvas.target)), \(bandAfterCanvas.count))"
        )
    }
}

#endif
