import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Design round d3 (2026-09-23 main-window mockup): the document tabs and the canvas top bar.
///
/// Pins the structure the mockup fixes — control order and grouping, what each control runs,
/// their names — the behaviour behind each control, and that every colour the two surfaces draw
/// is a design-system token. Nothing here puts a window on screen: the render checks draw an
/// `NSHostingView` that is never added to a window.
@MainActor
@Suite("Design d3 — canvas top bar", .shellTierSerialised)
struct DesignD3CanvasBarTests {

    // MARK: Structure

    @Test("The bar's controls run in the mockup's order, in five groups")
    func controlOrder() {
        #expect(CanvasTopBarControl.allCases == [
            .previousPage, .pageField, .nextPage,
            .zoomOut, .zoomField, .zoomIn,
            .toggleNavigator, .fitPage,
            .undo, .redo,
            .searchField, .searchOptions
        ])
        #expect(CanvasTopBarControl.groups.flatMap { $0 } == CanvasTopBarControl.allCases)
        #expect(CanvasTopBarControl.groups.count == 5)
    }

    @Test("Every button runs a real command from the command table — no dead ends")
    func everyButtonIsWired() throws {
        let table = ZPDFCommandTable.standard
        let buttons = CanvasTopBarControl.allCases.filter { $0.command != nil }
        #expect(buttons == [.previousPage, .nextPage, .zoomOut, .zoomIn, .toggleNavigator, .fitPage, .undo, .redo])
        for control in buttons {
            let command = try #require(control.command)
            #expect(table.command(command) != nil, "\(control) runs \(command), which the table must know")
            #expect(control.symbol != nil, "\(control) is a glyph button and needs a glyph")
        }
        #expect(CanvasTopBarControl.previousPage.command == .previousPage)
        #expect(CanvasTopBarControl.nextPage.command == .nextPage)
        #expect(CanvasTopBarControl.zoomOut.command == .zoomOut)
        #expect(CanvasTopBarControl.zoomIn.command == .zoomIn)
        #expect(CanvasTopBarControl.toggleNavigator.command == .toggleNavigator)
        #expect(CanvasTopBarControl.fitPage.command == .fitPage)
        #expect(CanvasTopBarControl.undo.command == .undo)
        #expect(CanvasTopBarControl.redo.command == .redo)
    }

    @Test("Every control has an English accessibility name, all distinct")
    func accessibilityNames() {
        let titles = CanvasTopBarControl.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(Set(titles).count == titles.count)
        #expect(CanvasTopBarControl.searchField.title == "Search in document")
        #expect(CanvasTopBarControl.previousPage.title == "Previous Page")
        #expect(CanvasTopBarControl.fitPage.title == "Fit Page")
        #expect(CanvasSearchField.placeholder == "Search in document") // d10: the catalogued key has no ellipsis
    }

    // MARK: Behaviour

    @Test("The page arrows turn the page and the status snapshot follows")
    func pageArrows() {
        let environment = ProjectShellEnvironment.mock()
        environment.document.goToPage(index: 0)
        #expect(!environment.document.canGoToPreviousPage)
        CanvasTopBarActions.press(.nextPage, environment: environment)
        #expect(environment.document.currentPageIndex == 1)
        #expect(environment.status.snapshot.pageIndex == 1)
        CanvasTopBarActions.press(.previousPage, environment: environment)
        #expect(environment.document.currentPageIndex == 0)
    }

    @Test("A typed page goes by printed label first, position second; rubbish goes nowhere")
    func typedPage() throws {
        let environment = ProjectShellEnvironment.mock()
        let pages = environment.document.pages
        try #require(pages.count >= 2)
        #expect(CanvasTopBarActions.commitPage("2", environment: environment) || pages[1].label != "2")
        #expect(CanvasTopBarActions.commitPage(pages[1].label, environment: environment))
        #expect(environment.document.currentPageIndex == 1)
        #expect(!CanvasTopBarActions.commitPage("no such sheet", environment: environment))
        #expect(environment.document.currentPageIndex == 1)
    }

    @Test("Zoom steps and the typed zoom reach the canvas; unusable text changes nothing")
    func zoom() {
        let environment = ProjectShellEnvironment.mock()
        environment.canvas.setZoom(1.0)
        CanvasTopBarActions.press(.zoomIn, environment: environment)
        #expect(abs(environment.canvas.viewport.zoom - 1.25) < 1e-9)
        CanvasTopBarActions.press(.zoomOut, environment: environment)
        #expect(abs(environment.canvas.viewport.zoom - 1.0) < 1e-9)
        #expect(CanvasTopBarActions.commitZoom("150%", environment: environment))
        #expect(abs(environment.canvas.viewport.zoom - 1.5) < 1e-9)
        #expect(!CanvasTopBarActions.commitZoom("lots", environment: environment))
        #expect(!CanvasTopBarActions.commitZoom("1,000", environment: environment), "ambiguous grouping is refused")
        #expect(abs(environment.canvas.viewport.zoom - 1.5) < 1e-9)
        CanvasTopBarActions.press(.fitPage, environment: environment)
        #expect(abs(environment.canvas.viewport.zoom - 1.0) < 1e-9)
    }

    @Test("Undo and Redo are handed to the app tier, which owns the undo manager")
    func undoRedoForwarded() {
        let environment = ProjectShellEnvironment.mock()
        var received: [ZPDFCommandID] = []
        environment.externalCommandHandler = { received.append($0) }
        CanvasTopBarActions.press(.undo, environment: environment)
        CanvasTopBarActions.press(.redo, environment: environment)
        #expect(received == [.undo, .redo])
    }

    @Test("Undo state: unknown stays enabled, a known empty stack dims, the help names the action")
    func undoState() {
        let state = CanvasUndoState()
        #expect(state.isUndoEnabled && state.isRedoEnabled, "unknown is not claimed as empty")
        state.canUndo = true
        state.canRedo = false
        #expect(state.isUndoEnabled)
        #expect(!state.isRedoEnabled)
        state.undoActionName = "Move Markup"
        let binding = ZPDFCommandTable.standard.command(.undo)?.binding
        let help = state.undoHelp(binding: binding)
        #expect(help.hasPrefix("Undo Move Markup"))
        if let binding { #expect(help.contains(binding.displayString)) }
        #expect(state.redoHelp(binding: nil) == "Redo")
    }

    @Test("Return in the search field: run a new query, step through the hits of the same one")
    func searchSubmitDecision() {
        #expect(CanvasTopBarDisplay.searchSubmit(query: "  ", lastRunQuery: nil, hitCount: 0) == .none)
        #expect(CanvasTopBarDisplay.searchSubmit(query: "screed", lastRunQuery: nil, hitCount: 0) == .run)
        #expect(CanvasTopBarDisplay.searchSubmit(query: "screed", lastRunQuery: "screed", hitCount: 3) == .advance)
        #expect(CanvasTopBarDisplay.searchSubmit(query: "screed", lastRunQuery: "screed", hitCount: 0) == .run)
        #expect(CanvasTopBarDisplay.searchSubmit(query: "wall", lastRunQuery: "screed", hitCount: 3) == .run)
    }

    @Test("Submitting runs the shared search presenter, then Return again reveals the next hit")
    func searchSubmitDrivesThePresenter() throws {
        let environment = ProjectShellEnvironment.mock()
        let last = CanvasTopBarActions.submitSearch(query: " screed ", lastRunQuery: nil, environment: environment)
        #expect(last == "screed")
        #expect(environment.search.query == "screed")
        try #require(environment.search.hits.count >= 2, "the sample set has several screed hits")
        let first = environment.search.activeHitID
        let again = CanvasTopBarActions.submitSearch(query: "screed", lastRunQuery: last, environment: environment)
        #expect(again == last)
        #expect(environment.search.activeHitID != first, "the second Return steps to the next hit")
    }

    @Test("Search options toggle a source but never the last one")
    func searchScopeToggle() {
        var scope = SearchScope(sources: [.pdfText, .markups])
        scope = SearchScopeEditing.scope(scope, togglingSource: .markups)
        #expect(scope.sources == [.pdfText])
        #expect(SearchScopeEditing.scope(scope, togglingSource: .pdfText).sources == [.pdfText])
        #expect(SearchScopeEditing.scope(scope, togglingSource: .comments).sources == [.pdfText, .comments])
    }

    // MARK: Text

    @Test("The page readout reads `/ 6`, and adds the position when the sheet label differs")
    func pageText() {
        #expect(CanvasTopBarDisplay.pageTrailingText(pageLabel: "1", pageIndex: 0, pageCount: 6) == "/ 6")
        #expect(CanvasTopBarDisplay.pageTrailingText(pageLabel: "A-101", pageIndex: 2, pageCount: 23) == "· 3 / 23")
        #expect(CanvasTopBarDisplay.pageAccessibilityValue(pageLabel: "1", pageIndex: 0, pageCount: 6) == "Page 1 of 6")
        #expect(CanvasTopBarDisplay.pageAccessibilityValue(pageLabel: "A-101", pageIndex: 2, pageCount: 23)
            == "Page A-101, 3 of 23")
    }

    @Test("The search field shows where you are among the hits, and nothing without hits")
    func searchPosition() {
        #expect(CanvasTopBarDisplay.searchPositionText(position: nil, count: 0) == nil)
        #expect(CanvasTopBarDisplay.searchPositionText(position: nil, count: 12) == "12")
        #expect(CanvasTopBarDisplay.searchPositionText(position: 3, count: 12) == "3/12")
    }

    @Test("The Navigator toggle says its state and what a click does")
    func navigatorToggleWords() {
        #expect(CanvasTopBarDisplay.navigatorValue(isVisible: true) == "Open")
        #expect(CanvasTopBarDisplay.navigatorValue(isVisible: false) == "Closed")
        #expect(CanvasTopBarDisplay.navigatorHelp(isVisible: true, binding: nil) == "Hide the Navigator")
        #expect(CanvasTopBarDisplay.navigatorHelp(isVisible: false, binding: nil) == "Show the Navigator")
    }

    // MARK: Look

    @Test("Hover and press draw the design system's state washes; disabled and rest draw none")
    func buttonStates() {
        #expect(CanvasBarButtonStyle.overlay(isEnabled: true, isHovering: false, isPressed: false) == nil)
        #expect(CanvasBarButtonStyle.overlay(isEnabled: true, isHovering: true, isPressed: false) == .stateHover)
        #expect(CanvasBarButtonStyle.overlay(isEnabled: true, isHovering: true, isPressed: true) == .statePressed)
        #expect(CanvasBarButtonStyle.overlay(isEnabled: false, isHovering: true, isPressed: true) == nil)
    }

    @Test("The bar's palette is the mockup's: controls flat on the ground, inset fields, tertiary disabled glyphs")
    func palette() {
        #expect(CanvasBarPalette.field == .elevated)
        // W-047: the bar's search field is the design system's, painted from its paint table.
        #expect(ZPDFSearchField.paint(isFocused: false, isHovering: false, isEnabled: true).fill == .inset)
        #expect(ZPDFSearchField.paint(isFocused: false, isHovering: false, isEnabled: true).stroke == .borderStrong)
        #expect(ZPDFSearchField.paint(isFocused: true, isHovering: false, isEnabled: true).stroke == .accentBlue)
        #expect(CanvasBarPalette.glyphDisabled == .textTertiary)
        #expect(CanvasBarPalette.separator == .border)
        #expect(CanvasBarPalette.glyph != CanvasBarPalette.glyphDisabled, "a disabled glyph must look disabled")
        #expect(CanvasTopBar.height == ZPDFSpacing.Chrome.canvasBarHeight)
    }

    @Test("Spec geometry: 28 pt hits, ~15 pt glyphs, 22 pt dividers, the mockup's button pitch, sliders for options")
    func geometry() {
        #expect(CanvasBarIconButton.side == 28)
        #expect(CanvasBarMetrics.glyph * 0.82 >= 14, "glyphs draw at the mockup's size, not 12 pt")
        #expect(CanvasBarMetrics.separatorHeight == 22)
        #expect(CanvasBarIconButton.side + CanvasBarMetrics.viewPairSpacing >= 44, "sidebar → fit pitch ~49")
        #expect(CanvasBarIconButton.side + CanvasBarMetrics.historyPairSpacing >= 36, "undo → redo pitch ~39")
        #expect(CanvasBarGroupBackground.height == ZPDFSpacing.Chrome.barControlHeight)
        #expect(CanvasTopBarControl.searchOptions.symbol == .sliders)
    }

    @Test("A narrow column sheds search, then history, then the view toggles — never page or zoom")
    func densities() {
        #expect(CanvasTopBarDensity.allCases == [.full, .withoutSearch, .withoutHistory, .navigationOnly])
        #expect(CanvasTopBarControl.allCases.allSatisfy { CanvasTopBarDensity.full.shows($0) })
        let essential: [CanvasTopBarControl] = [.previousPage, .pageField, .nextPage, .zoomOut, .zoomField, .zoomIn]
        for density in CanvasTopBarDensity.allCases {
            #expect(essential.allSatisfy { density.shows($0) }, "\(density) keeps page and zoom")
        }
        #expect(!CanvasTopBarDensity.withoutSearch.shows(.searchField))
        #expect(CanvasTopBarDensity.withoutSearch.shows(.undo))
        #expect(!CanvasTopBarDensity.withoutHistory.shows(.redo))
        #expect(CanvasTopBarDensity.withoutHistory.shows(.fitPage))
        #expect(!CanvasTopBarDensity.navigationOnly.shows(.toggleNavigator))
        // Each step down draws strictly fewer controls.
        let counts = CanvasTopBarDensity.allCases.map { d in CanvasTopBarControl.allCases.filter { d.shows($0) }.count }
        #expect(counts == counts.sorted(by: >) && Set(counts).count == counts.count)
    }

    @Test("The bar asks for no more height than its slot, so it never pushes the page down")
    func barFitsItsSlot() {
        let host = NSHostingView(rootView: CanvasTopBar(environment: ProjectShellEnvironment.mock()))
        let fitting = host.fittingSize
        print("d3 CanvasTopBar fittingSize \(fitting)")
        #expect(fitting.height <= CanvasTopBar.height + 0.5)
        // The canvas column may be as narrow as 360 pt; offered that, the bar sheds groups and
        // fits instead of asking for more.
        let narrow = NSHostingController(rootView: CanvasTopBar(environment: ProjectShellEnvironment.mock()))
            .sizeThatFits(in: CGSize(width: 360, height: CanvasTopBar.height))
        print("d3 CanvasTopBar at 360 pt asks for \(narrow)")
        #expect(narrow.width <= 360.5)
        let strip = NSHostingView(rootView: DocumentTabBarView(model: ProjectShellEnvironment.mock().tabBar))
        print("d3 DocumentTabBarView fittingSize \(strip.fittingSize)")
        #expect(strip.fittingSize.height <= DocumentTabMetrics.height + 4.5)
    }

    @Test("The bar renders off screen, with and without a document")
    func renders() throws {
        let environment = ProjectShellEnvironment.mock()
        let bitmap = try DesignD3Render.render(CanvasTopBar(environment: environment), size: CGSize(width: 1075, height: 48), name: "canvas-top-bar")
        #expect(DesignD3Render.distinctColours(bitmap) > 3, "the bar draws its groups, glyphs and field")
        let narrow = try DesignD3Render.render(CanvasTopBar(environment: environment), size: CGSize(width: 420, height: 48), name: "canvas-top-bar-narrow")
        #expect(DesignD3Render.distinctColours(narrow) > 3)
    }
}

@MainActor
@Suite("Design d3 — document tabs", .shellTierSerialised)
struct DesignD3TabTests {

    @Test("The front tab is raised; a back tab has no fill and washes only on hover")
    func tabStates() {
        #expect(DocumentTabPalette.ground == ZPDFWindowChrome.groundToken, "the strip sits on the top band's chrome")
        #expect(DocumentTabPalette.fill(isActive: true) == .elevated)
        #expect(DocumentTabPalette.fill(isActive: false) == nil, "inactive tab has no fill")
        #expect(DocumentTabPalette.activeStroke == .borderStrong)
        #expect(DocumentTabPalette.overlay(isActive: false, isHovering: true) == .stateHover)
        #expect(DocumentTabPalette.overlay(isActive: false, isHovering: false) == nil)
        #expect(DocumentTabPalette.overlay(isActive: true, isHovering: true) == nil, "hover must not look like selection")
        #expect(DocumentTabPalette.activeTitle != DocumentTabPalette.inactiveTitle)
    }

    @Test("The file name has priority: dot before it, badge only when it fits, everything in the tooltip")
    func titlePriority() throws {
        var summary = try #require(ZenitSampleProject.shared.tabs.first)
        summary.hasUnsavedChanges = true
        let item = DocumentTabItem(summary: summary, revisions: ZenitSampleProject.shared.revisions)
        #expect(item.displayTitle == summary.fileName)
        #expect(item.accessibilityValue == "edited")
        #expect(item.accessibilityLabel.contains(summary.title))
        #expect(item.tooltip.contains(summary.fileName))
        if let badge = item.revisionLabel { #expect(item.tooltip.contains(badge)) }
        #expect(item.tooltip.contains("Edited"))
    }

    @Test("Tabs keep their natural width when there is room, then shrink, then overflow — + always fits")
    func stripPlan() {
        let natural = DocumentTabMetrics.naturalWidth
        let wide = DocumentTabStripPlan.make(tabCount: 2, activeIndex: 0, available: 800)
        #expect(wide.tabWidth == natural && wide.visible == [0, 1] && wide.overflow.isEmpty)

        let shared = DocumentTabStripPlan.make(tabCount: 3, activeIndex: 0, available: 560)
        #expect(shared.visible == [0, 1, 2] && shared.overflow.isEmpty)
        #expect(shared.tabWidth < natural && shared.tabWidth >= DocumentTabMetrics.minimumWidth)

        let shared2 = DocumentTabStripPlan.make(tabCount: 2, activeIndex: 0, available: 400)
        #expect(shared2.visible == [0, 1] && shared2.tabWidth >= DocumentTabMetrics.minimumWidth)

        // d8's 300 pt left column with two documents: both tabs in the strip (LT3-03). This
        // used to expect the second in the › menu, which is the reported regression.
        let column = DocumentTabStripPlan.make(tabCount: 2, activeIndex: 1, available: 300)
        #expect(column.visible == [0, 1])
        #expect(column.overflow.isEmpty)
        #expect(column.tabWidth >= DocumentTabMetrics.minimumWidth)

        for count in 1...30 {
            for available in stride(from: CGFloat(160), through: 1400, by: 37) {
                for active in [0, count / 2, count - 1] {
                    let plan = DocumentTabStripPlan.make(tabCount: count, activeIndex: active, available: available)
                    #expect(plan.visible.contains(active), "front tab \(active) of \(count) visible at \(available)")
                    #expect(Set(plan.visible + plan.overflow) == Set(0..<count))
                    let used = DocumentTabMetrics.leadingInset
                        + CGFloat(plan.visible.count) * plan.tabWidth
                        + CGFloat(plan.visible.count - 1) * DocumentTabMetrics.spacing
                        + (plan.overflow.isEmpty ? 0 : DocumentTabMetrics.overflowWidth + DocumentTabMetrics.spacing)
                        + DocumentTabMetrics.spacing + DocumentTabMetrics.newTabWidth
                    #expect(used <= available + 0.5 || plan.tabWidth == DocumentTabMetrics.floorWidth,
                            "\(count) tabs at \(available) pt use \(used) pt: + would be clipped")
                }
            }
        }
    }

    @Test("In the 300 pt top-band column the + is drawn inside the strip")
    func plusVisibleInNarrowColumn() throws {
        let environment = ProjectShellEnvironment.mock()
        let bitmap = try DesignD3Render.render(
            DocumentTabBarView(model: environment.tabBar),
            size: CGSize(width: 300, height: 38),
            name: "tab-strip-300"
        )
        let plan = DocumentTabStripPlan.make(
            tabCount: environment.tabBar.items.count,
            activeIndex: environment.tabBar.items.firstIndex(where: \.isActive),
            available: 300
        )
        let plusRight = DocumentTabMetrics.leadingInset
            + CGFloat(plan.visible.count) * (plan.tabWidth + DocumentTabMetrics.spacing)
            + (plan.overflow.isEmpty ? 0 : DocumentTabMetrics.overflowWidth + DocumentTabMetrics.spacing)
            + DocumentTabMetrics.newTabWidth
        #expect(plusRight <= 300)
        let plusArea = CGRect(x: plusRight - DocumentTabMetrics.newTabWidth, y: 4, width: DocumentTabMetrics.newTabWidth, height: 30)
        #expect(DesignD3Render.distinctColours(bitmap, in: plusArea) > 2, "the + tab and its glyph are drawn")
    }

    @Test("A tab is the mockup's size and shape: rounded top, flared foot, open stroke")
    func tabShape() {
        #expect(DocumentTabMetrics.height == ZPDFSpacing.Chrome.documentTabHeight)
        #expect(DocumentTabMetrics.topRadius == ZPDFRadius.card)
        let rect = CGRect(x: 0, y: 0, width: 200, height: DocumentTabMetrics.height)
        let closed = DocumentTabShape().path(in: rect)
        let open = DocumentTabShape(closed: false).path(in: rect)
        #expect(abs(closed.boundingRect.width - rect.width) < 0.5)
        #expect(abs(closed.boundingRect.height - rect.height) < 0.5)
        // The foot flares: the bottom corners are on the path's edge, the top corners are cut.
        #expect(closed.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)))
        #expect(!closed.contains(CGPoint(x: rect.minX + 1, y: rect.minY + 1)), "top corners are rounded")
        #expect(!closed.contains(CGPoint(x: rect.minX + 1, y: rect.midY)), "the side stands in from the flare")
        // The stroke has no bottom edge: the tab stands on the baseline instead of being boxed.
        #expect(open.description != closed.description)
        #expect(!open.description.hasSuffix("h"), "the open outline is not closed")
    }

    /// S-055 (iteration 2): the strip's opt-in trailing Export and Inspector controls were
    /// deleted — never shown in the product — so the strip carries only documents, full stop.
    @Test("The strip carries only documents")
    func stripCarriesOnlyDocuments() throws {
        let environment = ProjectShellEnvironment.mock()
        let bare = try DesignD3Render.render(
            DocumentTabBarView(model: environment.tabBar),
            size: CGSize(width: 600, height: 40),
            name: "tab-strip"
        )
        #expect(DesignD3Render.distinctColours(bare) > 3, "the strip draws its tabs")
        // The right-hand 80 pt hold nothing but the ground and the baseline.
        let rightEdge = CGRect(x: 520, y: 0, width: 80, height: 40)
        #expect(DesignD3Render.distinctColours(bare, in: rightEdge) <= 2)
    }

    @Test("The model's existing behaviour survives the restyle")
    func modelUnchanged() throws {
        let environment = ProjectShellEnvironment.mock()
        let items = environment.tabBar.items
        try #require(!items.isEmpty)
        #expect(items.filter(\.isActive).count == 1)
        #expect(DocumentTabView.showsCloseButton(isHovering: false, isFocused: false, isActive: true))
        #expect(!DocumentTabView.showsCloseButton(isHovering: false, isFocused: false, isActive: false))
    }
}

@MainActor
@Suite("Design d3 — token use", .shellTierSerialised)
struct DesignD3TokenUseTests {

    /// The design round's source files.
    private static var sources: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUIShell")
        return [
            root.appendingPathComponent("Tabs/DocumentTabBarView.swift"),
            root.appendingPathComponent("Tabs/DocumentTabBarModel.swift"),
            root.appendingPathComponent("Canvas/CanvasTopBar.swift")
        ]
    }

    @Test("No raw colour anywhere in the tab strip or the canvas bar")
    func noRawColours() throws {
        let forbidden = [
            "Color(red", "Color(.sRGB", "Color(white", "Color(hue", "NSColor(red", "NSColor(white",
            "NSColor(calibrated", "NSColor(srgb", "#colorLiteral", "Color.white", "Color.black",
            "Color.blue", "Color.red", "Color.gray", ".foregroundColor(.", "Color(hex"
        ]
        for url in Self.sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in forbidden {
                #expect(!text.contains(needle), "\(url.lastPathComponent) uses \(needle)")
            }
        }
    }

    @Test("Every palette token has distinct light and dark values, so light appearance keeps working")
    func palettesAreTokens() {
        for token in CanvasBarPalette.all + DocumentTabPalette.all {
            let set = ZPDFColor.set(for: token)
            #expect(set.light != set.dark || token == .accent, "\(token) must resolve per appearance")
        }
    }
}

/// Off-screen rendering for the checks above. The view is hosted in an `NSHostingView` that is
/// never put in a window, and drawn with `cacheDisplay(in:to:)`.
@MainActor
enum DesignD3Render {

    static func render<V: View>(_ view: V, size: CGSize, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(ZPDFColor.background)
            .environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["ZENIT_D3_RENDER_DIR"],
           let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    /// The number of distinct colours in a region (in points), sampled every other point.
    static func distinctColours(_ bitmap: NSBitmapImageRep, in region: CGRect? = nil) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let area = region ?? CGRect(origin: .zero, size: bitmap.size)
        var seen = Set<UInt32>()
        var y = area.minY
        while y < area.maxY {
            var x = area.minX
            while x < area.maxX {
                if let colour = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) {
                    let key = UInt32(colour.redComponent * 255) << 16
                        | UInt32(colour.greenComponent * 255) << 8
                        | UInt32(colour.blueComponent * 255)
                    seen.insert(key)
                }
                x += 2
            }
            y += 2
        }
        return seen.count
    }
}
