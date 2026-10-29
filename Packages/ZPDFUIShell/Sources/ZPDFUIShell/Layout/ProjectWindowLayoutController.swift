import AppKit
import Foundation
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIMeasurement
import ZPDFUIPresentation

/// An `NSSplitViewController` that reports resizes, so the owner can persist pane sizes.
///
/// `NSSplitView`'s own autosave restores divider positions, but the shell also needs to know
/// *when* a divider moved, to keep its layout state and AppKit's autosave from drifting apart.
@MainActor
public final class ZPDFObservingSplitViewController: NSSplitViewController {

    /// Raised whenever the split lays its panes out at new sizes: on every step of a divider
    /// drag and of a live window resize, as well as after a programmatic change. (It used to be
    /// documented as "after the user finishes dragging", which it never was — S-059.)
    public var onResize: (@MainActor () -> Void)?

    /// Asked when a divider is double-clicked, with the divider's index.
    ///
    /// Returning `true` means the owner handled it — collapsing or restoring the pane itself,
    /// at the size that pane had. AppKit's own double-click collapse is then declined, because
    /// it restores a pane to whatever frame it last held rather than to the remembered one, and
    /// a pane that returns wrong teaches the user not to close it.
    public var onDividerDoubleClick: (@MainActor (Int) -> Bool)?

    public override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize?()
    }

    public override func splitView(
        _ splitView: NSSplitView,
        shouldCollapseSubview subview: NSView,
        forDoubleClickOnDividerAt dividerIndex: Int
    ) -> Bool {
        if onDividerDoubleClick?(dividerIndex) == true { return false }
        // No handler, or a divider the window has no opinion about: the macOS convention still
        // applies, so let AppKit answer for itself rather than swallowing the gesture.
        return super.splitView(
            splitView,
            shouldCollapseSubview: subview,
            forDoubleClickOnDividerAt: dividerIndex
        )
    }
}

/// The whole project window: tab strip, three-pane split, docked Quantity Ledger.
///
/// The arrangement is fixed; the 2026-09-23 main-window mockup fixes its look.
/// The window is one dark surface — the toolbar and the tab strip form a single band over the
/// transparent titlebar, the gaps between panes are that same ground — with the Navigator and
/// the Inspector standing on it as rounded cards, the canvas column unboxed between them (canvas
/// bar on top, page in the middle, status strip underneath) and the Quantity Ledger as a flush
/// bar along the bottom. The mockup has no window-wide status bar; its readouts live in the
/// canvas column's status strip (see ``StatusBarView``). This controller owns it in AppKit and hosts every
/// panel as SwiftUI inside `NSHostingView`, which is what lets the design-system components be
/// used unchanged while the window itself keeps native split, toolbar and window behaviour.
@MainActor
public final class ProjectWindowLayoutController: NSViewController {

    /// Height of the document tab strip, the lower half of the top band.
    /// A document tab plus a little air above it, so the tab stands on the band's hairline.
    public static let tabBarHeight: CGFloat = ZPDFSpacing.Chrome.documentTabHeight + ZPDFSpacing.xs
    /// Height of the canvas status strip under the page. Tall enough for a 24 pt hit target
    /// plus its hairline.
    public static let statusBarHeight: CGFloat = 26
    /// Height of the canvas bar above the page: page navigation, zoom, fit, undo, redo, search.
    public static let canvasTopBarHeight: CGFloat = CanvasTopBar.height
    /// The gap between the top band and the content row, and between the window edges and the
    /// Navigator and Inspector cards. The split dividers are this wide too.
    public static let gutter: CGFloat = ZPDFWindowChrome.gutter
    /// Height of the contextual tool options strip while it is showing.
    ///
    /// Zero the rest of the time: the strip appears only for the five measurement tools
    /// that need a value the drawing does not contain, so it is not a second permanent
    /// toolbar.
    public static let toolOptionsBarHeight: CGFloat = 30

    /// Everything the panels render.
    public let environment: ProjectShellEnvironment
    /// Which Navigator page and Inspector sections are open.
    public let panelState: ShellPanelState
    /// The last state written to, or read from, the store.
    public private(set) var layoutState: ProjectWindowLayoutState

    /// The stacked split: content above, Quantity Ledger below.
    public private(set) var outerSplitController: ZPDFObservingSplitViewController!
    /// The side-by-side split: Navigator, canvas, Inspector.
    public private(set) var contentSplitController: ZPDFObservingSplitViewController!
    /// The toolbar builder, so the window can install the toolbar.
    ///
    /// Built in `init`, not in `viewDidLoad`: a window controller is entitled to ask for the
    /// toolbar before it ever asks for the view.
    public let toolbarBuilder: ZenitToolbarBuilder

    /// The canvas pane: the document canvas, plus room over it for a canvas view mode.
    /// Built in ``buildSplitControllers()``; `nil` until the view loads.
    public private(set) var canvasPane: CanvasPaneContainerViewController?

    /// The number-key shortcuts for the first nine slots of the active tool set.
    ///
    /// Owned by the window, because the rule is about *this* window's canvas having focus and
    /// *this* window's Tool Library. Two open drawings each get their own.
    public let toolSlotRouter: ToolSlotKeyRouter

    /// Whether a tool key — a single-letter tool shortcut (A included) or a number slot —
    /// belongs to the canvas right now rather than to the window's tool shortcuts, answered by
    /// the host that knows (ADR-0030 §5.7, §5.8). The canvas owns every tool key during a
    /// two-point pick (Calibrate, Verify Scale, the Split Area line, Curve an Edge, a fence or
    /// fall line), while a typed length is being entered, and while a shape a tool switch would
    /// throw away is in progress; A also mid-count, where it is the arc key. An owned key goes on
    /// to the canvas, which uses it (A as an arc, a digit as a typed length) or says why no tool
    /// was chosen. `nil` — a window without the application's canvas — falls back to the
    /// measurement presenter's placed points.
    ///
    /// K-02 (iteration 1): this used to cover A alone, so once the letters were wired a P during
    /// Calibrate lit Pan while the next click still went to the pick, and the "c" of a typed
    /// "25cm" armed Callout and threw the half-drawn Length away.
    public var canvasOwnsToolKey: (@MainActor (_ characters: String, _ modifiers: ZPDFModifierFlags) -> Bool)?

    /// The document tab strip's view, at the foot of the top band's left column. `nil` until the
    /// view loads.
    public private(set) var tabStripView: NSView?

    /// The window's top band. `nil` until the view loads.
    public private(set) var topBand: ProjectTopBandView?
    private var topBandHeight: NSLayoutConstraint?

    /// Whether the top band shows its tools. View ▸ Hide Toolbar turns this off; the tabs stay.
    public var isTopBandShown: Bool { topBand?.isShown ?? !(layoutState.isTopBandHidden ?? false) }

    /// View ▸ Hide / Show Toolbar: collapses the band to its tab row, or brings the tools back.
    /// Remembered with the rest of the layout.
    public func toggleTopBandShown() {
        setTopBandShown(!isTopBandShown)
    }

    /// Shows the band as ``layoutState`` says: the one place a stored or recalled layout's
    /// `isTopBandHidden` reaches the view (S-047).
    private func applyTopBandFlag() {
        guard let topBand else { return }
        let shown = !(layoutState.isTopBandHidden ?? false)
        let changed = topBand.isShown != shown
        topBand.isShown = shown
        topBandHeight?.constant = topBand.preferredHeight
        if changed { view.needsLayout = true }
    }

    /// Shows or hides the top band's tools.
    public func setTopBandShown(_ shown: Bool) {
        layoutState.isTopBandHidden = shown ? nil : true
        guard let topBand else { return }
        topBand.isShown = shown
        topBandHeight?.constant = topBand.preferredHeight
        view.needsLayout = true
        persistLayoutState()
    }

    /// The floating Scale Regions panel, while it is open.
    /// Owned here because it belongs to this window, not to the application.
    var scaleRegionsWindow: ScaleRegionsWindowController?

    private let store: ProjectWindowLayoutStore
    private let canvasProvider: (@MainActor () -> NSViewController)?
    private var navigatorItem: NSSplitViewItem!
    private var canvasItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var ledgerItem: NSSplitViewItem?
    /// Stands in the outer split while the ledger is in its own window. On macOS 26 an
    /// `NSSplitViewController` whose split view was assigned (our chrome split view) and which
    /// holds exactly one item throws "index 1 beyond bounds [0 .. 0]" from
    /// `splitView:shouldHideDividerAtIndex:` on its next layout — the launch crash for anyone
    /// who quit with the ledger detached. The outer split therefore never drops to one item: a
    /// collapsed, zero-size placeholder takes the ledger's place.
    private var detachedLedgerPlaceholder: NSSplitViewItem?
    private var ledgerViewController: NSViewController!
    private var toolOptionsHost: NSViewController!
    /// Whether an observation of the style strip's target is pending (r2-markup).
    private var isObservingStyleStrip = false
    private var toolOptionsHeight: NSLayoutConstraint!
    private var detachedLedgerController: LedgerDetachWindowController?
    /// How the detached ledger's window reaches the screen. A test injects a no-op so it can
    /// exercise detach and re-dock without putting a window on the user's screen — the rule a
    /// crash-recovery test broke on 2026-08-25, and the reason this is a seam and not a call.
    var presentDetachedLedgerWindow: (LedgerDetachWindowController) -> Void = { $0.showWindow(nil) }
    /// The detached window's frame-autosave key. A test injects `""` (AppKit's documented
    /// no-autosave) so exercising detach cannot write into the user's real preferences —
    /// `WindowLayoutDefaultsIsolationTests` records what that cost the last time.
    var detachedLedgerAutosaveName: String = ZPDFShellAutosaveName.detachedLedgerWindow
    /// One ear strip per window edge, keyed by edge. Built once, sized by their content, so an
    /// edge with nothing closed on it occupies no space and intercepts no clicks.
    private var earHosts: [ZPDFPaneEdge: NSView] = [:]
    private var hasAppliedInitialLayout = false
    /// The undo toast's host over the canvas (NL-UX-12).
    private(set) var undoToastHost: NSView?
    private var isApplyingLayout = false

    /// Creates the window composition.
    ///
    /// - Parameters:
    ///   - environment: presenters and shell models.
    ///   - store: where the layout is persisted. Inject an in-memory store in tests.
    ///   - canvasProvider: builds the controller that fills the canvas pane. The app target passes
    ///     the real page renderer here; when it is `nil` the shell draws the presenter's geometry
    ///     itself, which is what lets the window be exercised against `MockPresenters`.
    public init(
        environment: ProjectShellEnvironment,
        store: ProjectWindowLayoutStore = ProjectWindowLayoutStore(),
        canvasProvider: (@MainActor () -> NSViewController)? = nil
    ) {
        self.environment = environment
        self.store = store
        self.canvasProvider = canvasProvider
        self.toolbarBuilder = ZenitToolbarBuilder(environment: environment)
        self.toolSlotRouter = ToolSlotKeyRouter(presenter: environment.toolLibrary)
        let state = store.load()
        self.layoutState = state
        self.panelState = ShellPanelState(
            navigatorSection: state.navigatorSection,
            expandedInspectorSections: state.expandedInspectorSections,
            isLedgerDetached: state.isLedgerDetached,
            isLedgerCollapsedToBar: state.isLedgerBarCollapsed,
            bottomPaneTab: state.bottomPaneTab ?? .quantities
        )
        super.init(nibName: nil, bundle: nil)
        environment.layoutController = self
        // While the canvas owns the keyboard — a two-point pick, a typed length, a shape a tool
        // switch would throw away — no tool key switches tools: a switch mid-shape discards the
        // shape (NL-MEASURE-05), and one during a pick lights a tool the next click does not use.
        // The key goes on to the canvas instead: A makes an arc, a digit starts a typed length
        // (NL-MEASURE-18), any other tool key is refused with a note. The canvas decides
        // (``canvasOwnsToolKey``), so the window and the canvas cannot disagree (ADR-0030). The
        // slot monitor runs before the canvas's keyDown, which is why the claim is
        // asked here at all.
        self.toolSlotRouter.claimsDrawingKey = { [weak self, measurement = environment.measurement] characters, modifiers in
            if let owns = self?.canvasOwnsToolKey { return owns(characters, modifiers) }
            // No application canvas: the measurement presenter's shape. A count group is not
            // lost by a tool switch — the switch commits it (decided 2026-08-26) — so only A,
            // the arc key, is held mid-count.
            guard let kind = measurement.activeKind, !measurement.placedPoints.isEmpty else { return false }
            return !kind.isPointPlacement || (characters == "a" && modifiers.isEmpty)
        }
        // L-103: while the armed tool is missing the value it needs (empty or unreadable field), a
        // number typed at the canvas goes into the options bar's field instead of arming the Tool
        // Library preset in that slot. Over a filled field the number is the slot.
        self.toolSlotRouter.takesParameterKey = { [weak self] characters, modifiers in
            self?.typeIntoParameterField(characters: characters, modifiers: modifiers) ?? false
        }
        // K-02 / R-069: the single-letter canvas tool shortcuts (S, P, Z, T, C, R, M, X, ⇧C, A)
        // run through the same command path as the toolbar and the menus. Unset, the router
        // passed every letter on and only A worked, served by the canvas's own keyDown.
        self.toolSlotRouter.performCommand = { [weak environment] command in
            environment?.perform(command)
        }
        // The toolbar's last-used memory, read back out of the store it has been written to
        // all along (CR-100). Before `onPersistableChange` is wired, and through a setter that
        // does not raise it: a restore is not a user choice, and a write to the store from
        // inside this initializer is how a restore becomes an overwrite.
        // All three palettes, the Shapes palette included (IM-141, R-081): the shape used to be
        // restorable and never stored, so Shapes forgot its last shape on every relaunch.
        environment.toolbar.restoreLastUsed(
            measurementKind: state.lastUsedMeasurementKind,
            countPresetID: state.lastUsedCountPresetID,
            shapeKind: state.lastUsedShapeKind
        )
        environment.toolbar.restoreToolStyle(state.toolStyle)
        environment.toolbar.onPersistableChange = { [weak self] in
            // The palette tooltips name the tool the button will re-arm, so they change
            // whenever the memory does (CR-114).
            self?.toolbarBuilder.refreshLiveHelp()
            self?.persistLayoutState()
        }
        panelState.onChange = { [weak self] in self?.persistLayoutState() }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        // The shell builds its window in code; there is no nib to decode from.
        return nil
    }

    // MARK: - View loading

    public override func loadView() {
        let container = ZPDFPanelBackgroundView(token: .background)
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        buildSplitControllers()
        buildChrome()
        // A tool armed before the window had a view — a restored session, a test — must
        // still get its options strip.
        updateToolOptionsBar()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        installToolSlotKeyMonitor()
    }

    public override func viewWillDisappear() {
        removeToolSlotKeyMonitor()
        // The Scale Regions panel belongs to THIS drawing (BH-291). It floats, and a tab switch
        // replaces this controller's view without deactivating the application, so the panel
        // used to stay up over the next tab's drawing — bound to this tab's model, filing a
        // boundary drawn on tab B against tab A, and out of reach of tab B's Escape.
        closeScaleRegionsPanel()
        super.viewWillDisappear()
    }

    // MARK: - Number-key tool slots

    /// The local key monitor that serves the number-key tool slots, while the window is up.
    ///
    /// A monitor rather than a responder-chain hook, because a bare digit has to be claimed
    /// *before* the canvas's own `keyDown` reaches `super` and beeps at it, and because the
    /// canvas view belongs to the app target while this rule belongs to the shell. The monitor
    /// is scoped hard: it ignores every event that is not for this controller's window, and it
    /// asks ``currentToolSlotFocus()`` before it will consider a key at all.
    private var toolSlotKeyMonitor: Any?

    /// Whether the number-key slots are live for this window right now.
    public var isToolSlotKeyMonitorInstalled: Bool { toolSlotKeyMonitor != nil }

    /// Starts serving the number-key slots. Idempotent.
    public func installToolSlotKeyMonitor() {
        guard toolSlotKeyMonitor == nil else { return }
        toolSlotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only `Sendable` values cross into the main actor here: `NSEvent` itself is not
            // `Sendable`, and reaching for it on the other side of the hop is the one thing
            // Swift 6 will not let this monitor do.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.view.window else { return false }
                guard event.windowNumber == window.windowNumber else { return false }
                return self.toolSlotRouter.handleKey(
                    characters: event.charactersIgnoringModifiers,
                    modifiers: ZPDFModifierFlags(event.modifierFlags),
                    focus: self.currentToolSlotFocus()
                )
            }
            return handled ? nil : event
        }
    }

    /// Stops serving them. Idempotent, and safe to call more than once per window.
    public func removeToolSlotKeyMonitor() {
        guard let monitor = toolSlotKeyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        toolSlotKeyMonitor = nil
    }

    /// The options bar's value box while the armed tool asks for a value, or `nil` (L-103).
    public var measurementParameterBox: MeasurementParameterBoxView? {
        guard isViewLoaded, let toolOptionsHost, !toolOptionsHost.view.isHidden,
              environment.measurement.requiredParameter != nil else { return nil }
        if let box = toolOptionsHost.view.firstMeasurementParameterBox() { return box }
        // The SwiftUI content makes the box on its first layout pass; a key that arrives before
        // the strip has been drawn still has a field to land in.
        toolOptionsHost.view.layoutSubtreeIfNeeded()
        return toolOptionsHost.view.firstMeasurementParameterBox()
    }

    /// Types a number key into the value the armed tool is asking for (L-103). Returns whether the
    /// key was spent: `false` when no value is being asked for, or the key is not part of a number.
    ///
    /// "Asked for" is ``MeasurementToolPresenting/isMissingRequiredParameter`` — the field is
    /// empty or does not read as a number, so the tool cannot commit and the options bar says
    /// "Enter a slope before finishing". It is *not* "the armed tool has a value field": every
    /// Wall Area, Volume and slope tool has one, and the first four Tool Library slots (Exterior
    /// Wall, Interior Wall, Slab 200 mm, Roof 6:12) arm such tools with their saved value in it.
    /// Taking digits on the field's mere presence turned "2" over an armed Exterior Wall into a
    /// 2 m wall height on the tool still armed, instead of Interior Wall with its own 2.4 m —
    /// the same silent wrong quantity L-103 reported, from the other direction. Over a filled
    /// field a number key is the Tool Library slot, as it always was.
    ///
    /// A digit or a decimal separator, bare or with Shift (the layouts whose digit row needs it,
    /// BH-283), puts the keyboard in the field and types there, replacing what the field held —
    /// the field selects its value when it takes the keyboard, so "20" typed at the canvas reads
    /// 20, not the old value with 20 after it. While a value is asked for, a number key never
    /// arms a preset, even in the instant before the strip has a field to take it.
    @discardableResult
    public func typeIntoParameterField(characters: String, modifiers: ZPDFModifierFlags) -> Bool {
        guard environment.measurement.isMissingRequiredParameter,
              modifiers.isEmpty || modifiers == [.shift], characters.count == 1,
              let character = characters.first,
              character.isNumber || character == "." || character == "," else { return false }
        measurementParameterBox?.focusAndInsert(characters)
        return true
    }

    /// Where the keyboard is pointing, as the slot rule needs to see it.
    ///
    /// Three things make a digit *not* a tool slot, and all three are real states of this
    /// window rather than guesses:
    ///
    /// - the first responder is not inside the canvas — the Tool Library's own filter field is
    ///   the obvious case, and typing `3` into it must produce a `3`;
    /// - text is being edited, which includes the canvas's **own** Text markup editor: that
    ///   editor is a text view inside the canvas, so "focus is on the canvas" is true at
    ///   exactly the moment the answer must be no;
    /// - a canvas view mode — Split Canvas, Revision Overlay — is covering the canvas, where
    ///   there is no armed tool to speak of.
    public func currentToolSlotFocus() -> ToolSlotKeyRouter.Focus {
        guard let responder = view.window?.firstResponder else { return .elsewhere }
        // `NSTextView` is an `NSText`, and a focused `NSTextField` puts its field editor —
        // also an `NSText` — in the chain, so one test covers every text surface in the window.
        let isEditingText = responder is NSText
        guard canvasPane?.isShowingMode != true, let canvasView = canvasPane?.canvasController.view else {
            return ToolSlotKeyRouter.Focus(isCanvasFirstResponder: false, isEditingText: isEditingText)
        }
        let isOnCanvas: Bool
        if let responderView = responder as? NSView {
            isOnCanvas = responderView === canvasView || responderView.isDescendant(of: canvasView)
        } else {
            isOnCanvas = false
        }
        return ToolSlotKeyRouter.Focus(
            isCanvasFirstResponder: isOnCanvas,
            isEditingText: isEditingText
        )
    }

    /// Applies the stored layout the first time the panes have a real size.
    ///
    /// This deliberately does **not** happen in `viewWillAppear`. At that point the split views
    /// have been added as Auto Layout subviews but never laid out, so their bounds are still
    /// zero — and `applyLayoutState` positions dividers by measuring those bounds. Restoring a
    /// 240 pt ledger against a zero-height split asks for divider position `-241`, which AppKit
    /// resolves by collapsing the pane. The docked Quantity Ledger then never appeared, and
    /// `captureLayoutState` wrote that collapse back to disk, so the next launch started from a
    /// corrupted layout.
    public override func viewDidLayout() {
        super.viewDidLayout()
        guard !initialLayoutSettled, hasUsableSplitBounds else { return }
        // The window passes through several sizes on its way up — the placeholder frame,
        // the fitting-size squeeze from the `contentViewController` swap, then the restored
        // autosaved frame. Applying the stored layout once against an early, smaller pass
        // left the ledger divider wherever those bounds happened to be. Re-apply on every
        // pass that changes the split's height and freeze only once it holds still.
        let height = outerSplitController.splitView.bounds.height
        if height != lastAppliedSplitHeight {
            lastAppliedSplitHeight = height
            // The root's `viewDidLayout` runs before its subviews finish their own pass. A divider
            // set now, against split subviews still framed for the previous size, was undone by
            // the split's pass that followed — the stored 240 pt ledger came up 535 pt tall until
            // the deferred `finishInitialLayout` corrected it, and never in a headless render.
            // Settle the splits at the new size first, so the positions set next are final.
            outerSplitController.splitView.layoutSubtreeIfNeeded()
            applyLayoutState()
            if !hasAppliedInitialLayout, layoutState.isLedgerDetached {
                // Not from inside this layout pass. Removing a split item while AppKit is
                // still laying the split out left `NSSplitViewController` asking about a
                // divider its item list no longer had — "index 1 beyond bounds [0 .. 0]" in
                // `splitView:shouldHideDividerAtIndex:`, an uncaught exception in the display
                // cycle that crashed the app on every launch for anyone whose ledger was
                // detached when they last quit (crash reports, 2026-09-23/24).
                DispatchQueue.main.async { [weak self] in
                    self?.detachQuantityLedger(persist: false)
                }
            }
            hasAppliedInitialLayout = true
        }
    }

    /// The outer split height the stored layout was last applied against.
    private var lastAppliedSplitHeight: CGFloat = -1
    /// Set by `finishInitialLayout()` once the stored layout has been applied against the
    /// window's final launch frame. Until then the stored layout is re-applied on every
    /// size change and nothing is persisted — repeated passes at the same *transient* size
    /// are not the end of the churn, so no repeat-height heuristic can stand in for this.
    private var initialLayoutSettled = false

    /// Whether both split views have been laid out to a size the divider maths can trust.
    private var hasUsableSplitBounds: Bool {
        contentSplitController.splitView.bounds.width > 0
            && outerSplitController.splitView.bounds.height > 0
    }

    private func buildSplitControllers() {
        // The two side panels are cards. Each needs the gutter only on the side facing the
        // window edge: the divider between it and the canvas is already a gutter wide.
        let navigator = ZPDFPanelHostViewController(
            accessibilityLabel: NSLocalizedString("Navigator", comment: "Accessibility: sidebar pane"),
            background: ZPDFWindowChrome.cardToken,
            chrome: .card(insets: NSEdgeInsets(top: 0, left: Self.gutter, bottom: 0, right: 0)),
            rootView: NavigatorSidebar(environment: environment, panelState: panelState)
        )
        let canvas = CanvasPaneContainerViewController(
            canvasController: canvasProvider?() ?? ZPDFPanelHostViewController(
                accessibilityLabel: NSLocalizedString("Page canvas", comment: "Accessibility: canvas pane"),
                background: .canvasBackdrop,
                rootView: CanvasHostPlaceholder(environment: environment)
            ),
            topBar: makeCanvasTopBar(),
            topBarHeight: Self.canvasTopBarHeight,
            statusStrip: ZPDFPanelHostViewController(
                accessibilityLabel: NSLocalizedString(
                    "Canvas status",
                    comment: "Accessibility: the status strip under the page canvas"
                ),
                background: ZPDFWindowChrome.groundToken,
                rootView: StatusBarView(environment: environment)
            ),
            statusStripHeight: Self.statusBarHeight
        )
        canvasPane = canvas
        installUndoToast(over: canvas)
        let inspector = ZPDFPanelHostViewController(
            accessibilityLabel: NSLocalizedString("Inspector", comment: "Accessibility: inspector pane"),
            background: ZPDFWindowChrome.cardToken,
            chrome: .card(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Self.gutter)),
            rootView: InspectorPanel(environment: environment, panelState: panelState)
        )
        let ledger = ZPDFPanelHostViewController(
            accessibilityLabel: NSLocalizedString("Quantity Ledger", comment: "Accessibility: ledger pane"),
            background: .surface,
            rootView: QuantityLedgerPane(environment: environment, panelState: panelState)
        )
        ledgerViewController = ledger

        // Escape backs out one level — from a panel, it closes the panel.
        // These are the AppKit-level escape routes; the SwiftUI views carry the same action
        // through `onExitCommand` for when focus is inside the SwiftUI content.
        navigator.onEscape = { [weak self] in self?.toggleNavigator() }
        inspector.onEscape = { [weak self] in self?.toggleInspector() }
        // Escape on the bottom pane closes the pane, whichever of its two tabs is on screen.
        ledger.onEscape = { [weak self] in self?.toggleBottomPane() }

        // Plain items, not `sidebarWithViewController:` / `inspectorWithViewController:`. Those
        // behaviours wrap the pane in the system sidebar material — on macOS 26 a floating glass
        // sidebar — which paints over the card and turns the mockup's flat navy panels into
        // light rounded slabs (design-qa, d9 pass 1). Collapse, width limits and the ears are
        // all driven by this controller, so nothing the behaviours added is lost.
        navigatorItem = NSSplitViewItem(viewController: navigator)
        navigatorItem.canCollapse = true
        navigatorItem.minimumThickness = ProjectWindowLayoutState.minimumNavigatorWidth
        navigatorItem.maximumThickness = ProjectWindowLayoutState.maximumNavigatorWidth
        navigatorItem.holdingPriority = .defaultLow

        canvasItem = NSSplitViewItem(viewController: canvas)
        canvasItem.canCollapse = false
        canvasItem.minimumThickness = 360
        canvasItem.holdingPriority = .init(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue - 10)

        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = ProjectWindowLayoutState.minimumInspectorWidth
        inspectorItem.maximumThickness = ProjectWindowLayoutState.maximumInspectorWidth
        // Held like the Navigator: when the window resizes, the canvas gives and takes.
        inspectorItem.holdingPriority = .defaultLow

        let content = ZPDFObservingSplitViewController()
        // Before anything touches `splitView`: the controller installs its own on first read.
        content.splitView = ZPDFChromeSplitView()
        content.splitView.isVertical = true
        // No `autosaveName` here, and none on the outer split. `ProjectWindowLayoutStore` already
        // persists every pane size and collapse flag, and it clamps them through
        // `ProjectWindowLayoutState.normalized()`. AppKit's own autosave restores raw divider
        // frames *after* `applyLayoutState` has run, so with both in play the two writers
        // overwrote each other and the unclamped autosave won — that is how a collapsed ledger
        // and a 477 pt navigator ended up in the defaults with no way to recover them.
        content.addSplitViewItem(navigatorItem)
        content.addSplitViewItem(canvasItem)
        content.addSplitViewItem(inspectorItem)
        content.onResize = { [weak self] in self?.splitViewsDidResize() }
        // Divider 0 is Navigator | canvas, divider 1 is canvas | Inspector.
        content.onDividerDoubleClick = { [weak self] index in
            guard let self else { return false }
            switch index {
            case 0:
                self.setNavigatorVisible(self.navigatorItem.isCollapsed)
                return true
            case 1:
                self.setInspectorVisible(self.inspectorItem.isCollapsed)
                return true
            default:
                return false
            }
        }
        contentSplitController = content

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.canCollapse = false
        contentItem.minimumThickness = 320

        let outer = ZPDFObservingSplitViewController()
        outer.splitView = ZPDFChromeSplitView()
        outer.splitView.isVertical = false
        outer.addSplitViewItem(contentItem)
        outer.onResize = { [weak self] in self?.splitViewsDidResize() }
        // The only divider of the outer split is content | bottom pane.
        outer.onDividerDoubleClick = { [weak self] index in
            guard let self, index == 0 else { return false }
            self.toggleBottomPane()
            return true
        }
        outerSplitController = outer

        // A ledger that was in its own window when the person quit never joins the split: it is
        // presented in its window once the first layout has settled. Adding it here and removing
        // it again during launch mutated the split mid-layout, which crashed every launch.
        if layoutState.isLedgerDetached {
            insertDetachedLedgerPlaceholder(into: outer)
        } else {
            insertLedgerItem()
        }
        addChild(outer)
    }

    private func buildChrome() {
        // The lower half of the top band, on the same ground as the toolbar above it.
        let tabBarHost = ZPDFPanelHostViewController(
            accessibilityLabel: NSLocalizedString("Open documents", comment: "Accessibility: tab bar"),
            background: ZPDFWindowChrome.groundToken,
            rootView: DocumentTabBarView(model: environment.tabBar)
        )
        // The contextual tool options strip. Always in the view tree,
        // zero-height until a tool asks it a question, so appearing costs a constraint
        // constant rather than a view-hierarchy rebuild mid-gesture.
        let toolOptionsHost = ZPDFPanelHostViewController(
            accessibilityLabel: NSLocalizedString("Tool options", comment: "Accessibility: tool options bar"),
            background: ZPDFWindowChrome.groundToken,
            rootView: ToolOptionsBar(environment: environment)
        )
        self.toolOptionsHost = toolOptionsHost
        addChild(tabBarHost)
        addChild(toolOptionsHost)
        tabStripView = tabBarHost.view

        // The top band: brand and tabs left, tools centred, workspace group right — drawn by the
        // window from the toolbar builder's own views (see ``ProjectTopBandView``).
        let band = ProjectTopBandView(builder: toolbarBuilder, environment: environment, tabsView: tabBarHost.view)
        band.isShown = !(layoutState.isTopBandHidden ?? false)
        topBand = band
        // LT3-03: the band grows a tab row when the open documents need one.
        band.onPreferredHeightChange = { [weak self, weak band] in
            guard let self, let band else { return }
            self.topBandHeight?.constant = band.preferredHeight
            self.view.needsLayout = true
        }

        let toolOptionsView = toolOptionsHost.view
        let splitView = outerSplitController.view
        for subview in [band, toolOptionsView, splitView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        toolOptionsHeight = toolOptionsView.heightAnchor.constraint(equalToConstant: 0)
        toolOptionsView.isHidden = true
        let bandHeight = band.heightAnchor.constraint(equalToConstant: band.preferredHeight)
        topBandHeight = bandHeight

        // The project window uses `.fullSizeContentView` with a transparent titlebar and a hidden
        // toolbar, so the band starts at the very top of the window, under the window controls,
        // exactly as the mockup's top chrome does.
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: view.topAnchor),
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bandHeight,

            toolOptionsView.topAnchor.constraint(equalTo: band.bottomAnchor),
            toolOptionsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolOptionsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolOptionsHeight,

            // A gutter under the band, then the content row down to the window's bottom edge:
            // the mockup's bottom edge is the Quantity Ledger bar, not a status bar.
            splitView.topAnchor.constraint(equalTo: toolOptionsView.bottomAnchor, constant: Self.gutter),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        buildPaneEars(over: splitView)
        refreshSurfaceState()
    }

    /// The canvas bar over the page, on the chrome ground: the bar draws only its rounded
    /// control groups, so the column's ground shows between them.
    private func makeCanvasTopBar() -> NSViewController? {
        ZPDFPanelHostViewController(
            accessibilityLabel: NSLocalizedString(
                "Canvas controls",
                comment: "Accessibility label for the bar above the canvas"
            ),
            background: ZPDFWindowChrome.groundToken,
            rootView: CanvasTopBar(environment: environment, undoState: environment.canvasUndoState)
        )
    }

    // MARK: - The ears

    /// Builds one ear strip per window edge, over the split view.
    ///
    /// Over rather than inside: an ear belongs to the *window edge the pane lived on*, and the
    /// pane it restores is gone from the split by the time the ear is needed, so there is no
    /// pane left to hang it off. Each strip is sized by its content, which is nothing at all
    /// while every pane on that edge is open — so the ears cost the canvas no clickable area
    /// and no pixels until the moment they are the only way back.
    private func buildPaneEars(over splitView: NSView) {
        for edge in ZPDFPaneEdge.allCases {
            let host = NSHostingView(rootView: PaneEarStrip(
                edge: edge,
                environment: environment,
                panelState: panelState,
                onActivate: { [weak self] surface in self?.reveal(surface) }
            ))
            host.sizingOptions = [.intrinsicContentSize]
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host, positioned: .above, relativeTo: splitView)

            // The same position along its edge every time, so the hand learns it: centred.
            switch edge {
            case .leading:
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: splitView.leadingAnchor),
                    host.centerYAnchor.constraint(equalTo: splitView.centerYAnchor)
                ])
            case .trailing:
                NSLayoutConstraint.activate([
                    host.trailingAnchor.constraint(equalTo: splitView.trailingAnchor),
                    host.centerYAnchor.constraint(equalTo: splitView.centerYAnchor)
                ])
            case .bottom:
                NSLayoutConstraint.activate([
                    host.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),
                    host.centerXAnchor.constraint(equalTo: splitView.centerXAnchor)
                ])
            }
            earHosts[edge] = host
        }
    }

    /// The view holding one surface's ear. `nil` before the view loads.
    ///
    /// Exposed so a test can prove the ear is in this window's view tree, rather than proving
    /// that a `ZPDFPaneEar` value can be constructed — the difference between the two is every
    /// built-but-unwired surface this project has shipped.
    public func paneEarHost(for surface: ZPDFClosableSurface) -> NSView? {
        earHosts[surface.edge]
    }

    // MARK: - Which surfaces are on screen

    /// Whether the bottom pane is on screen at all, docked or in its own window.
    public var isBottomPaneVisible: Bool {
        if detachedLedgerController != nil { return true }
        guard let ledgerItem else { return false }
        return !ledgerItem.isCollapsed
    }

    /// Whether one closable surface is on screen.
    ///
    /// The Quantity Ledger and History are the same split item, so "visible" for them means
    /// the bottom pane is up **and** showing that tab. That is what makes the View menu's
    /// title honest: *Hide History* only when History is the thing you are looking at.
    public func isVisible(_ surface: ZPDFClosableSurface) -> Bool {
        switch surface {
        case .navigator:
            return navigatorItem != nil && !navigatorItem.isCollapsed
        case .inspector:
            return inspectorItem != nil && !inspectorItem.isCollapsed
        case .quantityLedger:
            return isBottomPaneVisible && panelState.bottomPaneTab == .quantities
        case .history:
            return isBottomPaneVisible && panelState.bottomPaneTab == .history
        }
    }

    /// Recomputes the observable mirrors the ears, the toolbar chips and the menu read.
    ///
    /// Ears are not the complement of visibility. History is not visible while the pane shows
    /// Quantities, and it needs no ear — its tab is one click away. It needs one exactly when
    /// the pane itself is gone, and then so does the Quantity Ledger: an affordance present on
    /// one tab of a closed pane and absent on the other teaches a rule and then breaks it.
    public func refreshSurfaceState() {
        guard isViewLoaded, navigatorItem != nil, inspectorItem != nil else { return }
        var visible: Set<ZPDFClosableSurface> = []
        var ears: Set<ZPDFClosableSurface> = []
        for surface in ZPDFClosableSurface.allCases where isVisible(surface) {
            visible.insert(surface)
        }
        if !isVisible(.navigator) { ears.insert(.navigator) }
        if !isVisible(.inspector) { ears.insert(.inspector) }
        if !isBottomPaneVisible { ears.formUnion([.quantityLedger, .history]) }
        panelState.visibleSurfaces = visible
        panelState.earSurfaces = ears
    }

    // MARK: - Showing and hiding a surface

    /// Shows one surface, at the size the pane had.
    public func reveal(_ surface: ZPDFClosableSurface) {
        switch surface {
        case .navigator: setNavigatorVisible(true)
        case .inspector: setInspectorVisible(true)
        case .quantityLedger: showBottomPane(on: .quantities)
        case .history: showBottomPane(on: .history)
        }
    }

    /// Shows one surface, or hides it when it is already the thing on screen.
    ///
    /// The command every View-menu item and every ✕ runs.
    public func toggle(_ surface: ZPDFClosableSurface) {
        if isVisible(surface) {
            switch surface {
            case .navigator: setNavigatorVisible(false)
            case .inspector: setInspectorVisible(false)
            case .quantityLedger, .history: hideBottomPane()
            }
        } else {
            reveal(surface)
        }
    }

    /// Shows or hides the bottom pane, leaving its tab alone. The pane's AppKit Escape route and
    /// the outer divider's double-click.
    ///
    /// A detached ledger counts as on screen, so this hides it — re-docked, then collapsed, as
    /// ``toggle(_:)`` does for the pane's ✕ and its SwiftUI Escape. It used to stop at the
    /// re-dock, so Escape with focus in the detached ledger's table (which reaches the host's
    /// `cancelOperation`, not SwiftUI's `onExitCommand`) left the pane open in the window (U-046).
    public func toggleBottomPane() {
        if isBottomPaneVisible { hideBottomPane() } else { showBottomPane(on: panelState.bottomPaneTab) }
    }

    /// Brings the bottom pane up on one tab, at the height it had.
    private func showBottomPane(on tab: ZPDFBottomPaneTab) {
        panelState.bottomPaneTab = tab
        layoutState.bottomPaneTab = tab
        if let controller = detachedLedgerController {
            controller.showWindow(nil)
        } else if let ledgerItem, ledgerItem.isCollapsed || panelState.isLedgerCollapsedToBar {
            layoutState.isLedgerCollapsed = false
            revealDockedLedger(barCollapsed: false)
        }
        persistLayoutState()
        refreshSurfaceState()
    }

    /// Puts the bottom pane away, remembering the height it had.
    ///
    /// A detached ledger is re-docked first and *then* hidden (BH-807). The View menu reads
    /// "Hide Quantity Ledger" while the ledger is in its own window, and choosing it used to stop
    /// at the re-dock — the pane landed open in the window, the opposite of what the item said.
    private func hideBottomPane() {
        if detachedLedgerController != nil {
            attachQuantityLedger()
        }
        guard let ledgerItem, !ledgerItem.isCollapsed else { return }
        rememberLedgerHeight()
        layoutState.isLedgerCollapsed = true
        setCollapsed(true, of: ledgerItem)
        persistLayoutState()
        refreshSurfaceState()
    }

    /// Records the docked ledger's live height, so the ear and the menu restore *that*.
    private func rememberLedgerHeight() {
        guard let ledgerItem, !panelState.isLedgerCollapsedToBar else { return }
        let height = Double(ledgerItem.viewController.view.frame.height)
        if height > Double(QuantityLedgerPane.collapsedBarHeight) {
            layoutState.ledgerHeight = height
        }
    }

    /// Shows or hides the Navigator, restoring the width it had.
    ///
    /// The restore sets the divider explicitly instead of leaving `isCollapsed = false` to pick
    /// a width: AppKit brings a pane back at whatever frame it last held, which after a session
    /// of layout churn is not the width the person chose.
    public func setNavigatorVisible(_ visible: Bool) {
        guard navigatorItem != nil else { return }
        if visible {
            guard navigatorItem.isCollapsed else { return }
            layoutState.isNavigatorCollapsed = false
            fadePaneChange(of: navigatorItem)
            navigatorItem.isCollapsed = false
            view.layoutSubtreeIfNeeded()
            applyNavigatorWidth(layoutState.navigatorWidth)
        } else {
            guard !navigatorItem.isCollapsed else { return }
            let width = Double(navigatorItem.viewController.view.frame.width)
            if width >= ProjectWindowLayoutState.minimumNavigatorWidth {
                layoutState.navigatorWidth = width
            }
            // The stored flag moves with the pane. Until the launch layout has settled,
            // `viewDidLayout` re-applies the stored state on every size pass — and a stale
            // `false` here re-opened the pane the person had just closed.
            layoutState.isNavigatorCollapsed = true
            setCollapsed(true, of: navigatorItem)
        }
        persistLayoutState()
        refreshSurfaceState()
    }

    /// Shows or hides the Inspector, restoring the width it had.
    public func setInspectorVisible(_ visible: Bool) {
        guard inspectorItem != nil else { return }
        if visible {
            guard inspectorItem.isCollapsed else { return }
            layoutState.isInspectorCollapsed = false
            fadePaneChange(of: inspectorItem)
            inspectorItem.isCollapsed = false
            view.layoutSubtreeIfNeeded()
            applyInspectorWidth(layoutState.inspectorWidth)
        } else {
            guard !inspectorItem.isCollapsed else { return }
            let width = Double(inspectorItem.viewController.view.frame.width)
            if width >= ProjectWindowLayoutState.minimumInspectorWidth {
                layoutState.inspectorWidth = width
            }
            layoutState.isInspectorCollapsed = true
            setCollapsed(true, of: inspectorItem)
        }
        persistLayoutState()
        refreshSurfaceState()
    }

    /// Puts divider 0 where the Navigator is `width` wide.
    private func applyNavigatorWidth(_ width: Double) {
        let split = contentSplitController.splitView
        guard split.bounds.width > 0 else { return }
        split.setPosition(CGFloat(width), ofDividerAt: 0)
    }

    /// Puts divider 1 where the Inspector is `width` wide.
    private func applyInspectorWidth(_ width: Double) {
        let split = contentSplitController.splitView
        guard split.bounds.width > 0 else { return }
        split.setPosition(split.bounds.width - CGFloat(width) - split.dividerThickness, ofDividerAt: 1)
    }

    /// Shows or hides the contextual tool options strip.
    ///
    /// Called from ``ProjectShellEnvironment`` on every tool change, so the strip is a
    /// function of the armed tool and cannot drift from it. Exposed so a test can arm a
    /// tool and assert that the question actually appears.
    public func updateToolOptionsBar() {
        guard isViewLoaded, let toolOptionsHeight, let toolOptionsHost else { return }
        // r2-markup (NL-MARKUP-03): the style strip shares the slot.
        let shows = environment.measurement.requiredParameter != nil || MarkupStyleStrip.shows(in: environment)
        observeStyleStripTarget()
        guard toolOptionsHost.view.isHidden == shows else { return }
        toolOptionsHost.view.isHidden = !shows
        toolOptionsHeight.constant = shows ? Self.toolOptionsBarHeight : 0
        view.needsLayout = true
    }

    /// Re-evaluates the strip when the selection or the armed tool changes (r2-markup): the
    /// selection lives on the canvas presenter, which the tool-change hook does not hear.
    private func observeStyleStripTarget() {
        guard !isObservingStyleStrip else { return }
        isObservingStyleStrip = true
        withObservationTracking {
            _ = MarkupStyleStrip.target(in: environment)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isObservingStyleStrip = false
                self?.updateToolOptionsBar()
            }
        }
    }

    /// Whether the contextual tool options strip is on screen. Read by the shell's tests.
    public var isToolOptionsBarVisible: Bool {
        guard isViewLoaded, let toolOptionsHost else { return false }
        return !toolOptionsHost.view.isHidden
    }

    private func insertLedgerItem() {
        guard ledgerItem == nil else { return }
        let item = NSSplitViewItem(viewController: ledgerViewController)
        item.canCollapse = true
        // Above the content row's priority: when the window resizes it is the canvas that
        // grows and shrinks, never the ledger — the pane keeps the height the user gave it.
        item.holdingPriority = .init(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
        item.isCollapsed = layoutState.isLedgerCollapsed
        applyLedgerThicknessLimits(to: item, barCollapsed: layoutState.isLedgerBarCollapsed)
        outerSplitController.addSplitViewItem(item)
        ledgerItem = item
    }

    /// Adds the collapsed stand-in for a detached ledger (see ``detachedLedgerPlaceholder``).
    private func insertDetachedLedgerPlaceholder(into split: NSSplitViewController) {
        guard detachedLedgerPlaceholder == nil else { return }
        let empty = NSViewController()
        empty.view = NSView(frame: .zero)
        let item = NSSplitViewItem(viewController: empty)
        item.canCollapse = true
        item.minimumThickness = 0
        item.isCollapsed = true
        split.addSplitViewItem(item)
        detachedLedgerPlaceholder = item
    }

    /// Pins or frees the ledger pane's height range for the bar-collapsed state.
    ///
    /// Collapsed to its header bar the pane is exactly one header tall and the divider will
    /// not drag; expanded it is resizable between the supported bounds again.
    private func applyLedgerThicknessLimits(to item: NSSplitViewItem, barCollapsed: Bool) {
        if barCollapsed {
            item.minimumThickness = QuantityLedgerPane.collapsedBarHeight
            item.maximumThickness = QuantityLedgerPane.collapsedBarHeight
        } else {
            item.minimumThickness = ProjectWindowLayoutState.minimumLedgerHeight
            item.maximumThickness = ProjectWindowLayoutState.maximumLedgerHeight
        }
    }

    // MARK: - Layout state

    /// Pushes the stored layout onto the panes.
    public func applyLayoutState() {
        // Restored, not cleared: a caller that is itself applying a layout (a workspace recall,
        // re-docking the ledger) keeps its guard up after this nested apply (R-072).
        let wasApplying = isApplyingLayout
        isApplyingLayout = true
        defer { isApplyingLayout = wasApplying }

        navigatorItem.isCollapsed = layoutState.isNavigatorCollapsed
        inspectorItem.isCollapsed = layoutState.isInspectorCollapsed
        ledgerItem?.isCollapsed = layoutState.isLedgerCollapsed

        // Resolve the whole subtree from this controller's own view: laying out only the split's
        // subtree leaves the split's *own* frame unresolved, which is how the divider maths used
        // to run against zero bounds.
        view.layoutSubtreeIfNeeded()

        let contentSplit = contentSplitController.splitView
        if contentSplit.bounds.width > 0, !layoutState.isNavigatorCollapsed {
            contentSplit.setPosition(layoutState.navigatorWidth, ofDividerAt: 0)
        }
        if contentSplit.bounds.width > 0, !layoutState.isInspectorCollapsed {
            let width = contentSplit.bounds.width
            contentSplit.setPosition(
                width - layoutState.inspectorWidth - contentSplit.dividerThickness,
                ofDividerAt: 1
            )
        }

        let outerSplit = outerSplitController.splitView
        if let ledgerItem, outerSplit.bounds.height > 0, !layoutState.isLedgerCollapsed {
            applyLedgerThicknessLimits(to: ledgerItem, barCollapsed: layoutState.isLedgerBarCollapsed)
            var restoredHeight = layoutState.isLedgerBarCollapsed
                ? Double(QuantityLedgerPane.collapsedBarHeight)
                : layoutState.ledgerHeight
            let height = outerSplit.bounds.height
            // Clamp to what the canvas row can give up: a 240 pt ledger against a short
            // split would put the divider at a negative position, which AppKit resolves
            // by collapsing the pane — and that collapse then gets persisted as if the
            // user chose it (the corrupted-layout bug this method's comment describes).
            let available = Double(height - outerSplit.dividerThickness) - 360
            restoredHeight = min(
                restoredHeight,
                max(Double(QuantityLedgerPane.collapsedBarHeight), available)
            )
            ledgerItem.isCollapsed = false
            outerSplit.setPosition(
                height - restoredHeight - outerSplit.dividerThickness,
                ofDividerAt: 0
            )
        }
        panelState.isLedgerCollapsedToBar = layoutState.isLedgerBarCollapsed
        refreshSurfaceState()
    }

    /// Reads the live pane sizes back into ``layoutState``.
    public func captureLayoutState() {
        var state = layoutState
        state.isNavigatorCollapsed = navigatorItem.isCollapsed
        state.isInspectorCollapsed = inspectorItem.isCollapsed
        state.isLedgerCollapsed = ledgerItem?.isCollapsed ?? false
        state.isLedgerBarCollapsed = ledgerItem != nil && panelState.isLedgerCollapsedToBar
        state.isLedgerDetached = detachedLedgerController != nil
        if !navigatorItem.isCollapsed {
            state.navigatorWidth = Double(navigatorItem.viewController.view.frame.width)
        }
        if !inspectorItem.isCollapsed {
            state.inspectorWidth = Double(inspectorItem.viewController.view.frame.width)
        }
        if let ledgerItem, !ledgerItem.isCollapsed, !panelState.isLedgerCollapsedToBar {
            // The bar-collapsed height is a constant, never the height worth restoring to —
            // and mid-transition the live frame can still *be* the bar height (the flag
            // flips before the divider moves), so only a real content height is recorded.
            let height = Double(ledgerItem.viewController.view.frame.height)
            if height > Double(QuantityLedgerPane.collapsedBarHeight) {
                state.ledgerHeight = height
            }
        }
        state.detachedLedgerFrame = detachedLedgerController?.currentFrame ?? state.detachedLedgerFrame
        state.navigatorSection = panelState.navigatorSection
        state.bottomPaneTab = panelState.bottomPaneTab
        state.expandedInspectorSections = panelState.expandedInspectorSections
        state.lastUsedMeasurementKind = environment.toolbar.lastUsedMeasurementKind
        state.lastUsedCountPresetID = environment.toolbar.lastUsedCountPresetID
        state.lastUsedShapeKind = environment.toolbar.lastUsedShapeKind
        state.toolStyle = environment.toolbar.toolStyle == .zenitInk ? nil : environment.toolbar.toolStyle
        layoutState = state.normalized()
    }

    /// Applies the stored layout against the window's final launch bounds and opens the
    /// gate for persistence. Until this runs, nothing the launch-time size churn does to
    /// the panes is written back to disk — the churn once overwrote `ledgerHeight` with
    /// whatever a transient 447 pt pass had clamped it to.
    private func finishInitialLayout() {
        applyLayoutState()
        initialLayoutSettled = true
    }

    // MARK: - Undo toast (NL-UX-12, nl-ux)

    /// Floats the undo toast at the top of the canvas, just under the canvas bar. The host
    /// never takes a click.
    private func installUndoToast(over canvas: CanvasPaneContainerViewController) {
        let container = canvas.view
        let host = PassThroughHostingView(rootView: UndoToastView(model: environment.undoToast))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = [.intrinsicContentSize]
        container.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor, constant: canvas.topBarHeight + ZPDFSpacing.m)
        ])
        undoToastHost = host
    }

    // MARK: - Workspaces (NL-UX-10, nl-ux)

    /// The live arrangement, captured, as a workspace stores it.
    public func workspaceLayoutSnapshot() -> ProjectWindowLayoutState {
        captureLayoutState()
        return layoutState
    }

    /// Re-arranges the window to a stored workspace layout: panes, sizes, the Navigator page,
    /// the bottom tab, the expanded Inspector sections and the ledger's docked or detached
    /// state. The window's tool memory is kept — a workspace never changes the armed tool.
    public func applyWorkspaceLayout(_ workspace: ProjectWindowLayoutState) {
        var next = workspace.normalized()
        next.lastUsedMeasurementKind = layoutState.lastUsedMeasurementKind
        next.lastUsedCountPresetID = layoutState.lastUsedCountPresetID
        next.lastUsedShapeKind = layoutState.lastUsedShapeKind
        next.toolStyle = layoutState.toolStyle
        next.detachedLedgerFrame = next.detachedLedgerFrame ?? layoutState.detachedLedgerFrame
        layoutState = next
        // R-072: every write below raises a persist — `panelState.onChange` and the ledger's
        // attach both call `persistLayoutState()` — and a persist captures the LIVE panes over
        // `layoutState`, so the workspace's widths and collapse flags were replaced by the
        // arrangement being left before `applyLayoutState()` ran. `adoptStoredLayout()` has
        // always held this guard; the workspace recall now does too.
        isApplyingLayout = true
        panelState.navigatorSection = next.navigatorSection
        if let tab = next.bottomPaneTab { panelState.bottomPaneTab = tab }
        panelState.expandedInspectorSections = next.expandedInspectorSections
        if next.isLedgerDetached, detachedLedgerController == nil {
            detachQuantityLedger(persist: false)
        } else if !next.isLedgerDetached, detachedLedgerController != nil {
            attachQuantityLedger()
        }
        // Moving the ledger writes its own flags; the workspace's stand, with the frame the
        // detached window just reported. A detached ledger is never bar-collapsed.
        next.detachedLedgerFrame = layoutState.detachedLedgerFrame ?? next.detachedLedgerFrame
        if next.isLedgerDetached { next.isLedgerBarCollapsed = false }
        layoutState = next
        isApplyingLayout = false
        // S-047: the band follows the workspace's flag, which is stored with it. It used to be
        // written to the layout and not applied, so the band on screen and the stored layout
        // disagreed until the next tab switch or launch flipped the band.
        applyTopBandFlag()
        applyLayoutState()
        guard hasAppliedInitialLayout, initialLayoutSettled else { return }
        store.save(layoutState)
    }

    /// Whether a person is resizing right now — the event being handled is a drag of this
    /// application's (a divider drag's tracking loop), or the window is in live resize — so the
    /// layout is written once at the end rather than on every step. Read from the app's own
    /// current event, not the system-wide button state, so nothing outside the app defers a
    /// write. Injectable for tests, which cannot drag.
    var isUserResizing: @MainActor () -> Bool = {
        guard let event = NSApp?.currentEvent else { return false }
        return event.type == .leftMouseDragged || event.type == .leftMouseDown
    }

    /// A split laid its panes out at new sizes (S-059).
    ///
    /// The surface mirrors and ``layoutState`` follow every step, as before. The write to the
    /// store — a JSON encode, a defaults write and a `UserDefaults.didChangeNotification` that
    /// every window's author badge observes — waited for nothing and ran on every frame of a
    /// divider drag or live window resize. While a person is resizing it is now deferred to a
    /// default-run-loop-mode perform, which AppKit holds back through the drag's and the live
    /// resize's event tracking and runs once when they end.
    func splitViewsDidResize() {
        guard isUserResizing() || view.inLiveResize else {
            persistLayoutState()
            return
        }
        refreshSurfaceState()
        guard !isApplyingLayout, hasAppliedInitialLayout, initialLayoutSettled else { return }
        captureLayoutState()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(flushDeferredLayoutSave), object: nil)
        perform(#selector(flushDeferredLayoutSave), with: nil, afterDelay: 0, inModes: [.default])
    }

    /// The one write a resize defers to, once the drag or live resize is over.
    @objc private func flushDeferredLayoutSave() {
        persistLayoutState()
    }

    /// Captures and writes the layout. Called on panel changes, and once at the end of a
    /// divider drag or live window resize (``splitViewsDidResize()``).
    public func persistLayoutState() {
        // Before the guard: a divider dragged all the way to the edge collapses a pane with no
        // command involved, and that pane must grow its ear whether or not the layout is at a
        // point where it is worth writing to disk.
        refreshSurfaceState()
        guard !isApplyingLayout, hasAppliedInitialLayout, initialLayoutSettled else { return }
        captureLayoutState()
        store.save(layoutState)
    }

    // MARK: - Pane commands

    /// Collapses or expands one split item, and **recomputes the mirrors**.
    ///
    /// The recompute lives here rather than at each call site because it was missing from one.
    /// `revealNavigatorSection(_:)` expanded the Navigator without it, so opening Search from a
    /// closed Navigator left `panelState.visibleSurfaces` saying the Navigator was closed: its
    /// ear stayed on screen and its toolbar chip stayed dark while the panel was plainly up. The
    /// same staleness made a Navigator section impossible to close from its chip, because
    /// `isPanelOpen(.find)` reads that mirror and still said "open" after the pane collapsed.
    ///
    /// Found by `PanelSweepTests` on 2026-08-27. Every other caller already called
    /// `refreshSurfaceState()` afterwards, which is exactly why the one that forgot was invisible.
    /// Calling it here is idempotent, so those callers keep working and no new one can forget.
    ///
    /// The change itself is made in **one step** and the motion is a cross-fade
    /// (``fadePaneChange(of:)``). L-80 (live test 8): the pane used to slide, by setting
    /// `isCollapsed` inside an implicit-animation group. For the slide, the split view controller
    /// pins the pane's wrapper at a constant breadth (priority 999.99, above the pane's own
    /// minimum) and lifts the pin when its transition completes. When it did not complete — and
    /// in a window that is not drawing it never does — the pin outlived the slide: the pane came
    /// back pinned, the divider could not be moved, and after Hide Navigator, Hide Inspector,
    /// Hide Quantity Ledger and Show for each the Navigator was held at about 120 pt, under its
    /// 180 pt minimum. A one-step change installs no pin.
    private func setCollapsed(_ collapsed: Bool, of item: NSSplitViewItem) {
        guard item.isCollapsed != collapsed else { return }
        fadePaneChange(of: item)
        item.isCollapsed = collapsed
        refreshSurfaceState()
    }

    /// The motion for a pane appearing or going (navigator, inspector and ledger show/hide at
    /// `standard`): the split the pane belongs to cross-fades from what it
    /// showed to what it shows next. A layer transition, so the split's own layout is never in a
    /// transition of its own. With Reduce Motion on the change is simply made.
    private func fadePaneChange(of item: NSSplitViewItem) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let owner: NSSplitViewController? = contentSplitController?.splitViewItems.contains(item) == true
            ? contentSplitController
            : outerSplitController
        guard let splitView = owner?.view else { return }
        splitView.wantsLayer = true
        guard let layer = splitView.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = ZPDFMotion.standard.duration
        layer.add(fade, forKey: "zenit.paneVisibility")
    }

    /// Shows or hides the Navigator, restoring the width it had.
    public func toggleNavigator() {
        setNavigatorVisible(navigatorItem.isCollapsed)
    }

    /// Shows or hides the Inspector, restoring the width it had.
    public func toggleInspector() {
        setInspectorVisible(inspectorItem.isCollapsed)
    }

    /// Shows the bottom pane on its Quantities tab, or hides it when that is already what is
    /// on screen. Re-docks the pane first when it is in its own window.
    public func toggleQuantityLedger() {
        toggle(.quantityLedger)
    }

    /// Shows the bottom pane on its History tab, or hides it when History is already showing.
    public func toggleHistory() {
        toggle(.history)
    }

    /// Collapses the docked Quantity Ledger to just its header bar, or restores it to its
    /// previous height. One-click show/hide: the header chip and its chevron
    /// both route here.
    public func toggleQuantityLedgerBar() {
        guard detachedLedgerController == nil, let ledgerItem else { return }
        if ledgerItem.isCollapsed {
            // The pane is hidden entirely; asking for the bar means "show it again".
            revealDockedLedger(barCollapsed: false)
        } else {
            setLedgerBarCollapsed(!panelState.isLedgerCollapsedToBar)
        }
        persistLayoutState()
    }

    /// Un-collapses the docked ledger at a pinned height, keeping the window frame fixed.
    ///
    /// `NSSplitViewItem.isCollapsed = false` on its own re-adds the pane at whatever frame
    /// height it last had — after a session of layout churn that can be most of a screen,
    /// and AppKit resolves the shortfall by *growing the window*, which is how "Show
    /// Quantity Ledger" once pushed the status bar off a 1084 pt display. Pinning the item
    /// to its restored height during the reveal and re-asserting the window frame keeps the
    /// pane at `ledgerHeight` and the window exactly where the user left it.
    private func revealDockedLedger(barCollapsed: Bool) {
        guard let ledgerItem else { return }
        panelState.isLedgerCollapsedToBar = barCollapsed
        layoutState.isLedgerBarCollapsed = barCollapsed

        // Resolve the split's real bounds first — reading them stale is how a clamp
        // against "available height" once passed an 888 pt pane on a 1006 pt window.
        view.layoutSubtreeIfNeeded()
        let outerSplit = outerSplitController.splitView
        var target = barCollapsed
            ? Double(QuantityLedgerPane.collapsedBarHeight)
            : layoutState.ledgerHeight
        if outerSplit.bounds.height > 0 {
            // Never ask for more height than the canvas row can give up.
            let available = Double(outerSplit.bounds.height - outerSplit.dividerThickness) - 360
            target = min(target, max(Double(QuantityLedgerPane.collapsedBarHeight), available))
        }

        let window = view.window
        let savedFrame = window?.frame
        ledgerItem.minimumThickness = CGFloat(target)
        ledgerItem.maximumThickness = CGFloat(target)
        ledgerItem.isCollapsed = false
        view.layoutSubtreeIfNeeded()
        applyLedgerThicknessLimits(to: ledgerItem, barCollapsed: barCollapsed)
        if let window, let savedFrame, window.frame != savedFrame {
            window.setFrame(savedFrame, display: true)
            view.layoutSubtreeIfNeeded()
        }
        if outerSplit.bounds.height > 0 {
            outerSplit.setPosition(
                outerSplit.bounds.height - target - outerSplit.dividerThickness,
                ofDividerAt: 0
            )
        }
        // The clamped height is the one worth restoring next time.
        if !barCollapsed { layoutState.ledgerHeight = target }
    }

    /// Applies the bar-collapsed state to the docked ledger pane.
    private func setLedgerBarCollapsed(_ collapsed: Bool) {
        guard let ledgerItem else { return }
        if collapsed {
            // Remember the height being left so expanding restores it exactly.
            let height = Double(ledgerItem.viewController.view.frame.height)
            if height > Double(QuantityLedgerPane.collapsedBarHeight) {
                layoutState.ledgerHeight = height
            }
        }
        // Resolve the restore height *before* touching `panelState`: its onChange persists
        // the layout, and a capture taken mid-transition must not feed back into the target.
        let outerSplit = outerSplitController.splitView
        let targetHeight = collapsed
            ? Double(QuantityLedgerPane.collapsedBarHeight)
            : Self.clampedLedgerHeight(layoutState.ledgerHeight, splitHeight: outerSplit.bounds.height, dividerThickness: outerSplit.dividerThickness)
        panelState.isLedgerCollapsedToBar = collapsed
        layoutState.isLedgerBarCollapsed = collapsed
        applyLedgerThicknessLimits(to: ledgerItem, barCollapsed: collapsed)
        guard outerSplit.bounds.height > 0 else { return }
        outerSplit.setPosition(
            outerSplit.bounds.height - targetHeight - outerSplit.dividerThickness,
            ofDividerAt: 0
        )
        // The clamped height is the one worth restoring next time, as `revealDockedLedger` does.
        if !collapsed { layoutState.ledgerHeight = targetHeight }
    }

    /// A restored ledger height, limited to what the canvas row can give up (BH-808).
    ///
    /// The same clamp `revealDockedLedger` and `applyLayoutState` apply: a 700 pt ledger
    /// expanded from its header bar in a window shrunk to its 640 pt minimum asked for a divider
    /// at −171, which AppKit resolves by collapsing the pane — leaving nothing on screen while
    /// `isLedgerCollapsedToBar` said the pane was expanded. With no measured split yet the
    /// stored height passes through unchanged.
    static func clampedLedgerHeight(
        _ height: Double,
        splitHeight: CGFloat,
        dividerThickness: CGFloat
    ) -> Double {
        guard splitHeight > 0 else { return height }
        let available = Double(splitHeight - dividerThickness) - 360
        return min(height, max(Double(QuantityLedgerPane.collapsedBarHeight), available))
    }

    /// Opens the Navigator on one page, expanding it if it was collapsed.
    ///
    /// Through ``setNavigatorVisible(_:)`` (BH-809), so the Search and Project Zones chips reopen
    /// the pane exactly as the View menu and the ear do: at the width the person chose, with the
    /// stored collapse flag moved with it. A bare `setCollapsed(false, …)` let AppKit bring the
    /// pane back at whatever frame it last held and left `isNavigatorCollapsed` true, so a
    /// pre-settle layout pass (or a later `applyLayoutState`) re-collapsed the pane just opened.
    public func revealNavigatorSection(_ section: NavigatorSection) {
        if navigatorItem.isCollapsed { setNavigatorVisible(true) }
        panelState.navigatorSection = section
    }

    /// Shows a Navigator section, or closes the Navigator when that section is already showing.
    ///
    /// The panel chips show whether the panel is open, so pressing again is an obvious way
    /// back. `isPanelOpen(.find)` and `isPanelOpen(.projectZones)` answer that
    /// question, and the chips light — but ``revealNavigatorSection(_:)`` only ever *opens*, so
    /// the second press did nothing at all. The chip said "open", the reader pressed it to close,
    /// and the panel stayed. Found by `PanelSweepTests` on 2026-08-27.
    ///
    /// Closing the whole Navigator, rather than switching to another section, is the behaviour
    /// the chip promises: the chip is the Navigator-on-this-page, so turning it off turns that
    /// off. Switching sections is what the section switcher inside the Navigator is for.
    public func toggleNavigatorSection(_ section: NavigatorSection) {
        if !navigatorItem.isCollapsed, panelState.navigatorSection == section {
            // The same close as View ▸ Hide Navigator: the width remembered, the stored flag
            // moved with the pane and the layout written. A bare collapse left the store saying
            // "open" and the width unrecorded.
            setNavigatorVisible(false)
            return
        }
        revealNavigatorSection(section)
    }

    // MARK: - Detaching the ledger

    /// Moves the Quantity Ledger between the dock and its own window.
    public func toggleQuantityLedgerDetached() {
        if detachedLedgerController == nil {
            detachQuantityLedger(persist: true)
        } else {
            attachQuantityLedger()
        }
    }

    /// Moves the Quantity Ledger into its own window.
    ///
    /// - Parameter persist: `false` while restoring a saved layout, so the restore does not
    ///   immediately rewrite what it just read.
    public func detachQuantityLedger(persist: Bool = true) {
        guard detachedLedgerController == nil else { return }
        if let item = ledgerItem {
            // The placeholder first, so the outer split never holds a single item.
            insertDetachedLedgerPlaceholder(into: outerSplitController)
            outerSplitController.removeSplitViewItem(item)
            ledgerItem = nil
        }

        let controller = LedgerDetachWindowController(
            contentViewController: ledgerViewController,
            initialFrame: layoutState.detachedLedgerFrame,
            autosaveName: detachedLedgerAutosaveName,
            parentFrame: view.window?.frame,           // L-84: open beside the project window
            screenFrame: view.window?.screen?.visibleFrame
        )
        controller.onCloseRequested = { [weak self] in self?.attachQuantityLedger() }
        presentDetachedLedgerWindow(controller)
        detachedLedgerController = controller
        panelState.isLedgerDetached = true
        // Its own window always shows the full ledger; a bar-collapsed window would be
        // nothing but a title bar over a title bar.
        panelState.isLedgerCollapsedToBar = false
        layoutState.isLedgerBarCollapsed = false
        if persist { persistLayoutState() }
        refreshSurfaceState()
    }

    /// Docks the Quantity Ledger back into the project window.
    public func attachQuantityLedger() {
        guard let controller = detachedLedgerController else { return }
        layoutState.detachedLedgerFrame = controller.currentFrame
        controller.dismissForReattach()
        detachedLedgerController = nil
        panelState.isLedgerDetached = false
        panelState.isLedgerCollapsedToBar = false
        layoutState.isLedgerDetached = false
        layoutState.isLedgerCollapsed = false
        layoutState.isLedgerBarCollapsed = false
        let savedFrame = view.window?.frame
        insertLedgerItem()
        if let placeholder = detachedLedgerPlaceholder {
            outerSplitController.removeSplitViewItem(placeholder)
            detachedLedgerPlaceholder = nil
        }
        applyLayoutState()
        // Re-docking must never grow the window (see `revealDockedLedger`).
        if let window = view.window, let savedFrame, window.frame != savedFrame {
            window.setFrame(savedFrame, display: true)
        }
        persistLayoutState()
        refreshSurfaceState()
    }

    /// Whether the ledger is currently in its own window.
    public var isQuantityLedgerDetached: Bool { detachedLedgerController != nil }

    /// The live detached-window controller, for tests that drive the window's own close path.
    var detachedLedgerControllerForTesting: LedgerDetachWindowController? { detachedLedgerController }

    // MARK: - Toolbar customization

    /// Opens the standard toolbar customization sheet on the window.
    ///
    /// Reachable from View > Customize Toolbar (the `.customizeToolbar` command). The window's
    /// `NSToolbar` is hidden — the top band draws the tools — so it is shown for the length of
    /// the sheet, where the person drags items in and out as always, and hidden again when the
    /// sheet ends; the band follows every change through ``ProjectTopBandView/bind(to:)``.
    ///
    /// L-82 (live test 8): the toolbar and the band were both on screen for the length of the
    /// sheet — every tool drawn twice, one copy shifted up into the titlebar — and the toolbar
    /// stayed up after Done "until another tab is selected". Now the band stands aside while the
    /// toolbar is up (``ProjectTopBandView/isCustomizing``), and the end of the sheet is caught
    /// three ways, because one notification was not enough: the window's sheet ending, the
    /// palette no longer running when the window next updates, and the toolbar being put back
    /// up by AppKit after either. The sheet's display-mode menu ("Show: Icon Only") is turned off
    /// where AppKit allows it, because the chips draw their own captions and the toolbar must stay
    /// icon-only.
    public func runToolbarCustomization() {
        guard let window = view.window, let toolbar = window.toolbar else { return }
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        toolbar.displayMode = .iconOnly
        isCustomizingToolbar = true
        sawCustomizationPaletteRunning = false
        topBand?.isCustomizing = true
        toolbar.isVisible = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(customizationSheetEnded(_:)),
            name: NSWindow.didEndSheetNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowUpdatedDuringCustomization(_:)),
            name: NSWindow.didUpdateNotification,
            object: window
        )
        runCustomizationPalette(toolbar)
        if customizationPaletteIsRunning(toolbar) { sawCustomizationPaletteRunning = true }
    }

    /// How the customization sheet is started. A test injects a no-op: the real sheet would
    /// land on the user's screen.
    var runCustomizationPalette: (NSToolbar) -> Void = { $0.runCustomizationPalette(nil) }
    /// Whether the customization sheet is up. A test injects its own answer, since its sheet is
    /// never really run.
    var customizationPaletteIsRunning: (NSToolbar) -> Bool = { $0.customizationPaletteIsRunning }

    /// Whether this controller has the toolbar up for the customization sheet.
    public private(set) var isCustomizingToolbar = false
    /// Whether the sheet has been seen running since it was asked for, so a window update that
    /// arrives before AppKit has put the sheet up is not taken for its end.
    private var sawCustomizationPaletteRunning = false

    /// The customization sheet has closed: the toolbar goes back to being the band's model.
    @objc func customizationSheetEnded(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let toolbar = window.toolbar else { return }
        // A sheet that ends while the palette is still up is some other sheet over it.
        guard !(isCustomizingToolbar && customizationPaletteIsRunning(toolbar)) else { return }
        endToolbarCustomization()
    }

    /// The window updates after every event: once the palette has been up and is not any more,
    /// the customization is over, whatever notification did or did not arrive.
    @objc func windowUpdatedDuringCustomization(_ notification: Notification) {
        guard isCustomizingToolbar, let toolbar = (notification.object as? NSWindow)?.toolbar else { return }
        if customizationPaletteIsRunning(toolbar) {
            sawCustomizationPaletteRunning = true
        } else if sawCustomizationPaletteRunning {
            endToolbarCustomization()
        }
    }

    /// Ends a customization: the toolbar hidden again, the band back with the arrangement the
    /// sheet left. Idempotent.
    func endToolbarCustomization() {
        guard let window = view.window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: window)
        isCustomizingToolbar = false
        sawCustomizationPaletteRunning = false
        hideToolbarOutsideCustomization()
        topBand?.isCustomizing = false
        topBand?.refreshArrangement()
    }

    /// Watches the window's toolbar: shown at any moment other than the customization sheet —
    /// AppKit putting it back up as it finishes a customization it has already reported over,
    /// or an autosave restoring "visible" — it is hidden again on the next turn (L-82).
    private func observeToolbarVisibility(_ toolbar: NSToolbar?) {
        toolbarVisibilityObservation = toolbar?.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            // A run-loop block rather than a main-queue one: it also runs inside a nested run
            // loop, such as the one AppKit spins while it ends the sheet.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.hideToolbarOutsideCustomization() }
            }
        }
    }

    /// The observation behind ``observeToolbarVisibility(_:)``, for the toolbar now on the window.
    private var toolbarVisibilityObservation: NSKeyValueObservation?

    /// Hides the window's toolbar unless the customization sheet has it up: the band draws the
    /// tools, and a visible toolbar is a second copy of every one of them.
    func hideToolbarOutsideCustomization() {
        guard !isCustomizingToolbar, let toolbar = view.window?.toolbar else { return }
        if toolbar.displayMode != .iconOnly { toolbar.displayMode = .iconOnly }
        if toolbar.isVisible { toolbar.isVisible = false }
    }

    // MARK: - Window installation

    /// Installs the toolbar and the frame autosave on the window this controller fills.
    public func configure(window: NSWindow) {
        Self.applyChrome(to: window)
        window.toolbarStyle = Self.toolbarStyle
        window.toolbar = toolbarBuilder.makeToolbar()
        // Attaching the toolbar restores its autosaved configuration, which can carry a
        // display mode from an older build. The chips draw their own captions, so the
        // toolbar itself must stay icon-only or AppKit
        // doubles every caption under its chip. Not a user preference; re-assert it
        // after the autosave has been applied.
        window.toolbar?.displayMode = .iconOnly
        // Hidden: the band draws the tools; the toolbar keeps the arrangement, its autosave and
        // the customization sheet. Re-asserted after the autosave, which can carry visibility.
        window.toolbar?.isVisible = false
        observeToolbarVisibility(window.toolbar)
        topBand?.bind(to: window.toolbar)
        // The frame autosave writes `NSWindow Frame …` into the standard domain: the assembled
        // application's, never a test runner's.
        if ZPDFShellAutosaveName.appKitAutosavesEnabled {
            window.setFrameAutosaveName(ZPDFShellAutosaveName.projectWindow)
        }
        window.minSize = NSSize(width: 1_040, height: 640)
        // A controller configured again is a document tab coming back to the front. Every tab
        // has its own controller over the SAME stored layout, and each used to re-impose the
        // layout it had loaded at creation — close the Inspector in tab 2, switch to tab 1, and
        // tab 1's stale "open" popped it back and was then persisted over tab 2's choice
        // (BH-292). The window has one layout; the tab coming forward adopts the stored one.
        if initialLayoutSettled {
            adoptStoredLayout()
        }
        // One more pass after the launch churn: the frame set above is the window's final
        // size, but the split panes were positioned against whatever intermediate bounds
        // the layout passes happened to see. Re-apply the stored layout on the next turn
        // of the run loop, when the bounds are the real ones.
        DispatchQueue.main.async { [weak self] in
            self?.finishInitialLayout()
        }
    }

    /// The toolbar style the project window uses.
    ///
    /// The toolbar is hidden and the top band draws the tools, so the style shows only while the
    /// customization sheet has the toolbar up; unified is the compact one for that.
    public static let toolbarStyle: NSWindow.ToolbarStyle = .unified

    /// Makes the titlebar part of the chrome: transparent, over the window ground, with no rule
    /// under it — the top band's own hairline is the band's one lower edge.
    ///
    /// The window already uses `.fullSizeContentView`, so the layout root, painted in the ground
    /// token, runs up under the toolbar; the transparent titlebar lets it show, and the toolbar
    /// and tab strip read as one continuous surface instead of a system bar over a panel.
    public static func applyChrome(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = ZPDFColor.nsColor(ZPDFWindowChrome.groundToken)
    }

    /// Replaces this controller's in-memory layout with the stored one and applies it.
    ///
    /// What stays this tab's own: whether *its* ledger is in its own window, and that window's
    /// frame — a detached window is an object this controller owns, not a preference.
    func adoptStoredLayout() {
        var stored = store.load()
        stored.isLedgerDetached = layoutState.isLedgerDetached
        stored.detachedLedgerFrame = layoutState.detachedLedgerFrame
        if detachedLedgerController != nil {
            stored.isLedgerBarCollapsed = false
        }
        layoutState = stored
        applyTopBandFlag()
        isApplyingLayout = true
        panelState.navigatorSection = stored.navigatorSection
        panelState.expandedInspectorSections = stored.expandedInspectorSections
        panelState.bottomPaneTab = stored.bottomPaneTab ?? panelState.bottomPaneTab
        isApplyingLayout = false
        guard isViewLoaded, navigatorItem != nil else { return }
        applyLayoutState()
    }
}
