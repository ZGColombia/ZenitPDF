import AppKit
import MachO
import ObjectiveC
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell

// zpdf-hit-probe — the hosted hit-target guard (NL-MARKUP-01, LT3-01).
//
// WHY AN EXECUTABLE. SwiftUI's hit-testing depends on the SDK stamped into the *main
// executable*. The shipped app is stamped with the macOS 14 SDK, and in that mode SwiftUI leaves
// a hosted AppKit control drawn at opacity 0.02 out of hit-testing: the Inspector's colour
// swatches — a painted square over a nearly transparent system colour well — did nothing when
// clicked. Every package test runs inside `xctest`, which is stamped with the current SDK and
// hit-tests the modern way, so no test could see it. SwiftPM stamps this executable with the
// package's macOS 14 deployment target, exactly like the app, and the probe checks that stamp
// before it believes anything else it measures.
//
// WHAT IT DOES. It hosts the real `InspectorPanel` over `ProjectShellEnvironment.mock()` in a
// borderless window at (-12000, -12000) that is **never ordered in** — nothing is shown, nothing
// takes focus, the app never activates (`.prohibited`). Then:
//
//   1. every hosted AppKit control in the panel must be reachable by `hitTest` at its centre;
//   2. both Markup-tab swatches (Border, Fill Colour) are clicked with synthetic events, the
//      palette must open, and a click on one of its inks must produce exactly one bulk style
//      edit with that colour — the fill keeping its own opacity;
//   3. "No Fill", "More Colours…" (through an injected colour-panel surface, a continuous
//      drag folding into one edit) and the recent-colours row;
//   4. the fill swatch must not overlap the Remove Fill button;
//   5. with nothing selected and a shape tool armed, the tool-style swatch must set the style
//      the next shape draws with, and a style edit to a drawn markup must become the tools'
//      "last used" style;
//   6. live test 8 (LiveTest8Scenarios.swift): a click anywhere on a back document tab selects
//      it (L-106), a click on each Inspector tab opens that tab (L-90) — also right after a reply
//      was posted on Comments, with no stale hover plate left behind — and the Shapes list opens
//      from its whole › and from a held press on the chip while a quick click still draws the
//      last shape (L-100) — the top band hosted in a project window that is never ordered in,
//      with its menu presentation swapped for a recorder;
//   7. L-108 (L108Scenarios.swift): a click on the Inspector Comments tab, the Navigator Layers tab
//      or the Length chip 0.25 s after a canvas click — counted 2 by the system — reaches that
//      control, and a canvas click right after a chip reaches the canvas, once the press has gone
//      through the project window's click count; real double-clicks (canvas, Inspector tab, the
//      band's titlebar area) keep their count and their first view. AppKit's routing rule is run
//      on the real project window, because a window never ordered in dispatches no mouse event;
//   8. CR-202 (CR202CloseScenarios.swift): a click on each workflow panel's rendered close button
//      (Tool Library, the OCR sheet's header and footer, Revision Compare, Revision Overlay, Split
//      Canvas) runs that panel's `onClose` exactly once — after controls showing that a button
//      which ignores its action, or a click beside it, closes nothing.
//
// The palette is presented through an injected off-screen presenter — the product's popover
// swapped for a window that is never ordered in — and the colour panel through an injected
// surface, so the probe clicks the real palette without anything reaching the screen. The
// shared `NSColorPanel`'s ordering is swizzled away as a second guard.
//
// Exit status: 0 when every check passes, 1 when any fails, 2 when the probe cannot run.

// The probe hosts `ProjectShellEnvironment.mock()`, which exists only in debug and test builds
// (R-142: a release build ships no mock). `verify-hosted-hit-targets.sh` builds it in debug.
#if DEBUG || ZPDF_MOCKS

// MARK: - Bookkeeping

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var passes = 0
nonisolated(unsafe) var colourPanelOrderings: [String] = []

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if condition {
        passes += 1
        print("  PASS  \(message())")
    } else {
        failures.append(message())
        print("  FAIL  \(message())")
    }
}

func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

extension NSColorPanel {
    @objc func probe_orderFront(_ sender: Any?) { colourPanelOrderings.append("orderFront") }
    @objc func probe_makeKeyAndOrderFront(_ sender: Any?) { colourPanelOrderings.append("makeKeyAndOrderFront") }
}

/// The SDK version stamped into this executable, as "major.minor".
func stampedSDK() -> (minos: String, sdk: String, sdkMajor: UInt32)? {
    guard let header = _dyld_get_image_header(0) else { return nil }
    var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
        let command = cursor.assumingMemoryBound(to: load_command.self).pointee
        if command.cmd == UInt32(LC_BUILD_VERSION) {
            let build = cursor.assumingMemoryBound(to: build_version_command.self).pointee
            func text(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xFF)" }
            return (text(build.minos), text(build.sdk), build.sdk >> 16)
        }
        cursor = cursor.advanced(by: Int(command.cmdsize))
    }
    return nil
}

// MARK: - Injected surfaces

/// The popover, swapped for a window that is never ordered in.
@MainActor
final class OffscreenPopoverPresenter: ZPDFPopoverPresenting {
    private(set) var presented = 0
    private(set) var dismissed = 0
    private(set) var window: NSWindow?

    func present(_ controller: NSViewController, anchoredTo anchor: NSView) {
        window?.close()
        presented += 1
        let window = NSWindow(
            contentRect: NSRect(x: -12000, y: -11000, width: 320, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()
        self.window = window
    }

    func dismiss() {
        guard window != nil else { return }
        dismissed += 1
        window?.close()
        window = nil
    }
}

/// The colour panel, swapped for a value that records what the controller asks of it.
@MainActor
final class RecordingColourPanel: ZPDFColourPanelSurface {
    var colour = ColorRGBA(red: 1, green: 1, blue: 1)
    private(set) var target: AnyObject?
    private(set) var action: Selector?
    private(set) var shown = 0
    func prepare() {}
    func connect(target: AnyObject?, action: Selector?) {
        self.target = target
        self.action = action
    }
    func show() { shown += 1 }
    func hide() {}

    /// A person dragging across the wheel: one action per colour, as AppKit sends them.
    func drag(through colours: [ColorRGBA]) {
        for colour in colours {
            self.colour = colour
            if let action { _ = NSApp.sendAction(action, to: target, from: nil) }
        }
    }
}

// MARK: - Window plumbing

@MainActor
struct Host {
    let window: NSWindow
    var root: NSView { window.contentView!.superview! }

    init(_ view: some View, height: CGFloat = 1000) {
        let host = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: -12000, y: -12000, width: 320, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.4)
    }

    func frame(ofMarker identifier: String) -> NSRect? {
        Self.frame(ofMarker: identifier, in: window)
    }

    static func frame(ofMarker identifier: String, in window: NSWindow) -> NSRect? {
        guard let content = window.contentView else { return nil }
        window.layoutIfNeeded()
        let view = allViews(content).first { $0.identifier?.rawValue == identifier }
        return view.map { $0.convert($0.bounds, to: nil) }
    }
}

/// A synthetic left click at a point in window coordinates, delivered the way `NSWindow`
/// delivers one: the view `hitTest` finds at the point gets the mouse-down, and the same view
/// gets the mouse-up.
///
/// Delivered to the view rather than through `NSWindow.sendEvent`, because the window is never
/// ordered in and a window that is not on screen does not dispatch mouse events. The target is
/// still chosen by hit-testing, which is the thing under test: a click that SwiftUI's hit-testing
/// drops lands on the container instead and does nothing, exactly as in the app. The mouse-up
/// is queued before the mouse-down for an AppKit control whose tracking loop pulls it with
/// `nextEvent`; if nothing pulled it, it is taken back and delivered directly.
@MainActor
func click(_ point: NSPoint, in window: NSWindow) {
    let time = ProcessInfo.processInfo.systemUptime
    guard
        let root = window.contentView?.superview,
        let target = root.hitTest(point),
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ),
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        )
    else { return }
    NSApp.postEvent(up, atStart: false)
    target.mouseDown(with: down)
    if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
        target.mouseUp(with: pending)
    }
    spin(0.15)
}

@MainActor
func clickMarker(_ identifier: String, in window: NSWindow?) -> Bool {
    guard let window, let frame = Host.frame(ofMarker: identifier, in: window) else { return false }
    click(NSPoint(x: frame.midX, y: frame.midY), in: window)
    return true
}

/// Every hosted AppKit control must take a click at its centre.
@MainActor
func checkHostedControlsReachable(_ host: Host, scenario: String) {
    var count = 0
    for view in allViews(host.window.contentView!) {
        let name = String(describing: type(of: view))
        // Marker views never take a click by design: they sit *under* a control as its anchor.
        guard name.contains("PlatformViewHost"), !name.contains("ZPDFViewMarker"), !view.isHiddenOrHasHiddenAncestor,
              view.bounds.width > 1, view.bounds.height > 1 else { continue }
        count += 1
        let frame = view.convert(view.bounds, to: nil)
        let hit = host.root.hitTest(NSPoint(x: frame.midX, y: frame.midY))
        let reached = hit.map { $0 === view || $0.isDescendant(of: view) } ?? false
        let short = name
            .replacingOccurrences(of: "AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<", with: "")
            .replacingOccurrences(of: ">>", with: "")
        check(reached, "[\(scenario)] hosted \(short) at \(frame.origin.x),\(frame.origin.y) \(frame.width)x\(frame.height) takes a click at its centre")
    }
    check(count > 0, "[\(scenario)] found hosted AppKit controls to test (\(count))")
}

/// The two ways a swatch can be found: its marker (a real button) or, in the old design, the
/// hosted colour well itself.
@MainActor
func swatchFrame(role: String, in host: Host) -> NSRect? {
    host.frame(ofMarker: "zpdf.inspector.swatch.\(role)")
}

// MARK: - Scenarios

@MainActor
func markupTabScenario() {
    print("\n[markup tab] an area with its own fill, selected")
    let env = ProjectShellEnvironment.mock()
    let presenter = OffscreenPopoverPresenter()
    let panel = RecordingColourPanel()
    env.colourPalettePresenter = presenter
    env.colourPanel = ZPDFColourPanelController(surface: { panel })
    env.recentColours = ZPDFRecentColours()
    guard let canvas = env.canvas as? MockCanvasPresenter, let ledger = env.ledger as? MockLedgerPresenter,
          var target = canvas.visibleMarkups.first(where: { $0.measurementKind == .area && !$0.locked })
    else {
        print("probe: the mock project has no unlocked area to select")
        exit(2)
    }
    var fill = target.colorRGBA
    fill.alpha = 0.3
    target.fillRGBA = fill
    canvas.appendMarkup(target)
    canvas.select(markupIDs: [target.id], additive: false)
    let toolStyleBefore = env.toolbar.toolStyle

    let host = Host(InspectorPanel(environment: env, panelState: ShellPanelState()))
    checkHostedControlsReachable(host, scenario: "markup tab")

    let border = swatchFrame(role: "border", in: host)
    let fillSwatch = swatchFrame(role: "fill", in: host)
    check(border != nil, "[markup tab] the Border swatch is on screen as a button")
    check(fillSwatch != nil, "[markup tab] the Fill Colour swatch is on screen as a button")
    if let fillSwatch, let remove = host.frame(ofMarker: "zpdf.inspector.remove-fill") {
        check(!fillSwatch.intersects(remove), "[markup tab] the fill swatch \(fillSwatch) does not overlap Remove Fill \(remove)")
        // The old hosted well was 44 pt wide under a 28 pt swatch and overhung Remove Fill: no
        // hosted control may reach into the button's rectangle.
        let intruders = allViews(host.window.contentView!).filter { view in
            let name = String(describing: type(of: view))
            return name.contains("PlatformViewHost") && !name.contains("ZPDFViewMarker")
                && view.convert(view.bounds, to: nil).intersects(remove)
        }
        check(intruders.isEmpty, "[markup tab] no hosted control reaches into Remove Fill (\(intruders.map { $0.convert($0.bounds, to: nil) }))")
    } else {
        check(false, "[markup tab] the fill swatch and the Remove Fill button can both be found")
    }

    // Border → Red.
    let red = ZPDFMarkupInk.red.color
    var edits = ledger.appliedBulkEdits.count
    if let border {
        click(NSPoint(x: border.midX, y: border.midY), in: host.window)
        check(presenter.presented == 1, "[markup tab] one click on the Border swatch opens the palette (presented \(presenter.presented), colour panel orderings \(colourPanelOrderings))")
        check(clickMarker(ZPDFColourPalette.markerIdentifier(for: .red), in: presenter.window), "[markup tab] the palette's Red cell can be found and clicked")
        spin(0.3)
        let new = Array(ledger.appliedBulkEdits.dropFirst(edits))
        check(new.count == 1, "[markup tab] picking Red makes exactly one bulk edit (made \(new.count))")
        if let edit = new.first {
            check(edit.markupIDs == [target.id], "[markup tab] the edit targets the selected markup")
            check(edit.style.color.map { ZPDFColourMath.sameHue($0, red) } == true, "[markup tab] the edit sets the border to Red (\(String(describing: edit.style.color)))")
        }
        check(presenter.window == nil, "[markup tab] the palette closes after a pick")
    }

    // Fill → Green, keeping the fill's 30 %.
    edits = ledger.appliedBulkEdits.count
    if let fillSwatch {
        click(NSPoint(x: fillSwatch.midX, y: fillSwatch.midY), in: host.window)
        check(presenter.presented == 2, "[markup tab] one click on the Fill Colour swatch opens the palette")
        check(presenter.window.flatMap { Host.frame(ofMarker: ZPDFColourPalette.noneMarkerIdentifier, in: $0) } != nil, "[markup tab] the fill palette offers No Fill")
        check(presenter.window.flatMap { Host.frame(ofMarker: ZPDFColourPalette.recentMarkerIdentifier(index: 0), in: $0) } != nil, "[markup tab] the palette shows the recent colour just used")
        check(clickMarker(ZPDFColourPalette.markerIdentifier(for: .green), in: presenter.window), "[markup tab] the palette's Green cell can be clicked")
        spin(0.3)
        let new = Array(ledger.appliedBulkEdits.dropFirst(edits))
        check(new.count == 1, "[markup tab] picking Green for the fill makes exactly one bulk edit (made \(new.count))")
        if let fill = new.first?.style.fill {
            check(ZPDFColourMath.sameHue(fill, ZPDFMarkupInk.green.color), "[markup tab] the fill is Green")
            check(abs(fill.alpha - 0.3) < 0.0001, "[markup tab] the fill keeps its own 30 % opacity (\(fill.alpha))")
        } else {
            check(false, "[markup tab] the fill edit carries a fill colour")
        }

        // No Fill.
        edits = ledger.appliedBulkEdits.count
        click(NSPoint(x: fillSwatch.midX, y: fillSwatch.midY), in: host.window)
        check(clickMarker(ZPDFColourPalette.noneMarkerIdentifier, in: presenter.window), "[markup tab] No Fill can be clicked")
        spin(0.3)
        let none = Array(ledger.appliedBulkEdits.dropFirst(edits))
        check(none.count == 1 && none.first?.style.removesFill == true, "[markup tab] No Fill makes exactly one remove-fill edit")
    }

    // More Colours… → the colour panel, a continuous drag folding into one edit.
    edits = ledger.appliedBulkEdits.count
    if let border {
        click(NSPoint(x: border.midX, y: border.midY), in: host.window)
        check(clickMarker(ZPDFColourPalette.moreMarkerIdentifier, in: presenter.window), "[markup tab] More Colours… can be clicked")
        check(panel.shown == 1 && panel.action != nil, "[markup tab] More Colours… opens the colour panel with an explicit target and action")
        check(presenter.window == nil, "[markup tab] the palette closes when the colour panel opens")
        panel.drag(through: [ZPDFMarkupInk.orange, .magenta, .purple, .teal].map(\.color))
        spin(0.7)
        let new = Array(ledger.appliedBulkEdits.dropFirst(edits))
        check(new.count == 1, "[markup tab] a four-step colour-panel drag lands as one bulk edit (made \(new.count))")
        check(new.first?.style.color.map { ZPDFColourMath.sameHue($0, ZPDFMarkupInk.teal.color) } == true, "[markup tab] the colour the drag settled on is the one written")
    }

    check(env.toolbar.toolStyle == toolStyleBefore, "[markup tab] recolouring a measured area leaves the markup tools' style alone")
    check(colourPanelOrderings.isEmpty, "[markup tab] the shared colour panel was never ordered front")
    host.window.close()
}

@MainActor
func toolStyleScenario() {
    print("\n[tool style] nothing selected, Rectangle armed")
    let env = ProjectShellEnvironment.mock()
    let presenter = OffscreenPopoverPresenter()
    env.colourPalettePresenter = presenter
    env.colourPanel = ZPDFColourPanelController(surface: { RecordingColourPanel() })
    env.recentColours = ZPDFRecentColours()
    guard let canvas = env.canvas as? MockCanvasPresenter, let ledger = env.ledger as? MockLedgerPresenter else { exit(2) }
    canvas.select(markupIDs: [], additive: false)
    env.toolbar.activateShape(.rectangle)

    let host = Host(InspectorPanel(environment: env, panelState: ShellPanelState()))
    checkHostedControlsReachable(host, scenario: "tool style")
    let edits = ledger.appliedBulkEdits.count
    if let border = swatchFrame(role: "tool.border", in: host) {
        click(NSPoint(x: border.midX, y: border.midY), in: host.window)
        check(presenter.presented == 1, "[tool style] one click on the tool's Border swatch opens the palette")
        check(clickMarker(ZPDFColourPalette.markerIdentifier(for: .green), in: presenter.window), "[tool style] the palette's Green cell can be clicked")
        spin(0.3)
        let green = ZPDFMarkupInk.green.color
        check(ZPDFColourMath.sameHue(env.toolbar.toolStyle.stroke, green), "[tool style] the tools' stroke is now Green")
        check(ZPDFColourMath.sameHue(env.toolbar.activeSelection.style.stroke, green), "[tool style] the armed Rectangle draws Green")
        check(env.toolbar.activeSelection.mode == .markup(.rectangle), "[tool style] the Rectangle stays armed")
        check(ledger.appliedBulkEdits.count == edits, "[tool style] choosing a tool style edits no document")
    } else {
        check(false, "[tool style] the tool's Border swatch is on screen as a button")
    }
    check(swatchFrame(role: "tool.fill", in: host) != nil, "[tool style] a closed shape offers a fill swatch")
    host.window.close()

    print("\n[last used] a drawn markup restyled")
    let env2 = ProjectShellEnvironment.mock()
    let presenter2 = OffscreenPopoverPresenter()
    env2.colourPalettePresenter = presenter2
    env2.recentColours = ZPDFRecentColours()
    guard let canvas2 = env2.canvas as? MockCanvasPresenter,
          var shape = canvas2.visibleMarkups.first(where: { !$0.locked })
    else { exit(2) }
    shape.kind = .rectangle
    shape.measurementKind = nil
    canvas2.appendMarkup(shape)
    canvas2.select(markupIDs: [shape.id], additive: false)
    let host2 = Host(InspectorPanel(environment: env2, panelState: ShellPanelState()))
    if let border = swatchFrame(role: "border", in: host2) {
        click(NSPoint(x: border.midX, y: border.midY), in: host2.window)
        check(clickMarker(ZPDFColourPalette.markerIdentifier(for: .purple), in: presenter2.window), "[last used] the palette's Purple cell can be clicked")
        spin(0.3)
        check(ZPDFColourMath.sameHue(env2.toolbar.toolStyle.stroke, ZPDFMarkupInk.purple.color), "[last used] the next shape will be Purple, like the one just restyled")
        env2.toolbar.activateShape(.ellipse)
        check(ZPDFColourMath.sameHue(env2.toolbar.activeSelection.style.stroke, ZPDFMarkupInk.purple.color), "[last used] arming Ellipse afterwards arms it in Purple")
    } else {
        check(false, "[last used] the Border swatch is on screen as a button")
    }
    host2.window.close()
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    // Second guard: whatever happens, the shared colour panel is never ordered front.
    method_exchangeImplementations(
        class_getInstanceMethod(NSColorPanel.self, #selector(NSWindow.orderFront(_:)))!,
        class_getInstanceMethod(NSColorPanel.self, #selector(NSColorPanel.probe_orderFront(_:)))!
    )
    method_exchangeImplementations(
        class_getInstanceMethod(NSColorPanel.self, #selector(NSWindow.makeKeyAndOrderFront(_:)))!,
        class_getInstanceMethod(NSColorPanel.self, #selector(NSColorPanel.probe_makeKeyAndOrderFront(_:)))!
    )

    print("zpdf-hit-probe — hosted hit targets in a binary stamped like the app")
    guard let stamp = stampedSDK() else {
        print("probe: cannot read this executable's LC_BUILD_VERSION")
        exit(2)
    }
    print("  binary stamp: minos \(stamp.minos), sdk \(stamp.sdk)")
    check(stamp.sdkMajor < 15, "this binary is stamped with an SDK-14-era SDK (\(stamp.sdk)), so SwiftUI hit-tests as the shipped app does")

    markupTabScenario()
    toolStyleScenario()
    tabStripScenario()
    inspectorTabsScenario()
    inspectorTabsAfterReplyScenario()
    shapesPaletteScenario()
    l108Scenario()
    panelCloseScenario()

    let visible = NSApp.windows.filter(\.isVisible)
    check(visible.isEmpty, "no window was ever put on screen (\(visible.count) visible)")

    print("\nzpdf-hit-probe: \(passes) passed, \(failures.count) failed")
    if !failures.isEmpty {
        print("FAILED:")
        for failure in failures { print("  - \(failure)") }
        exit(1)
    }
    print("PASS")
    exit(0)
}

#else

print("zpdf-hit-probe needs a debug build: it hosts the mock environment, which a release build does not contain.")
exit(2)

#endif
