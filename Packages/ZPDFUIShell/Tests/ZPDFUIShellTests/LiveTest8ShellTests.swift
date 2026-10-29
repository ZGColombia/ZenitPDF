import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZPDFUIShell

/// A configured project window, laid out but never ordered on screen, with the launch layout
/// settled so pane commands persist and restore as they do in the app.
@MainActor
private func makeLiveTest8Window(
    width: CGFloat = 1_440,
    key: String,
    environment: ProjectShellEnvironment = .mock()
) -> (ProjectWindowLayoutController, ZPDFProjectWindow) {
    let layout = ProjectWindowLayoutController(
        environment: environment,
        store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key)
    )
    layout.presentDetachedLedgerWindow = { _ in }
    layout.detachedLedgerAutosaveName = ""
    layout.runCustomizationPalette = { _ in }
    let window = ZPDFProjectWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentViewController = layout
    layout.configure(window: window)
    window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: false)
    settle(window, layout)
    return (layout, window)
}

/// Lets queued layout passes and pane slides finish, as the seconds between two menu choices do.
@MainActor
private func settle(_ window: NSWindow, _ layout: ProjectWindowLayoutController, seconds: Double = 0.45) {
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
}

/// A drawing's search presenter for the hand-off test: a query answers after a short delay, as
/// the app's index does, with the results it was given for that query.
@MainActor
@Observable
final class HandoffSearchPresenter: SearchPresenting {
    var query: String = "" { didSet { if query != oldValue { runSearch() } } }
    var scope: SearchScope = .default
    var searchesAllDrawings = false
    private(set) var hits: [SearchHit] = []
    private(set) var activeHitID: SearchHit.ID?
    private(set) var isSearching = false
    var resultSummary: String { "\(hits.count) results" }
    var showsOCRDisclaimer: Bool { false }
    /// What each query finds, in this drawing's own numbering.
    var answers: [String: [SearchHit]] = [:]
    private(set) var runs = 0
    private(set) var selected: [SearchHit.ID] = []

    func runSearch() {
        runs += 1
        isSearching = true
        let found = answers[query] ?? []
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            self.hits = found
            self.isSearching = false
        }
    }
    func selectHit(id: SearchHit.ID) {
        activeHitID = id
        selected.append(id)
    }
    func advance(by delta: Int) {}
    func clear() { query = ""; hits = [] }
}

@Suite("Live test 8 — shell", .shellTierSerialised)
@MainActor
struct LiveTest8ShellTests {

    // MARK: - L-80

    @Test("L-80: after hiding and showing the three panes, the Navigator and Inspector are back at their widths and not pinned there")
    func panesComeBackUnpinned() throws {
        let (layout, window) = makeLiveTest8Window(key: "l8.navigator.width")
        defer { window.close() }
        let split = try #require(layout.contentSplitController).splitView
        let navigator = layout.contentSplitController.splitViewItems[0]
        let inspector = layout.contentSplitController.splitViewItems[2]
        #expect(navigator.viewController.view.frame.width == 270)
        #expect(inspector.viewController.view.frame.width == 300)
        // The live sequence: View ▸ Hide Navigator, Hide Inspector, Hide Quantity Ledger, then
        // Show for each, with time between the choices.
        for command in [ZPDFCommandID.toggleNavigator, .toggleInspector, .toggleQuantityLedger,
                        .toggleNavigator, .toggleInspector, .toggleQuantityLedger] {
            layout.environment.perform(command)
            settle(window, layout)
        }
        #expect(!navigator.isCollapsed && !inspector.isCollapsed && layout.isBottomPaneVisible)
        #expect(navigator.viewController.view.frame.width == 270)
        #expect(inspector.viewController.view.frame.width == 300)
        // Nothing holds the panes at a width: the dividers still go where they are put. Old
        // code: the hide had slid each pane out under a constant-breadth pin (priority 999.99)
        // that outlived the slide, so the Navigator stayed 270 pt and the Inspector 300 pt
        // here — and in the app, where the pin kept a mid-slide width, about 120 pt.
        split.setPosition(220, ofDividerAt: 0)
        split.setPosition(split.bounds.width - 340 - split.dividerThickness, ofDividerAt: 1)
        layout.view.layoutSubtreeIfNeeded()
        #expect(navigator.viewController.view.frame.width == 220)
        #expect(inspector.viewController.view.frame.width == 340)
    }

    // MARK: - L-82

    @Test("L-82: while Customize Toolbar has the toolbar up the band draws no tools, and the end of the sheet hides the toolbar for good")
    func customizationDrawsTheToolsOnce() throws {
        let (layout, window) = makeLiveTest8Window(key: "l8.customize")
        defer { window.close() }
        let band = try #require(layout.topBand)
        let toolbar = try #require(window.toolbar)
        var running = false
        layout.runCustomizationPalette = { _ in running = true }
        layout.customizationPaletteIsRunning = { _ in running }
        #expect(band.drawsTools)
        layout.environment.perform(.customizeToolbar)
        band.layoutSubtreeIfNeeded()
        #expect(toolbar.isVisible)
        // Old code: the band's brand and every tool chip stayed on screen under the toolbar the
        // sheet had put up — each tool drawn twice, one copy in the titlebar.
        #expect(!band.drawsTools)
        #expect(band.brandView?.isHidden ?? true)
        #expect(band.centreEntries.allSatisfy { $0.view.isHidden })
        #expect(band.rightEntries.allSatisfy { $0.view.isHidden })
        // The tabs stay: the sheet edits tools, not documents.
        #expect(!band.tabsView.isHidden)
        // The sheet's display-mode menu cannot offer a mode the chips do not draw.
        if #available(macOS 15.0, *) {
            #expect(toolbar.allowsDisplayModeCustomization == false)
        }
        #expect(toolbar.displayMode == .iconOnly)

        // Done, with no sheet-ended notification at all (old code waited for that one alone and
        // left the toolbar up "until another tab is selected"): the window's next update finds
        // the palette gone.
        running = false
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(!toolbar.isVisible)
        #expect(!layout.isCustomizingToolbar)
        band.layoutSubtreeIfNeeded()
        #expect(band.drawsTools)
        #expect(band.centreEntries.contains { !$0.view.isHidden })

        // AppKit putting the toolbar back up while it finishes the customization: hidden again
        // on the next turn.
        toolbar.isVisible = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!toolbar.isVisible)
    }

    @Test("L-82: a window update before the sheet is up is not taken for its end")
    func customizationIgnoresAnUpdateBeforeTheSheet() throws {
        let (layout, window) = makeLiveTest8Window(key: "l8.customize.early")
        defer { window.close() }
        let toolbar = try #require(window.toolbar)
        var running = false
        layout.runCustomizationPalette = { _ in }
        layout.customizationPaletteIsRunning = { _ in running }
        layout.environment.perform(.customizeToolbar)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(toolbar.isVisible, "the sheet has not been seen yet; an update is not its end")
        running = true
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(toolbar.isVisible)
        running = false
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        #expect(!toolbar.isVisible)
    }

    // MARK: - L-61, L-89

    /// The Tool Library as the app hosts it: the sample library, the default set.
    private static func toolLibrary() -> ToolLibraryPanelView<MockToolLibraryPresenter> {
        let presenter = MockToolLibraryPresenter()
        return ToolLibraryPanelView(
            presenter: presenter,
            model: ToolLibraryEditingModel(presets: presenter.presets),
            onClose: {}
        )
    }

    @Test("L-61: the floating Tool Library's content fits the panel's 380 pt, so the panel does not grow past its placement")
    func toolLibraryFitsTheFloatingPanel() throws {
        let host = NSHostingController(rootView: Self.toolLibrary())
        // Old code: the sets sat beside the tools at every width, so SwiftUI asked for at least
        // 168 + 1 + 280 = 449 pt, the hosting controller widened the 380 pt panel to that, and
        // the panel — placed against the window's right edge for 380 pt — ran off the screen.
        let fitting = host.sizeThatFits(in: NSSize(width: 380, height: 560))
        #expect(fitting.width <= 380, "the Tool Library asks for \(fitting.width) pt at the panel's 380 pt")
        let inspector = host.sizeThatFits(in: NSSize(width: 300, height: 700))
        #expect(inspector.width <= 300, "the Tool Library asks for \(inspector.width) pt in the Inspector's 300 pt")
    }

    @Test("L-89: below the side-by-side width the sets stack above the tools; the old sheet's 720 pt keeps them beside")
    func toolLibraryStacksWhenNarrow() {
        #expect(ToolLibraryPanelLayout.usesStackedLayout(width: 300), "the Inspector's Tools tab")
        #expect(ToolLibraryPanelLayout.usesStackedLayout(width: 380), "the floating panel's default width")
        #expect(!ToolLibraryPanelLayout.usesStackedLayout(width: 720), "the 720 pt sheet")
        // The side-by-side layout needs the 168 pt sidebar plus a tool area its header fits in.
        #expect(ToolLibraryPanelLayout.stackedLayoutWidth >= 168 + 1 + 280)
    }

    @Test("L-61, L-89: a squeezed panel header keeps its title and count on one line")
    func panelHeaderNeverWrapsPerLetter() {
        func header(width: CGFloat) -> CGFloat {
            let view = ZPDFPanelHeader(title: "My Tools", count: 14) {
                HStack(spacing: ZPDFSpacing.xs) {
                    ForEach(0..<6, id: \.self) { _ in
                        Color.clear.frame(width: 28, height: 24)
                    }
                }
            }
            return NSHostingView(rootView: view.frame(width: width)).fittingSize.height
        }
        let roomy = header(width: 600)
        // Old code: at 240 pt the title wrapped "MY / TOO / LS" and the badge "1 / 4" — a header
        // several lines tall.
        #expect(header(width: 240) == roomy, "squeezed \(header(width: 240)) pt against \(roomy) pt with room")
        #expect(header(width: 200) == roomy)
    }

    // MARK: - L-90

    @Test("L-90: with nothing selected each Inspector tab says something of its own")
    func inspectorEmptyStatesDiffer() {
        let markup = InspectorPanel.emptyState(for: .markup)
        let properties = InspectorPanel.emptyState(for: .properties)
        let comments = InspectorPanel.emptyState(for: .comments)
        // Old code: all three read "Nothing selected" over one message.
        #expect(Set([markup.title, properties.title, comments.title]).count == 3)
        #expect(Set([markup.message, properties.message, comments.message]).count == 3)
        #expect(Set([markup.symbol, properties.symbol, comments.symbol]).count == 3)
        #expect(markup.title == "Nothing selected")
    }

    @Test("L-90: the Inspector's page is the panel state's, so the tab a click chose is the one drawn")
    func inspectorTabLivesInPanelState() {
        let state = ShellPanelState()
        #expect(state.inspectorTab == .markup)
        _ = InspectorPanel(environment: .mock(), panelState: state, initialTab: .comments)
        #expect(state.inspectorTab == .comments)
        state.inspectorTab = .properties
        #expect(state.inspectorTab == .properties)
    }

    // MARK: - L-94

    @Test("L-94: Panels ▸ Show Project Zones with the Zones page up leaves it up; the lit chip is the way back")
    func showProjectZonesShows() throws {
        let (layout, window) = makeLiveTest8Window(key: "l8.zones")
        defer { window.close() }
        layout.environment.perform(.projectZones)
        #expect(layout.isVisible(.navigator))
        #expect(layout.panelState.navigatorSection == .zones)
        layout.environment.perform(.projectZones)
        // Old code: the second "Show Project Zones" hid the whole Navigator.
        #expect(layout.isVisible(.navigator))
        #expect(layout.panelState.navigatorSection == .zones)
        #expect(layout.environment.isPanelOpen(.projectZones))
        layout.environment.toolbar.run(.projectZones)
        #expect(!layout.isVisible(.navigator))
        // Closed the way View ▸ Hide Navigator closes it: the stored flag moved with the pane
        // (the chip's bare collapse used to leave the store saying "open").
        #expect(layout.layoutState.isNavigatorCollapsed)
    }

    // MARK: - L-100

    @Test("L-100: a palette's list hangs under its chip, with the palette's rows, and arms nothing")
    func paletteListHangsUnderItsChip() throws {
        let (layout, window) = makeLiveTest8Window(key: "l8.palette")
        defer { window.close() }
        let band = try #require(layout.topBand)
        var presented: [(titles: [String], view: NSView)] = []
        band.presentMenu = { menu, _, view in presented.append((menu.items.map(\.title), view)) }
        let before = layout.environment.toolbar.activeSelection
        for palette in [ZenitToolChip.Palette.shapes, .measure, .count] {
            presented = []
            layout.environment.openToolbarPalette(palette)
            #expect(presented.count == 1, "\(palette) opened \(presented.count) menus")
            let chip = band.centreEntries.first { $0.identifier == ProjectTopBandView.identifier(for: palette) }?.view
            #expect(presented.first?.view === chip, "\(palette)'s list hangs under its own chip")
        }
        layout.environment.openToolbarPalette(.shapes)
        #expect(presented.last?.titles.contains("Rectangle") == true)
        #expect(presented.last?.titles.contains("Cloud") == true)
        #expect(layout.environment.toolbar.activeSelection == before, "opening a list arms nothing")
    }

    @Test("L-100: a press held past the delay opens the list once and swallows its click; a quick press does neither")
    func paletteHoldOpensOnceAndSwallowsTheClick() {
        let hold = ZenitPaletteHold()
        var opened = 0
        hold.arm(after: 0.05) { opened += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hold.disarm()
        #expect(opened == 1)
        #expect(hold.takeFired(), "the click that ends the held press is not a click")
        #expect(!hold.takeFired(), "only that one")
        hold.arm(after: 0.2) { opened += 1 }
        hold.disarm()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(opened == 1, "a quick press opens nothing")
        #expect(!hold.takeFired())
    }

    // MARK: - L-91

    @Test("L-91: opening a hit in another drawing takes the search along, with that hit active")
    func searchFollowsTheOpenedHit() async throws {
        let drawingA = UUID(), drawingB = UUID(), pageB = UUID()
        func hit(_ id: UUID, in document: UUID, from source: UUID?) -> SearchHit {
            SearchHit(
                id: id, documentID: document, documentTitle: "Plan", pageID: pageB, pageIndex: 0,
                pageLabel: "1", source: .pdfText, snippet: "… GODKÄND …", highlightRange: 2..<8,
                sourceDocumentID: source, sourceDocumentTitle: source == nil ? nil : "Plan-A2"
            )
        }
        // In Plan-A's All Drawings list, the hit Plan-A2 answered.
        let foreign = hit(UUID(), in: drawingA, from: drawingB)
        let origin = HandoffSearchPresenter()
        origin.searchesAllDrawings = true
        var scope = SearchScope.default
        scope.isWholeWord = true
        origin.scope = scope
        origin.query = "GODK"
        // Plan-A2's own presenter numbers the same find differently, and lists one more.
        let local = hit(UUID(), in: drawingB, from: nil)
        let other = SearchHit(
            id: UUID(), documentID: drawingB, documentTitle: "Plan", pageID: UUID(), pageIndex: 1,
            pageLabel: "2", source: .pdfText, snippet: "GODKÄNT", highlightRange: 0..<4
        )
        let destination = HandoffSearchPresenter()
        destination.answers["GODK"] = [other, local]

        let task = try #require(ZPDFSearchHandoff.continueSearch(from: origin, into: destination, at: foreign))
        // Old code handed nothing over: Plan-A2's Search page stayed empty, on This Drawing.
        #expect(destination.query == "GODK")
        #expect(destination.searchesAllDrawings)
        #expect(destination.scope == scope)
        #expect(await task.value)
        #expect(destination.hits.count == 2)
        #expect(destination.activeHitID == local.id, "the hit that opened the drawing is the active one, so ▲ ▼ go on from it")
        #expect(destination.runs == 1, "one search, with the reach and scope already set")
    }

    @Test("L-91: nothing to hand over without a query, or into the same presenter")
    func searchHandoffNeedsTwoPresentersAndAQuery() {
        let presenter = HandoffSearchPresenter()
        presenter.query = "GODK"
        let hit = SearchHit(
            id: UUID(), documentID: UUID(), documentTitle: "Plan", pageID: UUID(), pageIndex: 0,
            pageLabel: "1", source: .pdfText, snippet: "GODK"
        )
        #expect(ZPDFSearchHandoff.continueSearch(from: presenter, into: presenter, at: hit) == nil)
        let empty = HandoffSearchPresenter()
        let destination = HandoffSearchPresenter()
        #expect(ZPDFSearchHandoff.continueSearch(from: empty, into: destination, at: hit) == nil)
        #expect(destination.runs == 0)
    }
}
