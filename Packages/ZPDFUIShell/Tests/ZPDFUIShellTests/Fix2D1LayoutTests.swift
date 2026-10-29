import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// A view that takes the keyboard, standing in for the application's canvas page view.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Builds a project window that is laid out but never ordered on screen.
@MainActor
private func makeWindow(
    environment: ProjectShellEnvironment = .mock(),
    defaults: ZPDFInMemoryDefaults = ZPDFInMemoryDefaults(),
    key: String,
    height: CGFloat = 900
) -> (ProjectWindowLayoutController, NSWindow) {
    let layout = ProjectWindowLayoutController(
        environment: environment,
        store: ProjectWindowLayoutStore(defaults: defaults, key: key)
    )
    layout.presentDetachedLedgerWindow = { _ in }
    layout.detachedLedgerAutosaveName = ""
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_400, height: height),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = layout
    window.setFrame(NSRect(x: 0, y: 0, width: 1_400, height: height), display: false)
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window)
}

/// Fix round 2, part D1: focus routing, panel painting, the layout controller's lifecycle and
/// bounds, the pane ears and the document tab bar.
@MainActor
@Suite("Fix2 D1 — Layout, focus and tabs", .shellTierSerialised)
struct Fix2D1LayoutTests {

    // MARK: - BH-289 / BH-290: keyboard focus across a canvas view mode

    /// A canvas pane whose canvas is an `NSScrollView` around a focusable page view — the shape
    /// of the application's `PDFCanvasViewController` — in a window never put on screen.
    private func makeCanvasPane() -> (CanvasPaneContainerViewController, NSWindow, FocusableView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = FocusableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = page
        let canvas = NSViewController()
        canvas.view = scrollView
        let pane = CanvasPaneContainerViewController(canvasController: canvas)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.layoutIfNeeded()
        return (pane, window, page)
    }

    private func makeMode() -> ZPDFPanelHostViewController<Text> {
        ZPDFPanelHostViewController(accessibilityLabel: "Split Canvas", background: .background, rootView: Text("Mode"))
    }

    /// BH-289 claimed `makeFirstResponder(modeView)` fails because the panel background refuses
    /// first responder, leaving the covered canvas page view key. Measured against the shipping
    /// `CanvasPaneContainerViewController` it does not: `NSWindow.makeFirstResponder(_:)` asks
    /// only `becomeFirstResponder()`, never `acceptsFirstResponder` (which governs clicks and
    /// the key-view loop), so the mode's background takes the keyboard —
    ///
    /// ```
    /// Fix2D1 BH-289 first responder after present: Optional(<ZPDFUIShell.ZPDFPanelBackgroundView: …>)
    /// ```
    ///
    /// Kept as a pin so the behaviour the finding doubted stays proven.
    @Test("Entering a mode takes the keyboard off the covered canvas")
    func enteringAModeMovesFocusOffTheCanvas() throws {
        let (pane, window, page) = makeCanvasPane()
        defer { window.contentViewController = nil }
        #expect(window.makeFirstResponder(page))
        #expect(window.firstResponder === page)

        pane.present(mode: makeMode())
        print("Fix2D1 BH-289 first responder after present: \(String(describing: window.firstResponder))")
        let responder = window.firstResponder as? NSView
        #expect(responder !== page, "the hidden canvas page view still holds the keyboard")
        if let responder {
            #expect(!responder.isDescendant(of: pane.canvasController.view))
        }
    }

    /// BH-290 claimed `makeFirstResponder(canvasController.view)` fails on the application's
    /// `NSScrollView` and strands the keyboard on the window. Measured with the application's
    /// shape — the page view is the scroll view's `documentView` (PDFCanvasViewController
    /// loadView) — the page view has the keyboard after leaving, even when a control inside the
    /// mode held it:
    ///
    /// ```
    /// Fix2D1 BH-290 first responder after dismiss: Optional(<…FocusableView: …>)
    /// ```
    @Test("Leaving a mode gives the keyboard back to the canvas page view")
    func leavingAModeRestoresCanvasFocus() throws {
        let (pane, window, page) = makeCanvasPane()
        defer { window.contentViewController = nil }
        #expect(window.makeFirstResponder(page))
        let mode = makeMode()
        pane.present(mode: mode)
        // Something inside the mode takes the keyboard, as a control in Split Canvas would.
        let inner = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        mode.view.addSubview(inner)
        #expect(window.makeFirstResponder(inner))

        pane.dismissMode()
        print("Fix2D1 BH-290 first responder after dismiss: \(String(describing: window.firstResponder))")
        #expect(window.firstResponder === page, "leaving the mode left \(String(describing: window.firstResponder)) as first responder")
    }

    // MARK: - BH-298: the panel background paints its token

    /// Old output: `wantsUpdateLayer` was the default `false`, so `updateLayer()` never ran and
    /// `layer?.backgroundColor` stayed `nil`.
    @Test("The panel background asks for updateLayer and paints its colour")
    func panelBackgroundPaints() throws {
        let view = ZPDFPanelBackgroundView(token: .surface)
        view.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        #expect(view.wantsUpdateLayer)
        view.needsDisplay = true
        view.displayIfNeeded()
        #expect(view.layer?.backgroundColor != nil, "the token was never painted")
        #expect(!view.acceptsFirstResponder, "an ordinary panel background never takes the keyboard")
    }

    // MARK: - BH-291: Scale Regions closes with its tab

    /// Old output: `viewWillDisappear` only removed the key monitor, so after it
    /// `isShowingScaleRegionsPanel == true` and the registry still held the mode.
    @Test("Switching away from a tab closes its Scale Regions panel")
    func scaleRegionsClosesOnTabSwitch() {
        let (layout, window) = makeWindow(key: "fix2d1.scaleRegions")
        defer { window.contentViewController = nil }
        layout.toggleScaleRegionsPanel()
        #expect(layout.isShowingScaleRegionsPanel)

        layout.viewWillDisappear()
        #expect(!layout.isShowingScaleRegionsPanel, "tab A's panel is still floating over tab B")
        #expect(layout.environment.modeRegistry.exitRoute(for: ProjectWindowLayoutController.scaleRegionsModeID) == nil)
    }

    // MARK: - BH-292: a tab coming forward adopts the stored layout

    /// Old output: tab 1 re-applied the layout it loaded at creation, so after tab 2 closed the
    /// Inspector `tab1.isVisible(.inspector) == true` and the store was then rewritten "open".
    @Test("A tab switched back to does not re-impose its stale layout")
    func tabSwitchAdoptsTheStoredLayout() async throws {
        let defaults = ZPDFInMemoryDefaults()
        let key = "fix2d1.sharedLayout"
        let (tab1, window) = makeWindow(defaults: defaults, key: key)
        defer { window.contentViewController = nil }
        tab1.configure(window: window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(tab1.isVisible(.inspector))

        // Tab 2 comes forward over the same stored layout and closes the Inspector.
        let tab2 = ProjectWindowLayoutController(
            environment: .mock(),
            store: ProjectWindowLayoutStore(defaults: defaults, key: key)
        )
        window.contentViewController = tab2
        window.layoutIfNeeded()
        tab2.view.layoutSubtreeIfNeeded()
        tab2.configure(window: window)
        try await Task.sleep(for: .milliseconds(50))
        tab2.setInspectorVisible(false)
        #expect(ProjectWindowLayoutStore(defaults: defaults, key: key).load().isInspectorCollapsed)

        // Back to tab 1.
        window.contentViewController = tab1
        window.layoutIfNeeded()
        tab1.configure(window: window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!tab1.isVisible(.inspector), "tab 1 re-opened the Inspector tab 2 closed")
        #expect(ProjectWindowLayoutStore(defaults: defaults, key: key).load().isInspectorCollapsed)
    }

    // MARK: - BH-807: Hide while detached hides

    /// Old output: `hideBottomPane` stopped after `attachQuantityLedger()`, so after "Hide
    /// Quantity Ledger" the pane was docked *open*: `isBottomPaneVisible == true`.
    @Test("Hide Quantity Ledger while it is in its own window re-docks it hidden")
    func hideWhileDetachedHides() {
        let (layout, window) = makeWindow(key: "fix2d1.detachedHide")
        defer { window.contentViewController = nil }
        layout.detachQuantityLedger()
        #expect(layout.isVisible(.quantityLedger), "detached, so the menu reads Hide")

        layout.toggle(.quantityLedger)
        #expect(!layout.isQuantityLedgerDetached)
        #expect(!layout.isBottomPaneVisible, "Hide showed the pane")
        #expect(layout.panelState.showsEar(for: .quantityLedger), "and its way back is the ear")
    }

    // MARK: - BH-808: expanding from the bar is clamped

    /// Old output: the expand asked for `bounds.height - 700 - 1` — a divider at −171 in a
    /// 530 pt split, which AppKit resolves by collapsing the pane.
    @Test("A tall ledger expanded in a short window is clamped to what the canvas can give up")
    func barExpandIsClamped() {
        let clamped = ProjectWindowLayoutController.clampedLedgerHeight(700, splitHeight: 530, dividerThickness: 1)
        #expect(530 - clamped - 1 >= 0, "the divider position must stay on screen")
        #expect(clamped >= Double(QuantityLedgerPane.collapsedBarHeight))
        #expect(ProjectWindowLayoutController.clampedLedgerHeight(240, splitHeight: 900, dividerThickness: 1) == 240)
        #expect(ProjectWindowLayoutController.clampedLedgerHeight(700, splitHeight: 0, dividerThickness: 1) == 700)
    }

    // MARK: - BH-809: a section chip reopens the Navigator the way the menu does

    /// Old output: `revealNavigatorSection` expanded the item but left
    /// `layoutState.isNavigatorCollapsed == true`, so the stored flag contradicted the pane.
    @Test("Opening Search from a closed Navigator restores its width and its stored flag")
    func revealSectionRestoresTheNavigator() {
        let (layout, window) = makeWindow(key: "fix2d1.revealSection")
        defer { window.contentViewController = nil }
        let split = layout.contentSplitController.splitView
        split.setPosition(300, ofDividerAt: 0)
        layout.view.layoutSubtreeIfNeeded()
        layout.setNavigatorVisible(false)
        #expect(layout.layoutState.isNavigatorCollapsed)

        layout.revealNavigatorSection(.search)
        #expect(layout.isVisible(.navigator))
        #expect(!layout.layoutState.isNavigatorCollapsed, "the stored flag still says collapsed")
        #expect(layout.panelState.navigatorSection == .search)
        layout.view.layoutSubtreeIfNeeded()
        let restored = layout.contentSplitController.splitViewItems[0].viewController.view.frame.width
        #expect(abs(restored - CGFloat(layout.layoutState.navigatorWidth)) <= 1)
    }

    // MARK: - IM-132: ⌘F focuses; the chip toggles

    @Test("⌘F with Search showing keeps it open and asks for the field; the chip still toggles")
    func findFocusesAndChipToggles() throws {
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = makeWindow(environment: environment, key: "fix2d1.find")
        defer { window.contentViewController = nil }

        environment.perform(.find)
        #expect(environment.isPanelOpen(.find))
        #expect(layout.panelState.takeSearchFieldFocusRequest())

        // Old output: the second ⌘F toggled — `isPanelOpen(.find) == false`, the Navigator hidden.
        environment.perform(.find)
        #expect(environment.isPanelOpen(.find), "⌘F closed Search instead of focusing it")
        #expect(layout.panelState.hasPendingSearchFieldFocus)
        #expect(layout.panelState.takeSearchFieldFocusRequest())
        #expect(!layout.panelState.takeSearchFieldFocusRequest(), "one ⌘F, one focus")

        // The chip is the way back — the real chip, as the person presses it (R-073: its action
        // called `perform(.find)`, which only reveals, so the lit chip never closed Search).
        let chip = try #require(layout.toolbarBuilder.workspaceChip(.zenitSearch))
        chip.action()
        #expect(!environment.isPanelOpen(.find))
        chip.action()
        #expect(environment.isPanelOpen(.find))
    }

    // MARK: - IM-120: two ears on one edge differ by shape

    @Test("Ears sharing the bottom edge carry different glyphs; a lone ear carries none")
    func sharedEdgeEarsAreDistinct() {
        let both: [ZPDFClosableSurface] = [.quantityLedger, .history]
        let ledger = PaneEarStrip.badge(for: .quantityLedger, among: both)
        let history = PaneEarStrip.badge(for: .history, among: both)
        #expect(ledger != nil && history != nil)
        #expect(ledger != history)
        #expect(PaneEarStrip.badge(for: .navigator, among: [.navigator]) == nil)
    }

    // MARK: - IM-225: the Inspector's open state is reported, not inferred

    /// S-055 (iteration 2): the tab strip's Inspector toggle, which this used to read, was
    /// deleted (never shown in the product). The state it spoke is the environment's surface
    /// mirror, which the toolbar's and View menu's Inspector command flip.
    @Test("The Inspector's open state flips with the pane, through the toolbar's command")
    func inspectorToggleReportsState() {
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = makeWindow(environment: environment, key: "fix2d1.inspectorToggle")
        defer { window.contentViewController = nil }
        #expect(environment.isSurfaceVisible(.inspector))
        layout.toggleInspector()
        #expect(!environment.isSurfaceVisible(.inspector))
        environment.perform(.toggleInspector)
        #expect(environment.isSurfaceVisible(.inspector))
        #expect(!ProjectShellEnvironment.mock().isSurfaceVisible(.inspector), "no window: not guessed open")
    }
}

/// The document tab bar's value logic.
@MainActor
@Suite("Fix2 D1 — Document tabs", .shellTierSerialised)
struct Fix2D1TabTests {

    private func revision(
        _ label: String,
        document: UUID,
        date: Date? = nil,
        baseline: Bool = false
    ) throws -> RevisionSummary {
        var copy = try #require(ZenitSampleProject.shared.revisions.first)
        copy = RevisionSummary(
            id: UUID(),
            documentID: document,
            name: label,
            revisionLabel: label,
            issuedDate: date,
            author: copy.author,
            pageCount: copy.pageCount,
            isBaseline: baseline,
            colorRGBA: copy.colorRGBA,
            fileName: copy.fileName
        )
        return copy
    }

    private func summary(id: UUID = UUID(), pages: Int = 3) throws -> DocumentTabSummary {
        var tab = try #require(ZenitSampleProject.shared.tabs.first)
        tab = DocumentTabSummary(
            id: id,
            title: tab.title,
            fileName: tab.fileName,
            fileURL: tab.fileURL,
            pageCount: pages,
            hasUnsavedChanges: false,
            isActive: true,
            mode: tab.mode
        )
        return tab
    }

    /// Old output: `lhs.revisionLabel > rhs.revisionLabel` chose `"Rev 9"`.
    @Test("Undated revisions badge the numerically newest label")
    func undatedBadgeIsNumeric() throws {
        let doc = UUID()
        let tab = try summary(id: doc)
        let item = DocumentTabItem(summary: tab, revisions: [
            try revision("Rev 9", document: doc), try revision("Rev 10", document: doc)
        ])
        #expect(item.revisionLabel == "Rev 10")

        let withBaseline = DocumentTabItem(summary: tab, revisions: [
            try revision("Z", document: doc, baseline: true), try revision("A", document: doc)
        ])
        #expect(withBaseline.revisionLabel == "A", "the baseline is the oldest when nothing is dated")

        let dated = DocumentTabItem(summary: tab, revisions: [
            try revision("Rev 10", document: doc),
            try revision("Rev 2", document: doc, date: Date(timeIntervalSince1970: 1_000))
        ])
        #expect(dated.revisionLabel == "Rev 2", "a dated revision beats an undated one")
    }

    /// Old output: `"…, saved, 1 pages"`.
    @Test("A one-page drawing is spoken as 1 page")
    func singlePageIsSingular() throws {
        let one = DocumentTabItem(summary: try summary(pages: 1), revisions: [])
        #expect(one.accessibilityLabel.hasSuffix("1 page"))
        let many = DocumentTabItem(summary: try summary(pages: 12), revisions: [])
        #expect(many.accessibilityLabel.hasSuffix("12 pages"))
    }

    /// IM-224, measured: grouping revisions once gives the same items as scanning them per tab,
    /// and does less work.
    @Test("Tab items group revisions once and match the per-tab scan")
    func itemsGroupRevisionsOnce() throws {
        var tabs: [DocumentTabSummary] = []
        var revisions: [RevisionSummary] = []
        for index in 0..<30 {
            let id = UUID()
            tabs.append(try summary(id: id))
            for rev in 0..<20 {
                revisions.append(try revision("Rev \(rev + index)", document: id))
            }
        }
        let input = DocumentTabBarInput(tabs: tabs, activeTabID: tabs[3].id, revisions: revisions)
        // The old derivation, verbatim in effect: every tab scans every revision.
        func perTabScan() -> [DocumentTabItem] {
            input.tabs.map { summary in
                var summary = summary
                summary.isActive = summary.id == input.activeTabID
                return DocumentTabItem(summary: summary, revisions: input.revisions)
            }
        }
        #expect(DocumentTabBarModel.items(from: input) == perTabScan())

        let clock = ContinuousClock()
        let old = clock.measure { for _ in 0..<50 { _ = perTabScan() } }
        let new = clock.measure { for _ in 0..<50 { _ = DocumentTabBarModel.items(from: input) } }
        print("Fix2D1 IM-224: 30 tabs x 20 revisions, 50 renders — per-tab scan \(old), grouped \(new)")
        #expect(new < old * 2, "grouping must not be slower than scanning")
    }

    @Test("Close Other Tabs closes every other tab through the close hook")
    func closeOthers() throws {
        let tabs = [try summary(), try summary(), try summary()]
        let model = DocumentTabBarModel(input: DocumentTabBarInput(tabs: tabs, activeTabID: tabs[0].id, revisions: []))
        var closed: [UUID] = []
        model.onClose = { closed.append($0) }
        model.closeOthers(keeping: tabs[1].id)
        #expect(closed == [tabs[0].id, tabs[2].id])
    }

    @Test("The close button's space is reserved and its help names the shortcut")
    func closeButtonIsStable() {
        #expect(DocumentTabView.showsCloseButton(isHovering: false, isFocused: false, isActive: true))
        #expect(!DocumentTabView.showsCloseButton(isHovering: false, isFocused: false, isActive: false))
        #expect(DocumentTabView.showsCloseButton(isHovering: true, isFocused: false, isActive: false))
        if let binding = ZPDFCommandTable.standard.command(.closeTab)?.binding?.displayString {
            #expect(DocumentTabView.closeHelp.contains(binding))
        }
    }
}
