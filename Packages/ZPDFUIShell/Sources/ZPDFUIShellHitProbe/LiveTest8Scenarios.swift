import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell

// Live test 8 (2026-10-04) click checks that only a binary stamped like the app can make:
// `xctest` does not deliver a synthetic click to a SwiftUI button at all (measured while fixing
// L-106 — a plain full-size `Button` in an off-screen window fired zero times), so these live
// here beside the swatch checks.

#if DEBUG || ZPDF_MOCKS

/// L-106: a click anywhere on a back tab brings it to the front.
///
/// Live test 8: "clicking Plan-B left Plan-A2 active, and the following ⌘W offered to close
/// Plan-A2". A narrow back tab gave only its left half to the select button: the right half was
/// the close button's reserved frame — not hit-testable while the tab is not hovered, and a
/// pointer that is warped rather than moved never hovers it — plus the gaps around it. A click
/// there fell through to the band, which starts a window drag.
@MainActor
func tabStripScenario() {
    print("\n[tab strip] a click anywhere on a back tab brings it to the front (L-106)")
    let tabs = [
        DocumentTabSummary(id: UUID(), title: "Plan-A", fileName: "Plan-A.pdf", pageCount: 1),
        DocumentTabSummary(id: UUID(), title: "Plan-A2", fileName: "Plan-A copy.pdf", pageCount: 1),
        DocumentTabSummary(id: UUID(), title: "Plan-B", fileName: "Plan-B.pdf", pageCount: 1)
    ]
    let model = DocumentTabBarModel(input: DocumentTabBarInput(tabs: tabs, activeTabID: tabs[1].id, revisions: []))
    var selected: [UUID] = []
    var closed: [UUID] = []
    model.onSelect = { selected.append($0) }
    model.onClose = { closed.append($0) }
    // Drag-to-reorder on, as the app wires it.
    model.onMoveTab = { _, _ in }

    // A 300 pt strip holds the three tabs at 80 pt each: (300 − 8 inset − 44 `+` − 2 gap − 2 × 2
    // between tabs) / 3, rounded down — `DocumentTabStripPlan`'s shared width.
    let stripWidth: CGFloat = 300
    let height = ZPDFSpacing.Chrome.documentTabHeight + 4
    let inset: CGFloat = 8, gap: CGFloat = 2, tabWidth: CGFloat = 80
    // The tab's own body, clear of the 5 pt flares at its foot corners.
    let y = ZPDFSpacing.Chrome.documentTabHeight / 2
    for index in [0, 2] {
        let left = inset + CGFloat(index) * (tabWidth + gap)
        for fraction in [0.25, 0.5, 0.7, 0.85, 0.94] {
            // A fresh strip per click: the click is the pointer's first event over the tab, as
            // when a pointer is warped there (automation, a tablet) rather than moved. A click
            // after another one on the same tab would find it hovered, with its ✕ showing.
            let host = Host(DocumentTabBarView(model: model).frame(width: stripWidth, height: height), height: height)
            selected = []
            closed = []
            let x = left + tabWidth * fraction
            click(NSPoint(x: x, y: y), in: host.window)
            check(
                selected == [tabs[index].id] && closed.isEmpty,
                "[tab strip] a click \(Int(fraction * 100)) % across back tab \(tabs[index].title) selects it (selected \(selected.count), closed \(closed.count))"
            )
            host.window.close()
        }
    }
}

/// L-90: a click on an Inspector tab opens that tab — with an area selected, as live test 8
/// had it, and with nothing selected.
@MainActor
func inspectorTabsScenario() {
    print("\n[inspector tabs] a click on a tab opens that tab (L-90)")
    for selecting in [true, false] {
        let env = ProjectShellEnvironment.mock()
        let label = selecting ? "area selected" : "nothing selected"
        if selecting {
            guard let canvas = env.canvas as? MockCanvasPresenter,
                  let area = canvas.visibleMarkups.first(where: { $0.measurementKind == .area })
            else {
                print("probe: the mock project has no area to select")
                exit(2)
            }
            canvas.select(markupIDs: [area.id], additive: false)
        }
        let state = ShellPanelState()
        let host = Host(InspectorPanel(environment: env, panelState: state).frame(width: 300, height: 900), height: 900)
        defer { host.window.close() }
        for tab in [InspectorTab.properties, .comments, .markup, .properties, .tools, .markup] {
            guard let frame = host.frame(ofMarker: tab.markerIdentifier) else {
                check(false, "[inspector tabs, \(label)] the \(tab.title) tab can be found")
                continue
            }
            click(NSPoint(x: frame.midX, y: frame.midY), in: host.window)
            check(state.inspectorTab == tab, "[inspector tabs, \(label)] a click on \(tab.title) at \(Int(frame.midX)),\(Int(frame.midY)) opens \(tab.title) (open: \(state.inspectorTab.title))")
        }
    }
}

// MARK: - L-90, the live precondition

/// How a click reaches the panel in ``inspectorTabsAfterReplyScenario()``.
///
/// `NSWindow.sendEvent` itself is not a route: a window that is never ordered in does not
/// dispatch a mouse-down through it (measured here — a Comments click sent that way opened
/// nothing), which is why ``click(_:in:)`` delivers to the hit-tested view.
enum ProbeClickRoute: String, CaseIterable {
    /// To the view hit-testing finds, as ``click(_:in:)`` delivers it.
    case direct = "direct"
    /// `NSWindow`'s mouse-down step first — the view under the pointer is made first responder
    /// when it accepts it, which ends a field editor's session — then the click.
    case firstResponderFirst = "first responder first"
}

/// A window that answers as the key window, as the live document window was: SwiftUI decides
/// focus and click-to-focus against the key window. Never ordered in.
final class ProbeKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@MainActor
func routedClick(_ point: NSPoint, in window: NSWindow, route: ProbeClickRoute) {
    switch route {
    case .direct:
        click(point, in: window)
    case .firstResponderFirst:
        if let target = window.contentView?.superview?.hitTest(point), target.acceptsFirstResponder,
           window.firstResponder !== target {
            window.makeFirstResponder(target)
        }
        click(point, in: window)
    }
}

/// The Inspector in a 300 × 900 window that is never ordered in.
@MainActor
func makeInspectorWindow(_ env: ProjectShellEnvironment, state: ShellPanelState, pretendsKey: Bool) -> NSWindow {
    let host = NSHostingView(rootView: InspectorPanel(environment: env, panelState: state).frame(width: 300, height: 900))
    let rect = NSRect(x: -12000, y: -12000, width: 300, height: 900)
    let window = pretendsKey
        ? ProbeKeyWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    spin(0.4)
    return window
}

/// The Comments tab's reply field, found by its placeholder.
@MainActor
func replyField(in window: NSWindow) -> NSTextField? {
    guard let content = window.contentView else { return nil }
    return allViews(content).compactMap { $0 as? NSTextField }.first {
        !$0.isHiddenOrHasHiddenAncestor
            && ($0.placeholderString == "Reply…" || $0.placeholderAttributedString?.string == "Reply…")
    }
}

/// The colour 4 pt under the top edge of a tab — its fill, clear of the title and the underline —
/// read from a 1× sRGB render of the window's content (raw bytes; `colorAt` lifts dark tones).
@MainActor
func tabFill(_ tab: InspectorTab, in window: NSWindow) -> [Int]? {
    guard let view = window.contentView, let frame = Host.frame(ofMarker: tab.markerIdentifier, in: window) else { return nil }
    let size = view.bounds.size
    guard let device = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    let rep = device.retagging(with: .sRGB) ?? device
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    let point = view.convert(NSPoint(x: frame.midX, y: frame.maxY - 4), from: nil)
    let x = Int(point.x), y = view.isFlipped ? Int(point.y) : Int(size.height - point.y)
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let data = rep.bitmapData else { return nil }
    let offset = y * rep.bytesPerRow + x * 4
    return [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
}

/// The pointer resting on a point without a click, as AppKit's tracking reports it.
@MainActor
func hover(_ point: NSPoint, in window: NSWindow) {
    guard let view = window.contentView,
          let moved = NSEvent.mouseEvent(
              with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
          )
    else { return }
    view.mouseEntered(with: moved)
    view.mouseMoved(with: moved)
    spin(0.2)
}

/// L-90 as live test 8 had it: "Clicking Properties with an area selected showed the Comments
/// tab instead". The step before was the Comments tab, where a reply had just been posted
/// ("Check the roof slope here"), so the reply field could still hold the keyboard focus, and
/// the pointer had been warped onto Comments for the previous click. The clean-state scenario
/// above never set that up. This one does, for every way a click can reach the panel, in a
/// plain and in a key window, after a reply sent with ⌘↩, after one sent with the Reply
/// button, and with a draft still in the field — and then clicks Properties and requires the
/// Properties page.
@MainActor
func inspectorTabsAfterReplyScenario() {
    print("\n[inspector tabs after a reply] Comments open, a reply just posted, then Properties (L-90)")
    enum Posting: String, CaseIterable { case commandReturn = "⌘↩", replyButton = "Reply button", draftOnly = "draft not sent" }
    var routedAll = 0, routedRight = 0
    for pretendsKey in [false, true] {
        for posting in Posting.allCases {
            for route in ProbeClickRoute.allCases {
                let label = "\(pretendsKey ? "key" : "plain") window, \(posting.rawValue), \(route.rawValue)"
                let env = ProjectShellEnvironment.mock()
                let review = MockReviewThreadPresenter(author: "Probe")
                env.review = review
                guard let canvas = env.canvas as? MockCanvasPresenter,
                      let area = canvas.visibleMarkups.first(where: { $0.measurementKind == .area && !$0.locked })
                else {
                    print("probe: the mock project has no unlocked area to select")
                    exit(2)
                }
                canvas.select(markupIDs: [area.id], additive: false)
                let state = ShellPanelState()
                let window = makeInspectorWindow(env, state: state, pretendsKey: pretendsKey)
                defer { window.close() }

                // Comments.
                guard let comments = Host.frame(ofMarker: InspectorTab.comments.markerIdentifier, in: window) else {
                    check(false, "[after a reply, \(label)] the Comments tab can be found")
                    continue
                }
                routedClick(NSPoint(x: comments.midX, y: comments.midY), in: window, route: route)
                guard state.inspectorTab == .comments else {
                    check(false, "[after a reply, \(label)] a click on Comments opens Comments (open: \(state.inspectorTab.title))")
                    continue
                }
                // Tools is never pointed at or chosen here: its fill is the plain tab. Read once the
                // page change to Comments has finished animating.
                spin(0.5)
                guard let markup = Host.frame(ofMarker: InspectorTab.markup.markerIdentifier, in: window),
                      let plain = tabFill(.tools, in: window) else {
                    check(false, "[after a reply, \(label)] the Markup and Tools tabs can be found and rendered")
                    continue
                }
                // The probe's pointer paints a hover plate, or the stale-plate check at the end would
                // pass for nothing.
                hover(NSPoint(x: markup.midX, y: markup.midY), in: window)
                spin(0.4)
                let hovered = tabFill(.markup, in: window)
                check(hovered != nil && hovered != plain, "[after a reply, \(label)] the pointer resting on Markup paints its hover plate (\(String(describing: hovered)) over plain \(plain))")
                // The live pointer was put on Comments for that click and stayed there. (A plate is
                // taken down by AppKit's exit event, which a synthesised move does not raise: Markup
                // keeps its plate here, exactly as a tab does live when the pointer is warped off it.)
                hover(NSPoint(x: comments.midX, y: comments.midY), in: window)
                spin(0.4)

                // The reply field takes the caret and the text.
                guard let field = replyField(in: window) else {
                    let fields = allViews(window.contentView!).compactMap { $0 as? NSTextField }.map { $0.placeholderString ?? "-" }
                    check(false, "[after a reply, \(label)] the Comments tab shows a reply field (text fields: \(fields))")
                    continue
                }
                let fieldFrame = field.convert(field.bounds, to: nil)
                routedClick(NSPoint(x: fieldFrame.midX, y: fieldFrame.midY), in: window, route: route)
                if (window.firstResponder as? NSTextView)?.isFieldEditor != true {
                    window.makeFirstResponder(field)
                }
                guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
                    check(false, "[after a reply, \(label)] the reply field takes the caret (first responder: \(String(describing: window.firstResponder)))")
                    continue
                }
                editor.insertText("Check the roof slope here", replacementRange: NSRange(location: NSNotFound, length: 0))
                spin(0.2)

                switch posting {
                case .commandReturn:
                    let key = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
                    )
                    _ = key.map { window.performKeyEquivalent(with: $0) }
                    spin(0.3)
                case .replyButton:
                    let buttons = allViews(window.contentView!).compactMap { $0 as? NSButton }
                    if let button = buttons.first(where: { $0.title == "Reply" && !$0.isHiddenOrHasHiddenAncestor }) {
                        let frame = button.convert(button.bounds, to: nil)
                        routedClick(NSPoint(x: frame.midX, y: frame.midY), in: window, route: route)
                    } else {
                        // A SwiftUI-drawn button: its label sits under the field, right-aligned.
                        routedClick(NSPoint(x: fieldFrame.maxX - 20, y: fieldFrame.minY - 18), in: window, route: route)
                    }
                    spin(0.3)
                case .draftOnly:
                    break
                }
                let posted = review.replies[area.id]?.count ?? 0
                if posting != .draftOnly {
                    check(posted == 1, "[after a reply, \(label)] the reply is posted (\(posted))")
                }
                let focusedBefore = (window.firstResponder as? NSTextView)?.isFieldEditor == true

                // Properties, with the pointer warped there: no move, only the click.
                guard let properties = Host.frame(ofMarker: InspectorTab.properties.markerIdentifier, in: window) else {
                    check(false, "[after a reply, \(label)] the Properties tab can be found")
                    continue
                }
                routedClick(NSPoint(x: properties.midX, y: properties.midY), in: window, route: route)
                spin(0.2)
                routedAll += 1
                let opened = state.inspectorTab
                let commentsBodyGone = replyField(in: window) == nil
                if opened == .properties && commentsBodyGone { routedRight += 1 }
                check(
                    opened == .properties && commentsBodyGone,
                    "[after a reply, \(label)] a click on Properties opens Properties (open: \(opened.title), reply field still shown: \(!commentsBodyGone), field had focus: \(focusedBefore))"
                )
                // What the strip looks like now: Comments, where the pointer last moved, must not
                // wear a fill a selection could be mistaken for — Markup, untouched, is the
                // reference. Old: Comments kept the hover plate (and, while the page change was
                // animating, the selected fill) beside the selected Properties.
                spin(0.8)
                if let commentsFill = tabFill(.comments, in: window), let markupFill = tabFill(.markup, in: window),
                   let propertiesFill = tabFill(.properties, in: window) {
                    check(
                        commentsFill == plain,
                        "[after a reply, \(label)] Comments, where the pointer was left, is drawn as a plain tab (Comments \(commentsFill), plain \(plain), Properties \(propertiesFill))"
                    )
                    check(
                        markupFill == plain,
                        "[after a reply, \(label)] Markup, which the pointer left without an exit, is drawn as a plain tab (Markup \(markupFill), plain \(plain))"
                    )
                    check(propertiesFill != plain, "[after a reply, \(label)] Properties wears the selected fill (\(propertiesFill))")
                } else {
                    check(false, "[after a reply, \(label)] the tab strip can be rendered off screen")
                }
            }
        }
    }
    print("  [after a reply] \(routedRight) of \(routedAll) Properties clicks opened Properties")
}

/// A project window with its top band, laid out but never ordered in.
@MainActor
func makeBandHost(_ env: ProjectShellEnvironment) -> (ProjectWindowLayoutController, ZPDFProjectWindow) {
    let layout = ProjectWindowLayoutController(
        environment: env,
        store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "probe.band")
    )
    let window = ZPDFProjectWindow(
        contentRect: NSRect(x: -12000, y: -12000, width: 1_600, height: 900),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = layout
    layout.configure(window: window)
    window.setFrame(NSRect(x: -12000, y: -12000, width: 1_600, height: 900), display: false)
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    spin(0.3)
    window.layoutIfNeeded()
    return (layout, window)
}

/// A press held on a point for `seconds`, then released, delivered like ``click(_:in:)``.
@MainActor
func pressAndHold(_ point: NSPoint, in window: NSWindow, seconds: Double) {
    let time = ProcessInfo.processInfo.systemUptime
    guard
        let root = window.contentView?.superview,
        let target = root.hitTest(point),
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ),
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + seconds,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        )
    else { return }
    target.mouseDown(with: down)
    spin(seconds)
    target.mouseUp(with: up)
    spin(0.15)
}

/// L-100: the Shapes list opens from its whole › and from a held press on the chip; a quick
/// click on the chip still draws the last shape.
///
/// Live test 8: "The list opens only from a 10 × 12 pt target at the corner of the Shapes
/// button; a click on the button or on the visible chevron arms Rectangle instead. Press-and-hold
/// does not open it." Measured on the old build in this probe: the pop-up behind the › was
/// 17 × 14 pt, vertically centred; a click 15 pt in from the chip's right edge reached the chip's
/// own button, and above or below the sliver reached the band.
@MainActor
func shapesPaletteScenario() {
    print("\n[shapes palette] the › and a held press open the list (L-100)")
    let env = ProjectShellEnvironment.mock()
    let (layout, window) = makeBandHost(env)
    defer { window.close() }
    guard let band = layout.topBand,
          let chip = band.centreEntries.first(where: { $0.identifier == .zenitShapes })?.view
    else {
        check(false, "[shapes palette] the band shows a Shapes chip")
        return
    }
    var presented: [[String]] = []
    band.presentMenu = { menu, _, _ in presented.append(menu.items.map(\.title)) }
    let frame = chip.convert(chip.bounds, to: nil)
    let selectBefore = env.toolbar.activeSelection
    // The › is the last 18 pt of the chip's view: every point of it, top to bottom.
    for dx in [CGFloat(3), 9, 15] {
        for fraction in [0.15, 0.5, 0.85] {
            presented = []
            let point = NSPoint(x: frame.maxX - dx, y: frame.minY + frame.height * fraction)
            click(point, in: window)
            check(
                presented.count == 1 && presented.first?.contains("Rectangle") == true,
                "[shapes palette] a click on the › \(Int(dx)) pt from the edge, \(Int(fraction * 100)) % up, opens the list (opened \(presented.count))"
            )
            check(env.toolbar.activeSelection == selectBefore, "[shapes palette] … and arms nothing (\(env.toolbar.activeTool))")
        }
    }
    // A quick click on the chip itself draws the last shape, and opens nothing.
    presented = []
    click(NSPoint(x: frame.minX + 30, y: frame.midY), in: window)
    check(presented.isEmpty, "[shapes palette] a click on the chip opens no list (opened \(presented.count))")
    check(env.toolbar.activeTool == .shapes, "[shapes palette] a click on the chip arms the last shape (\(env.toolbar.activeTool))")
    // A press held on the chip opens the list, and the release does not also arm a shape.
    env.toolbar.arm(.select)
    presented = []
    pressAndHold(NSPoint(x: frame.minX + 30, y: frame.midY), in: window, seconds: 0.7)
    check(presented.count == 1 && presented.first?.contains("Ellipse") == true,
          "[shapes palette] a press held on the chip opens the list (opened \(presented.count))")
    check(env.toolbar.activeTool == .select, "[shapes palette] … and the release arms nothing (\(env.toolbar.activeTool))")
}

#endif
