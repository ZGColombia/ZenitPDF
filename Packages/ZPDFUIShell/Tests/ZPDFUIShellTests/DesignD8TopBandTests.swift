import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// A configured project window at one width, laid out but never ordered on screen.
@MainActor
private func makeBandWindow(
    width: CGFloat,
    key: String,
    appearance: NSAppearance.Name = .darkAqua,
    defaults: ZPDFInMemoryDefaults = ZPDFInMemoryDefaults()
) -> (ProjectWindowLayoutController, ZPDFProjectWindow) {
    let layout = ProjectWindowLayoutController(
        environment: .mock(),
        store: ProjectWindowLayoutStore(defaults: defaults, key: key)
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
    window.appearance = NSAppearance(named: appearance)
    window.contentViewController = layout
    layout.configure(window: window)
    window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: false)
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window)
}

/// Design round d8, follow-up: the window draws its own top band.
@MainActor
@Suite("Design d8 — the top band", .shellTierSerialised)
struct DesignD8TopBandTests {

    // MARK: - Geometry

    @Test("One band 88 pt tall at the top of the window, under the window controls")
    func bandHeightAndPlace() throws {
        let (layout, window) = makeBandWindow(width: 1_672, key: "band.height")
        defer { window.close() }
        let band = try #require(layout.topBand)
        #expect(band.frame.minY == 0 && band.frame.height == ZPDFSpacing.Chrome.topBarHeight)
        #expect(band.frame.width == layout.view.bounds.width)
        #expect(window.toolbar?.isVisible == false, "no second, system toolbar under the band")
        // The content row starts one gutter under the band.
        #expect(abs(layout.outerSplitController.view.frame.minY - band.frame.maxY - ZPDFWindowChrome.gutter) < 0.5)
        // The brand clears the close, minimise and zoom buttons.
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        let zoomFrame = band.convert(zoom.bounds, from: zoom)
        let brand = try #require(band.brandView)
        #expect(brand.frame.minX > zoomFrame.maxX)
    }

    @Test("The tabs sit directly under the brand, at the foot of the band's left column")
    func tabsUnderBrand() throws {
        let (layout, window) = makeBandWindow(width: 1_672, key: "band.tabs")
        defer { window.close() }
        let band = try #require(layout.topBand)
        let brand = try #require(band.brandView)
        let tabs = band.tabsView
        #expect(tabs === layout.tabStripView)
        #expect(!brand.isHidden)
        #expect(brand.frame.maxY <= tabs.frame.minY, "brand \(brand.frame), tabs \(tabs.frame)")
        #expect(tabs.frame.maxY == band.bounds.height)
        #expect(tabs.frame.height == ProjectTopBandView.tabRowHeight)
        #expect(tabs.frame.minX == ZPDFWindowChrome.gutter)
        // The tabs stay in the left column: they never run under the tools.
        let firstTool = try #require(band.centreEntries.first?.view)
        #expect(tabs.frame.maxX < firstTool.frame.minX)
    }

    @Test("The tool group is centred on the window and on the band's full height")
    func toolsCentred() throws {
        let (layout, window) = makeBandWindow(width: 1_672, key: "band.centre")
        defer { window.close() }
        let band = try #require(layout.topBand)
        let views = band.centreEntries.map(\.view)
        let first = try #require(views.first), last = try #require(views.last)
        #expect(band.centreEntries.first?.identifier == .zenitSelect)
        #expect(band.centreEntries.last?.identifier == .zenitCutout)
        let groupMid = (first.frame.minX + last.frame.maxX) / 2
        #expect(abs(groupMid - band.bounds.midX) <= 1, "group centre \(groupMid), band centre \(band.bounds.midX)")
        for view in views where view.frame.height >= ZPDFSpacing.Chrome.toolButtonHeight {
            #expect(abs(view.frame.midY - band.bounds.midY) <= 1, "\(view.frame)")
            #expect(view.frame.height == ZPDFSpacing.Chrome.toolButtonHeight, "the chip ignores the titlebar safe area")
        }
        // Right group flush right, the author badge last.
        #expect(band.rightEntries.last?.identifier == .zenitAuthor)
        let author = try #require(band.rightEntries.last?.view)
        #expect(abs(author.frame.maxX - (band.bounds.width - ProjectTopBandView.edgeMargin)) <= 1)
        #expect(abs(author.frame.midY - band.bounds.midY) <= 1)
        #expect(band.moreView.isHidden)
        #expect(band.stage == .full)
    }

    @Test("Narrowing: the brand gives way first, then the right group, then the last tools")
    func collapseOrder() throws {
        var stages: [ProjectTopBandView.Stage] = []
        for width in stride(from: CGFloat(1_700), through: 1_040, by: -20) {
            let (layout, window) = makeBandWindow(width: width, key: "band.collapse")
            let band = try #require(layout.topBand)
            stages.append(band.stage)
            switch band.stage {
            case .full:
                #expect(band.brandView?.isHidden == false)
                #expect(band.moreView.isHidden)
            case .brandHidden:
                #expect(band.brandView?.isHidden == true)
                #expect(band.moreView.isHidden)
                #expect(band.rightEntries.allSatisfy { !$0.view.isHidden })
            case .rightCollapsed:
                #expect(band.brandView?.isHidden == true)
                #expect(!band.moreView.isHidden)
                #expect(band.rightEntries.filter { $0.identifier != .zenitAuthor }.allSatisfy { $0.view.isHidden })
                #expect(band.rightEntries.first { $0.identifier == .zenitAuthor }?.view.isHidden == false)
                #expect(band.overflowedCentreIdentifiers.isEmpty)
            case .toolsOverflowing:
                #expect(!band.moreView.isHidden)
                #expect(!band.overflowedCentreIdentifiers.isEmpty)
                // Only trailing tools move, and never the first-class measuring run.
                for identifier in [NSToolbarItem.Identifier.zenitSelect, .zenitCalibrate, .zenitLength, .zenitArea] {
                    #expect(!band.overflowedCentreIdentifiers.contains(identifier))
                }
            }
            // Nothing overlaps at any width.
            let visible = ([band.brandView, band.tabsView, band.moreView].compactMap { $0 }
                + band.centreEntries.map(\.view) + band.rightEntries.map(\.view)).filter { !$0.isHidden }
            for (index, a) in visible.enumerated() {
                for b in visible.dropFirst(index + 1) where a !== b {
                    #expect(!a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.frame), "width \(width): \(a.frame) × \(b.frame)")
                }
                #expect(a.frame.maxX <= band.bounds.width + 0.5)
            }
            window.close()
        }
        // The stages only ever tighten as the window narrows, and every one of them is reached.
        #expect(stages == stages.sorted())
        #expect(Set(stages) == [.full, .brandHidden, .rightCollapsed, .toolsOverflowing])
    }

    @Test("The More chip lists what did not fit: overflowed tools with their palettes, then the workspace commands")
    func moreMenuContents() throws {
        let (layout, window) = makeBandWindow(width: 1_040, key: "band.more")
        defer { window.close() }
        let band = try #require(layout.topBand)
        #expect(band.stage == .toolsOverflowing)
        var presented: NSMenu?
        band.presentMenu = { menu, _, _ in presented = menu }
        band.showOverflowMenu()
        let menu = try #require(presented)
        let titles = menu.items.map(\.title)
        for title in ["Tool Library", "Search", "Compare", "Export"] {
            #expect(titles.contains(title), "\(titles)")
        }
        let hasSeparator = menu.items.contains { $0.isSeparatorItem }
        #expect(hasSeparator)
        let overflowed = band.overflowedCentreIdentifiers
        #expect(overflowed.contains(.zenitCutout))
        // A palette tool keeps its list, as the toolbar's own overflow menu did (IM-140).
        if overflowed.contains(.zenitShapes) {
            let shapes = try #require(menu.items.first { $0.title == "Shapes" })
            #expect((shapes.submenu?.items.count ?? 0) > 0)
        }
        // Every enabled row runs something: no dead ends.
        for item in menu.items where !item.isSeparatorItem && item.submenu == nil {
            #expect(item.action != nil, "\(item.title) does nothing")
        }
    }

    // MARK: - The toolbar as the band's model

    @Test("The band follows the hidden toolbar's arrangement, as the customization sheet edits it")
    func followsToolbarArrangement() throws {
        let (layout, window) = makeBandWindow(width: 1_672, key: "band.arrangement")
        defer { window.close() }
        let band = try #require(layout.topBand)
        let toolbar = try #require(window.toolbar)
        #expect(band.identifiers == toolbar.items.map(\.itemIdentifier))
        // A removal is followed at once: the item is already gone when AppKit says so.
        let index = try #require(toolbar.items.firstIndex { $0.itemIdentifier == .zenitCutout })
        toolbar.removeItem(at: index)
        #expect(!band.centreEntries.contains { $0.identifier == .zenitCutout })
        // An insertion is followed live on a later turn, and without fail when the sheet ends —
        // the path every customization takes.
        var ran = false
        layout.runCustomizationPalette = { _ in ran = true }
        layout.runToolbarCustomization()
        #expect(ran)
        toolbar.insertItem(withItemIdentifier: .zenitCutout, at: index)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        #expect(band.centreEntries.contains { $0.identifier == .zenitCutout })
        #expect(band.identifiers == toolbar.items.map(\.itemIdentifier))
        #expect(toolbar.isVisible == false)
    }

    @Test("Customize Toolbar shows the toolbar for the sheet and hides it again when the sheet ends")
    func customizationShowsThenHides() throws {
        let (layout, window) = makeBandWindow(width: 1_672, key: "band.customize")
        defer { window.close() }
        var ran = false
        layout.runCustomizationPalette = { _ in ran = true }
        layout.environment.perform(.customizeToolbar)
        #expect(ran)
        #expect(window.toolbar?.isVisible == true)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        #expect(window.toolbar?.isVisible == false)
    }

    @Test("View ▸ Hide Toolbar collapses the band to its tab row, remembers it, and Show brings it back")
    func hideAndShowToolbar() throws {
        let defaults = ZPDFInMemoryDefaults()
        let (layout, window) = makeBandWindow(width: 1_672, key: "band.hide", defaults: defaults)
        defer { window.close() }
        let band = try #require(layout.topBand)
        let item = NSMenuItem(title: "", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "")
        #expect(window.validateMenuItem(item))
        #expect(item.title == "Hide Toolbar")

        window.toggleToolbarShown(item)
        layout.view.layoutSubtreeIfNeeded()
        #expect(!layout.isTopBandShown)
        #expect(band.frame.height == ProjectTopBandView.hiddenHeight)
        #expect(window.toolbar?.isVisible == false, "Hide Toolbar must not reveal the system toolbar")
        #expect(band.centreEntries.allSatisfy { $0.view.isHidden })
        #expect(!band.tabsView.isHidden)
        #expect(band.tabsView.frame.minX >= band.windowControlsInset(), "the tabs clear the window controls")
        #expect(window.validateMenuItem(item))
        #expect(item.title == "Show Toolbar")
        #expect(layout.layoutState.isTopBandHidden == true)

        window.toggleToolbarShown(item)
        layout.view.layoutSubtreeIfNeeded()
        #expect(layout.isTopBandShown)
        #expect(band.frame.height == ProjectTopBandView.height)
        #expect(layout.layoutState.isTopBandHidden == nil)
    }

    // MARK: - The drag area

    @Test("A double-click on the band's empty area does what the system titlebar setting says")
    func doubleClickFollowsSystemSetting() throws {
        #expect(ProjectTopBandView.doubleClickAction(reading: { _ in nil }) == .zoom)
        #expect(ProjectTopBandView.doubleClickAction(reading: { $0 == "AppleActionOnDoubleClick" ? "Maximize" : nil }) == .zoom)
        #expect(ProjectTopBandView.doubleClickAction(reading: { $0 == "AppleActionOnDoubleClick" ? "Minimize" : nil }) == .minimize)
        #expect(ProjectTopBandView.doubleClickAction(reading: { $0 == "AppleActionOnDoubleClick" ? "None" : nil }) == .none)
        #expect(ProjectTopBandView.doubleClickAction(reading: { $0 == "AppleMiniaturizeOnDoubleClick" ? true : nil }) == .minimize)

        let (layout, window) = makeBandWindow(width: 1_672, key: "band.doubleclick")
        defer { window.close() }
        let band = try #require(layout.topBand)
        var performed: [ProjectTopBandView.DoubleClickAction] = []
        band.readGlobalDefault = { $0 == "AppleActionOnDoubleClick" ? "Minimize" : nil }
        band.performWindowAction = { action, target in
            performed.append(action)
            #expect(target === window)
        }
        band.performTitlebarDoubleClick()
        #expect(performed == [.minimize])
    }

    @Test("A click in the titlebar strip reaches the band's controls, not the titlebar")
    func titlebarStripPassesClicksToTheBand() throws {
        let (layout, window) = makeBandWindow(width: 1_672, key: "band.hit")
        defer { window.close() }
        let band = try #require(layout.topBand)
        let select = try #require(band.centreEntries.first?.view)
        // A point on the Select chip inside the top 28 pt, where the titlebar lies.
        let point = NSPoint(x: select.frame.midX, y: select.frame.minY + 6)
        let theme = try #require(window.contentView?.superview)
        let hit = theme.hitTest(theme.convert(point, from: band))
        #expect(hit != nil && (hit === select || hit!.isDescendant(of: select)), "hit \(String(describing: hit))")
    }

    // MARK: - Accessibility and appearance

    @Test("The band is one named toolbar group; every chip is labelled")
    func accessibility() throws {
        let (layout, window) = makeBandWindow(width: 1_040, key: "band.ax")
        defer { window.close() }
        let band = try #require(layout.topBand)
        #expect(band.accessibilityRole() == .toolbar)
        #expect(band.accessibilityLabel() == "Toolbar")
        #expect(band.moreView.accessibilityLabel() == "More toolbar items")
        for entry in band.centreEntries where entry.identifier != .zenitToolSeparator {
            #expect(!(entry.view.accessibilityLabel() ?? "").isEmpty, "\(entry.identifier.rawValue) is unlabelled")
        }
        #expect(band.tabsView.accessibilityLabel() == "Open documents")
    }

    @Test("Light mode: the band repaints in the light ground and keeps its layout")
    func lightMode() throws {
        let (layout, window) = makeBandWindow(width: 1_672, key: "band.light", appearance: .aqua)
        defer { window.close() }
        let band = try #require(layout.topBand)
        band.needsDisplay = true
        band.displayIfNeeded()
        let painted = try #require(band.layer?.backgroundColor)
        let light = ZPDFColor.nsColor(ZPDFWindowChrome.groundToken, variant: .light).cgColor
        #expect(painted == light, "band painted \(painted), light ground \(light)")
        #expect(band.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        #expect(band.stage == .full)
        #expect(band.frame.height == ProjectTopBandView.height)
        // Dark paints the dark ground: the colour is the token's, not a fixed navy.
        window.appearance = NSAppearance(named: .darkAqua)
        band.needsDisplay = true
        band.displayIfNeeded()
        #expect(band.layer?.backgroundColor == ZPDFColor.nsColor(ZPDFWindowChrome.groundToken, variant: .dark).cgColor)
    }
}
