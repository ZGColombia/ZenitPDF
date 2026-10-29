import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Builds a project window that is laid out but never ordered on screen (a test may never put a
/// window on the user's screen).
@MainActor
private func makeLaidOutWindow(
    key: String,
    width: CGFloat = 1_672,
    height: CGFloat = 941
) -> (ProjectWindowLayoutController, NSWindow) {
    let layout = ProjectWindowLayoutController(
        environment: .mock(),
        store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key)
    )
    layout.presentDetachedLedgerWindow = { _ in }
    layout.detachedLedgerAutosaveName = ""
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = layout
    window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window)
}

/// Whether two colours are the same sRGB value, to within rounding.
private func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
    guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
    return abs(a.redComponent - b.redComponent) < 0.003
        && abs(a.greenComponent - b.greenComponent) < 0.003
        && abs(a.blueComponent - b.blueComponent) < 0.003
        && abs(a.alphaComponent - b.alphaComponent) < 0.003
}

/// A dynamic colour resolved under the dark appearance.
@MainActor
private func resolvedDark(_ color: NSColor) -> NSColor? {
    var resolved: NSColor?
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB)
    }
    return resolved
}

/// Every view in a subtree, depth first.
@MainActor
private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
}

/// Design round d8: the window composition of the 2026-09-23 main-window mockup — one dark
/// surface, rounded cards for the side panels, the canvas column with its bar and status strip,
/// no window-wide status bar.
@MainActor
@Suite("Design d8 — window composition", .shellTierSerialised)
struct DesignD8WindowTests {

    // MARK: - The status bar decision

    @Test("There is no window-wide status bar: the mockup's bottom edge is the ledger bar")
    func noWindowWideStatusBar() {
        let (layout, window) = makeLaidOutWindow(key: "d8.nostatusbar")
        defer { window.close() }
        let labels = allSubviews(of: layout.view).compactMap { $0.accessibilityLabel() }
        #expect(!labels.contains("Status bar"), "the old full-width status bar host is still in the window")
        // The outer split — content row above, ledger below — runs to the window's bottom edge.
        let split = layout.outerSplitController.view
        #expect(abs(split.frame.maxY - layout.view.bounds.maxY) < 0.5)
    }

    @Test("The canvas column carries the canvas bar on top and the status strip underneath")
    func canvasColumnHostsBarAndStrip() throws {
        let (layout, window) = makeLaidOutWindow(key: "d8.column")
        defer { window.close() }
        let pane = try #require(layout.canvasPane)
        let bar = try #require(pane.topBarController as? ZPDFPanelHostViewController<CanvasTopBar>)
        let strip = try #require(pane.statusStripController as? ZPDFPanelHostViewController<StatusBarView>)
        // Page navigation and zoom are the canvas bar's; the strip has no second pair to draw
        // (R-086 deleted it — see `stripCarriesNoNavigation`).
        #expect(bar.backgroundToken == ZPDFWindowChrome.groundToken)
        #expect(strip.backgroundToken == ZPDFWindowChrome.groundToken)
        #expect(bar.view.accessibilityLabel() == "Canvas controls")
        #expect(strip.view.accessibilityLabel() == "Canvas status")

        // Top to bottom in the (flipped) column: bar, canvas, strip — at their fixed heights.
        let barFrame = bar.view.frame
        let canvasFrame = pane.canvasController.view.frame
        let stripFrame = strip.view.frame
        #expect(pane.view.isFlipped)
        #expect(abs(barFrame.minY) < 0.5)
        #expect(abs(barFrame.height - ProjectWindowLayoutController.canvasTopBarHeight) < 0.5)
        #expect(abs(canvasFrame.minY - barFrame.maxY) < 0.5)
        #expect(abs(stripFrame.minY - canvasFrame.maxY) < 0.5)
        #expect(abs(stripFrame.height - ProjectWindowLayoutController.statusBarHeight) < 0.5)
        #expect(abs(stripFrame.maxY - pane.view.bounds.maxY) < 0.5)
        #expect(canvasFrame.height > 300, "the page keeps the column; the bars are furniture: canvas \(canvasFrame)")
    }

    @Test("A bare canvas pane is still exactly the canvas, edge to edge")
    func bareCanvasPaneFillsTheColumn() {
        let canvas = NSViewController()
        canvas.view = NSView()
        let pane = CanvasPaneContainerViewController(canvasController: canvas)
        pane.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        pane.view.layoutSubtreeIfNeeded()
        #expect(pane.topBarController == nil && pane.statusStripController == nil)
        #expect(canvas.view.frame == pane.view.bounds)
    }

    @Test("A view mode covers the canvas and its bar, never the status strip")
    func modeCoversBarButNotStrip() throws {
        let (layout, window) = makeLaidOutWindow(key: "d8.mode")
        defer { window.close() }
        let pane = try #require(layout.canvasPane)
        let mode = NSViewController()
        mode.view = NSView()
        pane.present(mode: mode)
        pane.view.layoutSubtreeIfNeeded()
        let stripFrame = try #require(pane.statusStripController?.view.frame)
        #expect(abs(mode.view.frame.minY) < 0.5, "the mode leaves the canvas bar live over a hidden canvas")
        #expect(abs(mode.view.frame.maxY - stripFrame.minY) < 0.5, "the mode hides the status strip")
        #expect(pane.topBarController?.view.isAccessibilityHidden() == true)
        #expect(pane.view.subviews.last === mode.view, "the mode must be drawn over the bar")
        pane.dismissMode()
        #expect(pane.topBarController?.view.isAccessibilityHidden() == false)
    }

    /// R-086: the strip's own page field and zoom field were built only when no canvas bar
    /// carried them, which the product never did. They are gone; the canvas bar's are the one
    /// page control and the one zoom control in the window.
    @Test("The status strip carries no page or zoom control: the canvas bar above the page does")
    func stripCarriesNoNavigation() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUIShell")
        let strip = try String(contentsOf: sources.appendingPathComponent("StatusBar/StatusBarView.swift"), encoding: .utf8)
        #expect(!strip.contains("struct PageStatusControl"))
        #expect(!strip.contains("struct ZoomStatusControl"))
        #expect(!strip.contains("includesNavigation"))
        let bar = try String(contentsOf: sources.appendingPathComponent("Canvas/CanvasTopBar.swift"), encoding: .utf8)
        #expect(bar.contains("CanvasPageControl("))
        #expect(bar.contains("CanvasZoomControl("))
    }

    // MARK: - One surface, cards on it

    @Test("Both splits divide with the chrome gutter, painted in the window ground")
    func splitsUseTheGutter() throws {
        let (layout, window) = makeLaidOutWindow(key: "d8.gutter")
        defer { window.close() }
        for split in [layout.contentSplitController.splitView, layout.outerSplitController.splitView] {
            let chrome = try #require(split as? ZPDFChromeSplitView)
            #expect(chrome.dividerThickness == ZPDFWindowChrome.gutter)
            let ground = ZPDFColor.nsColor(ZPDFWindowChrome.groundToken, variant: .dark)
            #expect(sameColor(resolvedDark(chrome.dividerColor), ground),
                    "the divider must read as gap, not as a rule")
        }
        // 12 pt between the Navigator card and the canvas (design QA pass 9
        // measured the old 8 pt).
        #expect(ZPDFWindowChrome.gutter == 12)
    }

    @Test("Navigator and Inspector are rounded cards inset from the window edge; the ledger bar is flush")
    func sidePanelsAreCards() throws {
        let (layout, window) = makeLaidOutWindow(key: "d8.cards")
        defer { window.close() }
        let items = layout.contentSplitController.splitViewItems
        let navigator = try #require(items[0].viewController as? ZPDFPanelHostViewController<NavigatorSidebar>)
        let inspector = try #require(items[2].viewController as? ZPDFPanelHostViewController<InspectorPanel>)
        let gutter = ZPDFWindowChrome.gutter
        #expect(navigator.chrome == .card(insets: NSEdgeInsets(top: 0, left: gutter, bottom: 0, right: 0)))
        #expect(inspector.chrome == .card(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: gutter)))
        for host in [navigator.cardView, inspector.cardView] {
            let card = try #require(host as? ZPDFPanelCardView)
            #expect(card.layer?.cornerRadius == ZPDFRadius.panel)
            #expect(card.layer?.masksToBounds == true)
            #expect(card.fillToken == ZPDFWindowChrome.cardToken)
            #expect(card.strokeToken == ZPDFWindowChrome.cardEdgeToken)
        }
        // The Navigator card starts one gutter in from the window's leading edge.
        let navCard = try #require(navigator.cardView)
        let navOrigin = navCard.convert(NSPoint.zero, to: layout.view)
        #expect(abs(navOrigin.x - gutter) < 0.5)
        // The Inspector card ends one gutter in from the trailing edge.
        let inspCard = try #require(inspector.cardView)
        let inspEnd = inspCard.convert(NSPoint(x: inspCard.bounds.maxX, y: 0), to: layout.view)
        #expect(abs(layout.view.bounds.maxX - inspEnd.x - gutter) < 0.5)

        let ledgerHost = try #require(layout.outerSplitController.splitViewItems.last?.viewController
            as? ZPDFPanelHostViewController<QuantityLedgerPane>)
        #expect(ledgerHost.chrome == .flush)
        #expect(ledgerHost.cardView == nil)
    }

    @Test("A card's border is one device pixel and follows the appearance")
    func cardBorderIsAHairline() {
        let card = ZPDFPanelCardView(fill: .surface)
        card.frame = NSRect(x: 0, y: 0, width: 80, height: 80)
        card.appearance = NSAppearance(named: .darkAqua)
        card.needsDisplay = true
        card.displayIfNeeded()
        let width = card.layer?.borderWidth ?? 0
        #expect(width > 0 && width <= 1)
        #expect(card.layer?.backgroundColor != nil)
        #expect(card.layer?.borderColor != nil)
    }

    @Test("The top band is one surface: tab strip on the ground, content row one gutter below it")
    func topBandIsOneSurface() throws {
        let (layout, window) = makeLaidOutWindow(key: "d8.band")
        defer { window.close() }
        let strip = try #require(layout.tabStripView)
        #expect(abs(strip.frame.height - ProjectWindowLayoutController.tabBarHeight) < 0.5)
        let host = try #require(layout.children.first { $0.view === strip }
            as? ZPDFPanelHostViewController<DocumentTabBarView>)
        #expect(host.backgroundToken == ZPDFWindowChrome.groundToken)
        #expect(!layout.isToolOptionsBarVisible)
        let content = layout.outerSplitController.view
        #expect(abs(content.frame.minY - strip.frame.maxY - ZPDFWindowChrome.gutter) < 0.5)
        // The root, too, is ground: nothing between the panels shows a different colour.
        #expect(layout.view is ZPDFPanelBackgroundView)
    }

    @Test("The titlebar is transparent over the ground, with no rule under the toolbar")
    func titlebarJoinsTheChrome() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        ProjectWindowLayoutController.applyChrome(to: window)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.titleVisibility == .hidden)
        #expect(sameColor(
            resolvedDark(window.backgroundColor),
            ZPDFColor.nsColor(ZPDFWindowChrome.groundToken, variant: .dark)
        ))
    }

    @Test("configure(window:) applies the chrome and keeps the toolbar icon-only")
    func configureAppliesChrome() {
        let (layout, window) = makeLaidOutWindow(key: "d8.configure")
        defer { window.close() }
        layout.configure(window: window)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.toolbar != nil)
        #expect(window.toolbar?.displayMode == .iconOnly)
        #expect(window.toolbar?.isVisible == false, "the band draws the tools; the toolbar is its hidden model")
    }

    @Test("The stored ledger height holds from the first layout pass, before configure(window:)")
    func storedLedgerHeightHoldsFromTheFirstPass() throws {
        // Old output (d6 / d9 renders, 2026-09-23): outer split items [320.0, 535.0] — the
        // divider set inside the root's viewDidLayout was undone by the split's own pass.
        let (layout, window) = makeLaidOutWindow(key: "d8.firstpass")
        defer { window.close() }
        let ledger = try #require(layout.outerSplitController.splitViewItems.last?.viewController.view)
        #expect(abs(ledger.frame.height - layout.layoutState.ledgerHeight) < 1,
                "ledger drawn \(ledger.frame.height) pt, stored \(layout.layoutState.ledgerHeight) pt")
    }

    // MARK: - First launch

    @Test("With nothing stored, the application's window opens the ledger as its bar")
    func firstLaunchOpensTheLedgerBar() {
        let defaults = ZPDFInMemoryDefaults()
        let store = ProjectWindowLayoutStore(defaults: defaults, key: "d8.firstlaunch", fallback: .firstLaunch)
        #expect(store.load().isLedgerBarCollapsed)
        #expect(!ProjectWindowLayoutState.default.isLedgerBarCollapsed, "the shipped default stays the expanded pane")
        #expect(ProjectWindowLayoutState.firstLaunch.ledgerHeight == ProjectWindowLayoutState.default.ledgerHeight,
                "the chevron still restores the default table height")

        let layout = ProjectWindowLayoutController(environment: .mock(), store: store)
        layout.presentDetachedLedgerWindow = { _ in }
        layout.detachedLedgerAutosaveName = ""
        #expect(layout.panelState.isLedgerCollapsedToBar)

        // A stored choice wins over the fallback.
        store.save(ProjectWindowLayoutState(isLedgerBarCollapsed: false))
        #expect(!store.load().isLedgerBarCollapsed)
        // …and an unreadable entry resolves to the fallback, not to the expanded default.
        defaults.setPersistedData(Data("junk".utf8), forKey: "d8.firstlaunch")
        #expect(store.load().isLedgerBarCollapsed)
    }

    // MARK: - The split structure other tiers rely on

    @Test("Navigator, canvas, Inspector across; content and ledger down — unchanged by the restyle")
    func splitStructureUnchanged() {
        let (layout, window) = makeLaidOutWindow(key: "d8.structure")
        defer { window.close() }
        #expect(layout.contentSplitController.splitViewItems.count == 3)
        #expect(layout.outerSplitController.splitViewItems.count == 2)
        #expect(layout.contentSplitController.splitViewItems[1].viewController is CanvasPaneContainerViewController)
    }

    @Test("The canvas bar's undo state lives on the shell, unknown until the app says")
    func undoStateStartsUnknown() {
        let environment = ProjectShellEnvironment.mock()
        #expect(environment.canvasUndoState.canUndo == nil)
        #expect(environment.canvasUndoState.canRedo == nil)
        #expect(environment.canvasUndoState.isUndoEnabled, "unknown must not dim the button")
    }

    // MARK: - The status strip when the column narrows (design QA pass 9)

    @Test("The warnings chip keeps its count when compact; the sentence stays in tooltip and label")
    func warningChipKeepsItsCount() {
        #expect(StatusBarDisplay.warningChipTitle(count: 3, badgeText: "3 warnings", compact: false) == "3 warnings")
        #expect(StatusBarDisplay.warningChipTitle(count: 3, badgeText: "3 warnings", compact: true) == "3")
        #expect(StatusBarDisplay.warningChipTitle(count: 12, badgeText: "12 warnings", compact: true).contains("12"))
    }

    @Test("The strip's arrangements tighten in order, and the tightest fits a narrow column untruncated")
    func stripVariantsTighten() throws {
        let environment = ProjectShellEnvironment.mock()
        let strip = StatusBarView(environment: environment)
        let snapshot = environment.status.snapshot
        #expect(StatusBarDisplay.hasDocument(snapshot))
        #expect(!environment.status.warnings.isEmpty, "the fixture carries warnings, so the chip is measured")
        var widths: [CGFloat] = []
        for variant in CanvasStripVariant.allCases {
            let host = NSHostingView(rootView: strip.stripRow(variant, snapshot: snapshot, hasDocument: true))
            widths.append(host.fittingSize.width)
        }
        #expect(widths == widths.sorted(by: >), "\(widths)")
        #expect(Set(widths).count == widths.count, "every step frees width: \(widths)")
        // The d9 capture's canvas column at 1672 pt was 1086 pt: some arrangement fits it whole.
        #expect(widths.contains { $0 <= 1_086 - 2 * ZPDFSpacing.m }, "\(widths)")
        // Coord goes before the right group compacts.
        #expect(CanvasStripVariant.noCoord.rawValue < CanvasStripVariant.compactRight.rawValue)
        #expect(CanvasStripVariant.allCases.filter(\.compactRight).allSatisfy { $0.coord == .hidden })
    }

    @Test("Snap toggles are spaced pills on the selected fill, not a comma list of accent buttons")
    func snapTogglesAreSpacedPills() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUIShell/StatusBar/StatusBarView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains("Text(verbatim: \",\")"))
        // The whole file now: the zoom control this used to cut off is gone (R-086).
        #expect(!text.contains(".toggleStyle(.button)"), "the strip's toggles use CanvasStripToggleStyle")
        #expect(text.contains("ZPDFColor.color(.selectedFill)"))
    }

    // MARK: - Token discipline

    @Test("The window chrome sources use design-system tokens only, never a raw colour")
    func noRawColoursInWindowChrome() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUIShell")
        let files = [
            "Shell/ZPDFWindowChrome.swift",
            "Shell/ZPDFPanelHostViewController.swift",
            "Layout/ProjectWindowLayoutController.swift",
            "Layout/CanvasPaneContainerViewController.swift",
            "Layout/ProjectTopBandView.swift",
            "Layout/ZPDFProjectWindow.swift",
            "StatusBar/StatusBarView.swift"
        ]
        let forbidden = ["NSColor(red", "NSColor(calibratedRed", "NSColor(srgbRed", "NSColor(white",
                         "Color(red", "Color(white", "#colorLiteral", "ZPDFRGBA(hex",
                         "NSColor.black", "NSColor.white", "Color.black", "Color.white",
                         "NSColor.windowBackgroundColor", "NSColor.controlBackgroundColor"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for literal in forbidden {
                #expect(!text.contains(literal), "\(file) uses a raw colour: \(literal)")
            }
        }
    }
}
