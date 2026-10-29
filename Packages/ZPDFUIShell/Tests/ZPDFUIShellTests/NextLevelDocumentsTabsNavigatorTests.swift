import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// A configured project window at one width, laid out but never ordered on screen.
@MainActor
private func makeWindow(width: CGFloat, key: String) -> (ProjectWindowLayoutController, ZPDFProjectWindow) {
    let layout = ProjectWindowLayoutController(
        environment: .mock(),
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
    window.contentViewController = layout
    layout.configure(window: window)
    window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: false)
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window)
}

/// Lets the band's queued height change run, then lays the window out again.
@MainActor
private func settle(_ layout: ProjectWindowLayoutController, _ window: NSWindow) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
}

/// LT3-03 and LT3-11 (2026-09-23): all open drawings must be visible in the list. Headless:
/// windows are built and laid out, never shown.
@MainActor
@Suite("Next level documents — every open drawing visible", .shellTierSerialised)
struct NextLevelDocumentsTabsNavigatorTests {

    /// The old plan (150 pt minimum) put the second of two documents in the › menu in the top
    /// band's 300 pt column: visible == [1], overflow == [0].
    @Test("Two documents in the 300 pt column: both tabs visible, no › menu, + inside")
    func twoDocumentsInColumn() {
        let strip = ProjectTopBandView.fullLeftColumn - ZPDFWindowChrome.gutter
        let plan = DocumentTabStripPlan.make(tabCount: 2, activeIndex: 0, available: strip)
        #expect(plan.visible == [0, 1])
        #expect(plan.overflow.isEmpty)
        #expect(plan.tabWidth >= DocumentTabMetrics.minimumWidth)
        #expect(DocumentTabMetrics.minimumWidth == 72)
    }

    @Test("1–12 documents at 1 040–1 728 pt windows: every tab visible and the + reachable")
    func everyTabVisibleAcrossWidths() throws {
        for width in stride(from: CGFloat(1_040), through: 1_728, by: 172) {
            let (layout, window) = makeWindow(width: width, key: "nl.tabs.\(Int(width))")
            defer { window.close() }
            let band = try #require(layout.topBand)
            for count in 1...12 {
                band.tabCount = count
                band.needsLayout = true
                band.layoutSubtreeIfNeeded()
                settle(layout, window)
                let available = band.tabsView.frame.width
                for active in [0, count - 1] {
                    let plan = DocumentTabStripPlan.make(tabCount: count, activeIndex: active, available: available)
                    #expect(plan.overflow.isEmpty, "\(count) tabs at a \(width) pt window: \(plan.overflow.count) in the › menu (strip \(available) pt)")
                    #expect(plan.visible.count == count)
                    #expect(plan.tabWidth >= DocumentTabMetrics.minimumWidth)
                    let used = DocumentTabMetrics.leadingInset
                        + CGFloat(count) * plan.tabWidth
                        + CGFloat(count - 1) * DocumentTabMetrics.spacing
                        + DocumentTabMetrics.spacing + DocumentTabMetrics.newTabWidth
                    #expect(used <= available + 0.5, "+ clipped: \(used) > \(available)")
                }
                // The strip is inside the band and the band's height follows the tab row.
                #expect(band.tabsView.frame.maxY <= band.bounds.height + 0.5)
                #expect(abs(band.frame.height - band.preferredHeight) < 0.5,
                        "\(count) tabs at \(width): band \(band.frame.height), wants \(band.preferredHeight)")
                if band.tabsWrapped {
                    // Its own row: under every tool, never overlapping one.
                    for entry in band.centreEntries where !entry.view.isHidden {
                        #expect(entry.view.frame.maxY <= band.tabsView.frame.minY + 0.5,
                                "\(count) at \(width): tool \(entry.view.frame), tabs \(band.tabsView.frame), band \(band.frame)")
                    }
                    #expect(band.preferredHeight == ProjectTopBandView.height + ProjectTopBandView.tabRowHeight)
                }
            }
        }
    }

    @Test("Few documents keep the mockup's band: tabs in the left column, 88 pt, no extra row")
    func fewDocumentsKeepLayout() throws {
        let (layout, window) = makeWindow(width: 1_672, key: "nl.tabs.few")
        defer { window.close() }
        let band = try #require(layout.topBand)
        #expect(band.tabCount == 2, "the band follows the tab model (mock: two drawings)")
        #expect(!band.tabsWrapped)
        #expect(band.frame.height == ProjectTopBandView.height)
        // Back to two after many: the extra row goes again.
        band.tabCount = 9
        band.needsLayout = true
        band.layoutSubtreeIfNeeded()
        settle(layout, window)
        #expect(band.tabsWrapped)
        #expect(band.frame.height == ProjectTopBandView.height + ProjectTopBandView.tabRowHeight)
        band.tabCount = 2
        band.needsLayout = true
        band.layoutSubtreeIfNeeded()
        settle(layout, window)
        #expect(!band.tabsWrapped)
        #expect(band.frame.height == ProjectTopBandView.height)
    }

    // MARK: - Navigator (LT3-11)

    private func tabs(_ count: Int) -> [DocumentTabSummary] {
        (0..<count).map {
            DocumentTabSummary(id: UUID(), title: "Drawing \($0 + 1)", fileName: "D\($0 + 1).pdf", pageCount: $0 + 1)
        }
    }

    /// Before: the Pages list showed only the front drawing's header and cards; the other open
    /// drawings were reachable only through the file header's ⋯ menu.
    @Test("N open drawings give N visible sections in Pages, the front one expanded")
    func sectionsPerDrawing() {
        for count in 1...12 {
            let open = tabs(count)
            let active = open[count / 2].id
            let sections = NavigatorDrawingSection.sections(tabs: open, activeID: active, collapsed: [])
            #expect(sections.map(\.id) == open.map(\.id), "every drawing once, in tab order")
            #expect(sections.filter(\.isExpanded).map(\.id) == [active])
            #expect(sections.filter(\.isActive).count == 1)
        }
    }

    @Test("A header click switches to a back drawing and folds the front one")
    func headerClicks() {
        let open = tabs(3)
        let sections = NavigatorDrawingSection.sections(tabs: open, activeID: open[0].id, collapsed: [open[0].id])
        #expect(sections[0].isExpanded == false, "the person folded the front drawing")
        #expect(sections[0].headerClick == .toggle(open[0].id))
        #expect(sections[1].headerClick == .switchTo(open[1].id))
        #expect(sections[2].accessibilityValue == "Collapsed")
        let duplicated = NavigatorDrawingSection.sections(tabs: open + [open[1]], activeID: nil, collapsed: [])
        #expect(duplicated.count == 3)
    }

    @Test("The mock window's Navigator lists both open drawings")
    func mockEnvironmentListsBoth() {
        let environment = ProjectShellEnvironment.mock()
        let sections = NavigatorDrawingSection.sections(
            tabs: environment.document.tabs,
            activeID: environment.document.activeTabID,
            collapsed: []
        )
        #expect(sections.count == environment.document.tabs.count)
        #expect(sections.count == 2)
        #expect(environment.tabBar.items.count == 2)
    }

    @Test("The Pages list builds with every drawing section, off screen")
    func pagesListBuilds() {
        let environment = ProjectShellEnvironment.mock()
        let host = NSHostingView(rootView: NavigatorPagesList(environment: environment)
            .frame(width: 262, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 262, height: 700)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    // MARK: NL-DOCS-14 — drag to reorder

    @Test("A tab dropped on another takes its place; a stray payload is refused")
    func dragReorder() {
        let open = tabs(3)
        let model = DocumentTabBarModel(input: DocumentTabBarInput(tabs: open, activeTabID: open[0].id, revisions: []))
        var moves: [(UUID, Int)] = []
        model.onMoveTab = { moves.append(($0, $1)) }
        model.moveTab(open[2].id, onto: open[0].id)
        model.moveTab(open[1].id, onto: open[1].id)
        #expect(moves.count == 1 && moves[0].0 == open[2].id && moves[0].1 == 0)
        #expect(DocumentTabBarModel.draggedTab(in: DocumentTabBarModel.dragPayload(for: open[1].id)) == open[1].id)
        #expect(DocumentTabBarModel.draggedTab(in: "zenit-page:\(open[1].id)") == nil)
    }
}
