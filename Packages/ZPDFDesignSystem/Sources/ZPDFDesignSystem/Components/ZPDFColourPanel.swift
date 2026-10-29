import AppKit
import SwiftUI
import ZPDFUIPresentation

// The AppKit half of the colour palette: where a popover is anchored, who presents it, and the
// explicit target/action route into `NSColorPanel` that replaced the hidden colour well.

// MARK: - Marker view

/// A plain, non-interactive `NSView` placed behind a SwiftUI control, for two jobs:
///
/// * **An anchor.** `NSPopover` needs a view and a rect to point at; a SwiftUI `Button` has
///   neither. The marker sits exactly under the control and hands its view over.
/// * **A landmark.** It carries an identifier, so the off-screen hit-target probe can find a
///   swatch in a window no accessibility client is attached to.
///
/// It never takes a click: `hitTest(_:)` answers `nil` and SwiftUI is told not to hit-test it.
/// It is drawn at full opacity and draws nothing, so it is outside the class of defect the
/// opacity lint bans — an interactive control drawn nearly transparent.
public struct ZPDFViewMarker: NSViewRepresentable {

    let identifier: String
    let anchor: ZPDFAnchorBox?

    public init(identifier: String, anchor: ZPDFAnchorBox? = nil) {
        self.identifier = identifier
        self.anchor = anchor
    }

    public func makeNSView(context: Context) -> NSView {
        let view = MarkerView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityElement(false)
        anchor?.view = view
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(identifier)
        anchor?.view = nsView
    }

    /// Answers no hit, ever: the control drawn over it takes the click.
    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }
}

extension View {
    /// Places a ``ZPDFViewMarker`` behind this view.
    public func zpdfMarker(_ identifier: String, anchor: ZPDFAnchorBox? = nil) -> some View {
        background(ZPDFViewMarker(identifier: identifier, anchor: anchor).allowsHitTesting(false))
    }
}

/// Holds the marker's view for the control that owns it. A reference, so SwiftUI state can keep
/// it without the view re-rendering whenever the marker is (re)made.
@MainActor
public final class ZPDFAnchorBox {
    public weak var view: NSView?
    public init() {}
}

// MARK: - Popover presentation

/// Presents a view controller pointing at an anchor.
///
/// Injected, like every other surface an automated run can reach: the product presents an
/// `NSPopover`; the hit-target probe presents the same controller in an off-screen window, so
/// it can click the real palette without putting anything on the user's screen.
@MainActor
public protocol ZPDFPopoverPresenting: AnyObject {
    /// Shows `controller` pointing at `anchor`, replacing anything this presenter shows.
    func present(_ controller: NSViewController, anchoredTo anchor: NSView)
    /// Closes whatever this presenter shows.
    func dismiss()
}

/// The product's presenter: a transient `NSPopover`, which closes on Escape and on a click
/// outside it.
@MainActor
public final class ZPDFSystemPopoverPresenter: NSObject, ZPDFPopoverPresenting, NSPopoverDelegate {

    private var popover: NSPopover?

    public override init() {}

    public func present(_ controller: NSViewController, anchoredTo anchor: NSView) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    public func dismiss() {
        popover?.close()
        popover = nil
    }

    public func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === popover { popover = nil }
    }
}

// MARK: - Colour panel

/// The colour panel as the controller sees it: a colour, a target and action, show and hide.
///
/// A seam so the routing can be tested without creating — let alone showing — the shared
/// `NSColorPanel`, which writes its own preferences the moment it is used.
@MainActor
public protocol ZPDFColourPanelSurface: AnyObject {
    /// The panel's colour.
    var colour: ColorRGBA { get set }
    /// Opaque colours only, continuous updates.
    func prepare()
    /// Points the panel's action at `target`, or unhooks it with `nil`.
    func connect(target: AnyObject?, action: Selector?)
    /// Orders the panel front.
    func show()
    /// Orders the panel out.
    func hide()
}

/// The product's surface: the shared `NSColorPanel`, created only when first used.
@MainActor
public final class ZPDFSystemColourPanelSurface: ZPDFColourPanelSurface {

    public init() {}

    private var panel: NSColorPanel { NSColorPanel.shared }

    public var colour: ColorRGBA {
        get { ColorRGBA(nsColor: panel.color) }
        set { panel.color = newValue.nsColor }
    }

    public func prepare() {
        panel.showsAlpha = false
        panel.isContinuous = true
    }

    public func connect(target: AnyObject?, action: Selector?) {
        panel.setTarget(target)
        panel.setAction(action)
    }

    public func show() { panel.orderFront(nil) }

    public func hide() { panel.orderOut(nil) }
}

/// Drives the colour panel for "More Colours…" through an explicit target and action.
///
/// One owner at a time. ``attach(owner:initial:onChange:)`` seeds the panel, points it at this
/// controller and orders it front; every colour the person then chooses is forwarded to that
/// owner's closure. ``detach(owner:)`` — called when the control goes away, for instance
/// because the selection changed — unhooks the panel and closes it, so a panel left open can
/// never write the old selection's pick onto the new one.
///
/// Seeding never reads as a pick: the panel is unhooked while its colour is set, and a value
/// equal to the seed is not forwarded (the CR-117 rule the colour well used to need).
@MainActor
public final class ZPDFColourPanelController: NSObject {

    public static let shared = ZPDFColourPanelController()

    private let surfaceProvider: @MainActor () -> any ZPDFColourPanelSurface
    private lazy var surface: any ZPDFColourPanelSurface = surfaceProvider()
    private weak var owner: AnyObject?
    private var onChange: ((ColorRGBA) -> Void)?
    private var seed: ColorRGBA?

    public init(surface: @escaping @MainActor () -> any ZPDFColourPanelSurface = { ZPDFSystemColourPanelSurface() }) {
        self.surfaceProvider = surface
    }

    /// Whether `owner` is the one the panel currently reports to.
    public func isAttached(_ owner: AnyObject) -> Bool { self.owner === owner }

    /// Seeds the panel with `initial`, routes its changes to `onChange`, and orders it front.
    public func attach(owner: AnyObject, initial: ColorRGBA?, onChange: @escaping (ColorRGBA) -> Void) {
        surface.connect(target: nil, action: nil)
        surface.prepare()
        if let initial { surface.colour = ZPDFColourMath.opaque(initial) }
        self.owner = owner
        self.onChange = onChange
        self.seed = surface.colour
        surface.connect(target: self, action: #selector(panelChanged(_:)))
        surface.show()
    }

    /// Unhooks and closes the panel if `owner` holds it; otherwise does nothing.
    public func detach(owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        onChange = nil
        seed = nil
        surface.connect(target: nil, action: nil)
        surface.hide()
    }

    @objc private func panelChanged(_ sender: Any?) {
        deliver(surface.colour)
    }

    /// Forwards one colour from the panel to the current owner — the action's body, callable
    /// without a panel on screen.
    public func deliver(_ color: ColorRGBA) {
        guard owner != nil, let onChange else { return }
        let picked = ZPDFColourMath.opaque(color)
        if let seed, ZPDFColourMath.sameHue(seed, picked) { return }
        seed = nil
        onChange(picked)
    }
}
