import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The project window's top band, drawn by the window itself: one navy band 88 pt tall, as the
/// 2026-09-23 main-window mockup draws it.
///
/// Left, the brand block with the document tabs directly under it (the brand to the right of
/// the window controls, the tabs from the window edge). Centre, the tool group, vertically
/// centred on the full band height and horizontally centred on the window. Right, the rounded
/// workspace group and the author badge.
///
/// # Why the window draws it
///
/// An `NSToolbar` row cannot hold a second row under one of its items, and its unified style is
/// a fixed 52 pt band — too short for the mockup's 60 pt tool chips, let alone the tabs. So the
/// band is a view in the content, under the transparent titlebar. The views in it are exactly
/// the ones ``ZenitToolbarBuilder`` builds for its toolbar items and the tab strip is
/// ``DocumentTabBarView``, unchanged: the band only arranges them.
///
/// # What the NSToolbar still does
///
/// The window keeps its `NSToolbar`, hidden. It is the arrangement's source of truth — its
/// identifier is the autosave key, its items are the person's customised order — and it is what
/// View ▸ Customize Toolbar edits with the system sheet. The band re-reads the toolbar's items
/// whenever one is added or removed (``bind(to:)``). Every command the band offers is also in the
/// menu bar, from the same command table, exactly as before.
///
/// # Narrow windows
///
/// The same order d2 gave the toolbar's overflow: first the brand gives way, then the right
/// group collapses into a **More** chip whose menu lists its commands, and only then do the last
/// tools move into that menu — with their palettes as submenus, as the toolbar's own overflow
/// menu listed them (IM-140). Nothing silently disappears.
@MainActor
public final class ProjectTopBandView: NSView {

    /// How much of the band fits the current width, from roomiest to tightest.
    public enum Stage: Int, Comparable, Sendable {
        /// Brand, every tool and the full right group.
        case full
        /// The brand has given way; everything else is in place.
        case brandHidden
        /// The right group has collapsed into the More chip.
        case rightCollapsed
        /// Trailing tools have moved into the More chip too.
        case toolsOverflowing

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What a double-click on the band's empty area does: the system's titlebar setting.
    public enum DoubleClickAction: Equatable, Sendable {
        case zoom
        case minimize
        case none
    }

    /// The band's height: the mockup's top chrome (`ZPDFSpacing.Chrome.topBarHeight`).
    public static let height: CGFloat = ZPDFSpacing.Chrome.topBarHeight
    /// The band's height with the toolbar hidden (View ▸ Hide Toolbar): only the tabs remain,
    /// on the row of the window controls.
    public static let hiddenHeight: CGFloat = ProjectWindowLayoutController.tabBarHeight
    /// The tab row's height, at the foot of the band.
    public static let tabRowHeight: CGFloat = ProjectWindowLayoutController.tabBarHeight
    /// The left column's width while the brand is shown: the mockup's ~300 pt brand-and-tabs
    /// column, or more when the brand needs it.
    public static let fullLeftColumn: CGFloat = 300
    /// The left column's width once the brand has given way: room for about one and a half tabs,
    /// the rest of the strip scrolls.
    public static let compactLeftColumn: CGFloat = 220
    /// The margin at the band's trailing edge.
    public static let edgeMargin: CGFloat = ZPDFSpacing.l
    /// The gap between two groups.
    public static let groupGap: CGFloat = ZPDFSpacing.xl
    /// The gap between two items inside a group.
    public static let itemSpacing: CGFloat = ZPDFSpacing.xs
    /// The window controls' inset when there are none to measure (no window, full screen).
    public static let fallbackWindowControlsInset: CGFloat = 78

    private let builder: ZenitToolbarBuilder
    /// The builder whose palette rows the band's palette menus list (L-100).
    var paletteBuilder: ZenitToolbarBuilder { builder }
    private let environment: ProjectShellEnvironment
    /// A toolbar that is never attached, only handed to the builder's delegate method so it can
    /// build items for the band. Its identifier differs from the real one: two toolbars with one
    /// identifier share a configuration, and this one must never touch the person's.
    private let scratchToolbar = NSToolbar(identifier: "zenit.topBand.scratch")

    /// The document tab strip, at the foot of the left column.
    public let tabsView: NSView
    /// The brand block, or `nil` when the person customised it away.
    public private(set) var brandView: NSView?
    /// The tool group, in the toolbar's order.
    public private(set) var centreEntries: [(identifier: NSToolbarItem.Identifier, view: NSView)] = []
    /// The right group, in the toolbar's order; the author badge last when present.
    public private(set) var rightEntries: [(identifier: NSToolbarItem.Identifier, view: NSView)] = []
    /// The More chip that holds whatever does not fit.
    public private(set) var moreView: NSView!
    /// The items the band arranges, in the toolbar's order.
    public private(set) var identifiers: [NSToolbarItem.Identifier] = []

    /// How many document tabs the strip holds. Followed through Observation from the
    /// environment's tab model; a test may set it directly.
    public var tabCount: Int = 0 {
        didSet {
            guard tabCount != oldValue else { return }
            needsLayout = true
        }
    }
    /// Whether the document tabs have a full-width row of their own under the tools (LT3-03).
    ///
    /// Every open document must have a visible tab. The tab column — the left column widened up
    /// to the tools (L-24) — holds as many tabs as fit beside the `+` at the readable width
    /// (``DocumentTabMetrics/readableWidth``, about ten characters of the name); when the
    /// documents need more than that, the band grows by one tab row and the strip spans the
    /// window's width under the tools, where tabs may shrink to 72 pt, so the › menu is reached
    /// only past what that row holds (about twelve at a 1 040 pt window, twenty at 1 728 pt).
    public private(set) var tabsWrapped = false
    /// Called after ``preferredHeight`` changes because the tab row wrapped or unwrapped. The
    /// window's layout controller updates the band's height constraint from it.
    public var onPreferredHeightChange: (() -> Void)?
    /// How much fits right now. Set by `layout()`.
    public private(set) var stage: Stage = .full
    /// The tools that have moved into the More chip, in order.
    public private(set) var overflowedCentreIdentifiers: [NSToolbarItem.Identifier] = []

    /// Whether the band shows its tools (View ▸ Hide / Show Toolbar). Hidden, only the tabs stay.
    public var isShown: Bool = true {
        didSet {
            guard isShown != oldValue else { return }
            needsLayout = true
        }
    }

    /// Whether View ▸ Customize Toolbar has the window's own toolbar up (L-82).
    ///
    /// The sheet edits the `NSToolbar`, so for its length the toolbar is shown — and it lies in
    /// the transparent titlebar, over the top of this band. Live test 8: "the toolbar is drawn
    /// twice, shifted vertically (logo, BUILT FOR WHAT'S NEXT and every tool icon doubled and
    /// overlapping)". While customizing, the band's own brand, tools and right group step aside
    /// and only the tabs stay, so the tools are on screen once: the toolbar the sheet is editing.
    public var isCustomizing: Bool = false {
        didSet {
            guard isCustomizing != oldValue else { return }
            needsLayout = true
        }
    }

    /// Whether the band is drawing its own tools right now: shown, and not standing aside for
    /// the customization sheet.
    public var drawsTools: Bool {
        isShown && !isCustomizing && (brandView.map { !$0.isHidden } ?? false
            || (centreEntries + rightEntries).contains { !$0.view.isHidden }
            || !moreView.isHidden)
    }

    /// The height the band wants in its current state.
    public var preferredHeight: CGFloat {
        guard isShown else { return Self.hiddenHeight }
        return Self.height + (tabsWrapped ? Self.tabRowHeight : 0)
    }

    /// Whether `tabCount` tabs need their own row when the tab column is `leftColumn` wide:
    /// whether the column cannot hold them all at the readable width (L-24).
    ///
    /// This compared with the 72 pt minimum before live test 5, so three tabs stayed in a
    /// ~330 pt column at 87 pt each — "Pl...df" — however wide the window was.
    static func tabsNeedOwnRow(tabCount: Int, leftColumn: CGFloat) -> Bool {
        DocumentTabStripPlan.minimumStripWidth(tabCount: tabCount, tabWidth: DocumentTabMetrics.readableWidth)
            > leftColumn - ZPDFWindowChrome.gutter
    }

    /// The right edge of the tab column: the left column, widened over the free chrome up to
    /// one group gap before the first visible tool — or, with no tool shown, before the right
    /// group (L-24). The tools stand across the tab row's height, so the tabs stop short of
    /// them rather than run underneath.
    static func tabColumnRight(left: CGFloat, centreStart: CGFloat?, rightGroupStart: CGFloat) -> CGFloat {
        max(left, (centreStart ?? rightGroupStart) - groupGap)
    }

    /// Reads the tab count and re-reads it whenever the tab model changes.
    private func followTabCount() {
        let tabBar = environment.tabBar
        let count = withObservationTracking {
            tabBar.items.count
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followTabCount() }
            }
        }
        tabCount = count
    }

    /// How a menu hung from a band chip — the More menu, the Export chooser — reaches the
    /// screen: its top-left corner at a point in the chip's view (``menuPlacement(for:menuWidth:)``).
    /// A test — or the off-screen hit-target probe — injects a recorder: `popUp` tracks the
    /// menu modally, which a headless run must never start.
    public var presentMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, origin, view in
        menu.popUp(positioning: nil, at: origin, in: view)
    }
    /// Reads the system's titlebar double-click setting. Injected by tests, so none of them
    /// writes a defaults domain to exercise it.
    var readGlobalDefault: (String) -> Any? = { UserDefaults.standard.object(forKey: $0) }
    /// Performs the double-click action on the window. Injected by tests.
    var performWindowAction: (DoubleClickAction, NSWindow?) -> Void = { action, window in
        switch action {
        case .zoom: window?.performZoom(nil)
        case .minimize: window?.performMiniaturize(nil)
        case .none: break
        }
    }

    private let hairline = CALayer()
    /// Items the band has built, kept so their views and menus stay alive.
    private var retainedItems: [NSToolbarItem] = []
    private weak var observedToolbar: NSToolbar?

    /// Creates the band.
    ///
    /// - Parameters:
    ///   - builder: builds every item's view, exactly as for the toolbar.
    ///   - environment: the shell the extra chips act on.
    ///   - tabsView: the document tab strip.
    public init(builder: ZenitToolbarBuilder, environment: ProjectShellEnvironment, tabsView: NSView) {
        self.builder = builder
        self.environment = environment
        self.tabsView = tabsView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(hairline)
        tabsView.translatesAutoresizingMaskIntoConstraints = true
        Self.ignoreSafeArea(in: tabsView)
        addSubview(tabsView)
        let more = NSHostingView(rootView: ZenitToolChip(
            environment: environment,
            glyph: .symbol(.more),
            title: NSLocalizedString("More", comment: "Top band chip that holds the items a narrow window has no room for"),
            selectionID: nil,
            helpText: {
                NSLocalizedString(
                    "More toolbar items",
                    comment: "Tooltip of the top band's More chip"
                )
            },
            action: { [weak self] in self?.showOverflowMenu() },
            palette: nil
        ))
        more.translatesAutoresizingMaskIntoConstraints = true
        more.safeAreaRegions = []
        more.setAccessibilityLabel(NSLocalizedString(
            "More toolbar items",
            comment: "Accessibility label of the top band's More chip"
        ))
        addSubview(more)
        moreView = more
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(NSLocalizedString("Toolbar", comment: "Accessibility label of the window's top band"))
        setArrangement(ZenitToolbarBuilder.defaultItemIdentifiers)
        followTabCount()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public nonisolated override var isFlipped: Bool { true }
    public nonisolated override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        let variant = ZPDFAppearanceVariant.matching(effectiveAppearance)
        layer?.backgroundColor = ZPDFColor.nsColor(ZPDFWindowChrome.groundToken, variant: variant).cgColor
        hairline.backgroundColor = ZPDFColor.nsColor(ZPDFWindowChrome.hairlineToken, variant: variant).cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Arrangement

    /// Follows a toolbar: arranges its items now and again whenever one is added or removed —
    /// which is what the customization sheet does.
    public func bind(to toolbar: NSToolbar?) {
        if let observedToolbar {
            NotificationCenter.default.removeObserver(self, name: NSToolbar.willAddItemNotification, object: observedToolbar)
            NotificationCenter.default.removeObserver(self, name: NSToolbar.didRemoveItemNotification, object: observedToolbar)
        }
        observedToolbar = toolbar
        guard let toolbar else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(toolbarItemsChanged(_:)),
            name: NSToolbar.willAddItemNotification, object: toolbar
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(toolbarItemsChanged(_:)),
            name: NSToolbar.didRemoveItemNotification, object: toolbar
        )
        refreshArrangement()
    }

    /// Re-reads the bound toolbar's items.
    public func refreshArrangement() {
        guard let toolbar = observedToolbar else { return }
        let current = toolbar.items.map(\.itemIdentifier)
        // An empty toolbar is one AppKit has not populated yet, not a person's choice: removing
        // every item leaves the brand and the tabs, but the sheet cannot empty the list to zero
        // while this band is the only way to reach the tools.
        setArrangement(current.isEmpty ? ZenitToolbarBuilder.defaultItemIdentifiers : current)
    }

    @objc private func toolbarItemsChanged(_ notification: Notification) {
        if notification.name == NSToolbar.didRemoveItemNotification {
            // The item is already gone from `items`.
            refreshArrangement()
            return
        }
        // `willAdd` arrives before the item is in `items`. Measured: a block queued from inside
        // the notification can run before `insertItem` has finished — building the item's
        // SwiftUI view drains the main queue — and read the old list. So the band waits for
        // the item itself to appear, re-reading on each turn, rather than trusting one hop.
        let added = notification.userInfo?["item"] as? NSToolbarItem
        refreshWhenPresent(added, attemptsLeft: 20)
        // And once more from the run loop a moment later, in case that drain ran the whole
        // chain inside `insertItem`. The customization sheet's end re-reads synchronously too
        // (`ProjectWindowLayoutController.customizationSheetEnded`), which is the definitive
        // sync; these two keep the band live while the sheet is still open.
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshArrangement() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshWhenPresent(_ item: NSToolbarItem?, attemptsLeft: Int) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let toolbar = self.observedToolbar else { return }
                if let item, attemptsLeft > 0, !toolbar.items.contains(where: { $0 === item }) {
                    self.refreshWhenPresent(item, attemptsLeft: attemptsLeft - 1)
                    return
                }
                self.refreshArrangement()
            }
        }
    }

    /// Where an identifier lives in the band.
    enum Slot { case brand, centre, right, ignored }

    static func slot(for identifier: NSToolbarItem.Identifier) -> Slot {
        switch identifier {
        case .zenitBrand:
            return .brand
        case .zenitWorkspaceGroup, .zenitToolLibrary, .zenitSearch, .zenitCompare, .zenitExport,
             .zenitAuthor, .toggleSidebar, .toggleInspector:
            return .right
        case .space, .flexibleSpace:
            // The band's layout is fixed — brand left, tools centred, workspace right — so the
            // spacers the toolbar needed to centre its tools have nothing to do here.
            return .ignored
        default:
            return ZenitToolbarBuilder.allowedItemIdentifiers.contains(identifier) ? .centre : .ignored
        }
    }

    /// Replaces the arranged items.
    public func setArrangement(_ newIdentifiers: [NSToolbarItem.Identifier]) {
        guard newIdentifiers != identifiers || (centreEntries.isEmpty && rightEntries.isEmpty) else { return }
        identifiers = newIdentifiers
        brandView?.removeFromSuperview()
        for entry in centreEntries + rightEntries { entry.view.removeFromSuperview() }
        brandView = nil
        centreEntries = []
        rightEntries = []
        retainedItems = []
        for identifier in newIdentifiers {
            let slot = Self.slot(for: identifier)
            guard slot != .ignored, let item = makeItem(identifier), let view = item.view else { continue }
            retainedItems.append(item)
            Self.ignoreSafeArea(in: view)
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
            switch slot {
            case .brand: brandView = view
            case .centre: centreEntries.append((identifier, view))
            case .right: rightEntries.append((identifier, view))
            case .ignored: break
            }
        }
        // The author badge always closes the band, wherever the list put it.
        if let index = rightEntries.firstIndex(where: { $0.identifier == .zenitAuthor }) {
            rightEntries.append(rightEntries.remove(at: index))
        }
        needsLayout = true
    }

    /// One item, built by the toolbar builder — the same view the toolbar would show — or, for
    /// the two system sidebar items, a chip running the matching panel command.
    private func makeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        if let item = builder.toolbar(scratchToolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: false) {
            return item
        }
        switch identifier {
        case .toggleSidebar:
            return panelChipItem(identifier, glyph: .symbol(.navigator), command: .toggleNavigator,
                                 title: NSLocalizedString("Navigator", comment: "Top band chip: show or hide the Navigator"))
        case .toggleInspector:
            return panelChipItem(identifier, glyph: .symbol(.inspector), command: .toggleInspector,
                                 title: NSLocalizedString("Inspector", comment: "Top band chip: show or hide the Inspector"))
        default:
            return nil
        }
    }

    private func panelChipItem(
        _ identifier: NSToolbarItem.Identifier,
        glyph: ZPDFGlyph,
        command: ZPDFCommandID,
        title: String
    ) -> NSToolbarItem {
        let environment = self.environment
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hosting = NSHostingView(rootView: ZenitToolChip(
            environment: environment,
            glyph: glyph,
            title: title,
            selectionID: nil,
            helpText: { title },
            action: { environment.perform(command) },
            palette: nil
        ))
        hosting.setAccessibilityLabel(title)
        item.view = hosting
        item.label = title
        let menuForm = NSMenuItem(title: title, action: #selector(BandMenuAction.run(_:)), keyEquivalent: "")
        let action = BandMenuAction { environment.perform(command) }
        menuForm.target = action
        menuForm.representedObject = action
        item.menuFormRepresentation = menuForm
        return item
    }

    // MARK: - Layout

    /// The leading inset that clears the window's close, minimise and zoom buttons.
    func windowControlsInset() -> CGFloat {
        guard let window,
              let zoom = window.standardWindowButton(.zoomButton),
              !zoom.isHidden, zoom.window === window
        else { return Self.fallbackWindowControlsInset }
        return convert(zoom.bounds, from: zoom).maxX + ZPDFSpacing.l
    }

    private static func width(of views: [NSView]) -> CGFloat {
        guard !views.isEmpty else { return 0 }
        return views.reduce(0) { $0 + $1.fittingSize.width } + itemSpacing * CGFloat(views.count - 1)
    }

    public override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let scale = window?.backingScaleFactor ?? 2
        let pixel = 1 / max(scale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hairline.frame = CGRect(x: 0, y: height - pixel, width: width, height: pixel)
        CATransaction.commit()
        let inset = windowControlsInset()

        guard isShown else {
            if tabsWrapped { tabsWrapped = false }
            // Hide Toolbar: the tabs alone, on the row of the window controls.
            brandView?.isHidden = true
            for entry in centreEntries + rightEntries { entry.view.isHidden = true }
            moreView.isHidden = true
            tabsView.frame = NSRect(x: inset, y: 0, width: max(0, width - inset - Self.edgeMargin), height: height)
            overflowedCentreIdentifiers = []
            return
        }

        let brandWidth = brandView?.fittingSize.width ?? 0
        let centreViews = centreEntries.map(\.view)
        let collapsible = rightEntries.filter { $0.identifier != .zenitAuthor }
        let fixedRight = rightEntries.filter { $0.identifier == .zenitAuthor }
        let rightFull = Self.width(of: rightEntries.map(\.view))
        let rightCollapsed = Self.width(of: (collapsible.isEmpty ? [] : [moreView]) + fixedRight.map(\.view))
        let leftFull = brandView == nil ? Self.fullLeftColumn : max(inset + brandWidth, Self.fullLeftColumn)
        let leftCompact = Self.compactLeftColumn

        func fits(_ left: CGFloat, _ centre: CGFloat, _ right: CGFloat) -> Bool {
            left + Self.groupGap + centre + Self.groupGap + right + Self.edgeMargin <= width
        }

        var left = leftFull
        var right = rightFull
        var visibleCentre = centreEntries.count
        let allCentre = Self.width(of: centreViews)
        if fits(leftFull, allCentre, rightFull) {
            stage = .full
        } else if brandView != nil, fits(leftCompact, allCentre, rightFull) {
            stage = .brandHidden
            left = leftCompact
        } else if fits(leftCompact, allCentre, rightCollapsed) {
            stage = .rightCollapsed
            left = leftCompact
            right = rightCollapsed
        } else {
            stage = .toolsOverflowing
            left = leftCompact
            // The More chip is needed now even when the right group had nothing to collapse.
            right = Self.width(of: [moreView] + fixedRight.map(\.view))
            while visibleCentre > 1,
                  !fits(left, Self.width(of: Array(centreViews.prefix(visibleCentre))), right) {
                visibleCentre -= 1
            }
            // A separator never ends the visible run on its own.
            while visibleCentre > 1, centreEntries[visibleCentre - 1].identifier == .zenitToolSeparator {
                visibleCentre -= 1
            }
        }

        // Centre: horizontally centred on the window, pushed aside only by the other groups.
        // Placed across before the tab row is decided: where the tools start is where the tab
        // column has to stop (L-24), and it does not depend on the tab row.
        let shown = Array(centreEntries.prefix(visibleCentre))
        overflowedCentreIdentifiers = centreEntries.dropFirst(visibleCentre)
            .map(\.identifier)
            .filter { $0 != .zenitToolSeparator }
        for entry in centreEntries.dropFirst(visibleCentre) { entry.view.isHidden = true }
        let centreWidth = Self.width(of: shown.map(\.view))
        let lowest = left + Self.groupGap
        let highest = width - Self.edgeMargin - right - Self.groupGap - centreWidth
        let centreStart = min(max(((width - centreWidth) / 2).rounded(), lowest), max(lowest, highest))

        // The tab column (L-24): the left column widened over the free chrome up to the tools,
        // so a wide window gives its tabs the room it has instead of a fixed ~300 pt column.
        let tabColumn = Self.tabColumnRight(
            left: left,
            centreStart: shown.isEmpty ? nil : centreStart,
            rightGroupStart: width - Self.edgeMargin - right
        )

        // The tabs' own row (LT3-03, L-24): when the tab column cannot show every document at
        // the readable tab width, the strip moves under the tools and spans the window. Decided
        // from the width and the tab count only, never from the current height, so it cannot
        // flip back and forth while the height constraint catches up.
        let wraps = Self.tabsNeedOwnRow(tabCount: tabCount, leftColumn: tabColumn)
        if wraps != tabsWrapped {
            tabsWrapped = wraps
            // Synchronously: the new height constraint is resolved in this same layout pass,
            // and the decision does not depend on the height, so the pass converges at once.
            onPreferredHeightChange?()
        }
        // The tools' band: the full height, less the tab row when the tabs have their own.
        let contentHeight = wraps ? min(Self.height, height) : height

        // Left column: the brand beside the window controls, the tabs at the foot.
        let brandRow = wraps ? contentHeight : height - Self.tabRowHeight
        if let brandView {
            brandView.isHidden = stage != .full
            let size = brandView.fittingSize
            brandView.frame = NSRect(x: inset, y: ((brandRow - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        let gutter = ZPDFWindowChrome.gutter
        if wraps {
            tabsView.frame = NSRect(
                x: gutter, y: height - Self.tabRowHeight,
                width: max(0, width - gutter - Self.edgeMargin), height: Self.tabRowHeight
            )
        } else {
            tabsView.frame = NSRect(x: gutter, y: brandRow, width: max(0, tabColumn - gutter), height: Self.tabRowHeight)
        }

        var x = centreStart
        for entry in shown {
            let size = entry.view.fittingSize
            entry.view.isHidden = false
            entry.view.frame = NSRect(x: x, y: ((contentHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Self.itemSpacing
        }

        // Right: flush to the trailing margin, vertically centred.
        let showsMore = stage == .toolsOverflowing || (stage == .rightCollapsed && !collapsible.isEmpty)
        let rightViews = showsMore ? [moreView!] + fixedRight.map(\.view) : rightEntries.map(\.view)
        if showsMore {
            for entry in collapsible { entry.view.isHidden = true }
        }
        moreView.isHidden = !rightViews.contains(moreView)
        var rx = width - Self.edgeMargin - Self.width(of: rightViews)
        for view in rightViews {
            let size = view.fittingSize
            view.isHidden = false
            view.frame = NSRect(x: rx, y: ((contentHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
            rx += size.width + Self.itemSpacing
        }

        // L-82: the customization sheet has the real toolbar up over the band; one copy of the
        // tools on screen. Everything keeps its frame, so the band comes back as it was.
        if isCustomizing {
            brandView?.isHidden = true
            for entry in centreEntries + rightEntries { entry.view.isHidden = true }
            moreView.isHidden = true
        }
    }

    // MARK: - The More menu

    /// The items the More chip lists right now: the tools that did not fit, then the collapsed
    /// right group's commands. Built fresh on every open, so palette submenus read the toolbar
    /// model as it is now.
    public func overflowMenu() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("More", comment: "Top band More menu title"))
        var built: [NSToolbarItem] = []
        func append(_ identifier: NSToolbarItem.Identifier, flatten: Bool) {
            guard let item = makeItem(identifier), let form = item.menuFormRepresentation else { return }
            built.append(item)
            if flatten, let submenu = form.submenu {
                for row in submenu.items {
                    submenu.removeItem(row)
                    menu.addItem(row)
                }
            } else {
                menu.addItem(form)
            }
        }
        for identifier in overflowedCentreIdentifiers { append(identifier, flatten: false) }
        if stage >= .rightCollapsed {
            let collapsible = rightEntries.map(\.identifier).filter { $0 != .zenitAuthor }
            if !menu.items.isEmpty, !collapsible.isEmpty { menu.addItem(.separator()) }
            for identifier in collapsible { append(identifier, flatten: identifier == .zenitWorkspaceGroup) }
        }
        overflowMenuItems = built
        return menu
    }

    /// Keeps the toolbar items behind an open More menu alive: their menu rows target them.
    private var overflowMenuItems: [NSToolbarItem] = []

    func showOverflowMenu() {
        presentMenu(overflowMenu(), Self.menuOrigin(under: moreView), moreView)
    }

    // MARK: - Menus hung from band chips (L-29)

    /// The gap between a chip's lower edge and the menu it opens.
    public static let menuGap: CGFloat = 4

    /// Where a menu hung from `view` puts its top-left corner, in `view`'s own coordinates:
    /// at the view's left edge, `gap` below its lower edge, whether the view is flipped (as a
    /// SwiftUI chip's hosting view is) or not.
    public static func menuOrigin(under view: NSView, gap: CGFloat = menuGap) -> NSPoint {
        NSPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY + gap : view.bounds.minY - gap)
    }

    /// Where a menu opened by the band item `identifier` hangs: the view it hangs from and its
    /// top-left corner in that view's coordinates, or `nil` when the band shows no chip for the
    /// item (View ▸ Hide Toolbar, or an item the person customised away).
    ///
    /// - The item's own chip, when it stands in the band on its own: under its left edge.
    /// - A workspace command inside the rounded workspace group, which is one view holding all
    ///   four chips: under the group. Export is the group's last chip and ends where the group
    ///   ends, so its menu's right edge is put at the group's right edge — under the Export chip,
    ///   not under Tool Library. (`menuWidth` is the menu's width, for that alignment.)
    /// - The More chip, when the item has moved into it.
    public func menuPlacement(for identifier: NSToolbarItem.Identifier, menuWidth: CGFloat) -> (view: NSView, origin: NSPoint)? {
        guard isShown, !isHiddenOrHasHiddenAncestor else { return nil }
        let entries = centreEntries + rightEntries
        if let own = entries.first(where: { $0.identifier == identifier }) {
            if !own.view.isHidden { return (own.view, Self.menuOrigin(under: own.view)) }
            return moreView.isHidden ? nil : (moreView, Self.menuOrigin(under: moreView))
        }
        let commands = ZenitToolbarBuilder.workspaceCommands.map(\.identifier)
        guard let index = commands.firstIndex(of: identifier),
              let group = entries.first(where: { $0.identifier == .zenitWorkspaceGroup })
        else { return nil }
        guard !group.view.isHidden else {
            return moreView.isHidden ? nil : (moreView, Self.menuOrigin(under: moreView))
        }
        var origin = Self.menuOrigin(under: group.view)
        if index == commands.count - 1 {
            origin.x = max(group.view.bounds.minX, group.view.bounds.maxX - menuWidth)
        }
        return (group.view, origin)
    }

    /// Opens `menu` under the chip of the band item `identifier` (L-29). Returns `false`, and
    /// opens nothing, when the band has no chip to hang it from; the caller then chooses.
    ///
    /// Live test 5 (2026-10-03): the toolbar's Export chooser was placed at the mouse pointer.
    /// Pressed through accessibility (VoiceOver's press, with the pointer resting on the
    /// canvas) it opened in the middle of the drawing, nowhere near the chip.
    @discardableResult
    public func popUpMenu(_ menu: NSMenu, under identifier: NSToolbarItem.Identifier) -> Bool {
        guard let placement = menuPlacement(for: identifier, menuWidth: menu.size.width) else { return false }
        presentMenu(menu, placement.origin, placement.view)
        return true
    }

    // MARK: - The window's drag area

    /// The system's titlebar double-click setting (Desktop & Dock ▸ Double-click a window's
    /// title bar to …).
    static func doubleClickAction(reading read: (String) -> Any?) -> DoubleClickAction {
        if let value = read("AppleActionOnDoubleClick") as? String {
            switch value {
            case "Minimize": return .minimize
            case "None": return .none
            default: return .zoom
            }
        }
        if let minimise = read("AppleMiniaturizeOnDoubleClick") as? Bool, minimise { return .minimize }
        return .zoom
    }

    /// Runs the titlebar double-click action, as the system titlebar would.
    public func performTitlebarDoubleClick() {
        performWindowAction(Self.doubleClickAction(reading: readGlobalDefault), window)
    }

    /// The band's empty area is the window's titlebar: drag to move, double-click per the
    /// system setting. The chips and tabs are their own views and never get here. A count of 2
    /// is two presses at the same place: ``ZPDFProjectWindow`` re-counts a press that lands
    /// anywhere else as a first click (L-108).
    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            performTitlebarDoubleClick()
            return
        }
        window?.performDrag(with: event)
    }
}

/// A hosting view that can be told to ignore the safe area.
///
/// The band lies under the transparent titlebar, so every view in it inherits a 32 pt top safe
/// area. SwiftUI honours it by padding its content — a 60 pt chip measured 92 pt and drew its
/// icon a third of the way down — which is right for content that must clear the titlebar and
/// wrong for the chrome that *is* the titlebar.
@MainActor
protocol ZPDFSafeAreaIgnoring: AnyObject {
    func ignoreSafeArea()
}

extension NSHostingView: ZPDFSafeAreaIgnoring {
    func ignoreSafeArea() { safeAreaRegions = [] }
}

extension ProjectTopBandView {
    /// Every hosting view in a subtree stops honouring the titlebar's safe area.
    static func ignoreSafeArea(in view: NSView) {
        (view as? ZPDFSafeAreaIgnoring)?.ignoreSafeArea()
        for subview in view.subviews { ignoreSafeArea(in: subview) }
    }
}

/// A menu row's action carried on the row: the band's own sidebar chips' overflow rows.
private final class BandMenuAction: NSObject {
    let perform: @MainActor () -> Void
    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
    @MainActor @objc func run(_ sender: Any?) { perform() }
}
